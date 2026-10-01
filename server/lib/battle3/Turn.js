'use strict';

/*
 * The Gen 3 turn machine: choices in, events out, and one party deciding.
 *
 * Node twin of src/BattleSim3/Turn.lua, itself a fork of BattleSim2's turn
 * machine. The public API is identical -- `create` / `attempt`, `submitChoice`,
 * `autoPick`, `tick`, `drainEvents`, `disconnect`, `reconnect`, `outcome`,
 * `snapshot` -- and so are the seat model, the phases (choice / replace /
 * resolving / over), the clock, the replace phase, participation and the `exp`
 * facts, the `team` rosters and the forced-lock-in pacing, so a hub switches
 * simulators by generation only. Move.js resolves every action as the Gen 3
 * engine does, Residual.js runs the Gen 3 end of turn, and this file orders the
 * turn and owns the bag, running and catching. Contracts C4 (sheet) and C5
 * (events): docs/plans/gen3-battle-sheet.md.
 *
 * **The RNG order is the contract.** One generator per battle (`this.rng`) and
 * the aim stream (`this.aim`, used only by `_autoTarget`). Every draw is
 * `rng.roll(lo, hi)` (Rng.js: top bits; a one-value range draws nothing), and
 * this twin draws at exactly the points the Lua header lists, in that order:
 *
 *   1. battle start: one roll(0,255) per speed-tied group of the switch-in order;
 *      Trace's pick between two or more traceable foes, roll(0, n-1);
 *   2. turn start: Quick Claw roll(0,65535) -- only when two or more seats fight
 *      and a fighting mon holds QUICK_CLAW; one roll(0,255) per group tied on
 *      both priority and speed;
 *   3. runs (wild modes): roll(0,255) for a runner slower than the wild mon;
 *   4. switches (and, interleaved in battler order, the bag items that are
 *      not balls -- those draw nothing): any foe Pursuit aimed at the leaving
 *      seat draws as a move, minus the canceller's and the accuracy draws;
 *   5. bag: balls (after other items, fastest thrower first) draw up to four
 *      roll(0,65535) (none for a Master Ball or odds > 254);
 *   6. moves, in speed order, each drawing only at the points it reaches (the
 *      full list is in the Lua header and docs/plans/gen3-battle-sheet.md §8;
 *      a multi-hit / Triple Kick / Beat Up strike runs its move end, contact
 *      abilities and King's Rock included, after every strike);
 *   7. end of turn: one roll(0,255) per tied group of the re-sort, then the
 *      phases in order (a Future Sight due on a seat emptied this turn draws
 *      in the replace phase instead, after the switch-ins).
 *
 * Nothing else rolls. A battle replays from its seed plus the choice log.
 *
 * A shared team (a side entry with `seats = 2`, the cart's own double battle)
 * is two seats over ONE party and ONE bag: seat 2 is `<playerId>#2`, both
 * carry `owner`. Neither seat benches the other's active mon or the one it has
 * claimed this turn; emptied seats refill in battler order, so with one mon
 * left only one seat is filled; a mon earns EXP once per owner; outcomes,
 * `waiting` and `team` name owners (the Lua header's policy list).
 *
 * Shape differences from the Lua, all forced by the language:
 *
 *   * `create` cannot return a value *and* a reason, so it returns the battle
 *     or null, and `attempt` returns { battle, reason } (battle2's shape).
 *   * `byId` is a Map (the hub reads `sim.byId.get(playerId)`), and the turn's
 *     priority table and the "seen" set of `_beginTurn` are keyed by object,
 *     so they are a Map and a Set.
 *   * Party indices stay 1-based as values (the Lua holds them that way) and
 *     every list read goes through `at()`.
 *
 * Nothing here throws. Bad input is refused with a reason from `attempt` or a
 * plain `false` from `submitChoice`.
 */

const Rng = require('./Rng.js');
const Types = require('./Types.js');
const Status = require('./Status.js');
const Abilities = require('./Abilities.js');
const Items = require('./Items.js');
const Field = require('./Field.js');
const Catch = require('./Catch.js');
const Effects = require('./Effects.js');
const Move = require('./Move.js');
const Residual = require('./Residual.js');
const Events = require('./events.js');
const {
  int, truthy, isTable, own, at, toNumber,
} = require('./lua.js');

const M = {};

M.VERSION = 1;
M.GENERATION = 3;

M.MONS_PER_PARTY = 6; // Config.BATTLE_MON_MAX
M.FIGHTERS_PER_SIDE = 3; // Config.COOP_SIDE
M.SEATS_PER_PARTY = 2; // a shared team fields at most two (the cart's double)
M.CHOICE_TIMEOUT = 60; // Config.BATTLE_CHOICE_TIMEOUT
M.RECONNECT_GRACE = 60; // Config.BATTLE_RECONNECT_GRACE
M.RESOLVE_TIMEOUT = 30; // Config.BATTLE_RESOLVE_TIMEOUT

M.TIE_BREAK_ROLL = 128;
M.AIM_SEED_OFFSET = 1597334677;

M.MODES = {
  '1v1': true, coop_npc: true, coop_pvp: true, wild: true, coop_wild: true,
};
M.SIDES = ['a', 'b'];

// Gen 3 statuses ride the wire in their own tokens, both ways.
M.STATUS_FROM_WIRE = {
  SLP: 'SLP', PSN: 'PSN', BRN: 'BRN', FRZ: 'FRZ', PAR: 'PAR', TOX: 'TOX',
};
M.STATUS_TO_WIRE = M.STATUS_FROM_WIRE;

const ACTIONS = {
  fight: true, item: true, switch: true, run: true, cancel: true,
};

const { E } = Effects;
const T = Move.TARGET;

function maxFighters(mode, side) {
  if (mode === 'coop_wild') {
    return (side === 'a') ? M.FIGHTERS_PER_SIDE : 1;
  }
  if (mode === '1v1' || mode === 'wild') return 1;
  return M.FIGHTERS_PER_SIDE;
}

const WILD_SIDE = 'b';

function isWildMode(mode) {
  return typeof mode === 'string' && mode.includes('wild');
}
M.isWildMode = isWildMode;

function isWildSeat(mode, fighter) {
  return fighter != null && fighter.side === WILD_SIDE && isWildMode(mode);
}

// RUN finishes the fight in wild modes (a real escape attempt) and 1v1 /
// coop_pvp (a concession); everywhere else it is the trainer refusal.
function runEndsBattle(mode) {
  return isWildMode(mode) || mode === '1v1' || mode === 'coop_pvp';
}
M.runEndsBattle = runEndsBattle;

// ------------------------------------------------------------------
// coercion (the C4 sheet)
// ------------------------------------------------------------------

function str(value) {
  if (typeof value === 'string' && value !== '') return value;
  return null;
}

function clamp(v, lo, hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

// Lua's `#t` on a sheet list: 0 for anything that is not an array.
function len(t) {
  return Array.isArray(t) ? t.length : 0;
}

function copyMove(raw) {
  if (!isTable(raw)) return null;
  const pp = Math.max(0, int(raw.pp, 0));
  const out = {
    id: str(raw.id) || 'MOVE',
    num: Math.max(0, int(raw.num, 0)),
    pp,
    maxPp: Math.max(pp, int(raw.maxPp, pp)),
    power: Math.max(0, int(raw.power, 0)),
    accuracy: Math.max(0, int(raw.accuracy, 100)),
    type: clamp(int(raw.type, 0), 0, 31),
    effect: clamp(int(raw.effect, 0), 0, 255),
    chance: clamp(int(raw.chance, 0), 0, 100),
    target: Math.max(0, int(raw.target, 0)),
    priority: clamp(int(raw.priority, 0), -7, 7),
    flags: Math.max(0, int(raw.flags, 0)),
  };
  // `name = str(raw.name)` in the Lua: an absent key, not a null one.
  const name = str(raw.name);
  if (name !== null) out.name = name;
  return out;
}
M.copyMove = copyMove;

// A pool entry: the packed "num:effect:power:type:accuracy:pp:chance:target:
// priority:flags:id" string (sheet doc §3.3) or a row table.
function parsePoolEntry(raw) {
  if (isTable(raw)) return copyMove(raw);
  if (typeof raw !== 'string') return null;
  // (raw .. ":"):gmatch("([^:]*):") is exactly a split on ':'.
  const parts = raw.split(':');
  if (parts.length !== 11) return null;
  const nums = [];
  for (let i = 1; i <= 10; i += 1) {
    const n = toNumber(parts[i - 1]);
    if (n === null || n !== Math.floor(n)) return null;
    nums.push(n);
  }
  const id = parts[10];
  if (!/^[A-Za-z0-9_-]+$/.test(id) || id.length > 40) return null;
  return copyMove({
    num: nums[0],
    effect: nums[1],
    power: nums[2],
    type: nums[3],
    accuracy: nums[4],
    pp: nums[5],
    maxPp: nums[5],
    chance: nums[6],
    target: nums[7],
    priority: nums[8],
    flags: nums[9],
    id,
  });
}
M.parsePoolEntry = parsePoolEntry;

function copyTypes(raw) {
  if (!isTable(raw)) return [0];
  const out = [];
  const n = Math.min(2, len(raw));
  for (let i = 1; i <= n; i += 1) out.push(clamp(int(raw[i - 1], 0), 0, 31));
  if (out.length === 0) return [0];
  if (out.length === 2 && out[1] === out[0]) out.pop();
  return out;
}

// String-keyed numbers only (ivs / evs): a list's numeric keys are skipped,
// as the Lua's `type(k) == "string"` skips them.
function copyNumbers(raw) {
  if (!isTable(raw)) return null;
  const out = {};
  if (Array.isArray(raw)) return out;
  for (const k of Object.keys(raw)) {
    if (toNumber(raw[k]) !== null) out[k] = int(raw[k], 0);
  }
  return out;
}

function copyMon(raw, fallback) {
  if (!isTable(raw)) return null;
  const stats = isTable(raw.stats) ? raw.stats : {};
  const maxHp = Math.max(1, int(raw.maxHp, 1));
  let hp = (raw.hp == null) ? maxHp : Math.max(0, int(raw.hp, 0));
  if (hp > maxHp) hp = maxHp;
  const status = Status.normalise(str(raw.status));
  const moves = [];
  if (isTable(raw.moves)) {
    const n = len(raw.moves);
    for (let i = 1; i <= n; i += 1) {
      if (moves.length >= 4) break;
      const mv = copyMove(raw.moves[i - 1]);
      if (mv) moves.push(mv);
    }
  }
  let hp3 = null;
  if (isTable(raw.hiddenPower)) {
    hp3 = {
      type: clamp(int(raw.hiddenPower.type, 0), 0, 17),
      power: clamp(int(raw.hiddenPower.power, 70), 1, 255),
    };
  }
  let beatUp = null;
  if (isTable(raw.beatUp)) {
    beatUp = { atk: Math.max(1, int(raw.beatUp.atk, 50)), def: Math.max(1, int(raw.beatUp.def, 50)) };
  }
  let { gender } = raw;
  if (gender !== 'M' && gender !== 'F') gender = 'U';
  const out = {
    species: str(raw.species) || '?',
    speciesId: str(raw.speciesId),
    speciesNum: Math.max(0, int(raw.speciesNum, 0)),
    slot: Math.max(0, int(raw.slot, Math.max(0, int(fallback, 0)))),
    level: clamp(int(raw.level, 1), 1, 100),
    hp,
    maxHp,
    stats: {
      atk: Math.max(1, int(stats.atk, 1)),
      def: Math.max(1, int(stats.def, 1)),
      spe: Math.max(1, int(stats.spe, 1)),
      spa: Math.max(1, int(stats.spa, 1)),
      spd: Math.max(1, int(stats.spd, 1)),
    },
    types: copyTypes(raw.types),
    ability: clamp(int(raw.ability, 0), 0, 255),
    abilityName: str(raw.abilityName),
    heldItem: Math.max(0, int(raw.heldItem, 0)),
    holdEffect: Math.max(0, int(raw.holdEffect, 0)),
    holdParam: Math.max(0, int(truthy(raw.holdEffectParam) ? raw.holdEffectParam : raw.holdParam, 0)),
    itemName: str(raw.itemName),
    gender,
    friendship: clamp(int(raw.friendship, 70), 0, 255),
    weight: Math.max(0, int(raw.weight, 0)),
    nature: clamp(int(raw.nature, 0), 0, 24),
    hiddenPower: hp3,
    beatUp,
    status,
    sleepTurns: (status === 'SLP') ? int(raw.sleepTurns, null) : null,
    catchRate: clamp(int(raw.catchRate, 255), 0, 255),
    moves,
    ivs: copyNumbers(raw.ivs),
    evs: copyNumbers(raw.evs),
    personality: int(raw.personality, null),
    otId: int(raw.otId, null),
  };
  if (out.heldItem === 0) {
    out.holdEffect = 0;
    out.holdParam = 0;
  }
  return out;
}
M.copyMon = copyMon;

// A bag sheet: [{ id, count, name? }] or { [id]: count }, numeric ids.
// Returns [bag, names] (keyed by the numeric id) or [null, null].
function copyBag(raw) {
  if (!isTable(raw)) return [null, null];
  const out = {};
  const names = {};
  let any = false;
  const put = (id, count, name) => {
    const n = Items.idOf(id);
    const c = int(count, 0);
    if (n == null || c == null || c < 1) return;
    out[n] = (truthy(out[n]) ? out[n] : 0) + c;
    if (str(name)) names[n] = name;
    any = true;
  };
  if (Array.isArray(raw) && raw.length > 0) {
    for (const entry of raw) {
      if (entry == null) break; // ipairs stops at the first hole
      if (isTable(entry)) put(entry.id, entry.count, entry.name);
    }
  } else if (!Array.isArray(raw)) {
    for (const id of Object.keys(raw)) put(id, raw[id]);
  }
  if (!any) return [null, null];
  return [out, names];
}

// ------------------------------------------------------------------
// the battle
// ------------------------------------------------------------------

function Battle() {}
M.Battle = Battle;

Move.install(Battle);
Residual.install(Battle);

Battle.TIE_BREAK_ROLL = M.TIE_BREAK_ROLL;
Battle.prototype.TIE_BREAK_ROLL = M.TIE_BREAK_ROLL;

function firstLiving(mons, skip) {
  for (let i = 1; i <= mons.length; i += 1) {
    if (mons[i - 1].hp > 0 && i !== skip) return i;
  }
  return null;
}

// The seat's standing mon (the party table), or null.
function activeMon(fighter) {
  const { b } = fighter;
  if (b && b.mon.hp > 0) return b.mon;
  return null;
}

function partyIndexOf(fighter, wireSlot) {
  for (let i = 1; i <= fighter.mons.length; i += 1) {
    if (fighter.mons[i - 1].slot === wireSlot) return i;
  }
  return wireSlot + 1;
}

// Lua's `a or b` for operands that draw nothing.
function orv(a, b) {
  return truthy(a) ? a : b;
}

Battle.prototype._newBattler = function _newBattler(fighter, index) {
  const mon = at(fighter.mons, index);
  const t1 = mon.types[0];
  const t2 = mon.types[1];
  const b = {
    fighter,
    slot: fighter.slot,
    side: fighter.side,
    mon,
    partyIndex: index,
    speciesNum: mon.speciesNum,
    type1: t1,
    type2: (t2 != null && t2 !== t1) ? t2 : null,
    ability: Abilities.nameOf(mon.ability),
    abilityName: mon.abilityName,
    stats: mon.stats,
    moves: mon.moves,
    overlay: false,
    stages: {
      atk: 0, def: 0, spe: 0, spa: 0, spd: 0, acc: 0, eva: 0,
    },
    isFirstTurn: 2,
    toxicCounter: 0,
  };
  return b;
};

Battle.prototype._sendEvent = function _sendEvent(fighter) {
  const { b } = fighter;
  const { mon } = b;
  this._emit('send', {
    slot: fighter.slot,
    side: fighter.side,
    hp: mon.hp,
    maxHp: mon.maxHp,
    text: mon.species,
    speciesId: mon.speciesId,
    level: mon.level,
    mon: fighter.active - 1,
    status: mon.status,
    confused: (int(b.confusion, 0) > 0) ? 1 : null,
  });
};

// opts:
//   id, mode, seed, typeTable (alias chart), specialTypes, movePool, terrain,
//   weather, underwater, choiceTimeout, reconnectGrace, resolveTimeout, now,
//   sides = { a: [{ playerId, name, mons, bag, seats? }], b: [...] }
//
// `seats = 2` makes one entry a shared team: two fighters over the same `mons`
// and `bag` -- seat 1 keeps `playerId`, seat 2 is `playerId + '#2'`, both have
// `owner = playerId` -- which is how the cart fields one trainer's party in a
// double battle (gPlayerParty / gEnemyParty behind battlers 0 and 2, or 1 and
// 3). The leads are the first two living mons; with only one, seat 2 starts
// empty. Every fighter carries `owner` and `seats` (the list of seats over its
// party, in slot order: itself alone without `seats = 2`).
//
// Returns { battle, reason }: the battle and null, or null and why.
function attempt(opts) {
  const refuse = (reason) => ({ battle: null, reason });
  if (!isTable(opts)) return refuse('battle needs an options table');

  const mode = own(M.MODES, opts.mode) ? opts.mode : '1v1';

  const self = Object.create(Battle.prototype);
  Object.assign(self, {
    id: str(opts.id) || 'battle',
    mode,
    seed: int(opts.seed, 0),
    rng: Rng.create(int(opts.seed, 0)),
    aim: Rng.create(int(opts.seed, 0) + M.AIM_SEED_OFFSET),
    typeTable: Types.copyTable(orv(opts.typeTable, opts.chart)),
    specialTypes: null,
    pool: null,
    terrain: clamp(int(opts.terrain, Field.DEFAULT_TERRAIN), 0, 9),
    initialWeather: Field.kind(opts.weather),
    underwater: opts.underwater === true,
    field: { weather: null, weatherTurns: 0 },
    sides: { a: Field.newSide(), b: Field.newSide() },
    choiceTimeout: Math.max(0, int(opts.choiceTimeout, M.CHOICE_TIMEOUT)),
    reconnectGrace: Math.max(0, int(opts.reconnectGrace, M.RECONNECT_GRACE)),
    resolveTimeout: Math.max(0, int(opts.resolveTimeout, M.RESOLVE_TIMEOUT)),
    now: Math.max(0, int(opts.now, 0)),
    phase: 'choice',
    turn: 1,
    seq: 0,
    buffer: [],
    pendingExp: [],
    fighters: [],
    byId: new Map(),
    bySide: { a: [], b: [] },
    order: [],
    result: null,
    deadline: null,
    resolveDeadline: null,
    fleeAttempts: 0,
    payDay: { a: 0, b: 0 }, // pret gPaydayMoney, per side (Effects PAYDAY)
    usedHeldItems: {}, // Recycle's memory, per field slot (Items.consume)
  });

  if (isTable(opts.specialTypes)) {
    const set = {};
    const n = len(opts.specialTypes);
    for (let i = 1; i <= n; i += 1) set[clamp(int(opts.specialTypes[i - 1], 0), 0, 31)] = true;
    self.specialTypes = set;
  }
  if (isTable(opts.movePool)) {
    const pool = {};
    let any = false;
    const n = len(opts.movePool);
    for (let i = 1; i <= n; i += 1) {
      const row = parsePoolEntry(opts.movePool[i - 1]);
      if (row && row.num > 0 && !truthy(pool[row.num])) {
        pool[row.num] = row;
        any = true;
      }
    }
    if (any) self.pool = pool;
  }

  const sides = isTable(opts.sides) ? opts.sides : {};
  for (const side of M.SIDES) {
    const roster = isTable(sides[side]) ? sides[side] : [];
    const count = len(roster);
    if (count === 0) return refuse(`side ${side} has nobody on it`);
    if (count > maxFighters(mode, side)) {
      return refuse(`side ${side} has more fighters than ${mode} allows`);
    }
    if (mode === 'coop_wild' && side === 'a' && count < 2) {
      return refuse('side a has fewer fighters than coop_wild allows');
    }
    for (let index = 1; index <= count; index += 1) {
      const entry = roster[index - 1];
      if (!isTable(entry)) return refuse(`side ${side} has a malformed fighter`);
      const playerId = str(entry.playerId);
      if (!playerId) return refuse(`a fighter on side ${side} has no playerId`);
      if (self.byId.has(playerId)) return refuse(`duplicate playerId ${playerId}`);
      const seats = (entry.seats == null) ? 1 : int(entry.seats, 0);
      if (seats < 1 || seats > M.SEATS_PER_PARTY) {
        return refuse(`${playerId} has a bad seat count`);
      }
      const bucket = self.bySide[side];
      if (bucket.length + seats > maxFighters(mode, side)) {
        return refuse(`side ${side} has more fighters than ${mode} allows`);
      }
      for (let seat = 2; seat <= seats; seat += 1) {
        if (self.byId.has(`${playerId}#${seat}`)) {
          return refuse(`duplicate playerId ${playerId}#${seat}`);
        }
      }
      const mons = [];
      if (isTable(entry.mons)) {
        const n = len(entry.mons);
        for (let i = 1; i <= n; i += 1) {
          if (mons.length >= M.MONS_PER_PARTY) break;
          const mon = copyMon(entry.mons[i - 1], mons.length);
          if (mon) mons.push(mon);
        }
      }
      if (mons.length === 0) return refuse(`${playerId} brought no monsters`);
      const [bag, names] = copyBag(entry.bag);
      const bagNames = names || {};
      const party = [];
      let lead = null;
      for (let seat = 1; seat <= seats; seat += 1) {
        // The cart's leads: the first usable mon, then the next one after it
        // (pokefirered/src/battle_controllers.c SetBattlePartyIds); none left,
        // and the seat starts empty (pret's absent battler).
        let active = null;
        if (seat === 1) {
          lead = firstLiving(mons);
          active = lead;
        } else if (lead != null) {
          active = firstLiving(mons, lead);
        }
        const fighter = {
          playerId: (seat === 1) ? playerId : `${playerId}#${seat}`,
          owner: playerId,
          seats: party,
          name: str(entry.name) || playerId,
          side,
          index: bucket.length + 1,
          slot: Events.fieldSlot(side, bucket.length + 1),
          mons,
          bag,
          bagNames,
          active,
          connected: true,
          graceEndsAt: null,
          choice: null,
          team: null,
          fought: {},
        };
        party.push(fighter);
        self.fighters.push(fighter);
        self.byId.set(fighter.playerId, fighter);
        bucket.push(fighter);
      }
    }
  }

  // pret battler ids interleave the sides: a1, b1, a2, b2, a3, b3.
  for (let i = 1; i <= M.FIGHTERS_PER_SIDE; i += 1) {
    if (self.bySide.a[i - 1]) self.order.push(self.bySide.a[i - 1]);
    if (self.bySide.b[i - 1]) self.order.push(self.bySide.b[i - 1]);
  }
  self.double = self.bySide.a.length > 1 || self.bySide.b.length > 1;

  for (const fighter of self.fighters) {
    if (fighter.active != null) fighter.b = self._newBattler(fighter, fighter.active);
  }
  for (const fighter of self.fighters) self._refield(fighter);
  for (const fighter of self.fighters) {
    if (fighter.b) self._sendEvent(fighter);
  }

  self.phase = 'resolving';
  self._battleStart();
  self._drainExp();
  self.phase = 'choice';
  if (!truthy(self.result) && self._anyMustReplace()) {
    self._openReplace();
    return { battle: self, reason: null };
  }
  self._openTurn();
  return { battle: self, reason: null };
}
M.attempt = attempt;

// The battle, or null when it was refused. `attempt` carries the reason.
function create(opts) {
  return attempt(opts).battle;
}
M.create = create;

// ------------------------------------------------------------------
// events
// ------------------------------------------------------------------

Battle.prototype._emit = function _emit(kind, fields) {
  const event = Events.build(kind, fields);
  if (!event) return null;
  this.seq += 1;
  event.battle = this.id;
  event.seq = this.seq;
  this.buffer.push(event);
  return event;
};

// One roster per party: a shared team's second seat holds the same list, so
// its first seat speaks for both.
Battle.prototype._syncTeams = function _syncTeams() {
  for (const fighter of this.fighters) {
    if (fighter.seats[0] === fighter) {
      const roster = Events.teamString(fighter.mons);
      if (roster !== fighter.team) {
        fighter.team = roster;
        this._emit('team', { slot: fighter.slot, side: fighter.side, team: roster });
      }
    }
  }
};

// The seats one owner fields, in slot order: both of a shared team, else the
// one fighter (a seat id finds its party too). Empty for an unknown id.
Battle.prototype.seatsOf = function seatsOf(ownerId) {
  const fighter = this.byId.get(str(ownerId) || '');
  if (!fighter) return [];
  return fighter.seats.slice();
};

Battle.prototype.drainEvents = function drainEvents() {
  const out = this.buffer;
  this.buffer = [];
  return out;
};

// ------------------------------------------------------------------
// the field
// ------------------------------------------------------------------

Battle.prototype._foeSeats = function _foeSeats(fighter) {
  const other = (fighter.side === 'a') ? 'b' : 'a';
  return this.bySide[other];
};

Battle.prototype._fighterAtSlot = function _fighterAtSlot(slot) {
  for (const fighter of this.fighters) {
    if (fighter.slot === slot) return fighter;
  }
  return null;
};

Battle.prototype._firstLivingFoe = function _firstLivingFoe(fighter) {
  for (const foe of this._foeSeats(fighter)) {
    if (activeMon(foe)) return foe;
  }
  return null;
};

// BattleSim2's aim stream: uniform over the living opposing seats, one byte
// drawn only when two or more stand.
Battle.prototype._autoTarget = function _autoTarget(fighter) {
  const living = [];
  for (const foe of this._foeSeats(fighter)) {
    if (activeMon(foe)) living.push(foe);
  }
  if (living.length === 0) return null;
  if (living.length === 1) return living[0];
  return living[this.aim.byte() % living.length];
};

Battle.prototype._sideAlive = function _sideAlive(side) {
  for (const fighter of this.bySide[side]) {
    if (firstLiving(fighter.mons) != null) return true;
  }
  return false;
};

// The side's players for an outcome: owners, each once (a shared team's two
// seats are one player).
Battle.prototype._sidePlayers = function _sidePlayers(side) {
  const out = [];
  const seen = new Set();
  for (const fighter of this.bySide[side]) {
    if (!seen.has(fighter.owner)) {
      seen.add(fighter.owner);
      out.push(fighter.owner);
    }
  }
  return out;
};

// Whether a seat that must replace has a mon to send. A shared team refills
// its emptied seats in battler order -- pret HandleFaintedMonActions walks the
// battlers in order and HasNoMonsToSwitch counts the partner's
// monToSwitchIntoId -- so a sibling ahead of this seat that is still owed a
// mon takes one off the bench first. With one mon left only one seat refills.
Battle.prototype._canRefill = function _canRefill(fighter) {
  let bench = this.benchOf(fighter).length;
  for (const seat of fighter.seats) {
    if (seat === fighter) break;
    if (truthy(seat.mustReplace) && seat.choice == null) bench -= 1;
  }
  return bench > 0;
};

// A shared team's seat whose sibling took the last bench mon stays empty for
// good (pret marks the battler absent, gAbsentBattlerFlags, and never asks it
// again). A one-seat fighter is only ever owed a mon it still has.
Battle.prototype._vacateSeats = function _vacateSeats() {
  for (const fighter of this.fighters) {
    if (truthy(fighter.mustReplace) && fighter.seats.length > 1 && this.benchOf(fighter).length === 0) {
      fighter.mustReplace = null;
      fighter.pendingFought = null;
    }
  }
};

Battle.prototype._owes = function _owes(fighter) {
  if (fighter.choice != null) return false;
  if (truthy(fighter.mustReplace)) return this._canRefill(fighter);
  if (this.phase === 'replace') return false;
  if (activeMon(fighter) == null) return false;
  return true;
};

// Forced lock-in (the cart withholds the menu): recharge, a two-turn release,
// Bide, rampage, Uproar, Rollout. The resolution narrates, not the fill.
Battle.prototype._fillForcedChoices = function _fillForcedChoices() {
  for (const fighter of this.fighters) {
    const { b } = fighter;
    if (fighter.choice == null && b && b.mon.hp > 0) {
      let choice = null;
      if (truthy(b.mustRecharge)) {
        choice = { action: 'fight', recharge: true, move: orv(b.lastSlot, 1) };
      } else if (truthy(b.lockedNum)) {
        choice = { action: 'fight', locked: true, move: orv(b.lockedSlot, 1) };
      }
      if (choice) {
        fighter.forced = true;
        fighter.choice = choice;
        this._emit('chose', { slot: fighter.slot, side: fighter.side, text: fighter.name });
      }
    }
  }
};

Battle.prototype._anyDisconnected = function _anyDisconnected() {
  for (const fighter of this.fighters) {
    if (!truthy(fighter.connected)) return true;
  }
  return false;
};

// ------------------------------------------------------------------
// choices
// ------------------------------------------------------------------

// Whether the bag still holds `item` for this seat. A shared team has one
// bag, and the cart takes a medicine out of it when it is CHOSEN -- the
// engine's partner cancel cannot give a non-ball item back (init.lua
// D.cancelPartner, pokefirered/src/battle_controller_player.c:286) -- so one
// the sibling seat has filed this turn is not there to choose again. A flute
// is never spent, so it is never held back.
Battle.prototype._bagHas = function _bagHas(fighter, item) {
  if (!truthy(fighter.bag)) return false;
  const held = fighter.bag[item];
  let n = truthy(held) ? held : 0;
  const effect = Items.bagEffect(item);
  if (!(effect && truthy(effect.noConsume))) {
    for (const seat of fighter.seats) {
      const c = seat.choice;
      if (seat !== fighter && c && c.action === 'item' && c.item === item) n -= 1;
    }
  }
  return n > 0;
};

// The battler party member `index` stands as: this seat's, or -- a shared
// team -- the sibling seat's, so a medicine on the partner works on its
// battler (the engine's items.lua active_for_slot finds battler 0 or 2).
Battle.prototype._partyBattler = function _partyBattler(fighter, index) {
  const seat = this.fieldedSeat(fighter, index);
  return (seat && seat.b) ? seat.b : null;
};

Battle.prototype._spendBag = function _spendBag(fighter, item) {
  if (!truthy(fighter.bag)) return;
  const n = fighter.bag[item];
  if (!truthy(n)) return;
  if (n <= 1) delete fighter.bag[item]; else fighter.bag[item] = n - 1;
};

// Whether a bag item would do anything to this party member (the cart's
// "It won't have any effect." refuses it before the turn is spent).
Battle.prototype._itemHasEffect = function _itemHasEffect(fighter, effect, index, moveIndex) {
  const mon = at(fighter.mons, index);
  if (!mon) return false;
  const b = this._partyBattler(fighter, index);
  if (truthy(effect.revive)) return mon.hp <= 0;
  if (mon.hp <= 0) return false;
  if (truthy(effect.activeOnly)) {
    if (!b) return false;
    if (truthy(effect.stage)) return b.stages[effect.stage] < 6;
    if (truthy(effect.focusEnergy)) return !truthy(b.focusEnergy);
    if (truthy(effect.mist)) return int(this.sides[b.side].mistTurns, 0) === 0;
    return false;
  }
  let any = false;
  if (truthy(effect.heal) || truthy(effect.healFull)) any = any || mon.hp < mon.maxHp;
  if (truthy(effect.cure)) {
    const s = Status.normalise(mon.status);
    any = any || (s != null && effect.cure[s] === true);
  }
  if (truthy(effect.confusion) && b) any = any || int(b.confusion, 0) > 0;
  if (truthy(effect.attract) && b) any = any || b.infatuatedWith != null;
  const moves = (b && truthy(b.moves)) ? b.moves : mon.moves;
  if (truthy(effect.pp) || truthy(effect.ppFull)) {
    const mv = at(moves, orv(moveIndex, 0));
    any = any || (mv != null && mv.pp < mv.maxPp);
  }
  if (truthy(effect.ppAll) || truthy(effect.ppAllFull)) {
    for (let i = 1; i <= moves.length; i += 1) {
      if (moves[i - 1].pp < moves[i - 1].maxPp) any = true;
    }
  }
  return any;
};

Battle.prototype._switchBlocked = function _switchBlocked(b) {
  if (!b) return false;
  if (truthy(this.isTrapped(b))) return true;
  return Abilities.escapeBlocker(this, b)[0] != null;
};

Battle.prototype._normaliseChoice = function _normaliseChoice(fighter, choice) {
  const { action } = choice;

  if (truthy(fighter.mustReplace)) {
    if (action !== 'switch') return null;
    const slot = int(choice.slot, null);
    if (slot == null) return null;
    const target = partyIndexOf(fighter, slot);
    const bench = at(fighter.mons, target);
    if (!bench || bench.hp <= 0) return null;
    if (this.partyTaken(fighter, target)) return null;
    return { action: 'switch', slot: target };
  }

  const { b } = fighter;
  if (!b || b.mon.hp <= 0) return null;

  if (action === 'run') {
    if (isWildMode(this.mode)) {
      const he = Items.of(b)[0];
      if (he !== Items.HOLD.CAN_ALWAYS_RUN && b.ability !== 'RUN_AWAY' && this._switchBlocked(b)) {
        return null;
      }
    }
    return { action: 'run' };
  }

  if (action === 'item') {
    const item = Items.idOf(choice.item);
    if (item == null) return null;
    if (isWildSeat(this.mode, fighter)) return null;
    if (truthy(fighter.bag) && !this._bagHas(fighter, item)) return null;
    const effect = Items.bagEffect(item);
    const out = { action: 'item', item, dexCaught: choice.dexCaught === true };
    if (!effect) return out; // "But it failed!", turn spent
    if (truthy(effect.ball) || truthy(effect.escape) || truthy(effect.flute)) return out;
    let index = fighter.active;
    if (choice.slot != null) {
      const slot = int(choice.slot, null);
      if (slot == null) return null;
      index = partyIndexOf(fighter, slot);
      if (!at(fighter.mons, index)) return null;
    }
    // An X item / Dire Hit / Guard Spec. is the choosing battler's own, even
    // in a double (pokefirered/src/item_use.c ItemUseInBattle_StatIncrease
    // reads gBattlerInMenuId; the engine's items.lua user_battler); a
    // medicine may name any party member, the partner's battler included.
    if (truthy(effect.activeOnly) && index !== fighter.active) return null;
    out.slot = index;
    if (choice.move != null) {
      const mv = int(choice.move, null);
      if (mv == null) return null;
      out.move = mv + 1;
    } else if (truthy(effect.needsMove)) {
      return null;
    }
    if (!this._itemHasEffect(fighter, effect, index, out.move)) return null;
    return out;
  }

  if (action === 'switch') {
    const slot = int(choice.slot, null);
    if (slot == null) return null;
    const target = partyIndexOf(fighter, slot);
    const bench = at(fighter.mons, target);
    if (!bench || bench.hp <= 0 || this.partyTaken(fighter, target)) return null;
    if (this._switchBlocked(b)) return null;
    return { action: 'switch', slot: target };
  }

  if (action === 'fight') {
    const index = int(choice.move, null);
    if (index == null) return null;
    const out = { action: 'fight', move: index + 1 };
    if (!truthy(this.hasUsableMove(b))) {
      out.struggle = true;
      out.move = 1;
    } else {
      const encoreSlot = (int(b.encoreTurns, 0) > 0 && truthy(b.encoreNum))
        ? this.slotOfNum(b, b.encoreNum) : null;
      if (truthy(encoreSlot)) {
        out.move = encoreSlot;
      } else {
        if (!truthy(at(b.moves, index + 1))) return null;
        const bad = this.moveLimitations(b);
        if (truthy(bad[index + 1])) return null;
      }
    }
    const row = out.struggle ? Move.STRUGGLE : at(b.moves, out.move);
    // Aimed as the cart's menu aims it: a Ghost's CURSE like a SELECTED move.
    const ttype = this.aimTarget(b, row);
    if (ttype === T.SELECTED || ttype === T.USER_OR_SELECTED) {
      let tf;
      if (choice.target != null) {
        tf = this._fighterAtSlot(int(choice.target, -1));
        if (!tf || tf === fighter) return null;
        if (!activeMon(tf) && !truthy(tf.mustReplace)) return null;
      } else {
        tf = this._firstLivingFoe(fighter);
        if (!tf) {
          for (const foe of this._foeSeats(fighter)) {
            if (truthy(foe.mustReplace)) {
              tf = foe;
              break;
            }
          }
        }
      }
      if (!tf) return { action: 'skip' };
      out.target = tf.slot;
    } else {
      const tf = this._firstLivingFoe(fighter);
      if (tf) out.target = tf.slot;
    }
    if (choice.pass != null) {
      const p = int(choice.pass, null);
      if (p != null) {
        const idx = partyIndexOf(fighter, p);
        const pm = at(fighter.mons, idx);
        if (pm && pm.hp > 0 && !this.partyTaken(fighter, idx)) {
          out.pass = idx;
        }
      }
    }
    return out;
  }

  return null;
};

Battle.prototype.submitChoice = function submitChoice(playerId, choice) {
  if (this.phase !== 'choice' && this.phase !== 'replace') return false;
  if (!isTable(choice)) return false;
  const fighter = this.byId.get(str(playerId) || '');
  if (!fighter) return false;
  if (!truthy(fighter.connected)) return false;
  if (!own(ACTIONS, choice.action)) return false;
  if (this.phase === 'replace' && !this._owes(fighter)) return false;

  if (choice.action === 'cancel') {
    if (this.phase === 'replace') return false;
    if (fighter.choice == null) return false;
    if (truthy(fighter.forced)) return false;
    this._emit('unchose', { slot: fighter.slot, side: fighter.side, text: fighter.name });
    fighter.choice = null;
    return true;
  }

  if (fighter.choice != null) return false;
  if (truthy(fighter.mustReplace)) {
    if (choice.action !== 'switch') return false;
  } else if (!activeMon(fighter)) {
    return false;
  }

  const normalised = this._normaliseChoice(fighter, choice);
  if (!normalised) return false;
  fighter.choice = normalised;
  this._emit('chose', { slot: fighter.slot, side: fighter.side, text: fighter.name });
  this._maybeResolve();
  return true;
};

Battle.prototype._anyoneOwes = function _anyoneOwes() {
  for (const fighter of this.fighters) {
    if (this._owes(fighter)) return true;
  }
  return false;
};

Battle.prototype._maybeResolve = function _maybeResolve() {
  if (this.phase !== 'choice' && this.phase !== 'replace') return false;
  if (this._anyDisconnected()) return false;
  for (const fighter of this.fighters) {
    if (this._owes(fighter)) return false;
  }
  if (this.phase === 'replace') {
    this._closeReplace();
    return true;
  }
  this._resolveTurn();
  return true;
};

// ------------------------------------------------------------------
// the auto-pick (timeout / NPC): BattleSim2's heuristic on Gen 3 ids
// ------------------------------------------------------------------

// EFFECT_* status moves worth using, by preference.
const AUTO_STATUS_PRI = {
  [E.SLEEP]: 4,
  [E.PARALYZE]: 3,
  [E.TOXIC]: 3,
  [E.POISON]: 2,
  [E.WILL_O_WISP]: 2,
  [E.CONFUSE]: 1,
  [E.LEECH_SEED]: 1,
};
// Self boosts / screens / Substitute: stat key, or true for a flag move.
const AUTO_SETUP = {
  [E.ATTACK_UP]: 'atk',
  [E.DEFENSE_UP]: 'def',
  [E.SPEED_UP]: 'spe',
  [E.SPECIAL_ATTACK_UP]: 'spa',
  [E.SPECIAL_DEFENSE_UP]: 'spd',
  [E.ATTACK_UP_2]: 'atk',
  [E.DEFENSE_UP_2]: 'def',
  [E.SPEED_UP_2]: 'spe',
  [E.SPECIAL_ATTACK_UP_2]: 'spa',
  [E.SPECIAL_DEFENSE_UP_2]: 'spd',
  [E.CALM_MIND]: 'spa',
  [E.BULK_UP]: 'atk',
  [E.DRAGON_DANCE]: 'atk',
  [E.COSMIC_POWER]: 'def',
  [E.FOCUS_ENERGY]: true,
  [E.LIGHT_SCREEN]: true,
  [E.REFLECT]: true,
  [E.SUBSTITUTE]: true,
};
// Heal items, strongest first; cures by status; X items (Gen 3 ids).
const AUTO_HEAL_PREF = [19, 20, 21, 31, 29, 28, 22, 27, 26, 30, 13, 44, 142, 139];
const AUTO_STATUS_CURE = {
  PSN: [19, 23, 32, 38, 141, 14, 135],
  TOX: [19, 23, 32, 38, 141, 14, 135],
  BRN: [19, 23, 32, 38, 141, 15, 136],
  FRZ: [19, 23, 32, 38, 141, 16, 137],
  SLP: [19, 23, 32, 38, 141, 17, 134, 39],
  PAR: [19, 23, 32, 38, 141, 18, 133],
};
const AUTO_X_ITEM = [75, 76, 77, 79, 74, 73];

Battle.prototype._effectivenessProduct = function _effectivenessProduct(moveType, defender) {
  const [product] = Types.effectivenessOf(this.typeTable, moveType, defender.type1, defender.type2,
    defender.identified);
  return product;
};

Battle.prototype._bestSeBench = function _bestSeBench(fighter, defender) {
  if (!defender) return null;
  let best = null;
  let bestEff = 100;
  for (let i = 1; i <= fighter.mons.length; i += 1) {
    if (!this.partyTaken(fighter, i)) {
      const bench = fighter.mons[i - 1];
      if (bench && bench.hp > 0) {
        let maxEff = 100;
        for (let j = 1; j <= bench.moves.length; j += 1) {
          const m = bench.moves[j - 1];
          if (m.pp > 0 && m.power > 0) {
            const eff = this._effectivenessProduct(m.type, defender);
            if (eff > maxEff) maxEff = eff;
          }
        }
        if (maxEff > 100) {
          if (best == null || maxEff > bestEff || (maxEff === bestEff && i < best)) {
            best = i;
            bestEff = maxEff;
          }
        }
      }
    }
  }
  return best;
};

Battle.prototype._autoItemChoice = function _autoItemChoice(fighter, b) {
  if (!truthy(fighter.bag)) return null;
  if (isWildSeat(this.mode, fighter)) return null;
  const { mon } = b;
  const s = Status.normalise(mon.status);
  if (s) {
    for (const id of (AUTO_STATUS_CURE[s] || [])) {
      if (this._bagHas(fighter, id)) {
        return { action: 'item', item: id, slot: fighter.active };
      }
    }
  }
  if (mon.hp < mon.maxHp && mon.hp * 2 <= mon.maxHp) {
    for (const id of AUTO_HEAL_PREF) {
      if (this._bagHas(fighter, id)) {
        return { action: 'item', item: id, slot: fighter.active };
      }
    }
  }
  const flat = b.stages.atk <= 0 && b.stages.def <= 0 && b.stages.spe <= 0 && b.stages.spa <= 0;
  if (flat && !truthy(b.focusEnergy)) {
    for (const id of AUTO_X_ITEM) {
      if (this._bagHas(fighter, id)) {
        const effect = Items.bagEffect(id);
        if (effect && this._itemHasEffect(fighter, effect, fighter.active)) {
          return { action: 'item', item: id, slot: fighter.active };
        }
      }
    }
  }
  return null;
};

Battle.prototype._autoChoice = function _autoChoice(fighter) {
  if (truthy(fighter.mustReplace)) {
    const foe = this._autoTarget(fighter);
    const defender = foe ? foe.b : null;
    const se = this._bestSeBench(fighter, defender);
    if (se != null) return { action: 'switch', slot: se };
    const next = this.benchOf(fighter)[0];
    if (next != null) return { action: 'switch', slot: next };
    return null;
  }

  const { b } = fighter;
  if (!b || b.mon.hp <= 0) return null;
  if (truthy(b.mustRecharge)) return { action: 'fight', recharge: true, move: orv(b.lastSlot, 1) };
  if (truthy(b.lockedNum)) return { action: 'fight', locked: true, move: orv(b.lockedSlot, 1) };

  let foe = this._autoTarget(fighter);
  if (!foe) {
    for (const f of this._foeSeats(fighter)) {
      if (truthy(f.mustReplace)) {
        foe = f;
        break;
      }
    }
  }
  if (!foe) return null;

  if (!truthy(this.hasUsableMove(b))) {
    return {
      action: 'fight', move: 1, struggle: true, target: foe.slot,
    };
  }
  const defender = foe.b;
  const bad = this.moveLimitations(b);
  if (!defender || defender.mon.hp <= 0) {
    for (let i = 1; i <= b.moves.length; i += 1) {
      if (!truthy(bad[i])) return { action: 'fight', move: i, target: foe.slot };
    }
    return {
      action: 'fight', move: 1, struggle: true, target: foe.slot,
    };
  }

  const itemPick = this._autoItemChoice(fighter, b);
  if (itemPick) return itemPick;

  const ds = defender.stages;
  const foeBoosted = ds.atk >= 2 || ds.def >= 2 || ds.spe >= 2 || ds.spa >= 2
    || truthy(defender.focusEnergy);
  const foeSub = int(defender.substituteHP, 0) > 0;
  const weSlower = this._speedOf(b) < this._speedOf(defender);
  const canSwitch = !this._switchBlocked(b);

  if (b.mon.hp * 4 <= b.mon.maxHp && canSwitch) {
    const se = this._bestSeBench(fighter, defender);
    if (se != null) return { action: 'switch', slot: se };
  }
  if ((foeBoosted || foeSub) && b.mon.hp * 2 <= b.mon.maxHp && canSwitch) {
    const se = this._bestSeBench(fighter, defender);
    if (se != null) return { action: 'switch', slot: se };
  }

  let pick = null;
  let pickEff = -1;
  let pickPow = -1;
  for (let i = 1; i <= b.moves.length; i += 1) {
    const m = b.moves[i - 1];
    if (!truthy(bad[i]) && m.power > 0) {
      const eff = this._effectivenessProduct(m.type, defender);
      if (pick == null || eff > pickEff || (eff === pickEff && m.power > pickPow)
         || (eff === pickEff && m.power === pickPow && i < pick)) {
        pick = i;
        pickEff = eff;
        pickPow = m.power;
      }
    }
  }

  if ((pick == null || pickEff === 0) && canSwitch) {
    const se = this._bestSeBench(fighter, defender);
    if (se != null) return { action: 'switch', slot: se };
  }
  if (pick != null && pickEff > 100) {
    return { action: 'fight', move: pick, target: foe.slot };
  }

  if (!truthy(Status.normalise(defender.mon.status)) && !foeSub) {
    let statusPick = null;
    let statusPri = -1;
    for (let i = 1; i <= b.moves.length; i += 1) {
      const m = b.moves[i - 1];
      if (!truthy(bad[i]) && m.power === 0) {
        const pri = AUTO_STATUS_PRI[m.effect];
        if (pri != null && pri > statusPri) {
          statusPick = i;
          statusPri = pri;
        }
      }
    }
    if (statusPick != null && (weSlower || foeBoosted || pick == null || pickEff <= 100)) {
      return { action: 'fight', move: statusPick, target: foe.slot };
    }
  }

  const flat = b.stages.atk <= 0 && b.stages.def <= 0 && b.stages.spe <= 0 && b.stages.spa <= 0;
  if (flat && !truthy(b.focusEnergy) && !foeBoosted && !foeSub
     && !(weSlower && b.mon.hp * 2 <= b.mon.maxHp)) {
    for (let i = 1; i <= b.moves.length; i += 1) {
      const m = b.moves[i - 1];
      if (!truthy(bad[i]) && m.power === 0) {
        const kind = AUTO_SETUP[m.effect];
        if (kind === true || (typeof kind === 'string' && b.stages[kind] <= 0)) {
          return { action: 'fight', move: i, target: foe.slot };
        }
      }
    }
  }

  if (!(pick != null && pickEff > 0)) {
    pick = null;
    pickPow = -1;
    for (let i = 1; i <= b.moves.length; i += 1) {
      const m = b.moves[i - 1];
      if (!truthy(bad[i]) && (pick == null || m.power > pickPow)) {
        pick = i;
        pickPow = m.power;
      }
    }
  }
  return { action: 'fight', move: orv(pick, 1), target: foe.slot };
};

Battle.prototype._autoChoiceOrSkip = function _autoChoiceOrSkip(fighter) {
  const auto = this._autoChoice(fighter);
  if (auto) return auto;
  if (this.phase === 'choice' && activeMon(fighter)) return { action: 'skip' };
  return null;
};

Battle.prototype.autoPick = function autoPick(playerId) {
  if (this.phase !== 'choice' && this.phase !== 'replace') return false;
  const fighter = this.byId.get(str(playerId) || '');
  if (!fighter) return false;
  if (fighter.choice != null) return false;
  if (this.phase === 'replace' && !this._owes(fighter)) return false;
  if (!truthy(fighter.mustReplace) && !activeMon(fighter)) return false;
  const auto = this._autoChoiceOrSkip(fighter);
  if (!auto) return false;
  fighter.choice = auto;
  this._emit('chose', { slot: fighter.slot, side: fighter.side, text: fighter.name });
  this._maybeResolve();
  return true;
};

// ------------------------------------------------------------------
// phases
// ------------------------------------------------------------------

Battle.prototype._openTurn = function _openTurn() {
  if (this._checkOver()) return;
  this.phase = 'choice';
  this.resolveDeadline = null;
  this.forcedPending = false;
  for (const fighter of this.fighters) {
    fighter.choice = null;
    fighter.forced = null;
    fighter.acted = null;
  }
  this.deadline = (this.choiceTimeout > 0) ? (this.now + this.choiceTimeout) : null;
  this._syncTeams();
  this._emit('turn', { amount: this.turn });
  this._fillForcedChoices();
  if (!this._anyoneOwes()) {
    this.forcedPending = true;
    this.deadline = null;
  }
};

Battle.prototype._anyMustReplace = function _anyMustReplace() {
  for (const fighter of this.fighters) {
    if (truthy(fighter.mustReplace) && this._canRefill(fighter)) return true;
  }
  return false;
};

Battle.prototype._openReplace = function _openReplace() {
  this.phase = 'replace';
  this.resolveDeadline = null;
  this.forcedPending = false;
  for (const fighter of this.fighters) {
    fighter.choice = null;
    fighter.forced = null;
  }
  this.deadline = (this.choiceTimeout > 0) ? (this.now + this.choiceTimeout) : null;
  this._syncTeams();
  for (const fighter of this.fighters) {
    if (this._owes(fighter)) {
      this._emit('turn', { amount: this.turn, slot: fighter.slot });
    }
  }
};

Battle.prototype._closeReplace = function _closeReplace() {
  this.phase = 'resolving';
  for (const fighter of this.order) {
    const { choice } = fighter;
    if (choice && choice.action === 'switch' && !truthy(this.result)) {
      const mon = at(fighter.mons, choice.slot);
      if (mon && mon.hp > 0) {
        const nb = this._switchIn(fighter, choice.slot);
        this.switchInEffects(nb, { spikes: true });
        this._faintSweep();
      }
    }
  }
  if (!truthy(this.result)) this._vacateSeats();
  // A delayed hit that came due on an emptied seat lands on the newcomer, as
  // the cart's replacement-first end of turn has it (Residual.js); one due on
  // a seat just vacated is dropped there.
  if (!truthy(this.result)) this._landPendingFutureSight();
  this._drainExp();
  this.phase = 'choice';
  if (!truthy(this.result)) this._checkOver();
  if (truthy(this.result)) return;
  if (this._anyMustReplace()) {
    this._openReplace();
    return;
  }
  this.turn += 1;
  this._openTurn();
};

// ------------------------------------------------------------------
// switching
// ------------------------------------------------------------------

// Drop every link another battler holds to one that is leaving
// (pokefirered/src/battle_main.c:2329 SwitchInClearSetData / battle_script_
// commands.c:4966).  `baton`: a Baton Pass keeps the passer's Mean Look-style
// traps and Lock-Ons standing -- the cart stores them by battler POSITION, so
// the newcomer inherits them (`_switchIn` re-points them).
Battle.prototype._unlink = function _unlink(old, baton) {
  for (const f of this.order) {
    const { b } = f;
    if (b && b !== old) {
      if (b.infatuatedWith === old) delete b.infatuatedWith;
      if (b.trapSource === old) {
        delete b.trapTurns;
        delete b.trapMove;
        delete b.trapSource;
      }
      if (!truthy(baton)) {
        if (b.trappedBy === old) delete b.trappedBy;
        if (b.lockedOnBy === old) {
          delete b.lockedOnTurns;
          delete b.lockedOnBy;
        }
      }
    }
  }
  for (const side of M.SIDES) {
    if (this.sides[side].followMe === old) this.sides[side].followMe = null;
  }
};

// Put party member `index` out on this seat (voluntary switch, replacement,
// Roar, Baton Pass). `baton` is the battler passing its volatiles on.
Battle.prototype._switchIn = function _switchIn(fighter, index, baton) {
  const old = fighter.b;
  if (old) {
    if (old.mon.hp > 0) Abilities.switchOut(this, old);
    this._unlink(old, baton != null);
    fighter.lastB = old;
  }
  fighter.active = index;
  fighter.mustReplace = null;
  const nb = this._newBattler(fighter, index);
  if (baton) {
    // pokefirered/src/battle_main.c:2350: status2 keeps confusion, Focus
    // Energy, Substitute, escape prevention and Curse; status3 keeps Leech Seed,
    // Lock-On, Perish Song, Ingrain and Mud / Water Sport.
    for (const k of Object.keys(baton.stages)) nb.stages[k] = baton.stages[k];
    nb.confusion = baton.confusion;
    nb.focusEnergy = baton.focusEnergy;
    nb.substituteHP = baton.substituteHP;
    nb.seededBy = baton.seededBy;
    nb.ingrain = baton.ingrain;
    nb.perishTurns = baton.perishTurns;
    nb.cursed = baton.cursed;
    nb.trappedBy = baton.trappedBy;
    nb.lockedOnTurns = baton.lockedOnTurns;
    nb.lockedOnBy = baton.lockedOnBy;
    nb.mudSport = baton.mudSport;
    nb.waterSport = baton.waterSport;
    // ...and what the passer held on others moves with the position: a foe it
    // trapped stays trapped, and a foe it Locked On to is re-armed for two
    // turns for the newcomer (:2356, STATUS3_ALWAYS_HITS_TURN(2)).
    for (const f of this.order) {
      const { b } = f;
      if (b && b !== old) {
        if (b.trappedBy === old) b.trappedBy = nb;
        if (b.lockedOnBy === old) {
          b.lockedOnBy = nb;
          if (b.side !== nb.side) b.lockedOnTurns = 2;
        }
      }
    }
  }
  fighter.b = nb;
  this._refield(fighter);
  const { mon } = nb;
  this._emit('switch', {
    slot: fighter.slot,
    side: fighter.side,
    text: mon.species,
    speciesId: mon.speciesId,
    level: mon.level,
    mon: index - 1,
  });
  this._sendEvent(fighter);
  return nb;
};

// Roar / Whirlwind / Baton Pass (Effects.js).
Battle.prototype.forceSwitch = function forceSwitch(fighter, index, reason, baton) {
  const target = at(fighter.mons, index);
  if (!target || target.hp <= 0) return null;
  const nb = this._switchIn(fighter, index, reason === 'baton_pass' ? baton : null);
  if (reason === 'baton_pass' && fighter.lastB && int(fighter.lastB.substituteHP, 0) > 0) {
    this._emit('sub', { slot: fighter.slot, side: fighter.side, amount: 1 });
  }
  return nb;
};

// Whirlwind / Roar blowing a battler out of a wild fight ends it
// (pokefirered/data/battle_scripts_1.s:3283).
Battle.prototype.blownAway = function blownAway(b) {
  this._concedeRun(b.fighter);
};

// Teleport out of a wild fight.
Battle.prototype.concede = function concede(fighter) {
  this._concedeRun(fighter);
};

Battle.prototype._concedeRun = function _concedeRun(fighter) {
  this._emit('run', { slot: fighter.slot, side: fighter.side, text: fighter.name });
  if (fighter.side === 'a') {
    this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'run');
  } else {
    this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'run');
  }
};

// ------------------------------------------------------------------
// resolution
// ------------------------------------------------------------------

// pokefirered/src/battle_main.c:3623 (engine clear_turn_flags)
Battle.prototype._clearTurnFlags = function _clearTurnFlags(b) {
  delete b.protected;
  delete b.enduring;
  delete b.magicCoat;
  delete b.snatch;
  delete b.helpingHand;
  delete b.flinched;
  delete b.lastPhysDmg;
  delete b.lastPhysBy;
  delete b.lastSpecDmg;
  delete b.lastSpecBy;
  delete b.lightningRodRedirected;
  delete b.movedThisTurn;
  delete b.turnOrder;
  delete b.unableToMove;
  delete b.statLoweredMsg;
  if (int(b.isFirstTurn, 0) > 0) b.isFirstTurn -= 1;
  // A counter of 0 is still "set" in Lua, so this is truthy(), not a > 0 test.
  if (truthy(b.rechargeTurns)) {
    b.rechargeTurns -= 1;
    if (b.rechargeTurns <= 0) {
      delete b.rechargeTurns;
      delete b.mustRecharge;
    }
  }
};

// Order the turn (pokefirered/src/battle_main.c:3532 SetActionsAndBattlersTurnOrder).
Battle.prototype._beginTurn = function _beginTurn() {
  for (const f of this.order) {
    if (f.b) this._clearTurnFlags(f.b);
  }
  this.sides.a.followMe = null;
  this.sides.b.followMe = null;

  const rows = [];
  for (let i = 1; i <= this.order.length; i += 1) {
    const f = this.order[i - 1];
    const { b } = f;
    const { choice } = f;
    if (b && b.mon.hp > 0 && choice && choice.action === 'fight') {
      // A recharge turn chooses no move (pokefirered/src/battle_main.c:3126
      // withholds the menu; :2993 left gChosenMoveByBattler MOVE_NONE): Rage
      // ends, no Focus Punch line, bracket 0 (the cart reads the stale chosen
      // slot, :3490 -- the recharge move or its caller, priority 0 on every
      // cart).
      let row = null;
      if (!truthy(choice.recharge)) row = this._actionMove(b, choice)[0];
      // pokefirered/src/battle_util.c:1223: Rage ends unless Rage is used again
      const num = row ? int(row.num, 0) : 0;
      if (truthy(b.rage) && num !== Move.MOVE.RAGE) delete b.rage;
      rows.push({
        f, b, row, pri: row ? int(row.priority, 0) : 0, order: i,
      });
    } else if (b) {
      // A seat that chose no move (bag, switch, run) has gChosenMoveByBattler
      // MOVE_NONE (battle_main.c:2993), which is not Rage.  The Fury Cutter
      // counter is NOT cleared by choosing something else in Gen 3 (pret has
      // no such check): a miss, the bag, a failed run, a switch or a canceller
      // stop resets it (CancelMultiTurnMoves / ClearFuryCutterDestinyBondGrudge).
      delete b.rage;
    }
  }

  this.randomTurnNumber = null;
  if (rows.length >= 2) {
    let anyClaw = false;
    for (const r of rows) {
      if (truthy(Items.has(r.b, Items.HOLD.QUICK_CLAW))) anyClaw = true;
    }
    if (anyClaw) this.randomTurnNumber = this.roll(0, 0xFFFF);
  }
  for (const r of rows) r.spe = this._speedOf(r.b);
  this._orderRows(rows);

  // Turn-order numbers (Protect / Magic Coat / Snatch "moved last" checks):
  // meta actions first in battler order, then the fighters, then the rest.
  const list = [];
  const seen = new Set();
  for (const f of this.order) {
    const a = f.choice ? f.choice.action : null;
    if (a === 'switch' || a === 'item' || a === 'run') {
      list.push(f);
      seen.add(f);
    }
  }
  for (const r of rows) {
    list.push(r.f);
    seen.add(r.f);
  }
  for (const f of this.order) {
    if (!seen.has(f)) list.push(f);
  }
  for (let i = 1; i <= list.length; i += 1) {
    const f = list[i - 1];
    if (f.b) f.b.turnOrder = i;
  }
  this.turnOrderFighters = list;
  this.fightRows = rows;
  this.turnPriority = new Map();
  for (const r of rows) this.turnPriority.set(r.b, r.pri);

  // pokefirered/src/battle_main.c:3669 CheckFocusPunch_ClearVarsBeforeTurnStarts
  for (const r of rows) {
    if (r.row && int(r.row.effect, -1) === E.FOCUS_PUNCH && !truthy(r.b.lockedNum)
        && Status.normalise(r.b.mon.status) !== 'SLP') {
      this._emit('anim', { slot: r.b.slot, side: r.b.side, text: 'FOCUS_PUNCH_SETUP' });
      this.say(`${this.nameOf(r.b)} is tightening its focus!`);
    }
  }
};

Battle.prototype._resolveTurn = function _resolveTurn() {
  this.phase = 'resolving';
  this.resolveDeadline = (this.resolveTimeout > 0) ? (this.now + this.resolveTimeout) : null;

  this._beginTurn();
  if (this._resolveRuns()) return;
  this._resolveSwitches();
  if (!truthy(this.result)) this._resolveItems();
  if (!truthy(this.result)) this._resolveFights();
  if (!truthy(this.result)) this._endTurn();
  this._faintSweep();
  this._drainExp();
  if (!truthy(this.result)) this._checkOver();

  if (!truthy(this.result) && this._anyMustReplace()) {
    this._openReplace();
    return;
  }
  if (!truthy(this.result)) {
    this.turn += 1;
    this._openTurn();
  }
};

// pokefirered/src/battle_main.c:4229 TryRunFromBattle (wild), a concession
// (1v1 / coop_pvp), or the trainer refusal.
Battle.prototype._resolveRuns = function _resolveRuns() {
  const running = [];
  for (const fighter of this.order) {
    if (fighter.choice && fighter.choice.action === 'run') running.push(fighter);
  }
  if (running.length === 0) return false;

  if (!runEndsBattle(this.mode)) {
    this.say("No! There's no running from a trainer battle!");
    return false;
  }

  if (!isWildMode(this.mode)) {
    const sides = {};
    for (const fighter of running) {
      sides[fighter.side] = true;
      this._emit('run', { slot: fighter.slot, side: fighter.side, text: fighter.name });
    }
    if (sides.a && sides.b) {
      this._finish('draw', null, null, 'run');
    } else if (sides.a) {
      this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'run');
    } else {
      this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'run');
    }
    return true;
  }

  for (const fighter of running) {
    const { b } = fighter;
    if (b && b.mon.hp > 0) {
      fighter.acted = true;
      const he = Items.of(b)[0];
      let escaped = false;
      if (he === Items.HOLD.CAN_ALWAYS_RUN) {
        const lbl = this.itemLabel(b);
        Items.heldEvent(this, b, int(b.mon.heldItem, 0), lbl);
        this.say(`${this.nameOf(b)} fled using its ${lbl}!`);
        escaped = true;
      } else if (b.ability === 'RUN_AWAY') {
        this.emitAbility(b);
        this.say(`${this.nameOf(b)} fled using RUN AWAY!`);
        escaped = true;
      } else {
        const foe = this.foes(b)[0];
        const mySpe = int(b.mon.stats.spe, 0);
        const foeSpe = foe ? int(foe.mon.stats.spe, 0) : 0;
        if (mySpe < foeSpe) {
          const speedVar = (Math.floor(mySpe * 128 / Math.max(1, foeSpe)) + this.fleeAttempts * 30) % 256;
          escaped = speedVar > this.roll(0, 255);
        } else {
          escaped = true;
        }
        this.fleeAttempts += 1;
        if (escaped) this.say('Got away safely!');
      }
      if (escaped) {
        this._emit('run', { slot: fighter.slot, side: fighter.side, text: fighter.name });
        const other = fighter.side === 'a' ? 'b' : 'a';
        this._finish('win', this._sidePlayers(other), this._sidePlayers(fighter.side), 'run');
        return true;
      }
      // pokefirered/src/battle_main.c:4311: a failed escape clears Fury
      // Cutter, Destiny Bond and Grudge like a bag action.
      delete b.furyCutter;
      delete b.destinyBond;
      delete b.grudge;
      this.say("Can't escape!");
    }
  }
  return false;
};

// Pursuit aimed at a seat that is switching out strikes first, doubled
// (engine init.lua D.pursuitRow / switchStep; pret Cmd_pursuitrelated).
Battle.prototype._pursuitBefore = function _pursuitBefore(fighter) {
  const foes = this._foeSeats(fighter);
  for (let i = foes.length; i >= 1; i -= 1) {
    const foe = foes[i - 1];
    const fb = foe.b;
    const { choice } = foe;
    if (fb && fb.mon.hp > 0 && choice && choice.action === 'fight' && !truthy(foe.acted)
        && fighter.b && fighter.b.mon.hp > 0) {
      const row = !truthy(choice.recharge) ? this._actionMove(fb, choice)[0] : null;
      const s = Status.normalise(fb.mon.status);
      if (row && int(row.effect, -1) === E.PURSUIT && choice.target === fighter.slot
          && s !== 'SLP' && s !== 'FRZ' && int(fb.truantCounter, 0) === 0) {
        foe.acted = true;
        this._fightAction(foe, choice, { pursuit: true });
        this._afterAction();
        this._faintSweep();
        this._drainExp();
        if (!truthy(this.result)) this._checkOver();
        if (truthy(this.result)) return;
      }
    }
  }
};

// pokefirered/src/battle_main.c:3532 SetActionsAndBattlersTurnOrder: the
// switch and bag actions go first, TOGETHER, in battler order (a1, b1, a2, ...),
// ahead of every move -- a1's Potion before b1's switch.  Balls are the one
// exception, BattleSim2's policy (sheet doc §6): they wait for the other bag
// actions and are thrown fastest first (`_resolveItems`).
Battle.prototype._resolveSwitches = function _resolveSwitches() {
  for (const fighter of this.order) {
    if (truthy(this.result)) return;
    const { choice } = fighter;
    if (choice && choice.action === 'switch') {
      const mon = at(fighter.mons, choice.slot);
      if (fighter.b && fighter.b.mon.hp > 0) this._pursuitBefore(fighter);
      if (truthy(this.result)) return;
      if (mon && mon.hp > 0 && (fighter.b == null || fighter.b.mon.hp > 0)) {
        fighter.acted = true;
        const nb = this._switchIn(fighter, choice.slot);
        this.switchInEffects(nb, { spikes: true });
        this._faintSweep();
        this._drainExp();
        if (!truthy(this.result)) this._checkOver();
      }
    } else if (choice && choice.action === 'item') {
      const effect = Items.bagEffect(choice.item);
      if (!(effect && truthy(effect.ball))) this._useItem(fighter);
    }
  }
};

// The balls, after every other bag action, fastest thrower first.
Battle.prototype._resolveItems = function _resolveItems() {
  const balls = [];
  for (let i = 1; i <= this.order.length; i += 1) {
    const fighter = this.order[i - 1];
    const { choice } = fighter;
    if (choice && choice.action === 'item') {
      const effect = Items.bagEffect(choice.item);
      if (effect && truthy(effect.ball)) {
        balls.push({
          f: fighter, pri: 0, spe: fighter.b ? this._speedOf(fighter.b) : 0, order: i,
        });
      }
    }
  }
  this._orderRows(balls);
  for (const r of balls) {
    if (truthy(this.result)) return;
    this._useItem(r.f);
  }
};

const SHAKE_TEXT = {
  0: 'Oh, no! The POKeMON broke free!',
  1: 'Aww! It appeared to be caught!',
  2: 'Aargh! Almost had it!',
  3: 'Shoot! It was so close, too!',
};

Battle.prototype._caughtSheet = function _caughtSheet(b, ball) {
  const { mon } = b;
  const moves = [];
  for (let i = 1; i <= mon.moves.length; i += 1) moves.push(copyMove(mon.moves[i - 1]));
  // `{ mon.types[1], mon.types[2] }` in the Lua: a nil second type leaves a
  // one-element list, not a trailing null.
  const types = [mon.types[0]];
  if (mon.types[1] != null) types.push(mon.types[1]);
  const sheet = {
    generation: 3,
    species: mon.species,
    speciesId: mon.speciesId,
    speciesNum: mon.speciesNum,
    level: mon.level,
    hp: mon.hp,
    maxHp: mon.maxHp,
    status: mon.status,
    stats: {
      atk: mon.stats.atk,
      def: mon.stats.def,
      spe: mon.stats.spe,
      spa: mon.stats.spa,
      spd: mon.stats.spd,
    },
    types,
    ability: mon.ability,
    heldItem: mon.heldItem,
    holdEffect: mon.holdEffect,
    holdEffectParam: mon.holdParam,
    gender: mon.gender,
    friendship: mon.friendship,
    nature: mon.nature,
    catchRate: mon.catchRate,
    ivs: mon.ivs,
    evs: mon.evs,
    personality: mon.personality,
    otId: mon.otId,
    moves,
    ball,
  };
  // A nil field in the Lua table is an absent key; keep the sheet the same shape.
  for (const k of Object.keys(sheet)) {
    if (sheet[k] == null) delete sheet[k];
  }
  return sheet;
};

Battle.prototype._useItem = function _useItem(fighter) {
  const { choice } = fighter;
  if (!(choice && choice.action === 'item')) return;
  fighter.acted = true;
  // pokefirered/src/battle_main.c:4155 HandleAction_UseItem:
  // ClearFuryCutterDestinyBondGrudge on the seat's battler.
  if (fighter.b) {
    delete fighter.b.furyCutter;
    delete fighter.b.destinyBond;
    delete fighter.b.grudge;
  }
  const { item } = choice;
  const effect = Items.bagEffect(item);
  this._emit('item', { slot: fighter.slot, side: fighter.side, text: String(item) });
  const label = fighter.bagNames[item];
  this.say(`${fighter.name} used ${truthy(label) ? label : 'an item'}!`);
  if (!(effect && truthy(effect.noConsume))) this._spendBag(fighter, item);

  if (!effect) {
    this.say('But it failed!');
    return;
  }

  if (truthy(effect.ball)) {
    const foe = isWildMode(this.mode) ? this._firstLivingFoe(fighter) : null;
    const target = foe ? foe.b : null;
    if (!target) {
      this.say('But it failed!');
      return;
    }
    const [caught, shakes] = Catch.attempt(item, target, this.rng, {
      types: target.mon.types,
      level: target.mon.level,
      turn: this.turn - 1,
      underwater: this.underwater,
      dexCaught: choice.dexCaught,
    });
    this._emit('ball', {
      slot: fighter.slot,
      side: fighter.side,
      target: foe.slot,
      amount: caught ? 4 : shakes,
      text: String(item),
    });
    if (caught) {
      this.say(`Gotcha! ${this.nameOf(target)} was caught!`);
      const finish = this._finish('win', this._sidePlayers(fighter.side),
        this._sidePlayers(fighter.side === 'a' ? 'b' : 'a'), 'catch');
      if (finish) {
        finish.caught = this._caughtSheet(target, item);
        finish.catcher = fighter.owner;
      }
    } else {
      this.say(SHAKE_TEXT[shakes] != null ? SHAKE_TEXT[shakes] : SHAKE_TEXT[0]);
    }
    return;
  }

  if (truthy(effect.escape)) {
    if (isWildMode(this.mode)) {
      this.say('Got away safely!');
      this._finish('win', this._sidePlayers(fighter.side),
        this._sidePlayers(fighter.side === 'a' ? 'b' : 'a'), 'run');
    } else {
      this.say('But it failed!');
    }
    return;
  }

  if (truthy(effect.flute)) {
    let woke = false;
    for (const seat of this.order) {
      // Each party once, from its first seat: a shared team's partner wakes
      // on its own battler.
      if (seat.seats[0] === seat) {
        for (let i = 1; i <= seat.mons.length; i += 1) {
          const mon = seat.mons[i - 1];
          if (Status.normalise(mon.status) === 'SLP' && mon.hp > 0) {
            woke = true;
            const b = this._partyBattler(seat, i);
            if (b) {
              this.cure(b, null);
            } else {
              mon.status = null;
              mon.sleepTurns = null;
            }
          }
        }
      }
    }
    this.say(woke ? 'All sleeping POKeMON woke up!' : 'Nothing happened.');
    this._syncTeams();
    return;
  }

  const index = orv(choice.slot, fighter.active);
  const mon = at(fighter.mons, index);
  const b = this._partyBattler(fighter, index);
  if (!mon || !this._itemHasEffect(fighter, effect, index, choice.move)) {
    this.say('But it had no effect!');
    return;
  }

  if (truthy(effect.stage) && b) {
    Effects.changeStat(this, b, effect.stage, 1, { user: true });
    return;
  }
  if (truthy(effect.focusEnergy) && b) {
    b.focusEnergy = true;
    this.say(`${this.nameOf(b)} is getting pumped!`);
    return;
  }
  if (truthy(effect.mist) && b) {
    this.sides[b.side].mistTurns = Field.MIST_TURNS;
    this.say(`${this.nameOf(b)}'s party became shrouded in MIST!`);
    return;
  }

  if (truthy(effect.revive)) {
    const hp = (effect.revive === 'full') ? mon.maxHp : Math.max(1, Math.floor(mon.maxHp / 2));
    mon.hp = hp;
    mon.status = null;
    mon.sleepTurns = null;
    this.say(`${mon.species} was revived!`);
    this._syncTeams();
    return;
  }

  if (truthy(effect.pp) || truthy(effect.ppFull) || truthy(effect.ppAll) || truthy(effect.ppAllFull)) {
    const moves = (b && truthy(b.moves)) ? b.moves : mon.moves;
    const restore = (mv, amount) => {
      if (amount === true) mv.pp = mv.maxPp; else mv.pp = Math.min(mv.maxPp, mv.pp + amount);
    };
    if (truthy(effect.pp) || truthy(effect.ppFull)) {
      restore(at(moves, choice.move), truthy(effect.ppFull) ? true : effect.pp);
    } else {
      for (let i = 1; i <= moves.length; i += 1) {
        restore(moves[i - 1], truthy(effect.ppAllFull) ? true : effect.ppAll);
      }
    }
    this.say(`${mon.species}'s PP was restored.`);
    if (b) this.emitMovesOf(b);
    return;
  }

  if (truthy(effect.healFull) || truthy(effect.heal)) {
    const amount = truthy(effect.healFull) ? mon.maxHp : effect.heal;
    if (b) {
      const gained = this.heal(b, amount);
      this.say(`${mon.species}'s HP was restored by ${gained} point(s).`);
    } else {
      const before = mon.hp;
      mon.hp = Math.min(mon.maxHp, mon.hp + amount);
      this.say(`${mon.species}'s HP was restored by ${mon.hp - before} point(s).`);
    }
  }
  const s = Status.normalise(mon.status);
  if (truthy(effect.cure) && s && truthy(effect.cure[s])) {
    const word = Status.WORD[s] != null ? Status.WORD[s] : 'status';
    const text = `${mon.species} was cured of its ${word} problem.`;
    if (b) {
      delete b.nightmare;
      this.cure(b, text);
    } else {
      mon.status = null;
      mon.sleepTurns = null;
      this.say(text);
    }
  }
  if (truthy(effect.confusion) && b && int(b.confusion, 0) > 0) {
    delete b.confusion;
    const text = `${mon.species} snapped out of confusion!`;
    this._emit('status', {
      slot: b.slot, side: b.side, confused: 0, text,
    });
    this.say(text);
  }
  if (truthy(effect.attract) && b && truthy(b.infatuatedWith)) {
    delete b.infatuatedWith;
    this.say(`${mon.species} got over its infatuation.`);
  }
  this._syncTeams();
};

Battle.prototype._resolveFights = function _resolveFights() {
  for (const r of (this.fightRows || [])) {
    if (truthy(this.result)) break;
    const { f } = r;
    // The battler that chose is the only one that acts: a replacement does not
    // inherit the turn, and a Pursuit already spent it.
    if (!truthy(f.acted) && f.b === r.b && r.b.mon.hp > 0) {
      f.acted = true;
      this._fightAction(f, f.choice);
      this._afterAction();
    }
    this._faintSweep();
    this._drainExp();
    if (!truthy(this.result)) this._checkOver();
  }
};

// ------------------------------------------------------------------
// faints
// ------------------------------------------------------------------

Battle.prototype._faintSweep = function _faintSweep() {
  for (const f of this.order) {
    const { b } = f;
    if (b && b.mon.hp <= 0 && !truthy(b.faintAnnounced)) this._faintBattler(b);
  }
};

// ------------------------------------------------------------------
// participation (BattleSim2's, verbatim in behaviour)
// ------------------------------------------------------------------

// Participation is keyed by PARTY member, not by seat: pret's sentIn bits
// (gSentPokesToOpponent) are party indices, so a shared team's mon that
// fought from both seats is one participant. The key names the party by its
// first seat's slot -- a one-seat fighter's own.
function foughtKey(fighter, index) {
  return `${fighter.seats[0].slot}:${index}`;
}

Battle.prototype._refield = function _refield(fighter) {
  fighter.fought = {};
  fighter.foughtSeats = null;
  const mine = activeMon(fighter) ? fighter.active : null;
  const foes = this.bySide[fighter.side === 'a' ? 'b' : 'a'];
  for (const foe of foes) {
    if (activeMon(foe)) {
      fighter.fought[foughtKey(foe, foe.active)] = true;
      if (mine != null) {
        foe.fought = foe.fought || {};
        foe.fought[foughtKey(fighter, mine)] = true;
      }
    }
  }
  const pending = fighter.pendingFought;
  fighter.pendingFought = null;
  if (pending) {
    for (let i = 1; i <= pending.length; i += 1) fighter.fought[pending[i - 1]] = true;
  }
};

Battle.prototype._standingOpposition = function _standingOpposition(fighter) {
  const keys = [];
  const foes = this.bySide[fighter.side === 'a' ? 'b' : 'a'];
  for (const foe of foes) {
    if (activeMon(foe)) keys.push(foughtKey(foe, foe.active));
  }
  return keys;
};

// A participant that faints stops being one (it earns nothing), but its SEAT
// is remembered as having fought (`foughtSeats`): pret's sentIn bits outlive a
// faint, and a seat whose participants all fell still pays its Exp. Share
// holders (`_awardExp`). A shared team is remembered as one seat, its first.
Battle.prototype._unfield = function _unfield(fighter, index) {
  const key = foughtKey(fighter, index);
  for (const other of this.fighters) {
    if (other.fought && truthy(other.fought[key])) {
      other.foughtSeats = other.foughtSeats || {};
      other.foughtSeats[fighter.seats[0].slot] = true;
    }
    if (other.fought) delete other.fought[key];
    const pending = other.pendingFought;
    if (pending) {
      for (let i = pending.length; i >= 1; i -= 1) {
        if (pending[i - 1] === key) pending.splice(i - 1, 1);
      }
    }
  }
};

const EXP_MODES = { wild: true, coop_wild: true, coop_npc: true };
const EXP_OWNER_SIDE = 'a';

// The field slot an `exp` fact names for party member `index`: the seat it is
// out on, else (benched) its party's first seat.
Battle.prototype._expSlot = function _expSlot(fighter, index) {
  const seat = this.fieldedSeat(fighter, index) || fighter.seats[0];
  return seat.slot;
};

// One pass per PARTY (its first seat): a shared team's mon is one participant
// however many seats it fought from, and gets one `exp` fact.
Battle.prototype._awardExp = function _awardExp(fallen, mon) {
  if (!own(EXP_MODES, this.mode)) return;
  if (fallen.side === EXP_OWNER_SIDE) return;
  const fought = fallen.fought || {};
  let participants = 0;
  const alive = [];
  const seatFought = new Set();
  const seatPaid = new Set();
  for (const fighter of this.bySide[EXP_OWNER_SIDE]) {
    if (fighter.seats[0] === fighter) {
      if (fallen.foughtSeats && truthy(fallen.foughtSeats[fighter.slot])) seatFought.add(fighter);
      for (let index = 1; index <= fighter.mons.length; index += 1) {
        if (truthy(fought[foughtKey(fighter, index)])) {
          participants += 1;
          seatFought.add(fighter);
          if (fighter.mons[index - 1].hp > 0) {
            alive.push({ fighter, index });
            seatPaid.add(fighter);
          }
        }
      }
    }
  }
  if (participants === 0) {
    for (const fighter of this.bySide[EXP_OWNER_SIDE]) {
      if (activeMon(fighter)) {
        participants += 1;
        alive.push({ fighter, index: fighter.active });
        seatFought.add(fighter.seats[0]);
        seatPaid.add(fighter.seats[0]);
      }
    }
  }
  for (const winner of alive) {
    this._emit('exp', {
      slot: this._expSlot(winner.fighter, winner.index),
      species: mon.species,
      speciesId: mon.speciesId,
      level: mon.level,
      participants,
      mon: winner.index - 1,
    });
  }
  // pokefirered/src/battle_script_commands.c:3113 Cmd_getexp pays the living
  // Exp. Share holders whether or not any participant still stands (viaSentIn
  // 0 is a SAFE_DIV, :3170).  A seat that fought this foe but has nobody
  // standing who did gets the holders-only fact: `participants` 0 and no
  // `mon`.  Its client prices it as a knockout with an empty sentIn set, so
  // only the holders' half is paid (sheet doc §7).
  for (const fighter of this.bySide[EXP_OWNER_SIDE]) {
    if (seatFought.has(fighter) && !seatPaid.has(fighter) && firstLiving(fighter.mons) != null) {
      this._emit('exp', {
        slot: fighter.slot,
        species: mon.species,
        speciesId: mon.speciesId,
        level: mon.level,
        participants: 0,
      });
    }
  }
};

Battle.prototype._drainExp = function _drainExp() {
  const queue = this.pendingExp;
  if (queue.length === 0) return;
  this.pendingExp = [];
  for (let i = 1; i <= queue.length; i += 1) this._awardExp(queue[i - 1].fallen, queue[i - 1].mon);
};

// A battler is down: the `faint` event, the participation bookkeeping, and the
// seat's next step (BattleSim2 `_faint`). Called at the engine's announcement
// points (Move.js tryFaint*, the residual steps, the action sweep).
Battle.prototype._faintBattler = function _faintBattler(b) {
  if (truthy(b.faintAnnounced)) return;
  b.faintAnnounced = true;
  const { fighter } = b;
  if (fighter.b !== b) return;
  const { mon } = b;
  mon.hp = 0;
  mon.status = null;
  mon.sleepTurns = null;
  this._unfield(fighter, b.partyIndex);
  this._unlink(b);
  // A shared team's bench leaves out the partner's active mon (`benchOf`).
  const next = this.benchOf(fighter)[0];
  this._emit('faint', {
    slot: fighter.slot, side: fighter.side, text: mon.species, amount: next != null ? 1 : null,
  });
  this._syncTeams();
  this.pendingExp.push({ fallen: fighter, mon });
  fighter.lastB = b;
  fighter.b = null;
  fighter.active = null;
  if (next != null) {
    fighter.mustReplace = true;
    fighter.pendingFought = this._standingOpposition(fighter);
  } else {
    fighter.mustReplace = null;
    fighter.pendingFought = null;
  }
  if (this.phase !== 'resolving') {
    this._drainExp();
    this._checkOver();
  }
};

// ------------------------------------------------------------------
// endings
// ------------------------------------------------------------------

Battle.prototype._checkOver = function _checkOver() {
  if (truthy(this.result)) return true;
  const aliveA = this._sideAlive('a');
  const aliveB = this._sideAlive('b');
  if (aliveA && aliveB) return false;
  if (!aliveA && !aliveB) {
    this._finish('draw', null, null, 'ko');
  } else if (aliveA) {
    const result = this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'ko');
    // pokefirered/src/battle_main.c:3764: only a WON battle runs
    // BattleScript_PayDayMoneyAndPickUpItems (Cmd_givepaydaymoney), and the
    // coins are the player side's.  Link rules pay nothing (1v1 / coop_pvp); in
    // the other modes side a is the player side.  The Amulet Coin doubling
    // (gBattleStruct->moneyMultiplier) and the wallet are the client's.
    const coins = int(this.payDay ? this.payDay.a : this.payDay, 0);
    if (result && own(EXP_MODES, this.mode) && coins > 0) result.payDay = coins;
  } else {
    this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'ko');
  }
  return true;
};

Battle.prototype._finish = function _finish(outcome, winners, losers, reason) {
  if (truthy(this.result)) return this.result;
  // nil winners / losers in the Lua are absent keys, not null ones.
  const result = { battle: this.id, outcome, reason };
  if (winners != null) result.winners = winners;
  if (losers != null) result.losers = losers;
  this.result = result;
  this.phase = 'over';
  this.deadline = null;
  this.resolveDeadline = null;
  this._emit('over', { text: reason });
  return this.result;
};

Battle.prototype.outcome = function outcome() {
  return this.result;
};

// ------------------------------------------------------------------
// the clock (BattleSim2's)
// ------------------------------------------------------------------

Battle.prototype.disconnect = function disconnect(playerId) {
  const fighter = this.byId.get(str(playerId) || '');
  if (!fighter || !truthy(fighter.connected)) return false;
  if (truthy(this.result)) return false;
  fighter.connected = false;
  fighter.graceEndsAt = this.now + this.reconnectGrace;
  this._emit('wait', { side: fighter.side, text: fighter.name });
  return true;
};

Battle.prototype.reconnect = function reconnect(playerId) {
  const fighter = this.byId.get(str(playerId) || '');
  if (!fighter || truthy(fighter.connected)) return false;
  if (truthy(this.result)) return false;
  if (fighter.graceEndsAt != null && this.now >= fighter.graceEndsAt) return false;
  fighter.connected = true;
  fighter.graceEndsAt = null;
  this._emit('reconnect', { side: fighter.side, text: fighter.name });
  if ((this.phase === 'choice' || this.phase === 'replace')
     && !this._anyDisconnected() && this.choiceTimeout > 0) {
    this.deadline = this.now + this.choiceTimeout;
  }
  this._maybeResolve();
  return true;
};

Battle.prototype.tick = function tick(nowSeconds) {
  const now = int(nowSeconds, this.now);
  if (now > this.now) this.now = now;
  if (truthy(this.result)) return false;

  if ((this.phase === 'choice' || this.phase === 'replace') && this._checkOver()) {
    return true;
  }

  if (truthy(this.forcedPending) && this.phase === 'choice' && !this._anyDisconnected()) {
    this.forcedPending = false;
    if (!this._anyoneOwes()) {
      this._maybeResolve();
      return true;
    }
  }

  let expiredA = false;
  let expiredB = false;
  for (const fighter of this.fighters) {
    if (!truthy(fighter.connected) && fighter.graceEndsAt != null && this.now >= fighter.graceEndsAt) {
      if (fighter.side === 'a') expiredA = true; else expiredB = true;
    }
  }
  if (expiredA || expiredB) {
    if (expiredA && expiredB) {
      this._finish('draw', null, null, 'disconnect');
    } else if (expiredA) {
      this._finish('forfeit', this._sidePlayers('b'), this._sidePlayers('a'), 'disconnect');
    } else {
      this._finish('forfeit', this._sidePlayers('a'), this._sidePlayers('b'), 'disconnect');
    }
    return true;
  }

  if (this.phase === 'resolving' && this.resolveDeadline != null && this.now >= this.resolveDeadline) {
    this._finish('draw', null, null, 'timeout');
    return true;
  }

  if ((this.phase === 'choice' || this.phase === 'replace')
     && this.deadline != null && this.now >= this.deadline && !this._anyDisconnected()) {
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) {
        const auto = this._autoChoiceOrSkip(fighter);
        if (auto) {
          fighter.choice = auto;
          this._emit('chose', { slot: fighter.slot, side: fighter.side, text: fighter.name });
          this.say(`${fighter.name} ran out of time`);
        }
      }
    }
    this._maybeResolve();
    if ((this.phase === 'choice' || this.phase === 'replace')
       && this.deadline != null && this.now >= this.deadline) {
      this.deadline = this.now + this.choiceTimeout;
    }
    return true;
  }

  return false;
};

// ------------------------------------------------------------------
// snapshot (tests and logs)
// ------------------------------------------------------------------

Battle.prototype.snapshot = function snapshot() {
  const field = [];
  const waiting = [];
  const owing = new Set();
  for (const fighter of this.fighters) {
    const { b } = fighter;
    const mon = b ? b.mon : null;
    const party = [];
    for (let i = 1; i <= fighter.mons.length; i += 1) party.push(fighter.mons[i - 1].hp);
    field.push({
      slot: fighter.slot,
      side: fighter.side,
      playerId: fighter.playerId,
      name: fighter.name,
      connected: fighter.connected,
      graceEndsAt: fighter.graceEndsAt,
      chose: fighter.choice != null ? fighter.choice.action : null,
      mustReplace: fighter.mustReplace === true,
      species: mon ? mon.species : null,
      hp: mon ? mon.hp : 0,
      maxHp: mon ? mon.maxHp : 0,
      status: mon ? mon.status : null,
      party,
    });
    // `waiting` names owners, each once: a shared team is one player.
    if (this._owes(fighter) && !owing.has(fighter.owner)) {
      owing.add(fighter.owner);
      waiting.push(fighter.owner);
    }
  }
  return {
    battle: this.id,
    mode: this.mode,
    phase: this.phase,
    turn: this.turn,
    seq: this.seq,
    now: this.now,
    deadline: this.deadline,
    resolveDeadline: this.resolveDeadline,
    over: truthy(this.result),
    reason: truthy(this.result) ? this.result.reason : null,
    rngState: this.rng.state(),
    weather: this.field.weather,
    field,
    waiting,
    payDay: { a: this.payDay.a, b: this.payDay.b },
  };
};

module.exports = M;
