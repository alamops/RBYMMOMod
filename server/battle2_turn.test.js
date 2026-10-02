#!/usr/bin/env node
'use strict';

/*
 * Cross-runtime parity suite for the **Gen 2** turn machine:
 * `lib/battle2/Turn.js`.
 *
 * The sibling suite (battle2_vectors.test.js) pins the *formulas* against a
 * shared vector pack. A vector cannot express what this file is for: the order
 * the questions get asked in, which of them are asked at all, and therefore how
 * many bytes come off the RNG before the next one. Two runtimes can agree on
 * every damage number and still fight two different battles from one seed if
 * one of them draws a crit byte for a move that missed.
 *
 * So the expected event streams are not written here and not computed here.
 * They come from luajit actually running src/BattleSim2/Turn.lua over the same
 * scenarios, spawned by `tests/drivers/battle2_turn_parity.lua`. When luajit is
 * not on PATH the same driver's committed output --
 * tests/fixtures/battle2_turn_parity.json -- stands in, and when luajit *is*
 * present both are checked, so a fixture that drifted behind the Lua is a
 * failure rather than a suite that quietly stopped testing anything.
 *
 * Scope is the three referee rules docs/plans/gen2-new-battle-system.md brought
 * across from the Gen 1 twin -- experience, the replace phase, and stolen-KO
 * retargeting -- because those are what is new in `lib/battle2/` and therefore
 * what can drift. Everything a Gen 2 fight shares with Gen 1 is already pinned
 * by battle_turn.test.js on the Gen 1 pair.
 * The badge scenarios add one more referee rule both twins must apply alike:
 * an uploaded badge set counts only on side a of a fight against the computer
 * (Turn.BADGE_MODES), never in a link battle and never on side b -- and what it
 * does there is Crystal's: the stat boosts, Glacier's Sp. Def tail, the 999 cap
 * and DoBadgeTypeBoosts.
 * The fidelity scenarios (docs/plans/gen12-referee-fidelity.md) pin the
 * pokecrystal rules both twins now share: the stage-then-badge stat order, the
 * crit stage comparison, TruncateHL_BC's loop and link wrap, per-side screens,
 * the confusion self-hit's quirks, typeless Struggle, a Metronome call made
 * with the last PP, and the move-priority brackets.
 *
 * The scenarios below are the JS half of that pair and have to stay a literal
 * mirror of the driver's: same seeds, same parties, same choices in the same
 * order. A change to one is a change to both, and regenerating the fixture is
 * the third step:
 *
 *   luajit tests/drivers/battle2_turn_parity.lua . > tests/fixtures/battle2_turn_parity.json
 *
 * ROM-free by construction: every species and move named here is invented.
 *
 * Run: node --test server/battle2_turn.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { Turn, events: Events } = require('./lib/battle2');

const ROOT = path.join(__dirname, '..');
const DRIVER = path.join(ROOT, 'tests', 'drivers', 'battle2_turn_parity.lua');
const FIXTURE = path.join(ROOT, 'tests', 'fixtures', 'battle2_turn_parity.json');

// ------------------------------------------------------------------
// fixtures -- mirrored line for line from the Lua driver
// ------------------------------------------------------------------

function mv(id, power, accuracy, type, pp) {
  return { id, pp: pp === undefined ? 60 : pp, power, accuracy, type, effect: 0, chance: 0 };
}

// Gen 2 sheet dialect throughout: spe / spa / spd, never the Gen 1
// spd=Speed / spc=Special pair, so `copyMon` takes the Gen 2 branch.
function mn(o) {
  return {
    species: o.species,
    level: o.level === undefined ? 20 : o.level,
    hp: o.hp,
    maxHp: o.maxHp === undefined ? 100 : o.maxHp,
    status: o.status,
    types: o.types,
    stats: {
      atk: o.atk === undefined ? 40 : o.atk,
      def: o.def === undefined ? 40 : o.def,
      spe: o.spe === undefined ? 40 : o.spe,
      spa: o.spa === undefined ? 40 : o.spa,
      spd: o.spd === undefined ? 40 : o.spd,
    },
    moves: o.moves,
    stages: o.stages,
    confusion: o.confusion,
    focusEnergy: o.focusEnergy,
  };
}

// A move with an effect id (lib/battle2/Effects.js numbering), which `mv`
// leaves at 0.
function fx(id, power, type, effect, pp) {
  return {
    id, pp: pp === undefined ? 60 : pp, power, accuracy: 255, type, effect, chance: 0,
  };
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

const SCENARIOS = [];
const scenario = (name, run) => SCENARIOS.push({ name, run });

// 1. a wild fight that ends in a KO: one owner seat, one payout, and the
//    rngState afterwards proves the payout drew nothing.
scenario('exp_wild', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'expw', mode: 'wild', seed: 4242, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80, moves: [thump()] })] }],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 60, spe: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 8; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('wild', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// 2. coop_wild: two owner seats standing at the KO, so two payouts in
//    field-slot order with a divisor of two.
scenario('exp_coop', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'expc', mode: 'coop_wild', seed: 5150, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 90, spe: 70, moves: [thump()] })] },
      ],
      b: [{ playerId: 'wild', name: 'Wild', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [thump()] })] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 8; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    battle.autoPick('wild');
    drainInto(battle, events);
  }
  return battle;
});

// 3. the replace phase: a foe seat with a bench falls, is solicited by field
//    slot, answers, and only then does the turn advance. The party index on
//    `switch` / `send` is what stops a client re-fielding the fallen copy of a
//    duplicated species.
scenario('replace', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'rep', mode: 'coop_npc', seed: 6161, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 95, spe: 90, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 95, spe: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        mn({ species: 'Beta', maxHp: 30, spe: 10, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [thump()] }),
      ] }],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 4; i += 1) {
    if (battle.outcome()) break;
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    // Called twice on purpose: the first files the ordinary turn's answer, the
    // second the replacement the KO opened. A loop that stopped after one would
    // leave the phase open, which is what `fillNpcChoices` does not.
    battle.autoPick('npc');
    battle.autoPick('npc');
    drainInto(battle, events);
  }
  return battle;
});

// 4. a stolen KO. `fast` empties foe seat 2; `slow` aimed there too and must
//    swing at seat 3 instead of fizzling -- and must do it having drawn the
//    same bytes the Lua twin drew.
scenario('retarget', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'ret', mode: 'coop_pvp', seed: 7272, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'fast', name: 'Fast', mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 200, spe: 99, moves: [thump()] })] },
        { playerId: 'slow', name: 'Slow', mons: [
          mn({ species: 'Gamma', maxHp: 300, atk: 200, spe: 90, moves: [thump()] })] },
      ],
      b: [
        { playerId: 'foeA', name: 'FoeA', mons: [
          mn({ species: 'Beta', maxHp: 1, spe: 5, moves: [thump()] })] },
        { playerId: 'foeB', name: 'FoeB', mons: [
          mn({ species: 'Delta', maxHp: 400, spe: 5, moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('fast', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('slow', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('foeA', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('foeB', { action: 'fight', move: 0, target: 0 });
  drainInto(battle, events);
  return battle;
});

// 5. a whole trapping chain. Gen1's 2..5 counter is a *total* attack count, so
//    the turn Wrap lands on deals the move's damage and no residual on top of
//    it; every later turn is one attack, forced on both seats and therefore
//    ticked rather than submitted. The tail also pins that a referee-filled
//    answer cannot be cancelled away -- silently, so what shows up on the wire
//    is the absence of an `unchose`.
scenario('trap_chain', (events) => {
  const wrap = () => ({ id: 'wrap', pp: 60, power: 5, accuracy: 255, type: 0,
    effect: 42, chance: 0 });
  const battle = build({
    id: 'trp', mode: '1v1', seed: 9999,
    choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 400, spe: 120, moves: [wrap()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, def: 200, spe: 1,
          moves: [mv('tap', 40, 255, 0)] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  for (let step = 1; step <= 10; step += 1) {
    battle.tick(step);
    drainInto(battle, events);
  }
  battle.submitChoice('p2', { action: 'cancel' });
  battle.submitChoice('p2', { action: 'switch', slot: 0 });
  drainInto(battle, events);
  return battle;
});

// the display name a sheet carries (PROTOCOL 26), and the id it falls back to
// when it carries none. The Gen 1 pair next door explains the shape; this is
// the Gen 2 twin of it, because BattleSim2 / lib/battle2 narrate a move from
// their own copies of the same five call sites.
scenario('move_names', (events) => {
  // `mv` writes effect=0, so the two effect moves are built by hand. 86 is
  // DISABLE_EFFECT and 82 is MIMIC_EFFECT (lib/battle2/Effects.js).
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
        mn({ species: 'Alpha', maxHp: 400, spe: 90,
             moves: [swipe(), lockdown(), copycat()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 400, spe: 10,
             moves: [thump(), nudge()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 0 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 0 });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 2 });
  battle.submitChoice('p2', { action: 'fight', move: 1 });
  drainInto(battle, events);
  for (let i = 0; i < 5; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 2 });
    battle.submitChoice('p2', { action: 'fight', move: 1 });
    drainInto(battle, events);
  }
  return battle;
});

// uploaded badge sets, and where the referee lets them count (Turn.BADGE_MODES
// / Turn.BADGE_SIDE: side a of a fight against the computer, never a link
// battle -- Crystal's BadgeStatBoosts returns early in one). Every seat holds
// all sixteen Gold badges and the ruleset names the types, so a leak would
// show as a stat boost or a type boost. Speeds sit a step apart so a PLAIN
// that leaked would reorder the field rather than merely move a damage number,
// and the npc fight carries a special move so GLACIER (Sp. Atk) and VOLCANO's
// type boost are both read. `badges_link` and `badges_coop_pvp` fight as
// though nobody held a badge; `badges_npc` boosts side a and ignores side b's
// upload; `badges_gold` drives the rules a plain fight never reaches -- the
// 999 cap, Glacier's Sp. Def tail, a type boost on a move with no stat badge
// behind it, and a confusion self-hit on boosted stats.
const allBadges = () => ({
  ZEPHYR: true, HIVE: true, PLAIN: true, FOG: true,
  MINERAL: true, STORM: true, GLACIER: true, RISING: true,
  BOULDER: true, CASCADE: true, THUNDER: true, RAINBOW: true,
  SOUL: true, MARSH: true, VOLCANO: true, EARTH: true,
});

// Chart index 0 is NORMAL (PLAIN's type), 1 FIRE (VOLCANO's, and Special),
// 2 BUG (HIVE's).
const TYPE_IDS = ['NORMAL', 'FIRE', 'BUG'];

scenario('badges_link', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'bl', mode: '1v1', seed: 2718, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: TYPE_IDS,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: allBadges(), mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 60, spe: 40, moves: [thump()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, atk: 60, spe: 42, moves: [thump()] })] }],
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
    typeIds: TYPE_IDS,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: allBadges(), mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, spe: 40, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', badges: allBadges(), mons: [
          mn({ species: 'Gamma', maxHp: 300, atk: 55, spe: 30, moves: [thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, spe: 42, moves: [thump()] })] },
        { playerId: 'b2', name: 'Bea', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 300, atk: 55, spe: 34, moves: [thump()] })] },
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
    typeIds: TYPE_IDS,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: allBadges(), mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, spe: 40, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', badges: allBadges(), mons: [
          mn({ species: 'Gamma', maxHp: 300, spa: 60, spd: 50, spe: 30,
               moves: [zap()] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, spe: 42, moves: [thump()] })] },
        { playerId: 'n2', name: 'NpcB', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 300, spa: 60, spd: 50, spe: 37,
               moves: [zap()] })] },
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

scenario('badges_gold', (events) => {
  const bite = () => mv('bite', 40, 255, 2);
  const thump = () => mv('thump', 40, 255, 0);
  const zap = () => mv('zap', 40, 255, 1);
  // Abe is confused, so his turns spend the confusion byte and, on this seed,
  // hit himself on MINERAL's boosted Defense.
  const abe = mn({ species: 'Gamma', maxHp: 300, atk: 50, def: 40,
    spa: 227, spd: 50, spe: 30, moves: [thump()] });
  abe.confusion = 4;
  const battle = build({
    id: 'bg', mode: 'coop_npc', seed: 2027, choiceTimeout: 60, reconnectGrace: 60,
    specialTypes: [1],
    typeIds: TYPE_IDS,
    sides: {
      a: [
        // 950 Attack under ZEPHYR is the 999 cap; HIVE type-boosts the BUG
        // move, which no stat badge stands behind.
        { playerId: 'a1', name: 'Ann', badges: { ZEPHYR: true, PLAIN: true, HIVE: true },
          mons: [mn({ species: 'Alpha', maxHp: 300, atk: 950, spe: 40,
            moves: [bite()] })] },
        // Sp. Atk 227 boosts to 255 under GLACIER, which Glacier's tail reads
        // as a Sp. Def boost too; MINERAL stands behind Defense.
        { playerId: 'a2', name: 'Abe', badges: { GLACIER: true, MINERAL: true },
          mons: [abe] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', badges: allBadges(), mons: [
          mn({ species: 'Beta', maxHp: 400, spa: 70, spe: 42, moves: [zap()] })] },
        { playerId: 'n2', name: 'NpcB', badges: allBadges(), mons: [
          mn({ species: 'Delta', maxHp: 999, def: 600, atk: 70, spe: 37,
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
    battle.submitChoice('n1', { action: 'fight', move: 0, target: 1 });
    battle.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
    drainInto(battle, events);
  }
  return battle;
});

// CalcPlayerStats' order: the stage, then the badge (see the driver).
scenario('stage_badge_order', (events) => {
  const slam = () => mv('slam', 100, 255, 0);
  const zap = () => mv('zap', 60, 255, 1);
  const battle = build({
    id: 'sb', mode: 'coop_npc', seed: 4096, choiceTimeout: 60, reconnectGrace: 60,
    // Index 0 names DARK, a type no held badge boosts, so PLAIN moves Speed
    // and nothing else.
    specialTypes: [1], typeIds: ['DARK', 'FIRE'],
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', badges: { ZEPHYR: true, PLAIN: true },
          mons: [mn({ species: 'Alpha', level: 50, maxHp: 400, atk: 100, spe: 100,
            types: [2], stages: { atk: -1, spe: -1 },
            moves: [slam()] })] },
        { playerId: 'a2', name: 'Abe', badges: { GLACIER: true },
          mons: [mn({ species: 'Gamma', level: 50, maxHp: 400, spa: 152, spd: 100,
            spe: 30, types: [2], stages: { spa: 1 },
            moves: [zap()] })] },
      ],
      b: [
        { playerId: 'n1', name: 'NpcA', mons: [
          mn({ species: 'Beta', level: 50, maxHp: 400, def: 20, spe: 73,
            types: [2], moves: [slam()] })] },
        { playerId: 'n2', name: 'NpcB', mons: [
          mn({ species: 'Delta', level: 50, maxHp: 400, spa: 120, spe: 20,
            types: [2], moves: [zap()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
  battle.submitChoice('n1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('n2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  return battle;
});

// CheckDamageStatsCritical, both ways (see the driver).
scenario('crit_stages', (events) => {
  const slash = () => {
    const m = mv('slash_hit', 70, 255, 0, 30);
    m.highCrit = true;
    return m;
  };
  const wall = () => fx('wall_up', 0, 1, 65, 20);
  const battle = build({
    id: 'cr', mode: '1v1', seed: 2, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 30, maxHp: 400, atk: 80, def: 80, spe: 60,
          types: [2], stages: { atk: 1, def: 2 }, moves: [slash(), wall()] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 30, maxHp: 400, atk: 80, def: 80, spe: 50,
          types: [2], focusEnergy: true, moves: [slash(), wall()] })] }],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('p1', { action: 'fight', move: 1 });
  battle.submitChoice('p2', { action: 'fight', move: 1 });
  drainInto(battle, events);
  for (let i = 0; i < 3; i += 1) {
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice('p2', { action: 'fight', move: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// TruncateHL_BC's loop against its single link pass (see the driver).
function truncation(mode, id, foeId) {
  return (events) => {
    const thump = () => mv('thump', 70, 255, 0);
    const wall = () => fx('wall_up', 0, 1, 65, 20);
    const battle = build({
      id, mode, seed: 31337, choiceTimeout: 60, reconnectGrace: 60,
      sides: {
        a: [{ playerId: 'p1', name: 'Ann', mons: [
          mn({ species: 'Alpha', level: 30, maxHp: 400, atk: 200, spe: 50,
            types: [2], moves: [thump()] })] }],
        b: [{ playerId: foeId, name: 'Bob', mons: [
          mn({ species: 'Beta', level: 30, maxHp: 400, def: 600, spe: 60,
            types: [2], moves: [wall(), thump()] })] }],
      },
    });
    drainInto(battle, events);
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice(foeId, { action: 'fight', move: 0 });
    drainInto(battle, events);
    battle.submitChoice('p1', { action: 'fight', move: 0 });
    battle.submitChoice(foeId, { action: 'fight', move: 1 });
    drainInto(battle, events);
    return battle;
  };
}
scenario('truncate_wild', truncation('wild', 'tw', 'wild'));
scenario('truncate_link', truncation('1v1', 'tl', 'p2'));

// Screens belong to the SIDE (see the driver).
scenario('screens_side', (events) => {
  const thump = () => mv('thump', 50, 255, 0);
  const wall = () => fx('wall_up', 0, 1, 65, 20);
  const haze = () => fx('reset_fog', 0, 1, 25, 20);
  const battle = build({
    id: 'ss', mode: 'coop_pvp', seed: 8080, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 999, spe: 90, types: [2],
            moves: [wall(), thump()] }),
          mn({ species: 'Gamma', maxHp: 999, spe: 85, types: [2],
            moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Eta', maxHp: 999, spe: 80, types: [2],
            moves: [thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 999, atk: 60, spe: 50, types: [2],
            moves: [thump(), haze()] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 999, atk: 60, spe: 40, types: [2],
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  // Ann: Reflect, Reflect again, switch to Gamma, then Gamma's one hit. Bob:
  // a hit on Abe every turn but the fourth, which is Haze.
  for (let turn = 1; turn <= 6; turn += 1) {
    if (turn === 3) {
      battle.submitChoice('a1', { action: 'switch', slot: 1 });
    } else {
      battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
    }
    battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
    battle.submitChoice('b1', { action: 'fight', move: turn === 4 ? 1 : 0, target: 1 });
    battle.submitChoice('b2', { action: 'fight', move: 0, target: 0 });
    drainInto(battle, events);
  }
  return battle;
});

// HitConfusion on both sides (see the driver).
scenario('self_hit', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const wall = () => fx('wall_up', 0, 1, 65, 20);
  const boom = () => fx('big_boom', 250, 0, 7, 5);
  const battle = build({
    id: 'sh', mode: 'coop_pvp', seed: 5, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 300, atk: 60, def: 60, spe: 50,
            types: [2], confusion: 4, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 300, spe: 90, types: [2],
            moves: [wall()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 300, atk: 60, def: 60, spe: 40,
            types: [2], confusion: 4, moves: [boom()] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 300, spe: 30, types: [2],
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  return battle;
});

// Struggle is typeless (see the driver).
scenario('struggle_typeless', (events) => {
  const battle = build({
    id: 'st', mode: '1v1', seed: 5555, choiceTimeout: 60, reconnectGrace: 60,
    chart: [[100, 0], [100, 100]],
    typeIds: ['NORMAL', 'GHOST'],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 30, maxHp: 300, atk: 80, spe: 60,
          types: [0], moves: [mv('thump', 40, 255, 0, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 30, maxHp: 300, def: 60, spe: 50,
          types: [1], moves: [mv('haunt', 40, 255, 1)] })] }],
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

// Metronome with its last PP calls a plain hit, not Struggle (see the driver).
scenario('metronome_last_pp', (events) => {
  const battle = build({
    id: 'mt', mode: '1v1', seed: 6060, choiceTimeout: 60, reconnectGrace: 60,
    metronomePool: [mv('pool_hit', 60, 255, 1, 10)],
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', level: 30, maxHp: 300, atk: 80, spe: 60,
          types: [2], moves: [fx('wave_finger', 0, 0, 83, 1)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', level: 30, maxHp: 300, def: 60, spe: 50,
          types: [2], moves: [mv('thump', 40, 255, 0)] })] }],
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

// GetMovePriority's brackets on a four-seat field (see the driver).
scenario('priority', (events) => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'pr', mode: 'coop_pvp', seed: 9090, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 300, spe: 10, types: [2],
            moves: [mv('QUICK_ATTACK', 40, 255, 0)] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 300, spe: 99, types: [2],
            moves: [fx('VITAL_THROW', 70, 0, 17), thump()] })] },
      ],
      b: [
        { playerId: 'b1', name: 'Bob', mons: [
          mn({ species: 'Beta', maxHp: 300, spe: 5, types: [2],
            moves: [mv('PROTECT', 0, 255, 0), mv('EXTREMESPEED', 80, 255, 0)] })] },
        { playerId: 'b2', name: 'Bea', mons: [
          mn({ species: 'Delta', maxHp: 300, spe: 50, types: [2],
            moves: [thump()] })] },
      ],
    },
  });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 4 });
  battle.submitChoice('b1', { action: 'fight', move: 0, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 1, target: 4 });
  battle.submitChoice('b1', { action: 'fight', move: 1, target: 0 });
  battle.submitChoice('b2', { action: 'fight', move: 0, target: 1 });
  drainInto(battle, events);
  return battle;
});

// ------------------------------------------------------------------
// running both halves
// ------------------------------------------------------------------

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
  const slim = { battle: out.battle, outcome: out.outcome, reason: out.reason };
  if (out.winners) slim.winners = out.winners;
  if (out.losers) slim.losers = out.losers;
  return slim;
}

function runJs() {
  return SCENARIOS.map(({ name, run }) => {
    const events = [];
    batches = [];
    const battle = run(events);
    return canonical({
      name,
      events,
      batches,
      outcome: slimOutcome(battle.outcome()),
      snapshot: snapshotDigest(battle),
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
  assert.strictEqual(jsRuns.length, 19, 'the JS half built every scenario');
  assert.ok(
    luaRuns || fixture,
    'neither luajit nor tests/fixtures/battle2_turn_parity.json is available -- '
    + 'install luajit or regenerate the fixture with '
    + '`luajit tests/drivers/battle2_turn_parity.lua . > tests/fixtures/battle2_turn_parity.json`',
  );
});

test('JS matches the Lua Gen2 turn machine, event for event', async (t) => {
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
      // that differs is the entire bug report -- a deep-equal on 60 events
      // prints all 60 and names none of them.
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
    'the fixture has drifted behind src/BattleSim2/Turn.lua -- regenerate with '
    + '`luajit tests/drivers/battle2_turn_parity.lua . > tests/fixtures/battle2_turn_parity.json`',
  );
});

// ------------------------------------------------------------------
// the rules, stated as claims rather than diffs
// ------------------------------------------------------------------

const expOf = (run) => run.events.filter((event) => event.t === 'exp');

test('a wild KO pays the one owner seat, facts only', () => {
  const exps = expOf(byName(jsRuns).get('exp_wild'));
  assert.strictEqual(exps.length, 1, 'exactly one payout');
  assert.strictEqual(exps[0].slot, 0, 'to the sole owner seat');
  assert.strictEqual(exps[0].species, 'Beta', 'naming the monster that fell');
  assert.strictEqual(exps[0].level, 20, 'and the level it was');
  assert.strictEqual(exps[0].participants, 1, 'split one way');
  assert.strictEqual(exps[0].mon, 0, 'banked by party index 0');
  assert.strictEqual(exps[0].amount, undefined,
    'and never an amount: this referee holds no species table');
});

test('a co-op KO pays both standing seats, in field-slot order', () => {
  const exps = expOf(byName(jsRuns).get('exp_coop'));
  assert.strictEqual(exps.length, 2, 'both owner seats are paid');
  assert.deepStrictEqual(exps.map((e) => e.slot), [0, 1],
    'seat order, not speed order -- a permutation here is a parity failure '
    + 'with no symptom anyone could read');
  assert.deepStrictEqual(exps.map((e) => e.participants), [2, 2],
    'and both name the same divisor');
});

test('1v1 and coop_pvp never emit exp -- the farming-loop gate', () => {
  // `retarget` is the coop_pvp scenario; a KO happens in it and pays nothing.
  const run = byName(jsRuns).get('retarget');
  assert.strictEqual(expOf(run).length, 0, 'coop_pvp pays nothing');
  assert.ok(run.events.some((e) => e.t === 'faint'),
    'and a faint really did happen, so the gate is what refused it');
});

test('a KO with a bench opens the replace phase before the next turn', () => {
  const run = byName(jsRuns).get('replace');
  const solicit = run.events.find((e) => e.t === 'turn' && e.slot !== undefined);
  assert.ok(solicit, 'a replacement solicitation was raised');
  assert.strictEqual(solicit.slot, 3, 'naming the seat that owes');

  const firstTurn = run.events.find((e) => e.t === 'turn' && e.slot === undefined);
  assert.strictEqual(solicit.amount, firstTurn.amount,
    'on the same turn number the faint happened on -- the phase does not advance it');

  // The batch reads as one story: faint, its spoils, the ask, the successor.
  const story = run.events
    .filter((e) => ['faint', 'exp', 'switch', 'send'].includes(e.t)
      || (e.t === 'turn' && e.slot !== undefined))
    .map((e) => (e.t === 'turn' ? 'ask' : e.t))
    .join(',');
  assert.ok(story.includes('faint,exp,exp,ask,switch,send'),
    `faint -> spoils -> ask -> switch -> send (${story})`);
});

test('every send and switch names the party index it fielded', () => {
  const run = byName(jsRuns).get('replace');
  for (const event of run.events) {
    if (event.t === 'send' || event.t === 'switch') {
      assert.strictEqual(typeof event.mon, 'number',
        `${event.t} on slot ${event.slot} carries no party index -- a seat holding `
        + 'two of a species would re-field the fallen copy');
    }
  }
  const replacement = run.events.find((e) => e.t === 'switch' && e.slot === 3);
  assert.strictEqual(replacement.mon, 1, 'the post-faint replacement is party index 1');
});

// The replace phase's REFUSALS, which the parity fixture cannot reach: its
// `replace` scenario answers the solicitation immediately and never attempts an
// illegal submit. tests/battle_sim2_turn.lua asserts these three on the Lua
// side; without them here a JS-only regression in the guards ships green, and
// "the two files are currently identical" is a fact about today, not a test.
test('during the replace phase only the seat that owes may answer', () => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'guards', mode: 'coop_npc', seed: 6161, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 95, spe: 90, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 95, spe: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        mn({ species: 'Beta', maxHp: 30, spe: 10, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [thump()] }),
      ] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
  battle.autoPick('npc');
  battle.drainEvents();

  assert.strictEqual(battle.snapshot().phase, 'replace',
    'the KO left the machine in the replace phase');
  assert.strictEqual(
    battle.submitChoice('a1', { action: 'fight', move: 0, target: 2 }), false,
    'a standing seat\'s fight is refused -- it would answer a turn that has '
    + 'not opened, and be spent before the player saw the successor come out');
  assert.strictEqual(battle.submitChoice('a1', { action: 'cancel' }), false,
    'and so is a cancel: a forced replacement cannot be taken back');
  assert.strictEqual(battle.autoPick('a1'), false,
    'an NPC that is still standing does not file either -- this false is how '
    + 'the fillNpcChoices loop learns to stop');
  assert.ok(battle.autoPick('npc'), 'only the seat that owes may answer');
  assert.strictEqual(battle.snapshot().phase, 'choice',
    'and answering it closes the phase');
});

test('autoPick Struggles rather than hanging when the NPC has no move', () => {
  const battle = build({
    id: 'emptymoves', mode: '1v1', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [] })] }],
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
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [] })] }],
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
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'WILD', mons: [
        mn({ species: 'Beta', maxHp: 40, spe: 10,
          moves: [mv('nudge', 10, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  const foe = battle.byId.get('p2');
  foe.mons[0].hp = 0;
  foe.active = null;
  assert.strictEqual(battle.tick(0), true, 'gen2: one tick notices the empty side');
  const out = battle.outcome();
  assert.ok(out, 'gen2: and the fight ends rather than waiting for the wild');
  assert.strictEqual(out.reason, 'ko', 'gen2: as a knockout');
});

test('FIGHT with nobody to aim at is a skip that closes a dead wild', () => {
  const battle = build({
    id: 'deadwild-skip', mode: 'wild', seed: 3, choiceTimeout: 0, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', mons: [
        mn({ species: 'Alpha', maxHp: 200, atk: 90, spe: 80,
          moves: [mv('thump', 40, 255, 0)] })] }],
      b: [{ playerId: 'p2', name: 'WILD', mons: [
        mn({ species: 'Beta', maxHp: 40, spe: 10,
          moves: [mv('nudge', 10, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  const foe = battle.byId.get('p2');
  foe.mons[0].hp = 0;
  foe.active = null;
  assert.ok(battle.submitChoice('p1', { action: 'fight', move: 0 }),
    'gen2: FIGHT with nobody to aim at is accepted as a skip');
  assert.ok(battle.outcome(), 'gen2: and the skip closes the fight');
});

test('every sentence about a move prints its name, and falls back to the id', () => {
  // Gen 2's own copies of the five call sites. Byte-shared with the Gen 1 pair
  // next door, and separate on purpose: BattleSim2 / lib/battle2 are a twin,
  // not an import, so a fix applied to one half of one generation is exactly
  // the drift this catches.
  const run = byName(jsRuns).get('move_names');
  const said = run.events.filter((event) => event.t === 'msg').map((event) => event.text);

  assert.ok(said.includes('Alpha used SLOW SWIPE'), 'an attack prints the display name');
  assert.ok(said.includes('THUMP HIT was disabled'), 'Disable landing names the move');
  assert.ok(said.includes('THUMP HIT is disabled'), 'and so does the refusal it causes');
  assert.ok(said.includes('THUMP HIT is no longer disabled'), 'and so does it wearing off');
  assert.ok(said.includes('Alpha learned THUMP HIT'), 'Mimic names what it copied');
  assert.ok(said.includes('Alpha used THUMP HIT'), 'and the copy keeps the name');
  assert.ok(said.includes('Beta used nudge'),
    'a move with no name -- a protocol-25 sheet -- is narrated under its id');

  const anims = run.events.filter((event) => event.t === 'anim').map((event) => event.text);
  assert.ok(anims.includes('slow_swipe'), 'the anim row still carries the registry id');
  assert.ok(!anims.includes('SLOW SWIPE'), 'and never the display name');
});

// The highest-consequence path in the phase and the one neither generation
// covered: if the timeout sweep does not reach a `replace` seat, an idle or
// dropped player wedges the fight forever -- `_maybeResolve` never fires,
// because the only thing anybody owes is the replacement nobody filed.
test('an unanswered replacement times out instead of wedging the fight', () => {
  const thump = () => mv('thump', 40, 255, 0);
  const battle = build({
    id: 'wedge', mode: 'coop_npc', seed: 6161, choiceTimeout: 10, reconnectGrace: 600,
    sides: {
      a: [
        { playerId: 'a1', name: 'Ann', mons: [
          mn({ species: 'Alpha', maxHp: 200, atk: 95, spe: 90, moves: [thump()] })] },
        { playerId: 'a2', name: 'Abe', mons: [
          mn({ species: 'Gamma', maxHp: 200, atk: 95, spe: 80, moves: [thump()] })] },
      ],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        mn({ species: 'Beta', maxHp: 30, spe: 10, moves: [thump()] }),
        mn({ species: 'Delta', maxHp: 400, spe: 10, moves: [thump()] }),
      ] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.submitChoice('a2', { action: 'fight', move: 0, target: 3 });
  battle.autoPick('npc');
  battle.drainEvents();
  assert.strictEqual(battle.snapshot().phase, 'replace');

  // Nobody answers. The clock is what has to carry it.
  assert.ok(battle.tick(battle.snapshot().now + 60),
    'the deadline passing is a tick that did something');
  assert.strictEqual(battle.snapshot().phase, 'choice',
    'the sweep filled the owed replacement and closed the phase');
  const sent = battle.drainEvents().filter((e) => e.t === 'send' && e.slot === 3);
  assert.ok(sent.length > 0, 'and the successor really was fielded');
});

test('a stolen KO retargets instead of fizzling', () => {
  const run = byName(jsRuns).get('retarget');
  const fizzled = run.events.some((e) => e.t === 'msg'
    && typeof e.text === 'string' && e.text.includes('has no target'));
  assert.ok(!fizzled, 'the slower ally does not fizzle on the seat its partner emptied');
  assert.ok(run.events.some((e) => e.t === 'damage' && e.slot === 3),
    'it swings at the nearest living opposing seat instead');
});

// ------------------------------------------------------------------
// the vocabulary really carries all of this
// ------------------------------------------------------------------

test('the Gen2 event vocabulary knows exp, the party index and the ask slot', () => {
  assert.strictEqual(Events.KINDS.exp, true, '`exp` is in the closed kind set');
  assert.strictEqual(Events.FIELDS.species, 'string');
  assert.strictEqual(Events.FIELDS.level, 'number');
  assert.strictEqual(Events.FIELDS.participants, 'number');
  assert.strictEqual(Events.FIELDS.mon, 'number');
  assert.ok(Events.SHAPES.send.mon, '`send` promises the party index it fielded');
  assert.ok(Events.SHAPES.send.status, '...and the condition a newcomer walked in with');
  assert.ok(Events.SHAPES.switch.mon, 'and so does `switch`');
  assert.ok(Events.SHAPES.turn.slot, '`turn` documents the solicitation slot');

  const built = Events.build('exp', {
    slot: 0, species: 'Beta', level: 20, participants: 2, mon: 1,
  });
  assert.ok(built, 'an exp event builds');
  assert.strictEqual(built.t, 'exp');
  assert.strictEqual(built.participants, 2);
  assert.strictEqual(built.mon, 1);
});

// ------------------------------------------------------------------
// wildlife never uses an item, from either end
// ------------------------------------------------------------------
//
// Twin of tests/battle_sim2_turn.lua's section 4, and byte-shared with the Gen 1
// pair. A wild monster has no bag and no hands, and its seat is driven from two
// ends -- the hub auto-picks for it, and a submitted choice can arrive addressed
// to it -- so both are pinned. The wild seat is handed a bag on purpose: even a
// seat that HAS one must never spend it, so a hub seeding the wrong kit cannot
// put a Potion in a wild monster's mouth.

const wildBattle2 = (mode, id, bBag) => {
  const sideA = [{
    playerId: 'p1', name: 'Ann', bag: { POTION: 1 },
    mons: [mn({ species: 'Alpha', maxHp: 200, spe: 90, moves: [mv('thump', 40, 255, 0)] })],
  }];
  if (mode === 'coop_wild') {
    sideA.push({
      playerId: 'p2', name: 'Pat',
      mons: [mn({ species: 'Gamma', maxHp: 200, spe: 1, moves: [mv('thump', 1, 255, 0)] })],
    });
  }
  return build({
    id, mode, seed: 88010, choiceTimeout: 10, reconnectGrace: 60,
    sides: {
      a: sideA,
      b: [{
        playerId: 'wild', name: 'Wild', bag: bBag,
        mons: [mn({
          species: 'Beta', maxHp: 200, hp: 40, spe: 10, status: 'PSN',
          moves: [mv('thump', 40, 255, 0)],
        })],
      }],
    },
  });
};

for (const mode of ['wild', 'coop_wild']) {
  test(`${mode}: auto-pick never reaches the wild seat's bag`, () => {
    const battle = wildBattle2(mode, 'wa', { POTION: 2, FULL_HEAL: 1, X_ATTACK: 1 });
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
    const battle = wildBattle2(mode, 'wb', { POTION: 1 });
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

test('Potion on a fainted party slot is refused', () => {
  const battle = build({
    id: 'potion-faint', mode: '1v1', seed: 88021,
    choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', bag: { POTION: 1 }, mons: [
        mn({ species: 'Alpha', maxHp: 100, hp: 50, spe: 90, moves: [mv('thump', 40, 255, 0)] }),
        mn({ species: 'Bench', maxHp: 100, hp: 0, spe: 1, moves: [mv('thump', 40, 255, 0)] }),
      ] }],
      b: [{ playerId: 'p2', name: 'Bob', mons: [
        mn({ species: 'Beta', maxHp: 200, spe: 10, moves: [mv('thump', 40, 255, 0)] })] }],
    },
  });
  battle.drainEvents();
  assert.strictEqual(
    battle.submitChoice('p1', { action: 'item', item: 'POTION', slot: 1 }), false,
    'Potion on a fainted party slot is refused',
  );
  assert.strictEqual(battle.byId.get('p1').bag.POTION, 1, 'and the bag is not spent');
  assert.strictEqual(battle.byId.get('p1').choice, null, 'and the turn is still owed');
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

// ------------------------------------------------------------------
// badge rules: Crystal's, and against the computer only
// ------------------------------------------------------------------

// Twin of tests/battle_sim2_turn.lua's 7, same sheets and seed, so the numbers
// are the same numbers. Crystal boosts the player's monster and only outside a
// link battle (BadgeStatBoosts opens with `ld a, [wLinkMode] / and a / ret nz`),
// so the referee keeps an uploaded set on side a of wild / coop_wild / coop_npc
// and drops it in 1v1, coop_pvp and on side b. What a kept set does is Gold's,
// not Red's: the ids are Gold's (ZEPHYR ... EARTH), ZEPHYR / MINERAL / PLAIN /
// GLACIER boost Attack / Defense / Speed / Sp. Atk by an eighth up to 999,
// Sp. Def only through Glacier's buggy tail, and DoBadgeTypeBoosts adds an
// eighth to a move whose type's badge is held.

const { Effects } = require('./lib/battle2');

// Every Gold badge, Johto then Kanto.
const ALL_BADGES = {};
for (const row of Effects.BADGE_TYPE_BOOSTS) ALL_BADGES[row.badge] = true;

// The ruleset's type axis. Index 0 is a type no badge names, so a move of type
// 0 is never type-boosted; 1 is BUG (HIVE's), 2 is FIRE and Special.
const RULES = { typeIds: ['DARK', 'BUG', 'FIRE'], specialTypes: [2] };

// One exchange: Ann (side a) and Bob (side b) each swing once. `a` / `b`
// override the stats, the move's power and type, and carry each seat's upload
// (`a.pp = 0` empties Ann's one slot, so she Struggles); `rules` is the ruleset
// (typeIds, specialTypes).
const exchange = (mode, a, b, rules = {}) => {
  const move = (power, type, pp = 20) => ({
    id: 'thump', pp, power, accuracy: 255, type, effect: 0, chance: 0,
  });
  const ann = {
    species: 'Alpha', level: 20, hp: 200, maxHp: 200,
    stats: { atk: a.atk || 88, def: a.def || 40, spe: a.spe || 40, spa: a.spa || 40, spd: 40 },
    moves: [move(50, a.type || 0, a.pp)],
  };
  if (a.confusion) ann.confusion = a.confusion;
  const battle = build({
    id: 'b1', mode, seed: a.seed || 777001, choiceTimeout: 60, reconnectGrace: 60,
    typeIds: rules.typeIds, specialTypes: rules.specialTypes,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: a.badges, mons: [ann] }],
      b: [{ playerId: 'p2', name: 'Bob', badges: b.badges, mons: [{
        species: 'Beta', level: 20, hp: 200, maxHp: 200,
        stats: { atk: b.atk || 40, def: b.def || 80, spe: b.spe || 40, spa: b.spa || 40, spd: 40 },
        moves: [move(b.power || 1, b.type || 0)],
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
// What a confusion self-hit cost, or null when the seat did not hit itself.
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

// A seed on which Ann hits herself on the first turn of a confusion.
let confusedSeed = null;
for (let seed = 1; seed <= 200; seed += 1) {
  if (selfHit(exchange('coop_npc', { seed, confusion: 3 }, {})) !== null) {
    confusedSeed = seed;
    break;
  }
}

test('badges count in the three fights against the computer, on side a', () => {
  assert.deepStrictEqual(Object.keys(Turn.BADGE_MODES).sort(),
    ['coop_npc', 'coop_wild', 'wild'], 'and in no other mode');
  assert.strictEqual(Turn.BADGE_SIDE, 'a', "and only on the player's side of them");
  assert.ok(confusedSeed !== null, 'found a seed where a confused Ann hits herself');
});

for (const mode of ['1v1', 'coop_pvp']) {
  test(`${mode}: a link battle ignores every uploaded badge`, () => {
    const bare = exchange(mode, {}, {});
    assert.strictEqual(hitOn(bare, 3), 18, 'the unbadged attack lands for 18');
    assert.strictEqual(hitOn(exchange(mode, { badges: { ZEPHYR: true } }, {}), 3), 18,
      'ZEPHYR does not raise the damage');
    // One seat at a time: both at once would cancel here (each attack is
    // boosted by the same eighth its target's defence is) and prove nothing.
    assert.deepStrictEqual(exchange(mode, { badges: ALL_BADGES }, {}), bare,
      'side a uploading every badge fights the unbadged fight');
    assert.deepStrictEqual(exchange(mode, {}, { badges: ALL_BADGES }), bare,
      'so does side b uploading every badge');
    assert.strictEqual(firstHit(exchange(mode, { spe: 40 }, { spe: 42 })), 0,
      'unbadged, Bob (42) outspeeds Ann (40)');
    assert.strictEqual(firstHit(exchange(mode, { spe: 40, badges: { PLAIN: true } }, { spe: 42 })), 0,
      'PLAIN does not let Ann overtake him');
    assert.strictEqual(hitOn(exchange(mode, { type: 1, badges: { HIVE: true } }, {}, RULES), 3), 12,
      'HIVE does not type-boost a BUG move either');
    const bareSelf = selfHit(exchange(mode, { seed: confusedSeed, confusion: 3 }, {}));
    assert.ok(bareSelf !== null, 'the confused Ann hits herself on this seed too');
    assert.strictEqual(
      selfHit(exchange(mode, { seed: confusedSeed, confusion: 3, badges: { ZEPHYR: true } }, {})),
      bareSelf, 'nor does ZEPHYR reach a confusion self-hit');
  });
}

for (const mode of ['coop_npc', 'wild']) {
  test(`${mode}: side a's badges follow Gold's rules against the computer`, () => {
    assert.strictEqual(hitOn(exchange(mode, {}, {}), 3), 18, 'unbadged, the same 18');
    // 88 -> 88 + floor(88 / 8) = 99 Attack; BattleSim2 reaches the same 20.
    assert.strictEqual(hitOn(exchange(mode, { badges: { ZEPHYR: true } }, {}), 3), 20,
      "ZEPHYR raises side a's physical damage to 20");
    assert.strictEqual(
      hitOn(exchange(mode, { badges: { BOULDER: true, BOULDERBADGE: true } }, {}), 3), 18,
      "BOULDER (Kanto) and BOULDERBADGE (Red's id) boost no stat on Gold");
    assert.strictEqual(firstHit(exchange(mode, { spe: 40 }, { spe: 42 })), 0,
      'unbadged, the foe (42) still goes first');
    assert.strictEqual(firstHit(exchange(mode, { spe: 40, badges: { PLAIN: true } }, { spe: 42 })), 3,
      'PLAIN (40 -> 45) puts side a in front');
    assert.strictEqual(hitOn(exchange(mode, {}, { power: 30 }), 0), 11,
      "Bob's 30-power hit on an unbadged Ann is 11");
    assert.strictEqual(hitOn(exchange(mode, { badges: { MINERAL: true } }, { power: 30 }), 0), 9,
      'MINERAL (Defense 40 -> 45) cuts it to 9');
    assert.strictEqual(hitOn(exchange(mode, { type: 2, spa: 88 }, {}, RULES), 3), 23,
      "Ann's Special hit, unbadged, is 23");
    assert.strictEqual(
      hitOn(exchange(mode, { type: 2, spa: 88, badges: { GLACIER: true } }, {}, RULES), 3), 25,
      'GLACIER (Sp. Atk 88 -> 99) raises it to 25');

    // Glacier's Sp. Def tail, both ways: Bob's Special hit on Ann. Sp. Atk 227
    // boosts to 255, which the tail reads as odd (Sp. Def boosted); 200 boosts
    // to 225, even, and Sp. Def stays as it was.
    const special = { power: 30, type: 2, spa: 60 };
    assert.strictEqual(hitOn(exchange(mode, { spa: 227 }, special, RULES), 0), 10,
      "Bob's Special hit on an unbadged Ann is 10");
    assert.strictEqual(
      hitOn(exchange(mode, { spa: 227, badges: { GLACIER: true } }, special, RULES), 0), 9,
      'GLACIER with Sp. Atk 227 (-> 255) boosts Sp. Def too: 9');
    assert.strictEqual(
      hitOn(exchange(mode, { spa: 200, badges: { GLACIER: true } }, special, RULES), 0), 10,
      'GLACIER with Sp. Atk 200 (-> 225) leaves Sp. Def alone: 10');

    // The 999 cap: 950 + floor(950 / 8) = 1068 is held at 999, so a badged 950
    // hits exactly as an unbadged 999 does, and harder than a bare 950.
    assert.strictEqual(hitOn(exchange(mode, { atk: 950 }, { def: 600 }), 3), 24,
      'an unbadged Attack of 950 hits for 24');
    assert.strictEqual(hitOn(exchange(mode, { atk: 999 }, { def: 600 }), 3), 26,
      'an unbadged Attack of 999 hits for 26');
    assert.strictEqual(
      hitOn(exchange(mode, { atk: 950, badges: { ZEPHYR: true } }, { def: 600 }), 3), 26,
      'ZEPHYR on 950 is capped at 999 and hits for the same 26');

    // DoBadgeTypeBoosts: Ann's BUG move (no STAB, so 12 bare) and HIVE.
    assert.strictEqual(hitOn(exchange(mode, { type: 1 }, {}, RULES), 3), 12,
      "Ann's BUG move, no badge, is 12");
    assert.strictEqual(hitOn(exchange(mode, { type: 1, badges: { HIVE: true } }, {}, RULES), 3), 13,
      'HIVE adds its eighth: 13');
    assert.strictEqual(hitOn(exchange(mode, { type: 1, badges: { FOG: true } }, {}, RULES), 3), 12,
      'a badge of another type adds nothing');
    assert.strictEqual(
      hitOn(exchange(mode, { type: 1, badges: { HIVE: true } }, {},
        { specialTypes: RULES.specialTypes }), 3), 12,
      "with no typeIds the move's type has no name, and nothing fires");
    assert.strictEqual(
      hitOn(exchange(mode, { badges: { HIVE: true } }, { power: 30, type: 1 }, RULES), 0),
      hitOn(exchange(mode, {}, { power: 30, type: 1 }, RULES), 0),
      "the foe's BUG move is not boosted by Ann's HIVE");

    // Struggle never is: pokecrystal BattleCommand_Stab returns for it
    // (`cp STRUGGLE / ret z`) before DoBadgeTypeBoosts. On a chart whose index
    // 0 is BUG, Ann's type-0 move takes HIVE's eighth; her Struggle, whose
    // placeholder type is that same 0, does not -- and takes no STAB either,
    // though Ann is type 0 (the same early return): 10 x 50 x 88 / 80 / 50 =
    // 11, +2 = 13, and the roll leaves 12, where STAB used to make it 19 and 18.
    const BUG_FIRST = { typeIds: ['BUG', 'DARK', 'FIRE'], specialTypes: [2] };
    assert.strictEqual(hitOn(exchange(mode, {}, {}, BUG_FIRST), 3), 18,
      "index 0 named BUG, Ann's type-0 move is 18 bare");
    assert.strictEqual(hitOn(exchange(mode, { badges: { HIVE: true } }, {}, BUG_FIRST), 3), 20,
      '...and HIVE type-boosts it to 20');
    const struggled = exchange(mode, { pp: 0 }, {}, BUG_FIRST);
    assert.ok(struggled.some((event) => event.t === 'anim' && event.text === 'STRUGGLE'),
      'with her one slot at 0 PP, Ann Struggles');
    assert.strictEqual(hitOn(struggled, 3), 12, 'her Struggle, no badge and no STAB, is 12');
    assert.strictEqual(
      hitOn(exchange(mode, { pp: 0, badges: { HIVE: true } }, {}, BUG_FIRST), 3), 12,
      'HIVE leaves her Struggle at 12 (type 0 is BUG here, and still nothing fires)');

    // HitConfusion reads the boosted Attack (ZEPHYR) like any other hit.
    const bareSelf = selfHit(exchange(mode, { seed: confusedSeed, confusion: 3 }, {}));
    const zephyrSelf = selfHit(exchange(mode,
      { seed: confusedSeed, confusion: 3, badges: { ZEPHYR: true } }, {}));
    assert.ok(bareSelf !== null && zephyrSelf !== null && zephyrSelf > bareSelf,
      'ZEPHYR raises a confusion self-hit too');
  });
}

test("coop_npc: side b's upload is ignored against the computer too", () => {
  // Each of these would have changed the fight had it counted: MINERAL would
  // cut Ann's hit, ZEPHYR would raise Bob's, and PLAIN (37 -> 41) would put
  // Bob ahead of Ann's 40.
  const bare = exchange('coop_npc', {}, { power: 30 });
  const hostile = exchange('coop_npc', {}, { badges: ALL_BADGES, power: 30 });
  assert.strictEqual(hitOn(hostile, 3), hitOn(bare, 3), "side b's MINERAL is ignored");
  assert.strictEqual(hitOn(hostile, 0), hitOn(bare, 0), "side b's ZEPHYR is ignored");
  assert.deepStrictEqual(hostile, bare, "side b's upload changes nothing at all");
  assert.strictEqual(firstHit(exchange('coop_npc', {}, { badges: ALL_BADGES, spe: 37 })), 3,
    "side b's PLAIN does not overtake side a");
  assert.deepStrictEqual(
    exchange('coop_npc', {}, { badges: ALL_BADGES, power: 30, type: 1 }, RULES),
    exchange('coop_npc', {}, { power: 30, type: 1 }, RULES),
    "side b's HIVE does not type-boost its BUG move");
});

// ------------------------------------------------------------------
// pokecrystal fidelity: stat order, crits, folding, screens, the self-hit,
// Struggle, a Metronome call and move priority
// ------------------------------------------------------------------
//
// Twin of tests/battle_sim2_turn.lua's section 8 (docs/plans/
// gen12-referee-fidelity.md, Gen 2): the same sheets, the same seeds and the
// same numbers, each worked from the cart's arithmetic there.

const { damage: Damage2 } = require('./lib/battle2');

// A sheet in one line: everything explicit, so the Lua twin builds the same.
function sheet(o) {
  return {
    species: o.species,
    level: o.level === undefined ? 20 : o.level,
    maxHp: o.maxHp === undefined ? 300 : o.maxHp,
    hp: o.hp,
    status: o.status,
    types: o.types === undefined ? [2] : o.types,
    stats: {
      atk: o.atk === undefined ? 40 : o.atk,
      def: o.def === undefined ? 40 : o.def,
      spe: o.spe === undefined ? 40 : o.spe,
      spa: o.spa === undefined ? 40 : o.spa,
      spd: o.spd === undefined ? 40 : o.spd,
    },
    stages: o.stages,
    confusion: o.confusion,
    substitute: o.substitute,
    moves: o.moves,
  };
}
const hit = (id, power, type, effect, pp) => ({
  id, pp: pp === undefined ? 30 : pp, power, accuracy: 255,
  type: type === undefined ? 0 : type, effect: effect === undefined ? 0 : effect, chance: 0,
});
const said = (events, text) => events.some((e) => e.t === 'msg' && e.text === text);
const damageOn = (events, slot) => {
  const event = events.find((e) => e.t === 'damage' && e.slot === slot);
  return event ? event.amount : null;
};
const animOrder = (events) => events.filter((e) => e.t === 'anim').map((e) => e.text).join(',');
function duel(o) {
  return build({
    id: 'b1', mode: o.mode || '1v1', seed: o.seed === undefined ? 4242 : o.seed,
    choiceTimeout: 60, reconnectGrace: 60,
    chart: o.chart, specialTypes: o.specialTypes, typeIds: o.typeIds,
    metronomePool: o.metronomePool,
    sides: {
      a: [{ playerId: 'p1', name: 'Ann', badges: o.badges, mons: o.a }],
      b: [{ playerId: 'p2', name: 'Bob', mons: o.b }],
    },
  });
}
function turnOf(battle, a, b) {
  battle.submitChoice('p1', a || { action: 'fight', move: 0 });
  battle.submitChoice('p2', b || { action: 'fight', move: 0 });
  return battle.drainEvents();
}

test('fidelity: CalcBattleStats, BadgeStatBoosts, TruncateHL_BC and GetMovePriority alone', () => {
  assert.strictEqual(Effects.applyStage(100, 1), 150, 'CalcBattleStats: 100 at +1 is 150');
  assert.strictEqual(Effects.applyStage(3, -6), 1, 'a quotient of 0 is raised to 1');
  assert.strictEqual(Effects.applyStage(700, 2), 999, 'one past MAX_STAT_VALUE is held at 999');

  const m = {
    stats: { atk: 100, def: 40, spe: 100, spa: 152, spd: 100 },
    stages: { atk: -1, spe: 2, spa: 1 },
  };
  assert.strictEqual(Effects.battleStat(m, 'atk', { ZEPHYR: true }), 74,
    "the stage first (66), then ZEPHYR's eighth: 74 -- badge-then-stage was 73");
  m.status = 'burn';
  assert.strictEqual(Effects.battleStat(m, 'atk', { ZEPHYR: true }), 37,
    'burn halves what the badge left: 37');
  m.status = 'paralysis';
  assert.strictEqual(Effects.battleStat(m, 'spe', { PLAIN: true }), 56,
    '200 at +2, 225 under PLAIN, quartered by paralysis: 56');
  assert.strictEqual(Effects.battleStat(m, 'spd', { GLACIER: true }), 112,
    "Glacier's tail reads the STAGED Sp. Atk: 228 boosts to 256, odd, so Sp. Def 100 -> 112");
  m.stages.spa = 0;
  assert.strictEqual(Effects.battleStat(m, 'spd', { GLACIER: true }), 100,
    'unstaged, 152 boosts to 171, even, and Sp. Def stays 100');

  const fold = (a, d, link) => {
    const out = Damage2.truncateStats(a, d, link);
    return `${out.attack}/${out.defense}`;
  };
  assert.strictEqual(fold(200, 100, false), '200/100', 'TruncateHL_BC leaves two bytes alone');
  assert.strictEqual(fold(950, 600, false), '237/150', 'folds both by four while either is past 255');
  assert.strictEqual(fold(200, 1200, false), '12/75', 'as often as it takes outside a link battle');
  assert.strictEqual(fold(200, 1200, true), '50/44', "once in one, keeping 300's low byte: the wrap");
  assert.strictEqual(fold(3, 1000, false), '1/250', 'a stat the shift empties becomes 1');
  assert.strictEqual(fold(1024, 50, true), '0/12', 'a wrapped attack stays 0 (DamageCalc only lifts defense)');

  const table = {
    PROTECT: 3, DETECT: 3, ENDURE: 3,
    QUICK_ATTACK: 2, MACH_PUNCH: 2, EXTREMESPEED: 2,
    ROAR: 0, WHIRLWIND: 0, COUNTER: 0, MIRROR_COAT: 0, VITAL_THROW: 0,
    STRUGGLE: 1, thump: 1,
  };
  for (const [id, want] of Object.entries(table)) {
    assert.strictEqual(Effects.movePriority(id), want, `GetMovePriority: ${id} is ${want}`);
  }
  assert.strictEqual(Effects.movePriority({ id: 'quick_attack' }), 2, 'a move record answers by its id, any case');
  assert.strictEqual(Effects.movePriority(null), Effects.BASE_PRIORITY, 'no move is BASE_PRIORITY');
});

test('fidelity: a crit keeps the staged pair only when the defender\'s stage is strictly lower', () => {
  const critHit = (atkStage, defStage) => {
    for (let seed = 1; seed <= 400; seed += 1) {
      const slash = hit('slash_hit', 40);
      slash.highCrit = true;
      const battle = duel({
        seed,
        a: [sheet({ species: 'Alpha', spe: 90, stages: { atk: atkStage }, moves: [slash] })],
        b: [sheet({ species: 'Beta', spe: 10, stages: { def: defStage }, moves: [hit('tap', 0, 0, 85)] })],
      });
      battle.drainEvents();
      const events = turnOf(battle);
      if (said(events, 'A critical hit')) return damageOn(events, 3);
    }
    return null;
  };
  // 10 x 40 x 40 / 40 / 50 = 8, x2 = 16, +2 = 18, then the roll.
  const plain = critHit(0, 6);
  assert.ok(plain !== null && plain >= 15 && plain <= 18,
    'a crit into Defense +6 reads the unmodified stats (15..18), not 160 Defense');
  // 10 x 40 x 160 / 60 / 50 = 21, x2 = 42, +2 = 44, then the roll.
  const staged = critHit(6, 1);
  assert.ok(staged !== null && staged >= 37 && staged <= 44,
    'a crit from Attack +6 into Defense +1 keeps both stages (37..44)');
});

test('fidelity: stages do not survive a switch-in or a faint', () => {
  const battle = duel({
    a: [
      sheet({ species: 'Alpha', spe: 90,
        moves: [hit('sharpen', 0, 0, Effects.idOf('ATTACK_UP2_EFFECT')), hit('thump', 60)] }),
      sheet({ species: 'Gamma', spe: 90, moves: [hit('thump', 10)] }),
    ],
    b: [sheet({ species: 'Beta', spe: 10, maxHp: 30, atk: 40,
      stages: { atk: 3, def: -2 }, moves: [hit('tap', 1)] })],
  });
  battle.drainEvents();
  turnOf(battle);
  assert.strictEqual(battle.byId.get('p1').mons[0].stages.atk, 2, 'the +2 lands on Alpha');
  turnOf(battle, { action: 'switch', slot: 1 });
  turnOf(battle, { action: 'switch', slot: 0 });
  assert.strictEqual(battle.byId.get('p1').mons[0].stages.atk, 0,
    'Alpha comes back in at 0: a send-out brings no stage (ResetPlayerStatLevels)');
  const beta = battle.byId.get('p2').mons[0];
  for (let i = 0; i < 6 && !battle.outcome(); i += 1) turnOf(battle, { action: 'fight', move: 1 });
  assert.strictEqual(beta.hp, 0, 'Beta goes down');
  assert.strictEqual(beta.stages.atk, 0, 'and its +3 Attack goes with it');
  assert.strictEqual(beta.stages.def, 0, 'and its -2 Defense');
});

test('fidelity: screens are per side, tick five times, fail on a recast and skip fixed damage', () => {
  const battle = duel({
    specialTypes: [1],
    a: [sheet({ species: 'Alpha', spe: 90, moves: [hit('glow_wall', 0, 1, 64, 20), hit('tap', 1)] })],
    b: [sheet({ species: 'Beta', spe: 10, spa: 60, moves: [hit('zap', 40, 1), hit('sonic_ping', 20, 0, 41)] })],
  });
  battle.drainEvents();
  const first = turnOf(battle);
  assert.strictEqual(battle.screens.a.lightScreen, 4, "Light Screen goes up at 5 and the turn's tick takes one");
  assert.strictEqual(battle.screens.b.lightScreen, 0, "on Ann's side only");
  const screened = damageOn(first, 0);
  assert.ok(screened !== null && screened >= 6 && screened <= 8,
    'a special hit into it reads Sp. Def doubled (6..8)');
  const again = turnOf(battle);
  assert.ok(said(again, 'But it failed'), 'a second Light Screen while one is up fails');
  assert.strictEqual(battle.screens.a.lightScreen, 3, 'and does not refresh the count');
  const fixed = turnOf(battle, { action: 'fight', move: 1 }, { action: 'fight', move: 1 });
  assert.strictEqual(damageOn(fixed, 0), 20, 'a fixed-damage hit is never screened: the post-hoc halving is gone');
  turnOf(battle, { action: 'fight', move: 1 });
  const fade = turnOf(battle, { action: 'fight', move: 1 });
  assert.ok(said(fade, "Ann's LIGHT SCREEN fell"), 'it falls at the end of its fifth turn');
  assert.strictEqual(battle.screens.a.lightScreen, 0, 'and is down');
  const bare = turnOf(battle, { action: 'fight', move: 1 });
  const unscreened = damageOn(bare, 0);
  assert.ok(unscreened !== null && unscreened >= 11 && unscreened <= 14,
    'the next special hit is whole again (11..14)');
});

test('fidelity: the confusion self-hit is DamageCalc alone, past the user\'s substitute', () => {
  const confusedFight = (seed) => duel({
    seed,
    a: [sheet({ species: 'Alpha', spe: 90, atk: 60, def: 60, confusion: 4,
      substitute: 50, moves: [hit('tap', 1)] })],
    b: [sheet({ species: 'Beta', spe: 10, moves: [hit('tap', 0, 0, 85)] })],
  });
  let found = null;
  for (let seed = 1; seed <= 200 && found === null; seed += 1) {
    const battle = confusedFight(seed);
    battle.drainEvents();
    if (said(turnOf(battle), 'Alpha hurt itself in confusion')) found = seed;
  }
  assert.ok(found !== null, 'a seed on which the confused Alpha hits itself');
  const battle = confusedFight(found);
  battle.drainEvents();
  const events = turnOf(battle);
  assert.strictEqual(damageOn(events, 0), 10, 'the self-hit is DamageCalc and nothing after: 10, every time');
  assert.strictEqual(battle.byId.get('p1').mons[0].hp, 290, 'and it comes off the HP');
  assert.strictEqual(battle.byId.get('p1').mons[0].substitute, 50,
    "past the user's own substitute (`ld c, TRUE`)");
});

test('fidelity: Struggle is typeless with a quarter recoil, and a last-PP Metronome call is not Struggle', () => {
  const GHOST_CHART = [[100, 0], [100, 100]];
  const vsGhost = (pp) => duel({
    chart: GHOST_CHART,
    a: [sheet({ species: 'Alpha', spe: 90, types: [0], moves: [hit('thump', 40, 0, 0, pp)] })],
    b: [sheet({ species: 'Beta', spe: 10, types: [1], moves: [hit('tap', 0, 0, 85)] })],
  });
  const normal = vsGhost(10);
  normal.drainEvents();
  assert.ok(said(turnOf(normal), "It doesn't affect Beta"), 'a NORMAL move cannot touch the GHOST on this chart');
  const struggle = vsGhost(0);
  struggle.drainEvents();
  const events = turnOf(struggle);
  const dealt = damageOn(events, 3);
  assert.ok(dealt !== null && dealt >= 10 && dealt <= 12,
    'Struggle hits the GHOST anyway, with no STAB (10..12)');
  assert.ok(!said(events, "It doesn't affect Beta"), 'and no matchup line at all');
  assert.strictEqual(damageOn(events, 0), Math.max(1, Math.floor(dealt / 4)),
    'recoil is a quarter of what it dealt');

  const feeble = duel({
    a: [sheet({ species: 'Alpha', spe: 90, atk: 1, moves: [hit('thump', 40, 0, 0, 0)] })],
    b: [sheet({ species: 'Beta', spe: 10, def: 255, moves: [hit('tap', 0, 0, 85)] })],
  });
  feeble.drainEvents();
  assert.strictEqual(damageOn(turnOf(feeble), 0), 1,
    "a Struggle that deals 1 still costs 1 (BattleCommand_Recoil's minimum)");

  const metronome = duel({
    metronomePool: [hit('pool_hit', 60, 1, 0, 10)],
    a: [sheet({ species: 'Alpha', spe: 90,
      moves: [hit('wave_finger', 0, 0, Effects.idOf('EFFECT_METRONOME'), 1)] })],
    b: [sheet({ species: 'Beta', spe: 10, moves: [hit('tap', 0, 0, 85)] })],
  });
  metronome.drainEvents();
  const called = turnOf(metronome);
  assert.ok(animOrder(called).includes('pool_hit'), 'the last PP calls the pool move');
  assert.ok(!said(called, 'Alpha is hit with recoil'), 'and the called move takes no Struggle recoil');
  const after = turnOf(metronome);
  assert.ok(animOrder(after).includes('STRUGGLE'), 'the turn after, every slot is empty: Struggle');
  assert.ok(said(after, 'Alpha is hit with recoil'), 'which does recoil');

  // ResetTurn re-enters DoMove past CheckTurn, so the called move is not gated
  // a second time: a confused caller spends one confusion turn, not two.
  const confusedCaller = (seed) => duel({
    seed, metronomePool: [hit('pool_hit', 60, 1, 0, 10)],
    a: [sheet({ species: 'Alpha', spe: 90, confusion: 5,
      moves: [hit('wave_finger', 0, 0, Effects.idOf('EFFECT_METRONOME'), 5)] })],
    b: [sheet({ species: 'Beta', spe: 10, moves: [hit('tap', 0, 0, 85)] })],
  });
  let clean = null;
  for (let seed = 1; seed <= 200 && clean === null; seed += 1) {
    const battle = confusedCaller(seed);
    battle.drainEvents();
    if (animOrder(turnOf(battle)).includes('pool_hit')) clean = battle;
  }
  assert.ok(clean !== null, 'a seed on which the confused caller gets its call off');
  assert.strictEqual(clean.byId.get('p1').mons[0].confusion, 4,
    'and the confusion counter ticked once: the called move ran no gate of its own');
});

test('fidelity: the priority bracket comes before the Speed', () => {
  const order = (aMove, aSpe, bMove, bSpe) => {
    const battle = duel({
      a: [sheet({ species: 'Alpha', spe: aSpe, moves: [aMove] })],
      b: [sheet({ species: 'Beta', spe: bSpe, moves: [bMove] })],
    });
    battle.drainEvents();
    return animOrder(turnOf(battle));
  };
  assert.strictEqual(order(hit('QUICK_ATTACK', 40), 10, hit('thump', 40), 99), 'QUICK_ATTACK,thump',
    'QUICK_ATTACK (2) beats a far faster plain hit (1)');
  assert.strictEqual(order(hit('QUICK_ATTACK', 40), 10, hit('EXTREMESPEED', 80), 99),
    'EXTREMESPEED,QUICK_ATTACK', "EXTREMESPEED shares QUICK_ATTACK's bracket, so Speed decides");
  assert.strictEqual(order(hit('thump', 40), 99, hit('PROTECT', 0), 1), 'PROTECT,thump',
    'PROTECT (3) moves first from the slowest seat');
  assert.strictEqual(order(hit('VITAL_THROW', 70, 0, 17), 99, hit('thump', 40), 1), 'thump,VITAL_THROW',
    'VITAL_THROW (0) moves last from the fastest seat');
  assert.strictEqual(order(hit('thump', 40, 0, 0, 0), 10, hit('VITAL_THROW', 70, 0, 17), 99),
    'STRUGGLE,VITAL_THROW', 'Struggle moves at BASE_PRIORITY, ahead of a bracket-0 move');
});

test('fidelity: an NPC never re-raises a screen that is already up', () => {
  const battle = build({
    id: 'b1', mode: 'coop_npc', seed: 77, choiceTimeout: 60, reconnectGrace: 60,
    sides: {
      a: [{ playerId: 'a1', name: 'Ann', mons: [
        sheet({ species: 'Alpha', spe: 10, moves: [hit('tap', 1)] })] }],
      b: [{ playerId: 'npc', name: 'Foe', mons: [
        sheet({ species: 'Beta', spe: 90, moves: [hit('wall_up', 0, 1, 65, 20), hit('thump', 40)] })] }],
    },
  });
  battle.drainEvents();
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.autoPick('npc');
  assert.ok(animOrder(battle.drainEvents()).includes('wall_up'), 'the NPC sets up Reflect on a level field');
  battle.submitChoice('a1', { action: 'fight', move: 0, target: 3 });
  battle.autoPick('npc');
  const second = animOrder(battle.drainEvents());
  assert.ok(!second.includes('wall_up'), 'and does not cast it again while it is up');
  assert.ok(second.includes('thump'), 'it attacks instead');
});
