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
    id: 'mn', mode: '1v1', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
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
    id, pp: 60, power, accuracy: 255,
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

  // Every other sentence that names a move, all four of them, because they are
  // four separate call sites and each one used to spell the id.
  assert.ok(said.includes('THUMP HIT was disabled'), 'Disable landing names the move');
  assert.ok(said.includes('THUMP HIT is disabled'), 'and so does the refusal it causes');
  assert.ok(said.includes('THUMP HIT is no longer disabled'), 'and so does it wearing off');
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
    assert.strictEqual(hitOn(bare, 3), 17, 'the unbadged attack lands for 17');
    assert.strictEqual(hitOn(exchange(mode, HIT, {}), 3), 17,
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
    assert.strictEqual(hitOn(exchange(mode, {}, {}), 3), 17, 'unbadged, the same 17');
    // 88 -> floor(88 * 9 / 8) = 99 Attack; BattleSim reaches the same 19.
    assert.strictEqual(hitOn(exchange(mode, HIT, {}), 3), 19,
      "BOULDERBADGE raises side a's physical damage to 19");
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
