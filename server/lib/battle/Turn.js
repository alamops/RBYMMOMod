'use strict';

/*
 * The turn machine: choices in, events out, and one party deciding.
 *
 * Node twin of src/BattleSim/Turn.lua, and the only file under lib/battle/ with
 * state. The formula modules beside it each answer a single question with no
 * memory; this owns the field, the clock, the RNG stream and the order the
 * questions get asked in. A battle brokered here is resolved by *one* process
 * -- this hub, or a LAN host running the Lua half -- and the clients receive an
 * ordered stream of events they draw. They are never asked what happened.
 *
 * **The RNG order is the contract.** The Lua twin has to consume draws at
 * exactly the same points or the same seed produces a different fight, so every
 * draw site is spelled out here and every one of them is conditional in a way
 * both runtimes can reproduce:
 *
 *   1. a speed tie-break byte, one per group of equally fast actors;
 *   2. one gate byte per actor whose monster has a gating status;
 *   3. one gate byte per actor whose monster is confused;
 *   4. per move that is actually used: accuracy byte, multihit-count byte
 *      (TWO_TO_FIVE only), crit byte, damage roll, side-chance byte
 *      (damaging hits only), in that order, and none of them drawn when an
 *      earlier step ended the move (a missed move draws no crit byte).
 *
 * The damage roll is drawn even when the hit turns out to be an immunity,
 * because in the Lua the roll is an argument to `Damage.compute` and arguments
 * are evaluated before the call finds out. That is a draw the port cannot
 * optimise away without desyncing the two runtimes on the next attack.
 *
 * Nothing else rolls. Residuals, switches, items and the clock are all
 * deterministic, so a battle replays from its seed plus the choice log.
 *
 * **Policies chosen where Gen 1 had no answer** -- the whole list, and the
 * reasoning behind each, lives in the Lua header rather than being restated
 * here; what follows is only what the port has to keep true:
 *
 *   * *Speed ties* break on a single byte per tied group, below 128 leaving the
 *     side-a member first and otherwise reversing the group.
 *   * *Running* is a concession: one side loses with reason `run`, both is a
 *     draw.
 *   * *Items* apply a hand-authored Gen1 heal/status table (not engine
 *     ItemEffects); unknown ids say "But it failed" and still spend the turn.
 *     Bags are client claims (sheet trust locked). Forced lock-in injects on
 *     openTurn (trapper continue anim + residual; no menu); forced-only turns
 *     defer to the next tick.
 *   * *Metronome* picks from host-uploaded metronomePool on the ruleset.
 *   * *Physical / Special* via host-uploaded specialTypes (Gen1 type categories).
 *   * A *faint with a living bench opens the `replace` phase*, between the turn
 *     it happened on and the next one: the turn number does not move, no other
 *     seat is asked, and nothing resolves until every owed send-out is in --
 *     then `_resolveSwitches` fields them (`switch` + `send`) and the next turn
 *     opens. It runs on the same clock as a choice window, so an unanswered
 *     replacement is auto-picked exactly like an unanswered move.
 *   * Solicitation for that phase is a `turn` event carrying the owing seat's
 *     field `slot`, one per seat. A `turn` with `slot` asks that seat for a
 *     replacement; a `turn` without one opens the ordinary choice window.
 *   * *Residuals* run in field order (side a, then side b), not speed order.
 *   * A *timeout* / NPC auto-picks with bag cures & heals (≤50% HP), X-items,
 *     SE damage, status / setup reading, and SE bench switches (deterministic
 *     heuristics — not a full TrainerAI port) -- and the fight goes on.
 *   * The choice clock is *suspended while anybody is disconnected*.
 *
 * Two shape differences from the Lua, both forced by the language:
 *
 *   * `Damage.compute` takes one flat object here and four positional tables
 *     there. Same arithmetic, same field names, different call.
 *   * `create` cannot return a value *and* a reason, so it returns the battle
 *     or null, and `attempt` returns { battle, reason } for the caller that has
 *     a client waiting to be told why.
 *
 * Nothing here throws. Bad input is refused with a reason from `attempt` or a
 * plain `false` from `submitChoice`: a fight that stops mid-turn is worse than
 * one that declines a malformed choice.
 */

const Damage = require('./Damage.js');
const Accuracy = require('./Accuracy.js');
const Crit = require('./Crit.js');
const Status = require('./Status.js');
const Effects = require('./Effects.js');
const Rng = require('./Rng.js');
const Events = require('./events.js');

const VERSION = 1;

// Mirrored from Config rather than required, for the reason in events.js: this
// directory runs where Config does not.
const MONS_PER_PARTY = 6; // Config.BATTLE_MON_MAX
const FIGHTERS_PER_SIDE = 2; // Config.COOP_SIDE
const CHOICE_TIMEOUT = 60; // Config.BATTLE_CHOICE_TIMEOUT
const RECONNECT_GRACE = 60; // Config.BATTLE_RECONNECT_GRACE
const RESOLVE_TIMEOUT = 30; // Config.BATTLE_RESOLVE_TIMEOUT

// Below this the side-a member of a tied group moves first.
const TIE_BREAK_ROLL = 128;

const MODES = {
  '1v1': true, coop_npc: true, coop_pvp: true, wild: true, coop_wild: true,
};
const SIDES = ['a', 'b'];

// The modes a faint pays experience in -- the ones vanilla awards it in. 1v1
// and coop_pvp never do; see `_awardExp` for why the gate is the mode rather
// than an owner flag. Side a is where the owners sit in all three; side b is
// the synthetic wild / trainer seat.
const EXP_MODES = { wild: true, coop_wild: true, coop_npc: true };
const EXP_OWNER_SIDE = 'a';

// Participation: who fought the monster that fell.
//
// Vanilla does not pay whoever happened to be standing when the foe dropped --
// it pays every monster of yours that was ever in against *that* foe and is
// still alive, benched included. The engine keeps it as one bitfield per party
// (`wPartyGainExpFlags`), and gen1recomp's port of it is the reference the
// twins mirror line for line:
//
//   * set on send-out. `BattleState:markParticipant`
//     (src/battle/BattleState.lua:2332-2337) flags the player mon that is out;
//     called at battle start (:1681), on a voluntary switch (:2424), on a
//     post-faint replacement (:4214) and again when the enemy sends its next
//     one out (:3980) -- the standing mon re-joins the new foe's set.
//   * cleared when the foe changes. `awardExp` ends with
//     `self.participants = {}` (:3899), so the set is per enemy MONSTER, not
//     per battle; the SHIFT arm zeroes it explicitly at the moment the enemy is
//     replaced (:4020, quoting core.asm:1436-1443). Gen 1 has no voluntary
//     enemy switch to cite, and the shift arm is the one place the cart states
//     what a foe swap does to the flags -- so a foe seat changing its monster
//     resets that seat's set here and re-marks the standing opposition,
//     exactly as :4020-4021 does.
//   * dropped on its own faint. `onFaint` does
//     `self.participants[battler.mon] = nil` (:3721-3723,
//     RemoveFaintedPlayerMon), so a participant that died before the KO is
//     neither paid NOR counted in the divisor.
//   * ...and the send-out's own mark (:3980) lands a turn late here, because a
//     seat is *asked* for its replacement rather than just sending one. It is
//     taken at the faint, against the field the faint happened on, and held in
//     `fighter.pendingFought` until `_refield` fields the successor. See
//     `_faint`; `_unfield` reaches the held copy too.
//
// The set lives per seat because a mediated fight has up to two foe seats, each
// with its own current monster; `fighter.fought` holds the opposing
// (field slot, party index) pairs that have been in against *this* seat's
// current one. Keys are strings so the two runtimes agree on membership without
// agreeing on iteration order -- nothing walks this table, it is only asked.
function foughtKey(slot, index) {
  return `${slot}:${index}`;
}

// Roster cap per side. coop_wild is 2v1 (humans on a, wild on b); other modes
// keep a single per-side ceiling (1 for 1v1/wild, FIGHTERS_PER_SIDE otherwise).
function maxFighters(mode, side) {
  if (mode === 'coop_wild') {
    return side === 'a' ? FIGHTERS_PER_SIDE : 1;
  }
  if (mode === '1v1' || mode === 'wild') return 1;
  return FIGHTERS_PER_SIDE;
}

// The wild monster's seat. Wildlife is always the synthetic side-b seat of a
// mode whose name says "wild" (the seat `maxFighters` caps at one above and
// `_awardExp` pays the other side for), and wildlife carries no bag: a wild
// monster never uses an item, no matter who asks on its behalf. Both askers are
// gated -- `_normaliseChoice` refuses a submitted one, `_autoItemChoice` never
// picks one -- because the seat can be driven from either end.
const WILD_SIDE = 'b';

function isWildSeat(mode, fighter) {
  return !!fighter && fighter.side === WILD_SIDE && Effects.isWildMode(mode);
}

// Auto-pick priorities (twin of Turn.lua AUTO_* tables).
const AUTO_STATUS_PRI = {
  32: 4, // SLEEP_EFFECT
  67: 3, // PARALYZE_EFFECT
  66: 2, // POISON_EFFECT
  49: 1, // CONFUSION_EFFECT
  84: 1, // LEECH_SEED_EFFECT
};
const AUTO_SETUP = {
  10: 'atk', 11: 'def', 12: 'spd', 13: 'spc',
  50: 'atk', 51: 'def', 52: 'spd', 53: 'spc',
  47: true, // FOCUS_ENERGY
  64: true, // LIGHT_SCREEN
  65: true, // REFLECT
  79: true, // SUBSTITUTE
};
const AUTO_HEAL_PREF = [
  'FULL_RESTORE', 'MAX_POTION', 'HYPER_POTION', 'SUPER_POTION',
  'LEMONADE', 'SODA_POP', 'FRESH_WATER', 'POTION',
];
const AUTO_STATUS_CURE = {
  poison: ['FULL_RESTORE', 'FULL_HEAL', 'ANTIDOTE'],
  toxic: ['FULL_RESTORE', 'FULL_HEAL', 'ANTIDOTE'],
  burn: ['FULL_RESTORE', 'FULL_HEAL', 'BURN_HEAL'],
  freeze: ['FULL_RESTORE', 'FULL_HEAL', 'ICE_HEAL'],
  sleep: ['FULL_RESTORE', 'FULL_HEAL', 'AWAKENING'],
  paralysis: ['FULL_RESTORE', 'FULL_HEAL', 'PARLYZ_HEAL'],
};
const AUTO_X_ITEM = [
  { id: 'X_ATTACK', stat: 'atk' },
  { id: 'X_DEFEND', stat: 'def' },
  { id: 'X_SPEED', stat: 'spd' },
  { id: 'X_SPECIAL', stat: 'spc' },
  { id: 'DIRE_HIT', flag: 'focusEnergy' },
  { id: 'GUARD_SPEC', flag: 'mist' },
];

// Default kit for coop_npc trainer seats with no uploaded bag (Gen1 gym-style).
const DEFAULT_NPC_BAG = {
  POTION: 2, SUPER_POTION: 1, FULL_HEAL: 1, X_ATTACK: 1,
};

// Wire spells a condition as a three-letter token and Status.js spells it as a
// word. Both are accepted on the way in and the token is what goes back out on
// an event, so neither vocabulary leaks into the other's file.
const STATUS_FROM_WIRE = {
  SLP: 'sleep', PSN: 'poison', BRN: 'burn',
  FRZ: 'freeze', PAR: 'paralysis', TOX: 'toxic',
};
const STATUS_TO_WIRE = {
  sleep: 'SLP', poison: 'PSN', burn: 'BRN',
  freeze: 'FRZ', paralysis: 'PAR', toxic: 'TOX',
};

// The conditions that can stop a move before it happens. Confusion is not here
// because in Gen 1 it is a volatile, not a status -- it rides on its own
// counter and is gated separately, after this one.
const GATING = { sleep: true, freeze: true, paralysis: true };

const ACTIONS = {
  fight: true, item: true, switch: true, run: true, cancel: true,
};

// Synthetic move used when every slot is out of PP. Not in any move table.
const STRUGGLE = {
  id: 'STRUGGLE', power: 50, accuracy: 255,
  type: 0, effect: 0, chance: 0,
};

const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

const has = (table, key) => typeof key === 'string' && own(table, key);

// ------------------------------------------------------------------
// coercion
// ------------------------------------------------------------------

const toNumber = Events.toNumber;

// Lua's `int(value, fallback)`. `fallback` is returned for anything tonumber()
// would refuse, which includes booleans -- Number(true) is 1 and would quietly
// invent a move index out of a flag.
function int(value, fallback) {
  const n = toNumber(value);
  if (n === null) return fallback;
  return Math.floor(n);
}

function str(value) {
  if (typeof value === 'string' && value !== '') return value;
  return null;
}

// Lua's `type(x) == "table"`: arrays included, null excluded.
const isTable = (value) => typeof value === 'object' && value !== null;

function copyMove(raw) {
  if (!isTable(raw)) return null;
  const pp = Math.max(0, int(raw.pp, 0));
  const maxPp = Math.max(pp, int(raw.maxPp, pp));
  return {
    id: str(raw.id) || 'move',
    pp,
    maxPp,
    power: Math.max(0, int(raw.power, 0)),
    accuracy: Math.max(0, int(raw.accuracy, 255)),
    type: Math.max(0, int(raw.type, 0)),
    effect: Math.max(0, int(raw.effect, 0)),
    chance: Math.max(0, int(raw.chance, 0)),
  };
}

// A defender with no stated types is type 0, which the chart lookup reads as
// "whatever the first row says" and, absent a chart, as neutral. That is the
// right default for a sim that must never refuse a party over a missing
// optional.
function copyTypes(raw) {
  if (!Array.isArray(raw)) return [0];
  const out = raw.map((value) => Math.max(0, int(value, 0)));
  if (out.length === 0) return [0];
  return out;
}

// Every monster is deep-copied on the way in, and that is load-bearing rather
// than tidy: the caller's object is usually a party the client still owns and
// redraws, and a sim that damaged it in place would make "run the same fixture
// twice" produce two different fights -- which is exactly the property the
// determinism suite is built to catch.
//
// `slot` is the *sender's* party position for this monster, zero-based, the way
// cleanBattleMon carries it -- and it is kept rather than dropped because a
// switch names it. The two numbers are the same only while every monster the
// client uploaded survived the copy and landed in the same order, and neither is
// guaranteed: a mon this file cannot describe is skipped, a party past
// MONS_PER_PARTY is cut short, and a coop_npc trainer's team is dealt across two
// seats before it ever gets here. In all three the array index has moved and the
// position on the player's own screen has not, so the position is what a choice
// is matched against. `fallback` is that index for a sender that stated none,
// which keeps an ordinary party numbered exactly as it always was.
function copyStages(raw) {
  const src = isTable(raw) ? raw : {};
  return {
    atk: Effects.clampStage(src.atk),
    def: Effects.clampStage(src.def),
    spd: Effects.clampStage(src.spd),
    spc: Effects.clampStage(src.spc),
    acc: Effects.clampStage(src.acc),
    eva: Effects.clampStage(src.eva),
  };
}

function copyMon(raw, fallback) {
  if (!isTable(raw)) return null;

  const stats = isTable(raw.stats) ? raw.stats : {};
  const maxHp = Math.max(1, int(raw.maxHp, 1));
  let hp = raw.hp === undefined || raw.hp === null
    ? maxHp
    : Math.max(0, int(raw.hp, 0));
  if (hp > maxHp) hp = maxHp;

  let status = str(raw.status);
  if (status) status = has(STATUS_FROM_WIRE, status) ? STATUS_FROM_WIRE[status] : status;
  if (status && !(has(GATING, status) || status === 'poison'
                  || status === 'burn' || status === 'toxic')) {
    status = null; // a token nothing branches on is noise
  }

  const moves = [];
  if (Array.isArray(raw.moves)) {
    for (const entry of raw.moves) {
      const move = copyMove(entry);
      if (move) moves.push(move);
    }
  }

  // Sleep with no counter is read as one turn left, so it still costs the turn
  // it wakes on rather than passing the gate as if healthy. Any other default
  // would be inventing a length; one is the shortest honest answer.
  let turns = Math.max(0, int(raw.statusTurns, 0));
  if (status === 'sleep' && turns === 0) turns = 1;

  const stages = copyStages(raw.stages);

  let disable = null;
  if (isTable(raw.disable)) {
    disable = {
      moveIndex: Math.max(0, int(raw.disable.moveIndex, 0)),
      turns: Math.max(0, int(raw.disable.turns, 0)),
    };
  }

  let charging = null;
  if (isTable(raw.charging)) {
    charging = {
      moveIndex: Math.max(1, int(raw.charging.moveIndex, 1)),
      effect: Math.max(0, int(raw.charging.effect, 0)),
      targetSlot: int(raw.charging.targetSlot, null),
    };
  }

  let trapped = null;
  if (isTable(raw.trapped)) {
    trapped = {
      turns: Math.max(0, int(raw.trapped.turns, 0)),
      damage: Math.max(0, int(raw.trapped.damage, 0)),
      fromSlot: int(raw.trapped.fromSlot, null),
    };
  }

  let thrashing = null;
  if (isTable(raw.thrashing)) {
    thrashing = {
      turns: Math.max(0, int(raw.thrashing.turns, 0)),
      moveIndex: Math.max(1, int(raw.thrashing.moveIndex, 1)),
    };
  }

  let bide = null;
  if (isTable(raw.bide)) {
    bide = {
      turns: Math.max(0, int(raw.bide.turns, 0)),
      stored: Math.max(0, int(raw.bide.stored, 0)),
      moveIndex: Math.max(1, int(raw.bide.moveIndex, 1)),
      targetSlot: int(raw.bide.targetSlot, null),
    };
  }

  let leechSeed = null;
  if (raw.leechSeed === true) {
    leechSeed = { fromSlot: null };
  } else if (isTable(raw.leechSeed)) {
    leechSeed = { fromSlot: int(raw.leechSeed.fromSlot, null) };
  }

  const out = {
    species: str(raw.species) || '?',
    slot: Math.max(0, int(raw.slot, Math.max(0, int(fallback, 0)))),
    level: Math.max(1, int(raw.level, 1)),
    hp,
    maxHp,
    status,
    statusTurns: turns,
    toxicCounter: Math.max(1, int(raw.toxicCounter, 1)),
    confusion: Math.max(0, int(raw.confusion, 0)),
    stats: {
      atk: Math.max(1, int(stats.atk, 1)),
      def: Math.max(1, int(stats.def, 1)),
      spd: Math.max(1, int(stats.spd, 1)),
      spc: Math.max(1, int(stats.spc, 1)),
    },
    types: copyTypes(raw.types),
    moves,
    stages,
    leechSeed,
    disable,
    flinch: raw.flinch === true,
    charging,
    invulnerable: raw.invulnerable === true,
    mustRecharge: raw.mustRecharge === true,
    trapped,
    trapping: null,
    thrashing,
    raging: raw.raging === true,
    rageMove: Math.max(0, int(raw.rageMove, 0)),
    bide,
    lastMoveIndex: Math.max(0, int(raw.lastMoveIndex, 0)),
    substitute: Math.max(0, int(raw.substitute, 0)),
    lightScreen: raw.lightScreen === true,
    reflect: raw.reflect === true,
    mist: raw.mist === true,
    focusEnergy: raw.focusEnergy === true,
    transformed: raw.transformed === true,
    xAccuracy: raw.xAccuracy === true,
    catchRate: Math.max(0, Math.min(255, int(raw.catchRate, 255))),
  };

  // Optional Stat Exp sheet (atk/def/spd/spc, optional hp).
  if (isTable(raw.evs)) {
    const evs = {};
    for (const key of ['hp', 'atk', 'def', 'spd', 'spc']) {
      if (raw.evs[key] !== undefined && raw.evs[key] !== null) {
        evs[key] = Math.max(0, Math.min(65535, int(raw.evs[key], 0)));
      }
    }
    out.evs = evs;
  }
  return out;
}

// ------------------------------------------------------------------
// the field
// ------------------------------------------------------------------
//
// Party indices stay 1-based throughout, the way the Lua holds them, and the
// array behind them is 0-based -- so every party lookup goes through `monAt`
// rather than open-coding the minus one at fifteen call sites.

function monAt(fighter, index) {
  if (index === null || index === undefined) return null;
  return fighter.mons[index - 1] || null;
}

function firstLiving(mons, skip) {
  for (let i = 1; i <= mons.length; i += 1) {
    if (mons[i - 1].hp > 0 && i !== skip) return i;
  }
  return null;
}

function activeMon(fighter) {
  if (!fighter.active) return null;
  const mon = monAt(fighter, fighter.active);
  if (mon && mon.hp > 0) return mon;
  return null;
}

// Which of this party a zero-based wire slot means.
//
// Matched against the position each monster claims rather than counted off the
// array, for the reason copyMon gives -- and the array index is the fallback
// rather than the rule, so a sender whose party arrived intact is unaffected and
// one whose party was cut or dealt still switches to the monster it named.
function partyIndexOf(fighter, wireSlot) {
  for (let i = 1; i <= fighter.mons.length; i += 1) {
    if (fighter.mons[i - 1].slot === wireSlot) return i;
  }
  return wireSlot + 1;
}

function hasType(mon, typeId) {
  return mon.types.includes(typeId);
}

function allPpEmpty(mon) {
  if (mon.moves.length === 0) return true;
  for (const m of mon.moves) {
    if (m.pp > 0) return false;
  }
  return true;
}

function copyBadges(raw) {
  if (!isTable(raw)) return null;
  const out = Object.create(null);
  let any = false;
  for (const id of Object.keys(raw)) {
    if (raw[id]) {
      out[id] = true;
      any = true;
    }
  }
  if (!any) return null;
  return out;
}

// Bag sheet for auto-pick / timeout item use (id → count). Accepts the same
// shapes Wire.bag does: a list of {id,count} or a map.
function copyBag(raw) {
  if (!isTable(raw)) return null;
  const out = Object.create(null);
  let any = false;
  const put = (id, count) => {
    if (typeof id !== 'string' || id === '') return;
    const n = int(count, 0);
    if (!n || n < 1) return;
    out[id] = (out[id] || 0) + n;
    any = true;
  };
  if (Array.isArray(raw)) {
    for (const entry of raw) {
      if (isTable(entry)) put(entry.id, entry.count);
    }
  } else {
    for (const id of Object.keys(raw)) put(id, raw[id]);
  }
  if (!any) return null;
  return out;
}

// ------------------------------------------------------------------
// the battle
// ------------------------------------------------------------------

class Battle {
  constructor(opts) {
    this.id = str(opts.id) || 'battle';
    this.mode = has(MODES, opts.mode) ? opts.mode : '1v1';
    this.seed = int(opts.seed, 0);
    this.rng = Rng.create(int(opts.seed, 0));
    this.chart = isTable(opts.chart) ? opts.chart : null;
    this.specialTypes = null;
    if (Array.isArray(opts.specialTypes)) {
      const set = Object.create(null);
      for (const t of opts.specialTypes) set[Math.max(0, int(t, 0))] = true;
      this.specialTypes = set;
    }
    this.metronomePool = null;
    if (Array.isArray(opts.metronomePool)) {
      const pool = [];
      for (const entry of opts.metronomePool) {
        const move = copyMove(entry);
        if (move) pool.push(move);
      }
      if (pool.length > 0) this.metronomePool = pool;
    }
    this.choiceTimeout = Math.max(0, int(opts.choiceTimeout, CHOICE_TIMEOUT));
    this.reconnectGrace = Math.max(0, int(opts.reconnectGrace, RECONNECT_GRACE));
    this.resolveTimeout = Math.max(0, int(opts.resolveTimeout, RESOLVE_TIMEOUT));
    this.now = Math.max(0, int(opts.now, 0));
    this.phase = 'choice';
    this.turn = 1;
    this.seq = 0;
    this.deadline = null;
    this.resolveDeadline = null;
    this.buffer = [];
    this.fighters = [];
    // A Map, not an object: a playerId is attacker-supplied and "__proto__" is
    // a perfectly legal string.
    this.byId = new Map();
    this.bySide = { a: [], b: [] };
    // What the current action has knocked down and not paid for yet; see
    // `_drainExp`. A list, so the order faints happened in is the order their
    // spoils are announced in.
    this.pendingExp = [];
    this.result = null;
  }

  // ----------------------------------------------------------------
  // events
  // ----------------------------------------------------------------

  _emit(kind, fields) {
    const event = Events.build(kind, fields);
    if (!event) return null;
    this.seq += 1;
    event.battle = this.id;
    event.seq = this.seq;
    this.buffer.push(event);
    return event;
  }

  _emitMoves(fighter, mon) {
    const moves = mon.moves.map((m) => ({
      id: m.id || 'move',
      pp: Math.max(0, int(m.pp, 0)),
      power: Math.max(0, int(m.power, 0)),
      accuracy: Math.max(0, int(m.accuracy, 255)),
      type: Math.max(0, int(m.type, 0)),
      effect: Math.max(0, int(m.effect, 0)),
      chance: Math.max(0, int(m.chance, 0)),
    }));
    return this._emit('moves', {
      slot: fighter.slot, side: fighter.side, moves,
    });
  }

  _say(text) {
    return this._emit('msg', { text });
  }

  /*
   * Everything since the last call, in order, and the buffer is emptied. A
   * caller that drops the returned list drops those events for good, which is
   * deliberate: the alternative -- a buffer that grows until somebody reads it
   * -- is a memory leak on a hub whose client has gone quiet.
   */
  drainEvents() {
    const out = this.buffer;
    this.buffer = [];
    return out;
  }

  // ----------------------------------------------------------------
  // the field
  // ----------------------------------------------------------------

  _foes(fighter) {
    return this.bySide[fighter.side === 'a' ? 'b' : 'a'];
  }

  _fighterAtSlot(slot) {
    for (const fighter of this.fighters) {
      if (fighter.slot === slot) return fighter;
    }
    return null;
  }

  _firstLivingFoe(fighter) {
    for (const foe of this._foes(fighter)) {
      if (activeMon(foe)) return foe;
    }
    return null;
  }

  // Which seat an action actually swings at, given the seat it was aimed at.
  //
  // A fight choice always names a living opposing seat when it is made:
  // `_normaliseChoice` refuses an empty one, and the replace phase means the
  // field is whole again before the next choice window opens.  **A mid-turn
  // faint is therefore the only way an aim can go stale** -- in a 2v2 the
  // faster ally KOs the seat the slower ally picked, and without this the
  // slower mon fizzles ("has no target") instead of swinging.
  //
  // Preference order:
  //   (a) whatever is standing in the SAME field position.  A seat *is* a
  //       field position here, so this also covers the case where the seat was
  //       emptied and refilled between choice and execution -- the aim the
  //       player made still points at a real monster and is honoured
  //       unchanged.
  //   (b) otherwise the NEAREST living opposing seat: smallest
  //       |seat.slot - aimedSlot| (both sit on the same side, so the side base
  //       cancels and this is seat-index distance), ties broken toward the
  //       lower seat index.  With two seats a side that is simply the adjacent
  //       seat; the rule is spelled out so a wider field could not make it
  //       ambiguous.
  //   (c) otherwise null -- the opposing side has nothing standing, the battle
  //       is ending, and the action is skipped.
  //
  // Only the opposing side is ever searched, so nothing here can redirect a
  // move onto the user or its ally; self-targeting and side-wide effects ride
  // the same opposing-seat aim they always did and are untouched.  The answer
  // is bound once per action in `_useMove`, so a multi-hit strike puts every
  // hit on the retargeted seat -- an action retargets, not each of its strikes.
  _retarget(fighter, slot) {
    const aimed = this._fighterAtSlot(slot);
    if (aimed && activeMon(aimed)) return aimed;

    let best = null;
    let bestDistance = null;
    for (const foe of this._foes(fighter)) {
      if (!activeMon(foe)) continue;
      const distance = Math.abs(foe.slot - slot);
      if (bestDistance === null || distance < bestDistance
          || (distance === bestDistance && foe.slot < best.slot)) {
        best = foe;
        bestDistance = distance;
      }
    }
    return best;
  }

  _sideAlive(side) {
    for (const fighter of this.bySide[side]) {
      if (firstLiving(fighter.mons)) return true;
    }
    return false;
  }

  _sidePlayers(side) {
    return this.bySide[side].map((fighter) => fighter.playerId);
  }

  // A fighter owes a choice when it has something standing, or when it must pick
  // a replacement after a faint. A player whose last monster fainted in a 2v2 is
  // a spectator for the rest of the fight, and waiting on them would hang the
  // turn. Multi-turn volatiles auto-fill before the player is asked.
  //
  // In the `replace` phase the only thing anybody owes is a replacement: the
  // seats that are still standing answered last turn and are not being asked
  // again, so their standing monster must not hold the phase open. Everything
  // that reads "who are we waiting on" -- `_anyoneOwes`, the timeout sweep in
  // `tick`, `snapshot().waiting` -- goes through here, which is why the phase
  // test lives in this one function rather than at each of those call sites.
  _owes(fighter) {
    if (fighter.choice !== null && fighter.choice !== undefined) return false;
    if (fighter.mustReplace) {
      return firstLiving(fighter.mons) !== null;
    }
    if (this.phase === 'replace') return false;
    if (activeMon(fighter) === null) return false;
    return true;
  }

  // Inject forced choices for charge release, recharge skip, thrash/rage repeat,
  // and trap lock-in. Gen1 trapping: victim can't move; user stays locked (no
  // menu) while residual damage (first-hit store) ticks — not a re-rolled fight.
  _fillForcedChoices() {
    for (const fighter of this.fighters) {
      if (fighter.choice !== null && fighter.choice !== undefined) continue;
      const mon = activeMon(fighter);
      if (!mon) continue;

      if (mon.mustRecharge) {
        mon.mustRecharge = false;
        this._say(`${mon.species} must recharge`);
        fighter.choice = { action: 'skip' };
        this._emit('chose', {
          slot: fighter.slot, side: fighter.side, text: fighter.name,
        });
        continue;
      }

      if (mon.bide) {
        if (mon.bide.turns > 0) {
          this._say(`${mon.species} is storing energy`);
          fighter.choice = { action: 'skip' };
          this._emit('chose', {
            slot: fighter.slot, side: fighter.side, text: fighter.name,
          });
        } else {
          const foe = this._firstLivingFoe(fighter);
          if (foe) {
            this._say(`${mon.species} unleashed energy`);
            fighter.choice = {
              action: 'fight',
              move: mon.bide.moveIndex,
              target: mon.bide.targetSlot || foe.slot,
              bideRelease: true,
            };
            this._emit('chose', {
              slot: fighter.slot, side: fighter.side, text: fighter.name,
            });
          }
        }
        continue;
      }

      if (mon.trapped && mon.trapped.turns > 0) {
        this._say(`${mon.species} can't move`);
        fighter.choice = { action: 'skip' };
        this._emit('chose', {
          slot: fighter.slot, side: fighter.side, text: fighter.name,
        });
        continue;
      }

      if (mon.trapping && mon.trapping.turns > 0) {
        // Cartridge lock-in: no menu, residual still deals stored damage. Emit
        // continue narration + anim so the screen shows the trap going on —
        // do not re-enter _useMove (that would re-roll damage).
        const move = mon.moves[mon.trapping.moveIndex - 1];
        const moveId = (move && move.id) || 'attack';
        this._say(`${mon.species}'s ${moveId} continues`);
        this._emit('anim', {
          slot: fighter.slot, side: fighter.side, text: moveId,
        });
        fighter.choice = { action: 'skip' };
        this._emit('chose', {
          slot: fighter.slot, side: fighter.side, text: fighter.name,
        });
        continue;
      }

      if (mon.charging) {
        const c = mon.charging;
        fighter.choice = {
          action: 'fight',
          move: c.moveIndex,
          target: c.targetSlot,
        };
        this._emit('chose', {
          slot: fighter.slot, side: fighter.side, text: fighter.name,
        });
        continue;
      }

      if (mon.thrashing && mon.thrashing.turns > 0) {
        const foe = this._firstLivingFoe(fighter);
        if (foe) {
          this._say(`${mon.species} thrashing about`);
          fighter.choice = {
            action: 'fight',
            move: mon.thrashing.moveIndex,
            target: foe.slot,
          };
          this._emit('chose', {
            slot: fighter.slot, side: fighter.side, text: fighter.name,
          });
        }
        continue;
      }

      if (mon.raging && mon.rageMove && mon.rageMove > 0) {
        const foe = this._firstLivingFoe(fighter);
        if (foe) {
          this._say(`${mon.species}'s RAGE is building`);
          fighter.choice = {
            action: 'fight',
            move: mon.rageMove,
            target: foe.slot,
          };
          this._emit('chose', {
            slot: fighter.slot, side: fighter.side, text: fighter.name,
          });
        }
      }
    }
  }

  _anyDisconnected() {
    return this.fighters.some((fighter) => !fighter.connected);
  }

  // ----------------------------------------------------------------
  // choices
  // ----------------------------------------------------------------
  //
  // Indices arrive zero-based, because that is how they ride on the wire:
  // `move` is 0..3 into the monster's moves, `slot` is 0..5 into the party, and
  // `target` is a 0..3 *field* slot. They are converted here, once, so nothing
  // downstream has to remember which of the three it is holding.

  _normaliseChoice(fighter, choice) {
    const action = choice.action;

    // Forced replacement: only a living bench switch is accepted. Fight / item /
    // run would spend a turn the seat does not have a mon for.
    if (fighter.mustReplace) {
      if (action !== 'switch') return null;
      const slot = int(choice.slot, null);
      if (slot === null) return null;
      const target = partyIndexOf(fighter, slot);
      const bench = monAt(fighter, target);
      if (!bench || bench.hp <= 0) return null;
      return { action: 'switch', slot: target };
    }

    const mon = activeMon(fighter);
    if (!mon) return null;

    if (action === 'run') return { action: 'run' };

    if (action === 'item') {
      const item = str(choice.item);
      if (!item) return null;
      // Wildlife has no bag and no hands. Refused rather than ignored so a wild
      // seat that is somehow handed one never spends the turn on it either.
      if (isWildSeat(this.mode, fighter)) return null;
      // A fighter with a bag sheet must actually hold the stack (hub/NPC auto).
      // Seats with no bag stay permissive so headless fixtures can still item.
      if (fighter.bag && !this._bagHas(fighter, item)) return null;
      const effect = Effects.itemEffect(item);
      const out = { action: 'item', item };
      if (choice.slot !== undefined && choice.slot !== null) {
        const slot = int(choice.slot, null);
        if (slot === null) return null;
        const target = partyIndexOf(fighter, slot);
        if (!monAt(fighter, target)) return null;
        out.slot = target;
      }
      if (choice.move !== undefined && choice.move !== null) {
        const move = int(choice.move, null);
        if (move === null) return null;
        out.move = move + 1;
      } else if (effect && effect.needsMove) {
        return null;
      }
      return out;
    }

    if (action === 'switch') {
      const slot = int(choice.slot, null);
      if (slot === null) return null;
      const target = partyIndexOf(fighter, slot);
      const bench = monAt(fighter, target);
      if (!bench || bench.hp <= 0 || target === fighter.active) return null;
      return { action: 'switch', slot: target };
    }

    if (action === 'fight') {
      const index = int(choice.move, null);
      if (index === null) return null;
      const move = mon.moves[index];
      if (!move) return null;
      // One empty slot is refused; every slot empty means Struggle on any index.
      if (move.pp <= 0 && !allPpEmpty(mon)) return null;
      if (mon.disable && mon.disable.turns > 0
          && mon.disable.moveIndex === index + 1) {
        return null;
      }

      let targetFighter;
      if (choice.target !== undefined && choice.target !== null) {
        targetFighter = this._fighterAtSlot(int(choice.target, -1));
        // A named target on the chooser's own side is refused. A seat mid-replace
        // (mustReplace, no active yet) is still a legal aim: switches resolve
        // before fights, so the mon will be out when the move lands.
        if (!targetFighter || targetFighter.side === fighter.side) {
          return null;
        }
        if (!activeMon(targetFighter) && !targetFighter.mustReplace) {
          return null;
        }
      } else {
        targetFighter = this._firstLivingFoe(fighter);
        if (!targetFighter) {
          for (const foe of this._foes(fighter)) {
            if (foe.mustReplace) { targetFighter = foe; break; }
          }
        }
        if (!targetFighter) return null;
      }
      return { action: 'fight', move: index + 1, target: targetFighter.slot };
    }

    return null;
  }

  /*
   * Returns true when the choice is now held for this turn, false otherwise.
   * False is the whole of the error report on purpose: the reasons a choice is
   * refused (wrong phase, unknown player, already answered, an index that names
   * nothing) are all things the client can see for itself, and a string here
   * would be a second vocabulary to keep in step across two runtimes.
   */
  submitChoice(playerId, choice) {
    if (this.phase !== 'choice' && this.phase !== 'replace') return false;
    if (!isTable(choice)) return false;

    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    if (!has(ACTIONS, choice.action)) return false;

    // The replace phase belongs to the seats that owe a send-out and to nobody
    // else: a standing seat's fight would be an answer to a turn that has not
    // opened yet, and taking it here would spend it before the player saw the
    // successor come out. Refused rather than queued, so the client asks again
    // on the `turn` that follows the send.
    if (this.phase === 'replace' && !this._owes(fighter)) return false;

    if (choice.action === 'cancel') {
      // A forced replacement is not a decision that can be taken back: the
      // field is a monster short until it is answered, so `unchose` here would
      // only hand the seat a second way to hold the fight open.
      if (this.phase === 'replace') return false;
      if (fighter.choice === null) return false;
      this._emit('unchose', {
        slot: fighter.slot, side: fighter.side, text: fighter.name,
      });
      fighter.choice = null;
      return true;
    }

    if (fighter.choice !== null) return false; // one answer per turn
    if (fighter.mustReplace) {
      if (choice.action !== 'switch') return false;
    } else if (!activeMon(fighter)) {
      return false;
    }

    const normalised = this._normaliseChoice(fighter, choice);
    if (!normalised) return false;

    fighter.choice = normalised;
    // Peers need this for the wait line: without it, only the chooser's own
    // client knows they answered (there is no `act` fan-out on the mediated path).
    this._emit('chose', {
      slot: fighter.slot, side: fighter.side, text: fighter.name,
    });
    this._maybeResolve();
    return true;
  }

  _maybeResolve() {
    if (this.phase !== 'choice' && this.phase !== 'replace') return false;
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) return false;
    }
    if (this.phase === 'replace') {
      this._closeReplace();
      return true;
    }
    this._resolveTurn();
    return true;
  }

  // timeout/NPC pick: bag cures/heals/X-items when present, else SE / status /
  // setup / switch. Deterministic twin of src/BattleSim/Turn.lua — richer than
  // a strongest-move heuristic, still not a full TrainerAI port.
  _effectivenessProduct(moveType, defender) {
    const percents = this._typePercents(moveType, defender);
    let eff = 1;
    for (const pct of percents) eff = (eff * pct) / 100;
    return eff;
  }

  _bagHas(fighter, itemId) {
    return !!(fighter.bag && (fighter.bag[itemId] || 0) > 0);
  }

  _spendBag(fighter, itemId) {
    if (!fighter.bag) return;
    const n = fighter.bag[itemId];
    if (!n) return;
    if (n <= 1) delete fighter.bag[itemId];
    else fighter.bag[itemId] = n - 1;
  }

  _bestSeBench(fighter, defender) {
    if (!defender) return null;
    let best = null;
    let bestEff = 1;
    for (let i = 1; i <= fighter.mons.length; i += 1) {
      if (i !== fighter.active) {
        const bench = fighter.mons[i - 1];
        if (bench && bench.hp > 0) {
          let maxEff = 1;
          for (let j = 0; j < bench.moves.length; j += 1) {
            const m = bench.moves[j];
            if (m.pp > 0 && m.power > 0) {
              const eff = this._effectivenessProduct(m.type, defender);
              if (eff > maxEff) maxEff = eff;
            }
          }
          if (maxEff > 1) {
            if (!best || maxEff > bestEff || (maxEff === bestEff && i < best)) {
              best = i;
              bestEff = maxEff;
            }
          }
        }
      }
    }
    return best;
  }

  // Bag item for the active mon: cure → heal ≤50% → X-item while stages flat.
  _autoItemChoice(fighter, mon) {
    if (!fighter.bag) return null;
    // A wild monster is not a trainer: it never reaches into a bag, even when
    // the hub seeded its seat with one.
    if (isWildSeat(this.mode, fighter)) return null;

    if (mon.status) {
      const list = AUTO_STATUS_CURE[mon.status];
      if (list) {
        for (const id of list) {
          if (this._bagHas(fighter, id)) {
            return { action: 'item', item: id, slot: fighter.active };
          }
        }
      }
    }

    if (mon.hp < mon.maxHp && mon.hp * 2 <= mon.maxHp) {
      for (const id of AUTO_HEAL_PREF) {
        if (this._bagHas(fighter, id)) {
          const effect = Effects.itemEffect(id);
          if (effect && (effect.heal || effect.healFull || effect.clearAllStatus)) {
            return { action: 'item', item: id, slot: fighter.active };
          }
        }
      }
    }

    const stagesFlat = mon.stages.atk <= 0 && mon.stages.def <= 0
      && mon.stages.spd <= 0 && mon.stages.spc <= 0;
    if (stagesFlat && !mon.focusEnergy && !mon.mist) {
      for (const row of AUTO_X_ITEM) {
        if (this._bagHas(fighter, row.id)) {
          if (row.flag === 'focusEnergy' && !mon.focusEnergy) {
            return { action: 'item', item: row.id };
          }
          if (row.flag === 'mist' && !mon.mist) {
            return { action: 'item', item: row.id };
          }
          if (row.stat && (mon.stages[row.stat] || 0) <= 0) {
            return { action: 'item', item: row.id };
          }
        }
      }
    }

    return null;
  }

  _autoChoice(fighter) {
    if (fighter.mustReplace) {
      const foe = this._firstLivingFoe(fighter);
      const defender = foe && activeMon(foe);
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
      const next = firstLiving(fighter.mons);
      if (next) return { action: 'switch', slot: next };
      return null;
    }

    const mon = activeMon(fighter);
    if (!mon) return null;

    if (mon.charging) {
      const c = mon.charging;
      return { action: 'fight', move: c.moveIndex, target: c.targetSlot };
    }
    if (mon.mustRecharge) {
      return { action: 'skip' };
    }
    if (mon.bide) {
      if (mon.bide.turns > 0) {
        return { action: 'skip' };
      }
      const foe = this._firstLivingFoe(fighter);
      if (foe) {
        return {
          action: 'fight',
          move: mon.bide.moveIndex,
          target: mon.bide.targetSlot || foe.slot,
          bideRelease: true,
        };
      }
    }
    if (mon.trapped && mon.trapped.turns > 0) {
      return { action: 'skip' };
    }
    if (mon.trapping && mon.trapping.turns > 0) {
      return { action: 'skip' };
    }
    if (mon.thrashing && mon.thrashing.turns > 0) {
      const foe = this._firstLivingFoe(fighter);
      if (foe) {
        return {
          action: 'fight',
          move: mon.thrashing.moveIndex,
          target: foe.slot,
        };
      }
    }
    if (mon.raging && mon.rageMove && mon.rageMove > 0) {
      const foe = this._firstLivingFoe(fighter);
      if (foe) {
        return { action: 'fight', move: mon.rageMove, target: foe.slot };
      }
    }

    let foe = this._firstLivingFoe(fighter);
    if (!foe) {
      for (const f of this._foes(fighter)) {
        if (f.mustReplace) { foe = f; break; }
      }
    }
    if (!foe) return null;
    const defender = activeMon(foe);
    if (!defender) {
      let pick = 1;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        if (mon.moves[i - 1].pp > 0) { pick = i; break; }
      }
      return { action: 'fight', move: pick, target: foe.slot };
    }

    const itemPick = this._autoItemChoice(fighter, mon);
    if (itemPick) return itemPick;

    const foeBoosted = (defender.stages.atk || 0) >= 2
      || (defender.stages.def || 0) >= 2
      || (defender.stages.spd || 0) >= 2
      || (defender.stages.spc || 0) >= 2
      || defender.focusEnergy;
    const foeSub = (defender.substitute || 0) > 0;
    const weSlower = this._speedOf(fighter, mon) < this._speedOf(foe, defender);

    // Critical HP: SE retreat (heal already tried via bag).
    if (mon.hp * 4 <= mon.maxHp) {
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
    }

    // Behind a boosted / subbed foe at mid-low HP: prefer an SE bench mon.
    if ((foeBoosted || foeSub) && mon.hp * 2 <= mon.maxHp) {
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
    }

    const disabled = (i) => mon.disable && mon.disable.turns > 0
      && mon.disable.moveIndex === i;

    let pick = null;
    let pickEff = -1;
    let pickPow = -1;
    for (let i = 1; i <= mon.moves.length; i += 1) {
      const m = mon.moves[i - 1];
      if (m.pp > 0 && m.power > 0 && !disabled(i)) {
        const eff = this._effectivenessProduct(m.type, defender);
        if (!pick || eff > pickEff
            || (eff === pickEff && m.power > pickPow)
            || (eff === pickEff && m.power === pickPow && i < pick)) {
          pick = i;
          pickEff = eff;
          pickPow = m.power;
        }
      }
    }

    if (!pick || pickEff === 0) {
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
    }

    if (pick && pickEff > 1) {
      return { action: 'fight', move: pick, target: foe.slot };
    }

    // Status fails against a Substitute; skip it and trade damage instead.
    if (!defender.status && !foeSub) {
      let statusPick = null;
      let statusPri = -1;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        const m = mon.moves[i - 1];
        if (m.pp > 0 && !disabled(i) && m.power === 0) {
          const pri = AUTO_STATUS_PRI[m.effect];
          if (pri !== undefined && (pri > statusPri
              || (pri === statusPri && (statusPick === null || i < statusPick)))) {
            statusPick = i;
            statusPri = pri;
          }
        }
      }
      if (statusPick !== null
          && (weSlower || foeBoosted || !pick || pickEff <= 1)) {
        return { action: 'fight', move: statusPick, target: foe.slot };
      }
    }

    const stagesFlat = mon.stages.atk <= 0 && mon.stages.def <= 0
      && mon.stages.spd <= 0 && mon.stages.spc <= 0;
    // Do not set up into a boosted foe, behind a substitute, or while slower
    // at mid-low HP — hit or switch instead.
    if (stagesFlat && !mon.focusEnergy && !foeBoosted && !foeSub
        && !(weSlower && mon.hp * 2 <= mon.maxHp)) {
      let setupPick = null;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        const m = mon.moves[i - 1];
        if (m.pp > 0 && !disabled(i) && m.power === 0) {
          const kind = AUTO_SETUP[m.effect];
          if (kind === true
              || (typeof kind === 'string' && (mon.stages[kind] || 0) <= 0)) {
            if (setupPick === null || i < setupPick) setupPick = i;
          }
        }
      }
      if (setupPick !== null) {
        return { action: 'fight', move: setupPick, target: foe.slot };
      }
    }

    if (!(pick && pickEff > 0)) {
      pick = null;
      pickPow = -1;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        const m = mon.moves[i - 1];
        if (m.pp > 0 && !disabled(i)) {
          if (!pick || m.power > pickPow
              || (m.power === pickPow && i < pick)) {
            pick = i;
            pickPow = m.power;
          }
        }
      }
    }

    if (pick === null) pick = 1;
    if (!mon.moves[pick - 1]) return null;
    return { action: 'fight', move: pick, target: foe.slot };
  }

  /*
   * File that pick for a seat that has nobody to send one.
   *
   * The npc side of a coop_npc is seated like any other fighter and has no
   * connection behind it, so without this the referee would wait out the whole
   * choice deadline every turn and then auto-pick anyway -- a minute a turn, for
   * a decision nothing was ever going to make. It is deliberately the *same*
   * pick the timeout files rather than a second, cleverer one: both runtimes
   * reproduce it byte for byte (bag / SE / status / setup / switch heuristics
   * above).
   *
   * Returns true when a choice was actually filed, so a caller can loop until
   * the machine stops owing. Filing one may resolve the turn and open the next,
   * which is what makes that loop the thing that carries the fight forward.
   */
  autoPick(playerId) {
    if (this.phase !== 'choice' && this.phase !== 'replace') return false;
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    if (fighter.choice !== null && fighter.choice !== undefined) return false;
    // Same rule as a human's: in the replace phase only the seats that owe a
    // send-out may file, so an NPC that is still standing does not answer a
    // turn that has not opened. The hub's fillNpcChoices calls this in a loop
    // and stops when nothing files, so the false is how the loop learns to stop.
    if (this.phase === 'replace' && !this._owes(fighter)) return false;
    if (!fighter.mustReplace && !activeMon(fighter)) return false;

    const auto = this._autoChoice(fighter);
    if (!auto) return false;
    fighter.choice = auto;
    this._emit('chose', {
      slot: fighter.slot, side: fighter.side, text: fighter.name,
    });
    this._maybeResolve();
    return true;
  }

  // ----------------------------------------------------------------
  // resolution
  // ----------------------------------------------------------------

  _anyoneOwes() {
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) return true;
    }
    return false;
  }

  _openTurn() {
    this.phase = 'choice';
    this.resolveDeadline = null;
    this.forcedPending = false;
    for (const fighter of this.fighters) fighter.choice = null;
    this.deadline = this.choiceTimeout > 0 ? this.now + this.choiceTimeout : null;
    this._emit('turn', { amount: this.turn });
    this._fillForcedChoices();
    // When every living seat is forced, defer resolve to the next tick so
    // clients see a turn boundary before the chain continues.
    if (!this._anyoneOwes()) {
      this.forcedPending = true;
      this.deadline = null;
    }
  }

  // ----------------------------------------------------------------
  // the replace phase
  // ----------------------------------------------------------------
  //
  // A faint with a living bench used to be folded into the *next* choice
  // window: the referee incremented the turn, opened it, and the seat's
  // replacement rode in alongside everybody else's fight. That is one window
  // with an empty box in it -- the player picked a move at a foe that was not
  // on the field yet, and the successor only walked out when the turn after
  // that resolved. Vanilla never does this, and neither does the host sim
  // beside it: CoopSim's `announceFaint` sends an NPC's next monster out inside
  // the faint batch and asks a player's seat before the fight goes on.
  //
  // So the referee holds a phase of its own between the two turns. Nothing else
  // is asked for, nothing resolves, and the turn number does not move: the
  // fight is still on the turn whose faint opened this. When the last owed
  // replacement is in, `_resolveSwitches` fields them all (`switch` + `send`)
  // and only then does the next turn open. For a seat with no connection behind
  // it that whole phase closes inside one hub flush -- NPC choices are filled
  // before the drain -- so the client reads one batch: faint ... switch ...
  // send ... turn.

  _anyMustReplace() {
    for (const fighter of this.fighters) {
      if (fighter.mustReplace && firstLiving(fighter.mons) !== null) return true;
    }
    return false;
  }

  /*
   * Solicitation: one `turn` per owing seat, carrying the seat's **field slot**.
   *
   * That slot is the whole of the wire change, and it is the client contract:
   *   * `turn` WITH `slot` -- this seat is being asked for a replacement. Its
   *     own client opens the switch picker; everyone else holds on "X is
   *     choosing who to send out...".
   *   * `turn` WITHOUT `slot` -- the ordinary choice window is open (`_openTurn`).
   * No new kind, no new field: `slot` is already in the event whitelist and
   * already rides the wire sanitiser kind-agnostically, so a client built
   * before this ignores it and degrades to the old behaviour rather than
   * breaking.
   *
   * Seat order is `this.fighters`, which is side a then side b in seating order
   * -- ascending field slot, and the same order in both runtimes.
   */
  _openReplace() {
    this.phase = 'replace';
    this.resolveDeadline = null;
    this.forcedPending = false;
    for (const fighter of this.fighters) fighter.choice = null;
    this.deadline = this.choiceTimeout > 0 ? this.now + this.choiceTimeout : null;
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) {
        this._emit('turn', { amount: this.turn, slot: fighter.slot });
      }
    }
  }

  // Every replacement is in: field them, then open the turn they were owed for.
  _closeReplace() {
    this._resolveSwitches();
    this.turn += 1;
    this._openTurn();
  }

  _speedOf(fighter, mon) {
    let spd = Effects.badgeBoost(mon.stats.spd, 'spd', fighter.badges);
    spd = Effects.applyStage(spd, mon.stages.spd);
    if (mon.status === 'paralysis') spd = Status.paralysisSpeed(spd);
    return spd;
  }

  /*
   * chart[atkType][defType], one percent per defender type, because
   * Damage.compute applies them as separate truncating steps the way the
   * original does. A missing row, a missing cell or no chart at all reads as
   * neutral: a party naming a type this match's chart has no row for is a
   * well-formed party, and refusing it over a lookup would be worse than
   * fighting it straight.
   *
   * The Lua indexes this as chart[atkType + 1][defType + 1] because its arrays
   * start at one. Same chart, same cell -- a JSON type chart transfers between
   * the two runtimes unchanged.
   */
  _typePercents(moveType, defender) {
    const row = this.chart ? this.chart[moveType] : null;
    const out = [];
    for (const defType of defender.types) {
      let pct = 100;
      if (isTable(row)) {
        const cell = toNumber(row[defType]);
        if (cell !== null) pct = Math.floor(cell);
      }
      // The Lua's Damage.compute treats any percent <= 0 as immunity; this
      // one short-circuits on exactly 0. Folding a negative cell down to 0
      // here is how a chart nobody should have written still resolves the
      // same fight on both runtimes.
      out.push(pct < 0 ? 0 : pct);
    }
    if (out.length === 0) out.push(100);
    return out;
  }

  _resolveTurn() {
    this.phase = 'resolving';
    // Armed for the rare case resolution does not leave this phase in the same
    // call -- a throw mid-resolve used to leave the field wedged forever, and
    // the hub's handle() contains those throws so the clock has to finish the job.
    this.resolveDeadline = this.resolveTimeout > 0
      ? this.now + this.resolveTimeout : null;

    if (this._resolveRuns()) return;
    this._resolveSwitches();
    this._resolveItems();
    this._resolveFights();
    if (!this.result) this._resolveResiduals();
    // The residual batch settles the same way an action's does: every flag is
    // off before the first share is counted. Unconditional, because a queue
    // nobody drains is exp that silently never happened.
    this._drainExp();
    if (!this.result) this._checkOver();

    // A seat that fell with a bench left is asked before anything else happens;
    // see the replace-phase note above. The turn does not advance here: it
    // advances in `_closeReplace`, once the successor is actually on the field.
    if (!this.result && this._anyMustReplace()) {
      this._openReplace();
      return;
    }

    if (!this.result) {
      this.turn += 1;
      this._openTurn();
    }
  }

  // Fleeing is a concession; see the policy note in the header.
  _resolveRuns() {
    const running = this.fighters.filter(
      (fighter) => fighter.choice && fighter.choice.action === 'run',
    );
    if (running.length === 0) return false;

    const sides = { a: false, b: false };
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

  _resolveSwitches() {
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (choice && choice.action === 'switch') {
        const mon = monAt(fighter, choice.slot);
        if (mon && mon.hp > 0) {
          fighter.active = choice.slot;
          fighter.mustReplace = null;
          // The seat's monster changed: its own participation set resets and
          // the standing opposition re-marks into it, while the incoming
          // monster joins the sets of the foes it is now in against.
          this._refield(fighter);
          mon.charging = null;
          mon.invulnerable = false;
          mon.thrashing = null;
          mon.raging = false;
          mon.rageMove = 0;
          mon.trapped = null;
          mon.trapping = null;
          mon.bide = null;
          mon.substitute = 0;
          mon.lightScreen = false;
          mon.reflect = false;
          mon.mist = false;
          mon.focusEnergy = false;
          mon.transformed = false;
          mon.xAccuracy = false;
          mon.leechSeed = null;
          mon.disable = null;
          this._clearTrapsFrom(fighter.slot);
          // `mon` is the index the referee just fielded -- `choice.slot`,
          // already normalised to a party position by `_normaliseChoice`. This
          // is the one that matters most: a forced post-faint replacement lands
          // here too, so without it a seat holding two of a species re-fields
          // the fallen copy on the client while the referee holds the living
          // one.
          this._emit('switch', {
            slot: fighter.slot, side: fighter.side, text: mon.species,
            mon: choice.slot - 1,
          });
          this._emit('send', {
            slot: fighter.slot, side: fighter.side, hp: mon.hp, text: mon.species,
            mon: choice.slot - 1,
          });
        }
      }
    }
  }

  _clearTrapsFrom(slot) {
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (mon && mon.trapped && mon.trapped.fromSlot === slot) mon.trapped = null;
      if (mon && mon.trapping && mon.trapping.targetSlot === slot) mon.trapping = null;
    }
  }

  _resolveItems() {
    // Non-ball items keep Gen1 array order (heals, dolls, vitamins, …). Balls
    // resolve in a second pass ordered by active-mon speed (fight tie policy),
    // so the faster thrower spends first and a successful catch aborts the rest.
    for (const fighter of this.fighters) {
      if (this.result) return;
      const choice = fighter.choice;
      if (choice && choice.action === 'item') {
        const effect = Effects.itemEffect(choice.item);
        if (!(effect && effect.ball)) {
          this._resolveOneItem(fighter);
        }
      }
    }

    const balls = [];
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (choice && choice.action === 'item') {
        const effect = Effects.itemEffect(choice.item);
        if (effect && effect.ball) {
          const mon = activeMon(fighter);
          balls.push({
            fighter,
            speed: mon ? this._speedOf(fighter, mon) : 0,
            order: balls.length + 1,
          });
        }
      }
    }
    this._sortActorsBySpeed(balls);
    for (const actor of balls) {
      if (this.result) return;
      this._resolveOneItem(actor.fighter);
    }
  }

  // Sort actors by active-mon speed (desc), then field order; tied groups flip
  // on one RNG byte >= TIE_BREAK_ROLL. Shared by fights and ball throws.
  _sortActorsBySpeed(actors) {
    if (actors.length <= 1) return;

    actors.sort((x, y) => {
      if (x.speed !== y.speed) return y.speed - x.speed;
      return x.order - y.order; // field order: side a, then side b
    });

    // One byte per group of equally fast actors, spent only when the group is
    // actually tied, so an ordinary turn between two different speeds costs no
    // draw at all on either runtime.
    let i = 0;
    while (i < actors.length) {
      let j = i;
      while (j < actors.length - 1 && actors[j + 1].speed === actors[i].speed) j += 1;
      if (j > i && this.rng.byte() >= TIE_BREAK_ROLL) {
        for (let lo = i, hi = j; lo < hi; lo += 1, hi -= 1) {
          const swap = actors[lo];
          actors[lo] = actors[hi];
          actors[hi] = swap;
        }
      }
      i = j + 1;
    }
  }

  _resolveOneItem(fighter) {
    const choice = fighter.choice;
    if (!(choice && choice.action === 'item')) return;

    const effect = Effects.itemEffect(choice.item);
    // Vitamins apply before the `item` event so `amount=1` can mean
    // "Stat Exp writeback is owed"; a failed vitamin still spends the bag
    // stack (Gen1) but must not bump save.statExp on the client.
    let vitaminApplied = false;
    let vitaminMon = null;
    let vitaminResult = null;
    if (effect && effect.vitamin) {
      const partyIdx = choice.slot != null ? choice.slot : fighter.active;
      const mon = monAt(fighter, partyIdx);
      if (mon && mon.hp > 0) {
        const result = Effects.applyVitamin(mon, choice.item);
        if (result) {
          vitaminApplied = true;
          vitaminMon = mon;
          vitaminResult = result;
        }
      }
    }
    const itemEv = {
      slot: fighter.slot, side: fighter.side, text: choice.item,
    };
    if (vitaminApplied) itemEv.amount = 1;
    this._emit('item', itemEv);
    this._say(`${fighter.name} used an item`);
    // Spend after the announce, win or fail (Gen1 bag stack). noConsume
    // (Poké Flute) and seats with no bag sheet are left alone.
    if (!(effect && effect.noConsume)) {
      this._spendBag(fighter, choice.item);
    }
    if (!effect) {
      this._say('But it failed');
    } else if (effect.ball) {
      if (!Effects.isWildMode(this.mode)) {
        this._say('But it failed');
      } else {
        const foe = this._firstLivingFoe(fighter);
        const target = foe && activeMon(foe);
        if (!target) {
          this._say('But it failed');
        } else {
          const result = Effects.catchAttempt(choice.item, target, this.rng);
          // Gen1 TossBallAnimation chain before the catch text (engine ballChain).
          this._emitBallChain(fighter, choice.item, result.caught, result.shakes);
          if (result.shakes > 0 && !result.caught) this._say('The ball shook');
          if (result.caught) {
            this._say('Gotcha');
            const finish = this._finish(
              'win',
              this._sidePlayers(fighter.side),
              this._sidePlayers(fighter.side === 'a' ? 'b' : 'a'),
              'catch',
            );
            const sheet = Effects.caughtSheet(target);
            if (finish && sheet) finish.caught = sheet;
            if (finish) finish.catcher = fighter.playerId;
          } else {
            this._say('It broke free');
          }
        }
      }
    } else if (effect.pokeDoll) {
      if (Effects.isWildMode(this.mode)) {
        this._say('The wild pokemon ran away');
        this._finish(
          'win',
          this._sidePlayers(fighter.side),
          this._sidePlayers(fighter.side === 'a' ? 'b' : 'a'),
          'run',
        );
      } else {
        this._say('But it failed');
      }
    } else if (effect.vitamin) {
      if (!vitaminApplied) {
        this._say('But it failed');
      } else {
        const mon = vitaminMon;
        const result = vitaminResult;
        const label = ({
          hp: 'HEALTH POINTS', atk: 'ATTACK', def: 'DEFENSE',
          spd: 'SPEED', spc: 'SPECIAL',
        })[result.stat] || 'STAT';
        if (result.stat === 'hp' && result.delta > 0) {
          this._emit('drain', {
            slot: fighter.slot, side: fighter.side,
            amount: result.delta, hp: mon.hp,
          });
        } else if (result.delta > 0) {
          this._emit('stat', {
            slot: fighter.slot, side: fighter.side,
            amount: mon.stats[result.stat],
            text: `${mon.species}'s ${label} rose`,
          });
        }
        this._say(`${mon.species}'s ${label} rose`);
      }
    } else if (effect.pokeFlute) {
      let woke = false;
      for (const seat of this.fighters) {
        for (const mon of seat.mons || []) {
          if (mon && mon.status === 'sleep') {
            mon.status = null;
            mon.statusTurns = 0;
            woke = true;
            this._emit('status', {
              slot: seat.slot, side: seat.side,
              text: `${mon.species} woke up`,
            });
          }
        }
      }
      if (woke) this._say('All sleeping POKeMON woke up');
      else this._say("Now, that's a catchy tune");
    } else {
      const partyIdx = choice.slot != null ? choice.slot : fighter.active;
      const mon = monAt(fighter, partyIdx);
      if (!mon) {
        this._say('But it failed');
      } else if (effect.activeOnly && partyIdx !== fighter.active) {
        this._say('But it failed');
      } else if (effect.faintedOnly && mon.hp > 0) {
        this._say('But it failed');
      } else if (!effect.faintedOnly && mon.hp <= 0
                 && (effect.heal || effect.healFull || effect.clearStatuses
                     || effect.clearAllStatus || effect.ppRestore
                     || effect.ppRestoreAll)) {
        this._say('But it failed');
      } else {
        let applied = false;
        if (effect.xAccuracy) {
          mon.xAccuracy = true;
          this._say(`${mon.species}'s hits will never miss`);
          applied = true;
        }
        if (effect.focusEnergy) {
          mon.focusEnergy = true;
          this._say(`${mon.species} is getting pumped`);
          applied = true;
        }
        if (effect.mist) {
          mon.mist = true;
          this._say(`${mon.species} is protected against stat changes`);
          applied = true;
        }
        if (effect.stage) {
          const stat = effect.stage.stat;
          const before = Effects.clampStage(mon.stages[stat]);
          if (before >= Effects.STAGE_MAX) {
            this._say('Nothing happened');
          } else {
            const after = Effects.clampStage(before + int(effect.stage.delta, 1));
            mon.stages[stat] = after;
            const label = ({
              atk: 'ATTACK', def: 'DEFENSE', spd: 'SPEED',
              spc: 'SPECIAL', acc: 'ACCURACY', eva: 'EVASION',
            })[stat] || 'STAT';
            this._say(`${mon.species}'s ${label} rose`);
            this._emit('stat', {
              slot: fighter.slot, side: fighter.side,
              amount: after, text: `${mon.species}'s ${label} rose`,
            });
          }
          applied = true;
        }
        if (effect.revive) {
          const amount = effect.revive;
          const hp = amount === 1 ? mon.maxHp
            : Math.max(1, Math.floor(mon.maxHp * amount));
          mon.hp = hp;
          mon.status = null;
          mon.statusTurns = 0;
          this._emit('drain', {
            slot: fighter.slot, side: fighter.side,
            amount: hp, hp: mon.hp,
          });
          this._say(`${mon.species} was revived`);
          applied = true;
        }
        if (effect.ppRestore) {
          const move = mon.moves[choice.move - 1];
          if (!move) {
            this._say('But it failed');
          } else {
            const maxPp = Math.max(int(move.maxPp, move.pp), move.pp);
            const before = move.pp;
            if (effect.ppRestore === true) move.pp = maxPp;
            else move.pp = Math.min(maxPp, move.pp + int(effect.ppRestore, 0));
            if (move.pp > before) {
              this._say(`${mon.species}'s PP was restored`);
              applied = true;
            } else {
              this._say('But it failed');
            }
          }
        }
        if (effect.ppRestoreAll) {
          let any = false;
          for (const move of mon.moves || []) {
            if (!move) continue;
            const maxPp = Math.max(int(move.maxPp, move.pp), move.pp);
            const before = move.pp;
            if (effect.ppRestoreAll === true) move.pp = maxPp;
            else move.pp = Math.min(maxPp, move.pp + int(effect.ppRestoreAll, 0));
            if (move.pp > before) any = true;
          }
          if (any) {
            this._say(`${mon.species}'s PP was restored`);
            applied = true;
          } else {
            this._say('But it failed');
          }
        }
        let healed = false;
        if (effect.healFull) {
          const before = mon.hp;
          mon.hp = mon.maxHp;
          if (mon.hp > before) {
            this._emit('drain', {
              slot: fighter.slot, side: fighter.side,
              amount: mon.hp - before, hp: mon.hp,
            });
            healed = true;
          }
        } else if (effect.heal && effect.heal > 0 && mon.hp < mon.maxHp) {
          this._heal(fighter, mon, effect.heal);
          healed = true;
        }
        let cleared = false;
        if (effect.clearAllStatus && mon.status) {
          mon.status = null;
          mon.statusTurns = 0;
          cleared = true;
        } else if (effect.clearStatuses && mon.status
                   && effect.clearStatuses[mon.status]) {
          mon.status = null;
          mon.statusTurns = 0;
          cleared = true;
        }
        if (cleared) {
          this._emit('status', {
            slot: fighter.slot, side: fighter.side,
            text: `${mon.species} recovered`,
          });
        }
        if (!applied && !healed && !cleared) {
          this._say('But it failed');
        }
      }
    }
  }

  // Gen1 TossBallAnimation event stream (mirror BattleState:ballChain / tossAnimFor).
  // Clients pair AnimPlayer opts.ball from the preceding `item` event's text.
  _emitBallChain(fighter, ballId, caught, shakes) {
    const slot = fighter.slot;
    const side = fighter.side;
    const toss = ballId === 'POKE_BALL' ? 'TOSS_ANIM'
      : ballId === 'GREAT_BALL' ? 'GREATTOSS_ANIM'
      : 'ULTRATOSS_ANIM';
    const anim = (text, amount) => {
      const fields = { slot, side, text };
      if (amount !== undefined) fields.amount = amount;
      this._emit('anim', fields);
    };
    anim(toss);
    anim('POOF_ANIM');
    if (!caught && !(shakes > 0)) return;
    anim('HIDEPIC_ANIM');
    anim('SHAKE_ANIM', shakes || 0);
    if (!caught) {
      anim('POOF_ANIM');
      anim('SHOWPIC_ANIM');
    }
  }

  _resolveFights() {
    const actors = [];
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      const mon = activeMon(fighter);
      if (choice && choice.action === 'fight' && mon) {
        actors.push({
          fighter,
          mon, // pinned: see the skip in the loop
          speed: this._speedOf(fighter, mon),
          order: actors.length + 1,
        });
      }
    }
    if (actors.length === 0) return;

    this._sortActorsBySpeed(actors);

    for (const actor of actors) {
      if (this.result) break;
      // The monster that chose is the only one allowed to act: if it fainted to
      // a faster attacker, the replacement that came in behind it does not
      // inherit the turn.
      if (activeMon(actor.fighter) === actor.mon) {
        this._useMove(actor.fighter, actor.mon);
      }
      // Finalize after each action (not inside `_faint`) so KO + recoil / explode
      // on the same move can still mutual-faint into a draw, while an empty-bench
      // KO still stops the slower seat from acting. The action's faint batch is
      // complete here, and that is the earliest moment its spoils can be counted
      // without paying a monster the same action was still killing (`_drainExp`).
      this._drainExp();
      if (!this.result) this._checkOver();
    }
  }

  // Returns false when a gate stopped the move.
  _runGates(fighter, mon) {
    if (mon.flinch) {
      mon.flinch = false;
      this._say(`${mon.species} flinched`);
      return false;
    }

    if (has(GATING, mon.status)) {
      const gate = Status.beforeMove(
        { status: mon.status, turnsRemaining: mon.statusTurns }, this.rng.byte(),
      );
      if (gate) {
        mon.statusTurns = int(gate.turnsRemaining, mon.statusTurns);
        if (gate.wokeUp) {
          mon.status = null;
          mon.statusTurns = 0;
          this._emit('status', {
            slot: fighter.slot, side: fighter.side,
            text: `${mon.species} woke up`,
          });
        } else if (gate.fullyParalyzed) {
          this._say(`${mon.species} is fully paralyzed`);
        } else if (mon.status === 'sleep') {
          this._say(`${mon.species} is fast asleep`);
        } else if (mon.status === 'freeze') {
          this._say(`${mon.species} is frozen solid`);
        }
        if (!gate.canMove) return false;
      }
    }

    if (mon.confusion > 0) {
      const gate = Status.beforeMove({
        status: 'confusion',
        turnsRemaining: mon.confusion,
        level: mon.level, attack: mon.stats.atk, defense: mon.stats.def,
      }, this.rng.byte());
      if (gate) {
        mon.confusion = int(gate.turnsRemaining, 0);
        if (gate.snappedOut) {
          this._say(`${mon.species} snapped out of confusion`);
        } else if (gate.selfHit) {
          this._say(`${mon.species} hurt itself in confusion`);
          this._damage(fighter, mon, gate.selfDamage || 0, null);
          return false;
        }
        if (!gate.canMove) return false;
      }
    }

    return true;
  }

  _applyPrimary(fighter, mon, targetFighter, targetMon, moveIndex, effectId) {
    const result = Effects.applyPrimary({
      effectId,
      rng: this.rng,
      userMon: mon,
      targetMon,
      userFighter: fighter,
      targetFighter,
      moveIndex,
      statusToWire: STATUS_TO_WIRE,
    });
    if (result.nothing) this._say('But nothing happened');
    for (const text of result.messages || []) this._say(text);
    for (const entry of result.events || []) {
      this._emit(entry.kind, entry.fields);
    }
    for (const heal of result.heals || []) {
      this._heal(fighter, mon, heal.amount);
    }
    for (const cost of result.costs || []) {
      this._damage(fighter, mon, cost.amount, null);
    }
    for (const hit of result.directDamage || []) {
      this._emit('damage', {
        slot: fighter.slot,
        side: fighter.side,
        amount: hit.amount,
        hp: mon.hp,
      });
    }
    if (result.movesChanged) this._emitMoves(fighter, mon);
  }

  _applySide(fighter, mon, targetFighter, targetMon, effectId, chance) {
    const result = Effects.applySide({
      effectId,
      chance,
      rng: this.rng,
      userMon: mon,
      targetMon,
      userFighter: fighter,
      targetFighter,
      statusToWire: STATUS_TO_WIRE,
    });
    for (const text of result.messages || []) this._say(text);
    for (const entry of result.events || []) {
      this._emit(entry.kind, entry.fields);
    }
  }

  _markLastMove(mon, moveIndex) {
    if (moveIndex && moveIndex >= 1) mon.lastMoveIndex = moveIndex;
  }

  _faintUser(fighter, mon) {
    if (mon.hp > 0) this._damage(fighter, mon, mon.hp, null);
  }

  _concedeRun(fighter) {
    this._emit('run', { slot: fighter.slot, side: fighter.side, text: fighter.name });
    if (fighter.side === 'a') {
      this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'run');
    } else {
      this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'run');
    }
  }

  _useMove(fighter, mon, opts = {}) {
    const choice = fighter.choice;
    if (!mon.moves[choice.move - 1]) return;

    if (!this._runGates(fighter, mon)) return;

    const struggling = allPpEmpty(mon) || choice.struggle;
    if (!struggling && mon.disable && mon.disable.turns > 0
        && mon.disable.moveIndex === choice.move) {
      const blocked = mon.moves[choice.move - 1];
      const moveId = blocked && blocked.id ? blocked.id : 'move';
      this._say(`${moveId} is disabled`);
      return;
    }

    // Resolved once, here, and used for the whole action: see `_retarget`.
    const target = this._retarget(fighter, choice.target);
    const defender = target && activeMon(target);
    if (!defender) {
      this._say(`${mon.species} has no target`);
      return;
    }
    // The seat actually swung at.  Anything this action *records* for a later
    // turn (a charge's aim, a Bide's aim) records this and not `choice.target`,
    // so the release lands where the action went rather than on the seat that
    // was already empty when it started.
    const targetSlot = target.slot;

    const move = opts.moveOverride || (struggling ? STRUGGLE : mon.moves[choice.move - 1]);
    const effectId = int(move.effect, 0);
    const releasing = mon.charging !== null && mon.charging !== undefined
      && Effects.isCharge(mon.charging.effect);
    const mirrorCopy = opts.mirrorCopy === true;

    if (!struggling && move.pp > 0 && !releasing && !choice.bideRelease) move.pp -= 1;
    this._emit('anim', { slot: fighter.slot, side: fighter.side, text: move.id });
    this._say(`${mon.species} used ${move.id}`);

    if (choice.bideRelease && mon.bide) {
      const stored = mon.bide.stored;
      mon.bide = null;
      if (stored <= 0) {
        this._say('But it failed');
        this._markLastMove(mon, choice.move);
        return;
      }
      this._damage(target, defender, 2 * stored, null);
      this._markLastMove(mon, choice.move);
      return;
    }

    // Charge / Fly: first turn sets state and ends; second turn releases.
    if (Effects.isCharge(effectId) && !mon.charging) {
      mon.charging = {
        moveIndex: choice.move,
        effect: effectId,
        targetSlot,
      };
      if (Effects.isFly(effectId)) mon.invulnerable = true;
      this._say(Effects.chargeMessage(mon, effectId));
      this._markLastMove(mon, choice.move);
      return;
    }

    if (mon.charging && Effects.isCharge(mon.charging.effect)) {
      mon.charging = null;
      mon.invulnerable = false;
    }

    if (defender.invulnerable) {
      this._say('But it failed');
      if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
      if (Effects.isJumpKick(effectId)) {
        this._damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), null);
      }
      this._markLastMove(mon, choice.move);
      return;
    }

    if (Effects.isMirrorMove(effectId) && !mirrorCopy) {
      const lastIdx = int(defender.lastMoveIndex, 0);
      if (lastIdx < 1 || !defender.moves[lastIdx - 1]) {
        this._say('But it failed');
        this._markLastMove(mon, choice.move);
        return;
      }
      this._markLastMove(mon, choice.move);
      this._useMove(fighter, mon, {
        moveOverride: copyMove(defender.moves[lastIdx - 1]),
        mirrorCopy: true,
      });
      return;
    }

    const metronomeCall = opts.metronomeCall === true;
    if (Effects.isMetronome(effectId) && !metronomeCall) {
      const pool = this.metronomePool;
      if (!pool || pool.length === 0) {
        this._say('But nothing happened');
        this._markLastMove(mon, choice.move);
        return;
      }
      const pick = this.rng.byte() % pool.length;
      this._markLastMove(mon, choice.move);
      this._useMove(fighter, mon, {
        moveOverride: copyMove(pool[pick]),
        metronomeCall: true,
      });
      return;
    }

    const alwaysHits = effectId === Effects.idOf('SWIFT_EFFECT')
      || mon.xAccuracy === true;

    const shot = Accuracy.hit({
      accuracy: move.accuracy,
      accuracyMod: Effects.stageMult(mon.stages.acc),
      evasionMod: Effects.stageMult(defender.stages.eva),
      roll: this.rng.byte(),
      alwaysHits,
    });
    if (!shot.hit) {
      this._say(`${mon.species} missed`);
      if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
      if (Effects.isJumpKick(effectId)) {
        this._damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), null);
      }
      this._markLastMove(mon, choice.move);
      return;
    }

    const isFixed = Effects.isFixedDamage(effectId);
    if (effectId === 8 && defender.status !== 'sleep') {
      this._say('But it failed');
      if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
      this._markLastMove(mon, choice.move);
      return;
    }

    if (move.power <= 0 && !isFixed) {
      if (Effects.isBide(effectId) && !mon.bide) {
        mon.bide = {
          turns: Effects.bideTurns(this.rng),
          stored: 0,
          moveIndex: choice.move,
          targetSlot,
        };
        this._say(`${mon.species} began storing energy`);
        this._markLastMove(mon, choice.move);
        return;
      }
      if (Effects.isSwitchAndTeleport(effectId)) {
        if (Effects.teleportRunAllowed(this.mode)) {
          this._concedeRun(fighter);
        } else {
          this._say('But it failed');
        }
        this._markLastMove(mon, choice.move);
        return;
      }
      if (Effects.isNoOp(effectId)) {
        this._say('But nothing happened');
        this._markLastMove(mon, choice.move);
        return;
      }
      if (Effects.handlesPrimary(effectId)) {
        this._applyPrimary(fighter, mon, target, defender, choice.move, effectId);
      } else {
        this._say('But nothing happened');
      }
      this._markLastMove(mon, choice.move);
      return;
    }

    if (effectId === 38) {
      if (this._speedOf(fighter, mon) <= this._speedOf(target, defender)) {
        this._say('But it failed');
        if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
        this._markLastMove(mon, choice.move);
        return;
      }
    }

    const hits = Effects.hitCount(effectId, this.rng);
    const critSpd = Effects.badgeBoost(mon.stats.spd, 'spd', fighter.badges);
    const isCrit = Crit.check({
      baseSpeed: critSpd,
      roll: this.rng.byte(),
      focusEnergy: mon.focusEnergy,
    }).isCrit;
    const percents = this._typePercents(move.type, defender);

    let immune = false;
    for (const pct of percents) {
      if (pct <= 0) { immune = true; break; }
    }

    let damage = 0;
    if (isFixed) {
      if (immune) {
        this.rng.damageRoll();
        this._say(`It doesn't affect ${defender.species}`);
        if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
        if (Effects.isJumpKick(effectId)) {
          this._damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), null);
        }
        this._markLastMove(mon, choice.move);
        return;
      }
      const fixed = Effects.fixedDamage({
        effectId,
        userMon: mon,
        targetMon: defender,
        power: move.power,
        userSpeed: this._speedOf(fighter, mon),
        foeSpeed: this._speedOf(target, defender),
      });
      if (fixed === null) {
        this.rng.damageRoll();
        this._say('But it failed');
        if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
        this._markLastMove(mon, choice.move);
        return;
      }
      this.rng.damageRoll();
      damage = fixed;
    } else {
      const isSpecial = Effects.isSpecialType(move.type, this.specialTypes);
      const atkKey = isSpecial ? 'spc' : 'atk';
      const defKey = isSpecial ? 'spc' : 'def';
      const atkStat = Effects.badgeBoost(
        isSpecial ? mon.stats.spc : mon.stats.atk, atkKey, fighter.badges);
      const atkStage = isSpecial ? mon.stages.spc : mon.stages.atk;
      const defStat = Effects.badgeBoost(
        isSpecial ? defender.stats.spc : defender.stats.def, defKey, target.badges);
      const defStage = isSpecial ? defender.stages.spc : defender.stages.def;

      let attack = Effects.applyStage(atkStat, atkStage);
      if (!isSpecial && mon.status === 'burn') attack = Status.burnAttack(attack);

      let defense = Effects.applyStage(defStat, defStage);
      if (Effects.isExplode(effectId)) {
        defense = Math.max(1, Math.floor(defense / 2));
      }

      const roll = this.rng.damageRoll();
      const result = Damage.compute({
        level: mon.level,
        attack,
        defense,
        power: move.power,
        crit: isCrit,
        stab: hasType(mon, move.type),
        typeEffect: percents,
        roll,
      });

      if (result.immune) {
        this._say(`It doesn't affect ${defender.species}`);
        if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
        if (Effects.isJumpKick(effectId)) {
          this._damage(fighter, mon, Effects.jumpKickCrash(mon.maxHp), null);
        }
        this._markLastMove(mon, choice.move);
        return;
      }
      damage = result.damage === null || result.damage === undefined
        ? 0 : result.damage;
    }

    const isSpecial = Effects.isSpecialType(move.type, this.specialTypes);
    damage = Effects.screenDamage(damage, defender, isSpecial);

    let effectiveness = 1;
    for (const pct of percents) effectiveness = (effectiveness * pct) / 100;
    if (isCrit && !isFixed) this._say('A critical hit');
    if (effectiveness > 1) {
      this._say("It's super effective");
    } else if (effectiveness < 1) {
      this._say("It's not very effective");
    }

    let totalDealt = 0;
    for (let h = 0; h < hits; h += 1) {
      if (defender.hp <= 0) break;
      const hpBefore = defender.hp;
      this._damage(target, defender, damage, null);
      totalDealt += hpBefore - defender.hp;
    }

    if (totalDealt > 0) {
      this._applySide(fighter, mon, target, defender, effectId, move.chance);

      if (Effects.isDrain(effectId)) {
        const heal = Effects.drainAmount(totalDealt);
        if (heal > 0) this._heal(fighter, mon, heal);
      }

      if (Effects.isPayDay(effectId)) {
        this._say('Coins scattered');
      }
    }

    if ((struggling || Effects.isRecoil(effectId)) && totalDealt >= 1) {
      const recoil = Effects.recoilAmount(totalDealt);
      this._say(`${mon.species} is hit with recoil`);
      this._damage(fighter, mon, recoil, null);
    }

    if (Effects.handlesPrimary(effectId)) {
      this._applyPrimary(fighter, mon, target, defender, choice.move, effectId);
    }

    if (Effects.isThrash(effectId) && !mon.thrashing) {
      mon.thrashing = {
        turns: Effects.thrashTurns(this.rng),
        moveIndex: choice.move,
      };
    }

    if (Effects.isRage(effectId)) {
      mon.raging = true;
      mon.rageMove = choice.move;
    }

    if (Effects.isTrapping(effectId) && totalDealt > 0) {
      const turns = Effects.trapTurns(this.rng);
      defender.trapped = {
        turns,
        damage: totalDealt,
        fromSlot: fighter.slot,
      };
      mon.trapping = {
        turns,
        moveIndex: choice.move,
        targetSlot: target.slot,
      };
    }

    if (Effects.isHyperBeam(effectId) && totalDealt > 0 && defender.hp > 0) {
      mon.mustRecharge = true;
    }

    if (Effects.isExplode(effectId)) {
      this._faintUser(fighter, mon);
    }

    this._markLastMove(mon, choice.move);

    if (mon.thrashing) {
      mon.thrashing.turns -= 1;
      if (mon.thrashing.turns <= 0) {
        mon.thrashing = null;
        const turns = this.rng.byte() % 4 + 2;
        mon.confusion = turns;
        this._say(`${mon.species} became confused`);
      }
    }
  }

  // One place where HP comes off, so the faint that follows can never be
  // forgotten at one of the call sites.
  _damage(fighter, mon, rawAmount, status) {
    let amount = Math.max(0, int(rawAmount, 0));

    if (amount > 0 && mon.bide && mon.bide.turns > 0) {
      mon.bide.stored += amount;
    }

    if (amount > 0 && mon.substitute && mon.substitute > 0) {
      if (amount >= mon.substitute) {
        mon.substitute = 0;
        this._say(`${mon.species}'s substitute broke`);
      } else {
        mon.substitute -= amount;
      }
      this._emit('damage', {
        slot: fighter.slot,
        side: fighter.side,
        amount,
        hp: mon.hp,
        status: status && has(STATUS_TO_WIRE, status) ? STATUS_TO_WIRE[status] : undefined,
      });
      return;
    }

    if (amount > mon.hp) amount = mon.hp;

    if (amount > 0 && mon.raging) {
      const before = Effects.clampStage(mon.stages.atk);
      const after = Effects.clampStage(before + 1);
      if (after !== before) {
        mon.stages.atk = after;
        this._say(`${mon.species}'s ATTACK rose`);
        this._emit('stat', {
          slot: fighter.slot, side: fighter.side,
          amount: after, text: `${mon.species}'s ATTACK rose`,
        });
      }
    }

    mon.hp -= amount;

    this._emit('damage', {
      slot: fighter.slot,
      side: fighter.side,
      amount,
      hp: mon.hp,
      status: status && has(STATUS_TO_WIRE, status) ? STATUS_TO_WIRE[status] : undefined,
    });

    if (mon.hp <= 0) this._faint(fighter, mon);
  }

  _heal(fighter, mon, amount) {
    let gained = Math.max(0, int(amount, 0));
    if (gained <= 0) return;
    const before = mon.hp;
    mon.hp = Math.min(mon.maxHp, mon.hp + gained);
    gained = mon.hp - before;
    if (gained <= 0) return;
    this._emit('drain', {
      slot: fighter.slot,
      side: fighter.side,
      amount: gained,
      hp: mon.hp,
    });
  }

  /**
   * This seat's monster just changed (battle start, switch, replacement).
   *
   * Its own set resets, then the currently standing opposition marks into it --
   * and the incoming monster marks into each of THEIR sets, which is the other
   * direction of BattleState.lua:2424: a switch-in joins the standing foe's
   * participants. A foe mid-replacement (nothing out) is neither read nor
   * written, the same way the engine has no enemy to mark against.
   */
  _refield(fighter) {
    fighter.fought = Object.create(null);
    const mine = activeMon(fighter) ? fighter.active : null;
    const foes = this.bySide[fighter.side === 'a' ? 'b' : 'a'];
    for (const foe of foes) {
      if (activeMon(foe)) {
        fighter.fought[foughtKey(foe.slot, foe.active)] = true;
        if (mine !== null) {
          if (!foe.fought) foe.fought = Object.create(null);
          foe.fought[foughtKey(fighter.slot, mine)] = true;
        }
      }
    }

    // ...and the mark the deferred send-out still owes (`_faint` explains why it
    // is held rather than taken here): whoever was standing when the monster
    // this one replaces went down was in against this one too, which is :3980
    // read for a seat that is asked for its replacement instead of just sending
    // it. Only this direction is owed -- the seat opposite re-derives its own
    // set the next time it refields, exactly as the engine keeps flags on one
    // side only. Consumed once: a seat that refields again later starts clean.
    const pending = fighter.pendingFought;
    fighter.pendingFought = null;
    if (pending) {
      for (const key of pending) fighter.fought[key] = true;
    }
  }

  /**
   * Who is standing opposite this seat right now, as participation keys, in
   * field order. A list rather than a set because it is walked: two runtimes
   * agreeing about a set they only ever ask is cheap, agreeing about one they
   * iterate is not.
   */
  _standingOpposition(fighter) {
    const keys = [];
    const foes = this.bySide[fighter.side === 'a' ? 'b' : 'a'];
    for (const foe of foes) {
      if (activeMon(foe)) keys.push(foughtKey(foe.slot, foe.active));
    }
    return keys;
  }

  /**
   * RemoveFaintedPlayerMon: a monster that faints stops being a participant
   * anywhere, so it neither collects nor counts.
   */
  _unfield(fighter, index) {
    const key = foughtKey(fighter.slot, index);
    for (const other of this.fighters) {
      if (other.fought) delete other.fought[key];
      // The held mark is reached too. A monster that fell while the seat
      // opposite was still choosing its replacement was never in against that
      // replacement, so it must not be sitting in the set the successor
      // inherits -- the same rule, one send-out earlier.
      const pending = other.pendingFought;
      if (pending) {
        for (let i = pending.length - 1; i >= 0; i -= 1) {
          if (pending[i] === key) pending.splice(i, 1);
        }
      }
    }
  }

  /**
   * What a faint pays, and to whom.
   *
   * **Facts, never an amount.** This referee holds no species table -- it never
   * has and, by the legal floor this whole server is built under, never will --
   * so it cannot compute a single point of experience. What it *can* do is
   * state the three things the formula needs and nothing else knows: which
   * monster fell, what level it was, and how many shares split it. Each client
   * then runs its own Experience over its own party, which is also the only
   * place the result can persist. Same shape as the vitamin writeback and the
   * catch grant: the authority announces, the owner applies.
   *
   * The mode gate is not a shortcut for the owner check, it is the rule. A
   * seated fighter here carries a playerId whether a connection is behind it or
   * a synthetic wild / trainer seat is, so "does this seat have an owner" is
   * not a question the turn machine can ask -- but the *mode* answers it,
   * because the hub only ever seats a synthetic opponent in these three, and
   * always on side b (`maxFighters` says the same thing about coop_wild's 2v1).
   * 1v1 and coop_pvp are left out deliberately rather than incidentally: paying
   * a player for beating another player is a farming loop, and it is not what
   * vanilla does with a link battle either.
   *
   * One event per PAID monster, in seat order and then party order -- the Lua
   * twin emits the same list in the same order, and a stream that differs by a
   * permutation is a parity failure with no symptom anyone could read. `bySide`
   * is built in roster index order and `fieldSlot` is monotonic in that index,
   * so the outer walk is a walk of slots; the inner one is the party array,
   * which is the order the engine's own party walk uses
   * (src/battle/BattleState.lua:3796).
   *
   * `slot` stays the owning FIGHTER's field slot -- that is the ownership gate,
   * and it is what a client checks before writing to its own save. `mon` says
   * which of that party banks the share, 0-based, because a benched participant
   * has no field slot to be named by.
   *
   * The divisor is the engine's: `participants` counts every member of the set,
   * `alive` is the subset still above zero HP, and only `alive` is paid
   * (BattleState.lua:3795-3801). The two agree in practice because a faint
   * already left the set (`_unfield`) -- mirrored rather than collapsed so the
   * shape stays comparable. The empty-set fallback is :3802-3804: with nothing
   * flagged, whoever is out gets it, which is also exactly what round 5 paid.
   *
   * No roll is drawn in here: the parity digest's rngState must not move
   * because a faint paid out.
   */
  _awardExp(fallen, mon) {
    if (!has(EXP_MODES, this.mode)) return;
    if (fallen.side === EXP_OWNER_SIDE) return;

    const fought = fallen.fought || Object.create(null);
    let participants = 0;
    const alive = [];
    for (const fighter of this.bySide[EXP_OWNER_SIDE]) {
      for (let index = 1; index <= fighter.mons.length; index += 1) {
        if (fought[foughtKey(fighter.slot, index)]) {
          participants += 1;
          if (fighter.mons[index - 1].hp > 0) alive.push({ fighter, index });
        }
      }
    }

    if (participants === 0) {
      for (const fighter of this.bySide[EXP_OWNER_SIDE]) {
        if (activeMon(fighter)) {
          participants += 1;
          alive.push({ fighter, index: fighter.active });
        }
      }
    }
    if (alive.length === 0) return;

    for (const winner of alive) {
      this._emit('exp', {
        slot: winner.fighter.slot,
        species: mon.species,
        level: mon.level,
        participants,
        mon: winner.index - 1,
      });
    }
  }

  /**
   * Pay for everything the action just felled, in the order it fell.
   *
   * Split from `_faint` because the engine splits it: `onFaint` knocks a
   * monster *down* and clears its flag (BattleState.lua:3721-3723), and the
   * payout is queued behind that in `enemyMonFainted` -- so by the time anybody
   * is counted, every monster the action killed has already left the set.
   * Paying inside `_faint` instead put a self-KO'er in its own victim's payout:
   * an Explosion or a recoil that kills its user runs `_faintUser` *after* the
   * target's faint, so the user was still standing, still flagged, and still in
   * the divisor. CoopSim's `reapFaints` drops the whole batch before announcing
   * any of it for exactly this reason; this is that same batch, at the boundary
   * the turn machine already had.
   *
   * Draws nothing: the parity digest's rngState must not move because a faint
   * paid out, whenever it pays.
   */
  _drainExp() {
    const queue = this.pendingExp;
    if (queue.length === 0) return;
    this.pendingExp = [];
    for (const owed of queue) this._awardExp(owed.fallen, owed.mon);
  }

  _faint(fighter, mon) {
    // RemoveFaintedPlayerMon first (BattleState.lua:3721-3723 runs at the top
    // of onFaint): this one is out of every participation set before anything
    // below can pay anybody, so a mon that died on the way to the KO is not in
    // the divisor. Keyed off the seat's own party position rather than
    // `active`, which the recoil path has not cleared yet.
    for (let index = 1; index <= fighter.mons.length; index += 1) {
      if (fighter.mons[index - 1] === mon) { this._unfield(fighter, index); break; }
    }
    mon.charging = null;
    mon.invulnerable = false;
    mon.mustRecharge = false;
    mon.thrashing = null;
    mon.raging = false;
    mon.rageMove = 0;
    mon.trapped = null;
    mon.trapping = null;
    mon.bide = null;
    mon.substitute = 0;
    mon.lightScreen = false;
    mon.reflect = false;
    mon.mist = false;
    mon.focusEnergy = false;
    mon.transformed = false;
    mon.xAccuracy = false;
    mon.leechSeed = null;
    mon.disable = null;
    this._clearTrapsFrom(fighter.slot);

    // Living bench? Computed before clearing active; fainted mon already has hp 0.
    const next = firstLiving(fighter.mons);
    const faintEv = { slot: fighter.slot, side: fighter.side, text: mon.species };
    // amount=1 is the authoritative mustReplace signal (living bench). Clients
    // open the replace picker from this rather than guessing from local HP.
    if (next) faintEv.amount = 1;
    this._emit('faint', faintEv);

    // Owed here, paid at the end of the action (`_drainExp`), with the fallen
    // sheet held in the queue so the payout still names the monster that fell
    // and the level it was. For an ordinary KO nothing moves: the faint, then
    // its spoils, and only then anything about what comes next -- the order
    // CoopSim announces in. What changes is the action that fells two: every
    // one of them is out of the sets before the first share is counted.
    this.pendingExp.push({ fallen: fighter, mon });

    fighter.active = null;
    if (next) {
      // Ask the seat for a switch on the next choice window; timeout / autoPick
      // still lands firstLiving (preferring an SE bench).
      fighter.mustReplace = true;
      // The successor's mark, taken now because the send-out is not now.
      //
      // Vanilla marks whoever is standing at the enemy's send-out
      // (BattleState.lua:3980), and the engine sends out inside the faint
      // itself, while the monster that landed the KO is still on the field --
      // which is also where CoopSim does it (`announceFaint` calls `sendOut`
      // for an NPC inside `reapFaints`). This referee cannot: it asks the seat,
      // and the answer arrives on the next choice window, by which time side
      // a's own switches have already resolved (`_resolveSwitches` walks side a
      // first). A player who swaps on that turn would hand the incoming foe a
      // set that never heard of the monster that beat the last one. So the
      // send-out's mark is taken here, against the field the faint actually
      // happened on, and held until `_refield` puts the successor out.
      fighter.pendingFought = this._standingOpposition(fighter);
    } else {
      fighter.mustReplace = null;
      fighter.pendingFought = null;
    }

    // While resolving, defer `_checkOver` to the caller (after the current move /
    // residual batch) so the same action can still faint the user (recoil,
    // explode) and land a draw. Outside resolve, end immediately -- and pay
    // first, because there is no action boundary out here to pay at.
    if (this.phase !== 'resolving') {
      this._drainExp();
      this._checkOver();
    }
  }

  _resolveResiduals() {
    for (const fighter of this.fighters) {
      if (this.result) return;
      let mon = activeMon(fighter);
      if (mon && mon.status) {
        const amount = Status.residual({
          status: mon.status, maxHp: mon.maxHp, toxicCounter: mon.toxicCounter,
        });
        if (amount !== null && amount !== undefined) {
          if (mon.status === 'toxic') mon.toxicCounter += 1;
          this._say(`${mon.species} is hurt by its ${mon.status}`);
          this._damage(fighter, mon, amount, mon.status);
        }
      }
      if (this.result) return;
      mon = activeMon(fighter);
      if (mon && mon.trapped && mon.trapped.turns > 0) {
        const trap = mon.trapped;
        this._say(`${mon.species} is hurt by the trap`);
        this._damage(fighter, mon, trap.damage, null);
        trap.turns -= 1;
        if (trap.turns <= 0) {
          mon.trapped = null;
          const trapper = trap.fromSlot !== null && trap.fromSlot !== undefined
            ? this._fighterAtSlot(trap.fromSlot) : null;
          const tMon = trapper && activeMon(trapper);
          if (tMon) tMon.trapping = null;
        } else {
          const trapper = trap.fromSlot !== null && trap.fromSlot !== undefined
            ? this._fighterAtSlot(trap.fromSlot) : null;
          const tMon = trapper && activeMon(trapper);
          if (tMon && tMon.trapping) tMon.trapping.turns = trap.turns;
        }
      }
      mon = activeMon(fighter);
      if (mon && mon.bide && mon.bide.turns > 0) {
        mon.bide.turns -= 1;
      }
      if (this.result) return;
      mon = activeMon(fighter);
      if (mon && mon.leechSeed) {
        const amount = Math.max(1, Math.floor(mon.maxHp / 16));
        this._say(`${mon.species} is seeded`);
        this._damage(fighter, mon, amount, null);
        const from = mon.leechSeed.fromSlot;
        const seeder = from !== null && from !== undefined
          ? this._fighterAtSlot(from) : null;
        const sMon = seeder && activeMon(seeder);
        if (sMon && sMon.hp > 0) this._heal(seeder, sMon, amount);
      }
      if (this.result) return;
      mon = activeMon(fighter);
      if (mon && mon.disable && mon.disable.turns > 0) {
        mon.disable.turns -= 1;
        if (mon.disable.turns <= 0) {
          const idx = mon.disable.moveIndex;
          const cleared = mon.moves[idx - 1];
          mon.disable = null;
          if (cleared && cleared.id) {
            this._say(`${cleared.id} is no longer disabled`);
          }
        }
      }
    }
  }

  // ----------------------------------------------------------------
  // endings
  // ----------------------------------------------------------------

  _checkOver() {
    if (this.result) return true;
    const aliveA = this._sideAlive('a');
    const aliveB = this._sideAlive('b');
    if (aliveA && aliveB) return false;

    if (!aliveA && !aliveB) {
      this._finish('draw', null, null, 'ko');
    } else if (aliveA) {
      this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'ko');
    } else {
      this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'ko');
    }
    return true;
  }

  /*
   * `outcome` is stated from the *field's* point of view, not a recipient's:
   * "win" means the winners list won. The per-client rendering -- the "loss"
   * the loser's screen shows -- belongs to the session layer that addresses the
   * message, because it is the only party that knows who it is talking to.
   *
   * A draw carries no lists at all rather than two empty ones, because
   * Wire.battleOutcome refuses an empty id list: the absence is the statement.
   */
  _finish(outcome, winners, losers, reason) {
    if (this.result) return this.result;

    const result = { battle: this.id, outcome, reason };
    if (winners) result.winners = winners;
    if (losers) result.losers = losers;

    this.result = result;
    this.phase = 'over';
    this.deadline = null;
    this.resolveDeadline = null;
    this._emit('over', { text: reason });
    return this.result;
  }

  // null until the fight is done, so `if (battle.outcome())` is the whole test.
  outcome() {
    return this.result;
  }

  // ----------------------------------------------------------------
  // the clock
  // ----------------------------------------------------------------

  disconnect(playerId) {
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter || !fighter.connected) return false;
    if (this.result) return false;

    fighter.connected = false;
    fighter.graceEndsAt = this.now + this.reconnectGrace;
    this._emit('wait', { side: fighter.side, text: fighter.name });
    return true;
  }

  // Back inside the window continues the fight from where it paused, and the
  // choice deadline restarts rather than resuming: the player who reconnects
  // with two seconds left on a clock they could not see would be choosing under
  // a timer the drop created.
  reconnect(playerId) {
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter || fighter.connected) return false;
    if (this.result) return false;
    if (fighter.graceEndsAt !== null && this.now >= fighter.graceEndsAt) return false;

    fighter.connected = true;
    fighter.graceEndsAt = null;
    this._emit('reconnect', { side: fighter.side, text: fighter.name });

    if ((this.phase === 'choice' || this.phase === 'replace')
        && !this._anyDisconnected() && this.choiceTimeout > 0) {
      this.deadline = this.now + this.choiceTimeout;
    }
    return true;
  }

  /*
   * Advances the wall clock and fires whatever it has passed. Returns true when
   * something actually happened, so a hub can skip a drain on a quiet tick.
   *
   * Time only moves forward: a caller handing back an earlier `now` -- two
   * sources of time on a hub, a clock that stepped -- must not un-expire a
   * grace period that already ran.
   */
  tick(nowSeconds) {
    const now = int(nowSeconds, this.now);
    if (now > this.now) this.now = now;
    if (this.result) return false;

    // Forced-only turns opened by the previous resolve wait here so one drain
    // does not swallow a whole trap / recharge / thrash chain.
    if (this.forcedPending && this.phase === 'choice') {
      this.forcedPending = false;
      if (!this._anyoneOwes()) {
        this._maybeResolve();
        return true;
      }
    }

    let expiredA = false;
    let expiredB = false;
    for (const fighter of this.fighters) {
      if (!fighter.connected && fighter.graceEndsAt !== null
          && this.now >= fighter.graceEndsAt) {
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

    // A turn left in `resolving` -- typically after a throw the hub contained --
    // has no player to wait on, so the ceiling is the only way out. `timeout` is
    // the existing reason: sanitize already phrases it, and a stuck resolve is not
    // something a screen can usefully distinguish from an unanswered turn.
    if (this.phase === 'resolving' && this.resolveDeadline !== null
        && this.now >= this.resolveDeadline) {
      this._finish('draw', null, null, 'timeout');
      return true;
    }

    // The choice clock is suspended while anybody is away; the grace above is
    // the only deadline running for them.
    //
    // The replace phase runs on the same clock, and has to: a seat that owes a
    // send-out and never answers would otherwise hold the field forever, with
    // no turn open for the deadline that used to cover it. `_autoChoice`
    // already answers a `mustReplace` seat with a bench switch (it is the
    // branch the NPC side takes), so the same sweep that fills an unanswered
    // move fills an unanswered replacement, `_maybeResolve` closes the phase,
    // and the fight carries on one monster down rather than wedging.
    if ((this.phase === 'choice' || this.phase === 'replace')
        && this.deadline !== null && this.now >= this.deadline
        && !this._anyDisconnected()) {
      for (const fighter of this.fighters) {
        if (this._owes(fighter)) {
          const auto = this._autoChoice(fighter);
          if (auto) {
            fighter.choice = auto;
            this._emit('chose', {
              slot: fighter.slot, side: fighter.side, text: fighter.name,
            });
            this._say(`${fighter.name} ran out of time`);
          }
        }
      }
      this._maybeResolve();
      // A fighter with nothing left to auto-pick would leave the turn open on a
      // deadline already in the past, and every later tick would announce the
      // timeout again. Push the clock instead: the fight waits one more window
      // rather than filling the log.
      if ((this.phase === 'choice' || this.phase === 'replace')
          && this.deadline !== null && this.now >= this.deadline) {
        this.deadline = this.now + this.choiceTimeout;
      }
      return true;
    }

    return false;
  }

  // ----------------------------------------------------------------
  // snapshot
  // ----------------------------------------------------------------
  //
  // For tests and for a log line, not for a client: a client is sent events.
  // Everything here is a copy, so a caller poking at it cannot reach into the
  // field.
  snapshot() {
    const field = [];
    const waiting = [];

    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);

      field.push({
        slot: fighter.slot,
        side: fighter.side,
        playerId: fighter.playerId,
        name: fighter.name,
        connected: fighter.connected,
        graceEndsAt: fighter.graceEndsAt,
        chose: fighter.choice ? fighter.choice.action : null,
        mustReplace: fighter.mustReplace === true,
        species: mon ? mon.species : null,
        hp: mon ? mon.hp : 0,
        maxHp: mon ? mon.maxHp : 0,
        status: mon && mon.status && has(STATUS_TO_WIRE, mon.status)
          ? STATUS_TO_WIRE[mon.status] : null,
        party: fighter.mons.map((entry) => entry.hp),
      });
      if (this._owes(fighter)) waiting.push(fighter.playerId);
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
      over: this.result !== null,
      reason: this.result ? this.result.reason : null,
      rngState: this.rng.state(),
      field,
      waiting,
    };
  }
}

// ------------------------------------------------------------------
// construction
// ------------------------------------------------------------------

/*
 * attempt(opts) -> { battle, reason }
 *
 * opts:
 *   id, mode, seed, chart, choiceTimeout, reconnectGrace, resolveTimeout, now
 *   sides = { a: [ { playerId, name, mons } ], b: [ ... ] }
 *
 * A reason and not a throw: the caller is a session handler that has a client
 * waiting to be told why. `create` is the same thing for a caller that only
 * wants the battle.
 */
function attempt(opts) {
  const refuse = (reason) => ({ battle: null, reason });

  if (!isTable(opts)) return refuse('battle needs an options table');

  const self = new Battle(opts);

  const sides = isTable(opts.sides) ? opts.sides : {};
  for (const side of SIDES) {
    const roster = Array.isArray(sides[side]) ? sides[side] : [];
    if (roster.length === 0) return refuse(`side ${side} has nobody on it`);
    const sideMax = maxFighters(self.mode, side);
    if (roster.length > sideMax) {
      return refuse(`side ${side} has more fighters than ${self.mode} allows`);
    }
    for (let index = 1; index <= roster.length; index += 1) {
      const entry = roster[index - 1];
      if (!isTable(entry)) return refuse(`side ${side} has a malformed fighter`);

      const playerId = str(entry.playerId);
      if (!playerId) return refuse(`a fighter on side ${side} has no playerId`);
      if (self.byId.has(playerId)) return refuse(`duplicate playerId ${playerId}`);

      const mons = [];
      if (Array.isArray(entry.mons)) {
        for (const raw of entry.mons) {
          if (mons.length >= MONS_PER_PARTY) break;
          const mon = copyMon(raw, mons.length);
          if (mon) mons.push(mon);
        }
      }
      if (mons.length === 0) return refuse(`${playerId} brought no monsters`);

      const fighter = {
        playerId,
        name: str(entry.name) || playerId,
        side,
        index,
        slot: Events.fieldSlot(side, index),
        mons,
        badges: copyBadges(entry.badges),
        bag: copyBag(entry.bag),
        active: firstLiving(mons),
        connected: true,
        graceEndsAt: null,
        choice: null,
        // Who has been in against THIS seat's current monster; see `_refield`.
        fought: Object.create(null),
      };
      self.fighters.push(fighter);
      self.byId.set(playerId, fighter);
      self.bySide[side].push(fighter);
    }
  }

  // Everybody is fielded at once, so the opening participation sets are the
  // opening field. `_refield` re-adds the standing opposition every time it
  // runs, so walking the roster once is enough: a later seat's reset cannot
  // lose an earlier seat's entry, it re-derives it.
  for (const fighter of self.fighters) self._refield(fighter);

  // `mon` is the party index the referee itself fielded (here: `firstLiving`),
  // zero-based like the `exp` event's. A client cannot re-derive it from `text`:
  // a party may hold the same species twice, and resolving the name against the
  // party then picks whichever copy comes first -- which is how a fainted
  // duplicate came back onto the field. The index is unambiguous.
  for (const fighter of self.fighters) {
    const mon = activeMon(fighter);
    if (mon) {
      self._emit('send', {
        slot: fighter.slot, side: fighter.side, hp: mon.hp, text: mon.species,
        mon: fighter.active - 1,
      });
    }
  }

  self._openTurn();
  return { battle: self, reason: null };
}

// The battle, or null when it was refused. `attempt` carries the reason.
function create(opts) {
  return attempt(opts).battle;
}

module.exports = {
  VERSION,
  create,
  attempt,
  Battle,
  MONS_PER_PARTY,
  FIGHTERS_PER_SIDE,
  CHOICE_TIMEOUT,
  RECONNECT_GRACE,
  RESOLVE_TIMEOUT,
  TIE_BREAK_ROLL,
  DEFAULT_NPC_BAG,
  MODES,
  SIDES,
  STATUS_FROM_WIRE,
  STATUS_TO_WIRE,
};
