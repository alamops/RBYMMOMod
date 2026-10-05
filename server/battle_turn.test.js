#!/usr/bin/env node
'use strict';

/*
 * Cross-runtime parity suite for the turn machine: `lib/battle/Turn.js`.
 *
 * The sibling suite (battle.test.js) pins the *formulas* against a shared
 * vector pack. A vector cannot express what this file is for: the order the
 * questions get asked in, which of them are asked at all, and therefore how
 * many bytes come off the RNG before the next one. Two runtimes can agree on
 * every damage number and still fight two different battles from one seed if
 * one of them draws a crit byte for a move that missed.
 *
 * So the expected event streams are not written here and not computed here.
 * They come from luajit actually running src/BattleSim/Turn.lua over the same
 * scenarios, spawned by `tests/drivers/battle_turn_parity.lua`. When luajit is
 * not on PATH the same driver's committed output --
 * tests/fixtures/battle_turn_parity.json -- stands in, and when luajit *is*
 * present both are checked, so a fixture that drifted behind the Lua is a
 * failure rather than a suite that quietly stopped testing anything.
 *
 * The scenarios below are the JS half of that pair and have to stay a literal
 * mirror of the driver's: same seeds, same parties, same choices in the same
 * order. A change to one is a change to both, and regenerating the fixture is
 * the third step:
 *
 *   luajit tests/drivers/battle_turn_parity.lua . > tests/fixtures/battle_turn_parity.json
 *
 * Regenerate whenever RNG draw sites move — item use / catch rolls are the
 * usual suspects after BattleSim item work.
 *
 * ROM-free by construction: every species, move and item named here is
 * invented, and the type charts are two-by-two integers.
 *
 * Run: node --test server/battle_turn.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { Turn, events: Events } = require('./lib/battle');

const ROOT = path.join(__dirname, '..');
const DRIVER = path.join(ROOT, 'tests', 'drivers', 'battle_turn_parity.lua');
const FIXTURE = path.join(ROOT, 'tests', 'fixtures', 'battle_turn_parity.json');

// ------------------------------------------------------------------
// fixtures -- mirrored line for line from the Lua driver
// ------------------------------------------------------------------

function mv(id, power, accuracy, type, pp) {
  return { id, pp: pp === undefined ? 60 : pp, power, accuracy, type, effect: 0, chance: 0 };
}

function mn(o) {
  const out = {
    species: o.species,
    level: o.level === undefined ? 20 : o.level,
    hp: o.hp,
    maxHp: o.maxHp === undefined ? 100 : o.maxHp,
    status: o.status,
    statusTurns: o.statusTurns,
    confusion: o.confusion,
    toxicCounter: o.toxicCounter,
    types: o.types,
    stats: {
      atk: o.atk === undefined ? 40 : o.atk,
      def: o.def === undefined ? 40 : o.def,
      spd: o.spd === undefined ? 40 : o.spd,
      spc: o.spc === undefined ? 40 : o.spc,
    },
    moves: o.moves,
  };
  if (o.catchRate !== undefined) out.catchRate = o.catchRate;
  if (o.evs) out.evs = o.evs;
  if (o.baseSpd !== undefined) out.baseSpd = o.baseSpd;
  // K1's `traded`, and raw sheet fields the shorthand above does not carry
  // (reflect, disable, ...) -- both absent from every scenario before G1b's.
  if (o.traded) out.traded = true;
  Object.assign(out, o.extra || {});
  return out;
}

function build(opts) {
  const { battle, reason } = Turn.attempt(opts);
  assert.ok(battle, `scenario refused: ${reason}`);
  return battle;
}

// The events go into one flat list, and how many came out of each drain goes
// into a second one beside it. The counts are not decoration: they are the only
// record of *when* an event was available, and a clock that fired a turn early
// produces exactly the same events in exactly the same order, just one drain
// sooner.
let batches = [];

function drainInto(battle, into) {
  const list = battle.drainEvents();
  for (const event of list) into.push(event);
  batches.push(list.length);
}

// The stored battle stats behind the stream (the g1_* scenarios): every
// standing seat's `cur` and stages, and its screens, at the point the scenario
// asks. Only a scenario that calls this carries a `probes` key at all, so every
// scenario that predates it encodes exactly as it did.
let probes = [];

function probe(battle, at) {
  for (const fighter of battle.fighters) {
    const mon = fighter.active ? fighter.mons[fighter.active - 1] : null;
    if (mon && mon.hp > 0) {
      probes.push({
        at, slot: fighter.slot,
        atk: mon.cur.atk, def: mon.cur.def, spd: mon.cur.spd, spc: mon.cur.spc,
        sAtk: mon.stages.atk, sDef: mon.stages.def, sSpd: mon.stages.spd,
        sSpc: mon.stages.spc, sAcc: mon.stages.acc, sEva: mon.stages.eva,
        reflect: mon.reflect === true, lightScreen: mon.lightScreen === true,
      });
    }
  }
}

// A flinch the stream never shows (the g1_flinch_* scenarios): a standing
// seat's FLINCHED bit, read between turns -- after one turn's events and the
// next turn's open, which is where the reset does or does not happen. Rows of
// their own shape in the same `probes` list.
function probeFlinch(battle, at) {
  for (const fighter of battle.fighters) {
    const mon = fighter.active ? fighter.mons[fighter.active - 1] : null;
    if (mon && mon.hp > 0) probes.push({ at, slot: fighter.slot, flinch: mon.flinch === true });
  }
}

const SCENARIOS = [];
const scenario = (name, run) => SCENARIOS.push({ name, run });

const fightOrReplace = (battle, playerId) => {
  const snap = battle.snapshot();
  for (const f of snap.field || []) {
    if (f.playerId === playerId) {
      if (f.mustReplace) {
        let slot = null;
        for (let i = 0; i < (f.party || []).length; i += 1) {
          if ((f.party[i] || 0) > 0) { slot = i; break; }
        }
        if (slot !== null) {
          return battle.submitChoice(playerId, { action: 'switch', slot });
        }
        return false;
      }
      break;
    }
  }
  return battle.submitChoice(playerId, { action: 'fight', move: 0 });
};

// 1. a deterministic KO fight between two equally fast sides, so the speed
//    tie-break byte is spent on every turn and faint replacement runs.
scenario('ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'ko', mode: '1v1', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 120, atk: 60, spd: 55, moves: [thump()] }),
        mn({ species: 'Gamma', maxHp: 90, moves: [thump()] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 120, atk: 58, spd: 55, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 90, moves: [thump()] }),
      ] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 40; i += 1) {
    if (battle.outcome()) break;
    fightOrReplace(battle, 'p1');
    fightOrReplace(battle, 'p2');
    drainInto(battle, events);
  }
  return battle;
});

// 2. a side drops and the grace runs out: forfeit, no rolls at all.
scenario('forfeit', (events) => {
  const battle = build({
    id: 'ff', mode: '1v1', seed: 7, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.disconnect('p2');
  drainInto(battle, events);
  battle.tick(30);
  drainInto(battle, events);
  battle.tick(61);
  drainInto(battle, events);
  return battle;
});

// 3. a drop that comes back inside the window, and the fight carries on.
scenario('reconnect', (events) => {
  const battle = build({
    id: 'rc', mode: '1v1', seed: 11, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 60,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 30,
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.disconnect('p1');
  battle.tick(30);
  battle.reconnect('p1');
  drainInto(battle, events);
  // Past the deadline the drop started, inside the one the return restarted:
  // nothing may fire here, which is the whole claim about a resumed clock.
  battle.tick(80);
  drainInto(battle, events);
  battle.tick(120);
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 4. the awkward turn: a burn residual, a paralysis gate, confusion, a type
//    chart with both directions on it, an item, a status move, a switch and a
//    deadline that expires with one side still owing a choice.
scenario('status', (events) => {
  const battle = build({
    id: 'st', mode: '1v1', seed: 99, choiceTimeout: 10, reconnectGrace: 60,
    chart: [[100, 200, 50], [50, 100, 200], [200, 50, 100]],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 25, maxHp: 160, atk: 70, def: 45,
          spd: 50, types: [0], status: 'BRN',
          moves: [mv('thump', 40, 255, 0), mv('hex', 0, 255, 1), mv('weak', 35, 200, 2)] }),
        mn({ species: 'Gamma', maxHp: 100, spd: 30, types: [2],
          moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 25, maxHp: 150, atk: 65, def: 50,
          spd: 50, types: [1], status: 'PAR', confusion: 3,
          moves: [mv('thump', 40, 255, 1)] }),
      ] }],
    },
  });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'item', item: 'restore' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'fight', move: 2 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);

  // Only one side answers; the clock spends the other one's turn.
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.tick(1000);
  drainInto(battle, events);

  for (let i = 0; i < 25; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 5. an immunity row, a sleep counter that runs out, and toxic stacking until
//    it kills the side carrying it.
scenario('immune', (events) => {
  const battle = build({
    id: 'im', mode: '1v1', seed: 31, choiceTimeout: 60, reconnectGrace: 60,
    chart: [[100, 0], [100, 100]],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, types: [0], status: 'SLP',
          statusTurns: 2, moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 5, types: [1], status: 'TOX',
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 20; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 6. running: one side concedes, and then a fixture where both do.
scenario('run_one', (events) => {
  const battle = build({
    id: 'r1', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'run' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

scenario('run_both', (events) => {
  const battle = build({
    id: 'r2', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'run' });
  battle.submitChoice('p2', { action: 'run' });
  drainInto(battle, events);
  return battle;
});

// 7. the tie-break byte at its boundary, from both sides of it. The two seeds
//    are chosen so the first draw of the battle -- which in a tied 1v1 is the
//    tie-break byte itself -- is 127 and then 128, the two values that decide
//    whether the group reverses. Without these a threshold that had drifted by
//    one would still agree with the Lua on every other fixture here.
const tie = (id, seed) => (events) => {
  const battle = build({
    id, mode: '1v1', seed, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 60, spd: 50,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, atk: 45, spd: 50,
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
};

scenario('tie_low', tie('tl', 172)); // first byte 127: side a keeps the lead
scenario('tie_high', tie('th', 41)); // first byte 128: the group reverses

// 8. a residual on each side at once, which is the only way the end-of-turn
//    order is observable: residuals run in field order, not in the speed order
//    the moves used, and with one burn in the fixture that claim is untestable.
scenario('residual_both', (events) => {
  const battle = build({
    id: 'rb', mode: '1v1', seed: 23, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 160, spd: 40, status: 'BRN',
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 160, spd: 90, status: 'PSN',
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 9. a switch and an item in the same turn, on opposite sides. Both resolve
//    before any move and neither rolls, so the only thing this fixture states
//    is the order of the two passes -- which is the only thing about them that
//    the two runtimes could get differently.
scenario('switch_item', (events) => {
  const battle = build({
    id: 'si', mode: '1v1', seed: 13, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, moves: [mv('thump', 40, 255, 0)] }),
        mn({ species: 'Gamma', maxHp: 180, moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  battle.submitChoice('p2', { action: 'item', item: 'restore' });
  drainInto(battle, events);
  return battle;
});

// 10. sleep with no counter on it. A party can arrive carrying SLP and no
//     number, and the two runtimes have to invent the same length or one of
//     them spends a turn the other one does not -- so this fixture states the
//     default out loud rather than leaving it to the copy step's comment.
scenario('sleep_default', (events) => {
  const battle = build({
    id: 'sd', mode: '1v1', seed: 61, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 60, status: 'SLP',
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10,
          moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 11. PP running out, on both of the paths that can happen down. Side a spends
//     its last PP on move one and the deadline then has to auto-pick move two;
//     side b starts with nothing left anywhere and every one of its turns falls
//     through to the first move on empty PP, because a turn that cannot pick
//     has to resolve rather than hang. A port that forgot to decrement would
//     keep picking side a's first move and agree with nothing here.
scenario('pp', (events) => {
  const battle = build({
    id: 'pp', mode: '1v1', seed: 88, choiceTimeout: 10, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 300, spd: 60, moves: [
          mv('last', 40, 255, 0, 1), mv('spare', 30, 255, 0, 5),
        ] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 300, spd: 10, moves: [
          mv('empty', 20, 255, 0, 0),
        ] })] }],
    },
  });
  drainInto(battle, events);
  let clock = 0;
  for (let i = 0; i < 3; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    clock += 20;
    battle.tick(clock);
    drainInto(battle, events);
  }
  return battle;
});

// 12. a 2v2 across four field slots with every actor at the same speed, so the
//     tie-break reverses a group of four rather than a pair.
scenario('coop', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'cc', mode: 'coop_pvp', seed: 777, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 150, spd: 50, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 150, spd: 50, moves: [thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 150, spd: 50, moves: [thump()] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 150, spd: 50, moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 4; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('b1', { action: 'fight', move: 0 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  battle.disconnect('b1');
  battle.tick(1000);
  drainInto(battle, events);
  return battle;
});

// 13. wild catch: MASTER_BALL ends without catch rolls; still a new mode and
//     outcome.reason / caught digest the prior fixtures never touched.
scenario('wild_master', (events) => {
  const battle = build({
    id: 'wm', mode: 'wild', seed: 51, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 80,
          moves: [mv('splash', 0, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 40, hp: 10, spd: 10, catchRate: 255,
          moves: [mv('splash', 0, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'item', item: 'MASTER_BALL' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 14. wild POKE_BALL: catchAttempt draws from the RNG. Regenerate the fixture
//     whenever catch/item draw sites move.
scenario('wild_ball', (events) => {
  const battle = build({
    id: 'wb', mode: 'wild', seed: 88, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, spd: 80,
          moves: [mv('splash', 0, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 100, hp: 25, spd: 10, catchRate: 45,
          moves: [mv('splash', 0, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'item', item: 'POKE_BALL' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  if (!battle.outcome()) {
    battle.submitChoice('p1', { action: 'item', item: 'MASTER_BALL' });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 15. vitamins: fight-local Stat Exp on the sheet (+2560); Gen1 stat delta.
scenario('vitamin', (events) => {
  const battle = build({
    id: 'vt', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 100, maxHp: 200, spd: 80, atk: 40,
          moves: [mv('splash', 0, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10,
          moves: [mv('splash', 0, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'item', item: 'PROTEIN' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 16. round 5: wild-mode KO. The faint on the synthetic side b is the one
//     `_awardExp` pays for -- one `exp` event for the sole owner-slot winner
//     (slot 0), split one way (participants = 1). Looped like `ko` rather
//     than aimed at an exact turn count, so the fixture survives a damage
//     formula tweak without a hand-tuned HP number going stale.
scenario('wild_ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'wk', mode: 'wild', seed: 5001, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80, moves: [thump()] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 60, spd: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 10; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 17. round 5: coop_wild 2v1 KO. Both owner slots are standing when the
//     wild mon falls, so `_awardExp` walks bySide.a twice -- slot 0 (a1)
//     then slot 1 (a2), field-slot order -- and each event names
//     participants = 2, the share count the split is over.
scenario('coop_wild_ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'cwk', mode: 'coop_wild', seed: 5002, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 90, spd: 70, moves: [thump()] })] },
      ],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 10; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0 });
    battle.submitChoice('a2', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 18. round 6: participation KO. Mon A fights, switches out alive, and its
//     replacement (mon B) lands the KO. Vanilla still owes mon A a share --
//     it was in against this foe (`_refield` / `_awardExp`) -- so the
//     referee pays both, on the one seat that owns them, each event naming
//     which party index (`mon`, 0-based) is banking it: 0 for Alpha, 1 for
//     Gamma, both against a divisor of 2.
scenario('participation_ko', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const tap = () => mv('tap', 5, 255, 0);
  const battle = build({
    id: 'pko', mode: 'wild', seed: 101, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80, moves: [thump()] }),
        mn({ species: 'Gamma', maxHp: 200, atk: 90, spd: 80, moves: [thump()] }),
      ] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 90, spd: 10, moves: [tap()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  for (let i = 0; i < 10; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 19. an Explosion-style double-KO in coop_wild: a1's move fells the wild
//     mon AND a1 itself in the same action. `_faint`/`_unfield` take the
//     self-KO'er out of every participation set before `_drainExp` counts
//     anyone, so a1 is neither paid nor counted, and the wild mon's one exp
//     event names only a2, participants = 1.
scenario('explode_double_ko', (events) => {
  // This file's own `mv` always writes effect=0 (its pp default lives in
  // that slot instead) -- every other scenario here is fine with that, but
  // EXPLODE is effect 7 (lib/battle/effects.js's EXPLODE_EFFECT), so `boom`
  // is built by hand rather than through the shared helper.
  const boom = () => ({ id: 'boom', pp: 60, power: 250, accuracy: 255, type: 0,
    effect: 7, chance: 0 });
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'xa', mode: 'coop_wild', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 200, spd: 90, moves: [boom()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 40, spd: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 60, spd: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0 });
  battle.submitChoice('a2', { action: 'fight', move: 0 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// 20. the replacement mark: a1 KOs b1, then on the very next turn a switches
//     to a2 (still alive, a1 was never fainted) the same turn b fields b2.
//     Vanilla still marks a1 -- it was standing when b1 fell -- and the
//     send-out's own mark lands on a2 too, so when a2 finishes off b2 both
//     a1 and a2 are paid, on the one seat, divisor 2.
scenario('replacement_mark', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const tap = () => mv('tap', 5, 255, 0);
  const battle = build({
    id: 'xd', mode: 'coop_npc', seed: 101, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 300, atk: 200, spd: 80, moves: [thump()] }),
        mn({ species: 'Gamma', maxHp: 300, atk: 200, spd: 80, moves: [thump()] }),
      ] }],
      b: [{ playerId: 'npc', name: 'Rival', mons: [
        mn({ species: 'Beta', maxHp: 40, spd: 10, moves: [tap()] }),
        mn({ species: 'Delta', maxHp: 40, spd: 10, moves: [tap()] }),
      ] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('npc', { action: 'fight', move: 0 });
  drainInto(battle, events);
  // npc's fallen b1 owes a replacement first -- close the replace phase
  // (b fields b2) -- THEN p1 files its voluntary switch to a2 on the
  // turn-2 window that the closed replace phase opens.
  battle.submitChoice('npc', { action: 'switch', slot: 1 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'switch', slot: 1 });
  drainInto(battle, events);
  for (let i = 0; i < 6; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('npc', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 21. dead-target retargeting (U-wave): a faster ally KOs the seat a slower
//     ally aimed at, in the same turn. `_retarget` (Turn.js's twin of
//     Turn.lua:646-690) is the only reason the slower ally's action does not
//     fizzle -- it redraws no RNG of its own, but its target resolution runs
//     on every runtime and nothing here reached it before: U1 found no
//     existing scenario landed an action on a seat that died mid-turn, which
//     is why the bug (a fizzle, "has no target", where a real attack
//     belonged) lived undetected. The retargeted hit still draws the same
//     accuracy/damage/crit bytes a same-turn attack always would, so this
//     also exercises those draws from a target the choice never named.
scenario('retarget_ko', (events) => {
  const battle = build({
    id: 'rk', mode: 'coop_pvp', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'fast', name: 'Fast', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 200, spd: 90,
               moves: [mv('bigsmash', 150, 255, 0)] })] },
        { playerId: 'slow', name: 'Slow', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 60, spd: 10,
               moves: [mv('tap', 40, 255, 0)] })] },
      ],
      b: [
        { playerId: 'foeA', name: 'FoeA', mons: [
          mn({ species: 'Beta', maxHp: 12, spd: 5,
               moves: [mv('thump', 40, 255, 0)] })] },
        { playerId: 'foeB', name: 'FoeB', mons: [
          mn({ species: 'Delta', maxHp: 200, spd: 4,
               moves: [mv('thump', 40, 255, 0)] })] },
      ],
    },
  });
  drainInto(battle, events);
  // Both allies aim at foeA (slot 3). Fast (spd 90) KOs it; Slow (spd 10)
  // resolves after and must retarget onto foeB (slot 4) rather than fizzle.
  battle.submitChoice('fast', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('slow', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('foeA', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('foeB', { action: 'fight', move: 0, target: 0 });
  drainInto(battle, events);
  return battle;
});

// Who the referee swings at when nobody chose. A coop_npc trainer holds two
// seats with no connection behind them, so both file their own picks through
// `autoPick` -- and until the aim stream existed, both picked "the lowest
// living foe" and hammered seat 0 for the whole fight while the second player
// was never attacked once.
//
// Six turns is enough for the spread to show, and the fixture pins the aims
// themselves rather than merely "they were not all seat 0": the aim draw is a
// second generator, and a second generator is a second way for the runtimes to
// part company. The snapshot's `rngState` is the other half of the claim -- it
// must be exactly what it was before aims spread, because the draws come off
// `aim` and never off `rng`.
scenario('coop_npc_aim', (events) => {
  const battle = build({
    id: 'aim', mode: 'coop_npc', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'p1', name: 'One', mons: [
          mn({ species: 'Alpha', maxHp: 400, spd: 10,
               moves: [mv('tap', 40, 255, 0)] })] },
        { playerId: 'p2', name: 'Two', mons: [
          mn({ species: 'Gamma', maxHp: 400, spd: 10,
               moves: [mv('tap', 40, 255, 0)] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', mons: [
          mn({ species: 'Beta', maxHp: 400, spd: 90,
               moves: [mv('thump', 40, 255, 0)] })] },
        { playerId: 'n2', name: 'NpcB', mons: [
          mn({ species: 'Delta', maxHp: 400, spd: 80,
               moves: [mv('thump', 40, 255, 0)] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 6; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('p2', { action: 'fight', move: 0, target: 4 });
    battle.autoPick('n1');
    battle.autoPick('n2');
    drainInto(battle, events);
  }
  return battle;
});

// 25. a whole trapping chain: Wrap lands, the counter is Gen1's *total* attack
//     count, so the turn it lands on deals the move's damage and no residual on
//     top of it -- every later turn is one attack, narrated as a forced skip on
//     both seats. A turn forced on every seat opens without a deadline and
//     waits for a `tick`, so this is also the one scenario where the batch
//     counts prove the two runtimes advance that chain in the same steps.
scenario('trap_chain', (events) => {
  const wrap = () => ({ id: 'wrap', pp: 60, power: 5, accuracy: 255, type: 0,
    effect: 42, chance: 0 });
  const battle = build({
    id: 'xt', mode: '1v1', seed: 9999, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 120, moves: [wrap()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, def: 200, spd: 1,
          moves: [mv('tap', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  // The forced turns resolve one tick at a time; ten is past the longest roll.
  for (let step = 1; step <= 10; step += 1) {
    battle.tick(step);
    drainInto(battle, events);
  }
  // A referee-filled answer cannot be taken back -- the refusal is silent, so
  // what this pins is that neither runtime emits an `unchose` for it.
  battle.submitChoice('p2', { action: 'cancel' });
  battle.submitChoice('p2', { action: 'switch', slot: 0 });
  drainInto(battle, events);
  return battle;
});

// 26. the display name a sheet carries (PROTOCOL 26), and the id it falls back
//     to when it carries none. Both spellings appear in one fight, because both
//     reach the same sentences: "used", the two halves of Disable, and Mimic's
//     "learned". A protocol-25 client uploads moves with no `name` at all, so
//     the fallback is not a defensive branch -- it is what half the fights on a
//     mixed hub narrate under, and the two runtimes have to agree on it word
//     for word.
// (DISABLE picks its slot at random -- DisableEffect's `BattleRandom & 3`,
// R1b: seed 4243 picks THUMP HIT.)
scenario('move_names', (events) => {
  // `mv` writes effect=0, so the two effect moves are built by hand the way
  // `explode_double_ko` builds EXPLODE. 86 is DISABLE_EFFECT and 82 is
  // MIMIC_EFFECT (lib/battle/Effects.js).
  const swipe = () => ({
    id: 'slow_swipe', name: 'SLOW SWIPE', pp: 60, power: 10,
    accuracy: 255, type: 0, effect: 0, chance: 0,
  });
  const lockdown = () => ({
    id: 'lock_down', name: 'LOCK DOWN', pp: 60, power: 0,
    accuracy: 255, type: 0, effect: 86, chance: 0,
  });
  const copycat = () => ({
    id: 'copy_cat', name: 'COPY CAT', pp: 60, power: 0,
    accuracy: 255, type: 0, effect: 82, chance: 0,
  });
  const thump = () => ({
    id: 'thump', name: 'THUMP HIT', pp: 60, power: 10,
    accuracy: 255, type: 0, effect: 0, chance: 0,
  });
  // No `name` at all: the protocol-25 sheet, narrated under its id.
  const nudge = () => mv('nudge', 10, 255, 0);
  const battle = build({
    id: 'mn', mode: '1v1', seed: 4243, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 90,
             moves: [swipe(), lockdown(), copycat()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 10,
             moves: [thump(), nudge()] })] }],
    },
  });
  drainInto(battle, events);
  // 1: both swing. "Alpha used SLOW SWIPE" and "Beta used THUMP HIT" are the
  //    line this whole field exists for; before it they read "slow_swipe".
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  // 2: Ann is faster, so Disable lands on the move Bob just used and then
  //    refuses the one he picked -- "THUMP HIT was disabled", "THUMP HIT is
  //    disabled", both under the same spelling the attack was.
  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  // 3: Mimic copies Bob's last move. The copy has to carry the name across
  //    with it, or "Alpha learned THUMP HIT" reverts to the slug here and on
  //    every turn the copy is used afterwards. Bob falls back to the move that
  //    carries no name at all.
  battle.submitChoice('p1', { action: 'fight', move: 2 });
  battle.submitChoice('p2', { action: 'fight', move: 1 });
  drainInto(battle, events);
  // 4-8: the copy is used, and Disable wears off somewhere in here ("THUMP HIT
  //      is no longer disabled") -- the one sentence that is written from a
  //      move nobody chose this turn.
  for (let i = 0; i < 5; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 2 });
    battle.submitChoice('p2', { action: 'fight', move: 1 });
    drainInto(battle, events);
  }
  return battle;
});

// 27-29. uploaded badge sets, and where the referee lets them count
//     (Turn.BADGE_MODES / Turn.BADGE_SIDE: side a of a fight against the
//     computer, never a link battle -- pokered's ApplyBadgeStatBoosts returns
//     early in one). Speeds sit a step apart so a SOULBADGE that leaked would
//     reorder the field rather than merely move a damage number, and the npc
//     fight carries a special move so VOLCANOBADGE is read on both ends of a
//     hit. `badges_link` and `badges_coop_pvp` fight as though nobody held a
//     badge; `badges_npc` boosts side a and ignores side b's upload. Until
//     these, no scenario carried a badge at all, so the twins had never been
//     held to the same boost even where the boost is right.
const allBadges = () => ({
  BOULDERBADGE: true, THUNDERBADGE: true, SOULBADGE: true,
  VOLCANOBADGE: true,
});

scenario('badges_link', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'bl', mode: '1v1', seed: 2718, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 60, spd: 40, moves: [thump()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, atk: 60, spd: 42, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

scenario('badges_coop_pvp', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'bp', mode: 'coop_pvp', seed: 3141, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: allBadges(), mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, spd: 40, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', badges: allBadges(), mons: [
          mn({ species: 'Gamma', maxHp: 300, atk: 55, spd: 30, moves: [thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, spd: 42, moves: [thump()] })] },
        { playerId: 'b2', name: 'Bea', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 300, atk: 55, spd: 34, moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  return battle;
});

scenario('badges_npc', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const zap = () => mv('zap', 40, 255, 1);
  const battle = build({
    id: 'bn', mode: 'coop_npc', seed: 1618, choiceTimeout: 60, reconnectGrace: 60,
    specialTypes: [1],
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: allBadges(), mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, spd: 40, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', badges: allBadges(), mons: [
          mn({ species: 'Gamma', maxHp: 300, spc: 60, spd: 30, moves: [zap()] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, spd: 42, moves: [thump()] })] },
        { playerId: 'n2', name: 'NpcB', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 300, spc: 60, spd: 37, moves: [zap()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('n1', { action: 'fight', move: 0, target: 0 });
    battle.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  return battle;
});


// 30-41. Gen 1 stored battle stats (docs/plans/gen12-referee-fidelity.md §1
//     items 1-5, task G1a): every trigger of the badge-stacking glitch, the
//     re-penalty glitch, the resets, the 999 / 1 walls, critical hits on party
//     stats, Reflect and Light Screen in the defence, the 8-bit scaling, the
//     Explosion order, the 997 cap, the self-hit's borrowed Reflect and the
//     flinch reset at turn open. `probe` pins the battle stats themselves; the
//     "Gen 1 stored battle stats" tests below state the hand-checked numbers.
//     `baseSpd: 0` holds a crit off where it would blur a number, 255 with a
//     high-crit move forces one.
function fx(id, power, effect, o = {}) {
  const out = {
    id, pp: o.pp === undefined ? 60 : o.pp, power, accuracy: 255,
    type: o.type === undefined ? 0 : o.type, effect,
    chance: o.chance === undefined ? 0 : o.chance,
  };
  if (o.highCrit) out.highCrit = true;
  return out;
}

// The player's own raise (50 = ATTACK_UP2) and an accuracy raise (14) each
// re-run every badge; the wild monster's paralysis is re-quartered each time.
scenario('g1_stack_up', (events) => {
  const battle = build({
    id: 'g1u', mode: 'wild', seed: 6101, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 300, atk: 100, def: 80, spd: 60, spc: 50,
          baseSpd: 0, moves: [fx('sharpen', 0, 50), fx('aim', 0, 14),
            fx('thump', 40, 0)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 300, spd: 80, status: 'PAR', baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  [0, 1, 2].forEach((move, i) => {
    battle.submitChoice('p1', { action: 'fight', move });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
    probe(battle, i + 1);
  });
  return battle;
});

// The enemy's drops on the player: a primary (18), a side-effect drop (71,
// Psychic's) and an accuracy drop (22) -- each re-runs the badges, and the
// re-penalty halves the burned target's Attack again every time.
scenario('g1_stack_down', (events) => {
  const battle = build({
    id: 'g1d', mode: 'wild', seed: 6102, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 300, atk: 100, def: 80, spd: 60, spc: 50,
          status: 'BRN', baseSpd: 0, moves: [fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 300, spd: 90, baseSpd: 0,
          moves: [fx('growl', 0, 18), fx('psyray', 40, 71, { chance: 100 }),
            fx('sand', 0, 22)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  [0, 1, 2].forEach((move, i) => {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move });
    drainInto(battle, events);
    probe(battle, i + 1);
  });
  return battle;
});

// An X item and Rage: both are the player's raises, so both re-run the badges;
// the item's re-penalty lands on the battler opposite and Rage's on the
// attacker that built it.
scenario('g1_rage_xitem', (events) => {
  const battle = build({
    id: 'g1r', mode: 'wild', seed: 6103, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), bag: { X_SPEED: 1 },
        mons: [
          mn({ species: 'Alpha', maxHp: 400, atk: 100, def: 80, spd: 60, spc: 50,
            baseSpd: 0, moves: [fx('fury', 20, 81)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 400, atk: 80, spd: 50, status: 'BRN',
          baseSpd: 0, moves: [fx('thump', 10, 0)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  battle.submitChoice('p1', { action: 'item', item: 'X_SPEED' });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  probe(battle, 1);
  for (let turn = 2; turn <= 3; turn += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
    probe(battle, turn);
  }
  return battle;
});

// The resets: a switch-in reloads party -> badges with every stage at 0, and
// Haze copies the unmodified stats over both battlers -- badges and the foe's
// paralysis penalty lifted with the stages.
scenario('g1_resets', (events) => {
  const battle = build({
    id: 'g1z', mode: 'wild', seed: 6104, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 300, atk: 100, def: 80, spd: 60, spc: 50,
          baseSpd: 0, moves: [fx('sharpen', 0, 50), fx('haze', 0, 25)] }),
        mn({ species: 'Gamma', maxHp: 300, baseSpd: 0, moves: [fx('splash', 0, 85)] }),
      ] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 300, spd: 80, status: 'PAR', baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  const plan = [
    { action: 'fight', move: 0 },
    { action: 'switch', slot: 1 },
    { action: 'switch', slot: 0 },
    { action: 'fight', move: 0 },
    { action: 'fight', move: 1 },
  ];
  plan.forEach((choice, i) => {
    battle.submitChoice('p1', choice);
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
    probe(battle, i + 1);
  });
  return battle;
});

// The walls, in a link fight (no badges; the re-penalty is unconditional): a
// raise past 999 stores 999, the next raise on that 999 fails with the stage
// wound back one step (+2 nets +1), and a drop on a stat already at 1 fails
// the same way (-2 nets -1).
scenario('g1_walls', (events) => {
  const battle = build({
    id: 'g1w', mode: '1v1', seed: 6105, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 300, atk: 500, spd: 90, baseSpd: 0,
          moves: [fx('sharpen', 0, 50), fx('soften', 0, 19),
            fx('crush', 0, 59)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 300, def: 1, spd: 60, status: 'PAR',
          baseSpd: 0, moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  [0, 0, 1, 2].forEach((move, i) => {
    battle.submitChoice('p1', { action: 'fight', move });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
    probe(battle, i + 1);
  });
  return battle;
});

// A critical hit reads both party stats: the raised, badged, burned Attack and
// the foe's Reflect all fall away.
scenario('g1_crit_party', (events) => {
  const battle = build({
    id: 'g1c', mode: 'wild', seed: 6106, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 300, atk: 100, def: 80, spd: 60, spc: 50,
          status: 'BRN', baseSpd: 255,
          moves: [fx('sharpen', 0, 50), fx('slash', 70, 0, { highCrit: true })] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 400, def: 100, spd: 30, baseSpd: 0,
          moves: [fx('wall', 0, 65), fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  probe(battle, 1);
  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('wild', { action: 'fight', move: 1 });
  drainInto(battle, events);
  probe(battle, 2);
  return battle;
});

// Transform copies the battle and unmodified stats, never the party ones: the
// transformed monster's crit swings with its own pre-Transform Attack, and a
// crit on it reads its own pre-Transform Defense.
scenario('g1_transform_crit', (events) => {
  const battle = build({
    id: 'g1t', mode: '1v1', seed: 6107, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, atk: 30, def: 30, spd: 90, spc: 30,
          baseSpd: 255, moves: [fx('mimicry', 0, 57)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, atk: 200, def: 100, spd: 40, spc: 100,
          baseSpd: 255, moves: [fx('slash', 70, 0, { highCrit: true })] })] }],
    },
  });
  drainInto(battle, events);
  for (let turn = 1; turn <= 2; turn += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
    probe(battle, turn);
  }
  return battle;
});

// Screens double the defence before the scaling: 512 x2 = 1024 wraps to a 0
// byte and divides as 1. A second Reflect fails, a fixed-damage move ignores
// it, and Haze takes both screens down.
scenario('g1_screens', (events) => {
  const battle = build({
    id: 'g1s', mode: '1v1', seed: 6109, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 900, def: 512, spd: 90, baseSpd: 0,
          moves: [fx('wall', 0, 65), fx('glow', 0, 64), fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, atk: 100, spd: 30, baseSpd: 0,
          moves: [fx('thump', 10, 0), fx('sonic', 20, 41), fx('haze', 0, 25)] })] }],
    },
  });
  drainInto(battle, events);
  [[0, 0], [0, 1], [1, 2], [2, 0]].forEach(([mine, theirs], i) => {
    battle.submitChoice('p1', { action: 'fight', move: mine });
    battle.submitChoice('p2', { action: 'fight', move: theirs });
    drainInto(battle, events);
    probe(battle, i + 1);
  });
  return battle;
});

// The 997 cap sits before the type chart and the roll: 4200 is held to 997+2
// (a 999-HP target, so the event states the whole hit).
scenario('g1_cap', (events) => {
  const battle = build({
    id: 'g1k', mode: '1v1', seed: 6109, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 999, def: 10, spd: 90, types: [2],
          baseSpd: 0, moves: [fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 100, maxHp: 400, atk: 250, spd: 30,
          types: [1], baseSpd: 0, moves: [fx('crush', 200, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// Explosion halves the defence after the scaling: 300 -> 75 -> 37, not
// 300 -> 150 unscaled.
scenario('g1_explode_order', (events) => {
  const battle = build({
    id: 'g1x', mode: '1v1', seed: 6110, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 900, def: 300, spd: 90, types: [2],
          baseSpd: 0, moves: [fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 50, maxHp: 400, atk: 100, spd: 30,
          types: [1], baseSpd: 0, moves: [fx('blast', 170, 7)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// The confusion self-hit borrows the OPPONENT's Reflect for its own Defense:
// 160 against 9 x2 is 73 a hit rather than 144.
scenario('g1_self_hit_reflect', (events) => {
  const battle = build({
    id: 'g1h', mode: '1v1', seed: 6111, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 900, atk: 160, def: 9, spd: 30, confusion: 6,
          baseSpd: 0, moves: [fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('wall', 0, 65), fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  for (let turn = 1; turn <= 5; turn += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: turn === 1 ? 0 : 1 });
    drainInto(battle, events);
  }
  return battle;
});

// ...and in a 2v2 the Reflect it borrows is the battler opposite's: Ann (seat
// 0) faces Bob's Reflect, Abe (seat 1) faces Bea, who has none.
scenario('g1_opposite_reflect', (events) => {
  const battle = build({
    id: 'g1o', mode: 'coop_pvp', seed: 6112, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 900, atk: 160, def: 9, spd: 30, confusion: 6,
            baseSpd: 0, moves: [fx('splash', 0, 85)] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 900, atk: 160, def: 9, spd: 20, confusion: 6,
            baseSpd: 0, moves: [fx('splash', 0, 85)] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0,
            moves: [fx('wall', 0, 65), fx('splash', 0, 85)] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 400, spd: 80, baseSpd: 0,
            moves: [fx('splash', 0, 85)] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let turn = 1; turn <= 5; turn += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('b1', { action: 'fight', move: turn === 1 ? 0 : 1, target: 0 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  probe(battle, 5);
  return battle;
});

// A flinch landed on a monster that already moved dies at the next turn's
// open (MainInBattleLoop) instead of costing it that turn.
scenario('g1_flinch_reset', (events) => {
  const battle = build({
    id: 'g1f', mode: '1v1', seed: 6113, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('thump', 10, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 30, baseSpd: 0,
          moves: [fx('stomp', 10, 31, { chance: 100 })] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 42-58. Gen 1 priority, obedience, the called-move path and the flinch-reset
//     skip (docs/plans/gen12-referee-fidelity.md §1 items 6-8, task G1b).
//     Every obedience seed was picked by a scan to reach the branch its
//     comment names; the "Gen 1 priority, obedience" tests below force each
//     branch with scripted bytes, and the vector pack's `obedience` section
//     pins the rolls themselves.

// Quick Attack +1, Counter -1, read off the selected move; the same move on
// both sides falls to Speed. 1v1 is a link fight: priority is every mode's.
scenario('g1_priority', (events) => {
  const kit = () => [fx('QUICK_ATTACK', 10, 0), fx('thump', 10, 0), fx('COUNTER', 10, 0)];
  const battle = build({
    id: 'g1q', mode: '1v1', seed: 6301, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 30, baseSpd: 0, moves: kit() })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0, moves: kit() })] }],
    },
  });
  drainInto(battle, events);
  for (const [a, b] of [[0, 1], [0, 0], [1, 2], [2, 2], [0, 2]]) {
    battle.submitChoice('p1', { action: 'fight', move: a });
    battle.submitChoice('p2', { action: 'fight', move: b });
    drainInto(battle, events);
  }
  return battle;
});

// Four actors in three brackets: the two Quick Attacks at Speed 20 are one
// tie group (one byte: this seed's turn-1 byte is >= 128, NpcA's first; its
// turn-2 byte is below, Ann's first -- 6304 since COUNTER draws only its hit
// test, 6302 before), then the plain move, then the Counter at Speed 99,
// last.
scenario('g1_priority_group', (events) => {
  const battle = build({
    id: 'g1g', mode: 'coop_npc', seed: 6304, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 400, spd: 20, baseSpd: 0,
            moves: [fx('QUICK_ATTACK', 10, 0)] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 400, spd: 50, baseSpd: 0,
            moves: [fx('thump', 10, 0)] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', mons: [
          mn({ species: 'Beta', maxHp: 400, spd: 20, baseSpd: 0,
            moves: [fx('QUICK_ATTACK', 10, 0)] })] },
        { playerId: 'n2', name: 'NpcB', mons: [
          mn({ species: 'Delta', maxHp: 400, spd: 99, baseSpd: 0,
            moves: [fx('COUNTER', 10, 0)] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('n1', { action: 'fight', move: 0, target: 0 });
    battle.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  return battle;
});

// A Metronome that calls Quick Attack moved at Metronome's bracket: the
// faster foe goes first. The call spends Alpha's last PP and takes no
// Struggle recoil, and runs no second paralysis gate; the next turn's
// Struggle is the real thing and does recoil.
scenario('g1_metronome_last_pp', (events) => {
  const battle = build({
    id: 'g1m', mode: 'wild', seed: 6302, choiceTimeout: 60, reconnectGrace: 60,
    metronomePool: [fx('QUICK_ATTACK', 10, 0)],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 120, status: 'PAR', baseSpd: 0,
          moves: [fx('metronome', 0, 83, { pp: 1 })] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('thump', 10, 0)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// The whole CheckForDisobedience ladder on one traded level-100 monster with
// no badge (cap 10), paralysed, against a foe behind a Reflect (seed 6809's
// twelve turns are listed beside the Lua twin).
scenario('g1_obey_ladder', (events) => {
  const battle = build({
    id: 'g1l', mode: 'wild', seed: 6809, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 100, maxHp: 999, atk: 30, def: 60, spd: 90,
          status: 'PAR', traded: true, baseSpd: 0,
          moves: [fx('thump', 10, 0), fx('chop', 10, 0), fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 999, spd: 30, baseSpd: 0, extra: { reflect: true },
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  for (let turn = 1; turn <= 12; turn += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
    if (turn === 5) probe(battle, 5);
  }
  return battle;
});

// An R1 pass, then `.useRandomMove`: "used instead," and the PP comes off the
// CHOSEN slot, then a loaf line. Level 60 under RAINBOWBADGE (cap 50).
scenario('g1_obey_instead', (events) => {
  const battle = build({
    id: 'g1i', mode: 'wild', seed: 6316, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann',
        badges: { CASCADEBADGE: true, RAINBOWBADGE: true }, mons: [
          mn({ species: 'Alpha', level: 60, maxHp: 400, spd: 90, traded: true, baseSpd: 0,
            moves: [fx('thump', 10, 0), fx('chop', 10, 0), fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 30, baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// `.useRandomMove`'s four refusals, each on seed 6303 -- whose rolls answer
// "use another move" -- and each falling to `.monDoesNothing` without a
// `.chooseMove` draw.
const refusal = (name, moves, extra) => (events) => {
  const battle = build({
    id: name, mode: 'wild', seed: 6303, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann',
        badges: { CASCADEBADGE: true, RAINBOWBADGE: true }, mons: [
          mn({ species: 'Alpha', level: 60, maxHp: 400, spd: 90, traded: true,
            baseSpd: 0, moves, extra })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 30, baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
};
scenario('g1_obey_refuse_one', refusal('g1r1', [fx('thump', 10, 0)]));
scenario('g1_obey_refuse_disabled', refusal('g1r2',
  [fx('thump', 10, 0), fx('chop', 10, 0)], { disable: { moveIndex: 2, turns: 5 } }));
scenario('g1_obey_refuse_struggle', refusal('g1r3',
  [fx('thump', 10, 0, { pp: 0 }), fx('chop', 10, 0, { pp: 0 })]));
scenario('g1_obey_refuse_pp', refusal('g1r4',
  [fx('thump', 10, 0), fx('chop', 10, 0, { pp: 0 })]));

// No roll at all: EARTHBADGE's cap (101) over a level-100 traded monster, and
// CASCADEBADGE's 30 over a level-30 one -- the cap compare comes first.
scenario('g1_obey_capped', (events) => {
  const battle = build({
    id: 'g1c', mode: 'coop_wild', seed: 6302, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: { EARTHBADGE: true }, mons: [
          mn({ species: 'Alpha', level: 100, maxHp: 400, spd: 90, traded: true,
            baseSpd: 0, moves: [fx('thump', 10, 0), fx('chop', 10, 0)] })] },
        { playerId: 'a2', name: 'Abe', badges: { CASCADEBADGE: true }, mons: [
          mn({ species: 'Gamma', level: 30, maxHp: 400, spd: 70, traded: true,
            baseSpd: 0, moves: [fx('thump', 10, 0), fx('chop', 10, 0)] })] },
      ],
      b: [{ playerId: 'w', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 900, spd: 30, baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 2; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('w', { action: 'fight', move: 0, target: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// Never in a link fight, and never for side b: both traded level-100s with no
// badge obey every turn and draw nothing for it.
const obeyNever = (id, mode, aTraded) => (events) => {
  const battle = build({
    id, mode, seed: 6809, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 100, maxHp: 999, spd: 90, traded: aTraded, baseSpd: 0,
          moves: [fx('thump', 10, 0), fx('chop', 10, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 100, maxHp: 999, spd: 30, traded: true, baseSpd: 0,
          moves: [fx('thump', 10, 0), fx('chop', 10, 0)] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
};
scenario('g1_obey_link', obeyNever('g1k', '1v1', true));
scenario('g1_obey_side_b', obeyNever('g1b', 'wild', false));

// The flinch-reset skip: a raging monster on the player's seat that a slower
// Stomp flinches keeps the flinch through the next turn's open and loses its
// Rage to it; in a link fight the reset is unconditional.
const rageFlinch = (id, mode) => (events) => {
  const battle = build({
    id, mode, seed: 6303, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('fury', 20, 81)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 30, baseSpd: 0,
          moves: [fx('stomp', 10, 31, { chance: 100 })] })] }],
    },
  });
  drainInto(battle, events);
  for (let turn = 1; turn <= 3; turn += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
    probeFlinch(battle, turn);
  }
  return battle;
};
scenario('g1_flinch_rage', rageFlinch('g1fr', 'wild'));
// ...and in a link fight too: both sides are "the player" by the owner's rule
// (R1b).
scenario('g1_flinch_rage_link', rageFlinch('g1fl', '1v1'));

// A Hyper Beam user that a slower Stomp flinches does not recharge:
// FlinchSideEffect calls ClearHyperBeam on its target (effects.asm :991), so
// at the next open the reset takes the flinch (probe 1) and the beam fires
// again, to be flinched again (probe 2). (Gap 4, closed by R1b; this scenario
// used to pin the referee's kept recharge.)
scenario('g1_flinch_recharge', (events) => {
  const battle = build({
    id: 'g1fh', mode: 'wild', seed: 6303, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('beam', 20, 80)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 30, baseSpd: 0,
          moves: [fx('stomp', 10, 31, { chance: 100 })] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  probeFlinch(battle, 1);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  probeFlinch(battle, 2);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// The Gen 1 review fixes (task FX1); tests/battle_sim_turn.lua section 27
// states the numbers behind each.
//
// A Leech Seed tick that knocks the seeded monster out: the seeder is read
// before the damage, and still healed by the whole 1/16.
scenario('g1_leech_ko', (events) => {
  const battle = build({
    id: 'g1ls', mode: '1v1', seed: 6501, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', hp: 50, maxHp: 100, spd: 90, baseSpd: 0,
          moves: [fx('seed', 0, 84)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', hp: 3, maxHp: 100, spd: 10, baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  return battle;
});

// Rage builds only after an opponent's move lands: the raging monster's own
// poison, the Leech Seed on it and its confusion self-hits build nothing.
scenario('g1_rage_quiet', (events) => {
  const battle = build({
    id: 'g1rq', mode: 'wild', seed: 6509, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 400, atk: 100, def: 80, spd: 90, spc: 50,
          status: 'PSN', confusion: 4, baseSpd: 0, moves: [fx('fury', 20, 81)],
          extra: { raging: true, rageMove: 1, leechSeed: { fromSlot: 3 } } })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 10, baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  for (let turn = 1; turn <= 3; turn += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
    probe(battle, turn);
  }
  return battle;
});

// The hit that knocks the raging monster out builds nothing, so the burned
// attacker is not halved a second time by the re-penalty.
scenario('g1_rage_lethal', (events) => {
  const battle = build({
    id: 'g1rl', mode: 'wild', seed: 6503, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', hp: 20, maxHp: 300, atk: 100, def: 80, spd: 90,
          spc: 50, baseSpd: 0, moves: [fx('fury', 20, 81)] }),
        mn({ species: 'Gamma', maxHp: 300, baseSpd: 0,
          moves: [fx('splash', 0, 85)] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 300, atk: 200, spd: 10, status: 'BRN',
          baseSpd: 0, moves: [fx('thump', 80, 0)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('wild', { action: 'fight', move: 0 });
  drainInto(battle, events);
  probe(battle, 1);
  return battle;
});

// A Substitute that soaks the hit does not stop the build, and a two-hit move
// builds once per hit. A 5-HP doll breaks on the first hit, which ends the
// move: one build, +1. A 12-HP doll (g1_rage_sub_late) breaks on the second:
// both thrown, both build, +2.
const rageSub = (id, seed, doll) => (events) => {
  const battle = build({
    id, mode: '1v1', seed, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('fury', 20, 81)],
          extra: { raging: true, rageMove: 1, substitute: doll } })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 10, baseSpd: 0,
          moves: [fx('kicks', 20, 44)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  probe(battle, 1);
  return battle;
};
scenario('g1_rage_sub', rageSub('g1rs', 6504, 5));
scenario('g1_rage_sub_late', rageSub('g1rsl', 6504, 12));

// The two builds no hit carries: a missed Disable (power 0: the build comes
// before its own hit test) and a missed Explosion (`.notDone`).
scenario('g1_rage_misses', (events) => {
  const blind = (id, power, effect) => Object.assign(fx(id, power, effect), { accuracy: 0 });
  const battle = build({
    id: 'g1rm', mode: '1v1', seed: 6505, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('fury', 20, 81)],
          extra: { raging: true, rageMove: 1, lastMoveIndex: 1 } })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 10, baseSpd: 0,
          moves: [blind('numb', 0, 86), blind('boom', 130, 7)] })] }],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  [0, 1].forEach((move, i) => {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move });
    drainInto(battle, events);
    probe(battle, i + 1);
  });
  return battle;
});

// A trap's later turns are the trapper's own attack, so each tick builds the
// trapped monster's Rage and the re-penalty finds the trapper (slot 4), not
// the battler standing opposite (slot 3).
scenario('g1_rage_trap', (events) => {
  const battle = build({
    id: 'g1rt', mode: 'coop_pvp', seed: 6506, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
            moves: [fx('fury', 20, 81)],
            extra: { raging: true, rageMove: 1 } })] },
        { playerId: 'a2', name: 'Amy', mons: [
          mn({ species: 'Gamma', maxHp: 400, spd: 80, baseSpd: 0,
            moves: [fx('splash', 0, 85)] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 400, atk: 200, spd: 20, status: 'BRN',
            baseSpd: 0, moves: [fx('splash', 0, 85)] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 400, atk: 200, spd: 10, status: 'BRN',
            baseSpd: 0, moves: [fx('wrap', 5, 42)] })] },
      ],
    },
  });
  drainInto(battle, events);
  probe(battle, 0);
  for (let turn = 1; turn <= 4; turn += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 0 });
    for (let step = 1; step <= 3; step += 1) battle.tick(turn * 10 + step);
    drainInto(battle, events);
    probe(battle, turn);
  }
  return battle;
});

// A Bide aimed at field slot 0 is released at slot 0 -- slot 0 is a real seat,
// not "no aim" (this file once read it with `||` and let the spread aim pick).
scenario('g1_bide_slot0', (events) => {
  const battle = build({
    id: 'g1bz', mode: 'coop_pvp', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
            moves: [fx('tap', 10, 0)] })] },
        { playerId: 'a2', name: 'Amy', mons: [
          mn({ species: 'Gamma', maxHp: 400, spd: 80, baseSpd: 0,
            moves: [fx('splash', 0, 85)] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 400, spd: 10, baseSpd: 0,
            moves: [fx('bide', 0, 26)] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 400, spd: 5, baseSpd: 0,
            moves: [fx('splash', 0, 85)] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let turn = 1; turn <= 4; turn += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 0 });
    for (let step = 1; step <= 3; step += 1) battle.tick(turn * 10 + step);
    drainInto(battle, events);
  }
  return battle;
});

// A side-effect drop at -6 says nothing; only a primary prints the line.
scenario('g1_side_min', (events) => {
  const battle = build({
    id: 'g1sm', mode: '1v1', seed: 6507, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
          moves: [fx('bubble', 10, 70, { chance: 100 }), fx('goo', 0, 20)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spd: 10, baseSpd: 0,
          moves: [fx('splash', 0, 85)],
          extra: { stages: { atk: 0, def: 0, spd: -6, spc: 0, acc: 0, eva: 0 } } })] }],
    },
  });
  drainInto(battle, events);
  for (const move of [0, 1]) {
    battle.submitChoice('p1', { action: 'fight', move });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 67-80. Gen 1 side-effect odds (task FX4). Red's move records carry no
// chance, so every Red move reaches the referee at chance 0 and the odds are
// each pokered routine's own constant (Effects.SIDE_THRESHOLD). A g1_odds_*
// scenario fights one turn per seed -- a fast Alpha's side-effect move into a
// slow Beta, chance 0 -- with seeds a scan picked so the routine's byte is
// exactly threshold - 1 (it lands) and then exactly the threshold (it does
// not). `probeSide` pins every battle's draw count (`rng`) and the target's
// condition.

// After each battle's turn: its RNG state, then every standing seat's
// condition, confusion, flinch and the two stages a side-effect drop moves.
function probeSide(battle, at) {
  probes.push({ at, rng: battle.rng.state() });
  for (const fighter of battle.fighters) {
    const mon = fighter.active ? fighter.mons[fighter.active - 1] : null;
    if (mon && mon.hp > 0) {
      probes.push({
        at, slot: fighter.slot, status: mon.status || '',
        confusion: mon.confusion || 0, flinch: mon.flinch === true,
        sSpd: mon.stages.spd, sSpc: mon.stages.spc,
      });
    }
  }
}

// One turn per entry, every battle's events into the one stream: Alpha (p1,
// fast) uses `move`, Beta (p2, slow) splashes. An entry may swap either move
// (`aMove` / `bMove`), the speeds, the mode, the ruleset's `typeIds`, and
// Beta's HP, status, types and raw sheet fields (`bExtra`).
function sideTurns(id, entries) {
  return (events) => {
    let battle = null;
    entries.forEach((e, index) => {
      battle = build({
        id: `${id}${index + 1}`, mode: e.mode || '1v1', seed: e.seed, choiceTimeout: 60,
        reconnectGrace: 60, typeIds: e.typeIds,
        sides: {
          a: [{ playerId: 'p1', name: 'Ann', mons: [
            mn({ species: 'Alpha', maxHp: 400, spd: e.aSpd || 90, types: [1],
              baseSpd: 0, moves: [e.aMove || e.move] })] }],
          b: [{ playerId: 'p2', name: 'Bob', mons: [
            mn({ species: 'Beta', hp: e.bHp, maxHp: 400, spd: e.bSpd || 10,
              baseSpd: 0, types: e.bTypes || [1], status: e.bStatus,
              moves: [e.bMove || fx('splash', 0, 85)], extra: e.bExtra })] }],
        },
      });
      drainInto(battle, events);
      battle.submitChoice('p1', { action: 'fight', move: 0 });
      battle.submitChoice('p2', { action: 'fight', move: 0 });
      drainInto(battle, events);
      probeSide(battle, index + 1);
    });
    return battle;
  };
}

const hit = (effect, o = {}) => fx('hit', 10, effect, { chance: o.chance, type: o.type });

// Each pair: the byte at threshold - 1, then at the threshold. The scan's
// seeds put the routine's byte at the same draw (acc, crit, roll, then the
// side byte), so one seed serves every family whose threshold it straddles.
const odds = (id, effect, below, at) => sideTurns(id, [
  { seed: below, move: hit(effect) }, { seed: at, move: hit(effect) }]);
scenario('g1_odds_poison1', odds('g1op1', 2, 11078, 6227)); // 51 / 52
scenario('g1_odds_poison2', odds('g1op2', 33, 192, 3)); // 102 / 103
scenario('g1_odds_twineedle', odds('g1otw', 77, 11078, 6227)); // 51 / 52
scenario('g1_odds_burn1', odds('g1ob1', 4, 18957, 14106)); // 25 / 26
scenario('g1_odds_freeze1', odds('g1of1', 5, 18957, 14106)); // 25 / 26
scenario('g1_odds_paralyze2', odds('g1op2p', 36, 8071, 3220)); // 76 / 77
scenario('g1_odds_flinch1', odds('g1ofl1', 31, 18957, 14106)); // 25 / 26
scenario('g1_odds_flinch2', odds('g1ofl2', 37, 8071, 3220)); // 76 / 77
scenario('g1_odds_drop', odds('g1odr', 71, 28460, 23588)); // 84 / 85
scenario('g1_odds_confuse', odds('g1ocf', 76, 23829, 18957)); // 24 / 25

// The computer's drop (wild Beta, fast, lowers Alpha's Speed): the extra miss
// byte comes first -- 63 misses and draws nothing more; 64 passes, and the
// side byte 84 then lands. g1_odds_drop is the link fight that never draws it.
scenario('g1_odds_computer_drop', sideTurns('g1ocd', [
  { seed: 12021, mode: 'wild', aSpd: 10, bSpd: 90, aMove: fx('splash', 0, 85), bMove: hit(70) },
  { seed: 9921, mode: 'wild', aSpd: 10, bSpd: 90, aMove: fx('splash', 0, 85), bMove: hit(70) },
]));

// Precedence on one seed (the side byte is 50): chance 0 is the cart's 26 and
// misses; an explicit 20 is floor(20 * 255 / 100) = 51 and lands; 19 is 48 and
// misses. A chance on an effect with no side routine draws nothing -- the last
// two battles end on the same RNG state.
scenario('g1_side_precedence', sideTurns('g1sp', [
  { seed: 15950, move: hit(4) },
  { seed: 15950, move: hit(4, { chance: 20 }) },
  { seed: 15950, move: hit(4, { chance: 19 }) },
  { seed: 15950, move: hit(0, { chance: 100 }) },
  { seed: 15950, move: hit(0) },
]));

// What each routine checks before it draws, on one seed whose side byte is 0
// -- any draw would land -- so a battle that ends on battle 1's RNG state (the
// plain hit) drew nothing (the Lua driver's comment numbers each battle).
const POISON_AXIS = ['NORMAL', 'POISON'];
const FIRE_AXIS = ['NORMAL', 'FIRE'];
const SUB = { substitute: 200 };
const DOLL = { substitute: 1 };
scenario('g1_side_gates', sideTurns('g1sg', [
  { seed: 21964, move: hit(0) },
  { seed: 21964, move: hit(4), bStatus: 'PSN' },
  { seed: 21964, move: hit(4), bTypes: [0] },
  { seed: 21964, move: hit(2), typeIds: POISON_AXIS },
  { seed: 21964, move: hit(2) },
  { seed: 21964, move: hit(4), bExtra: SUB },
  { seed: 21964, move: hit(31), bExtra: SUB },
  { seed: 21964, move: hit(2), bExtra: SUB },
  { seed: 21964, move: hit(71), bExtra: SUB },
  { seed: 21964, move: hit(76), bExtra: SUB },
  { seed: 21964, move: hit(4), bExtra: DOLL },
  { seed: 21964, move: hit(77), bExtra: DOLL },
  { seed: 21964, move: hit(4, { type: 1 }), typeIds: FIRE_AXIS, bStatus: 'FRZ', bTypes: [0] },
  { seed: 21964, move: hit(71), bExtra: { mist: true } },
  { seed: 21964, move: hit(0), bHp: 1 },
  { seed: 21964, move: hit(4), bHp: 1 },
]));

// Multi-hit moves after a broken Substitute: a first-hit break ends the move
// (`.nullifyEffect` zeroed the effect before TwoToFiveAttacksEffect could mark
// it multi-hit); a later break leaves it going, the effect still gone (the Lua
// driver's comment numbers each battle).
const multi = (effect) => fx('multi', 40, effect);
scenario('g1_multi_sub', sideTurns('g1ms', [
  { seed: 29011, move: multi(29) },
  { seed: 29011, move: multi(29), bExtra: { substitute: 5 } },
  { seed: 29011, move: multi(29), bExtra: { substitute: 15 } },
  { seed: 29007, move: multi(44) },
  { seed: 29007, move: multi(44), bExtra: { substitute: 5 } },
  { seed: 29007, move: multi(44), bExtra: { substitute: 15 } },
  { seed: 11078, move: multi(77) },
  { seed: 11078, move: multi(77), bExtra: { substitute: 5 } },
  { seed: 11078, move: multi(77), bExtra: { substitute: 15 } },
  { seed: 11078, move: multi(0) },
  { seed: 29011, move: multi(29), bExtra: { substitute: 9 } },
  { seed: 29007, move: multi(44), bExtra: { substitute: 8 } },
]));

// ------------------------------------------------------------------
// R1a (gen12-referee-gaps-fix): the damage tails, AlwaysHappenSideEffects,
// COUNTER, RAGE / THRASH PP, called multi-turn moves, Leech Seed, Pay Day and
// the self-hit -- each against pokered, one battle per case (the Lua driver's
// comments spell out every battle).
// ------------------------------------------------------------------

// After each turn of a `duels` battle: the RNG state, wDamage (`lastDamage`)
// and the Pay Day pile, then every seat's monster -- standing or not -- with
// the volatiles these rows move. `pp` is the slots' PP, comma-joined.
function probeDuel(battle, at, turn) {
  probes.push({
    at, turn, rng: battle.rng.state(), last: battle.lastDamage,
    payA: battle.payDay.a, payB: battle.payDay.b,
  });
  for (const fighter of battle.fighters) {
    fighter.mons.forEach((mon, i) => {
      probes.push({
        at, turn, slot: fighter.slot, mon: i + 1, hp: mon.hp,
        sub: mon.substitute || 0, zero: mon.subAtZero === true,
        raging: mon.raging === true, recharge: mon.mustRecharge === true,
        charging: !!mon.charging, invuln: mon.invulnerable === true,
        thrash: !!mon.thrashing, bide: !!mon.bide,
        conf: mon.confusion || 0, tox: mon.toxicCounter || 0,
        sAtk: mon.stages.atk, pp: mon.moves.map((m) => String(m.pp)).join(','),
      });
    });
  }
}

// One battle per entry (the Lua driver's `duels`): Ann's Alpha (p1) against
// Bob's Beta (p2), one game turn per `turns` pair, a closing outcome row.
function duels(id, entries) {
  return (events) => {
    let battle = null;
    entries.forEach((e, index) => {
      const at = index + 1;
      battle = build({
        id: `${id}${at}`, mode: e.mode || '1v1', seed: e.seed, choiceTimeout: 60,
        reconnectGrace: 60, typeIds: e.typeIds, chart: e.chart, metronomePool: e.pool,
        sides: {
          a: [{ playerId: 'p1', name: 'Ann', mons: [mn(e.a)] }],
          b: [{ playerId: 'p2', name: 'Bob', mons: [mn(e.b)] }],
        },
      });
      drainInto(battle, events);
      const turns = e.turns || [[0, 0]];
      for (let t = 0; t < turns.length; t += 1) {
        if (battle.outcome()) break;
        const turnNo = battle.turn;
        battle.submitChoice('p1', { action: 'fight', move: turns[t][0] });
        if (battle.turn === turnNo) {
          battle.submitChoice('p2', { action: 'fight', move: turns[t][1] });
        }
        if (battle.forcedPending) battle.tick(battle.now);
        drainInto(battle, events);
        probeDuel(battle, at, t + 1);
      }
      const o = battle.outcome();
      if (o) {
        probes.push({
          at, outcome: o.outcome, reason: o.reason,
          winner: o.winners ? o.winners[0] : '', payDay: o.payDay || 0,
        });
      }
    });
    return battle;
  };
}

const SPLASH = fx('splash', 0, 85);
const fast = (moves, extra, o = {}) => ({
  species: 'Alpha', maxHp: 400, hp: o.hp, level: o.level, atk: o.atk, spd: 90, baseSpd: 0,
  types: o.types || [1], moves, status: o.status, confusion: o.confusion,
  toxicCounter: o.toxicCounter, extra,
});
const slow = (moves, extra, o = {}) => ({
  species: 'Beta', maxHp: o.maxHp === undefined ? 400 : o.maxHp, hp: o.hp, def: o.def, spd: 10,
  baseSpd: 0, types: o.types || [1], moves: moves || [SPLASH], status: o.status,
  confusion: o.confusion, toxicCounter: o.toxicCounter, extra,
});

const TAIL_CHART = [[100, 100, 100], [100, 50, 100], [100, 50, 50], [100, 0, 100]];
const TAIL_TYPES = [1, 2];
const tail = (ty) => fx('tap', 10, 0, { type: ty });
const weak = (moves, extra) => ({
  species: 'Alpha', maxHp: 400, level: 2, atk: 5, spd: 90, baseSpd: 0, types: [0], moves, extra,
});
const tailTarget = () => slow(undefined, undefined, { def: 200, types: TAIL_TYPES });
scenario('g1_damage_tails', duels('g1dt', [
  { seed: 7101, chart: TAIL_CHART, a: weak([tail(1)]), b: tailTarget() },
  { seed: 7101, chart: TAIL_CHART, a: weak([tail(2)]), b: tailTarget() },
  { seed: 7101, chart: TAIL_CHART, a: weak([tail(0)]), b: tailTarget() },
  { seed: 7101, chart: TAIL_CHART, a: weak([tail(3)]), b: tailTarget() },
  { seed: 7101, a: fast([fx('thump', 40, 0)]), b: slow(undefined, { substitute: 9 }),
    turns: [[0, 0], [0, 0]] },
]));

const HOLD = { substitute: 200 };
const BREAK = { substitute: 1 };
const hurt = (moves, extra) => fast(moves, extra, { hp: 300 });
const ZERO_PP = [fx('thump', 40, 0, { pp: 0 })];
scenario('g1_always_happen', duels('g1ah', [
  { seed: 7201, a: hurt([fx('leech', 40, 3)]), b: slow(undefined, HOLD) },
  { seed: 7201, a: hurt([fx('leech', 40, 3)]), b: slow(undefined, BREAK) },
  { seed: 7201, a: hurt([fx('ram', 40, 48)]), b: slow(undefined, HOLD) },
  { seed: 7201, a: hurt([fx('ram', 40, 48)]), b: slow(undefined, BREAK) },
  { seed: 7201, a: hurt(ZERO_PP), b: slow(undefined, HOLD) },
  { seed: 7201, a: hurt(ZERO_PP), b: slow(undefined, BREAK) },
  { seed: 7201, a: hurt([fx('beam', 60, 80)]), b: slow(undefined, HOLD), turns: [[0, 0], [0, 0]] },
  { seed: 7201, a: hurt([fx('beam', 60, 80)]), b: slow(undefined, BREAK), turns: [[0, 0], [0, 0]] },
  { seed: 7201, a: hurt([fx('blast', 60, 7)]), b: slow(undefined, HOLD) },
  { seed: 7201, a: hurt([fx('blast', 60, 7)]), b: slow(undefined, BREAK) },
  { seed: 7201, a: hurt([fx('RAGE', 20, 81)]), b: slow(undefined, HOLD) },
  { seed: 7201, a: hurt([fx('RAGE', 20, 81)]), b: slow(undefined, BREAK) },
  { seed: 7201, a: hurt([fx('leech', 40, 3)]),
    b: slow([fx('RAGE', 20, 81)], { raging: true, rageMove: 1 }) },
  { seed: 7201, a: hurt([fx('ram', 40, 48)], { substitute: 30 }), b: slow(undefined, HOLD) },
  { seed: 7201, a: hurt([fx('blast', 60, 7)], { substitute: 30 }), b: slow(undefined, HOLD) },
]));

const payer = (o) => ({
  species: 'Alpha', maxHp: 400, hp: o.hp, level: o.level, spd: 90, baseSpd: 0, types: [1],
  moves: [fx('coin', 80, 16)],
});
const payee = (o) => ({
  species: 'Beta', maxHp: 400, hp: o.hp === undefined ? 40 : o.hp, atk: o.atk, spd: 10,
  baseSpd: 0, types: [1], moves: [fx('coin', o.power === undefined ? 10 : o.power, 16)],
  extra: o.extra,
});
const TWO = [[0, 0], [0, 0], [0, 0], [0, 0]];
scenario('g1_pay_day', duels('g1pd', [
  { seed: 7401, mode: 'wild', a: payer({}), b: payee({}), turns: TWO },
  { seed: 7401, mode: '1v1', a: payer({}), b: payee({}), turns: TWO },
  { seed: 7401, mode: 'wild', a: payer({}), b: payee({ extra: { substitute: 1 } }), turns: TWO },
  { seed: 7401, mode: 'wild', a: payer({ level: 140 }), b: payee({}), turns: TWO },
  { seed: 7401, mode: 'wild', a: payer({ hp: 40 }), b: payee({ hp: 400, atk: 250, power: 120 }),
    turns: TWO },
]));

const CTR = fx('COUNTER', 1, 0, { type: 1 });
const counterer = (extra) => ({
  species: 'Alpha', maxHp: 400, spd: 10, baseSpd: 0, types: [1], moves: [CTR], extra,
});
const striker = (moves, types) => ({
  species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0, types: types || [1], moves,
});
const THUMP = fx('thump', 40, 0);
const GHOST_CHART = [[100, 100, 100], [100, 100, 0], [100, 100, 100]];
const missing = () => Object.assign(fx('thump', 40, 0), { accuracy: 0 });
scenario('g1_counter', duels('g1ct', [
  { seed: 7501, a: counterer(), b: striker([THUMP]) },
  { seed: 7501, a: counterer(), b: striker([fx('flame', 40, 0, { type: 2 })]) },
  { seed: 7501, a: counterer(), b: striker([CTR]) },
  { seed: 7501, a: counterer(), b: striker([missing()]) },
  { seed: 7501, a: counterer({ substitute: 200 }), b: striker([THUMP]) },
  { seed: 7501, chart: GHOST_CHART, a: counterer(), b: striker([THUMP], [2]) },
  { seed: 7501, a: counterer(), b: striker([THUMP, fx('growl', 0, 18)]), turns: [[0, 0], [0, 1]] },
  { seed: 7501, a: counterer(), b: striker([fx('chop', 40, 0, { type: 1 })]) },
  { seed: 7501, typeIds: ['FIRE', 'FIGHTING', 'WATER', 'NORMAL'], a: counterer(),
    b: striker([THUMP]) },
]));

scenario('g1_rage_thrash_pp', duels('g1rp', [
  { seed: 7601, a: fast([fx('RAGE', 20, 81, { pp: 1 })]), b: slow([fx('thump', 10, 0)]),
    turns: [[0, 0], [0, 0], [0, 0]] },
  { seed: 7601, a: fast([fx('THRASH', 30, 27, { pp: 1 })]), b: slow(),
    turns: [[0, 0], [0, 0], [0, 0], [0, 0]] },
  { seed: 7601, a: fast([fx('RAGE', 20, 81)], { raging: true, rageMove: 1, stages: { atk: 6 } }),
    b: slow([fx('thump', 10, 0)]) },
]));

const metro = () => fx('METRONOME', 0, 83);
const FOUR = [[0, 0], [0, 0], [0, 0], [0, 0]];
const poolOf = (m) => [m];
scenario('g1_called_multiturn', duels('g1cm', [
  { seed: 7701, pool: poolOf(fx('FLY', 90, 43)), a: fast([metro()]), b: slow(), turns: FOUR },
  { seed: 7701, pool: poolOf(fx('DIG', 100, 39)), a: fast([metro()]), b: slow(), turns: FOUR },
  { seed: 7701, pool: poolOf(fx('THRASH', 30, 27)), a: fast([metro()]), b: slow(), turns: FOUR },
  { seed: 7701, pool: poolOf(fx('RAGE', 20, 81)), a: fast([metro()]),
    b: slow([fx('thump', 10, 0)]), turns: FOUR },
  { seed: 7701, pool: poolOf(fx('BIDE', 0, 26)), a: fast([metro()]),
    b: slow([fx('thump', 10, 0)]), turns: FOUR },
  { seed: 7701,
    a: { species: 'Alpha', maxHp: 400, spd: 10, baseSpd: 0, types: [1], moves: [fx('MIRROR_MOVE', 0, 9)] },
    b: { species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0, types: [1], moves: [fx('FLY', 90, 43), SPLASH] },
    turns: [[0, 0], [0, 0], [0, 1]] },
]));

const SEEDED = { leechSeed: { fromSlot: 0 } };
const seeder = () => fast([SPLASH], undefined, { hp: 300 });
scenario('g1_leech_toxic', duels('g1lt', [
  { seed: 7801, a: seeder(), b: slow(undefined, SEEDED, { status: 'TOX', toxicCounter: 1 }),
    turns: [[0, 0], [0, 0]] },
  { seed: 7801, a: seeder(), b: slow(undefined, SEEDED, { status: 'PSN', hp: 20 }) },
  { seed: 7801, a: seeder(), b: slow(undefined, SEEDED, { status: 'BRN', hp: 20 }) },
  { seed: 7801, a: seeder(), b: slow(undefined, { leechSeed: { fromSlot: 0 }, substitute: 50 },
    { status: 'PSN' }) },
]));

const dizzy = (extra, moves) => fast(moves || [SPLASH], extra, { confusion: 4 });
scenario('g1_self_hit', duels('g1sh', [
  { seed: 7304, a: dizzy({ substitute: 30 }), b: slow(undefined, { substitute: 10 }) },
  { seed: 7304, a: dizzy({ substitute: 30 }), b: slow(undefined, { substitute: 5 }) },
  { seed: 7304, a: dizzy({ substitute: 30 }), b: slow() },
  { seed: 7304, a: dizzy(undefined), b: slow(undefined, { substitute: 10 }) },
  { seed: 7304, a: dizzy({ charging: { moveIndex: 1, effect: 43, targetSlot: 3, moveId: 'FLY' },
    invulnerable: true }, [fx('FLY', 90, 43)]), b: slow(), turns: [[0, 0], [0, 0]] },
  { seed: 7304, a: dizzy({ thrashing: { turns: 1, moveIndex: 1 } }, [fx('THRASH', 30, 27)]),
    b: slow(), turns: [[0, 0], [0, 0]] },
  { seed: 7304, a: dizzy({ bide: { turns: 0, stored: 30, moveIndex: 1, targetSlot: 3 } },
    [fx('BIDE', 0, 26)]), b: slow(), turns: [[0, 0], [0, 0]] },
]));

// ------------------------------------------------------------------
// R1b (gen12-referee-gaps-fix wave 2): the Lua driver's `fights` scenarios,
// literal for literal (every sheet is written out whole on both sides).
// ------------------------------------------------------------------

// After each row of a `fights` battle: the RNG state and wDamage, then every
// monster of every seat with the state these rows move.
function probeR1b(battle, at, turn) {
  probes.push({ at, turn, rng: battle.rng.state(), last: battle.lastDamage });
  for (const fighter of battle.fighters) {
    fighter.mons.forEach((mon, i) => {
      const st = mon.stages;
      probes.push({
        at, turn, slot: fighter.slot, mon: i + 1,
        hp: mon.hp, maxHp: mon.maxHp, level: mon.level,
        status: mon.status || '', tox: mon.toxicCounter || 0,
        linger: mon.toxicLinger === true, conf: mon.confusion || 0,
        moves: mon.moves.map((m) => `${m.id}:${m.pp}`).join(','),
        types: mon.types.map(String).join(','),
        transformed: mon.transformed === true, recharge: mon.mustRecharge === true,
        invuln: mon.invulnerable === true, charging: !!mon.charging,
        disable: mon.disable ? `${mon.disable.moveIndex}/${mon.disable.turns}` : '',
        used: mon.lastUsedMove ? mon.lastUsedMove.id : '',
        cur: `${mon.cur.atk}/${mon.cur.def}/${mon.cur.spd}/${mon.cur.spc}`,
        party: `${mon.partyStats.atk}/${mon.partyStats.def}/${mon.partyStats.spd}/${mon.partyStats.spc}`,
        stages: `${st.atk}/${st.def}/${st.spd}/${st.spc}/${st.acc}/${st.eva}`,
        flags: (mon.mist ? 'm' : '') + (mon.xAccuracy ? 'x' : '')
          + (mon.focusEnergy ? 'f' : '') + (mon.leechSeed ? 's' : '')
          + (mon.reflect ? 'r' : '') + (mon.lightScreen ? 'l' : ''),
        sub: mon.substitute || 0,
        trapped: mon.trapped ? `${mon.trapped.turns}/${mon.trapped.damage}` : '',
        trapping: mon.trapping ? String(mon.trapping.turns) : '',
        thrash: mon.thrashing ? mon.thrashing.turns : -1,
        bide: mon.bide ? `${mon.bide.turns}/${mon.bide.stored}` : '',
      });
    });
  }
}

// One battle per entry (the Lua driver's `fights`): its seats in field order,
// one row of choices per step (a number is a FIGHT slot), an optional K9
// level-up (`lv`) handed over before the row, `probeR1b` after it, and the
// outcome at the end.
function fights(id, entries) {
  return (events) => {
    let battle = null;
    entries.forEach((e, index) => {
      const at = index + 1;
      const sides = { a: [], b: [] };
      for (const seat of e.seats) {
        sides[seat.side].push({
          playerId: seat.pid, name: seat.pid, mons: seat.mons,
          bag: seat.bag, badges: seat.badges,
        });
      }
      battle = build({
        id: `${id}${at}`, mode: e.mode || '1v1', seed: e.seed, choiceTimeout: 60,
        reconnectGrace: 60, typeIds: e.typeIds, chart: e.chart,
        metronomePool: e.pool, sides,
      });
      drainInto(battle, events);
      e.turns.forEach((row, t) => {
        if (battle.outcome()) return;
        if (row.lv) {
          const lv = row.lv;
          probes.push({ at, turn: t + 1,
            levelUp: battle.levelUp(lv[0], lv[1], lv[2], lv[3], lv[4]) });
          drainInto(battle, events);
        }
        const turnNo = battle.turn;
        const phase = battle.phase;
        for (const seat of e.seats) {
          let c = row[seat.pid];
          if (c !== undefined && c !== null && battle.turn === turnNo && battle.phase === phase) {
            if (typeof c === 'number') c = { action: 'fight', move: c };
            battle.submitChoice(seat.pid, c);
          }
        }
        if (battle.forcedPending) battle.tick(battle.now);
        drainInto(battle, events);
        probeR1b(battle, at, t + 1);
      });
      const o = battle.outcome();
      if (o) {
        probes.push({
          at, outcome: o.outcome, reason: o.reason,
          winner: o.winners ? o.winners[0] : '', payDay: o.payDay || 0,
        });
      }
    });
    return battle;
  };
}

// A move: 60 PP and accuracy 255 unless `o` says otherwise (`o.ppUps` is
// contract K8's).
function r1m(id, power, effect, o = {}) {
  const m = {
    id, pp: o.pp === undefined ? 60 : o.pp, power,
    accuracy: o.accuracy === undefined ? 255 : o.accuracy,
    type: o.type || 0, effect, chance: o.chance || 0,
  };
  if (o.highCrit) m.highCrit = true;
  if (o.ppUps !== undefined) m.ppUps = o.ppUps;
  return m;
}

// A sheet: level 20, 400 HP, 40 across, type 1 and base Speed 0 (no crits)
// unless `o` says otherwise; every other key of `o` is a raw sheet field
// (status, stages, K7's base / dvs, a Substitute, ...).
const R1S_SHORT = new Set(['level', 'maxHp', 'hp', 'atk', 'def', 'spd', 'spc', 'types', 'baseSpd']);
function r1s(species, moves, o = {}) {
  const out = {
    species, level: o.level === undefined ? 20 : o.level, hp: o.hp,
    maxHp: o.maxHp === undefined ? 400 : o.maxHp,
    stats: {
      atk: o.atk === undefined ? 40 : o.atk, def: o.def === undefined ? 40 : o.def,
      spd: o.spd === undefined ? 40 : o.spd, spc: o.spc === undefined ? 40 : o.spc,
    },
    types: o.types || [1], baseSpd: o.baseSpd === undefined ? 0 : o.baseSpd, moves,
  };
  for (const [key, value] of Object.entries(o)) {
    if (!R1S_SHORT.has(key)) out[key] = value;
  }
  return out;
}

// The 1v1 shape of a `fights` entry: Ann (p1) on side a, Bob (p2) on side b,
// `o.aSeat` / `o.bSeat` their bag and badges, the rest of `o` the entry's.
function r1duo(a, b, o) {
  const aSeat = o.aSeat || {};
  const bSeat = o.bSeat || {};
  const e = {
    seats: [
      { pid: 'p1', side: 'a', mons: a, bag: aSeat.bag, badges: aSeat.badges },
      { pid: 'p2', side: 'b', mons: b, bag: bSeat.bag, badges: bSeat.badges },
    ],
  };
  for (const [key, value] of Object.entries(o)) {
    if (key !== 'aSeat' && key !== 'bSeat') e[key] = value;
  }
  return e;
}

// TRANSFORM (transform.asm) and the switch-out that undoes it:
//   1 1v1: Alpha transforms into Beta -- Beta's moves at 5 PP each
//     (`.copyPPLoop`), Beta's types -- then switches out and back in: its
//     own moves (the PP it had), its own types (LoadBattleMonFromParty);
//   2 wild: the wild Beta transforms into Alpha and takes Alpha's K7 base
//     stats, DVs and base Speed with the species byte; Alpha's crits on it
//     read GetEnemyMonStat -- a CalcStat over Alpha's base Defense and DVs at
//     Beta's level 30, no stat exp -- and Beta's own crits Alpha's base Speed;
//   3 the same without K7: the party stats, as before.
scenario('g1_transform_restore', fights('g1tf', [
  r1duo(
    [
      r1s('Alpha', [r1m('morph', 0, 57), r1m('tap', 10, 0)], { spd: 90, types: [1] }),
      r1s('Gamma', [r1m('splash', 0, 85)], { spd: 90 }),
    ],
    [
      r1s('Beta', [r1m('thump', 10, 0, { pp: 12 }), r1m('chop', 10, 0, { pp: 3 })],
        { spd: 10, types: [2] }),
    ],
    {
      seed: 8101,
      turns: [
        { p1: 0, p2: 0 },
        { p1: { action: 'switch', slot: 1 }, p2: 0 },
        { p1: { action: 'switch', slot: 0 }, p2: 0 },
        { p1: 1, p2: 0 },
      ],
    }),
  r1duo(
    [
      r1s('Alpha', [r1m('slash', 70, 0, { highCrit: true })],
        {
          spd: 90,
          baseSpd: 255,
          base: { hp: 60, atk: 80, def: 70, spd: 120, spc: 90 },
          dvs: { atk: 12, def: 9, spd: 15, spc: 6 },
        }),
    ],
    [
      r1s('Beta', [r1m('morph', 0, 57)],
        {
          level: 30,
          spd: 10,
          base: { hp: 48, atk: 48, def: 48, spd: 48, spc: 48 },
          dvs: { atk: 3, def: 4, spd: 5, spc: 6 },
        }),
    ],
    { mode: 'wild', seed: 8102, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('slash', 70, 0, { highCrit: true })], { spd: 90, baseSpd: 255 })],
    [r1s('Beta', [r1m('morph', 0, 57)], { level: 30, spd: 10 })],
    { mode: 'wild', seed: 8102, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
]));

// HazeEffect_ (move_effects/haze.asm): every stage and battle stat reset,
// confusion, X Accuracy, Mist, Focus Energy, Leech Seed, Bad Poison, Reflect,
// Light Screen and Disable gone on both battlers, and the TARGET's status
// cured -- a sleeping or frozen target loses the move it has not used yet
// (CANNOT_MOVE in its selected move):
//   1 1v1: Alpha (badly poisoned, staged, behind Reflect) hazes a sleeping,
//     confused, Misted, pumped, seeded, disabled Beta: Alpha is left plainly
//     poisoned, Beta wakes and does not move;
//   2 1v1: a frozen Beta is thawed and loses its move;
//   3 coop_pvp: all four battlers -- Gamma's confusion and stages, Delta's
//     Bad Poison and seed -- and only Beta, the target, is cured.
scenario('g1_haze_full', fights('g1hz', [
  r1duo(
    [
      r1s('Alpha', [r1m('haze', 0, 25)],
        {
          spd: 90,
          status: 'TOX',
          toxicCounter: 3,
          stages: { atk: 2, def: -1, spd: 0, spc: 0, acc: 1, eva: 0 },
          reflect: true,
          focusEnergy: true,
        }),
    ],
    [
      r1s('Beta', [r1m('thump', 10, 0)],
        {
          spd: 10,
          status: 'SLP',
          statusTurns: 5,
          confusion: 4,
          mist: true,
          focusEnergy: true,
          xAccuracy: true,
          leechSeed: { fromSlot: 0 },
          disable: { moveIndex: 1, turns: 4 },
          stages: { atk: -2, def: 3, spd: 0, spc: 0, acc: 0, eva: 2 },
        }),
    ],
    { seed: 8201, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('haze', 0, 25)], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10, status: 'FRZ' })],
    { seed: 8202, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  {
    mode: 'coop_pvp',
    seed: 8203,
    seats: [
      { pid: 'a1', side: 'a', mons: [r1s('Alpha', [r1m('haze', 0, 25)], { spd: 90 })] },
      {
        pid: 'a2',
        side: 'a',
        mons: [
          r1s('Gamma', [r1m('splash', 0, 85)],
            {
              spd: 80,
              confusion: 3,
              stages: { atk: 0, def: 0, spd: 4, spc: 0, acc: 0, eva: 0 },
            }),
        ],
      },
      {
        pid: 'b1',
        side: 'b',
        mons: [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10, status: 'PAR', mist: true })],
      },
      {
        pid: 'b2',
        side: 'b',
        mons: [
          r1s('Delta', [r1m('splash', 0, 85)],
            {
              spd: 5,
              status: 'TOX',
              toxicCounter: 2,
              leechSeed: { fromSlot: 0 },
              stages: { atk: -3, def: 0, spd: 0, spc: 0, acc: 0, eva: 0 },
            }),
        ],
      },
    ],
    turns: [
      {
        a1: { action: 'fight', move: 0, target: 3 },
        a2: { action: 'fight', move: 0, target: 3 },
        b1: { action: 'fight', move: 0, target: 0 },
        b2: { action: 'fight', move: 0, target: 0 },
      },
    ],
  },
]));

// StatModifierDownEffect's primary branch (effects.asm :539-716), in its
// order: the computer's extra 25% miss byte (outside a link battle), a
// Substitute, then MoveHitTest -- Mist before its accuracy byte, X Accuracy
// with none -- each "But it failed!", and a stage at -6 "Nothing happened!":
//   1 wild: the wild Beta growls four times (the miss byte every turn);
//   2 1v1: the same growls, no miss byte;
//   3 wild: into Alpha's Mist -- no accuracy byte;
//   4 1v1: Alpha growls at Beta's doll -- no accuracy byte;
//   5 1v1: Alpha at -6 Attack; Alpha (X Accuracy) growls with no byte;
//   6 1v1: a SWORDS DANCE at +6 says "Nothing happened!", and draws nothing.
scenario('g1_stat_drop_primary', fights('g1sd', [
  r1duo(
    [r1s('Alpha', [r1m('splash', 0, 85)], { spd: 10 })],
    [r1s('Beta', [r1m('growl', 0, 18)], { spd: 90 })],
    {
      mode: 'wild',
      seed: 8301,
      turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }],
    }),
  r1duo(
    [r1s('Alpha', [r1m('splash', 0, 85)], { spd: 10 })],
    [r1s('Beta', [r1m('growl', 0, 18)], { spd: 90 })],
    {
      seed: 8301,
      turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }],
    }),
  r1duo(
    [r1s('Alpha', [r1m('splash', 0, 85)], { spd: 10, mist: true })],
    [r1s('Beta', [r1m('growl', 0, 18)], { spd: 90 })],
    { mode: 'wild', seed: 8302, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('growl', 0, 18)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, substitute: 30 })],
    { seed: 8303, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('growl', 0, 18)], { spd: 90, xAccuracy: true })],
    [
      r1s('Beta', [r1m('growl', 0, 18)],
        { spd: 10, stages: { atk: 0, def: 0, spd: 0, spc: 0, acc: 0, eva: 0 } }),
    ],
    { seed: 8304, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [
      r1s('Alpha', [r1m('dance', 0, 50)],
        { spd: 90, stages: { atk: 6, def: 0, spd: 0, spc: 0, acc: 0, eva: 0 } }),
    ],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { seed: 8305, turns: [{ p1: 0, p2: 0 }] }),
]));

// ClearHyperBeam (effects.asm :1181-1191), beyond the flinch
// (g1_flinch_recharge): a freeze on the player's turn (`.freeze1`; the
// computer's `.freeze2` leaves it) and a trap that starts -- before its hit
// test, so even one that misses:
//   1 wild: the wild Beta beams, Alpha (the player) freezes it: no recharge;
//   2 wild: Alpha beams, the wild Beta freezes it: Alpha still recharges;
//   3 1v1: the same, a link fight: both sides are the player, it is cleared;
//   4 wild: Alpha beams, the wild Beta's Wrap misses: no recharge.
scenario('g1_clear_recharge', fights('g1cr', [
  r1duo(
    [r1s('Alpha', [r1m('chill', 10, 35, { chance: 100 })], { spd: 10 })],
    [r1s('Beta', [r1m('beam', 20, 80)], { spd: 90 })],
    { mode: 'wild', seed: 8401, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('beam', 20, 80)], { spd: 90 })],
    [r1s('Beta', [r1m('chill', 10, 35, { chance: 100 })], { spd: 10 })],
    { mode: 'wild', seed: 8401, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('beam', 20, 80)], { spd: 90 })],
    [r1s('Beta', [r1m('chill', 10, 35, { chance: 100 })], { spd: 10 })],
    { seed: 8401, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('beam', 20, 80)], { spd: 90 })],
    [r1s('Beta', [r1m('wrap', 10, 42, { accuracy: 0 })], { spd: 10 })],
    { mode: 'wild', seed: 8402, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
]));

// The computer's item and switch in its own slot of the order
// (MainInBattleLoop -> TrainerAI at `.enemyMovesFirst` / after
// ExecutePlayerMove), a coop_npc trainer on side b:
//   1 a slower Beta's SUPER POTION lands after Alpha's hit;
//   2 a faster Beta switches to Delta before Alpha moves: the hit finds Delta;
//   3 a slower Beta that Alpha knocks out never switches (the AI's turn is
//     gone with it); its send-out follows;
//   4 the same Speed: the tie byte is drawn for the item as for a move.
scenario('g1_computer_turn_slot', fights('g1ct', [
  r1duo(
    [r1s('Alpha', [r1m('tap', 20, 0)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, hp: 100 })],
    {
      mode: 'coop_npc',
      seed: 8501,
      bSeat: { bag: { SUPER_POTION: 1 } },
      turns: [{ p1: 0, p2: { action: 'item', item: 'SUPER_POTION' } }],
    }),
  r1duo(
    [r1s('Alpha', [r1m('tap', 20, 0)], { spd: 10 })],
    [
      r1s('Beta', [r1m('splash', 0, 85)], { spd: 90 }),
      r1s('Delta', [r1m('splash', 0, 85)], { spd: 5 }),
    ],
    { mode: 'coop_npc', seed: 8502, turns: [{ p1: 0, p2: { action: 'switch', slot: 1 } }] }),
  r1duo(
    [r1s('Alpha', [r1m('tap', 200, 0)], { spd: 90, atk: 200 })],
    [
      r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, hp: 5 }),
      r1s('Delta', [r1m('splash', 0, 85)], { spd: 5 }),
    ],
    {
      mode: 'coop_npc',
      seed: 8503,
      turns: [{ p1: 0, p2: { action: 'switch', slot: 1 } }, { p2: { action: 'switch', slot: 1 } }],
    }),
  r1duo(
    [r1s('Alpha', [r1m('tap', 20, 0)], { spd: 40 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 40, hp: 100 })],
    {
      mode: 'coop_npc',
      seed: 8504,
      bSeat: { bag: { SUPER_POTION: 1 } },
      turns: [{ p1: 0, p2: { action: 'item', item: 'SUPER_POTION' } }],
    }),
]));

// Asleep or frozen, the move menu is skipped (MainInBattleLoop :308-311,
// SelectEnemyMove :2946-2948): last turn's selection stands and the bracket
// reads it.  Alpha (slow) taps on turn 1 and is put to sleep; on turn 2 its
// QUICK ATTACK choice still moves in tap's bracket, after Beta.  MIRROR MOVE
// then finds Alpha's used move zeroed by the fast-asleep turn.
scenario('g1_asleep_selection', fights('g1as', [
  r1duo(
    [r1s('Alpha', [r1m('tap', 10, 0), r1m('QUICK_ATTACK', 10, 0)], { spd: 10 })],
    [
      r1s('Beta', [r1m('lull', 0, 32), r1m('thump', 10, 0), r1m('MIRROR_MOVE', 0, 9)],
        { spd: 90 }),
    ],
    { seed: 8601, turns: [{ p1: 0, p2: 0 }, { p1: 1, p2: 1 }, { p1: 1, p2: 2 }] }),
]));

// AnyMoveToSelect (core.asm :2713-2753) with a move disabled ORs the other
// slots' raw PP bytes: a 0-PP move with no PP Ups leaves nothing -- STRUGGLE
// -- even with the disabled move's PP full.
scenario('g1_struggle_disabled', fights('g1sg', [
  r1duo(
    [
      r1s('Alpha', [r1m('tap', 10, 0, { pp: 0 }), r1m('chop', 10, 0, { pp: 10 })],
        { spd: 90, disable: { moveIndex: 2, turns: 5 } }),
    ],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { seed: 8701, turns: [{ p1: 0, p2: 0 }, { p1: 1, p2: 0 }] }),
]));

// DisableEffect (effects.asm :1286-1367): its MoveHitTest, then a random
// slot (`BattleRandom & 3`, redrawn until it holds a move -- and, when the
// target is the player's, has a raw PP byte: PP Ups count), for 1..8 steps
// of `.AnyMoveDisabledCheck`, each in the disabled monster's own turn:
//   1 1v1: Beta's THUMP / CHOP / SLAM, disabled and worn off over six turns;
//   2 1v1: a 0-PP move with PP Ups is pickable, a bare 0-PP one never is;
//   3 wild: the player disables the wild Beta, whose PP is never read;
//   4 1v1: accuracy 0 -- "But it failed!"; a doll does not stop it.
scenario('g1_disable', fights('g1ds', [
  r1duo(
    [r1s('Alpha', [r1m('lock', 0, 86), r1m('splash', 0, 85)], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0), r1m('chop', 10, 0), r1m('slam', 10, 0)], { spd: 10 })],
    {
      seed: 8801,
      turns: [
        { p1: 0, p2: 0 },
        { p1: 1, p2: 0 },
        { p1: 1, p2: 0 },
        { p1: 1, p2: 0 },
        { p1: 1, p2: 0 },
        { p1: 1, p2: 0 },
      ],
    }),
  r1duo(
    [r1s('Alpha', [r1m('lock', 0, 86)], { spd: 90 })],
    [
      r1s(
        'Beta',
        [
          r1m('thump', 10, 0, { pp: 0, ppUps: 2 }),
          r1m('chop', 10, 0, { pp: 0 }),
          r1m('slam', 10, 0, { pp: 5 }),
        ],
        { spd: 10 }),
    ],
    { seed: 8802, turns: [{ p1: 0, p2: 2 }] }),
  r1duo(
    [r1s('Alpha', [r1m('lock', 0, 86)], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0, { pp: 0 }), r1m('chop', 10, 0, { pp: 0 })], { spd: 10 })],
    { mode: 'wild', seed: 8803, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('lock', 0, 86, { accuracy: 0 }), r1m('lock', 0, 86)], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10, substitute: 30 })],
    { seed: 8804, turns: [{ p1: 0, p2: 0 }, { p1: 1, p2: 0 }] }),
]));

// PoisonEffect's primary branch (effects.asm :78-162): a doll, a status or a
// Poison type turn it away before its MoveHitTest ("It didn't affect"), and
// TOXIC -- the move, by its id -- badly poisons:
//   1 a Poison-type Beta (typeIds names index 1): no byte drawn;
//   2 a Normal-type Beta: poisoned;
//   3 TOXIC: badly poisoned, the counter climbing;
//   4 a doll: turned away.
scenario('g1_poison_primary', fights('g1pp', [
  r1duo(
    [r1s('Alpha', [r1m('powder', 0, 66)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, types: [1] })],
    { seed: 8901, typeIds: ['NORMAL', 'POISON'], turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('powder', 0, 66)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, types: [0] })],
    { seed: 8901, typeIds: ['NORMAL', 'POISON'], turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('TOXIC', 0, 66)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, types: [0] })],
    {
      seed: 8902,
      typeIds: ['NORMAL', 'POISON'],
      turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }],
    }),
  r1duo(
    [r1s('Alpha', [r1m('powder', 0, 66)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, types: [0], substitute: 30 })],
    { seed: 8903, typeIds: ['NORMAL', 'POISON'], turns: [{ p1: 0, p2: 0 }] }),
]));

// "Hit the enemy N times!" (_MultiHitText, the player's) and "Hit N
// times!" (_HitXTimesText, the computer's), with the drawn count, once the
// hits run out with the target standing; a knockout returns before it:
//   1 1v1: Alpha's DOUBLE KICK;
//   2 wild: the wild Beta's;
//   3 1v1: a two-to-five move that knocks Beta out says nothing;
//   4 1v1: a power-0 two-to-five move still hits (CalculateDamage's 2).
scenario('g1_multihit_lines', fights('g1mh', [
  r1duo(
    [r1s('Alpha', [r1m('kicks', 20, 44)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { seed: 9001, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('splash', 0, 85)], { spd: 10 })],
    [r1s('Beta', [r1m('kicks', 20, 44)], { spd: 90 })],
    { mode: 'wild', seed: 9001, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('pelt', 40, 29)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, hp: 12 })],
    { seed: 9002, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('pelt', 0, 29)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { seed: 9003, turns: [{ p1: 0, p2: 0 }] }),
]));

// Contract K9, the rebuild experience.asm makes after a level-up in battle:
//   1 wild: the fielded Alpha (burned, at +1 Attack, every badge) grows to
//     level 21 with stated stats and max HP: the party stats, the HP step,
//     then CalculateModifiedStats, the burn and the badges; the benched
//     Gamma grows from its K7 sheet alone (no stats stated); a claim with a
//     stat that went down, a level that did not go up, and side b's are
//     refused;
//   2 1v1: a link fight earns no experience -- refused.
scenario('g1_level_up', fights('g1lu', [
  r1duo(
    [
      r1s('Alpha', [r1m('tap', 10, 0)],
        {
          spd: 90,
          atk: 60,
          spc: 55,
          maxHp: 60,
          hp: 30,
          status: 'BRN',
          stages: { atk: 1, def: 0, spd: 0, spc: 0, acc: 0, eva: 0 },
          def: 50,
        }),
      r1s('Gamma', [r1m('splash', 0, 85)],
        {
          level: 15,
          atk: 22,
          spd: 22,
          spc: 28,
          maxHp: 38,
          base: { hp: 45, atk: 49, def: 49, spd: 45, spc: 65 },
          dvs: { atk: 10, def: 8, spd: 12, spc: 14 },
          def: 22,
        }),
    ],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    {
      mode: 'wild',
      seed: 9101,
      aSeat: {
        badges: { BOULDERBADGE: true, THUNDERBADGE: true, SOULBADGE: true, VOLCANOBADGE: true },
      },
      turns: [
        { p1: 0, p2: 0, lv: ['p1', 1, 21, { atk: 63, def: 52, spd: 94, spc: 57 }, 63] },
        { p1: 0, p2: 0, lv: ['p1', 2, 16, null, null] },
        { p1: 0, p2: 0, lv: ['p1', 1, 22, { atk: 62, def: 53, spd: 95, spc: 58 }, 64] },
        { p1: 0, p2: 0, lv: ['p1', 1, 21, { atk: 64, def: 53, spd: 95, spc: 58 }, 64] },
        { p1: 0, p2: 0, lv: ['p2', 1, 21, { atk: 41, def: 41, spd: 41, spc: 41 }, 401] },
      ],
    }),
  r1duo(
    [r1s('Alpha', [r1m('tap', 10, 0)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    {
      seed: 9102,
      turns: [{ p1: 0, p2: 0, lv: ['p1', 1, 21, { atk: 42, def: 42, spd: 92, spc: 42 }, 402] }],
    }),
]));

// JUMP KICK's crash is 1 HP (PrintMoveFailureText: wDamage is 0 by then) and
// goes the self-hit's way past the crasher's own doll to the opposing one;
// SetDamageEffects draw no crit, no roll and ignore the chart, and
// `.specialDamage` reads the move id:
//   1 a missed JUMP KICK: 1 HP;  2 behind its own doll: Beta's doll takes it;
//   3 into a Ghost (chart 0): "doesn't affect", then the crash;
//   4 SEISMIC TOSS (level 30) and SONICBOOM into a Ghost: 30, then 20;
//   5 DRAGON RAGE, then SUPER FANG: 40, then half what is left;
//   6 PSYWAVE (level 30): BattleRandom until it is in 1..44.
scenario('g1_crash_and_set_damage', fights('g1cs', [
  r1duo(
    [r1s('Alpha', [r1m('leap', 70, 45, { accuracy: 0 })], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { seed: 9201, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('leap', 70, 45, { accuracy: 0 })], { spd: 90, substitute: 40 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, substitute: 10 })],
    { seed: 9201, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('leap', 70, 45, { type: 1 })], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, types: [2] })],
    {
      seed: 9202,
      chart: [[100, 100, 100], [100, 100, 0], [100, 100, 100]],
      turns: [{ p1: 0, p2: 0 }],
    }),
  r1duo(
    [
      r1s('Alpha', [r1m('SEISMIC_TOSS', 1, 41, { type: 1 }), r1m('SONICBOOM', 1, 41)],
        { level: 30, spd: 90 }),
    ],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10, types: [2] })],
    {
      seed: 9203,
      chart: [[100, 100, 0], [100, 100, 0], [100, 100, 100]],
      turns: [{ p1: 0, p2: 0 }, { p1: 1, p2: 0 }],
    }),
  r1duo(
    [r1s('Alpha', [r1m('DRAGON_RAGE', 1, 41), r1m('fang', 1, 40)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { seed: 9204, turns: [{ p1: 0, p2: 0 }, { p1: 1, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('PSYWAVE', 1, 41)], { level: 30, spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { seed: 9205, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
]));

// OneHitKOEffect_ fails only on a SLOWER user (`jr c`): a Speed tie lands;
// a full paralysis (`.MonHurtItselfOrFullyParalysed`) drops a charge but not
// INVULNERABLE:
//   1 1v1, both at Speed 40: the OHKO lands;
//   2 a paralysed Alpha in the air with FLY is fully paralysed on the release
//     turn (seed 9309): no charge, still invulnerable -- Beta's thump fails --
//     and turn 2 is Alpha's own choice, a fresh FLY.
scenario('g1_ohko_paralysis', fights('g1op', [
  r1duo(
    [r1s('Alpha', [r1m('drill', 1, 38)], { spd: 40 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 40 })],
    { seed: 9301, turns: [{ p1: 0, p2: 0 }] }),
  r1duo(
    [
      r1s('Alpha', [r1m('FLY', 90, 43)],
        {
          spd: 90,
          status: 'PAR',
          charging: { moveIndex: 1, effect: 43, targetSlot: 3, moveId: 'FLY' },
          invulnerable: true,
        }),
    ],
    [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10 })],
    { seed: 9309, turns: [{ p2: 0 }, { p1: 0, p2: 0 }] }),
]));

// TrappingEffect runs before the hit (SpecialEffectsCont): only MoveHitTest's
// miss takes it back -- a doll that holds keeps the trap, an immunity leaves
// it at 0 a turn -- and its counter is the two-to-five odds:
//   1 Wrap into a 50-HP doll that holds: Beta held;
//   2 Wrap, accuracy 0: no trap;
//   3 Wrap into a Ghost (chart 0): "doesn't affect", Beta held at 0;
//   4 Wrap breaking a 3-HP doll: Beta held all the same.
scenario('g1_trap_start', fights('g1ts', [
  r1duo(
    [r1s('Alpha', [r1m('wrap', 15, 42)], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10, substitute: 50 })],
    { seed: 9401, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('wrap', 15, 42, { accuracy: 0 })], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10 })],
    { seed: 9402, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('wrap', 15, 42)], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10, types: [2] })],
    {
      seed: 9403,
      chart: [[100, 100, 0], [100, 100, 100], [100, 100, 100]],
      turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }, { p1: 0, p2: 0 }],
    }),
  r1duo(
    [r1s('Alpha', [r1m('wrap', 15, 42)], { spd: 90 })],
    [r1s('Beta', [r1m('thump', 10, 0)], { spd: 10, substitute: 3 })],
    { seed: 9404, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
]));

// MIRROR MOVE copies wEnemyUsedMove -- the last move the target printed a
// "used" line for: after its METRONOME called THRASH it is THRASH, and
// Alpha, mirroring, thrashes too (a MIRROR MOVE of METRONOME would have
// called again).
scenario('g1_mirror_used', fights('g1mu', [
  r1duo(
    [r1s('Alpha', [r1m('MIRROR_MOVE', 0, 9)], { spd: 10 })],
    [r1s('Beta', [r1m('METRONOME', 0, 83)], { spd: 90 })],
    { seed: 9501, pool: [r1m('THRASH', 30, 27)], turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 0 }] }),
]));

// EndOfBattle pays the Pay Day pile whenever wBattleResult is still 0: an
// escape by TELEPORT / ROAR / WHIRLWIND -- either side's -- pays; the
// player's RUN (TryRunningFromBattle writes 2) does not:
//   1 wild: Alpha's PAY DAY, then the wild Beta teleports away;
//   2 wild: Alpha's PAY DAY, then Alpha teleports;
//   3 wild: Alpha's PAY DAY, then Alpha runs.
scenario('g1_pay_day_escape', fights('g1pe', [
  r1duo(
    [r1s('Alpha', [r1m('coins', 20, 16)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85), r1m('warp', 0, 28)], { spd: 10 })],
    { mode: 'wild', seed: 9601, turns: [{ p1: 0, p2: 0 }, { p1: 0, p2: 1 }] }),
  r1duo(
    [r1s('Alpha', [r1m('coins', 20, 16), r1m('warp', 0, 28)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { mode: 'wild', seed: 9601, turns: [{ p1: 0, p2: 0 }, { p1: 1, p2: 0 }] }),
  r1duo(
    [r1s('Alpha', [r1m('coins', 20, 16)], { spd: 90 })],
    [r1s('Beta', [r1m('splash', 0, 85)], { spd: 10 })],
    { mode: 'wild', seed: 9601, turns: [{ p1: 0, p2: 0 }, { p1: { action: 'run' }, p2: 0 }] }),
]));

// A power-0 move whose routine never calls MoveHitTest draws no accuracy
// byte and is not stopped by FLY: Beta (fast) is up on turns 1 and 3, where
// Alpha's effect-less move goes ahead and its GROWL fails (MoveHitTest's
// INVULNERABLE); SWORDS DANCE and HAZE draw nothing either.
scenario('g1_no_hit_test', fights('g1nh', [
  r1duo(
    [
      r1s(
        'Alpha',
        [r1m('wave', 0, 0), r1m('dance', 0, 50), r1m('haze', 0, 25), r1m('growl', 0, 18)],
        { spd: 10 }),
    ],
    [r1s('Beta', [r1m('FLY', 90, 43)], { spd: 90 })],
    {
      seed: 9701,
      turns: [{ p1: 0, p2: 0 }, { p1: 1, p2: 0 }, { p1: 3, p2: 0 }, { p1: 2, p2: 0 }],
    }),
]));

// ------------------------------------------------------------------
// running both halves
// ------------------------------------------------------------------

// The Lua driver's snapshot digest, rebuilt from this side. `rngState` is the
// load-bearing field: two runtimes that drew a different number of bytes
// disagree here even when every visible event happened to line up.
function snapshotDigest(battle) {
  const snap = battle.snapshot();
  return {
    phase: snap.phase,
    turn: snap.turn,
    seq: snap.seq,
    now: snap.now,
    deadline: snap.deadline,
    rngState: snap.rngState,
    field: snap.field.map((entry) => ({
      slot: entry.slot, hp: entry.hp, party: entry.party,
    })),
  };
}

// Through JSON, so an absent key and a key holding undefined compare the same
// way they do on the Lua side, where both are simply nil.
const canonical = (value) => JSON.parse(JSON.stringify(value));

function slimOutcome(out) {
  if (!out) return null;
  const slim = {
    battle: out.battle,
    outcome: out.outcome,
    reason: out.reason,
  };
  if (out.winners) slim.winners = out.winners;
  if (out.losers) slim.losers = out.losers;
  if (out.caught) {
    slim.caught = {
      species: out.caught.species,
      level: out.caught.level,
      hp: out.caught.hp,
      maxHp: out.caught.maxHp,
    };
  }
  // K11: the Pay Day pile a won fight against the computer reports.
  if (out.payDay) slim.payDay = out.payDay;
  return slim;
}

function runJs() {
  return SCENARIOS.map(({ name, run }) => {
    const events = [];
    batches = [];
    probes = [];
    const battle = run(events);
    return canonical({
      name,
      events,
      batches,
      outcome: slimOutcome(battle.outcome()),
      snapshot: snapshotDigest(battle),
      probes: probes.length > 0 ? probes : undefined,
    });
  });
}

function runLua() {
  const luajit = spawnSync('luajit', [DRIVER, ROOT], { encoding: 'utf8' });
  if (luajit.error || luajit.status !== 0) return null;
  return JSON.parse(luajit.stdout);
}

const jsRuns = runJs();
const luaRuns = runLua();
const fixture = fs.existsSync(FIXTURE)
  ? JSON.parse(fs.readFileSync(FIXTURE, 'utf8'))
  : null;

const byName = (runs) => new Map(runs.map((entry) => [entry.name, entry]));

// ------------------------------------------------------------------

test('the parity scenarios are all present on both sides', () => {
  assert.ok(jsRuns.length >= 21, 'the JS half built every scenario');
  assert.ok(
    luaRuns || fixture,
    'neither luajit nor tests/fixtures/battle_turn_parity.json is available -- '
    + 'install luajit or regenerate the fixture with '
    + '`luajit tests/drivers/battle_turn_parity.lua . > tests/fixtures/battle_turn_parity.json`',
  );
});

test('JS matches the Lua turn machine, event for event', async (t) => {
  if (!luaRuns) {
    t.skip('luajit not on PATH -- the committed fixture carries this instead');
    return;
  }
  const lua = byName(luaRuns);
  for (const run of jsRuns) {
    await t.test(run.name, () => {
      const twin = lua.get(run.name);
      assert.ok(twin, `${run.name}: the Lua driver did not produce this scenario`);

      // Compared one at a time before the whole list, because the first event
      // that differs is the entire bug report -- a deep-equal on 95 events
      // prints all 95 and names none of them.
      const shorter = Math.min(run.events.length, twin.events.length);
      for (let i = 0; i < shorter; i += 1) {
        assert.deepStrictEqual(
          run.events[i], twin.events[i],
          `${run.name}: event #${i + 1} differs`,
        );
      }
      assert.strictEqual(
        run.events.length, twin.events.length,
        `${run.name}: event count differs`,
      );
      assert.deepStrictEqual(
        run.batches, twin.batches,
        `${run.name}: the same events, but not available at the same points`,
      );
      assert.deepStrictEqual(run.outcome, twin.outcome, `${run.name}: outcome differs`);
      assert.deepStrictEqual(
        run.snapshot, twin.snapshot,
        `${run.name}: snapshot digest differs -- an rngState mismatch means the `
        + 'two runtimes drew a different number of bytes',
      );
      assert.deepStrictEqual(
        run.probes, twin.probes,
        `${run.name}: the stored battle stats differ under the same stream`,
      );
    });
  }
});

test('JS matches the committed Lua fixture', async (t) => {
  if (!fixture) {
    t.skip('no committed fixture');
    return;
  }
  const pinned = byName(fixture);
  for (const run of jsRuns) {
    await t.test(run.name, () => {
      const twin = pinned.get(run.name);
      assert.ok(twin, `${run.name}: not in the fixture -- regenerate it`);
      assert.deepStrictEqual(run.events, twin.events, `${run.name}: events differ`);
      assert.deepStrictEqual(run.batches, twin.batches, `${run.name}: drain points differ`);
      assert.deepStrictEqual(run.outcome, twin.outcome, `${run.name}: outcome differs`);
      assert.deepStrictEqual(run.snapshot, twin.snapshot, `${run.name}: snapshot differs`);
      assert.deepStrictEqual(run.probes, twin.probes, `${run.name}: probes differ`);
    });
  }
});

test('the committed fixture still is what luajit produces', (t) => {
  if (!luaRuns || !fixture) {
    t.skip('needs both luajit and the fixture');
    return;
  }
  assert.deepStrictEqual(
    luaRuns, fixture,
    'the fixture has drifted behind src/BattleSim/Turn.lua -- regenerate with '
    + '`luajit tests/drivers/battle_turn_parity.lua . > tests/fixtures/battle_turn_parity.json`',
  );
});

// ------------------------------------------------------------------
// the deterministic KO and the forfeit, stated as claims rather than diffs
// ------------------------------------------------------------------

test('the KO fight ends, and names who won', () => {
  const run = byName(jsRuns).get('ko');
  assert.deepStrictEqual(run.outcome, {
    battle: 'ko', outcome: 'win', reason: 'ko', winners: ['p1'], losers: ['p2'],
  });
  assert.strictEqual(run.snapshot.phase, 'over');
  assert.ok(
    run.events.some((event) => event.t === 'faint'),
    'a KO leaves a faint in the stream',
  );
  assert.strictEqual(
    run.events.filter((event) => event.t === 'over').length, 1,
    'and exactly one over',
  );
});

test('coop_npc RUN refuses without finishing the fight', () => {
  const battle = build({
    id: 'npc-run', mode: 'coop_npc', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, atk: 80, moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  const turnBefore = battle.snapshot().turn;
  const hpBefore = battle.snapshot().field.find((f) => f.playerId === 'p1').hp;
  battle.submitChoice('p1', { action: 'run' });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  const events = battle.drainEvents();
  assert.strictEqual(battle.outcome(), null, 'the gym is not forfeited');
  assert.ok(
    events.some((event) => event.t === 'msg'
      && event.text === "No! There's no running from a trainer battle!"),
    'the trainer refusal is in the turn stream, Wire-safe',
  );
  assert.ok(!events.some((event) => event.t === 'over'), 'with no over event');
  assert.ok(!events.some((event) => event.t === 'run'), 'and no run event');
  assert.strictEqual(battle.snapshot().turn, turnBefore + 1, 'the turn was still spent');
  assert.ok(
    battle.snapshot().field.find((f) => f.playerId === 'p1').hp < hpBefore,
    'so the foe still got its attack',
  );
});

test('mid-turn-KO retargeting: the slower ally swings onto the survivor, not "has no target"', () => {
  const run = byName(jsRuns).get('retarget_ko');
  const events = run.events;

  const koIdx = events.findIndex((event) => event.t === 'faint' && event.text === 'Beta');
  assert.ok(koIdx > -1, "fast's hit really KO'd the aimed-at seat (foeA/Beta)");

  assert.ok(
    !events.some((event) => event.t === 'msg' && event.text && event.text.includes('has no target')),
    "slow's action never fizzles for the dead aim",
  );

  let sawSlowAnim = false;
  let landedOnSlot4 = false;
  for (let i = koIdx + 1; i < events.length; i += 1) {
    const event = events[i];
    if (event.t === 'anim' && event.side === 'a' && event.slot === 1) sawSlowAnim = true;
    if (sawSlowAnim && event.t === 'damage' && event.side === 'b' && event.slot === 4) {
      landedOnSlot4 = true;
      break;
    }
  }
  assert.ok(sawSlowAnim, "slow's move still plays its anim after the mid-turn KO");
  assert.ok(landedOnSlot4, 'slow’s attack lands as real damage on foeB (slot 4), the retargeted seat');

  assert.strictEqual(run.snapshot.field.find((f) => f.slot === 3).hp, 0,
    'foeA (the original, now-dead aim) stayed at 0 hp');
  assert.ok(run.snapshot.field.find((f) => f.slot === 4).hp < 200,
    'foeB (the retargeted seat) actually took the hit');
});

test('a coop_npc trainer spreads its aim across both players, not seat 0 every turn', () => {
  const run = byName(jsRuns).get('coop_npc_aim');
  const hits = run.events
    .filter((event) => event.t === 'damage' && event.side === 'a')
    .map((event) => event.slot);

  assert.strictEqual(hits.length, 12, 'two npc seats swung once each for six turns');
  assert.ok(hits.includes(0), 'the first player was attacked');
  assert.ok(hits.includes(1),
    'and so was the second -- the bug this pins is that slot 1 was never once hit');

  // Not merely "both appear": a rota would also satisfy that. The aim is drawn
  // per action, so the two seats of a single turn are free to agree or differ.
  const turns = [];
  for (let i = 0; i < hits.length; i += 2) turns.push([hits[i], hits[i + 1]]);
  assert.ok(turns.some(([x, y]) => x === y), 'some turns both npcs gang up on one player');
  assert.ok(turns.some(([x, y]) => x !== y), 'and on others they split -- it is a draw, not a rota');

  // The load-bearing half, asserted directly rather than inferred: an aim draw
  // must not spend a byte of the battle's own generator. One that did would
  // move every roll after it and silently rewrite the whole vector pack next
  // door -- a regression with no symptom a player could describe.
  const probe = build({
    id: 'probe', mode: 'coop_npc', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'p1', name: 'One', mons: [
          mn({ species: 'Alpha', maxHp: 400, spd: 10, moves: [mv('tap', 40, 255, 0)] })] },
        { playerId: 'p2', name: 'Two', mons: [
          mn({ species: 'Gamma', maxHp: 400, spd: 10, moves: [mv('tap', 40, 255, 0)] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', mons: [
          mn({ species: 'Beta', maxHp: 400, spd: 90, moves: [mv('thump', 40, 255, 0)] })] },
        { playerId: 'n2', name: 'NpcB', mons: [
          mn({ species: 'Delta', maxHp: 400, spd: 80, moves: [mv('thump', 40, 255, 0)] })] },
      ],
    },
  });
  const before = probe.rng.state();
  const npc = probe.byId.get ? probe.byId.get('n1') : probe.byId.n1;
  const aims = new Set();
  for (let i = 0; i < 32; i += 1) aims.add(probe._autoTarget(npc).slot);
  assert.strictEqual(probe.rng.state(), before,
    'thirty-two aim draws later, the battle RNG has not moved');
  assert.deepStrictEqual([...aims].sort(), [0, 1],
    'and those draws did reach both player seats');
});

test('every sentence about a move prints its name, and falls back to the id', () => {
  const run = byName(jsRuns).get('move_names');
  const said = run.events.filter((event) => event.t === 'msg').map((event) => event.text);

  // The line the whole field exists for. Before PROTOCOL 26 this read
  // "Alpha used slow_swipe" -- the id, in the one place a player reads the
  // fight.
  assert.ok(said.includes('Alpha used SLOW SWIPE'), 'an attack prints the display name');

  // Every other sentence that names a move, all three of them, because they
  // are separate call sites and each one used to spell the id. (Disable
  // wearing off names the monster -- the cart's DisabledNoMoreText, R1b.)
  assert.ok(said.includes('THUMP HIT was disabled'), 'Disable landing names the move');
  assert.ok(said.includes('THUMP HIT is disabled'), 'and so does the refusal it causes');
  assert.ok(said.includes("Beta's disabled no more!"), 'and it wearing off names the monster');
  assert.ok(said.includes('Alpha learned THUMP HIT'), 'Mimic names what it copied');
  assert.ok(said.includes('Alpha used THUMP HIT'),
    'and the copy keeps the name -- a copy that dropped it would revert to the '
    + 'slug on every turn afterwards');

  // The fallback is not a defensive branch: a protocol-25 client uploads moves
  // with no name at all, and half the fights on a mixed hub narrate under this.
  assert.ok(said.includes('Beta used nudge'), 'a move with no name is narrated under its id');

  // The id has to keep travelling on `anim` regardless -- that is what a client
  // looks the move animation and the move-menu label up by, and a referee that
  // started sending the display name there would break art rather than text.
  const anims = run.events.filter((event) => event.t === 'anim').map((event) => event.text);
  assert.ok(anims.includes('slow_swipe'), 'the anim row still carries the registry id');
  assert.ok(!anims.includes('SLOW SWIPE'), 'and never the display name');
});

test('a wild-mode faint pays exactly one exp event, after the faint and before over', () => {
  const run = byName(jsRuns).get('wild_ko');
  const kinds = run.events.map((event) => event.t);
  const expIdx = kinds.indexOf('exp');
  assert.ok(expIdx > -1, 'the fight paid an exp event');
  assert.strictEqual(kinds.filter((t) => t === 'exp').length, 1, 'exactly one -- one owner-slot winner');
  assert.ok(kinds.indexOf('faint') > -1 && kinds.indexOf('faint') < expIdx,
    'the faint precedes the exp event -- the sheet is still in hand when it is paid');
  assert.ok(kinds.indexOf('over') > expIdx, 'and the exp event precedes over');
  const exp = run.events.find((event) => event.t === 'exp');
  assert.strictEqual(exp.slot, 0, 'paid to the sole owner seat, field slot 0');
  assert.strictEqual(exp.species, 'Beta', 'naming the wild mon that fell');
  assert.strictEqual(exp.level, 20, 'and its level');
  assert.strictEqual(exp.participants, 1, 'split one way -- one standing winner');
});

test('a coop_wild 2v1 faint pays both owner seats, slot 0 then slot 1', () => {
  const run = byName(jsRuns).get('coop_wild_ko');
  const exps = run.events.filter((event) => event.t === 'exp');
  assert.strictEqual(exps.length, 2, 'one event per standing owner-slot winner');
  assert.deepStrictEqual(exps.map((event) => event.slot), [0, 1],
    'field-slot order -- a1 (slot 0) before a2 (slot 1)');
  for (const exp of exps) {
    assert.strictEqual(exp.species, 'Beta');
    assert.strictEqual(exp.level, 20);
    assert.strictEqual(exp.participants, 2, 'both winners were standing, so the split is two ways');
  }
});

test('a switch-out-alive participant is paid alongside its replacement, mon 0 then mon 1', () => {
  const run = byName(jsRuns).get('participation_ko');
  const exps = run.events.filter((event) => event.t === 'exp');
  assert.strictEqual(exps.length, 2, 'both the fighter and its replacement are paid');
  assert.deepStrictEqual(exps.map((event) => event.slot), [0, 0],
    'both events sit on the one seat that owns them');
  assert.deepStrictEqual(exps.map((event) => event.mon), [0, 1],
    'party index 0 (Alpha, switched out alive) then 1 (Gamma, the replacement)');
  for (const exp of exps) {
    assert.strictEqual(exp.species, 'Beta');
    assert.strictEqual(exp.participants, 2, 'the divisor counts both participants');
  }
});

test('a self-KO is neither paid nor counted -- the exploder drops out before the divisor is taken', () => {
  const run = byName(jsRuns).get('explode_double_ko');
  const kinds = run.events.map((event) => event.t);
  // Both faints land -- the wild mon's, then a1's own -- before the one exp
  // event the knockout funds, and that event is the only one this action pays.
  const faintIdx = [];
  kinds.forEach((t, i) => { if (t === 'faint') faintIdx.push(i); });
  assert.strictEqual(faintIdx.length, 2,
    "both the wild mon and the self-KO'er faint in this action");
  const expIdx = kinds.indexOf('exp');
  assert.ok(expIdx > faintIdx[1], 'the exp event comes after BOTH faints');
  assert.strictEqual(kinds.filter((t) => t === 'exp').length, 1,
    'exactly one exp event -- the exploder funds nothing of its own');
  const exp = run.events.find((event) => event.t === 'exp');
  assert.strictEqual(exp.slot, 1, "paid to a2's seat, not a1's");
  assert.strictEqual(exp.mon, 0, "a2's own party index");
  assert.strictEqual(exp.participants, 1,
    'divisor 1 -- a1 is dropped from the set, not merely unpaid');
});

test('the replacement mark: a switch-out survivor and its send-out both bank a KO against a new foe', () => {
  const run = byName(jsRuns).get('replacement_mark');
  const allExp = run.events.filter((event) => event.t === 'exp');
  // b1's own knockout pays one event (only a1 was ever in against it), and
  // b2's -- the one this test is about -- pays two.
  assert.strictEqual(allExp.length, 3, 'one event for b1, two for b2');
  assert.strictEqual(allExp[0].participants, 1, "b1's knockout: a1 alone, divisor 1");

  const exps = allExp.slice(1);
  assert.strictEqual(exps.length, 2, 'both a1 (standing when b1 fell) and a2 (the send-out) are paid');
  assert.deepStrictEqual(exps.map((event) => event.slot), [0, 0],
    'both events sit on the one seat that owns them');
  assert.deepStrictEqual(exps.map((event) => event.mon), [0, 1],
    'party index 0 (Alpha, standing at the first KO) then 1 (Gamma, the send-out)');
  for (const exp of exps) {
    assert.strictEqual(exp.participants, 2,
      'the deferred mark carried onto the SECOND foe -- divisor 2, not 1');
  }
});

test('1v1 and coop_pvp never emit exp -- the farming-loop gate', () => {
  const ko = byName(jsRuns).get('ko');
  assert.ok(ko.events.some((event) => event.t === 'faint'), 'ko: a faint really happened');
  for (const name of ['ko', 'coop']) {
    const run = byName(jsRuns).get(name);
    assert.ok(!run.events.some((event) => event.t === 'exp'),
      `${name}: a PvP-shaped mode must never pay exp -- that is a farming loop`);
  }
});

test('a side that drops past its grace forfeits, and rolls nothing doing it', () => {
  const run = byName(jsRuns).get('forfeit');
  assert.deepStrictEqual(run.outcome, {
    battle: 'ff', outcome: 'forfeit', reason: 'disconnect',
    winners: ['p1'], losers: ['p2'],
  });
  assert.strictEqual(
    run.snapshot.rngState, 7,
    'the seed is untouched -- a forfeit consults no roll on either runtime',
  );
  // One `team` per seat behind the opening send-outs: `_openTurn` syncs the
  // rosters before it opens the window, and the first sync always publishes.
  assert.deepStrictEqual(
    run.events.map((event) => event.t),
    ['send', 'send', 'team', 'team', 'turn', 'wait', 'over'],
  );
});

// The two fixtures above only pin the tie-break threshold if they really landed
// on either side of it. If a change to the draw order moves what the first byte
// is spent on, these stop being a boundary pair and start being one more pass
// -- so the ordering they were built to show is asserted directly.
test('the tie-break pair really straddles the threshold', () => {
  const runs = byName(jsRuns);
  const firstAttacker = (name) => runs.get(name).events
    .find((event) => event.t === 'anim').side;

  assert.strictEqual(firstAttacker('tie_low'), 'a', 'byte 127 leaves side a first');
  assert.strictEqual(firstAttacker('tie_high'), 'b', 'byte 128 reverses the group');
});

test('residuals tick in field order, not speed order', () => {
  const hurt = byName(jsRuns).get('residual_both').events
    .filter((event) => event.t === 'damage' && event.status)
    .map((event) => event.status);
  assert.deepStrictEqual(
    hurt, ['BRN', 'PSN'],
    "side a's burn ticks before side b's poison even though side b moved first",
  );
});

test('a switch resolves before an item, and neither spends a roll', () => {
  const run = byName(jsRuns).get('switch_item');
  // The two opening `team` rows, and no more: nothing in this run changes a
  // ball state, so the diff in `_syncTeams` publishes nothing on the second
  // window.
  assert.deepStrictEqual(
    run.events.map((event) => event.t),
    ['send', 'send', 'team', 'team', 'turn', 'chose', 'chose',
     'switch', 'send', 'item', 'msg', 'msg', 'turn'],
  );
  // 'restore' is an unknown id: announce + "But it failed", still no RNG draw.
  assert.strictEqual(run.snapshot.rngState, 13, 'the seed is untouched');
});

test('sleep with no counter costs exactly the turn it wakes on', () => {
  const run = byName(jsRuns).get('sleep_default');
  const cleared = run.events.find((event) => event.t === 'status');
  assert.ok(cleared, 'the sleeper woke');
  assert.strictEqual(cleared.text, 'Alpha woke up');
  assert.strictEqual(cleared.status, undefined, 'a status event with no status means cleared');
  assert.ok(
    run.events.findIndex((event) => event.t === 'anim' && event.side === 'a')
      > run.events.indexOf(cleared),
    'and it did not also get to move on the turn it woke',
  );
});

test('a spent move is spent, and an empty one Struggles', () => {
  const used = byName(jsRuns).get('pp').events
    .filter((event) => event.t === 'anim')
    .map((event) => `${event.side}:${event.text}`);
  assert.deepStrictEqual(
    used,
    ['a:last', 'b:STRUGGLE', 'a:spare', 'b:STRUGGLE',
     'a:spare', 'b:STRUGGLE', 'a:spare', 'b:STRUGGLE'],
    'the last PP is spent once; an empty movepool Struggles thereafter',
  );
});

test('autoPick Struggles rather than hanging when the NPC has no move', () => {
  const battle = build({
    id: 'emptymoves', mode: '1v1', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10, moves: [] })] }],
    },
  });
  battle.drainEvents();
  assert.ok(battle.submitChoice('p1', { action: 'fight', move: 0 }), 'the player files');
  assert.ok(battle.autoPick('p2'), 'an empty-moves NPC still files');
  assert.ok(battle.drainEvents().some((event) => event.t === 'anim' && event.text === 'STRUGGLE'),
    'the empty sheet Struggles rather than skipping');
  assert.ok(battle.turn >= 2 || battle.outcome(),
    'the turn closed rather than sitting on an owed NPC');
});

test('timeout sweep Struggles an empty sheet instead of pushing the clock', () => {
  const battle = build({
    id: 'emptymoves-timeout', mode: '1v1', seed: 3, choiceTimeout: 10, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spd: 10, moves: [] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.turn, 1, 'the opening window is turn 1');
  assert.strictEqual(battle.tick(9), false, 'inside the deadline the sweep does nothing');
  assert.strictEqual(battle.tick(11), true, 'past the deadline the sweep files');
  assert.ok(battle.drainEvents().some((event) => event.t === 'anim' && event.text === 'STRUGGLE'),
    'an unanswered empty sheet Struggles rather than pushing the clock');
  assert.ok(battle.turn >= 2 || battle.outcome(),
    'the timeout closed the turn instead of waiting another window');
});

test('a dead wild in the choice window ends the fight on tick', () => {
  const battle = build({
    id: 'deadwild-tick', mode: 'wild', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'WILD', mons: [
        mn({ species: 'Beta', maxHp: 40, spd: 10,
          moves: [mv('nudge', 10, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  const foe = battle.byId.get('p2');
  foe.mons[0].hp = 0;
  foe.active = null;
  assert.strictEqual(battle.tick(0), true, 'one tick notices the empty side');
  const out = battle.outcome();
  assert.ok(out, 'and the fight ends rather than waiting for the wild');
  assert.strictEqual(out.reason, 'ko', 'as a knockout');
});

test('FIGHT with nobody to aim at is a skip that closes a dead wild', () => {
  const battle = build({
    id: 'deadwild-skip', mode: 'wild', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spd: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'WILD', mons: [
        mn({ species: 'Beta', maxHp: 40, spd: 10,
          moves: [mv('nudge', 10, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  const foe = battle.byId.get('p2');
  foe.mons[0].hp = 0;
  foe.active = null;
  assert.ok(battle.submitChoice('p1', { action: 'fight', move: 0 }),
    'FIGHT with nobody to aim at is accepted as a skip');
  assert.ok(battle.outcome(), 'and the skip closes the fight');
});

// ------------------------------------------------------------------
// properties a fixture cannot state
// ------------------------------------------------------------------

test('same seed and same choices replay identically', () => {
  const first = runJs();
  const second = runJs();
  assert.deepStrictEqual(second, first, 'a battle is a pure function of seed plus choices');
});

test('a different seed produces a different fight', () => {
  const play = (seed) => {
    const thump = () => mv('thump', 40, 255, 0);
    const battle = build({
      id: 'seedcheck', mode: '1v1', seed, choiceTimeout: 60, reconnectGrace: 60,
      sides: {
        a: [{ playerId: 'p1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 120, atk: 60, spd: 55, moves: [thump()] })] }],
        b: [{ playerId: 'p2', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 120, atk: 58, spd: 55, moves: [thump()] })] }],
      },
    });
    const events = [];
    drainInto(battle, events);
    for (let i = 0; i < 40; i += 1) {
      if (battle.outcome()) break;
      battle.submitChoice('p1', { action: 'fight', move: 0 });
      battle.submitChoice('p2', { action: 'fight', move: 0 });
      drainInto(battle, events);
    }
    return JSON.stringify(events);
  };
  assert.notStrictEqual(play(4242), play(9001));
});

test('the party the caller handed over is not the party that fights', () => {
  const party = [mn({ species: 'Alpha', maxHp: 200, hp: 200, moves: [mv('thump', 40, 255, 0)] })];
  const battle = build({
    id: 'copy', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: party }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  battle.drainEvents();

  const mine = battle.snapshot().field.find((entry) => entry.playerId === 'p1');
  assert.ok(mine.hp < 200, 'the fight really happened');
  assert.strictEqual(party[0].hp, 200, "the caller's monster kept its HP");
  assert.strictEqual(party[0].moves[0].pp, 60, 'and its PP');
  assert.strictEqual(battle.drainEvents().length, 0, 'a drained buffer comes back empty');
});

// `text` is the token the fight is *narrated* under, and on a real upload that
// token is the player's nickname wherever their monster has one -- so it is the
// one thing on the event the client opposite cannot look anything up by.
// `speciesId` and `level` ride beside it for exactly that seat: without them it
// has no front pic to draw, no number for the level pill, and (on the faint) no
// base rate to price the award with. Both are pass-through -- no formula here
// reads either, and there is no species table to read them against.
test('a send states the registry id and the level, not just the narrated name', () => {
  const battle = build({
    id: 'sid', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [{
        ...mn({ species: 'Nickname', level: 33, moves: [mv('thump', 40, 255, 0)] }),
        speciesId: 'alpha',
      }] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  const sends = new Map();
  for (const event of battle.drainEvents()) {
    if (event.t === 'send') sends.set(event.slot, event);
  }
  assert.ok(sends.has(0) && sends.has(3), 'the opening fields both seats');
  assert.strictEqual(sends.get(0).text, 'Nickname', 'narrated under the uploaded token');
  assert.strictEqual(sends.get(0).speciesId, 'alpha', 'with the registry id beside it');
  assert.strictEqual(sends.get(0).level, 33, 'and the level nothing else on the wire says');
  assert.strictEqual(sends.get(3).speciesId, undefined, 'a sheet with no id produces no field');
  assert.strictEqual(sends.get(3).level, 20, 'though the level is always known');
  assert.ok(Events.check(sends.get(0))[0], "and it is an event Wire's whitelist accepts");
});

test('a send names the condition the occupant walked in with', () => {
  const battle = build({
    id: 'sst', mode: '1v1', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', status: 'PSN', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', status: 'SLP', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  const sends = new Map();
  for (const event of battle.drainEvents()) {
    if (event.t === 'send') sends.set(event.slot, event);
  }
  assert.strictEqual(sends.get(0).status, 'PSN', 'poisoned walk-in is on the send');
  assert.strictEqual(sends.get(3).status, 'SLP', '...and the sleeper on the other seat');
  assert.ok(Events.check(sends.get(0))[0], "still an event Wire's whitelist accepts");
});

test('every event emitted is in the closed vocabulary, with contiguous seq', () => {
  let count = 0;
  for (const run of jsRuns) {
    const perBattle = new Map();
    for (const event of run.events) {
      count += 1;
      assert.ok(Events.KINDS[event.t], `${run.name}: unknown kind ${event.t}`);
      const [fine, why] = Events.check(event);
      assert.ok(fine, `${run.name}: ${event.t} is malformed -- ${why}`);

      const previous = perBattle.get(event.battle);
      if (previous !== undefined) {
        assert.strictEqual(
          event.seq, previous + 1,
          `${run.name}: seq jumped ${previous} -> ${event.seq}; a client reads a gap as lost messages`,
        );
      }
      perBattle.set(event.battle, event.seq);
    }
  }
  assert.ok(count > 100, 'the scenarios produced a real sample of events');
});

test('create refuses what it cannot fight, and says why', () => {
  const refused = (opts) => {
    const { battle, reason } = Turn.attempt(opts);
    assert.strictEqual(battle, null);
    assert.strictEqual(typeof reason, 'string');
    return reason;
  };
  const one = () => [mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })];

  refused(null);
  refused({ sides: { a: [], b: [] } });
  refused({ sides: { a: [{ playerId: 'p1', mons: one() }] } });
  refused({ sides: { a: [{ playerId: 'p1', mons: one() }], b: [{ playerId: 'p1', mons: one() }] } });
  refused({ sides: { a: [{ playerId: 'p1', mons: [] }], b: [{ playerId: 'p2', mons: one() }] } });
  refused({
    mode: '1v1',
    sides: {
      a: [{ playerId: 'p1', mons: one() }, { playerId: 'p3', mons: one() }],
      b: [{ playerId: 'p2', mons: one() }],
    },
  });

  assert.strictEqual(Turn.create(null), null, 'create is the same refusal without the reason');
});

test('what a choice may say', () => {
  const battle = build({
    id: 'choices', mode: '1v1', seed: 17, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0), mv('empty', 40, 255, 0, 0)] }),
        mn({ species: 'Gamma', moves: [mv('thump', 40, 255, 0)] }),
        mn({ species: 'Down', hp: 0, moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();

  const no = (playerId, choice, what) => assert.strictEqual(
    battle.submitChoice(playerId, choice), false, what,
  );

  no('ghost', { action: 'fight', move: 0 }, 'an unknown player is refused');
  no('p1', { action: 'wander' }, 'an action outside the vocabulary is refused');
  no('p1', { action: 'fight' }, 'fight with no move is refused');
  no('p1', { action: 'fight', move: 7 }, 'a move index that names nothing is refused');
  no('p1', { action: 'fight', move: 1 }, 'a move with no PP left is refused');
  no('p1', { action: 'switch', slot: 2 }, 'switching to a fainted monster is refused');
  no('p1', { action: 'switch', slot: 0 }, 'switching to the monster already out is refused');
  no('p1', { action: 'item' }, 'an item choice with no item is refused');
  no('p1', { action: 'item', item: 'POTION', slot: 2 },
    'Potion on a fainted mon is refused');
  no('p1', { action: 'item', item: 'PROTEIN', slot: 2 },
    'Protein on a fainted mon is refused');
  no('p1', { action: 'item', item: 'REVIVE', slot: 0 },
    'Revive on a living mon is refused');
  no('p1', { action: 'fight', move: 0, target: 1 }, 'a target nobody occupies is refused');
  no('p1', { action: 'fight', move: 0, target: 0 }, 'and so is aiming at your own slot');
  no('p1', { action: 'cancel' }, 'cancelling nothing is refused');
  no('p1', { action: 'fight', move: true }, 'a boolean is not a move index');

  assert.strictEqual(
    battle.submitChoice('p1', { action: 'fight', move: 0, target: 3 }), true,
    'a well-formed choice is accepted',
  );
  no('p1', { action: 'fight', move: 0 }, 'a second choice in the same turn is refused');
  assert.strictEqual(
    battle.submitChoice('p1', { action: 'cancel' }), true,
    'but the first one can be taken back',
  );
  assert.strictEqual(
    battle.submitChoice('p1', { action: 'switch', slot: 1 }), true, 'and replaced',
  );

  battle.submitChoice('p2', { action: 'fight', move: 0 });
  const drained = battle.drainEvents();
  assert.strictEqual(drained.filter((event) => event.t === 'switch').length, 1, 'the switch resolved');
  const mine = battle.snapshot().field.find((entry) => entry.playerId === 'p1');
  assert.strictEqual(mine.species, 'Gamma', 'with the new monster out');
});

test('a playerId that is also an Object key is just a playerId', () => {
  const battle = build({
    id: 'proto', mode: '1v1', seed: 1, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: '__proto__', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'constructor', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.submitChoice('toString', { action: 'run' }), false,
    'a name nobody registered is still an unknown player');
  assert.strictEqual(battle.submitChoice('__proto__', { action: 'fight', move: 0 }), true);
  assert.strictEqual(battle.submitChoice('constructor', { action: 'fight', move: 0 }), true);
  assert.strictEqual(battle.snapshot().turn, 2, 'and the turn resolved between them');
});

test('the choice clock is suspended while anybody is away', () => {
  const battle = build({
    id: 'paused', mode: '1v1', seed: 2, choiceTimeout: 10, reconnectGrace: 600,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.snapshot().deadline, 10, 'creating the battle armed the clock');
  battle.disconnect('p2');
  battle.tick(120);
  assert.strictEqual(battle.snapshot().turn, 1, 'the turn did not resolve behind their back');
  assert.strictEqual(battle.outcome(), null, 'and the grace has not run out either');
});

test('a dropped seat cannot file a choice until reconnect()', () => {
  const battle = build({
    id: 'dropped-choice', mode: '1v1', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.disconnect('p1');
  assert.strictEqual(battle.submitChoice('p1', { action: 'fight', move: 0 }), false,
    'a disconnected seat cannot file a choice');
  assert.strictEqual(battle.submitChoice('p2', { action: 'fight', move: 0 }), true,
    'the seat that stayed may still file');
  assert.strictEqual(battle.snapshot().turn, 1,
    'the turn does not resolve on the dropped seat\'s leftover');
  battle.reconnect('p1');
  assert.strictEqual(battle.submitChoice('p1', { action: 'fight', move: 0 }), true,
    'reconnect restores the right to choose');
  assert.strictEqual(battle.snapshot().turn, 2,
    'and the already-filed peer lets the turn complete');
});

test('a leftover choice does not resolve the turn until reconnect()', () => {
  const battle = build({
    id: 'leftover-choice', mode: '1v1', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(battle.submitChoice('p1', { action: 'fight', move: 0 }), true,
    'a connected seat may file before it drops');
  battle.disconnect('p1');
  assert.strictEqual(battle.submitChoice('p2', { action: 'fight', move: 0 }), true,
    'the seat that stayed may still file after the drop');
  assert.strictEqual(battle.snapshot().turn, 1,
    'a leftover choice does not resolve the turn while a seat is away');
  battle.reconnect('p1');
  assert.strictEqual(battle.snapshot().turn, 2,
    'reconnect completes the already-answered turn without a second pick');
});

test('a zero-length grace still expires', () => {
  const battle = build({
    id: 'nograce', mode: '1v1', seed: 2, choiceTimeout: 0, reconnectGrace: 0,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.disconnect('p2');
  assert.strictEqual(battle.tick(0), true, 'a graceEndsAt of 0 is a deadline, not an absence');
  assert.strictEqual(battle.outcome().outcome, 'forfeit');
});

test('a wedged resolve aborts on the wall-clock ceiling', () => {
  const battle = build({
    id: 'stuck', mode: '1v1', seed: 3, choiceTimeout: 60, reconnectGrace: 60,
    resolveTimeout: 30,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  battle.phase = 'resolving';
  battle.resolveDeadline = battle.now - 1;
  assert.strictEqual(battle.tick(battle.now), true, 'a past resolveDeadline is a tick that acted');
  const out = battle.outcome();
  assert.ok(out, 'the ceiling ends the fight');
  assert.strictEqual(out.outcome, 'draw', 'as a draw -- nobody won a stuck resolve');
  assert.strictEqual(out.reason, 'timeout', 'under the existing timeout reason');
  assert.strictEqual(battle.snapshot().phase, 'over');
  assert.strictEqual(battle.snapshot().resolveDeadline, null);
});

// ------------------------------------------------------------------
// wildlife never uses an item, from either end
// ------------------------------------------------------------------
//
// Twin of tests/battle_sim_turn.lua's 12f3. A wild monster has no bag and no
// hands, and its seat is driven from two ends -- the hub auto-picks for it, and
// a submitted choice can arrive addressed to it -- so both are pinned. The wild
// seat is handed a bag on purpose: even a seat that HAS one must never spend
// it, so a hub seeding the wrong kit (which is what `wild` did with
// DEFAULT_NPC_BAG) cannot put a Potion in a wild monster's mouth.

const wildBattle = (mode, id, bBag) => {
  const sideA = [{
    playerId: 'p1', name: 'Ann', bag: { POTION: 1 },
    mons: [mn({ species: 'Alpha', maxHp: 200, spd: 90, moves: [mv('thump', 40, 255, 0)] })],
  }];
  if (mode === 'coop_wild') {
    sideA.push({
      playerId: 'p2', name: 'Pat',
      mons: [mn({ species: 'Gamma', maxHp: 200, spd: 1, moves: [mv('thump', 1, 255, 0)] })],
    });
  }
  return build({
    id, mode, seed: 88010, choiceTimeout: 10, reconnectGrace: 60,
    sides: {
      a: sideA,
      b: [{
        playerId: 'wild', name: 'Wild', bag: bBag,
        mons: [mn({
          species: 'Beta', maxHp: 200, hp: 40, spd: 10, status: 'PSN',
          moves: [mv('thump', 40, 255, 0)],
        })],
      }],
    },
  });
};

for (const mode of ['wild', 'coop_wild']) {
  test(`${mode}: auto-pick never reaches the wild seat's bag`, () => {
    const battle = wildBattle(mode, 'wa', { POTION: 2, FULL_HEAL: 1, X_ATTACK: 1 });
    battle.drainEvents();
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    assert.strictEqual(battle.tick(11), true, "the wild seat's turn resolves");
    const items = battle.drainEvents().filter((event) => event.t === 'item');
    assert.deepStrictEqual(items, [], 'no item event came off the wild seat');
    assert.strictEqual(battle.byId.get('wild').bag.POTION, 2, 'and it spent none of it');
    assert.strictEqual(battle.byId.get('wild').bag.FULL_HEAL, 1, 'cure untouched too');
    assert.strictEqual(battle.byId.get('wild').mons[0].status, 'poison', 'still poisoned');
  });

  test(`${mode}: a submitted item from the wild seat is refused`, () => {
    const battle = wildBattle(mode, 'wb', { POTION: 1 });
    battle.drainEvents();
    assert.strictEqual(
      battle.submitChoice('wild', { action: 'item', item: 'POTION', slot: 0 }), false,
      'wildlife cannot be talked into using an item',
    );
    assert.strictEqual(battle.byId.get('wild').choice, null, 'and files nothing');
    assert.strictEqual(
      battle.submitChoice('p1', { action: 'item', item: 'POTION', slot: 0 }), true,
      'the player on side a still may',
    );
  });
}

// ------------------------------------------------------------------
// badges: against the computer only
// ------------------------------------------------------------------

// Twin of tests/battle_sim_turn.lua's 23, same sheets and seed, so the numbers
// are the same numbers. The cart boosts the player's monster and only outside a
// link battle (pokered's ApplyBadgeStatBoosts, "return if link battle"), so the
// referee keeps an uploaded set on side a of wild / coop_wild / coop_npc and
// drops it in 1v1, coop_pvp and on side b. Three halves: a PvP fight with
// badges is the unbadged fight, damage and turn order alike; the same seats
// against the computer are boosted, so the gate is the mode and not a removal;
// and side b's upload is ignored even there.

const ALL_BADGES = {
  BOULDERBADGE: true, THUNDERBADGE: true, SOULBADGE: true, VOLCANOBADGE: true,
};

// One exchange: Ann (side a) and Bob (side b) each swing once. `a` / `b`
// override the stats and carry each seat's upload; `a.seed` / `a.confusion`
// set up a confused Ann on a chosen seed (the self-hit test below).
const exchange = (mode, a, b) => {
  const thump = (power) => ({
    id: 'thump', pp: 20, power, accuracy: 255, type: 0, effect: 0, chance: 0,
  });
  const ann = {
    species: 'Alpha', level: 20, hp: 200, maxHp: 200,
    stats: { atk: a.atk || 88, def: a.def || 40, spd: a.spd || 40, spc: 40 },
    moves: [thump(50)],
  };
  if (a.confusion) ann.confusion = a.confusion;
  const battle = build({
    id: 'b1', mode, seed: a.seed || 777001, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: a.badges, mons: [ann] }],
      b: [{ playerId: 'p2', name: 'Bob', badges: b.badges, mons: [{
        species: 'Beta', level: 20, hp: 200, maxHp: 200,
        stats: { atk: b.atk || 40, def: 80, spd: b.spd || 40, spc: 40 },
        moves: [thump(b.power || 1)],
      }] }],
    },
  });
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  return canonical(battle.drainEvents());
};
const hitOn = (events, slot) => {
  const hit = events.find((event) => event.t === 'damage' && event.slot === slot);
  return hit ? hit.amount : null;
};
const firstHit = (events) => {
  const hit = events.find((event) => event.t === 'damage');
  return hit ? hit.slot : null;
};

// Damage: BOULDERBADGE on Ann's physical hit. Speed: Ann at 40 against Bob at
// 42, so SOULBADGE (40 -> 45) is exactly what decides who swings first.
const HIT = { badges: { BOULDERBADGE: true } };
const FAST = { badges: { SOULBADGE: true }, spd: 40 };
const FOE = { spd: 42 };

test('the Gen 1 boost is x9/8, held at MAX_STAT_VALUE', () => {
  // Twin of the cap lines in tests/battle_sim_turn.lua's 23: pokered's
  // .applyBoostToStat holds the boosted word at 999 (the engine's port:
  // src/battle/Damage.lua:44-54).
  const { Effects } = require('./lib/battle');
  assert.strictEqual(Effects.MAX_STAT_VALUE, 999, 'the cap is MAX_STAT_VALUE, 999');
  assert.strictEqual(Effects.badgeBoost(64, 'atk', { BOULDERBADGE: true }), 72, 'floor(64 * 9 / 8)');
  assert.strictEqual(Effects.badgeBoost(887, 'atk', { BOULDERBADGE: true }), 997,
    '887 boosts to 997, under the cap');
  assert.strictEqual(Effects.badgeBoost(888, 'atk', { BOULDERBADGE: true }), 999,
    '888 boosts to exactly 999');
  assert.strictEqual(Effects.badgeBoost(950, 'atk', { BOULDERBADGE: true }), 999,
    '950 would boost to 1068 and is held at 999');
});

test('badges count in the three fights against the computer, on side a', () => {
  assert.deepStrictEqual(Object.keys(Turn.BADGE_MODES).sort(),
    ['coop_npc', 'coop_wild', 'wild'], 'and in no other mode');
  assert.strictEqual(Turn.BADGE_SIDE, 'a', "and only on the player's side of them");
});

for (const mode of ['1v1', 'coop_pvp']) {
  test(`${mode}: a link battle ignores every uploaded badge`, () => {
    const bare = exchange(mode, {}, {});
    // 18 since K12 (the damage roll reads the RNG's high bits); 17 before.
    assert.strictEqual(hitOn(bare, 3), 18, 'the unbadged attack lands for 18');
    assert.strictEqual(hitOn(exchange(mode, HIT, {}), 3), 18,
      'BOULDERBADGE does not raise the damage');
    // One seat at a time: both at once would cancel here (each attack is
    // boosted by the same ninth its target's defence is) and prove nothing.
    assert.deepStrictEqual(exchange(mode, { badges: ALL_BADGES }, {}), bare,
      'side a uploading every badge fights the unbadged fight');
    assert.deepStrictEqual(exchange(mode, {}, { badges: ALL_BADGES }), bare,
      'so does side b uploading every badge');
    assert.strictEqual(firstHit(exchange(mode, { spd: 40 }, FOE)), 0,
      'unbadged, Bob (42) outspeeds Ann (40)');
    assert.strictEqual(firstHit(exchange(mode, FAST, FOE)), 0,
      'SOULBADGE does not let Ann overtake him');
  });
}

for (const mode of ['coop_npc', 'wild']) {
  test(`${mode}: side a's badges still boost against the computer`, () => {
    assert.strictEqual(hitOn(exchange(mode, {}, {}), 3), 18, 'unbadged, the same 18');
    // 88 -> floor(88 * 9 / 8) = 99 Attack; BattleSim reaches the same 20
    // (18 / 20 since K12's high-bits damage roll; 17 / 19 before).
    assert.strictEqual(hitOn(exchange(mode, HIT, {}), 3), 20,
      "BOULDERBADGE raises side a's physical damage to 20");
    assert.strictEqual(firstHit(exchange(mode, { spd: 40 }, FOE)), 0,
      'unbadged, the foe (42) still goes first');
    assert.strictEqual(firstHit(exchange(mode, FAST, FOE)), 3,
      'SOULBADGE (40 -> 45) puts side a in front');
  });
}

test("coop_npc: side b's upload is ignored against the computer too", () => {
  // Each of these would have changed the fight had it counted: THUNDERBADGE
  // would cut Ann's hit, BOULDERBADGE would raise Bob's, and SOULBADGE
  // (37 -> 41) would put Bob ahead of Ann's 40.
  const bare = exchange('coop_npc', {}, { power: 30 });
  const hostile = exchange('coop_npc', {}, { badges: ALL_BADGES, power: 30 });
  assert.strictEqual(hitOn(hostile, 3), hitOn(bare, 3), "side b's THUNDERBADGE is ignored");
  assert.strictEqual(hitOn(hostile, 0), hitOn(bare, 0), "side b's BOULDERBADGE is ignored");
  assert.deepStrictEqual(hostile, bare, "side b's upload changes nothing at all");
  assert.strictEqual(firstHit(exchange('coop_npc', {}, { badges: ALL_BADGES, spd: 37 })), 3,
    "side b's SOULBADGE does not overtake side a");
});

test("the confusion self-hit reads side a's badge-boosted stats, in computer fights only", () => {
  // Twin of (d) in tests/battle_sim_turn.lua's 23: pokered's
  // HandleSelfConfusionDamage takes wBattleMon's Attack and Defense, which
  // ApplyBadgeStatBoosts raised, and the engine port's computeDamage(user, user)
  // boosts both ends (src/battle/BattleState.lua:4187). Attack 160 and Defense
  // 9 keep the two boosts from cancelling: 160 -> 180 and 9 -> 10 move the
  // 40-power hit from 144 to 146.
  const selfHit = (events) => {
    let hurt = false;
    for (const event of events) {
      if (event.t === 'msg' && typeof event.text === 'string'
          && event.text.includes('hurt itself')) {
        hurt = true;
      } else if (hurt && event.t === 'damage') {
        return event.amount;
      }
    }
    return null;
  };
  let confusedSeed = null;
  for (let seed = 1; seed <= 200; seed += 1) {
    if (selfHit(exchange('coop_npc', { seed, atk: 160, def: 9, confusion: 3 }, {})) !== null) {
      confusedSeed = seed;
      break;
    }
  }
  assert.ok(confusedSeed !== null, 'found a seed where a confused Ann hits herself');
  const confused = (mode, badges) => selfHit(exchange(mode,
    { seed: confusedSeed, atk: 160, def: 9, confusion: 3, badges }, {}));
  const PAIR = { BOULDERBADGE: true, THUNDERBADGE: true };
  assert.strictEqual(confused('coop_npc'), 144, "coop_npc: unbadged, Ann's self-hit is 144");
  assert.strictEqual(confused('coop_npc', PAIR), 146,
    'coop_npc: BOULDERBADGE + THUNDERBADGE (180 / 10) make it 146');
  assert.strictEqual(confused('coop_npc', { BOULDERBADGE: true }), 162,
    'coop_npc: BOULDERBADGE alone (180 / 9) raises it to 162');
  assert.strictEqual(confused('coop_npc', { THUNDERBADGE: true }), 130,
    'coop_npc: THUNDERBADGE alone (160 / 10) cuts it to 130');
  assert.strictEqual(confused('1v1'), 144, '1v1: the same unbadged 144');
  assert.strictEqual(confused('1v1', PAIR), 144,
    '1v1: the pair reaches no self-hit in a link battle');
});

// ------------------------------------------------------------------
// Gen 1 stored battle stats, stated as claims (twin of tests/battle_sim_turn.lua
// section 25; the arithmetic is worked there beside each assertion)
// ------------------------------------------------------------------

const jsRun = (name) => jsRuns.find((entry) => entry.name === name);
const probeAt = (name, at, slot) => {
  const row = (jsRun(name).probes || []).find((p) => p.at === at && p.slot === slot);
  return row ? `${row.atk}/${row.def}/${row.spd}/${row.spc}` : null;
};
const damagesOn = (name, slot) => jsRun(name).events
  .filter((event) => event.t === 'damage' && event.slot === slot)
  .map((event) => event.amount);
const saidIn = (name, text) => jsRun(name).events
  .some((event) => event.t === 'msg' && event.text === text);

test('the switch-in seed is party -> penalty -> badges, and a raise re-runs every badge', () => {
  assert.strictEqual(probeAt('g1_stack_up', 0, 0), '112/90/67/56', 'x9/8 on all four');
  assert.strictEqual(probeAt('g1_stack_up', 0, 3), '40/40/20/40', 'the foe quartered, never boosted');
  assert.strictEqual(probeAt('g1_stack_up', 1, 0), '225/101/75/63',
    'ATTACK_UP2: 100 x 2 = 200, then every badge again');
  assert.strictEqual(probeAt('g1_stack_up', 1, 3), '40/40/5/40', 're-penalty: 20 quartered to 5');
  assert.strictEqual(probeAt('g1_stack_up', 2, 0), '253/113/84/70',
    'an accuracy raise compounds the badges again');
  assert.strictEqual(probeAt('g1_stack_up', 2, 3), '40/40/1/40', '...and floors the foe at 1');
});

test("the enemy's drops on the player re-run the badges, then re-penalise the target", () => {
  assert.strictEqual(probeAt('g1_stack_down', 0, 0), '56/90/67/56', 'burned seed: 50 -> 56');
  assert.strictEqual(probeAt('g1_stack_down', 1, 0), '37/101/75/63', 'Growl: 66 -> 74 -> 37');
  assert.strictEqual(probeAt('g1_stack_down', 2, 0), '20/113/84/37', 'a side-effect Special drop');
  assert.strictEqual(probeAt('g1_stack_down', 3, 0), '11/127/94/41', 'an accuracy drop');
  const fell = jsRun('g1_stack_down').events.find((event) => event.t === 'stat');
  assert.strictEqual(fell.amount, undefined, 'a stage below 0 rides no (unsigned) amount');
});

test('an X item and Rage are the player\'s raises; the re-penalty finds the foe', () => {
  assert.strictEqual(probeAt('g1_rage_xitem', 1, 0), '126/101/101/63', 'X SPEED: 90 -> 101');
  assert.strictEqual(probeAt('g1_rage_xitem', 1, 3), '20/40/50/40', 'the battler opposite: 40 -> 20');
  assert.strictEqual(probeAt('g1_rage_xitem', 2, 0), '168/113/113/70', 'a Rage build: 150 -> 168');
  assert.strictEqual(probeAt('g1_rage_xitem', 2, 3), '10/40/50/40', 'the attacker: 20 -> 10');
  assert.strictEqual(probeAt('g1_rage_xitem', 3, 0), '225/127/127/78', 'a second build');
});

test('a switch-in and Haze reset the stored stats', () => {
  assert.strictEqual(probeAt('g1_resets', 3, 0), '112/90/67/56', 'back in: party -> badges, stages 0');
  assert.strictEqual(probeAt('g1_resets', 5, 0), '100/80/60/50', 'Haze: the unmodified stats');
  assert.strictEqual(probeAt('g1_resets', 5, 3), '40/40/80/40', "Haze lifts the foe's paralysis");
});

test('the 999 and 1 walls fail, winding the stage back one step', () => {
  const stages = (at, slot) => {
    const row = jsRun('g1_walls').probes.find((p) => p.at === at && p.slot === slot);
    return [row.sAtk, row.sDef];
  };
  assert.strictEqual(probeAt('g1_walls', 1, 0), '999/40/90/40', '500 x 2 = 1000 is stored as 999');
  assert.deepStrictEqual(stages(2, 0), [3, 0], 'a +2 on 999 fails and nets +1');
  assert.deepStrictEqual(stages(3, 3), [0, 0], 'a -1 on a Defense of 1 fails, wound back');
  assert.deepStrictEqual(stages(4, 3), [0, -1], 'a -2 on it nets -1');
  assert.ok(saidIn('g1_walls', 'Nothing happened'), 'and says so');
});

test('a crit reads both party stats; Transform never copies them', () => {
  const [crit] = damagesOn('g1_crit_party', 3);
  assert.ok(crit >= 34 && crit <= 40,
    `the crit is the party 100 vs 100 band 34..40, not the raised 225 into a Reflect (${crit})`);
  const onBob = damagesOn('g1_transform_crit', 3);
  assert.ok(onBob.length > 0 && onBob[0] <= 13,
    'the transformed crit swings with its own 30 Attack, not the copied 200');
});

test('screens double the defence before the 8-bit scaling, and stack with nothing', () => {
  const onAnn = damagesOn('g1_screens', 0);
  assert.ok(onAnn[0] >= 66 && onAnn[0] <= 78, '512 x2 = 1024 wraps to a 0 byte: divides as 1');
  assert.strictEqual(onAnn[1], 20, 'a fixed-damage move is not halved');
  assert.ok(onAnn[2] <= 3, 'after Haze, the unscreened 512 is a 3 at most');
  assert.ok(saidIn('g1_screens', 'But it failed'), 'a second Reflect fails');
  const after = jsRun('g1_screens').probes.find((p) => p.at === 3 && p.slot === 0);
  assert.strictEqual(after.reflect || after.lightScreen, false, 'Haze takes both screens down');
});

test('the 997 cap, the Explosion order and the self-hit\'s borrowed Reflect', () => {
  const [capped] = damagesOn('g1_cap', 0);
  assert.ok(capped >= 850 && capped <= 999, `4200 is held to 999 before the roll (${capped})`);
  const [blast] = damagesOn('g1_explode_order', 0);
  assert.ok(blast >= 44 && blast <= 52, 'the defence halves after the scaling: base 52');
  const selfHits = damagesOn('g1_self_hit_reflect', 0);
  assert.ok(selfHits.length > 0 && selfHits.every((d) => d === 73),
    "160 into the opponent's-Reflect-doubled 9 is 73");
  assert.ok(damagesOn('g1_opposite_reflect', 0).every((d) => d === 73),
    'seat 0 faces the Reflect');
  assert.ok(damagesOn('g1_opposite_reflect', 1).every((d) => d === 144),
    'seat 1 faces a foe with none: 144');
  assert.ok(!saidIn('g1_flinch_reset', 'Alpha flinched'), 'a stale flinch dies at turn open');
});

// The rest are battles of their own: what a cure, a vitamin and a faint do to
// the stored stats.
const g1Battle = (o) => build({
  id: 'g1u', mode: o.mode || 'wild', seed: o.seed || 6201, choiceTimeout: 60, reconnectGrace: 60,
  sides: {
    a: [{ playerId: 'p1', name: 'Ann', badges: o.aBadges, bag: o.aBag, mons: o.a }],
    b: [{ playerId: 'p2', name: 'Bob', bag: o.bBag, mons: o.b }],
  },
});
const g1Mon = (o) => mn({ species: 'Alpha', maxHp: 300, atk: 100, def: 80, spd: 60, spc: 50,
  baseSpd: 0, moves: [fx('splash', 0, 85)], ...o });
const g1Foe = (o) => mn({ species: 'Beta', baseSpd: 0, moves: [fx('splash', 0, 85)], ...o });
const g1Active = (battle, playerId) => {
  const fighter = battle.byId.get(playerId);
  return fighter.mons[fighter.active - 1];
};

test("a player's cure reloads the party stats; a Full Restore that heals, or the computer's, does not", () => {
  const cured = (item, hp, side) => {
    const battle = g1Battle({
      mode: side === 'b' ? 'coop_npc' : 'wild', aBadges: allBadges(),
      aBag: { [item]: 1 }, bBag: { [item]: 1 },
      a: [g1Mon({ status: side === 'b' ? undefined : 'PAR', hp })],
      b: [g1Foe({ spd: 80, status: side === 'b' ? 'PAR' : undefined })],
    });
    if (side === 'b') {
      battle.submitChoice('p1', { action: 'fight', move: 0 });
      battle.submitChoice('p2', { action: 'item', item });
      return g1Active(battle, 'p2');
    }
    battle.submitChoice('p1', { action: 'item', item });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    return g1Active(battle, 'p1');
  };
  const healed = cured('PARLYZ_HEAL');
  assert.strictEqual(healed.status, null);
  assert.strictEqual(`${healed.cur.atk}/${healed.cur.spd}`, '100/60',
    'ItemUseMedicine copies the party stats: penalty and badges gone');
  assert.strictEqual(cured('FULL_RESTORE', 100).cur.spd, 16,
    'a Full Restore that also heals keeps the stored 15 -> 16');
  assert.strictEqual(cured('FULL_RESTORE').cur.spd, 60, 'at full HP it is a Full Heal');
  const npc = cured('PARLYZ_HEAL', undefined, 'b');
  assert.strictEqual(npc.status, null);
  assert.strictEqual(npc.cur.spd, 20, 'AICureStatus leaves the quartered Speed');
});

test('a vitamin rebuilds the fielded battle stats; a faint and a switch reload them', () => {
  const vit = g1Battle({
    aBadges: allBadges(), aBag: { PROTEIN: 1 },
    a: [g1Mon({ level: 100 })], b: [g1Foe({})],
  });
  vit.submitChoice('p1', { action: 'item', item: 'PROTEIN' });
  vit.submitChoice('p2', { action: 'fight', move: 0 });
  const alpha = g1Active(vit, 'p1');
  assert.strictEqual(alpha.partyStats.atk, 112, 'PROTEIN at level 100 is +12');
  assert.strictEqual(alpha.cur.atk, 126, '112 through the badge: 126');

  const fell = g1Battle({
    mode: '1v1',
    a: [g1Mon({ hp: 1, moves: [fx('sharpen', 0, 50)] }), g1Mon({ species: 'Gamma' })],
    b: [g1Foe({ atk: 200, spd: 10, moves: [fx('thump', 40, 0)] })],
  });
  fell.submitChoice('p1', { action: 'fight', move: 0 });
  fell.submitChoice('p2', { action: 'fight', move: 0 });
  const fallen = fell.byId.get('p1').mons[0];
  assert.strictEqual(fallen.hp, 0);
  assert.strictEqual(fallen.stages.atk, 0, 'a faint zeroes the stages');
  assert.strictEqual(fallen.cur.atk, 100, '...and reloads the battle stats');

  const mimic = g1Battle({
    mode: '1v1',
    a: [g1Mon({ atk: 30, spd: 90, moves: [fx('mimicry', 0, 57)] }), g1Mon({ species: 'Gamma' })],
    b: [g1Foe({ atk: 200 })],
  });
  mimic.submitChoice('p1', { action: 'fight', move: 0 });
  mimic.submitChoice('p2', { action: 'fight', move: 0 });
  const ditto = g1Active(mimic, 'p1');
  assert.deepStrictEqual([ditto.cur.atk, ditto.stats.atk, ditto.partyStats.atk], [200, 200, 30],
    'Transform copies battle and unmodified stats, never the party struct');
  mimic.submitChoice('p1', { action: 'switch', slot: 1 });
  mimic.submitChoice('p2', { action: 'fight', move: 0 });
  mimic.submitChoice('p1', { action: 'switch', slot: 0 });
  mimic.submitChoice('p2', { action: 'fight', move: 0 });
  assert.strictEqual(g1Active(mimic, 'p1').stats.atk, 30, 'switched back in, its own stats return');
});

// ------------------------------------------------------------------
// Gen 1 priority, obedience, the called-move path and the flinch-reset skip,
// stated as claims (twin of tests/battle_sim_turn.lua section 26, where the
// cart's arithmetic for every script is worked beside it)
// ------------------------------------------------------------------

const { Rng: G1bRng } = require('./lib/battle');

// The battle's generator, handed the BattleRandom bytes CheckForDisobedience
// reads, in order, then a seeded generator for everything after.
const g1bScript = (battle, bytes) => {
  const fallback = G1bRng.create(99);
  let used = 0;
  battle.rng = {
    byte() {
      used += 1;
      if (used <= bytes.length) return bytes[used - 1];
      return fallback.byte();
    },
    nextInt: (lo, hi) => fallback.nextInt(lo, hi),
    damageRoll: () => fallback.damageRoll(),
    next: () => fallback.next(),
    state: () => fallback.state(),
  };
};

// A sheet names its moves (PROTOCOL 26); an id with an underscore gets the
// display name a client sends, as the Lua twin's do.
const g1bMove = (id, power, effect, o = {}) => {
  const out = { id, pp: o.pp === undefined ? 20 : o.pp, power, accuracy: 255, type: 0,
    effect, chance: o.chance === undefined ? 0 : o.chance };
  if (id.includes('_')) out.name = id.replace(/_/g, ' ');
  return out;
};
const g1bMon = (o) => {
  const out = {
    species: o.species || 'Alpha', level: o.level === undefined ? 20 : o.level, hp: o.hp,
    maxHp: o.maxHp === undefined ? 60 : o.maxHp, status: o.status,
    stats: { atk: o.atk || 40, def: o.def || 40, spd: o.spd || 40, spc: o.spc || 40 },
    moves: o.moves || [g1bMove('thump', 40, 0)],
  };
  if (o.confusion) out.confusion = o.confusion;
  if (o.baseSpd !== undefined) out.baseSpd = o.baseSpd;
  if (o.traded) out.traded = true;
  Object.assign(out, o.extra || {});
  return out;
};
const g1bArena = (o) => {
  const battle = build({
    id: 'b1', mode: o.mode || 'wild', seed: o.seed || 6401, metronomePool: o.pool,
    choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: o.badges, mons: o.a.map(g1bMon) }],
      b: [{ playerId: 'p2', name: 'Bob', mons: o.b.map(g1bMon) }],
    },
  });
  battle.drainEvents();
  return battle;
};
const g1bStep = (battle, a, b) => {
  battle.submitChoice('p1', a);
  battle.submitChoice('p2', b);
  return battle.drainEvents();
};
const g1bUse = (i) => ({ action: 'fight', move: i });
const g1bSaid = (events, text) => events.some((e) => e.t === 'msg' && e.text === text);
const g1bOrder = (events) => events.filter((e) => e.t === 'anim')
  .map((e) => `${e.slot}:${e.text}`).join(' ');
const g1bHits = (events, slot) => events.filter((e) => e.t === 'damage' && e.slot === slot)
  .map((e) => e.amount);
const g1bActive = (battle, playerId) => {
  const fighter = battle.byId.get(playerId);
  return fighter.mons[fighter.active - 1];
};
const g1bSplash = () => g1bMove('splash', 0, 85);
// The traded level-100 monster every obedience case starts from: faster than
// Bob, so its rolls are the turn's first draws.
const g1bRogue = (o = {}) => ({
  species: 'Alpha', level: 100, maxHp: 999, atk: 30, def: 60, spd: 90, traded: true, baseSpd: 0,
  moves: [g1bMove('thump', 10, 0), g1bMove('chop', 10, 0), g1bSplash()], ...o,
});
const g1bBob = (o = {}) => ({
  species: 'Beta', maxHp: 999, spd: 30, baseSpd: 0, moves: [g1bSplash()], ...o,
});

test('Gen 1 priority: Quick Attack first, Counter last, Metronome and Struggle at 0', () => {
  for (const mode of ['1v1', 'wild']) {
    const kit = () => [g1bMove('QUICK_ATTACK', 10, 0), g1bMove('thump', 10, 0),
      g1bMove('COUNTER', 10, 0)];
    const battle = g1bArena({ mode,
      a: [{ species: 'Alpha', maxHp: 400, spd: 30, baseSpd: 0, moves: kit() }],
      b: [{ species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0, moves: kit() }] });
    assert.strictEqual(g1bOrder(g1bStep(battle, g1bUse(0), g1bUse(1))), '0:QUICK_ATTACK 3:thump',
      `${mode}: the slower Quick Attack moves first`);
    assert.strictEqual(g1bOrder(g1bStep(battle, g1bUse(0), g1bUse(0))),
      '3:QUICK_ATTACK 0:QUICK_ATTACK', `${mode}: Quick Attack on both sides is Speed's`);
    assert.strictEqual(g1bOrder(g1bStep(battle, g1bUse(1), g1bUse(2))), '0:thump 3:COUNTER',
      `${mode}: the faster Counter moves last`);
    assert.strictEqual(g1bOrder(g1bStep(battle, g1bUse(2), g1bUse(2))), '3:COUNTER 0:COUNTER',
      `${mode}: Counter on both sides is Speed's`);
  }
  const metro = g1bArena({ pool: [g1bMove('QUICK_ATTACK', 10, 0)],
    a: [{ species: 'Alpha', maxHp: 400, spd: 30, baseSpd: 0, moves: [g1bMove('metronome', 0, 83)] }],
    b: [{ species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0, moves: [g1bMove('thump', 10, 0)] }] });
  assert.strictEqual(g1bOrder(g1bStep(metro, g1bUse(0), g1bUse(0))),
    '3:thump 0:metronome 0:QUICK_ATTACK', "a called Quick Attack moves at Metronome's bracket");
  const spent = g1bArena({
    a: [{ species: 'Alpha', maxHp: 400, spd: 30, baseSpd: 0,
      moves: [g1bMove('QUICK_ATTACK', 10, 0, { pp: 0 })] }],
    b: [{ species: 'Beta', maxHp: 400, spd: 90, baseSpd: 0, moves: [g1bMove('thump', 10, 0)] }] });
  assert.strictEqual(g1bOrder(g1bStep(spent, g1bUse(0), g1bUse(0))), '3:thump 0:STRUGGLE',
    'Struggle off an empty Quick Attack slot has no priority');
  for (let seed = 1; seed <= 40; seed += 1) {
    const tied = g1bArena({ mode: '1v1', seed,
      a: [{ species: 'Alpha', maxHp: 400, spd: 50, baseSpd: 0, moves: [g1bMove('thump', 10, 0)] }],
      b: [{ species: 'Beta', maxHp: 400, spd: 50, baseSpd: 0,
        moves: [g1bMove('QUICK_ATTACK', 10, 0)] }] });
    assert.strictEqual(g1bOrder(g1bStep(tied, g1bUse(0), g1bUse(0))), '3:QUICK_ATTACK 0:thump',
      `seed ${seed}: different brackets never share a tie byte`);
  }
});

test('Gen 1 obedience: who never rolls plays out exactly as untraded', () => {
  const same = (label, o) => {
    const run = (traded) => {
      const a = o.a.map((opts, i) => (i === 0 && o.side !== 'b' ? { ...opts, traded } : { ...opts }));
      const b = o.b.map((opts, i) => (i === 0 && o.side === 'b' ? { ...opts, traded } : { ...opts }));
      const battle = g1bArena({ mode: o.mode, badges: o.badges, seed: 6402, a, b });
      const events = g1bStep(battle, g1bUse(0), g1bUse(0));
      return JSON.stringify(events) + '#' + battle.rng.state();
    };
    assert.strictEqual(run(true), run(false), label);
  };
  same('level 10 under no badge', { a: [g1bRogue({ level: 10 })], b: [g1bBob()] });
  same("CASCADEBADGE's cap 30", { badges: { CASCADEBADGE: true }, a: [g1bRogue({ level: 30 })], b: [g1bBob()] });
  same("EARTHBADGE's cap 101", { badges: { EARTHBADGE: true }, a: [g1bRogue()], b: [g1bBob()] });
  same('a link fight', { mode: '1v1', a: [g1bRogue()], b: [g1bBob()] });
  same('coop_pvp', { mode: 'coop_pvp', a: [g1bRogue()], b: [g1bBob()] });
  same('side b', { side: 'b', a: [g1bRogue({ traded: false })], b: [g1bBob({ level: 100 })] });
  same("a thrash's continuation",
    { a: [g1bRogue({ extra: { thrashing: { turns: 2, moveIndex: 1 } } })], b: [g1bBob()] });
  same("a Rage's continuation", { a: [g1bRogue({ moves: [g1bMove('fury', 10, 81)],
    extra: { raging: true, rageMove: 1 } })], b: [g1bBob()] });
  same("a charge's release", { a: [g1bRogue({ moves: [g1bMove('glow', 10, 39)],
    extra: { charging: { moveIndex: 1, effect: 39, targetSlot: 3 } } })], b: [g1bBob()] });
  same("a Bide's release", { a: [g1bRogue({ moves: [g1bMove('bide', 0, 26)],
    extra: { bide: { turns: 0, stored: 5, moveIndex: 1, targetSlot: 3 } } })], b: [g1bBob()] });
});

test('Gen 1 obedience: the R1 pass and the move used instead', () => {
  const pass = g1bArena({ a: [g1bRogue()], b: [g1bBob()] });
  g1bScript(pass, [0x20]);
  assert.ok(g1bSaid(g1bStep(pass, g1bUse(0), g1bUse(0)), 'Alpha used thump'), 'an R1 pass');
  assert.strictEqual(g1bActive(pass, 'p1').moves[0].pp, 19);

  const battle = g1bArena({ a: [g1bRogue()], b: [g1bBob()] });
  g1bScript(battle, [0x05, 0x02, 0x00, 0x01]);
  const events = g1bStep(battle, g1bUse(0), g1bUse(0));
  assert.ok(g1bSaid(events, 'Alpha used instead, chop'), '"used instead,"');
  assert.strictEqual(g1bOrder(events), '0:chop 3:splash');
  const alpha = g1bActive(battle, 'p1');
  assert.deepStrictEqual([alpha.moves[0].pp, alpha.moves[1].pp, alpha.lastMoveIndex], [19, 20, 2],
    'the chosen slot pays; the move used is the last move');

  const quick = g1bArena({ a: [g1bRogue({ spd: 10,
    moves: [g1bMove('QUICK_ATTACK', 10, 0), g1bMove('thump', 10, 0)] })], b: [g1bBob()] });
  g1bScript(quick, [0x05, 0x02, 0x01]);
  assert.strictEqual(g1bOrder(g1bStep(quick, g1bUse(0), g1bUse(0))), '0:thump 3:splash',
    "the chosen Quick Attack's bracket moves the move used instead");
});

test('Gen 1 obedience: every .useRandomMove refusal loafs without a draw', () => {
  const refused = (label, moves, extra) => {
    const battle = g1bArena({ a: [g1bRogue({ moves, extra })], b: [g1bBob()] });
    g1bScript(battle, [0x05, 0x02, 0x02]);
    const events = g1bStep(battle, g1bUse(0), g1bUse(0));
    assert.ok(g1bSaid(events, 'Alpha turned away!'), `${label}: loafs`);
    assert.strictEqual(g1bOrder(events), '3:splash', `${label}: uses nothing`);
    assert.strictEqual(g1bActive(battle, 'p1').moves[0].pp, moves[0].pp, `${label}: spends nothing`);
  };
  refused('one move known', [g1bMove('thump', 10, 0)]);
  refused('a move disabled', [g1bMove('thump', 10, 0), g1bMove('chop', 10, 0)],
    { disable: { moveIndex: 2, turns: 3 } });
  refused('Struggle', [g1bMove('thump', 10, 0, { pp: 0 }), g1bMove('chop', 10, 0, { pp: 0 })]);
  refused('no PP outside the chosen slot', [g1bMove('thump', 10, 0), g1bMove('chop', 10, 0, { pp: 0 })]);
});

test('Gen 1 obedience: the nap overwrites the status and keeps the stored penalty', () => {
  const par = g1bArena({ a: [g1bRogue({ spd: 200, status: 'PAR' })], b: [g1bBob()] });
  assert.strictEqual(g1bActive(par, 'p1').cur.spd, 50);
  g1bScript(par, [200, 0x05, 50, 0x24, 0x18]);
  const events = g1bStep(par, g1bUse(0), g1bUse(0));
  assert.ok(g1bSaid(events, 'Alpha began to nap!'));
  const napped = events.find((e) => e.t === 'status' && e.slot === 0);
  assert.strictEqual(napped && napped.status, 'SLP');
  const alpha = g1bActive(par, 'p1');
  assert.deepStrictEqual([alpha.status, alpha.statusTurns, alpha.cur.spd], ['sleep', 3, 50]);

  const brn = g1bArena({ a: [g1bRogue({ status: 'BRN' })], b: [g1bBob()] });
  g1bScript(brn, [0x05, 50, 0x24, 0x18]);
  g1bStep(brn, g1bUse(0), g1bUse(0));
  assert.deepStrictEqual([g1bActive(brn, 'p1').status, g1bActive(brn, 'p1').cur.atk], ['sleep', 15]);
  assert.ok(g1bSaid(g1bStep(brn, g1bUse(0), g1bUse(0)), 'Alpha is fast asleep'));
});

test("Gen 1 obedience: won't obey + the self-hit, and the four loaf lines", () => {
  const selfHit = (reflect) => {
    const battle = g1bArena({ a: [g1bRogue()],
      b: [g1bBob({ extra: reflect ? { reflect: true } : undefined })] });
    g1bScript(battle, [0x05, 50, 0xA5]);
    const events = g1bStep(battle, g1bUse(0), g1bUse(0));
    assert.ok(g1bSaid(events, "Alpha won't obey!") && g1bSaid(events, 'Alpha hurt itself in confusion'));
    return g1bHits(events, 0)[0];
  };
  assert.strictEqual(selfHit(true), 10, "the foe's Reflect doubles the self-hit's Defense");
  assert.strictEqual(selfHit(false), 18);
  for (const [b, line] of [[0x00, 'Alpha is loafing around.'], [0x05, "Alpha won't obey!"],
    [0xFE, 'Alpha turned away!'], [0x0B, 'Alpha ignored orders!']]) {
    const battle = g1bArena({ a: [g1bRogue()], b: [g1bBob()] });
    g1bScript(battle, [0x05, 50, 0x4B, b]);
    const events = g1bStep(battle, g1bUse(0), g1bUse(0));
    assert.ok(g1bSaid(events, line), line);
    assert.strictEqual(g1bHits(events, 0).length, 0, `${line}: nobody is hurt`);
  }
});

test('Gen 1 obedience: a Metronome instead keeps the flag, a Mirror Move clears it', () => {
  const metro = g1bArena({ pool: [g1bMove('chop', 10, 0)],
    a: [g1bRogue({ moves: [g1bMove('thump', 10, 0), g1bMove('metronome', 0, 83)] })], b: [g1bBob()] });
  g1bScript(metro, [0x05, 0x02, 0x01]);
  const events = g1bStep(metro, g1bUse(0), g1bUse(0));
  assert.ok(g1bSaid(events, 'Alpha used instead, metronome') && g1bSaid(events, 'Alpha used instead, chop'));
  assert.strictEqual(g1bActive(metro, 'p1').moves[0].pp, 19);

  const mirror = g1bArena({
    a: [g1bRogue({ moves: [g1bMove('thump', 10, 0), g1bMove('mirror', 0, 9)] })], b: [g1bBob()] });
  g1bScript(mirror, [0x20]);
  g1bStep(mirror, g1bUse(0), g1bUse(0));
  g1bScript(mirror, [0x05, 0x02, 0x01]);
  const copied = g1bStep(mirror, g1bUse(0), g1bUse(0));
  assert.ok(g1bSaid(copied, 'Alpha used instead, mirror') && g1bSaid(copied, 'Alpha used splash'));
});

test('Gen 1 called moves: no Struggle recoil off the last PP, and no second gate', () => {
  const metro = g1bArena({ pool: [g1bMove('thump', 10, 0)],
    a: [{ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0, moves: [g1bMove('metronome', 0, 83, { pp: 1 })] }],
    b: [g1bBob()] });
  let events = g1bStep(metro, g1bUse(0), g1bUse(0));
  assert.ok(g1bSaid(events, 'Alpha used thump') && !g1bSaid(events, 'Alpha is hit with recoil'),
    'a Metronome on its last PP takes no recoil');
  events = g1bStep(metro, g1bUse(0), g1bUse(0));
  assert.ok(g1bSaid(events, 'Alpha used STRUGGLE') && g1bSaid(events, 'Alpha is hit with recoil'),
    'the Struggle after it does');

  const mirror = g1bArena({
    a: [{ species: 'Alpha', maxHp: 400, spd: 10, baseSpd: 0, moves: [g1bMove('mirror', 0, 9, { pp: 1 })] }],
    b: [g1bBob({ moves: [g1bMove('thump', 10, 0)] })] });
  events = g1bStep(mirror, g1bUse(0), g1bUse(0));
  assert.ok(g1bSaid(events, 'Alpha used thump') && !g1bSaid(events, 'Alpha is hit with recoil'),
    'a Mirror Move on its last PP takes no recoil');

  const dizzy = g1bArena({ pool: [g1bMove('thump', 10, 0)],
    a: [{ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0, confusion: 6,
      moves: [g1bMove('metronome', 0, 83)] }], b: [g1bBob()] });
  g1bScript(dizzy, [200]);
  assert.ok(g1bSaid(g1bStep(dizzy, g1bUse(0), g1bUse(0)), 'Alpha used thump'));
  assert.strictEqual(g1bActive(dizzy, 'p1').confusion, 5, 'the call runs no second confusion gate');
});

test('Gen 1 flinch-reset skip: the player\'s raging or recharging monster keeps its flinch', () => {
  const rage = (mode, side) => {
    const fast = { species: side === 'b' ? 'Beta' : 'Alpha', maxHp: 400, spd: 90, baseSpd: 0,
      moves: [g1bMove('fury', 20, 81)] };
    const slow = { species: side === 'b' ? 'Alpha' : 'Beta', maxHp: 400, spd: 30, baseSpd: 0,
      moves: [g1bMove('stomp', 10, 31, { chance: 100 })] };
    const battle = g1bArena({ mode, a: [side === 'b' ? slow : fast], b: [side === 'b' ? fast : slow] });
    g1bStep(battle, g1bUse(0), g1bUse(0));
    return g1bStep(battle, g1bUse(0), g1bUse(0));
  };
  assert.ok(g1bSaid(rage('wild'), 'Alpha flinched'), "the player's raging monster keeps it");
  // The owner's rule (R1b): both sides of a link fight are "the player".
  assert.ok(g1bSaid(rage('1v1'), 'Alpha flinched'), 'a link fight keeps it too');
  assert.ok(!g1bSaid(rage('wild', 'b'), 'Beta flinched'), "the computer's raging monster is reset");

  const beam = g1bArena({
    a: [{ species: 'Alpha', maxHp: 400, spd: 90, baseSpd: 0, moves: [g1bMove('beam', 20, 80)] }],
    b: [g1bBob({ maxHp: 400, moves: [g1bMove('stomp', 10, 31, { chance: 100 })] })] });
  // A flinch that lands runs ClearHyperBeam on its target (R1b): the beam
  // user is not recharging at the open, so the reset takes the flinch and
  // the beam fires again.
  g1bStep(beam, g1bUse(0), g1bUse(0));
  assert.strictEqual(g1bActive(beam, 'p1').mustRecharge, false, 'the flinch cleared the recharge');
  assert.strictEqual(g1bActive(beam, 'p1').flinch, false, '...so the open reset the flinch');
  assert.ok(g1bSaid(g1bStep(beam, g1bUse(0), g1bUse(0)), 'Alpha used beam'), '...and it fires again');

  const coop = build({ id: 'b1', mode: 'coop_wild', seed: 6403, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [g1bMon({ species: 'Alpha', maxHp: 400, spd: 90,
          baseSpd: 0, moves: [g1bMove('fury', 20, 81)] })] },
        { playerId: 'a2', name: 'Abe', mons: [g1bMon({ species: 'Gamma', maxHp: 400, spd: 80,
          baseSpd: 0, moves: [g1bMove('thump', 10, 0)] })] },
      ],
      b: [{ playerId: 'w', name: 'Wild', mons: [g1bMon({ species: 'Beta', maxHp: 900, spd: 30,
        baseSpd: 0, moves: [g1bMove('stomp', 10, 31, { chance: 100 })] })] }],
    } });
  coop.drainEvents();
  const round = (target) => {
    coop.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    coop.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    coop.submitChoice('w', { action: 'fight', move: 0, target });
    return coop.drainEvents();
  };
  round(0);
  assert.ok(g1bSaid(round(1), 'Alpha flinched'), 'co-op: the raging seat keeps its flinch');
  const third = round(1);
  assert.ok(!g1bSaid(third, 'Gamma flinched') && g1bSaid(third, 'Gamma used thump'),
    "co-op: the partner's flinch is reset");
});

test('Gen 1 badgeRules and traded: the player against the computer; true or absent', () => {
  const rules = (mode) => {
    const sides = mode === 'coop_wild' ? {
      a: [{ playerId: 'p1', name: 'Ann', mons: [g1bMon({})] }, { playerId: 'p3', name: 'Abe', mons: [g1bMon({})] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [g1bMon({ species: 'Beta' })] }],
    } : {
      a: [{ playerId: 'p1', name: 'Ann', mons: [g1bMon({})] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [g1bMon({ species: 'Beta' })] }],
    };
    const battle = build({ id: 'b1', mode, seed: 1, sides });
    return `${battle.byId.get('p1').badgeRules}/${battle.byId.get('p2').badgeRules}`;
  };
  assert.strictEqual(rules('wild'), 'true/null');
  assert.strictEqual(rules('coop_wild'), 'true/null');
  assert.strictEqual(rules('coop_npc'), 'true/null');
  assert.strictEqual(rules('1v1'), 'null/null');
  assert.strictEqual(rules('coop_pvp'), 'null/null');
  const traded = (value) => {
    const battle = build({ id: 'b1', mode: '1v1', seed: 1, sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [g1bMon({ extra: { traded: value } })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [g1bMon({ species: 'Beta' })] }] } });
    return g1bActive(battle, 'p1').traded;
  };
  assert.strictEqual(traded(true), true);
  assert.strictEqual(traded(false), undefined);
  assert.strictEqual(traded('yes'), undefined);
});

// ------------------------------------------------------------------
// The Gen 1 review fixes (FX1), stated as claims (twin of
// tests/battle_sim_turn.lua section 27, where the arithmetic is worked)
// ------------------------------------------------------------------

const stageAt = (name, at, slot) => {
  const row = (jsRun(name).probes || []).find((p) => p.at === at && p.slot === slot);
  return row ? row.sAtk : null;
};
const eventsOf = (name, kind) => jsRun(name).events.filter((event) => event.t === kind);

test('a Leech Seed tick that knocks the seeded monster out still heals the seeder', () => {
  const faint = eventsOf('g1_leech_ko', 'faint');
  assert.deepStrictEqual(faint.map((e) => `${e.slot}:${e.text}`), ['3:Beta'], 'the seeded monster falls');
  assert.deepStrictEqual(eventsOf('g1_leech_ko', 'drain').map((e) => `${e.slot}:${e.amount}:${e.hp}`),
    ['0:6:56'], 'the whole 1/16 of 100, though only 3 HP came off');
  assert.strictEqual(jsRun('g1_leech_ko').outcome.outcome, 'win');
});

test("Rage builds from no poison, Leech Seed or confusion self-hit", () => {
  assert.ok(saidIn('g1_rage_quiet', 'Alpha hurt itself in confusion'), 'the seed does reach a self-hit');
  for (const at of [1, 2, 3]) {
    assert.strictEqual(stageAt('g1_rage_quiet', at, 0), 0, `turn ${at}: no build`);
    assert.strictEqual(probeAt('g1_rage_quiet', at, 0), '112/90/101/56', `turn ${at}: the switch-in stats`);
  }
  assert.ok(!saidIn('g1_rage_quiet', "Alpha's ATTACK rose"));
});

test('the hit that knocks a raging monster out builds nothing and re-penalises nobody', () => {
  assert.ok(!saidIn('g1_rage_lethal', "Alpha's ATTACK rose"));
  assert.strictEqual(probeAt('g1_rage_lethal', 0, 3), '100/40/10/40', 'the burned attacker: 200 -> 100');
  assert.strictEqual(probeAt('g1_rage_lethal', 1, 3), '100/40/10/40', 'not halved again to 50');
});

test('a Substitute that soaks the hit still builds, once per hit', () => {
  // The build follows the hit: each `stat` comes right after its `damage`.
  const order = (name) => jsRun(name).events
    .filter((e) => e.slot === 0 && (e.t === 'damage' || e.t === 'stat')).map((e) => e.t);
  const alphaHp = (name) => jsRun(name).events
    .filter((e) => e.t === 'damage' && e.slot === 0).map((e) => e.hp);
  // A 5-HP doll: the first hit breaks it and ends the double kick.
  assert.ok(saidIn('g1_rage_sub', "Alpha's substitute broke"));
  assert.strictEqual(stageAt('g1_rage_sub', 1, 0), 1, 'one hit, one build: +1');
  assert.strictEqual(probeAt('g1_rage_sub', 1, 0), '60/40/90/40', '40 x 150 / 100');
  assert.deepStrictEqual(alphaHp('g1_rage_sub'), [400], 'the doll took it; no second hit');
  assert.deepStrictEqual(order('g1_rage_sub'), ['damage', 'stat']);
  // A 12-HP doll: soaked by the first, broken by the second -- both build.
  assert.ok(saidIn('g1_rage_sub_late', "Alpha's substitute broke"));
  assert.strictEqual(stageAt('g1_rage_sub_late', 1, 0), 2, 'the soaked hit and the breaking one: +2');
  assert.strictEqual(probeAt('g1_rage_sub_late', 1, 0), '80/40/90/40', '40 x 200 / 100');
  assert.deepStrictEqual(alphaHp('g1_rage_sub_late'), [400, 400], 'both on the doll');
  assert.deepStrictEqual(order('g1_rage_sub_late'), ['damage', 'stat', 'damage', 'stat']);
});

test('a missed Disable and a missed Explosion both build the target', () => {
  assert.strictEqual(stageAt('g1_rage_misses', 1, 0), 1, 'the Disable missed and the target built');
  assert.strictEqual(stageAt('g1_rage_misses', 2, 0), 2, 'the Explosion missed and the target built');
  // The Disable's miss is DisableEffect's "But it failed!" (R1b); the
  // Explosion's is the attack's.
  assert.strictEqual(jsRun('g1_rage_misses').events.filter((e) => e.t === 'msg' && e.text === 'Beta missed').length, 1);
  assert.strictEqual(jsRun('g1_rage_misses').events.filter((e) => e.t === 'msg' && e.text === 'But it failed').length, 1);
  assert.strictEqual(jsRun('g1_rage_misses').outcome.winners[0], 'p1', 'the exploder still went down');
});

test("a trap's later ticks build the trapped monster and re-penalise the trapper", () => {
  assert.deepStrictEqual([1, 2, 3, 4].map((at) => stageAt('g1_rage_trap', at, 0)), [1, 2, 3, 4]);
  assert.deepStrictEqual([1, 2, 3, 4].map((at) => probeAt('g1_rage_trap', at, 4)),
    ['50/40/10/40', '25/40/10/40', '12/40/10/40', '6/40/10/40'], 'Delta, the trapper, halved each time');
  assert.deepStrictEqual([1, 2, 3, 4].map((at) => probeAt('g1_rage_trap', at, 3)),
    ['100/40/20/40', '100/40/20/40', '100/40/20/40', '100/40/20/40'], 'Beta, standing opposite, never');
});

test('a Bide aimed at field slot 0 is released at slot 0', () => {
  const released = jsRun('g1_bide_slot0').events.filter((e) => e.t === 'damage' && e.side === 'a');
  // `.BideCheck` stores wDamage (R1b): Alpha's 5 a turn, three stores on
  // this seed's counter, 2 x 15 on the fourth turn.
  assert.deepStrictEqual(released.map((e) => `${e.slot}:${e.amount}`), ['0:30']);
});

test('a side-effect drop at -6 is silent; a primary at -6 says so', () => {
  // CantLowerAnymore's NothingHappenedText (R1b).
  const lines = jsRun('g1_side_min').events.filter((e) => e.t === 'msg' && e.text === 'Nothing happened');
  assert.strictEqual(lines.length, 1, 'once, for the primary on turn 2');
  const texts = jsRun('g1_side_min').events.filter((e) => e.t === 'msg').map((e) => e.text);
  assert.ok(texts.indexOf('Nothing happened') > texts.indexOf('Alpha used goo'));
});

// ------------------------------------------------------------------
// Gen 1 side-effect odds (FX4), stated as claims (twin of
// tests/battle_sim_turn.lua section 28, where the bytes are forced and the
// draws counted)
// ------------------------------------------------------------------

// Battle `at` of a sideTurns scenario: its RNG state, the target's (slot 3)
// or the user's (slot 0) probe row, and what was said in it.
const rngOf = (name, at) => jsRun(name).probes.find((p) => p.at === at && p.slot === undefined).rng;
const seatOf = (name, at, slot) => jsRun(name).probes.find((p) => p.at === at && p.slot === slot);
const saidAt = (name, at, text) => {
  const battle = jsRun(name).events.find((e) => e.t === 'msg').battle.replace(/1$/, String(at));
  return jsRun(name).events.some((e) => e.battle === battle && e.t === 'msg' && e.text === text);
};
// The `damage` events the target (slot 3) took in battle `at`, as "amount:hp"
// -- a doll's hit leaves hp where it was.
const hitsAt = (name, at) => {
  const battle = jsRun(name).events.find((e) => e.t === 'msg').battle.replace(/1$/, String(at));
  return jsRun(name).events
    .filter((e) => e.battle === battle && e.t === 'damage' && e.slot === 3)
    .map((e) => `${e.amount}:${e.hp}`);
};

test("Red's side effects fire at chance 0: below each routine's threshold, not at it", () => {
  for (const [name, landed] of [
    ['g1_odds_poison1', 'poison'], ['g1_odds_poison2', 'poison'], ['g1_odds_twineedle', 'poison'],
    ['g1_odds_burn1', 'burn'], ['g1_odds_freeze1', 'freeze'], ['g1_odds_paralyze2', 'paralysis'],
  ]) {
    assert.strictEqual(seatOf(name, 1, 3).status, landed, `${name}: threshold - 1 lands`);
    assert.strictEqual(seatOf(name, 2, 3).status, '', `${name}: the threshold does not`);
  }
  for (const name of ['g1_odds_flinch1', 'g1_odds_flinch2']) {
    assert.ok(saidAt(name, 1, 'Beta flinched'), `${name}: threshold - 1 flinches`);
    assert.ok(!saidAt(name, 2, 'Beta flinched'), `${name}: the threshold does not`);
  }
  assert.strictEqual(seatOf('g1_odds_drop', 1, 3).sSpc, -1, '84 < 85 drops the Special');
  assert.strictEqual(seatOf('g1_odds_drop', 2, 3).sSpc, 0, '85 does not');
  assert.ok(seatOf('g1_odds_confuse', 1, 3).confusion > 0, '24 < 25 confuses');
  assert.strictEqual(seatOf('g1_odds_confuse', 2, 3).confusion, 0, '25 does not (no + 1 here)');
});

test("the computer's side-effect drop draws its extra miss first", () => {
  assert.strictEqual(seatOf('g1_odds_computer_drop', 1, 0).sSpd, 0, 'the miss byte 63 stops it');
  assert.strictEqual(seatOf('g1_odds_computer_drop', 2, 0).sSpd, -1, '64 passes and 84 lands');
});

test('an explicit chance overrides the cart odds; a chance on no side routine draws nothing', () => {
  assert.deepStrictEqual([1, 2, 3].map((at) => seatOf('g1_side_precedence', at, 3).status),
    ['', 'burn', ''], 'byte 50: the cart 26 misses, 20% (51) lands, 19% (48) misses');
  assert.strictEqual(rngOf('g1_side_precedence', 1), rngOf('g1_side_precedence', 2), 'one draw either way');
  assert.strictEqual(rngOf('g1_side_precedence', 4), rngOf('g1_side_precedence', 5),
    'effect 0 at chance 100 draws no more than effect 0 at chance 0');
  assert.notStrictEqual(rngOf('g1_side_precedence', 1), rngOf('g1_side_precedence', 5));
});

test('each side-effect routine draws only where the cart does', () => {
  const g = 'g1_side_gates';
  const plain = rngOf(g, 1);
  for (const [at, why] of [
    [2, 'a burn into a poisoned target'], [3, 'a burn into a target of its own type'],
    [4, 'a poison into a Poison-type target'], [6, 'a burn into a Substitute'],
    [7, 'a flinch into a Substitute'], [8, 'a poison into a Substitute'],
    [9, 'a drop into a Substitute'], [11, 'a burn whose hit broke the Substitute'],
    [12, 'a Twineedle whose first hit broke the Substitute'], [13, 'a Fire thaw'],
  ]) {
    assert.strictEqual(rngOf(g, at), plain, `${why} draws nothing`);
  }
  assert.strictEqual(seatOf(g, 2, 3).status, 'poison', 'the poisoned target stays poisoned');
  assert.strictEqual(seatOf(g, 3, 3).status, '', 'and the same-type one unburned');
  assert.notStrictEqual(rngOf(g, 5), plain, 'without typeIds no type is POISON: it draws');
  assert.strictEqual(seatOf(g, 5, 3).status, 'poison');
  assert.notStrictEqual(rngOf(g, 10), plain, 'confusion draws through a Substitute');
  assert.ok(seatOf(g, 10, 3).confusion > 0, '...and confuses the monster behind it');
  assert.ok(saidAt(g, 11, "Beta's substitute broke") && seatOf(g, 11, 3).status === '');
  assert.ok(saidAt(g, 12, "Beta's substitute broke") && seatOf(g, 12, 3).status === '');
  assert.deepStrictEqual(hitsAt(g, 12), ['3:400'], 'the Twineedle ends at the hit that broke the doll');
  assert.ok(saidAt(g, 13, 'Fire defrosted Beta'), 'a Fire move thaws a frozen target');
  assert.strictEqual(seatOf(g, 13, 3).status, '');
  assert.strictEqual(seatOf(g, 14, 3).sSpc, -1, 'Mist does not stop a side-effect drop');
  assert.ok(!saidAt(g, 14, 'But it failed'));
  assert.strictEqual(rngOf(g, 15), rngOf(g, 16), 'a knockout draws no side byte');
  assert.strictEqual(seatOf(g, 16, 3), undefined, 'the target is down');
});

test('a multi-hit move ends at a Substitute its first hit broke, and goes on past a later break', () => {
  const g = 'g1_multi_sub';
  // Two-to-five on seed 29011, 9 a hit: the count bytes after hit 1 are 182
  // (2, so TwoToFiveAttacksEffect draws again) and 151 (3): five hits.
  assert.deepStrictEqual(hitsAt(g, 1), ['9:391', '9:382', '9:373', '9:364', '9:355'], 'no doll: five hits');
  assert.deepStrictEqual(hitsAt(g, 2), ['9:400'], 'a 5-HP doll: the first hit breaks it, and the move ends');
  assert.ok(saidAt(g, 2, "Beta's substitute broke"));
  assert.notStrictEqual(rngOf(g, 2), rngOf(g, 1), '...and no count byte is drawn after a first-hit break');
  assert.strictEqual(rngOf(g, 3), rngOf(g, 1), 'a doll that holds hit 1: the count is drawn as with none');
  assert.deepStrictEqual(hitsAt(g, 3), ['9:400', '9:400', '9:391', '9:382', '9:373'],
    'a 15-HP doll: broken by the second hit, and hits 3 to 5 land on Beta');
  assert.ok(saidAt(g, 3, "Beta's substitute broke"));
  // DOUBLE KICK (8 a hit since K12's high-bits damage roll; 9 before).
  assert.deepStrictEqual(hitsAt(g, 4), ['8:392', '8:384'], 'no doll: two hits');
  assert.deepStrictEqual(hitsAt(g, 5), ['8:400'], 'a 5-HP doll: the second hit is never thrown');
  assert.deepStrictEqual(hitsAt(g, 6), ['8:400', '8:400'], 'a 15-HP doll: both hits, both on it');
  assert.ok(saidAt(g, 5, "Beta's substitute broke") && saidAt(g, 6, "Beta's substitute broke"));
  // TWINEEDLE, on a seed whose side byte (51) poisons (9 a hit since K12; 8 before).
  assert.deepStrictEqual(hitsAt(g, 7), ['9:391', '9:382', '25:357'], 'no doll: two hits, then the tick');
  assert.strictEqual(seatOf(g, 7, 3).status, 'poison');
  assert.deepStrictEqual(hitsAt(g, 8), ['9:400'], 'a 5-HP doll: one hit');
  assert.deepStrictEqual(hitsAt(g, 9), ['9:400', '9:400'], 'a 15-HP doll: two hits, both on it');
  for (const at of [8, 9]) {
    assert.ok(saidAt(g, at, "Beta's substitute broke"));
    assert.strictEqual(seatOf(g, at, 3).status, '', `battle ${at}: no poison`);
    assert.strictEqual(rngOf(g, at), rngOf(g, 10), `battle ${at}: no side byte, a plain hit's stream`);
  }
  assert.notStrictEqual(rngOf(g, 7), rngOf(g, 10), 'the poison that landed drew its byte');
  // AttackSubstitute's `sub [hl]` / `ret nc`: a hit for exactly the doll's HP
  // leaves it standing at 0, and only the next hit breaks it.
  assert.deepStrictEqual(hitsAt(g, 11), ['9:400', '9:400', '9:391', '9:382', '9:373'],
    'a 9-HP doll hit for 9 stands at 0; hit 2 breaks it, hits 3-5 land');
  assert.strictEqual(rngOf(g, 11), rngOf(g, 1), '...the count drawn, as the doll held hit 1');
  assert.ok(saidAt(g, 11, "Beta's substitute broke"));
  assert.deepStrictEqual(hitsAt(g, 12), ['8:400', '8:400'], 'DOUBLE KICK: an 8-HP doll hit for 8 stands, hit 2 breaks it');
  assert.ok(saidAt(g, 12, "Beta's substitute broke"));
});

// ------------------------------------------------------------------
// R1a: the Lua driver's `duels` scenarios, asserted on the JS half (the parity
// tests above hold the Lua half to the same stream).
// ------------------------------------------------------------------

const duelEvents = (name, at) => {
  const id = jsRun(name).events[0].battle.replace(/1$/, String(at));
  return jsRun(name).events.filter((e) => e.battle === id);
};
const duelTexts = (name, at) => duelEvents(name, at).filter((e) => e.t === 'msg').map((e) => e.text);
const duelSaid = (name, at, text) => duelTexts(name, at).includes(text);
const duelRow = (name, at, turn) => jsRun(name).probes
  .find((p) => p.at === at && p.turn === turn && p.rng !== undefined);
const duelSeat = (name, at, turn, slot) => jsRun(name).probes
  .find((p) => p.at === at && p.turn === turn && p.slot === slot && p.mon === 1);
const duelEnd = (name, at) => jsRun(name).probes.find((p) => p.at === at && p.outcome !== undefined);
// "slot:amount:hp" for every damage event, in order.
const duelHits = (name, at) => duelEvents(name, at).filter((e) => e.t === 'damage')
  .map((e) => `${e.slot}:${e.amount}:${e.hp}`);

test('Red damage tails: no roll at 0 or 1, a 0.25x zero misses, an exact-HP doll stands at 0', () => {
  const g = 'g1_damage_tails';
  // A base-2 hit (level 2, Attack 5, Defense 200).
  assert.deepStrictEqual(duelHits(g, 1), ['3:1:399'], '0.5x: 1 damage, as RandomizeDamage leaves it');
  assert.ok(duelSaid(g, 2, 'Alpha missed') && duelHits(g, 2).length === 0,
    '0.25x: 0 is a miss (AdjustDamageForMoveType sets wMoveMissed)');
  assert.ok(duelSaid(g, 4, "It doesn't affect Beta"));
  assert.strictEqual(duelRow(g, 1, 1).rng, duelRow(g, 2, 1).rng, 'the 1 and the 0 draw no roll');
  assert.strictEqual(duelRow(g, 4, 1).rng, duelRow(g, 1, 1).rng, 'nor does an immunity');
  assert.notStrictEqual(duelRow(g, 3, 1).rng, duelRow(g, 1, 1).rng, 'a 2 and up rolls');
  assert.strictEqual(duelRow(g, 2, 1).last, 0, 'the miss zeroes wDamage');
  // Battle 5: a 9-HP doll hit for 9.
  assert.deepStrictEqual([duelSeat(g, 5, 1, 3).sub, duelSeat(g, 5, 1, 3).zero], [0, true],
    'the doll stands at 0 HP (AttackSubstitute `sub [hl]` / `ret nc`)');
  assert.strictEqual(duelTexts(g, 5).filter((t) => t === "Beta's substitute broke").length, 1);
  assert.strictEqual(duelSeat(g, 5, 2, 3).zero, false, 'turn 2: the next hit breaks it');
  assert.strictEqual(duelSeat(g, 5, 2, 3).hp, 400, '...and Beta is untouched by either');
});

test('AlwaysHappenSideEffects: a doll that holds still drains, recoils, recharges; one that breaks cancels', () => {
  const g = 'g1_always_happen';
  const alpha = (at, turn = 1) => duelSeat(g, at, turn, 0);
  assert.deepStrictEqual(duelHits(g, 1), ['3:9:400'], 'the drain move hits the 200-HP doll for 9');
  assert.strictEqual(alpha(1).hp, 304, 'and still heals half of it (DrainHPEffect_ halves wDamage)');
  assert.strictEqual(duelRow(g, 1, 1).last, 4, '...which it halved in place');
  assert.strictEqual(alpha(2).hp, 300, 'a doll the drain broke: no heal');
  assert.strictEqual(alpha(3).hp, 298, 'recoil off a holding doll: a quarter of 9');
  assert.strictEqual(alpha(4).hp, 300, 'recoil after a break: none');
  assert.ok(duelSaid(g, 5, 'Alpha used STRUGGLE'));
  assert.strictEqual(alpha(5).hp, 295, "STRUGGLE's recoil is HALF of 11 (RecoilEffect_ `cp STRUGGLE`)");
  assert.strictEqual(alpha(6).hp, 300, '...and none after a break');
  assert.ok(duelSaid(g, 7, 'Alpha must recharge'), 'HYPER BEAM into a holding doll still recharges');
  assert.strictEqual(duelTexts(g, 8).filter((t) => t === 'Alpha used beam').length, 2,
    'one that broke the doll: no recharge, Alpha fires again on turn 2');
  assert.strictEqual(duelEnd(g, 9).winner, 'p2', 'EXPLOSION into a holding doll: Alpha goes down');
  assert.strictEqual(duelEnd(g, 10), undefined, 'EXPLOSION that broke the doll: Alpha lives');
  assert.strictEqual(alpha(10).hp, 300);
  assert.strictEqual(alpha(11).raging, true, 'RAGE into a holding doll starts raging');
  assert.strictEqual(alpha(12).raging, false, 'RAGE that broke the doll never starts');
  const t13 = duelEvents(g, 13).map((e) => (e.t === 'msg' ? e.text : e.t));
  assert.ok(t13.indexOf('drain') < t13.indexOf("Beta's RAGE is building!"),
    'the drain (AlwaysHappen) comes before the target Rage build');
  assert.strictEqual(alpha(14).hp, 298, 'recoil comes off the HP behind the user\'s own doll');
  assert.strictEqual(alpha(14).sub, 30, '...never the doll');
  assert.strictEqual(duelEnd(g, 15).winner, 'p2', 'EXPLOSION behind its own doll still faints the user');
});

test('Pay Day: the whole pile on a won fight against the computer, nothing in a link fight', () => {
  const g = 'g1_pay_day';
  assert.deepStrictEqual([duelEnd(g, 1).winner, duelEnd(g, 1).payDay], ['p1', 200],
    "3 x 40 of Alpha's and 2 x 40 of the computer's");
  assert.strictEqual(duelEnd(g, 2).payDay, 0, '1v1 pays nothing');
  assert.strictEqual(duelRow(g, 3, 1).payA, 0, 'a use that broke a doll scatters nothing');
  assert.strictEqual(duelEnd(g, 3).payDay, 240);
  assert.strictEqual(duelEnd(g, 4).payDay, 24, 'level 140: 280 wraps the 8-bit `add a` to 24');
  assert.deepStrictEqual([duelEnd(g, 5).winner, duelEnd(g, 5).payDay], ['p2', 0],
    "the computer's win pays nothing");
});

test('COUNTER: twice wDamage against a Normal or Fighting move, else a miss', () => {
  const g = 'g1_counter';
  assert.deepStrictEqual(duelHits(g, 1), ['0:9:391', '3:18:382'], 'twice the thump');
  assert.ok(duelSaid(g, 2, 'Alpha missed'), 'a Fire hit is not countered');
  assert.notStrictEqual(duelRow(g, 2, 1).rng, duelRow(g, 1, 1).rng, '...with no hit test drawn');
  assert.ok(duelSaid(g, 3, 'Beta missed') && duelSaid(g, 3, 'Alpha missed'), 'COUNTER against COUNTER');
  assert.ok(duelSaid(g, 4, 'Alpha missed'), 'a missed thump leaves wDamage at 0');
  assert.deepStrictEqual(duelHits(g, 5), ['0:9:400', '3:18:382'], 'the hit on the doll counts whole');
  assert.deepStrictEqual(duelHits(g, 6), ['0:9:391', '3:18:382'], 'untyped: it reaches a Ghost');
  assert.strictEqual(duelRow(g, 7, 2).last, 18, 'turn 2: wDamage still holds the counter');
  assert.ok(duelTexts(g, 7).slice(-1)[0] === 'Alpha missed', '...but a 0-power move is not countered');
  assert.deepStrictEqual(duelHits(g, 8), ['0:14:386', '3:28:372'], 'a Fighting hit is countered');
  assert.ok(duelSaid(g, 9, 'Alpha missed'), 'typeIds decides which index is NORMAL');
});

test('RAGE and THRASH spend PP once; RAGE at 0 PP stays RAGE; the build line per build', () => {
  const g = 'g1_rage_thrash_pp';
  assert.deepStrictEqual([1, 2, 3].map((t) => duelSeat(g, 1, t, 0).pp), ['0', '0', '0']);
  assert.strictEqual(duelTexts(g, 1).filter((t) => t === 'Alpha used RAGE').length, 3,
    'RAGE every turn at 0 PP, never STRUGGLE');
  assert.ok(!duelSaid(g, 1, 'Alpha used STRUGGLE'));
  assert.strictEqual(duelTexts(g, 1).filter((t) => t === "Alpha's RAGE is building!").length, 3);
  const t1 = duelTexts(g, 1);
  assert.strictEqual(t1[t1.indexOf("Alpha's RAGE is building!") + 1], "Alpha's ATTACK rose");
  assert.deepStrictEqual([1, 2, 3].map((t) => duelSeat(g, 2, t, 0).pp), ['0', '0', '0'],
    'THRASH pays on its first turn only');
  // ThrashPetalDanceEffect's counter is the turns AFTER the first (R1b):
  // 3 on this seed, so it thrashes on turns 1-4 and turn 4's step confuses.
  assert.strictEqual(duelSeat(g, 2, 3, 0).thrash, true, '...still thrashing on turn 3');
  assert.strictEqual(duelSeat(g, 2, 4, 0).conf > 0, true, '...and confuses at its end');
  assert.ok(!duelSaid(g, 3, "Alpha's RAGE is building!"), 'at +6 HandleBuildingRage says nothing');
  assert.strictEqual(duelSeat(g, 3, 1, 0).pp, '60', 'a raging RAGE spends no PP');
});

test('METRONOME / MIRROR MOVE: a called multi-turn move is the one replayed', () => {
  const g = 'g1_called_multiturn';
  for (const [at, id] of [[1, 'FLY'], [2, 'DIG']]) {
    assert.strictEqual(duelSeat(g, at, 1, 0).invuln, true, `${id}: up on turn 1`);
    assert.deepStrictEqual(duelTexts(g, at).slice(0, 6).filter((t) => t.startsWith('Alpha used')),
      ['Alpha used METRONOME', `Alpha used ${id}`, `Alpha used ${id}`], `${id} lands on turn 2`);
    assert.strictEqual(duelSeat(g, at, 2, 0).pp, '59', 'METRONOME spent once for both turns');
  }
  // 1 + the counter (3 on this seed): ThrashPetalDanceEffect counts the turns
  // after the first (R1b).
  assert.strictEqual(duelTexts(g, 3).filter((t) => t === 'Alpha used THRASH').length, 4);
  assert.strictEqual(duelTexts(g, 3).filter((t) => t === 'Alpha used METRONOME').length, 1);
  assert.strictEqual(duelTexts(g, 4).filter((t) => t === 'Alpha used RAGE').length, 4,
    'a called RAGE rages on as RAGE');
  assert.strictEqual(duelTexts(g, 4).filter((t) => t === 'Alpha used METRONOME').length, 1);
  assert.ok(duelSaid(g, 5, 'Alpha unleashed energy'));
  // `.UnleashEnergy` prints no used-move line (R1b): the animation names it.
  const e5 = duelEvents(g, 5);
  const at5 = e5.findIndex((e) => e.t === 'msg' && e.text === 'Alpha unleashed energy');
  assert.deepStrictEqual([e5[at5 + 1].t, e5[at5 + 1].text], ['anim', 'BIDE'],
    'the called BIDE unleashes as BIDE, not METRONOME');
  const t6 = duelTexts(g, 6);
  assert.strictEqual(t6.filter((t) => t === 'Alpha used MIRROR_MOVE').length, 2);
  assert.strictEqual(t6[t6.length - 1], 'Alpha used FLY', 'turn 3: the mirrored FLY, not MIRROR MOVE');
  assert.strictEqual(duelSeat(g, 6, 3, 3).hp, 381, '...and it lands');
  assert.strictEqual(duelSeat(g, 6, 3, 0).pp, '58', 'MIRROR MOVE spent on turns 1 and 2 only');
});

test('LEECH SEED: times the toxic counter, and a poison or burn knockout still feeds', () => {
  const g = 'g1_leech_toxic';
  assert.deepStrictEqual(duelHits(g, 1).filter((h) => h.startsWith('3:')),
    ['3:25:375', '3:50:325', '3:75:250', '3:100:150'], 'toxic x1, seed x2, toxic x3, seed x4');
  assert.strictEqual(duelSeat(g, 1, 1, 0).hp, 350, 'the seeder gets the seed x2');
  assert.strictEqual(duelSeat(g, 1, 2, 3).tox, 5, 'the counter climbs twice a turn');
  for (const at of [2, 3]) {
    assert.strictEqual(duelSeat(g, at, 1, 3).hp, 0, `battle ${at}: the tick knocks Beta out`);
    assert.strictEqual(duelSeat(g, at, 1, 0).hp, 325, '...and Alpha is still fed 25');
  }
  assert.deepStrictEqual([duelSeat(g, 4, 1, 3).hp, duelSeat(g, 4, 1, 3).sub], [350, 50],
    'both ticks pass the doll');
});

test('a confusion self-hit behind a doll hits the opposing doll, and clears BattleStatus1', () => {
  const g = 'g1_self_hit';
  const seat = (at, turn, slot) => duelSeat(g, at, turn, slot);
  assert.deepStrictEqual([seat(1, 1, 0).hp, seat(1, 1, 0).sub], [400, 30], 'Alpha and its doll untouched');
  assert.deepStrictEqual([seat(1, 1, 3).sub, seat(1, 1, 3).zero], [0, true], "Beta's 10 doll takes the 10, at 0");
  assert.ok(duelSaid(g, 2, "Beta's substitute broke"), 'a 5 doll breaks');
  assert.deepStrictEqual(duelHits(g, 3), [], 'no doll across: nothing moves');
  assert.strictEqual(seat(3, 1, 0).hp, 400);
  assert.deepStrictEqual([seat(4, 1, 0).hp, seat(4, 1, 3).sub], [390, 10], 'no own doll: Alpha takes it');
  assert.deepStrictEqual([seat(5, 1, 0).charging, seat(5, 1, 0).invuln], [false, false],
    'the charge and the vanish are gone');
  assert.strictEqual(seat(5, 2, 0).charging, false, 'turn 2 is no forced release');
  assert.ok(!duelHits(g, 5).some((h) => h.startsWith('3:')), '...no FLY lands on Beta');
  assert.strictEqual(seat(6, 1, 0).thrash, false, 'the thrash is gone');
  assert.ok(!duelSaid(g, 6, 'Alpha became confused'), '...so it never ends in confusion');
  assert.strictEqual(seat(7, 1, 0).bide, false, 'the Bide is gone');
  assert.strictEqual(seat(7, 1, 3).hp, 400, 'nothing unleashed');
});

// ------------------------------------------------------------------
// R1b: the Lua driver's `fights` scenarios, asserted on the JS half (the
// parity tests above hold the Lua half to the same stream;
// tests/battle_sim_turn.lua's R1b section forces the bytes and counts them).
// ------------------------------------------------------------------

const r1Seat = (name, at, turn, slot, mon = 1) => jsRun(name).probes
  .find((p) => p.at === at && p.turn === turn && p.slot === slot && p.mon === mon);
const r1Row = (name, at, turn) => jsRun(name).probes
  .find((p) => p.at === at && p.turn === turn && p.rng !== undefined);
const r1End = (name, at) => jsRun(name).probes.find((p) => p.at === at && p.outcome !== undefined);
const r1Level = (name, at, turn) => jsRun(name).probes
  .find((p) => p.at === at && p.turn === turn && p.levelUp !== undefined).levelUp;

test('Transform: 5 PP copies, undone at the switch-out, and the species byte behind a crit', () => {
  const g = 'g1_transform_restore';
  assert.deepStrictEqual([r1Seat(g, 1, 1, 0).moves, r1Seat(g, 1, 1, 0).types], ['thump:5,chop:5', '2'],
    "Beta's moves at 5 PP each, Beta's type");
  assert.deepStrictEqual([r1Seat(g, 1, 2, 0).moves, r1Seat(g, 1, 2, 0).types, r1Seat(g, 1, 2, 0).transformed],
    ['morph:59,tap:60', '1', false], 'switched out: its own moves, PP and type back');
  assert.ok(duelSaid(g, 1, 'Alpha used tap'), 'and back in, its own move');
  // Alpha's crits on the transformed wild Beta: GetEnemyMonStat, a CalcStat
  // over Alpha's base Defense 70 and DV 9 at Beta's level 30 (52), against
  // the party stat 40 without K7.
  assert.deepStrictEqual([duelHits(g, 2)[1], duelHits(g, 3)[1]], ['3:20:355', '3:26:349'],
    'the CalcStat Defense 52 against the party 40');
  assert.ok(duelSaid(g, 2, 'Beta used slash') && duelHits(g, 2)[2] === '0:52:348',
    "the copied slash, critting off Alpha's base Speed, with the CalcStat Attack");
});

test('Haze: every battler reset, the target cured and its move gone', () => {
  const g = 'g1_haze_full';
  const a = r1Seat(g, 1, 1, 0);
  const b = r1Seat(g, 1, 1, 3);
  assert.deepStrictEqual([a.status, a.stages, a.flags], ['poison', '0/0/0/0/0/0', ''],
    'the user: Bad Poison gone, stages and Reflect / Focus Energy gone');
  assert.deepStrictEqual([b.status, b.conf, b.flags, b.disable, b.stages], ['', 0, '', '', '0/0/0/0/0/0'],
    'the target: cured, unconfused, no Mist / X Accuracy / seed / Disable');
  // Two turns each: the thump comes on turn 2 only.
  assert.strictEqual(duelTexts(g, 1).filter((x) => x === 'Beta used thump').length, 1,
    'the sleeping target woke and lost its turn-1 move');
  assert.strictEqual(duelTexts(g, 2).filter((x) => x === 'Beta used thump').length, 1,
    'the frozen one likewise');
  assert.deepStrictEqual([r1Seat(g, 3, 1, 1).conf, r1Seat(g, 3, 1, 1).stages], [0, '0/0/0/0/0/0'],
    'a 2v2: the partner of the user too');
  assert.deepStrictEqual([r1Seat(g, 3, 1, 4).status, r1Seat(g, 3, 1, 4).flags], ['poison', ''],
    "...and the target's partner: plain poison, unseeded");
  assert.strictEqual(r1Seat(g, 3, 1, 3).status, '', 'only the target is cured');
});

test("StatModifierDownEffect's primary: the computer's miss byte, then Mist and a doll before the accuracy byte", () => {
  const g = 'g1_stat_drop_primary';
  assert.ok(duelSaid(g, 1, 'But it failed'), "the computer's growl misses on its own byte");
  assert.strictEqual(r1Seat(g, 2, 4, 0).stages.split('/')[0], '-4', 'a link fight: four growls, four drops');
  assert.strictEqual(r1Row(g, 4, 1).rng, 8303, 'into a doll: no byte at all (the seed untouched)');
  assert.strictEqual(r1Row(g, 6, 1).rng, 8305, 'SWORDS DANCE at +6: Nothing happened, no byte');
  assert.ok(duelSaid(g, 6, 'Nothing happened'));
});

test('ClearHyperBeam: a freeze on the player\'s turn and a trap that starts', () => {
  const g = 'g1_clear_recharge';
  assert.ok(!duelSaid(g, 1, 'Beta must recharge'), "the player's freeze clears the wild beam's recharge");
  assert.ok(duelSaid(g, 2, 'Alpha must recharge'), "the computer's freeze does not");
  assert.ok(!duelSaid(g, 3, 'Alpha must recharge'), 'a link fight: both sides are the player');
  assert.ok(!duelSaid(g, 4, 'Alpha must recharge') && duelSaid(g, 4, 'Beta missed'),
    'a Wrap that misses has cleared it already');
});

test("the computer's item and switch in its own turn slot", () => {
  const g = 'g1_computer_turn_slot';
  const kinds = (at) => duelEvents(g, at).filter((e) => ['damage', 'item', 'switch'].includes(e.t))
    .map((e) => e.t);
  assert.deepStrictEqual(kinds(1), ['damage', 'item'], 'a slower trainer: the hit, then its potion');
  assert.deepStrictEqual(kinds(2), ['switch', 'damage'], 'a faster one switches first, the hit finds Delta');
  assert.strictEqual(duelHits(g, 2)[0], '3:5:395');
  assert.deepStrictEqual(kinds(3), ['damage', 'switch'], 'a knocked-out one never switches; its send-out follows');
  assert.notStrictEqual(r1Row(g, 4, 1).rng, r1Row(g, 1, 1).rng, 'a Speed tie draws its byte for the item too');
});

test('asleep, the selection is last turn\'s, and MIRROR MOVE finds a used move zeroed', () => {
  const g = 'g1_asleep_selection';
  const t = duelTexts(g, 1);
  const second = t.indexOf('Beta used thump');
  assert.ok(second > 0 && t.indexOf('Alpha is fast asleep', second) > second,
    "turn 2: the sleeping Alpha's QUICK ATTACK moves in tap's bracket, after Beta");
  assert.ok(t.includes('But it failed'), 'turn 3: Beta mirrors nothing');
});

test('Struggle with a move disabled reads the raw PP bytes', () => {
  assert.strictEqual(duelTexts('g1_struggle_disabled', 1).filter((x) => x === 'Alpha used STRUGGLE').length, 2);
});

test('DISABLE: a random slot, 1-8 steps in its own turn, a miss fails, a doll does not stop it', () => {
  const g = 'g1_disable';
  assert.ok(duelSaid(g, 1, 'chop was disabled') && duelSaid(g, 1, "Beta's disabled no more!"));
  assert.ok(duelSaid(g, 3, 'chop was disabled'), "the wild target's 0-PP move is pickable");
  assert.deepStrictEqual(duelTexts(g, 4).slice(0, 2), ['Alpha used lock', 'But it failed']);
  assert.ok(duelSaid(g, 4, 'thump was disabled'), '...and the doll lets the second through');
});

test('PoisonEffect turns a Poison type away; TOXIC badly poisons', () => {
  const g = 'g1_poison_primary';
  assert.ok(duelSaid(g, 1, "It didn't affect Beta"));
  assert.strictEqual(r1Seat(g, 2, 1, 3).status, 'poison');
  assert.deepStrictEqual([r1Seat(g, 3, 3, 3).status, r1Seat(g, 3, 3, 3).hp], ['toxic', 250],
    '25, 50, 75: the counter climbs');
  assert.ok(duelSaid(g, 4, "It didn't affect Beta"), 'a doll');
});

test('the multi-hit lines, by seat', () => {
  const g = 'g1_multihit_lines';
  assert.ok(duelSaid(g, 1, 'Hit the enemy 2 times!'));
  assert.ok(duelSaid(g, 2, 'Hit 2 times!'));
  assert.ok(!duelTexts(g, 3).some((x) => x.startsWith('Hit ')), 'a knockout says nothing');
  assert.deepStrictEqual(duelHits(g, 4).slice(0, 2), ['3:1:399', '3:1:398'], 'power 0 still hits');
});

test('K9: the level-up rebuild, and what is refused', () => {
  const g = 'g1_level_up';
  assert.deepStrictEqual([1, 2, 3, 4, 5].map((t) => r1Level(g, 1, t)), [true, true, false, false, false]);
  assert.strictEqual(r1Level(g, 2, 1), false, 'a link fight earns nothing');
  const a = r1Seat(g, 1, 1, 0);
  assert.deepStrictEqual([a.level, a.maxHp, a.party, a.cur], [21, 63, '63/52/94/57', '52/58/105/64'],
    'party, then stage, burn and every badge');
  const gamma = r1Seat(g, 1, 2, 0, 2);
  assert.deepStrictEqual([gamma.level, gamma.maxHp, gamma.hp, gamma.party], [16, 40, 40, '23/23/23/30'],
    'the bench, from its K7 sheet');
});

test('the crash, and the set-damage moves', () => {
  const g = 'g1_crash_and_set_damage';
  assert.strictEqual(duelHits(g, 1)[0], '0:1:399', 'a 1 HP crash');
  assert.strictEqual(duelHits(g, 2)[0], '3:1:400', "behind its own doll: the opposing doll takes it");
  assert.ok(duelSaid(g, 3, "It doesn't affect Beta") && duelHits(g, 3)[0] === '0:1:399');
  assert.deepStrictEqual(duelHits(g, 4).filter((h) => h.startsWith('3:')), ['3:30:370', '3:20:350'],
    'SEISMIC TOSS and SONICBOOM through a 0x chart');
  assert.deepStrictEqual(duelHits(g, 5).filter((h) => h.startsWith('3:')), ['3:40:360', '3:180:180']);
});

test('OHKO on a tie; full paralysis keeps the vanish', () => {
  assert.strictEqual(r1End('g1_ohko_paralysis', 1).winner, 'p1', 'the tie lands');
  const s = r1Seat('g1_ohko_paralysis', 2, 1, 0);
  assert.deepStrictEqual([s.charging, s.invuln], [false, true]);
  assert.ok(duelSaid('g1_ohko_paralysis', 2, 'But it failed'), "Beta's thump finds nobody");
});

test('the trap starts before the hit', () => {
  const g = 'g1_trap_start';
  assert.notStrictEqual(r1Seat(g, 1, 1, 3).trapped, '', 'a doll that holds keeps it');
  assert.strictEqual(r1Seat(g, 2, 1, 3).trapped, '', 'a miss takes it back');
  assert.strictEqual(r1Seat(g, 3, 1, 3).trapped.split('/')[1], '0', 'an immunity leaves it at 0');
  assert.notStrictEqual(r1Seat(g, 4, 1, 3).trapped, '', 'a doll that breaks keeps it too');
});

test('MIRROR MOVE copies the move used, not the caller', () => {
  assert.ok(duelSaid('g1_mirror_used', 1, 'Alpha used THRASH'));
  assert.strictEqual(r1Seat('g1_mirror_used', 1, 1, 0).used, 'THRASH');
});

test('Pay Day on an escape, but not on RUN', () => {
  const g = 'g1_pay_day_escape';
  assert.deepStrictEqual([1, 2, 3].map((at) => r1End(g, at).payDay), [80, 40, 0]);
  assert.deepStrictEqual([1, 2, 3].map((at) => r1End(g, at).reason), ['run', 'run', 'run']);
});

test('no hit test for a power-0 routine that has none', () => {
  const g = 'g1_no_hit_test';
  assert.strictEqual(r1Row(g, 1, 1).rng, 9701, 'turn 1: nothing drawn');
  assert.strictEqual(r1Row(g, 1, 3).rng, r1Row(g, 1, 2).rng, 'turn 3: the GROWL fails before a byte');
  assert.ok(duelSaid(g, 1, "Alpha's ATTACK rose"), 'SWORDS DANCE lands');
});
