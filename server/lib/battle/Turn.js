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
 *   4. per move that is actually used: accuracy byte, crit byte, damage roll,
 *      in that order, and none of them drawn when an earlier step ended the
 *      move (a missed move draws no crit byte).
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
 *   * *Items* announce themselves and spend the turn; the bag is not modelled.
 *   * *Status moves* (power 0) narrate and do nothing.
 *   * *Physical and special are not split* -- Wire's move carries no category.
 *   * A *faint sends the next living monster in party order*, immediately.
 *   * *Residuals* run in field order (side a, then side b), not speed order.
 *   * A *timeout* auto-picks the first move with PP left and the fight goes on.
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

const MODES = { '1v1': true, coop_npc: true, coop_pvp: true };
const SIDES = ['a', 'b'];

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
  return {
    id: str(raw.id) || 'move',
    pp: Math.max(0, int(raw.pp, 0)),
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

  return {
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
  };
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

  _sideAlive(side) {
    for (const fighter of this.bySide[side]) {
      if (firstLiving(fighter.mons)) return true;
    }
    return false;
  }

  _sidePlayers(side) {
    return this.bySide[side].map((fighter) => fighter.playerId);
  }

  // A fighter owes a choice when it has something standing. A player whose last
  // monster fainted in a 2v2 is a spectator for the rest of the fight, and
  // waiting on them would hang the turn.
  _owes(fighter) {
    return activeMon(fighter) !== null && fighter.choice === null;
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
    const mon = activeMon(fighter);
    if (!mon) return null;

    if (action === 'run') return { action: 'run' };

    if (action === 'item') {
      const item = str(choice.item);
      if (!item) return null;
      return { action: 'item', item };
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
      if (!move || move.pp <= 0) return null;

      let targetFighter;
      if (choice.target !== undefined && choice.target !== null) {
        targetFighter = this._fighterAtSlot(int(choice.target, -1));
        // A named target that is empty or on the chooser's own side is refused
        // rather than redirected: redirecting would spend somebody's turn on a
        // monster they did not pick, and the client can ask again.
        if (!targetFighter || targetFighter.side === fighter.side
            || !activeMon(targetFighter)) {
          return null;
        }
      } else {
        targetFighter = this._firstLivingFoe(fighter);
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
    if (this.phase !== 'choice') return false;
    if (!isTable(choice)) return false;

    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    if (!has(ACTIONS, choice.action)) return false;

    if (choice.action === 'cancel') {
      if (fighter.choice === null) return false;
      fighter.choice = null;
      return true;
    }

    if (fighter.choice !== null) return false; // one answer per turn
    if (!activeMon(fighter)) return false;

    const normalised = this._normaliseChoice(fighter, choice);
    if (!normalised) return false;

    fighter.choice = normalised;
    this._maybeResolve();
    return true;
  }

  _maybeResolve() {
    if (this.phase !== 'choice') return false;
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) return false;
    }
    this._resolveTurn();
    return true;
  }

  // The first move with PP left, at the first living foe. Used when a deadline
  // passes: doing nothing would stall a clock that nothing else stops, and
  // picking the *best* move would be the sim playing somebody's turn well
  // rather than merely playing it.
  _autoChoice(fighter) {
    const mon = activeMon(fighter);
    if (!mon) return null;
    const foe = this._firstLivingFoe(fighter);
    if (!foe) return null;

    let pick = null;
    for (let i = 1; i <= mon.moves.length; i += 1) {
      if (mon.moves[i - 1].pp > 0) { pick = i; break; }
    }
    // Out of PP everywhere is still a turn that has to resolve, so the first
    // move goes out on empty PP rather than the fight hanging. Gen 1 would send
    // Struggle here; there is no move table to send it from.
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
   * pick the timeout files rather than a second, cleverer one: the trainer plays
   * a turn rather than playing it well, and both runtimes reproduce it byte for
   * byte.
   *
   * Returns true when a choice was actually filed, so a caller can loop until
   * the machine stops owing. Filing one may resolve the turn and open the next,
   * which is what makes that loop the thing that carries the fight forward.
   */
  autoPick(playerId) {
    if (this.phase !== 'choice') return false;
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    if (fighter.choice !== null && fighter.choice !== undefined) return false;
    if (!activeMon(fighter)) return false;

    const auto = this._autoChoice(fighter);
    if (!auto) return false;
    fighter.choice = auto;
    this._maybeResolve();
    return true;
  }

  // ----------------------------------------------------------------
  // resolution
  // ----------------------------------------------------------------

  _openTurn() {
    this.phase = 'choice';
    this.resolveDeadline = null;
    for (const fighter of this.fighters) fighter.choice = null;
    this.deadline = this.choiceTimeout > 0 ? this.now + this.choiceTimeout : null;
    this._emit('turn', { amount: this.turn });
  }

  _speedOf(mon) {
    if (mon.status === 'paralysis') return Status.paralysisSpeed(mon.stats.spd);
    return mon.stats.spd;
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
    if (!this.result) this._checkOver();

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
          this._emit('switch', {
            slot: fighter.slot, side: fighter.side, text: mon.species,
          });
          this._emit('send', {
            slot: fighter.slot, side: fighter.side, hp: mon.hp, text: mon.species,
          });
        }
      }
    }
  }

  _resolveItems() {
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (choice && choice.action === 'item') {
        this._emit('item', {
          slot: fighter.slot, side: fighter.side, text: choice.item,
        });
        this._say(`${fighter.name} used an item`);
      }
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
          speed: this._speedOf(mon),
          order: actors.length + 1,
        });
      }
    }
    if (actors.length === 0) return;

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

    for (const actor of actors) {
      if (this.result) break;
      // The monster that chose is the only one allowed to act: if it fainted to
      // a faster attacker, the replacement that came in behind it does not
      // inherit the turn.
      if (activeMon(actor.fighter) === actor.mon) {
        this._useMove(actor.fighter, actor.mon);
      }
    }
  }

  // Returns false when a gate stopped the move.
  _runGates(fighter, mon) {
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

  _useMove(fighter, mon) {
    const choice = fighter.choice;
    const move = mon.moves[choice.move - 1];
    if (!move) return;

    if (!this._runGates(fighter, mon)) return;

    const target = this._fighterAtSlot(choice.target);
    const defender = target && activeMon(target);
    if (!defender) {
      // The chosen target went down before this actor moved. Redirecting would
      // be choosing a different opponent on somebody's behalf, so the move
      // fizzles and the turn is spent -- the same thing the original does when
      // its target is gone.
      this._say(`${mon.species} has no target`);
      return;
    }

    if (move.pp > 0) move.pp -= 1;
    this._emit('anim', { slot: fighter.slot, side: fighter.side, text: move.id });
    this._say(`${mon.species} used ${move.id}`);

    const shot = Accuracy.hit({ accuracy: move.accuracy, roll: this.rng.byte() });
    if (!shot.hit) {
      this._say(`${mon.species} missed`);
      return;
    }

    if (move.power <= 0) {
      // The status-move stub: narrated, and nothing more. See the header.
      this._say('But nothing happened');
      return;
    }

    const isCrit = Crit.check({ baseSpeed: mon.stats.spd, roll: this.rng.byte() }).isCrit;
    const percents = this._typePercents(move.type, defender);

    let attack = mon.stats.atk;
    if (mon.status === 'burn') attack = Status.burnAttack(attack);

    // Drawn before the call, and unconditionally: the Lua passes this as an
    // argument, so the draw happens even on the immunity that returns below.
    const roll = this.rng.damageRoll();
    const result = Damage.compute({
      level: mon.level,
      attack,
      defense: defender.stats.def,
      power: move.power,
      crit: isCrit,
      stab: hasType(mon, move.type),
      typeEffect: percents,
      roll,
    });

    if (result.immune) {
      this._say(`It doesn't affect ${defender.species}`);
      return;
    }

    let effectiveness = 1;
    for (const pct of percents) effectiveness = (effectiveness * pct) / 100;
    if (isCrit) this._say('A critical hit');
    if (effectiveness > 1) {
      this._say("It's super effective");
    } else if (effectiveness < 1) {
      this._say("It's not very effective");
    }

    this._damage(target, defender, result.damage === null || result.damage === undefined
      ? 0 : result.damage, null);
  }

  // One place where HP comes off, so the faint that follows can never be
  // forgotten at one of the call sites.
  _damage(fighter, mon, rawAmount, status) {
    let amount = Math.max(0, int(rawAmount, 0));
    if (amount > mon.hp) amount = mon.hp;
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

  _faint(fighter, mon) {
    this._emit('faint', { slot: fighter.slot, side: fighter.side, text: mon.species });

    const next = firstLiving(fighter.mons);
    if (next) {
      fighter.active = next;
      const incoming = monAt(fighter, next);
      this._emit('send', {
        slot: fighter.slot, side: fighter.side,
        hp: incoming.hp, text: incoming.species,
      });
    } else {
      fighter.active = null;
    }

    this._checkOver();
  }

  _resolveResiduals() {
    for (const fighter of this.fighters) {
      if (this.result) return;
      const mon = activeMon(fighter);
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

    if (this.phase === 'choice' && !this._anyDisconnected() && this.choiceTimeout > 0) {
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
    if (this.phase === 'choice' && this.deadline !== null && this.now >= this.deadline
        && !this._anyDisconnected()) {
      for (const fighter of this.fighters) {
        if (this._owes(fighter)) {
          const auto = this._autoChoice(fighter);
          if (auto) {
            fighter.choice = auto;
            this._say(`${fighter.name} ran out of time`);
          }
        }
      }
      this._maybeResolve();
      // A fighter with nothing left to auto-pick would leave the turn open on a
      // deadline already in the past, and every later tick would announce the
      // timeout again. Push the clock instead: the fight waits one more window
      // rather than filling the log.
      if (this.phase === 'choice' && this.deadline !== null && this.now >= this.deadline) {
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
  const perSide = self.mode === '1v1' ? 1 : FIGHTERS_PER_SIDE;

  const sides = isTable(opts.sides) ? opts.sides : {};
  for (const side of SIDES) {
    const roster = Array.isArray(sides[side]) ? sides[side] : [];
    if (roster.length === 0) return refuse(`side ${side} has nobody on it`);
    if (roster.length > perSide) {
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
        active: firstLiving(mons),
        connected: true,
        graceEndsAt: null,
        choice: null,
      };
      self.fighters.push(fighter);
      self.byId.set(playerId, fighter);
      self.bySide[side].push(fighter);
    }
  }

  for (const fighter of self.fighters) {
    const mon = activeMon(fighter);
    if (mon) {
      self._emit('send', {
        slot: fighter.slot, side: fighter.side, hp: mon.hp, text: mon.species,
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
  MODES,
  SIDES,
  STATUS_FROM_WIRE,
  STATUS_TO_WIRE,
};
