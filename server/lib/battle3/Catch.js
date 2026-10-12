'use strict';

/*
 * Gen 3 catching: ball multipliers, odds and the four shake checks.
 *
 * Node twin of src/BattleSim3/Catch.lua (pret pokefirered/src/
 * battle_script_commands.c:9463 Cmd_handleballthrow). Two places follow pret
 * rather than the engine's float shortcut (docs/plans/gen3-battle-sheet.md §5.5):
 *
 *   * the odds are `floor(catchRate * mult / 10)` first, then
 *     `* (3M - 2H) / (3M)` -- the cart's integer order;
 *   * the shake threshold is `1048560 / Sqrt(Sqrt(16711680 / odds))` with the
 *     cart's INTEGER square roots.
 *
 * attempt -> [caught, shakes, odds].
 *
 * Nothing here throws.
 */

const Types = require('./Types.js');
const { int, truthy } = require('./lua.js');

const MASTER = 1;
const ULTRA = 2;
const GREAT = 3;
const POKE = 4;
const SAFARI = 5;
const NET = 6;
const DIVE = 7;
const NEST = 8;
const REPEAT = 9;
const TIMER = 10;
const LUXURY = 11;
const PREMIER = 12;

// pret sBallCatchBonuses (x10), Ultra .. Safari
const BONUS = {
  2: 20, 3: 15, 4: 10, 5: 15,
};

// A missed throw's line by its shakes (pret gBallEscapeStringIds, printed by
// BattleScript_ShakeBallThrow): the bag's balls (Turn.js `_useItem`) and the
// Safari Ball (Safari.js) alike.
const SHAKE_TEXT = {
  0: 'Oh, no! The POKeMON broke free!',
  1: 'Aww! It appeared to be caught!',
  2: 'Aargh! Almost had it!',
  3: 'Shoot! It was so close, too!',
};

function isBall(item) {
  const n = int(item, 0);
  return n >= 1 && n <= 12;
}

// ctx: { types: [t1, t2], level, turn (battle turn counter), underwater, dexCaught }
function multiplier(ballIn, ctxIn) {
  const ball = int(ballIn, POKE);
  const ctx = ctxIn || {};
  if (ball === MASTER) return 255;
  if (ball <= SAFARI) return BONUS[ball] !== undefined ? BONUS[ball] : 10;
  const t = ctx.types || [];
  if (ball === NET) {
    for (let i = 1; i <= t.length; i += 1) {
      if (t[i - 1] === Types.ID.WATER || t[i - 1] === Types.ID.BUG) return 30;
    }
    return 10;
  }
  if (ball === DIVE) {
    return truthy(ctx.underwater) ? 35 : 10;
  }
  if (ball === NEST) {
    const level = int(ctx.level, 50);
    if (level < 40) {
      let m = 40 - level;
      if (m <= 9) m = 10;
      return m;
    }
    return 10;
  }
  if (ball === REPEAT) {
    return truthy(ctx.dexCaught) ? 30 : 10;
  }
  if (ball === TIMER) {
    return Math.min(40, 10 + Math.max(0, int(ctx.turn, 0)));
  }
  return 10;
}

// The integer odds `a` (0..). status: wire token or null.
function odds(ball, catchRate, hp, maxHp, status, ctx) {
  const mult = multiplier(ball, ctx);
  const mhp = Math.max(1, int(maxHp, 1));
  const h = Math.max(0, int(hp, 0));
  let o = Math.floor(Math.max(0, int(catchRate, 0)) * mult / 10);
  o = Math.floor(o * (mhp * 3 - h * 2) / (3 * mhp));
  if (status === 'SLP' || status === 'FRZ') {
    o *= 2;
  } else if (status === 'PSN' || status === 'BRN' || status === 'PAR' || status === 'TOX') {
    o = Math.floor(o * 15 / 10);
  }
  return o;
}

function isqrt(nIn) {
  const n = Math.max(0, Math.floor(nIn));
  let r = Math.floor(Math.sqrt(n));
  while (r * r > n) r -= 1;
  while ((r + 1) * (r + 1) <= n) r += 1;
  return r;
}

// The shake threshold for odds a (0 < a <= 254), compared against a 0..65535 draw.
function shakeThreshold(oddsIn) {
  const o = int(oddsIn, 0);
  if (o <= 0) return 0;
  const inner = isqrt(isqrt(Math.floor(16711680 / o)));
  if (inner <= 0) return 65536;
  return Math.floor(1048560 / inner);
}

// Returns [caught, shakes (0..4; 4 = caught), odds]. Draws up to four
// rng.roll(0, 65535), stopping at the first failure.
function attempt(ballIn, target, rng, ctx) {
  const ball = int(ballIn, POKE);
  if (ball === MASTER) return [true, 4, 255];
  const mon = (target && target.mon) || target || {};
  const o = odds(ball, mon.catchRate, mon.hp, mon.maxHp, mon.status, ctx);
  if (o > 254) return [true, 4, o];
  const b = shakeThreshold(o);
  let shakes = 0;
  while (shakes < 4) {
    const r = rng ? rng.roll(0, 65535) : 65535;
    if (r < b) shakes += 1; else break;
  }
  return [shakes === 4, shakes, o];
}

module.exports = {
  MASTER,
  ULTRA,
  GREAT,
  POKE,
  SAFARI,
  NET,
  DIVE,
  NEST,
  REPEAT,
  TIMER,
  LUXURY,
  PREMIER,
  BONUS,
  SHAKE_TEXT,
  isBall,
  multiplier,
  odds,
  isqrt,
  shakeThreshold,
  attempt,
};
