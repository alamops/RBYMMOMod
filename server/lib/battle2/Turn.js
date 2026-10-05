'use strict';

/*
 * The turn machine (Gen 2 scaffold): choices in, events out, and one party deciding.
 *
 * Node twin of src/BattleSim2/Turn.lua, and the only file under lib/battle2/ with
 * state. The formula modules beside it each answer a single question with no
 * memory; this owns the field, the clock, the RNG stream and the order the
 * questions get asked in. A battle brokered here is resolved by *one* process
 * -- this hub, or a LAN host running the Lua half -- and the clients receive an
 * ordered stream of events they draw. They are never asked what happened.
 *
 * Sheet stats are atk/def/spe/spa/spd (Sp.Def); legacy spd+spc still accepted
 * on ingest. Damage/crit/accuracy/status draws use Gen2 rules, and the held
 * items, obedience, Thief, Rage, the Gold-native secondary effects
 * (Effects.js 87..), traps, rampages, Pay Day, Mirror Move, Leech Seed and the
 * damage tail follow pokecrystal (the Lua header cites them).
 *
 * **The RNG order is the contract.** The Lua twin has to consume draws at
 * exactly the same points or the same seed produces a different fight, so every
 * draw site is spelled out here and every one of them is conditional in a way
 * both runtimes can reproduce:
 *
 *   1. Quick Claw bytes: in each priority bracket two or more fighters share,
 *      one byte per Quick Claw holder (side b's first, then side a's, each in
 *      field order) until one fires, then
 *      a speed tie-break byte, one per group of actors in the same priority
 *      bracket, Quick Claw standing and speed -- a recharging seat and a
 *      storing Bide among the actors (R2b);
 *   2. the gate bytes of each actor, in CheckTurn's order (`_runGates`): one
 *      for a sleeping monster (a frozen one draws none and never thaws
 *      there), then one for a confused one, then one for a paralysed one --
 *      each only when the monster has that status and no earlier gate (a
 *      flinch, a self-hit, the disabled move) stopped it; a storing Bide runs
 *      them too;
 *   3. the obedience bytes of a traded monster over its badge cap, on a
 *      `badgeRules` seat (`_obey`, each only when reached);
 *   4. per move that is actually used: METRONOME's pick (redrawn on a known
 *      move) and SLEEP TALK's slot bytes ahead of the called move's own; a
 *      rampage's confusion byte (its last turn; none under its side's
 *      SAFEGUARD) or THRASH's turn-count byte (its first, ahead of
 *      `checkhit`); the accuracy byte -- a BattleRandom byte against a
 *      BRIGHTPOWDER and for a one-hit KO, none when `.DreamEater` /
 *      `.DrainSub` / `.FlyDigMoves` or OHKO's own gates stopped the move
 *      first; the `effectchance` byte right after it, hit or miss, for
 *      a script that runs one there and no substitute standing
 *      (Effects.drawsEffectChance -- on a FLY / DIG miss too); then per hit
 *      the crit byte, the damage roll (neither for a one-hit KO) and a Focus
 *      Band byte on a holder,
 *      MULTI_HIT's count byte (or two) after the first hit when the target
 *      still stands; then the move's tail -- DEFENSE_DOWN_HIT's second
 *      `effectchance` byte, the computer's StatDown byte, TRI ATTACK's own
 *      `effectchance` byte and its loop's bytes, the confusion side effect's
 *      turn byte, TRAP_TARGET's count byte -- and the King's Rock byte, in
 *      that order, none of them drawn when an earlier step ended the move. The
 *      StatDown byte (Effects.statDownGate) is a side b seat's in a fight
 *      against the computer, for a stat-down move but MUD-SLAP / OCTAZOOKA --
 *      a primary one right after its accuracy byte, hit or missed
 *      (`_statDownAfterMiss`), a *DownHit in its tail, through a substitute
 *      too -- and never into Mist or at -6.
 *
 * The damage roll is drawn even when the hit turns out to be an immunity,
 * because in the Lua the roll is an argument to `Damage.compute` and arguments
 * are evaluated before the call finds out. That is a draw the port cannot
 * optimise away without desyncing the two runtimes on the next attack.
 *
 * Between turns, HandleDefrost draws one byte per frozen monster the freeze
 * did not land on that turn (`_heldDefrost`) -- a successor's too, at the
 * replace phase's close.
 *
 * Nothing else rolls. Residuals, switches, the bag, the between-turn held
 * items, rage and the clock are all deterministic, so a battle replays from its
 * seed plus the choice log -- and a fight with no held item, no traded monster
 * and no priority move draws what it drew before any of them existed, but for
 * three changes the cart's order made on purpose (the Lua header lists them):
 * a flinched sleeper or freezer draws its status gate first, a called move no
 * longer re-runs the gates, and the paralysis byte follows the confusion byte
 * and the disabled-move check. The computer's stat-down moves draw the
 * StatDown byte (item 4) on top: only a fight against the computer whose side
 * b uses one moves.
 *
 * **Policies chosen where Gen 1 had no answer** -- the whole list, and the
 * reasoning behind each, lives in the Lua header rather than being restated
 * here; what follows is only what the port has to keep true:
 *
 *   * *Turn order* is the priority bracket (Effects.movePriority), then a
 *     Quick Claw that fired in it (at most one per bracket, `_quickClaws`),
 *     then Speed (the battle stat), then the tie-break; switches and items
 *     resolve before any move, and a seat whose turn is a forced skip rolls no
 *     Quick Claw.
 *   * *Held items* (Items.js: the static rules keyed on the sheet's hold
 *     effect), *obedience* (`_obey`), the *flinch reset* (`_openTurn`) and
 *     *Rage* (a counter the foe's hits build and Rage multiplies by, no
 *     lock-in, no Attack stage: `_buildRage`, `_resetRage`) follow
 *     pokecrystal; the Lua header has the citations.
 *   * *Speed ties* break on a single byte per tied group, below 128 leaving the
 *     side-a member first and otherwise reversing the group. A group is one
 *     bracket at one Speed.
 *   * *Struggle* is typeless (no STAB, no matchup, no badge type boost) with
 *     1/4 recoil, and is the move a top-level `_useMove` resolves to when every
 *     slot is empty -- never a move Metronome or Mirror Move calls.
 *   * *Running* is mode-gated like Teleport: wild/coop_wild flee, 1v1/coop_pvp
 *     concede, coop_npc refuses without finishing.
 *   * *Items* apply a hand-authored Gen1 heal/status table (not engine
 *     ItemEffects); unknown ids say "But it failed" and still spend the turn.
 *     Bags are client claims (sheet trust locked). Forced lock-in (recharge,
 *     a charge's release, a rampage, Bide) injects on openTurn; a trap is none
 *     on Gold (the wrapped seat is asked and refused a switch, HandleWrap's
 *     sixteenth is the residual); forced-only turns defer to the next tick.
 *   * *Metronome* picks from host-uploaded metronomePool on the ruleset.
 *   * *Physical / Special* via host-uploaded specialTypes (Gen1 type categories).
 *   * *Type names* ride on the ruleset as `typeIds`, the chart's axis in
 *     order (`typeIds[i]` names type index i), because the badge type boost is
 *     keyed by type and a move only carries an index; the side effects read
 *     it too, for POISON (a Poison type is never poisoned by one) and NORMAL
 *     (a Normal move's burn or freeze never meets the same-type return).
 *     Absent typeIds, no move's type can be named: no type boost fires, a side
 *     effect poisons a Poison type, and burn and freeze compare the move's
 *     type index with the target's alone.
 *   * A *faint sends the next living monster in party order*, immediately.
 *   * *Residuals* run in field order (side a, then side b), not speed order.
 *   * A *timeout* / NPC auto-picks with bag cures & heals (≤50% HP), X-items,
 *     SE damage, status / setup reading, and SE bench switches (deterministic
 *     heuristics — not a full TrainerAI port) -- and the fight goes on.
 *   * The choice clock is *suspended while anybody is disconnected*.
 *     `submitChoice` also refuses a seat whose `connected` is false until
 *     `reconnect()`, because SESSION_LEAVE leaves the TCP up and would
 *     otherwise keep resolving turns through the pause. `_maybeResolve`
 *     waits on the same flag, so a leftover or forced fill cannot complete
 *     the turn while anyone is away; `reconnect()` asks it again.
 *
 * The referee-gaps run's wave 3 (R2c) gave the Gold-only scripts ids of their
 * own (Effects.js 106..132) and runs their commands -- the damage formulas,
 * PROTECT / ENDURE, COUNTER / MIRROR COAT, FUTURE SIGHT, PURSUIT, the weather
 * (`this.weather`, its `msg` lines and no event kind), the fixed-damage rows --
 * and put every draw at the cart's point: CheckHit's byte domain (no byte at
 * 255, none for a script with no `checkhit`), the crit and roll where each
 * script puts them, no sleep byte, paralysis under 63, SleepTarget's 2..7,
 * the Disable count in CheckTurn. The Lua twin's header lists the order.
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
const Items = require('./Items.js');

const VERSION = 1;

// Mirrored from Config rather than required, for the reason in events.js: this
// directory runs where Config does not.
const MONS_PER_PARTY = 6; // Config.BATTLE_MON_MAX
const FIGHTERS_PER_SIDE = 3; // Config.COOP_SIDE
const CHOICE_TIMEOUT = 60; // Config.BATTLE_CHOICE_TIMEOUT
const RECONNECT_GRACE = 60; // Config.BATTLE_RECONNECT_GRACE
const RESOLVE_TIMEOUT = 30; // Config.BATTLE_RESOLVE_TIMEOUT

// Below this the side-a member of a tied group moves first.
const TIE_BREAK_ROLL = 128;

// Where the aim stream starts, relative to the battle's own seed. See
// `_autoTarget`: the referee's choice of *whom* to swing at is drawn from a
// second generator so that adding it moved no roll in the first one, and a
// second generator started on the same number would be the same sequence read
// twice -- every aim would echo a damage roll. The offset is arbitrary and
// load-bearing only in that both runtimes use it.
const AIM_SEED_OFFSET = 1597334677;

const MODES = {
  '1v1': true, coop_npc: true, coop_pvp: true, wild: true, coop_wild: true,
};
const SIDES = ['a', 'b'];

// The modes an uploaded `badges` set counts in, and the one side it counts on.
//
// The fights against the computer, on the player's seats, because that is the
// only place the cart applies its badge boosts at all: pokecrystal's
// BadgeStatBoosts (engine/battle/core.asm) opens with `ld a, [wLinkMode] /
// and a / ret nz`, returning before it reads a badge in any link battle, and
// raises wBattleMon -- the player's monster -- and nothing else; the engine's
// port says the same (gen1recomp src/battle/gen2/Battle.lua:811-815, "never
// the enemy and never in link"), and DoBadgeTypeBoosts (engine/battle/
// misc.asm:146) boosts only the player's own move. 1v1 and coop_pvp are link
// battles in everything but the cable, so both sides fight them unboosted.
// Side b of the other three is the synthetic wild / trainer seat (see
// EXP_MODES below), which no cart boosts, so a set uploaded for it is a
// confused or a hostile client and is dropped the same way.
//
// The referee is the gate rather than the client or the hub: a client can
// forge an upload and a hub passes `badges` through untouched, and this is the
// one place both hubs and solo share. It is applied once, in `attempt`, where a
// seat's set is copied -- every reader after that (`_speedOf`, both ends of the
// damage step, the type boost, the confusion self-hit) sees null and needs
// no gate of its own.
const BADGE_MODES = { wild: true, coop_wild: true, coop_npc: true };
const BADGE_SIDE = 'a';

// The mod's link battles: the two modes where both seats are people, which
// the cart would have fought over the cable. Read where pokecrystal reads
// `wLinkMode == LINK_COLOSSEUM` -- TruncateHL_BC's single pass
// (Damage.truncateStats) -- and nowhere else yet.
const LINK_MODES = { '1v1': true, coop_pvp: true };

// The cart lineages whose rules differ (contract K6): `family` on a side entry,
// stamped by the hub (never read off the wire) and by solo. The fight reads
// side a's first fighter's; absent or unknown is Gold / Silver's. Only
// TruncateHL_BC reads it (`_onePassTruncate`).
const FAMILIES = { gs: true, crystal: true };
const DEFAULT_FAMILY = 'gs';

// Berserk Gene's confusion when the seat's last confusion count ran out: 256
// checks (a 0 count wraps on CheckTurn's `dec [hl]`).
const BERSERK_CONFUSION = 256;

// Guard on the cart's rejection-sampling loops; both runtimes stop at the same
// count (the Lua twin explains).
const REDRAW_LIMIT = 1024;

// The highest level a K9 level-up may report (Wire.LEVEL_MAX, MAX_LEVEL).
const LEVEL_MAX = 100;

// wTimeOfDay's readings the time-of-day heals compare (a create option).
const TIMES = { morn: true, day: true, nite: true };

// BattleCommand_FutureSight's `ld a, 4`: hits when HandleFutureSight's count
// reaches 1 -- two turns after the use.
const FUTURE_SIGHT_COUNT = 4;

// `.DoNothing`: BattleRandom & 3 picks the line.
const LOAF_LINES = [' is loafing around.', " won't obey!", ' turned away!', ' ignored orders!'];

// The modes a faint pays experience in -- the ones vanilla awards it in. 1v1
// and coop_pvp never do; see `_awardExp` for why the gate is the mode rather
// than an owner flag. Side a is where the owners sit in all three; side b is
// the synthetic wild / trainer seat.
const EXP_MODES = { wild: true, coop_wild: true, coop_npc: true };
const EXP_OWNER_SIDE = 'a';

// Participation: who fought the monster that fell.
//
// Mirrored from the Gen 1 twin (server/lib/battle/Turn.js), which mirrors
// gen1recomp's own `BattleState:markParticipant` / `awardExp`. Gen 2 keeps the
// same bookkeeping -- `wPartyGainExpFlags` survives into Gold unchanged and
// `src/battle/gen2/Battle.lua:awardExperience` walks the same set -- so this is
// the Gen 1 machinery verbatim rather than a second derivation. Where Gen 2
// genuinely differs is in what a *share is worth* (its own stat exp, the Exp
// Share halved pass, the traded and Lucky Egg boosts), and none of that is
// here: the referee announces facts, the client prices them.
//
//   * set on send-out -- battle start, a voluntary switch, a post-faint
//     replacement, and again when the seat opposite sends its next one out.
//   * cleared when the foe changes: the set is per enemy MONSTER, not per
//     battle.
//   * dropped on its own faint (`_unfield`), so a participant that died before
//     the KO is neither paid NOR counted in the divisor.
//   * ...and the send-out's own mark lands a turn late here, because a seat is
//     *asked* for its replacement rather than just sending one. It is taken at
//     the faint, against the field the faint happened on, and held in
//     `fighter.pendingFought` until `_refield` fields the successor.
//
// Keys are strings so the two runtimes agree on membership without agreeing on
// iteration order -- nothing walks this table, it is only asked.
function foughtKey(slot, index) {
  return `${slot}:${index}`;
}

// Roster cap per side. coop_wild is N vs 1 wild (humans on a, wild on b) -- not
// exactly 2v1; other modes keep a single per-side ceiling (1 for 1v1/wild,
// FIGHTERS_PER_SIDE otherwise).
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

// The computer's own seat: side b of a fight against the computer, the one
// side BADGE_MODES never boosts -- the cart's enemy, whose turn is
// `hBattleTurn` 1 with wLinkMode 0. Where the cart gives the enemy a rule of
// its own outside a link battle -- BattleCommand_StatDown's `.ComputerMiss`
// is the case -- this is the seat that takes it. Every other seat (side a
// there, both sides of a link fight) is a player on its own cartridge. The
// Gen 1 twin keeps the same test.
function isComputerSeat(mode, fighter) {
  return !!fighter && has(BADGE_MODES, mode) && fighter.side !== BADGE_SIDE;
}

// A seat a person plays on their own cartridge: every seat but the computer's
// and the wild monster's (BIDE's menu, PursuitSwitch; the Lua twin explains).
function isPlayerSeat(mode, fighter) {
  return !!fighter && !isComputerSeat(mode, fighter) && !isWildSeat(mode, fighter);
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
  10: 'atk', 11: 'def', 12: 'spe', 13: 'spa',
  50: 'atk', 51: 'def', 52: 'spe', 53: 'spa',
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
  { id: 'X_SPEED', stat: 'spe' },
  { id: 'X_SPECIAL', stat: 'spa' },
  { id: 'DIRE_HIT', flag: 'focusEnergy' },
  { id: 'GUARD_SPEC', flag: 'mist' },
];

// Default kit kept as a named gym-style reference. Not auto-seeded onto
// unclaimed coop_npc seats: hosts upload the trainer's own items, and a
// Youngster with an empty kit must stay empty (seeding this made 2v2s look
// like eight healing items).
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
// `type: 0` is a placeholder index that nothing reads (Struggle is typeless);
// `typeId` is the cart row's NORMAL, the registry id a held type-boost item is
// matched against in DamageCalc.
const STRUGGLE = {
  id: 'STRUGGLE', power: 50, accuracy: 255,
  type: 0, effect: 0, chance: 0, typeId: 'NORMAL',
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

// An optional whole number in lo..hi, or null -- a field the sheet may leave
// out, whose absence is the answer.
function optInt(value, lo, hi) {
  const n = int(value, null);
  if (n === null) return null;
  return Math.max(lo, Math.min(hi, n));
}

function copyMove(raw) {
  if (!isTable(raw)) return null;
  const pp = Math.max(0, int(raw.pp, 0));
  const maxPp = Math.max(pp, int(raw.maxPp, pp));
  return {
    id: str(raw.id) || 'move',
    // Optional (PROTOCOL 26), and absence is a real answer rather than a gap
    // to fill: a sheet from a protocol-25 client states no name, and the
    // sentences below fall back to the id exactly as they always did.
    name: str(raw.name),
    pp,
    maxPp,
    power: Math.max(0, int(raw.power, 0)),
    accuracy: Math.max(0, int(raw.accuracy, 255)),
    type: Math.max(0, int(raw.type, 0)),
    effect: Math.max(0, int(raw.effect, 0)),
    chance: Math.max(0, int(raw.chance, 0)),
    highCrit: raw.highCrit === true,
    // Contract K8: the sheet's raw GetMovePriority number and the slot's PP
    // Ups (the Lua twin explains). Absent stays absent.
    priority: optInt(raw.priority, 0, 255),
    ppUps: optInt(raw.ppUps, 0, 3),
  };
}

// Contract K7 / K14 on a Gold sheet: the base stats, DVs, stat exp and
// happiness, each kept only when stated (the Lua twin explains).
const SHEET_BLOCKS = {
  base: { keys: ['hp', 'atk', 'def', 'spe', 'spa', 'spd'], max: 255 },
  dvs: { keys: ['atk', 'def', 'spe', 'spc'], max: 15 },
  statExp: { keys: ['hp', 'atk', 'def', 'spe', 'spc'], max: 65535 },
};

function copyBlock(raw, spec) {
  if (!isTable(raw)) return null;
  const out = {};
  let any = false;
  for (const key of spec.keys) {
    const n = optInt(raw[key], 0, spec.max);
    if (n !== null) {
      out[key] = n;
      any = true;
    }
  }
  return any ? out : null;
}

/*
 * What a move is *called* in a sentence: the display name its sheet carried
 * (PROTOCOL 26), or its registry id when it carried none.
 *
 * Prose only. An `anim` event carries the **id** and has to keep carrying it --
 * that is what a client looks the move animation and the move-menu label up by
 * -- so the two spellings are never interchangeable, and every call here is a
 * line somebody reads rather than a key something indexes.
 */
function moveLabel(move, fallback) {
  const back = fallback || 'move';
  if (!isTable(move)) return back;
  return str(move.name) || str(move.id) || back;
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
  // Gen2 stages: spe (Speed), spa, spd (Sp.Def). Legacy Gen1: spd=Speed, spc=Special.
  const gen2shaped = src.spe !== undefined && src.spe !== null
    || src.spa !== undefined && src.spa !== null
    || src.speed !== undefined && src.speed !== null;
  let speStage = src.spe;
  if (speStage === undefined || speStage === null) speStage = src.speed;
  if ((speStage === undefined || speStage === null) && !gen2shaped) speStage = src.spd;
  let spaStage = src.spa;
  if (spaStage === undefined || spaStage === null) spaStage = src.spc;
  let spdStage;
  if (gen2shaped) {
    spdStage = src.spd;
  } else {
    spdStage = src.spc;
  }
  return {
    atk: Effects.clampStage(src.atk),
    def: Effects.clampStage(src.def),
    spe: Effects.clampStage(speStage),
    spa: Effects.clampStage(spaStage),
    spd: Effects.clampStage(spdStage),
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
      moveId: str(raw.charging.moveId),
    };
  }

  let trapped = null;
  // A wrap the sheet carries: its HandleWrap count and its trapper's seat.
  if (isTable(raw.trapped)) {
    trapped = {
      turns: Math.max(0, int(raw.trapped.turns, 0)),
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
    // The pokedex id behind that prose name, when the sender stated one. Kept
    // rather than dropped for the same reason `slot` is: no formula here reads
    // it and there is no species table to read it against, but it is the only
    // thing on the sheet that lets the client *opposite* draw this monster and
    // price the exp it is worth, and the referee is the only party that can
    // hand it over. Absent stays absent -- written below rather than here, so
    // a sheet without one carries no key at all (the shape Lua produces, and
    // the one the determinism fixtures compare against).
    slot: Math.max(0, int(raw.slot, Math.max(0, int(fallback, 0)))),
    level: Math.max(1, int(raw.level, 1)),
    hp,
    maxHp,
    status,
    statusTurns: turns,
    toxicCounter: Math.max(1, int(raw.toxicCounter, 1)),
    confusion: Math.max(0, int(raw.confusion, 0)),
    stats: (() => {
      // Gen2 sheet: spa/spd (Sp.Def) + spe (Speed). Legacy Gen1: spd=Speed, spc=both specials.
      const atk = Math.max(1, int(stats.atk, 1));
      const def = Math.max(1, int(stats.def, 1));
      let spe; let spa; let spDef;
      if (stats.spa !== undefined && stats.spa !== null
          || stats.spe !== undefined && stats.spe !== null
          || stats.speed !== undefined && stats.speed !== null) {
        spe = Math.max(1, int(stats.spe !== undefined && stats.spe !== null ? stats.spe : (stats.speed !== undefined && stats.speed !== null ? stats.speed : 1), 1));
        spa = Math.max(1, int(stats.spa !== undefined && stats.spa !== null ? stats.spa : (stats.spc !== undefined && stats.spc !== null ? stats.spc : 1), 1));
        spDef = Math.max(1, int(stats.spd !== undefined && stats.spd !== null ? stats.spd : (stats.spc !== undefined && stats.spc !== null ? stats.spc : spa), 1));
      } else {
        spe = Math.max(1, int(stats.spd, 1));
        spa = Math.max(1, int(stats.spc, 1));
        spDef = spa;
      }
      return { atk, def, spe, spa, spd: spDef };
    })(),
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
    thrashing,
    raging: raw.raging === true,
    rageCounter: Math.max(0, Math.min(255, int(raw.rageCounter, 0))),
    bide,
    lastMoveIndex: Math.max(0, int(raw.lastMoveIndex, 0)),
    substitute: Math.max(0, int(raw.substitute, 0)),
    mist: raw.mist === true,
    focusEnergy: raw.focusEnergy === true,
    transformed: raw.transformed === true,
    xAccuracy: raw.xAccuracy === true,
    catchRate: Math.max(0, Math.min(255, int(raw.catchRate, 255))),
  };

  // The Gold held item and what the engine's item row says about it (contract
  // K2), kept only alongside an item; the referee's copy is the one that
  // changes (Items.take / Items.give). Absent keys stay absent, the Lua shape.
  const heldItem = str(raw.heldItem);
  if (heldItem) {
    out.heldItem = heldItem;
    out.holdEffect = str(raw.holdEffect);
    out.holdParam = Math.max(0, Math.min(255, int(raw.holdParam, 0)));
    out.itemName = str(raw.itemName);
    if (raw.mail === true) out.mail = true;
  }
  // The obedience check's one fact about the monster (contract K1).
  if (raw.traded === true) out.traded = true;
  for (const name of Object.keys(SHEET_BLOCKS)) {
    const block = copyBlock(raw[name], SHEET_BLOCKS[name]);
    if (block) out[name] = block;
  }
  const happiness = optInt(raw.happiness, 0, 255);
  if (happiness !== null) out.happiness = happiness;

  // Optional Stat Exp sheet (atk/def/spe/spa/spd, optional hp).
  if (isTable(raw.evs)) {
    const evs = {};
    for (const key of ['hp', 'atk', 'def', 'spe', 'spa', 'spd']) {
      if (raw.evs[key] !== undefined && raw.evs[key] !== null) {
        evs[key] = Math.max(0, Math.min(65535, int(raw.evs[key], 0)));
      }
    }
    out.evs = evs;
  }
  const speciesId = str(raw.speciesId);
  if (speciesId) out.speciesId = speciesId;
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

// CheckUserMove: whether the user already knows a move, by id.
function knowsMove(mon, move) {
  const key = Effects.moveKey(move);
  for (const m of mon.moves) {
    if (Effects.moveKey(m) === key) return true;
  }
  return false;
}

// TrapTarget's line, by the trapping move's id (`.Traps`); a move the table
// does not name gets FIRE SPIN's.
function trapLine(move, user, target) {
  const key = Effects.moveKey(move);
  if (key === 'BIND') return `${user.species} used BIND on ${target.species}`;
  if (key === 'WRAP') return `${target.species} was WRAPPED by ${user.species}`;
  if (key === 'CLAMP') return `${target.species} was CLAMPED by ${user.species}`;
  return `${target.species} was trapped`;
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

// The badges a seat fights with: its own upload where the cart would have
// applied it (BADGE_MODES, BADGE_SIDE), and null everywhere else.
function seatBadges(mode, side, raw) {
  if (!has(BADGE_MODES, mode) || side !== BADGE_SIDE) return null;
  return copyBadges(raw);
}

// The ruleset's type registry ids in chart-axis order, so `typeIds[i]` names
// the type a move or a monster calls `i` (MediatedBattle.typeOrder builds that
// axis). Kept dense: an entry that is not a string reads as false, a type with
// no name, rather than shifting every index after it.
function copyTypeIds(raw) {
  if (!Array.isArray(raw)) return null;
  const out = [];
  let any = false;
  for (const id of raw) {
    if (typeof id === 'string' && id !== '') {
      out.push(id);
      any = true;
    } else {
      out.push(false);
    }
  }
  if (!any) return null;
  return out;
}

// The chart index `typeIds` (copied, above) gives the type registry id
// `name`: zero-based, the axis every move and monster on the upload uses; null
// when it names no such type, or names none at all. The side effects ask it
// for POISON (CheckIfTargetIsPoisonType) and NORMAL (CheckMoveTypeMatchesTarget's
// exemption), the way the Gen 1 twin asks for POISON and FIRE.
function typeIndexOf(typeIds, name) {
  if (!Array.isArray(typeIds)) return null;
  for (let i = 0; i < typeIds.length; i += 1) {
    if (typeIds[i] === name) return i;
  }
  return null;
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

// The between-turn held-item routines' seat filter: null is the whole field.
function inSet(only, fighter) {
  return only === null || only === undefined || only.has(fighter);
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
    this.aim = Rng.create(int(opts.seed, 0) + AIM_SEED_OFFSET);
    this.chart = isTable(opts.chart) ? opts.chart : null;
    this.specialTypes = null;
    this.typeIds = copyTypeIds(opts.typeIds);
    this.poisonType = typeIndexOf(opts.typeIds, 'POISON');
    this.normalType = typeIndexOf(opts.typeIds, 'NORMAL');
    // BattleCommand_LeechSeed's `cp GRASS` (a Grass type is never seeded).
    this.grassType = typeIndexOf(opts.typeIds, 'GRASS');
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
    // What the current action has knocked down and not paid for yet; see
    // `_drainExp`. A list, so the order faints happened in is the order their
    // spoils are announced in.
    this.pendingExp = [];
    this.fighters = [];
    // A Map, not an object: a playerId is attacker-supplied and "__proto__" is
    // a perfectly legal string.
    this.byId = new Map();
    this.bySide = { a: [], b: [] };
    // Reflect / Light Screen and Safeguard, held per SIDE as pokecrystal
    // holds them: turns left, 0 when down. A side's seats share them, a
    // switch or a faint leaves them up, Haze does not touch them, and only the
    // between-turn ticks (`_tickSafeguard`, `_tickScreens`) take them down.
    this.screens = {
      a: { lightScreen: 0, reflect: 0, safeguard: 0 },
      b: { lightScreen: 0, reflect: 0, safeguard: 0 },
    };
    // wPayDayMoney: the coins every PAY DAY that landed scattered, whoever
    // used it (BattleCommand_PayDay); see `_payDayOutcome`.
    this.payDay = 0;
    // wBattleWeather / wWeatherCount: null or { kind, turns } (the Lua twin
    // explains each of these four).
    this.weather = null;
    // wCurDamage, COUNTER / MIRROR COAT's register.
    this.curDamage = 0;
    // wTimeOfDay for the time-of-day heals, or null.
    this.timeOfDay = has(TIMES, opts.timeOfDay) ? opts.timeOfDay : null;
    // This turn's action order (`_wentFirst`): seat -> position.
    this.actionOrder = new Map();
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

  // partyIndex is 1-based into the fighter's party. Present on a PP
  // spend/restore so the client can write that sheet; absent on
  // Transform/Mimic so the overlay is not mistaken for the real set.
  _emitMoves(fighter, mon, partyIndex) {
    const moves = mon.moves.map((m) => ({
      id: m.id || 'move',
      pp: Math.max(0, int(m.pp, 0)),
      maxPp: Math.max(0, int(m.maxPp, m.pp)),
      power: Math.max(0, int(m.power, 0)),
      accuracy: Math.max(0, int(m.accuracy, 255)),
      type: Math.max(0, int(m.type, 0)),
      effect: Math.max(0, int(m.effect, 0)),
      chance: Math.max(0, int(m.chance, 0)),
    }));
    const fields = { slot: fighter.slot, side: fighter.side, moves };
    if (partyIndex != null) fields.mon = partyIndex - 1;
    return this._emit('moves', fields);
  }

  _say(text) {
    return this._emit('msg', { text });
  }

  /*
   * Every seat's party roster, published when -- and only when -- it moved.
   *
   * Gen 2's twin of `server/lib/battle/Turn.js:_syncTeams`; read that one's
   * header for why the referee is the only party to a mediated fight that can
   * say this, and why it says a ball row and never a sheet. Same three tokens,
   * same diff, same three call sites, in the same order -- the roster chip does
   * not know which generation drew it.
   */
  _syncTeams() {
    for (const fighter of this.fighters) {
      const roster = Events.teamString(fighter.mons);
      if (roster !== fighter.team) {
        fighter.team = roster;
        this._emit('team', {
          slot: fighter.slot, side: fighter.side, team: roster,
        });
      }
    }
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

  // Which opposing seat an action *nobody chose* swings at.
  //
  // Every aim the referee files for itself comes through here: an NPC's pick,
  // the identical pick a human's timeout files, and the lock-in turns of
  // thrash / rage / bide, where nobody is asked for a target because the move
  // does not offer one.
  //
  // It used to be `_firstLivingFoe`, which answers "the lowest-numbered living
  // foe" -- the right answer to a question with one possible answer, and the
  // wrong one the moment a side holds two players. A coop_wild's wild monster
  // and *both* seats of a coop_npc trainer swung at seat 0 every turn of every
  // fight, so the second player on the side was never once attacked. Reported
  // from a real two-player game, and reproducible in one sitting: 18 damage
  // events, 18 of them on slot 0.
  //
  // So: uniform over the living opposing seats. Three properties make that
  // safe to add to a sim two runtimes have to agree on byte for byte.
  //
  //   * The draw is on `this.aim`, not `this.rng`. A draw on the battle's own
  //     generator would shift every roll after it and silently rewrite every
  //     recorded vector; this one cannot move a number that already exists.
  //   * One living foe is answered without drawing at all. A 1v1, and the lone
  //     wild seat of a wild / coop_wild fight, therefore consume nothing and
  //     replay exactly as they always did -- the aim stream in those fights is
  //     never even touched.
  //   * `byte()` is the draw, not `nextInt`. `nextInt` takes the whole LCG
  //     state modulo the span, and this generator's bit 0 alternates every
  //     step, so a two-seat side would have got a perfect A-B-A-B rota rather
  //     than a spread. `byte()` reads bits 16..23, which is the reason Rng.js
  //     puts them there.
  //
  // Draw order is the parity contract, exactly as it is for `this.rng`: both
  // runtimes call this at the same points, in the same seat order, or their
  // aim streams part company. The turn-parity drivers are what hold that.
  _autoTarget(fighter) {
    const living = [];
    for (const foe of this._foes(fighter)) {
      if (activeMon(foe)) living.push(foe);
    }
    if (living.length === 0) return null;
    if (living.length === 1) return living[0];
    return living[this.aim.byte() % living.length];
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
  //
  // Byte-identical to the Gen 1 twin: a stolen KO is a field-geometry rule, and
  // the field has the same shape in both games.
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
  // that reads "who are we waiting on" goes through here, which is why the
  // phase test lives in this one function rather than at each call site.
  _owes(fighter) {
    if (fighter.choice !== null && fighter.choice !== undefined) return false;
    if (fighter.mustReplace) {
      return firstLiving(fighter.mons) !== null;
    }
    if (this.phase === 'replace') return false;
    if (activeMon(fighter) === null) return false;
    return true;
  }

  // The forced answer for a recharging or biding seat, or null (the Lua twin
  // explains): a recharge is a turn-order actor with no move (`recharge`), a
  // Bide a move used every turn -- storing (`bideStore`) until its count
  // runs out, then released (`bideRelease`) -- through CheckTurn's gates. A
  // player's Bide is no lock-in (`_asksBide`): this is what its FIGHT means.
  _lockedChoice(fighter, mon) {
    if (mon.mustRecharge) return { action: 'skip', recharge: true };
    if (mon.bide) {
      const slotted = mon.bide.targetSlot !== null && mon.bide.targetSlot !== undefined;
      if (mon.bide.turns > 0) {
        return {
          action: 'fight', move: mon.bide.moveIndex,
          target: slotted ? mon.bide.targetSlot : null, bideStore: true,
        };
      }
      const foe = this._autoTarget(fighter);
      if (!foe) return null;
      return {
        action: 'fight',
        move: mon.bide.moveIndex,
        // Lua's `targetSlot or foe.slot`: seat 0 is a seat.
        target: slotted ? mon.bide.targetSlot : foe.slot,
        bideRelease: true,
      };
    }
    return null;
  }

  // Whether a biding seat is asked rather than filled: CheckPlayerLockedIn
  // does not quit on SUBSTATUS_BIDE, so the player's menu opens during a Bide
  // (FIGHT goes on with it, an item ends it -- R2b's finding (h)); the
  // computer's and the wild one's Bide stay locked.
  _asksBide(fighter) {
    return isPlayerSeat(this.mode, fighter);
  }

  // Inject forced choices for charge release, recharge skip, the computer's
  // Bide, the rampage's next turns and ROLLOUT's (CheckPlayerLockedIn). A trap
  // is not one on Gold: a wrapped monster picks its moves (wPlayerWrapCount
  // only closes switching and running, `_normaliseChoice`) and its trapper is
  // free (`_wrapTick` holds HandleWrap).
  _fillForcedChoices() {
    for (const fighter of this.fighters) {
      if (fighter.choice !== null && fighter.choice !== undefined) continue;
      const mon = activeMon(fighter);
      if (!mon) continue;

      if (mon.mustRecharge || (mon.bide && !this._asksBide(fighter))) {
        const locked = this._lockedChoice(fighter, mon);
        if (locked) {
          fighter.forced = true;
          fighter.choice = locked;
          this._emit('chose', {
            slot: fighter.slot, side: fighter.side, text: fighter.name,
          });
        }
        continue;
      }

      if (mon.charging) {
        const c = mon.charging;
        fighter.forced = true;
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
        const foe = this._autoTarget(fighter);
        if (foe) {
          this._say(`${mon.species} thrashing about`);
          fighter.forced = true;
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

      // SUBSTATUS_ROLLOUT: the next roll is the same move, aimed like a
      // rampage's.
      if (mon.rollout && mon.rollout.active) {
        const foe = this._autoTarget(fighter);
        if (foe) {
          fighter.forced = true;
          fighter.choice = {
            action: 'fight',
            move: mon.rollout.moveIndex,
            target: foe.slot,
          };
          this._emit('chose', {
            slot: fighter.slot, side: fighter.side, text: fighter.name,
          });
        }
        continue;
      }

      // Rage is not a lock-in on Gold / Crystal: the seat is asked like any
      // other, and `_resetRage` ends the rage when it picks anything else.
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
  // `target` is a 0..5 *field* slot. They are converted here, once, so nothing
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
    // wPlayerWrapCount: a monster a trapping move holds can be neither
    // recalled (`.check_trapped`) nor run from a wild fight (`.cant_escape`).
    // Refused rather than filed, as the menu refuses it; conceding a link
    // fight is the mod's, not a run.
    const wrapped = !!(mon.trapped && mon.trapped.turns > 0);

    if (action === 'run') {
      if (wrapped && Effects.teleportRunAllowed(this.mode)) return null;
      return { action: 'run' };
    }

    // FIGHT during a player's Bide (`_asksBide`): whatever slot was named, the
    // Bide goes on -- storing, or its release.
    if (action === 'fight' && mon.bide) {
      const locked = this._lockedChoice(fighter, mon);
      if (locked) return locked;
      return { action: 'skip' };
    }

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
      // Gen 1: Potion/Ether/status/vitamin on a KO, and Revive on a living
      // mon, never leave the picker. Refuse here so a submitted choice cannot
      // spend the bag or the turn.
      const targetMon = monAt(fighter, out.slot != null ? out.slot : fighter.active);
      if (targetMon) {
        if (effect && effect.faintedOnly && targetMon.hp > 0) return null;
        if (targetMon.hp <= 0 && Effects.itemFailsOnFainted(effect)) return null;
      }
      return out;
    }

    if (action === 'switch') {
      if (wrapped) return null;
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
        // Deliberately `_firstLivingFoe` and not `_autoTarget`: this is a
        // *player's* move with the aim left off, and the answer to that is a
        // predictable default the client can show, not a die roll. Only the
        // aims nobody chose spread.
        targetFighter = this._firstLivingFoe(fighter);
        if (!targetFighter) {
          for (const foe of this._foes(fighter)) {
            if (foe.mustReplace) { targetFighter = foe; break; }
          }
        }
        if (!targetFighter) {
          // Same leftover as `_autoChoiceOrSkip`: a living seat with nobody
          // across the field to aim at spends the turn rather than hanging
          // the window. Solo's choice clock is 0, so a refused FIGHT used
          // to mark the band answered and wait for WILD forever.
          return { action: 'skip' };
        }
      }
      return { action: 'fight', move: index + 1, target: targetFighter.slot };
    }

    return null;
  }

  /*
   * Returns true when the choice is now held for this turn, false otherwise.
   * False is the whole of the error report on purpose: the reasons a choice is
   * refused (wrong phase, unknown player, disconnected, already answered, an
   * index that names nothing) are all things the client can see for itself, and
   * a string here would be a second vocabulary to keep in step across two
   * runtimes.
   */
  submitChoice(playerId, choice) {
    if (this.phase !== 'choice' && this.phase !== 'replace') return false;
    if (!isTable(choice)) return false;

    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    // disconnect() pauses the clock but used to keep taking answers from the
    // same socket (SESSION_LEAVE leaves TCP up). Refuse until reconnect().
    if (!fighter.connected) return false;
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
      // A referee-filled answer is not the player's to take back. Recharge,
      // Bide, a rampage and a charge release all fill the seat at `_openTurn`;
      // without this a client could cancel out of a lock-in, and on a turn
      // where *every* seat is forced `_openTurn` left no deadline, so the
      // cleared choice would hang the fight with nothing to time it out.
      if (fighter.forced) return false;
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
    // A leftover or forced fill must not complete the turn while a seat is
    // away: the clock is paused for them, and resolving would spend it.
    // reconnect() calls this once everyone is back.
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
      && mon.stages.spe <= 0 && mon.stages.spa <= 0;
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
      const foe = this._autoTarget(fighter);
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
    if (mon.mustRecharge || mon.bide) {
      const locked = this._lockedChoice(fighter, mon);
      if (locked) return locked;
    }
    // A wrapped monster fights on but cannot switch (`_normaliseChoice`), so
    // none of the retreats below is open to it.
    const canSwitch = !(mon.trapped && mon.trapped.turns > 0);
    if (mon.thrashing && mon.thrashing.turns > 0) {
      const foe = this._autoTarget(fighter);
      if (foe) {
        return {
          action: 'fight',
          move: mon.thrashing.moveIndex,
          target: foe.slot,
        };
      }
    }
    let foe = this._autoTarget(fighter);
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
      || (defender.stages.spe || 0) >= 2
      || (defender.stages.spa || 0) >= 2
      || defender.focusEnergy;
    const foeSub = (defender.substitute || 0) > 0;
    const weSlower = this._speedOf(fighter, mon) < this._speedOf(foe, defender);

    // Critical HP: SE retreat (heal already tried via bag).
    if (canSwitch && mon.hp * 4 <= mon.maxHp) {
      const se = this._bestSeBench(fighter, defender);
      if (se) return { action: 'switch', slot: se };
    }

    // Behind a boosted / subbed foe at mid-low HP: prefer an SE bench mon.
    if (canSwitch && (foeBoosted || foeSub) && mon.hp * 2 <= mon.maxHp) {
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

    if (canSwitch && (!pick || pickEff === 0)) {
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
      && mon.stages.spe <= 0 && mon.stages.spa <= 0;
    // Do not set up into a boosted foe, behind a substitute, or while slower
    // at mid-low HP — hit or switch instead.
    if (stagesFlat && !mon.focusEnergy && !foeBoosted && !foeSub
        && !(weSlower && mon.hp * 2 <= mon.maxHp)) {
      let setupPick = null;
      for (let i = 1; i <= mon.moves.length; i += 1) {
        const m = mon.moves[i - 1];
        if (m.pp > 0 && !disabled(i) && m.power === 0) {
          let kind = AUTO_SETUP[m.effect];
          // A screen already up on this side would only fail (BattleCommand_
          // Screen's second cast), so it is no setup at all.
          if ((m.effect === 64 && this.screens[fighter.side].lightScreen > 0)
              || (m.effect === 65 && this.screens[fighter.side].reflect > 0)) {
            kind = undefined;
          }
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
    // An empty sheet is Struggle, not a hang: `_useMove` treats allPpEmpty
    // (including `moves.length === 0`) as the synthetic STRUGGLE even with no slot.
    return { action: 'fight', move: pick, target: foe.slot };
  }

  /*
   * What autoPick / the timeout sweep files when `_autoChoice` has no answer.
   *
   * A living seat in the choice phase that `_autoChoice` cannot describe (empty
   * moves, nothing across the field to aim at) used to return null, so nothing
   * was filed. The hub then waited out BATTLE_CHOICE_TIMEOUT and retried the
   * same null (deadline pushed). Solo sets SOLO_CHOICE_TIMEOUT to 0, which this
   * file reads as "no deadline at all", so the NPC never files, the player has
   * already answered, and the band sits on "Waiting for X..." with RUN refused
   * in a trainer fight -- a battle with no way out.
   *
   * An empty sheet with a living foe is now a fight (`_autoChoice` names slot
   * 1; `_useMove` turns that into Struggle). Skip remains for the leftover
   * case: a living seat with nobody across the field to aim at. A mustReplace
   * seat with no living bench stays null: that seat cannot skip a send-out,
   * and `_checkOver` should have ended the fight.
   */
  _autoChoiceOrSkip(fighter) {
    const auto = this._autoChoice(fighter);
    if (auto) return auto;
    if (this.phase === 'choice' && activeMon(fighter)) {
      return { action: 'skip' };
    }
    return null;
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
    // turn that has not opened. `Relay:fillNpcChoices` calls this in a loop and
    // stops when nothing files, so the false is how the loop learns to stop.
    if (this.phase === 'replace' && !this._owes(fighter)) return false;
    if (!fighter.mustReplace && !activeMon(fighter)) return false;

    const auto = this._autoChoiceOrSkip(fighter);
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
    // A side that is already down must not be asked for a move. Without this,
    // a faint that left the field in `choice` (or `_closeReplace` after an
    // empty send-out) opened a window nobody across the field could answer,
    // and Solo's zero timeout left the band on "Waiting for WILD...".
    if (this._checkOver()) return;
    this.phase = 'choice';
    this.resolveDeadline = null;
    this.forcedPending = false;
    for (const fighter of this.fighters) {
      fighter.choice = null;
      fighter.forced = null;
      // CheckPlayerLockedIn resets both SUBSTATUS_FLINCHED bits as the player
      // is asked for a move, except while the player's monster must recharge;
      // "the player" is a `badgeRules` seat, kept per seat for its own fielded
      // monster, and the reset is unconditional everywhere else (the Lua twin
      // explains).
      const mon = activeMon(fighter);
      const kept = fighter.badgeRules && mon && mon.mustRecharge ? mon : null;
      for (const each of fighter.mons) {
        if (each !== kept) each.flinch = false;
        // BattleTurn's top clears wPlayerJustGotFrozen / wEnemyJustGotFrozen.
        each.justFrozen = null;
      }
      // ...and wPlayerIsSwitching / wEnemyIsSwitching (PURSUIT's doubling).
      fighter.switching = null;
    }
    // ...and wCurDamage, and this referee's record of who went first.
    this.curDamage = 0;
    this.actionOrder = new Map();
    // HandleBerserkGene, at the head of BattleTurn's loop -- before the menu.
    this._berserkGene();
    this.deadline = this.choiceTimeout > 0 ? this.now + this.choiceTimeout : null;
    // Before the window opens: a player deciding this turn is looking at the
    // rosters, and anything a status or a bench potion moved last turn has to
    // be on them by the time the menu is up.
    this._syncTeams();
    this._emit('turn', { amount: this.turn });
    this._fillForcedChoices();
    // When every living seat is forced, defer resolve to the next tick so
    // clients see a turn boundary before the chain continues.
    if (!this._anyoneOwes()) {
      this.forcedPending = true;
      this.deadline = null;
    }
  }

  // ------------------------------------------------------------------
  // the replace phase
  // ------------------------------------------------------------------
  //
  // A faint with a living bench used to be folded into the *next* choice
  // window: the referee incremented the turn, opened it, and the seat's
  // replacement rode in alongside everybody else's fight. That is one window
  // with an empty box in it -- the player picked a move at a foe that was not
  // on the field yet, and the successor only walked out when the turn after
  // that resolved. Vanilla never does this.
  //
  // So the referee holds a phase of its own between the two turns. Nothing else
  // is asked for, nothing resolves, and the turn number does not move: the
  // fight is still on the turn whose faint opened this. When the last owed
  // replacement is in, `_resolveSwitches` fields them all (`switch` + `send`)
  // and only then does the next turn open. For a seat with no connection behind
  // it that whole phase closes inside one flush -- `fillNpcChoices` runs before
  // the drain -- so the client reads one batch: faint ... switch ... send ...
  // turn.
  //
  // Ported from the Gen 1 twin unchanged: the pacing complaint it answers is
  // about the *referee's* turn structure, which both generations share.

  _anyMustReplace() {
    for (const fighter of this.fighters) {
      if (fighter.mustReplace && firstLiving(fighter.mons) !== null) return true;
    }
    return false;
  }

  // Solicitation: one `turn` per owing seat, carrying the seat's **field slot**.
  //
  //   * `turn` WITH `slot` -- this seat is being asked for a replacement. Its
  //     own client opens the switch picker; everyone else holds on "X is
  //     choosing who to send out...".
  //   * `turn` WITHOUT `slot` -- the ordinary choice window (`_openTurn`).
  //
  // No new kind, no new field: `slot` is already in Events.FIELDS and already
  // rides the wire sanitiser kind-agnostically, so a client built before this
  // ignores it and degrades to the old behaviour rather than breaking.
  //
  // Seat order is `this.fighters`, which is side a then side b in seating order
  // -- ascending field slot, and the same order in both runtimes.
  _openReplace() {
    this.phase = 'replace';
    this.resolveDeadline = null;
    this.forcedPending = false;
    for (const fighter of this.fighters) {
      fighter.choice = null;
      fighter.forced = null;
    }
    this.deadline = this.choiceTimeout > 0 ? this.now + this.choiceTimeout : null;
    // The other window a player answers from, and the same reason.
    this._syncTeams();
    for (const fighter of this.fighters) {
      if (this._owes(fighter)) {
        this._emit('turn', { amount: this.turn, slot: fighter.slot });
      }
    }
  }

  // Every replacement is in: field them, then open the turn they were owed for.
  // Every replacement is in: field them, give them this turn's between-turn
  // held items (the Lua twin explains), then open the turn they were owed for.
  _closeReplace() {
    const filled = new Set();
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (fighter.mustReplace && choice && choice.action === 'switch') filled.add(fighter);
    }
    this._resolveSwitches();
    this._heldLeftovers(filled);
    this._heldMysteryberry(filled);
    this._heldDefrost(filled);
    this._heldStatBoosts(filled);
    this._heldHealing(filled);
    this.turn += 1;
    this._openTurn();
  }

  // The battle stat a hit or the turn order reads (Effects.battleStat: stage,
  // then the seat's badge boost, then burn / paralysis), with the seat's own
  // badges -- null wherever the cart would not have boosted (BADGE_MODES).
  _battleStat(fighter, mon, key) {
    return Effects.storedStat(mon, key, fighter.badges);
  }

  // The battle stats a monster comes onto the field with (the Lua twin
  // explains): InitBattleMon's status-then-badge, or LoadEnemyMon's bare
  // party stats for the computer's seat outside a link fight.
  _switchInStats(fighter, mon) {
    const order = isComputerSeat(this.mode, fighter) ? 'load' : 'init';
    Effects.snapStats(mon, fighter.badges, Effects.calcStats(mon, fighter.badges, order));
  }

  _speedOf(fighter, mon) {
    return this._battleStat(fighter, mon, 'spe');
  }

  // The bracket an action moves in: the selected move's (Effects.movePriority),
  // which is Struggle's when every slot is empty -- the move `_useMove` will
  // resolve to -- and the slot's own otherwise, so a Metronome moves at
  // Metronome's priority whatever it calls.
  _priorityOf(fighter, mon) {
    const choice = fighter.choice;
    // A recharging seat's is the move that left it recharging, a Bide's
    // BIDE's (`_lockedMove`).
    if (choice && choice.recharge) return Effects.movePriority(mon.rechargeMove);
    // A lock-in's move first (`_lockedMove`), as GetMovePriority reads
    // wCurPlayerMove.
    const locked = this._lockedMove(fighter, mon);
    if (locked) return Effects.movePriority(locked);
    if (allPpEmpty(mon)) return Effects.movePriority(STRUGGLE);
    return Effects.movePriority(mon.moves[(choice ? choice.move : 0) - 1]);
  }

  // Whether the screen that guards against this kind of hit is up on `side`.
  _screenUp(side, isSpecial) {
    const screens = this.screens[side];
    if (!screens) return false;
    if (isSpecial) return screens.lightScreen > 0;
    return screens.reflect > 0;
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

  // The registry id of chart index `typeIndex` (`typeIds`), or null when the
  // ruleset named none or this index is past its end.
  _typeIdOf(typeIndex) {
    const ids = this.typeIds;
    if (!ids) return null;
    return ids[int(typeIndex, -1)] || null;
  }

  // ------------------------------------------------------------------
  // held items (Items.js holds the rules; these are the cart's call sites --
  // the Lua twin's notes cite each one)
  // ------------------------------------------------------------------

  // K6: one pass in a link battle on either cart and in every battle on Gold /
  // Silver; only Crystal outside a link battle loops.
  _onePassTruncate() {
    return has(LINK_MODES, this.mode) || this.family !== 'crystal';
  }

  // Which of this seat's party a monster is, 1-based, by identity.
  _partyIndex(fighter, mon) {
    for (let i = 1; i <= fighter.mons.length; i += 1) {
      if (fighter.mons[i - 1] === mon) return i;
    }
    return null;
  }

  // The `held` event (contract K3); the caller says the cart's sentence next.
  _emitHeld(fighter, mon, itemId, amount) {
    const index = this._partyIndex(fighter, mon);
    this._emit('held', {
      slot: fighter.slot, side: fighter.side,
      mon: index === null ? undefined : index - 1,
      text: itemId, amount,
    });
  }

  // The registry id of a move's type (Struggle's row says NORMAL).
  _moveTypeId(move) {
    if (!isTable(move)) return null;
    return move.typeId || this._typeIdOf(move.type);
  }

  // The attacker's type-boost item for this move, or null.
  _typeBoostOf(mon, move) {
    return Items.typeBoostPercent(mon, this._moveTypeId(move));
  }

  // wBattleMonSpecies, which Transform rewrites.
  _battleSpecies(mon) {
    if (mon.transformed) return mon.transformSpecies === undefined ? null : mon.transformSpecies;
    return mon.speciesId === undefined ? null : mon.speciesId;
  }

  // HandleBerserkGene, every seat in field order.
  _berserkGene() {
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (mon && mon.heldItem === Items.BERSERK_GENE) {
        const name = Items.label(mon);
        const item = Items.take(mon);
        const wasConfused = mon.confusion > 0;
        if (!wasConfused) {
          const count = int(fighter.confuseCount, 0);
          mon.confusion = count > 0 ? count : BERSERK_CONFUSION;
        }
        this._emitHeld(fighter, mon, item.heldItem, 0);
        this._say(`${mon.species}'s ${name} activated!`);
        const before = Effects.clampStage(mon.stages.atk);
        const after = Effects.clampStage(before + 2);
        if (after !== before) {
          mon.stages.atk = after;
          Effects.dropSnap(mon);
          const text = `${mon.species}'s ATTACK rose`;
          this._say(text);
          this._emit('stat', {
            slot: fighter.slot, side: fighter.side, amount: after, stage: after, text,
          });
        }
        if (!wasConfused) {
          const text = `${mon.species} became confused`;
          this._say(text);
          this._emit('status', { slot: fighter.slot, side: fighter.side, confused: 1, text });
        }
      }
    }
  }

  // DetermineMoveOrder's `.equal_priority`, widened to a field: in every
  // bracket two or more actors share, highest first, the Quick Claw holders
  // draw (side b's seats, then side a's, each in field order) until one fires.
  _quickClaws(actors) {
    const counts = new Map();
    const brackets = [];
    for (const actor of actors) {
      const p = actor.priority === undefined ? 0 : actor.priority;
      if (!counts.has(p)) { counts.set(p, 0); brackets.push(p); }
      counts.set(p, counts.get(p) + 1);
    }
    brackets.sort((x, y) => y - x);
    for (const p of brackets) {
      if (counts.get(p) >= 2) {
        const holders = actors.filter((actor) => (actor.priority === undefined ? 0 : actor.priority) === p
          && actor.clawParam !== null && actor.clawParam !== undefined);
        holders.sort((x, y) => {
          const xs = x.fighter.side === 'b' ? 0 : 1;
          const ys = y.fighter.side === 'b' ? 0 : 1;
          if (xs !== ys) return xs - ys;
          return x.order - y.order;
        });
        for (const holder of holders) {
          if (Items.quickClawFires(holder.clawParam, this.rng.byte())) {
            holder.claw = true;
            break;
          }
        }
      }
    }
  }

  // One hit through BattleCommand_ApplyDamage's Focus Band arm.
  // ApplyDamage asks ENDURE first (wave 3, the Lua twin explains): FalseSwipe's
  // clamp and "ENDURED the hit!", no Focus Band byte. A hit of 0 takes and
  // shows nothing. wCurDamage (`curDamage`) keeps the HP the hit took -- 0
  // when a substitute took it.
  _strike(fighter, mon, rawAmount) {
    let amount = rawAmount;
    let banded = false;
    let endured = false;
    if (mon.endure) {
      const clamp = Items.focusBand(amount, mon.hp);
      amount = clamp.amount;
      endured = clamp.held;
    } else {
      const held = Items.effect(mon);
      if (held.effect === Items.FOCUS_BAND && mon.hp > 0) {
        if (this.rng.byte() < held.param) {
          const band = Items.focusBand(amount, mon.hp);
          amount = band.amount;
          banded = band.held;
        }
      }
    }
    // ApplyDamage's `.update_damage_taken`, between the band and the HP: a
    // biding monster with no substitute adds the hit's whole wCurDamage to
    // what BIDE releases, a 16-bit sum pinned at $ffff. Only a move's hit.
    if (mon.bide && int(mon.substitute, 0) <= 0) {
      mon.bide.stored = Math.min(Damage.WORD_MAX,
        mon.bide.stored + Math.max(0, int(amount, 0)));
    }
    amount = Math.max(0, int(amount, 0));
    const behindSub = int(mon.substitute, 0) > 0;
    const before = mon.hp;
    if (amount > 0) this._damage(fighter, mon, amount, null);
    this.curDamage = (behindSub || amount <= 0) ? 0 : (before - mon.hp);
    if (endured) {
      this._say(`${mon.species} ENDURED the hit!`);
    } else if (banded) {
      this._emitHeld(fighter, mon, mon.heldItem, 1);
      this._say(`${mon.species} hung on with ${Items.label(mon)}!`);
    }
  }

  // BattleCommand_Thief, both ways and in every mode. Its wEffectFailed
  // return (a substitute at `effectchance`, or the chance byte not landing --
  // the 1/256 miss of a 100% move) is the caller's: it asks this only when the
  // side-chance byte `_useMove` drew landed with no substitute standing.
  _thief(fighter, mon, target, defender) {
    if (mon.heldItem || !defender.heldItem) return;
    if (Items.isMail(defender)) return;
    const item = Items.take(defender);
    Items.give(mon, item);
    this._emitHeld(target, defender, item.heldItem, 0);
    this._emitHeld(fighter, mon, item.heldItem, 1);
    this._say(`${mon.species} stole ${Items.label(mon)} from its foe!`);
  }

  // BattleCommand_BuildOpponentRage, right after `checkfaint` in every
  // damaging script: a raging target still standing gains a rage step (a hit
  // into its substitute counts); nothing else builds rage. 255 holds, silently.
  _buildRage(defender) {
    if (defender.hp <= 0 || !defender.raging) return;
    if (defender.rageCounter >= 255) return;
    defender.rageCounter += 1;
    this._say(`${defender.species}'s RAGE is building!`);
  }

  // BattleCommand_HeldFlinch (`kingsrock`).
  _kingsRock(mon, move, effectId, defender) {
    const held = Items.effect(mon);
    if (held.effect !== Items.FLINCH) return;
    if (!Items.kingsRockMove(effectId, Effects.moveKey(move))) return;
    if (defender.hp <= 0 || (defender.substitute || 0) > 0) return;
    if (this.rng.byte() < held.param) {
      defender.flinch = true;
      defender.mustRecharge = false;
    }
  }

  // UseHeldStatusHealingItem. Returns true when it acted.
  _statusBerry(fighter, mon) {
    const held = Items.effect(mon);
    const cures = held.effect && has(Items.STATUS_CURE, held.effect)
      ? Items.STATUS_CURE[held.effect] : null;
    if (!cures || !mon.status || !has(cures, mon.status)) return false;
    const name = Items.label(mon);
    const text = `${mon.species} recovered using a ${name}!`;
    mon.status = null;
    mon.statusTurns = 0;
    this._emit('status', { slot: fighter.slot, side: fighter.side, text });
    if (held.effect === Items.HEAL_STATUS && mon.confusion > 0) {
      mon.confusion = 0;
      this._emit('status', { slot: fighter.slot, side: fighter.side, confused: 0, text });
    }
    const item = Items.take(mon);
    this._emitHeld(fighter, mon, item.heldItem, 0);
    this._say(text);
    return true;
  }

  // UseConfusionHealingItem.
  _confusionBerry(fighter, mon) {
    if (!(mon.confusion > 0)) return false;
    const held = Items.effect(mon);
    if (held.effect !== Items.HEAL_CONFUSION && held.effect !== Items.HEAL_STATUS) return false;
    const text = `A ${Items.label(mon)} rid ${mon.species} of its confusion.`;
    mon.confusion = 0;
    this._emit('status', { slot: fighter.slot, side: fighter.side, confused: 0, text });
    const item = Items.take(mon);
    this._emitHeld(fighter, mon, item.heldItem, 0);
    this._say(text);
    return true;
  }

  // HandleHPHealingItem: Berry, Gold Berry, Berry Juice.
  _hpBerry(fighter, mon) {
    const held = Items.effect(mon);
    if (held.effect !== Items.BERRY || !Items.berryWants(mon.hp, mon.maxHp)) return false;
    const name = Items.label(mon);
    this._heal(fighter, mon, held.param);
    const item = Items.take(mon);
    this._emitHeld(fighter, mon, item.heldItem, 0);
    this._say(`${mon.species} recovered using a ${name}!`);
    return true;
  }

  // HandleLeftovers: player then enemy. The between-turn held-item routines
  // take `only`, a Set of seats: null is the whole field, a set the
  // successors `_closeReplace` fielded.
  _heldLeftovers(only = null) {
    for (const fighter of this.fighters) {
      const mon = inSet(only, fighter) ? activeMon(fighter) : null;
      if (mon && Items.holds(mon, Items.LEFTOVERS) && mon.hp < mon.maxHp) {
        this._heal(fighter, mon, Items.sixteenth(mon.maxHp));
        this._emitHeld(fighter, mon, mon.heldItem, 1);
        this._say(`${mon.species} recovered with ${Items.label(mon)}.`);
      }
    }
  }

  // HandleMysteryberry: player then enemy. The cart scans the PARTY moves and
  // PP, which a transformed monster never spends: for one the scan is of the
  // party list Transform put aside (`preTransform.moves`) and the copies are
  // not touched -- its owner is told once Transform is undone. A sheet that
  // arrived transformed carries no party list and keeps the berry.
  _heldMysteryberry(only = null) {
    for (const fighter of this.fighters) {
      const mon = inSet(only, fighter) ? activeMon(fighter) : null;
      const saved = mon && mon.transformed && mon.preTransform ? mon.preTransform : null;
      if (mon && (saved || !mon.transformed) && Items.holds(mon, Items.RESTORE_PP)) {
        const party = saved ? saved.moves : mon.moves;
        let slot = null;
        for (let i = 1; i <= party.length; i += 1) {
          if (party[i - 1].pp <= 0) { slot = i; break; }
        }
        if (slot !== null) {
          const move = party[slot - 1];
          move.pp += Effects.moveKey(move) === 'SKETCH' ? 1 : 5;
          if (int(move.maxPp, 0) < move.pp) move.maxPp = move.pp;
          if (saved) {
            saved.ppTouched = true;
          } else {
            this._emitMoves(fighter, mon, fighter.active);
          }
          const name = Items.label(mon);
          const item = Items.take(mon);
          this._emitHeld(fighter, mon, item.heldItem, 0);
          this._say(`${mon.species} recovered PP using ${name}.`);
        }
      }
    }
  }

  // HandleStatBoostingHeldItems: player then enemy.
  _heldStatBoosts(only = null) {
    for (const fighter of this.fighters) {
      const mon = inSet(only, fighter) ? activeMon(fighter) : null;
      const held = mon ? Items.effect(mon) : { effect: null };
      const stat = held.effect && has(Items.STAT_UP, held.effect) ? Items.STAT_UP[held.effect] : null;
      if (stat) {
        const before = Effects.clampStage(mon.stages[stat]);
        const after = Effects.clampStage(before + 1);
        if (after !== before) {
          const name = Items.label(mon);
          const item = Items.take(mon);
          mon.stages[stat] = after;
          Effects.dropSnap(mon);
          this._emitHeld(fighter, mon, item.heldItem, 0);
          this._say(`${mon.species}'s ${name} activated!`);
          const text = `${mon.species}'s ${Effects.STAT_LABELS[stat] || stat} rose`;
          this._say(text);
          this._emit('stat', {
            slot: fighter.slot, side: fighter.side, amount: after, stage: after, text,
          });
        }
      }
    }
  }

  // HandleHealingItems: the enemy's items first (side b, then side a), each
  // asked HP berry, then status berry, then confusion berry.
  _heldHealing(only = null) {
    for (const side of ['b', 'a']) {
      for (const fighter of this.bySide[side]) {
        const mon = inSet(only, fighter) ? activeMon(fighter) : null;
        if (mon) {
          this._hpBerry(fighter, mon);
          this._statusBerry(fighter, mon);
          this._confusionBerry(fighter, mon);
        }
      }
    }
  }

  // ------------------------------------------------------------------
  // obedience (BattleCommand_CheckObedience; the Lua twin cites the lines)
  // ------------------------------------------------------------------

  // `.rand1` / `.rand2`.
  _obeyDraw(span, swapped) {
    let r = 0;
    for (let n = 0; n < REDRAW_LIMIT; n += 1) {
      r = this.rng.byte();
      if (swapped) r = Items.swap(r);
      if (r < span) return r;
    }
    return r % span;
  }

  // `.UseInstead`: a 1-based slot, or null.
  _obeyInstead(mon, selected) {
    if (mon.moves.length <= 1) return null;
    if (mon.disable && mon.disable.turns > 0) return null;
    let total = 0;
    for (const m of mon.moves) total += Math.max(0, int(m.pp, 0));
    const chosen = mon.moves[(selected || 0) - 1];
    if ((chosen ? chosen.pp : 0) === total) return null;
    const rows = Math.min(4, mon.moves.length);
    for (let n = 0; n < REDRAW_LIMIT; n += 1) {
      const r = this.rng.byte() % 4;
      if (r < rows && (r + 1) !== selected && mon.moves[r].pp > 0) return r + 1;
    }
    return null;
  }

  // `.EndDisobedience`.
  _disobeyed(fighter, mon) {
    mon.lastMoveIndex = 0;
    mon.lastCounterMove = null;
    return 'stop';
  }

  // `.DoNothing`.
  _loaf(fighter, mon) {
    this._say(`${mon.species}${LOAF_LINES[this.rng.byte() % 4]}`);
    return this._disobeyed(fighter, mon);
  }

  // null when the monster obeys, 'stop', or the 1-based slot it uses instead.
  // Never asked for a Bide's release: StoreEnergy skips past checkobedience
  // (`jp SkipToBattleCommand`), so only Bide's first use is checked.
  _obey(fighter, mon, move) {
    if (!fighter.badgeRules || mon.traded !== true) return null;
    if (fighter.choice && fighter.choice.bideRelease) return null;
    if (mon.charging && Effects.isCharge(mon.charging.effect)) return null;
    if (mon.thrashing) return null;
    // BattleCommand_CheckRollout skips `checkobedience` on a roll in progress.
    if (mon.rollout && mon.rollout.active) return null;
    const cap = Items.obedienceCap(fighter.badges);
    const level = mon.level;
    if (cap >= level) return null;
    const span = Math.min(255, cap + level);
    if (this._obeyDraw(span, true) < cap) return null;

    // IgnoreSleepOnly: Snore or Sleep Talk, chosen while asleep (the cart's
    // ellipsis glyph is three dots here: Wire.text has no such glyph).
    if (mon.status === 'sleep' && has(Items.SLEEP_BYPASS, Effects.moveKey(move))) {
      this._say(`${mon.species} ignored orders...sleeping!`);
      return 'stop';
    }

    if (this._obeyDraw(span, false) < cap) {
      const slot = this._obeyInstead(mon, fighter.choice ? fighter.choice.move : null);
      if (slot !== null) return slot;
      return this._loaf(fighter, mon);
    }

    const over = level - cap;
    const r = Items.swap(this.rng.byte());
    if (r < over) {
      // `.Nap`: the status byte is overwritten, whatever it held.
      let turns = 0;
      for (let n = 0; n < REDRAW_LIMIT; n += 1) {
        turns = Items.napTurns(this.rng.byte());
        if (turns !== 0) break;
      }
      if (turns === 0) turns = 1;
      Effects.setStatusOn(mon, fighter, 'sleep');
      mon.statusTurns = turns;
      const text = `${mon.species} began to nap!`;
      this._say(text);
      this._emit('status', {
        slot: fighter.slot, side: fighter.side, status: STATUS_TO_WIRE.sleep, text,
      });
      return this._disobeyed(fighter, mon);
    }
    if (r - over >= over) return this._loaf(fighter, mon);

    // "won't obey!" and HitConfusion, past the monster's own substitute.
    this._say(`${mon.species} won't obey!`);
    const folded = this._selfHitStats(fighter, mon, move);
    const damage = Status.selfHitDamage({
      level: mon.level, attack: folded.attack, defense: folded.defense,
      itemBoostPercent: this._typeBoostOf(mon, move),
    });
    this._say(`${mon.species} hurt itself in confusion`);
    this._damage(fighter, mon, damage, null, true);
    return this._disobeyed(fighter, mon);
  }

  // ParsePlayerAction / ParseEnemyAction, as the turn's actions are read and
  // before any runs: rage and its counter survive only on a seat choosing Rage
  // again (no switch, item, run, lock-in or forced fill, no other move --
  // Struggle, Metronome and Mirror Move included); the FURY CUTTER count only
  // for FURY CUTTER again, the PROTECT count only for PROTECT / DETECT /
  // ENDURE; and a player's Bide ends on anything but its FIGHT (`.reset_bide`).
  _resetRage() {
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (!mon) continue;
      const choice = fighter.choice;
      let chosen = null;
      if (choice && choice.action === 'fight' && !fighter.forced
          && !choice.bideStore && !choice.bideRelease && !allPpEmpty(mon)) {
        chosen = mon.moves[choice.move - 1] || null;
      }
      const effect = chosen ? int(chosen.effect, 0) : null;
      if ((mon.raging || mon.rageCounter > 0) && !(effect !== null && Effects.isRage(effect))) {
        mon.raging = false;
        mon.rageCounter = 0;
      }
      if (effect !== Effects.FURY_CUTTER) mon.furyCutter = 0;
      if (effect !== Effects.PROTECT && effect !== Effects.ENDURE) mon.protectCount = 0;
      if (mon.bide && this._asksBide(fighter) && choice
          && !choice.bideStore && !choice.bideRelease) {
        mon.bide = null;
      }
    }
  }

  _resolveTurn() {
    this.phase = 'resolving';
    // Armed for the rare case resolution does not leave this phase in the same
    // call -- a throw mid-resolve used to leave the field wedged forever, and
    // the hub's handle() contains those throws so the clock has to finish the job.
    this.resolveDeadline = this.resolveTimeout > 0
      ? this.now + this.resolveTimeout : null;

    this._resetRage();
    // The actions that are not a move went first (`_wentFirst`).
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (choice && choice.action !== 'fight' && !choice.recharge) {
        this.actionOrder.set(fighter, 0);
      }
    }
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
    // advances in `_closeReplace`, once the successor is on the field.
    if (!this.result && this._anyMustReplace()) {
      this._openReplace();
      return;
    }

    if (!this.result) {
      this.turn += 1;
      this._openTurn();
    }
  }

  // Fleeing is a concession in 1v1/coop_pvp, a wild escape in *wild modes,
  // and a trainer refusal (no finish) everywhere else; see Effects.runEndsBattle.
  _resolveRuns() {
    const running = this.fighters.filter(
      (fighter) => fighter.choice && fighter.choice.action === 'run',
    );
    if (running.length === 0) return false;

    if (!Effects.runEndsBattle(this.mode)) {
      this._say("No! There's no running from a trainer battle!");
      return false;
    }

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

  // Transform undone (the Lua twin explains): what the monster was comes back
  // from `preTransform`. Returns whether a berry restored party PP while it
  // was transformed.
  _undoTransform(mon) {
    const saved = mon.preTransform;
    mon.transformed = false;
    mon.transformSpecies = null;
    mon.transformBase = null;
    if (!saved) return false;
    mon.preTransform = null;
    mon.stats = saved.stats;
    mon.types = saved.types;
    mon.moves = saved.moves;
    mon.dvs = saved.dvs;
    Effects.dropSnap(mon);
    return saved.ppTouched === true;
  }

  // What NewBattleMonStatus clears that this referee keeps on the monster (the
  // Lua twin explains): Transform, confusion, SUBSTATUS_TOXIC, a foe's
  // lock-on -- and from wave 3 PROTECT / ENDURE, ROLLOUT, DEFENSE CURL and the
  // FURY CUTTER and PROTECT counts. Returns `_undoTransform`'s answer.
  _clearSubstatus(mon) {
    mon.confusion = 0;
    if (mon.status === 'toxic') mon.status = 'poison';
    mon.lockOn = null;
    mon.justFrozen = null;
    mon.protect = null;
    mon.endure = null;
    mon.protectCount = 0;
    mon.furyCutter = 0;
    mon.rollout = null;
    mon.curled = null;
    return this._undoTransform(mon);
  }

  // PursuitSwitch as a player withdraws a monster (the Lua twin explains):
  // each foe whose PURSUIT is aimed at the seat takes its whole turn now, and
  // its later one is spent.
  _pursue(fighter) {
    if (!isPlayerSeat(this.mode, fighter)) return;
    for (const foe of this._foes(fighter)) {
      if (this.result || !activeMon(fighter)) return;
      const choice = foe.choice;
      const foeMon = activeMon(foe);
      if (foeMon && choice && choice.action === 'fight' && !choice.pursued
          && !foe.forced && choice.target === fighter.slot && !allPpEmpty(foeMon)) {
        const move = foeMon.moves[choice.move - 1];
        if (move && int(move.effect, 0) === Effects.PURSUIT) {
          choice.pursued = true;
          this.actionOrder.set(foe, 0);
          this._useMove(foe, foeMon);
          this._drainExp();
        }
      }
    }
  }

  _resolveSwitches() {
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      if (choice && choice.action === 'switch') {
        // wPlayerIsSwitching / wEnemyIsSwitching, then the PURSUIT that chases
        // a player.
        fighter.switching = true;
        if (!fighter.mustReplace) this._pursue(fighter);
        const mon = monAt(fighter, choice.slot);
        if (mon && mon.hp > 0) {
          const outIndex = fighter.active;
          const outgoing = outIndex ? monAt(fighter, outIndex) : null;
          let touched = false;
          if (outgoing && outgoing !== mon) touched = this._clearSubstatus(outgoing);
          fighter.active = choice.slot;
          fighter.mustReplace = null;
          // The seat's monster changed: its own participation set resets and
          // the standing opposition re-marks into it, while the incoming
          // monster joins the sets of the foes it is now in against.
          this._refield(fighter);
          // A send-out brings no stage with it (ResetPlayerStatLevels): the
          // levels belong to the side's field position on the cart, and a
          // monster coming back in must not find the ones it left with.
          Effects.resetStages(mon);
          mon.charging = null;
          mon.invulnerable = false;
          mon.thrashing = null;
          mon.raging = false;
          mon.rageCounter = 0;
          mon.trapped = null;
          mon.bide = null;
          mon.substitute = 0;
          mon.mist = false;
          mon.focusEnergy = false;
          mon.xAccuracy = false;
          mon.leechSeed = null;
          mon.disable = null;
          mon.minimized = false;
          this._clearSubstatus(mon);
          // NewBattleMonStatus / NewEnemyMonStatus: a send-out clears BOTH
          // sides' last counter moves.
          mon.lastCounterMove = null;
          this._forgetFoesLastMoves(fighter);
          this._clearTrapsFrom(fighter.slot);
          this._switchInStats(fighter, mon);
          // `mon` is the index the referee just fielded -- `choice.slot`,
          // already normalised to a party position by `_normaliseChoice`. This
          // is the one that matters most: a forced post-faint replacement lands
          // here too, so without it a seat holding two of a species re-fields
          // the fallen copy on the client while the referee holds the living
          // one.
          this._emit('switch', {
            slot: fighter.slot, side: fighter.side, text: mon.species,
            speciesId: mon.speciesId, level: mon.level,
            mon: choice.slot - 1,
          });
          this._emit('send', {
            slot: fighter.slot, side: fighter.side, hp: mon.hp, maxHp: mon.maxHp,
            text: mon.species,
            speciesId: mon.speciesId, level: mon.level,
            mon: choice.slot - 1,
            status: mon.status && has(STATUS_TO_WIRE, mon.status)
              ? STATUS_TO_WIRE[mon.status] : undefined,
            confused: (mon.confusion && mon.confusion > 0) ? 1 : undefined,
          });
          // The party PP a Mysteryberry restored under Transform.
          if (touched) this._emitMoves(fighter, outgoing, outIndex);
        }
      }
    }
  }

  // A send-out or a faint at `slot` ends the wraps its monster held (every
  // send-out clears both wrap counts on the cart).
  _clearTrapsFrom(slot) {
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (mon && mon.trapped && mon.trapped.fromSlot === slot) mon.trapped = null;
    }
  }

  // The other half of that send-out: the seats across the field forget what
  // they last used (wLastEnemyCounterMove / wLastPlayerCounterMove).
  _forgetFoesLastMoves(fighter) {
    for (const foe of this._foes(fighter)) {
      const mon = activeMon(foe);
      if (mon) mon.lastCounterMove = null;
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
    this._orderActors(balls);
    for (const actor of balls) {
      if (this.result) return;
      this._resolveOneItem(actor.fighter);
    }
  }

  // Sort actors by priority bracket (desc), then a Quick Claw that fired, then
  // active-mon speed (desc), then field order; tied groups flip on one RNG byte
  // >= TIE_BREAK_ROLL. Shared by fights and ball throws -- a ball carries no
  // `priority` and no `clawParam`, so every thrower sits in one bracket, rolls
  // no claw, and the order is Speed's, as it always was.
  //
  // pokecrystal's DetermineMoveOrder for two battlers: CompareMovePriority,
  // then (`.equal_priority`) each side's Quick Claw roll, then the Speed
  // compare, then the coin flip. A Quick Claw is a roll *inside* a bracket, so
  // it sits between the bracket key and the Speed key here, drawn before the
  // tie-break bytes (`_quickClaws`).
  _orderActors(actors) {
    if (actors.length <= 1) return;

    this._quickClaws(actors);

    const bracket = (actor) => (actor.priority === undefined ? 0 : actor.priority);
    const claw = (actor) => (actor.claw ? 1 : 0);
    actors.sort((x, y) => {
      if (bracket(x) !== bracket(y)) return bracket(y) - bracket(x);
      if (claw(x) !== claw(y)) return claw(y) - claw(x);
      if (x.speed !== y.speed) return y.speed - x.speed;
      return x.order - y.order; // field order: side a, then side b
    });

    // One byte per group of actors in one bracket, of one Quick Claw standing,
    // at one Speed, spent only when the group is actually tied, so an ordinary
    // turn between two different speeds costs no draw at all on either runtime.
    let i = 0;
    while (i < actors.length) {
      let j = i;
      while (j < actors.length - 1 && actors[j + 1].speed === actors[i].speed
             && bracket(actors[j + 1]) === bracket(actors[i])
             && claw(actors[j + 1]) === claw(actors[i])) j += 1;
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
        // Wild modes seat exactly one monster on side b, so "the first
        // living foe" and "the only foe" are the same seat -- no aim to
        // spread.
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
            if (fighter.side === BADGE_SIDE) this._payDayOutcome(finish);
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
          spe: 'SPEED', spa: 'SP.ATK', spd: 'SP.DEF',
        })[result.stat] || 'STAT';
        if (result.stat === 'hp' && result.delta > 0) {
          this._emit('drain', {
            slot: fighter.slot, side: fighter.side,
            // ...and what the bar is now out of: an HP UP moves the maximum
            // itself, so a client told only the new HP would draw the rise
            // against the old ceiling.
            amount: result.delta, hp: mon.hp, maxHp: mon.maxHp,
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
      } else if (mon.hp <= 0 && Effects.itemFailsOnFainted(effect)) {
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
            Effects.dropSnap(mon);
            const label = ({
              atk: 'ATTACK', def: 'DEFENSE', spe: 'SPEED',
              spa: 'SP.ATK', spd: 'SP.DEF', acc: 'ACCURACY', eva: 'EVASION',
            })[stat] || 'STAT';
            this._say(`${mon.species}'s ${label} rose`);
            this._emit('stat', {
              slot: fighter.slot, side: fighter.side,
              amount: after, stage: after, text: `${mon.species}'s ${label} rose`,
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
              // Fielded mon only: a bench Ether must not redraw FIGHT.
              if (partyIdx === fighter.active) this._emitMoves(fighter, mon, partyIdx);
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
            if (partyIdx === fighter.active) this._emitMoves(fighter, mon, partyIdx);
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
        let clearedConfusion = false;
        if (effect.clearAllStatus) {
          if (mon.status) {
            mon.status = null;
            mon.statusTurns = 0;
            cleared = true;
          }
          if (mon.confusion && mon.confusion > 0) {
            mon.confusion = 0;
            clearedConfusion = true;
          }
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
        if (clearedConfusion) {
          this._emit('status', {
            slot: fighter.slot, side: fighter.side, confused: 0,
            text: `${mon.species} recovered`,
          });
        }
        if (!applied && !healed && !cleared && !clearedConfusion) {
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

  // A recharging seat's turn (CheckTurn's first test): "must recharge", the
  // bit cleared, CantMove -- or, when a flinch or a freeze cancelled the
  // recharge before this slot came, the gates.
  _rechargeTurn(fighter, mon) {
    if (mon.mustRecharge) {
      mon.mustRecharge = false;
      this._say(`${mon.species} must recharge`);
      this._cantMove(mon);
      return;
    }
    if (!this._runGates(fighter, mon, mon.rechargeMove || null)) this._cantMove(mon);
  }

  _resolveFights() {
    const actors = [];
    for (const fighter of this.fighters) {
      const choice = fighter.choice;
      const mon = activeMon(fighter);
      // A recharge is an actor too (`_lockedChoice`); a PURSUIT already
      // spent chasing a switch (`_pursue`) is not.
      if (choice && (choice.action === 'fight' || choice.recharge) && mon
          && !choice.pursued) {
        const held = Items.effect(mon);
        actors.push({
          fighter,
          mon, // pinned: see the skip in the loop
          priority: this._priorityOf(fighter, mon),
          speed: this._speedOf(fighter, mon),
          order: actors.length + 1,
          // A Quick Claw holder's parameter, for `_quickClaws`; null otherwise.
          clawParam: held.effect === Items.QUICK_CLAW ? held.param : null,
        });
      }
    }
    if (actors.length === 0) return;

    this._orderActors(actors);
    actors.forEach((actor, i) => this.actionOrder.set(actor.fighter, i + 1));

    for (const actor of actors) {
      if (this.result) break;
      // The monster that chose is the only one allowed to act: if it fainted to
      // a faster attacker, the replacement that came in behind it does not
      // inherit the turn.
      if (activeMon(actor.fighter) === actor.mon) {
        if (actor.fighter.choice.recharge) {
          this._rechargeTurn(actor.fighter, actor.mon);
        } else {
          this._useMove(actor.fighter, actor.mon);
        }
      }
      // Finalize after each action (not inside `_faint`) so KO + recoil / explode
      // on the same move can still mutual-faint into a draw, while an empty-bench
      // KO still stops the slower seat from acting. The action's faint batch is
      // complete here, and that is the earliest moment its spoils can be counted
      // without paying a monster the same action was still killing (`_drainExp`).
      this._drainExp();
      if (!this.result) this._checkOver();
    }
    this._endProtection();
  }

  // CheckOpponentWentFirst widened to a field (the Lua twin explains): seat
  // `a` acted before seat `b` this turn; no recorded action reads as 0.
  _wentFirst(a, b) {
    const pa = a && this.actionOrder.has(a) ? this.actionOrder.get(a) : 0;
    const pb = b && this.actionOrder.has(b) ? this.actionOrder.get(b) : 0;
    return pa < pb;
  }

  // EndOpponentProtectEndureDestinyBond's PROTECT / ENDURE, widened to a
  // field: they guard the rest of the turn's moves and are gone once those
  // are done (the Lua twin explains).
  _endProtection() {
    for (const fighter of this.fighters) {
      for (const mon of fighter.mons) {
        mon.protect = null;
        mon.endure = null;
      }
    }
  }

  // HitSelfInConfusion (pokecrystal engine/battle/effect_commands.asm:
  // 2864-2898) and the head of the BattleCommand_DamageCalc it falls into
  // (:2900-2915): the confused monster's own battle Attack against its own
  // battle Defense -- stage, badge and burn, as any hit reads them -- that
  // Defense doubled by its OWN side's Reflect, both folded by TruncateHL_BC,
  // and the Defense halved again when the move it SELECTED is Explosion /
  // Self-Destruct, because DamageCalc's EFFECT_SELFDESTRUCT check reads
  // BATTLE_VARS_MOVE_EFFECT and that is still the selected move (a cart bug,
  // docs/bugs_and_glitches.md, kept). No crit: HitConfusion clears
  // wCriticalHit before it calls in. Returns { attack, defense }.
  _selfHitStats(fighter, mon, selected) {
    const attack = this._battleStat(fighter, mon, 'atk');
    let defense = this._battleStat(fighter, mon, 'def');
    if (this._screenUp(fighter.side, false)) defense *= 2;
    const folded = Damage.truncateStats(attack, defense, this._onePassTruncate());
    if (selected && Effects.isExplode(selected.effect)) {
      folded.defense = Math.max(1, Math.floor(folded.defense / 2));
    }
    return folded;
  }

  // One status gate (Status.beforeMove: its byte, its line, the counter it
  // ticks). Returns whether the monster may move past it. A freeze draws
  // nothing and never thaws here (HandleDefrost does, `_heldDefrost`); a
  // wake-up writes the status byte with no rebuild.
  _statusGate(fighter, mon) {
    if (mon.status === 'freeze') {
      this._say(`${mon.species} is frozen solid`);
      return false;
    }
    // Sleep's gate is the counter alone; only paralysis draws.
    const roll = mon.status === 'paralysis' ? this.rng.byte() : null;
    const gate = Status.beforeMove(
      { status: mon.status, turnsRemaining: mon.statusTurns }, roll,
    );
    if (!gate) return true;
    mon.statusTurns = int(gate.turnsRemaining, mon.statusTurns);
    if (gate.wokeUp) {
      Effects.setStatusOn(mon, fighter, null);
      mon.statusTurns = 0;
      this._emit('status', {
        slot: fighter.slot, side: fighter.side,
        text: `${mon.species} woke up`,
      });
    } else if (gate.fullyParalyzed) {
      this._say(`${mon.species} is fully paralyzed`);
    } else if (mon.status === 'sleep') {
      this._say(`${mon.species} is fast asleep`);
    }
    return gate.canMove;
  }

  // Returns false when a gate stopped the move. `selected` is the move the
  // monster is about to use (Struggle when every slot is empty): the sleep
  // gate's Snore / Sleep Talk exception, the confusion self-hit and the
  // disabled-move check read it the way the cart's CheckTurn and DamageCalc
  // do. CheckTurn's order (the Lua twin cites the lines): sleep, freeze, the
  // flinch (`.not_frozen`), the Disable count's tick (R2b's finding (f)),
  // confusion, the disabled move, and paralysis last.
  _runGates(fighter, mon, selected) {
    // CheckTurn's `.not_asleep`: a frozen monster that selected FLAME WHEEL or
    // SACRED FIRE (by move id) skips the freeze check, no byte and no line;
    // the move's own `defrost` thaws it after its hit (`_useMove`).
    const thawing = mon.status === 'freeze' && !!selected
      && has(Effects.FREEZE_BYPASS, Effects.moveKey(selected));
    if ((mon.status === 'sleep' || mon.status === 'freeze') && !thawing) {
      const asleep = mon.status === 'sleep';
      if (!this._statusGate(fighter, mon)) {
        // "Snore and Sleep Talk bypass sleep": told it is fast asleep, the
        // monster goes on to obedience and the move.
        if (!(asleep && mon.status === 'sleep' && selected
              && has(Items.SLEEP_BYPASS, Effects.moveKey(selected)))) {
          return false;
        }
      }
    }

    if (mon.flinch) {
      mon.flinch = false;
      this._say(`${mon.species} flinched`);
      return false;
    }

    if (mon.disable && mon.disable.turns > 0) {
      mon.disable.turns -= 1;
      if (mon.disable.turns <= 0) {
        mon.disable = null;
        this._say(`${mon.species}'s disabled no more!`);
      }
    }

    if (mon.confusion > 0) {
      // The self-hit's stats (`_selfHitStats`), built whether or not this
      // turn's byte lands on a self-hit: they draw nothing. Status.confusionTick
      // also takes `itemBoostPercent` -- DamageCalc's type-boost item scan, run
      // for the SELECTED move's type (STRUGGLE.typeId for Struggle), the other
      // cart bug.
      const folded = this._selfHitStats(fighter, mon, selected);
      const gate = Status.beforeMove({
        status: 'confusion',
        turnsRemaining: mon.confusion,
        level: mon.level,
        attack: folded.attack,
        defense: folded.defense,
        itemBoostPercent: this._typeBoostOf(mon, selected),
      }, this.rng.byte());
      if (gate) {
        mon.confusion = int(gate.turnsRemaining, 0);
        // CheckTurn's `dec [hl]` on this field position's confuse count.
        fighter.confuseCount = mon.confusion;
        if (gate.snappedOut) {
          this._say(`${mon.species} snapped out of confusion`);
          this._emit('status', {
            slot: fighter.slot, side: fighter.side, confused: 0,
            text: `${mon.species} snapped out of confusion`,
          });
        } else if (gate.selfHit) {
          this._say(`${mon.species} hurt itself in confusion`);
          // `ld c, TRUE / call DoPlayerDamage`: the self-hit skips the user's
          // own substitute and comes off its HP.
          this._damage(fighter, mon, gate.selfDamage || 0, null, true);
          return false;
        }
        if (!gate.canMove) return false;
      }
    }

    // MoveDisabled: Struggle is no slot, so it is never the disabled move.
    const choice = fighter.choice;
    if (selected !== STRUGGLE && choice && mon.disable && mon.disable.turns > 0
        && mon.disable.moveIndex === choice.move) {
      this._say(`${moveLabel(mon.moves[choice.move - 1])} is disabled`);
      return false;
    }

    if (mon.status === 'paralysis') {
      if (!this._statusGate(fighter, mon)) return false;
    }

    return true;
  }

  // A status or a confusion this move's effect just put on `targetMon`, and
  // the held item the cart asks about it straight away (UseHeldStatusHealingItem
  // at the end of every status-inflicting command, UseConfusionHealingItem at
  // the end of FinishConfusingTarget). A confusion that lands also becomes this
  // field position's confuse count.
  _afterInfliction(targetFighter, targetMon, before) {
    if (!(targetFighter && targetMon) || targetMon.hp <= 0) return;
    if (targetMon.status && !before.status) {
      this._statusBerry(targetFighter, targetMon);
    }
    if (targetMon.confusion > 0 && before.confusion === 0) {
      targetFighter.confuseCount = targetMon.confusion;
      this._confusionBerry(targetFighter, targetMon);
    }
  }

  // Every monster on the field, in field order (Haze's reach).
  _fieldMons() {
    const out = [];
    for (const fighter of this.fighters) {
      const mon = activeMon(fighter);
      if (mon) out.push(mon);
    }
    return out;
  }

  // Whether a move's matchup against `defender` is 0 (`stab`'s
  // wTypeModifier). Struggle is typeless.
  _immuneTo(move, defender) {
    if (move === STRUGGLE) return false;
    for (const pct of this._typePercents(move.type, defender)) {
      if (pct <= 0) return true;
    }
    return false;
  }

  // `move` is the sheet move in use: its id is MinimizeDropSub's `cp MINIMIZE`.
  // Returns Effects.applyPrimary's result.
  _applyPrimary(fighter, mon, targetFighter, targetMon, moveIndex, effectId, move) {
    const before = { status: targetMon.status, confusion: targetMon.confusion };
    const result = Effects.applyPrimary({
      effectId,
      rng: this.rng,
      userMon: mon,
      targetMon,
      userFighter: fighter,
      targetFighter,
      moveIndex,
      statusToWire: STATUS_TO_WIRE,
      userScreens: this.screens[fighter.side],
      computerMover: isComputerSeat(this.mode, fighter),
      moveKey: Effects.moveKey(move),
      moveImmune: this._immuneTo(move, targetMon),
      poisonType: this.poisonType,
      grassType: this.grassType,
      fieldMons: this._fieldMons(),
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
    this._afterInfliction(targetFighter, targetMon, before);
    return result;
  }

  // A primary stat-down move whose `checkhit` missed -- its accuracy byte, or a
  // target out of reach in the sky or underground (`.FlyDigMoves`) -- still
  // runs its `attackdown`: the status scripts (AttackDown and the rest, data/
  // moves/effects.asm) have no `failuretext` between the two, and checkhit only
  // sets wAttackMissed, which BattleCommand_StatDown reads at `.DidntMiss`,
  // after its `.ComputerMiss` byte. So the computer draws that byte for a
  // missed stat-down move too, unless Mist or a stage at -6 stopped the routine
  // first (Effects.statDownGate). Its verdict changes nothing -- the move has
  // failed either way. A *DownHit that misses never gets here: its
  // `failuretext` ends the script first. Returns StatDownFailText's line for a
  // primary stat-down move, null for any other (the Lua twin explains).
  _statDownAfterMiss(fighter, defender, effectId) {
    const stat = Effects.primaryStatDown(effectId);
    if (!stat) return null;
    const line = Effects.statDownMissLine(defender, stat);
    if (isComputerSeat(this.mode, fighter)) {
      Effects.statDownGate(this.rng, defender, stat, true, effectId, defender.lockOn === true);
    }
    return line;
  }

  // The secondary effect of a damaging move whose `effectchance` byte has
  // already been drawn (`hit`, see `_useMove`). `move` is the sheet move that
  // landed: its type goes to Effects.applySide with the two named types
  // (CheckIfTargetIsPoisonType's POISON, CheckMoveTypeMatchesTarget's NORMAL
  // exemption) and whether the move is the computer's -- BattleCommand_StatDown
  // draws its extra miss on the enemy's turn outside a link battle, the seat
  // isComputerSeat names.
  _applySide(fighter, mon, targetFighter, targetMon, effectId, hit, move) {
    const before = { status: targetMon.status, confusion: targetMon.confusion };
    const result = Effects.applySide({
      effectId,
      hit: hit === true,
      rng: this.rng,
      userMon: mon,
      targetMon,
      userFighter: fighter,
      targetFighter,
      statusToWire: STATUS_TO_WIRE,
      moveType: move ? move.type : undefined,
      poisonType: this.poisonType,
      normalType: this.normalType,
      computerMover: isComputerSeat(this.mode, fighter),
      // The bytes the effect draws itself (TRI ATTACK, DEFENSE_DOWN_HIT's
      // second `effectchance`), and RaiseStat's 999 test's badges.
      chance: move ? move.chance : undefined,
      userBadges: fighter.badges,
      targetSafeguard: this._safeguarded(targetFighter),
      sunny: this._weatherKind() === 'sun',
      targetWentFirst: this._wentFirst(targetFighter, fighter),
    });
    for (const text of result.messages || []) this._say(text);
    for (const entry of result.events || []) {
      this._emit(entry.kind, entry.fields);
    }
    this._afterInfliction(targetFighter, targetMon, before);
    // BattleCommand_FreezeTarget's tail once the berry left the freeze
    // standing: EndRechargeOpp and wEnemyJustGotFrozen (the Lua twin explains).
    if (targetMon.hp > 0 && targetMon.status === 'freeze' && before.status !== 'freeze') {
      targetMon.mustRecharge = false;
      targetMon.justFrozen = true;
    }
  }

  // SafeCheckSafeguard / BattleCommand_CheckSafeguard: whether the side a seat
  // sits on has SAFEGUARD up.
  _safeguarded(fighter) {
    const screens = fighter ? this.screens[fighter.side] : null;
    return !!screens && int(screens.safeguard, 0) > 0;
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

  // usedmovetext (UsedMoveText): the move an action is now using becomes its
  // user's LAST_MOVE / LAST_COUNTER_MOVE -- what a foe's MIRROR MOVE copies.
  // A called move records itself; Struggle is kept as the STRUGGLE sentinel.
  // Cleared by ClearLastMove, `.EndDisobedience` and every send-out. The Lua
  // twin carries the long note.
  _recordLastMove(mon, move) {
    mon.lastCounterMove = move === STRUGGLE ? STRUGGLE : copyMove(move);
  }

  // The move a lock-in resolves to (CheckPlayerLockedIn's `.quit`): a charge's
  // release and a rampage's next turn re-use the move that started them -- the
  // called one, when METRONOME or MIRROR MOVE called it -- never Struggle.
  _lockedMove(fighter, mon) {
    // A Bide's storing and release turns use BIDE: a called one's record, or
    // the slot -- never Struggle.
    const choice = fighter.choice;
    if (mon.bide && choice && (choice.bideRelease || choice.bideStore)) {
      return mon.bide.move || mon.moves[mon.bide.moveIndex - 1] || null;
    }
    const charge = mon.charging;
    if (charge && Effects.isCharge(charge.effect)) {
      return charge.move || mon.moves[charge.moveIndex - 1] || null;
    }
    const rampage = mon.thrashing;
    if (rampage && rampage.turns > 0) {
      return rampage.move || mon.moves[rampage.moveIndex - 1] || null;
    }
    // ROLLOUT's next roll (SUBSTATUS_ROLLOUT), the move that started it.
    const roll = mon.rollout;
    if (roll && roll.active) {
      return roll.move || mon.moves[roll.moveIndex - 1] || null;
    }
    return null;
  }

  // CantMove: every CheckTurn stop clears SUBSTATUS_BIDE, _RAMPAGE and
  // _CHARGED, and a FLY / DIG user comes back down; Gold's also clears
  // SUBSTATUS_ROLLOUT and the FURY CUTTER count, and EndTurn's ResetDamage
  // zeroes wCurDamage.
  _cantMove(mon) {
    mon.bide = null;
    mon.thrashing = null;
    if (mon.charging && Effects.isCharge(mon.charging.effect)) {
      mon.charging = null;
      mon.invulnerable = false;
    }
    if (mon.rollout) mon.rollout.active = false;
    mon.furyCutter = 0;
    this.curDamage = 0;
  }

  // The move a vanished monster is charging, upper-cased ("FLY" / "DIG"), or
  // null when it is on the field.
  _vanishedInto(mon) {
    if (!mon.invulnerable || !mon.charging) return null;
    const charge = mon.charging;
    let id = charge.moveId;
    if (!id && charge.move) id = charge.move.id;
    if (!id) {
      const slot = mon.moves && mon.moves[charge.moveIndex - 1];
      id = slot ? slot.id : null;
    }
    return Effects.moveKey(id);
  }

  // Whether this hit's doubling command fires (Effects.DOUBLE_VS_*).
  _doublesDamage(effectId, defender) {
    if (Effects.DOUBLE_VS_MINIMIZED[effectId]) return defender.minimized === true;
    if (Effects.DOUBLE_VS_FLYING[effectId]) return this._vanishedInto(defender) === 'FLY';
    if (Effects.DOUBLE_VS_UNDERGROUND[effectId]) return this._vanishedInto(defender) === 'DIG';
    return false;
  }

  // BattleCommand_EffectChance where the script has one right after
  // `checkhit` (Effects.drawsEffectChance): drawn hit or miss, skipped with no
  // byte by a substitute standing before the hit.
  _effectChance(move, effectId, behindSub) {
    if (!Effects.drawsEffectChance(effectId, move)) return false;
    return Effects.effectChance(this.rng, move.chance, behindSub) === true;
  }

  // One pass of the damage commands up to `damagevariation` (the Lua twin
  // carries the notes): `critical` (none at power 0 or with `opts.noCrit`),
  // the power commands (HIDDEN POWER's power and type, RETURN / FRUSTRATION,
  // MAGNITUDE's byte and line, REVERSAL's row; `opts.power` wins),
  // `damagestats`, `damagecalc`, TRIPLE KICK's kicks, `stab` (none for
  // Struggle and `opts.noStab`) and RAGE's multiplier. The roll is the
  // caller's (`_vary`). Returns { damage, crit, percents, immune, moveType }.
  _hitDamage(fighter, mon, target, defender, move, effectId, struggling, opts = {}) {
    let power = Math.max(0, int(move.power, 0));
    const isCrit = opts.noCrit ? false : this._critical(mon, move);

    let moveType = move.type;
    let typeName = this._typeIdOf(move.type);
    if (effectId === Effects.HIDDEN_POWER) {
      const hp = Effects.hiddenPower(mon.dvs);
      if (hp) power = hp.power;
      const index = hp ? typeIndexOf(this.typeIds, hp.type) : null;
      if (index !== null && index !== undefined) {
        moveType = index;
        typeName = hp.type;
      }
    } else if (effectId === Effects.RETURN) {
      power = Effects.happinessPower(mon.happiness);
    } else if (effectId === Effects.FRUSTRATION) {
      power = Effects.frustrationPower(mon.happiness);
    } else if (effectId === Effects.MAGNITUDE) {
      const m = Effects.magnitude(this.rng.byte());
      power = m.power;
      this._say(`Magnitude ${m.magnitude}!`);
    } else if (effectId === Effects.REVERSAL) {
      power = Effects.reversalPower(mon.hp, mon.maxHp);
    }
    if (opts.power !== undefined && opts.power !== null) power = opts.power;

    // Struggle skips BattleCommand_Stab's matchup loop with the rest of it, so
    // it is neutral against everything, a Ghost included; so are the scripts
    // with no `stab`.
    const noStab = struggling || !!opts.noStab;
    const percents = noStab ? [100] : this._typePercents(moveType, defender);
    const out = { damage: 0, crit: isCrit, percents, moveType };
    const stats = this._damageStats(fighter, mon, target, defender, moveType, effectId, isCrit);

    // DamageCalc's type-boost item scan: NORMAL for Struggle, HIDDEN POWER's
    // own type.
    const boostType = struggling ? STRUGGLE.typeId : typeName;
    let d = Damage.calc(mon.level, power, stats.attack, stats.defense, {
      crit: isCrit, itemBoostPercent: Items.typeBoostPercent(mon, boostType),
    });
    if (d === null) d = 0;
    if (opts.kicks !== undefined && opts.kicks !== null) d = Damage.multiply(d, opts.kicks);

    if (!noStab) {
      const stabbed = Damage.stab(d, {
        weatherTenths: Effects.weatherTenths(this._weatherKind(), typeName, effectId),
        // The attacker's own badges: a foe seat holds none (BADGE_SIDE).
        badgeTypeBoost: Effects.badgeTypeBoost(typeName, fighter.badges),
        stab: hasType(mon, moveType),
        typeEffect: percents,
      });
      d = stabbed.damage;
      if (stabbed.immune) { out.immune = true; return out; }
    }
    // BattleCommand_RageDamage: x(count + 1), after STAB, before the roll.
    if (Effects.isRage(effectId) && mon.rageCounter > 0) {
      d = Math.min(Damage.WORD_MAX, d * (mon.rageCounter + 1));
    }
    out.damage = d;
    return out;
  }

  // BattleCommand_Critical: nothing at power 0, otherwise one byte against
  // Gen 2's ladder with the attacker's item (Crit.level).
  _critical(mon, move) {
    if (Math.max(0, int(move.power, 0)) <= 0) return false;
    const critLevel = Crit.level({
      focusEnergy: mon.focusEnergy,
      highCritMove: move.highCrit === true,
      scopeLens: Items.holds(mon, Items.CRITICAL_UP),
      speciesItemBonus: Items.critSpeciesItem(this._battleSpecies(mon), mon.heldItem),
    });
    return Crit.check({
      criticalLevel: critLevel,
      roll: this.rng.below(Crit.chance(critLevel)),
    }).isCrit;
  }

  // BattleCommand_DamageStats for a move of chart type `moveType`: the attack
  // and defense registers DamageCalc multiplies. Returns { attack, defense }.
  _damageStats(fighter, mon, target, defender, moveType, effectId, isCrit) {
    const isSpecial = Effects.isSpecialType(moveType, this.specialTypes);
    const atkKey = isSpecial ? 'spa' : 'atk';
    const defKey = isSpecial ? 'spd' : 'def';

    // PlayerAttackDamage / EnemyAttackDamage (pokecrystal engine/battle/
    // effect_commands.asm:2532-2612, 2777-2855), in the cart's order.
    //
    // 1. The defender's battle stat (stage, its seat's badge), doubled when
    //    its SIDE has the screen up -- Reflect for a physical hit, Light
    //    Screen for a special one -- as a 16-bit value, before any fold.
    let defense = this._battleStat(target, defender, defKey);
    if (this._screenUp(target.side, isSpecial)) defense *= 2;
    // 2. The attacker's battle stat: stage, its seat's badge, burn.
    let attack = this._battleStat(fighter, mon, atkKey);
    // 3. CheckDamageStatsCritical (:2660-2700): a crit keeps the pair above
    //    only when the defender's stage is strictly LOWER than the
    //    attacker's; otherwise it reads the unmodified stats -- no stage, no
    //    badge, no burn and no screen.
    if (isCrit && !(Effects.clampStage(defender.stages[defKey])
                    < Effects.clampStage(mon.stages[atkKey]))) {
      attack = Math.max(1, int(mon.stats[atkKey], 1));
      defense = Math.max(1, int(defender.stats[defKey], 1));
    }
    // 4. ThickClubBoost (physical) / LightBallBoost (special) double the
    //    attack here, still 16-bit, which is why they can wrap past 1024
    //    when the fold below makes one pass (Items.speciesAttack).
    attack = Items.speciesAttack(mon, isSpecial, attack);
    // 5. TruncateHL_BC: both folded into a byte -- one pass in a link battle
    //    and on Gold / Silver, a loop on Crystal otherwise (K6).
    const folded = Damage.truncateStats(attack, defense, this._onePassTruncate());
    // 6. DittoMetalPowder on the folded pair (Items.metalPowder), and then
    //    BattleCommand_DamageCalc halves the defense for Explosion /
    //    Self-Destruct, at least 1 (:2904-2913).
    const powdered = Items.metalPowder(defender, folded.attack, folded.defense);
    attack = powdered.attack;
    defense = powdered.defense;
    if (Effects.isExplode(effectId)) {
      defense = Math.max(1, Math.floor(defense / 2));
    }
    return { attack, defense };
  }

  // BattleCommand_DamageVariation where the script puts it: one roll, drawn
  // only when the damage is 2 or more.
  _vary(damage) {
    if (!Damage.varies(damage)) return Math.max(0, int(damage, 0));
    return Damage.applyRoll(damage, this.rng.damageRoll());
  }

  // BattleCommand_CheckHit, in the cart's order (the Lua twin carries the
  // notes): `.DreamEater`, `.Protect` ("PROTECTING itself!"), `.DrainSub`,
  // `.LockOn`, `.FlyDigMoves` ('vanished'), `.ThunderRain`, X Accuracy and
  // EFFECT_ALWAYS_HIT, then Accuracy.js's byte domain -- the move's byte, or
  // BattleCommand_OHKO's, or THUNDER's in the sun -- where a byte of 255
  // draws nothing. Returns 'hit', 'miss', 'vanished' or 'protected'.
  _checkHit(mon, defender, move, effectId, ohkoByte) {
    if (effectId === Effects.idOf('DREAM_EATER_EFFECT') && defender.status !== 'sleep') {
      return 'miss';
    }
    if (defender.protect) {
      this._say(`${defender.species}'s PROTECTING itself!`);
      return 'protected';
    }
    if (Effects.isDrain(effectId) && int(defender.substitute, 0) > 0) return 'miss';

    if (defender.lockOn) {
      defender.lockOn = null;
      if (!(this._vanishedInto(defender) === 'FLY'
            && Effects.LOCK_ON_SKY_MISS[Effects.moveKey(move)] === true)) {
        return 'hit';
      }
    }

    if (defender.invulnerable
        && !Effects.hitsInvulnerable(this._vanishedInto(defender), move)) {
      return 'vanished';
    }

    const weather = this._weatherKind();
    if (effectId === Effects.THUNDER && weather === 'rain') return 'hit';
    if (mon.xAccuracy === true || effectId === Effects.idOf('SWIFT_EFFECT')) return 'hit';

    let base = ohkoByte;
    if (base === null || base === undefined) {
      base = (effectId === Effects.THUNDER && weather === 'sun')
        ? Accuracy.THUNDER_SUN_BYTE : Accuracy.moveByte(move.accuracy);
    }
    const held = Items.effect(defender);
    const stages = mon.stages && typeof mon.stages === 'object' ? mon.stages : {};
    const byte = Accuracy.finalByte(base, {
      accuracyStage: stages.acc,
      evasionStage: defender.stages.eva,
      brightPowder: held.effect === Items.BRIGHTPOWDER ? held.param : null,
      identified: defender.identified === true,
    });
    if (!Accuracy.draws(byte)) return 'hit';
    return Accuracy.hitByte(byte, this.rng.byte()) ? 'hit' : 'miss';
  }

  // BattleCommand_SleepTalk's pick (the Lua twin carries the notes): fails
  // awake, on an empty second slot and with nothing callable; otherwise
  // BattleRandom & 3 until it names a move that is not SLEEP TALK, the
  // disabled move or a two-turn move. Returns the move, or null.
  _sleepTalkPick(mon, using) {
    if (mon.status !== 'sleep') return null;
    const moves = mon.moves;
    if (!moves[1]) return null;
    let disabledKey = null;
    if (mon.disable && mon.disable.turns > 0 && moves[mon.disable.moveIndex - 1]) {
      disabledKey = Effects.moveKey(moves[mon.disable.moveIndex - 1]);
    }
    const usingKey = Effects.moveKey(using);
    const callable = (m) => {
      const key = Effects.moveKey(m);
      if (key === usingKey || key === disabledKey) return false;
      return !Effects.SLEEP_TALK_EXCLUDED[int(m.effect, 0)];
    };
    let usable = false;
    for (let i = 0; i < Math.min(4, moves.length); i += 1) {
      if (callable(moves[i])) { usable = true; break; }
    }
    if (!usable) return null;
    for (let i = 0; i < REDRAW_LIMIT; i += 1) {
      const m = moves[this.rng.byte() % 4];
      if (m && callable(m)) return m;
    }
    return null;
  }

  _useMove(fighter, mon, opts = {}) {
    const choice = fighter.choice;
    // A move Metronome or Mirror Move called is not the turn's own move. The
    // gates already ran for the move that called it -- BattleCommand_Metronome
    // ends in ResetTurn, which re-enters DoMove past CheckTurn -- and it is
    // never Struggle, whatever PP the calling slot has left: Struggle is a
    // move, not a state of the user's PP, so the call that spent the last PP
    // takes no recoil.
    const called = opts.moveOverride !== undefined && opts.moveOverride !== null;
    // The move this action resolves to: a lock-in's (`_lockedMove`, a Bide's
    // included), else the synthetic STRUGGLE when every slot is empty -- an
    // empty sheet included -- else the chosen slot.
    let move = opts.moveOverride;
    let locked = null;
    if (!called) {
      locked = this._lockedMove(fighter, mon);
      if (locked) {
        move = locked;
      } else if (allPpEmpty(mon)) {
        move = STRUGGLE;
      } else {
        move = mon.moves[choice.move - 1];
      }
    }
    if (!move) return;
    const struggling = move === STRUGGLE;

    // A move used in place of a disobeyed one runs no CheckTurn of its own. A
    // stop is CantMove's (`_cantMove`). A Bide's storing turn runs CheckTurn
    // too, so a storing Bide a gate stops is over.
    const disobeyed = opts.disobeyed === true;
    if (!called && !disobeyed && !this._runGates(fighter, mon, move)) {
      this._cantMove(mon);
      return;
    }

    // BattleCommand_StoreEnergy, ahead of `checkobedience` and `usedmovetext`:
    // on a storing turn the line, and the move ends.
    if (choice.bideStore) {
      this._say(`${mon.species} is storing energy`);
      return;
    }

    // `checkobedience`, for the move the monster chose (`_obey`). A move it
    // uses instead is used in full under "used instead,", and then forgotten
    // as the last move (`.EndDisobedience`).
    if (!called && !disobeyed) {
      const verdict = this._obey(fighter, mon, move);
      if (verdict === 'stop') return;
      if (typeof verdict === 'number') {
        const saved = fighter.choice;
        fighter.choice = { action: 'fight', move: verdict, target: saved.target };
        this._useMove(fighter, mon, { disobeyed: true });
        fighter.choice = saved;
        mon.lastMoveIndex = 0;
        mon.lastCounterMove = null;
        return;
      }
    }

    // Resolved once, here, and used for the whole action: see `_retarget`.
    const target = this._retarget(fighter, choice.target);
    const defender = target && activeMon(target);
    if (!defender) {
      this._say(`${mon.species} has no target`);
      return;
    }
    // The seat actually swung at. Anything this action *records* for a later
    // turn (a charge's aim, a Bide's aim) records this and not `choice.target`,
    // so the release lands where the action went rather than on the seat that
    // was already empty when it started.
    const targetSlot = target.slot;

    const effectId = int(move.effect, 0);
    const releasing = mon.charging !== null && mon.charging !== undefined
      && Effects.isCharge(mon.charging.effect);
    // A rampage's next turn: the locked move again, no PP (DoTurn's
    // SUBSTATUS_RAMPAGE mask).
    const rampaging = locked !== null && !releasing
      && mon.thrashing !== null && mon.thrashing !== undefined;
    // ROLLOUT's next roll: CheckRollout skips past `doturn`, so no PP either.
    const rolling = locked !== null && !releasing && !rampaging
      && !!mon.rollout && mon.rollout.active === true;
    const mirrorCopy = opts.mirrorCopy === true;

    // BattleCommand_CheckRollout on a fresh ROLLOUT: the count back to 0.
    if (effectId === Effects.ROLLOUT && !rolling) {
      mon.rollout = {
        count: 0, active: false, moveIndex: choice.move,
        move: called ? copyMove(move) : null,
      };
    }

    if (!struggling && move.pp > 0 && !releasing && !rampaging && !rolling
        && !choice.bideRelease) {
      move.pp -= 1;
      // FIGHT reads the uploaded sheet. Publish whenever PP actually moved
      // (Transform/Mimic already emit via movesChanged). Skip an override
      // copy -- Metronome/Mirror already spent the real slot on the first call.
      if (!opts.moveOverride) this._emitMoves(fighter, mon, fighter.active);
    }

    // BattleCommand_CheckRampage on a rampage's next turn: the count goes
    // down, and when it runs out the rampage ends and the user is confused for
    // 2-3 turns -- before the move it still makes this turn -- unless its own
    // side's SAFEGUARD is up, which spares it the confusion and its byte.
    if (rampaging) {
      const rampage = mon.thrashing;
      rampage.turns -= 1;
      if (rampage.turns <= 0) {
        mon.thrashing = null;
        if (!this._safeguarded(fighter)) {
          const turns = Effects.rampageConfusion(this.rng);
          mon.confusion = turns;
          fighter.confuseCount = turns;
          this._say(`${mon.species} became confused`);
          this._emit('status', {
            slot: fighter.slot, side: fighter.side, confused: 1,
            text: `${mon.species} became confused`,
          });
        }
      }
    }

    // BattleCommand_SkipSunCharge: SOLARBEAM under the sun fires at once.
    const chargingUp = Effects.isCharge(effectId) && !mon.charging
      && !(effectId === Effects.SOLARBEAM && this._weatherKind() === 'sun');
    this._emit('anim', {
      slot: fighter.slot, side: fighter.side, text: move.id,
      amount: chargingUp ? 1 : undefined,
    });
    if (choice.bideRelease && mon.bide) {
      // StoreEnergy's release: "unleashed energy!", and no `usedmovetext`.
      this._say(`${mon.species} unleashed energy`);
    } else {
      this._say(`${mon.species}${disobeyed ? ' used instead, ' : ' used '}${moveLabel(move)}`);
      this._recordLastMove(mon, move);
    }

    if (choice.bideRelease && mon.bide) {
      const stored = mon.bide.stored;
      mon.bide = null;
      // BattleCommand_StoreEnergy's release, then `resettypematchup`,
      // `checkhit` and `bidefailtext` (R2b's finding (h); the Lua twin
      // explains): "It doesn't affect" for a matchup of 0, "But it failed"
      // for any other miss or nothing stored.
      const immune = this._immuneTo(move, defender);
      const verdict = this._checkHit(mon, defender, move, effectId);
      if (stored <= 0 || immune || verdict !== 'hit') {
        this.curDamage = 0;
        this._say(immune ? `It doesn't affect ${defender.species}` : 'But it failed');
        this._markLastMove(mon, choice.move);
        return;
      }
      // The damage taken doubled as a 16-bit pair, a carry pinning $ffff,
      // through applydamage, then `checkfaint`, `buildopponentrage` and
      // `kingsrock`.
      this._strike(target, defender, Math.min(Damage.WORD_MAX, 2 * stored));
      this._buildRage(defender);
      this._kingsRock(mon, move, effectId, defender);
      this._markLastMove(mon, choice.move);
      return;
    }

    // BattleCommand_MirrorMove: ClearLastMove, then the opponent's
    // LAST_COUNTER_MOVE -- failing with MirrorMoveFailedText when there is
    // none or the user already knows it (CheckUserMove) -- used in full
    // through ResetTurn.
    if (Effects.isMirrorMove(effectId) && !mirrorCopy) {
      mon.lastCounterMove = null;
      const copied = defender.lastCounterMove;
      if (!copied || knowsMove(mon, copied)) {
        this._say('The MIRROR MOVE failed!');
        this._markLastMove(mon, choice.move);
        return;
      }
      this._markLastMove(mon, choice.move);
      this._useMove(fighter, mon, {
        moveOverride: copied === STRUGGLE ? STRUGGLE : copyMove(copied),
        mirrorCopy: true,
      });
      return;
    }

    // BattleCommand_Metronome: ClearLastMove, then the pick -- redrawn while
    // it is a move the user already knows (`.GetMove`'s CheckUserMove); a pool
    // the user knows whole is "But nothing happened", as no pool is.
    const metronomeCall = opts.metronomeCall === true;
    if (Effects.isMetronome(effectId) && !metronomeCall) {
      mon.lastCounterMove = null;
      const pool = this.metronomePool;
      const open = (pool || []).some((entry) => !knowsMove(mon, entry));
      let pick = null;
      if (open) {
        for (let n = 0; n < REDRAW_LIMIT; n += 1) {
          const entry = pool[this.rng.byte() % pool.length];
          if (!knowsMove(mon, entry)) { pick = entry; break; }
        }
      }
      this._markLastMove(mon, choice.move);
      if (!pick) {
        this._say('But nothing happened');
        return;
      }
      this._useMove(fighter, mon, {
        moveOverride: copyMove(pick),
        metronomeCall: true,
      });
      return;
    }

    // BattleCommand_SleepTalk: ClearLastMove, the pick, and the picked move
    // used through ResetTurn like a METRONOME call.
    if (effectId === Effects.SLEEP_TALK && !opts.sleepTalkCall) {
      mon.lastCounterMove = null;
      const pick = this._sleepTalkPick(mon, move);
      this._markLastMove(mon, choice.move);
      if (!pick) {
        this._say('But it failed');
        return;
      }
      this._useMove(fighter, mon, {
        moveOverride: copyMove(pick),
        sleepTalkCall: true,
      });
      return;
    }

    // Charge / Fly: first turn sets state and ends; second turn releases.
    if (chargingUp) {
      mon.charging = {
        moveIndex: choice.move,
        effect: effectId,
        targetSlot,
        moveId: move.id,
        // The move a METRONOME or MIRROR MOVE called: the release next turn
        // is that move (`_lockedMove`), not a second call.
        move: called ? copyMove(move) : null,
      };
      if (Effects.vanishes(effectId, move)) mon.invulnerable = true;
      this._say(Effects.chargeMessage(mon, effectId, move.id));
      this._markLastMove(mon, choice.move);
      return;
    }

    if (mon.charging && Effects.isCharge(mon.charging.effect)) {
      mon.charging = null;
      mon.invulnerable = false;
    }

    // BattleCommand_Rampage, THRASH's `rampage` on its first turn, ahead of
    // `checkhit` (so on a miss too): 1-2 more turns, the called move kept. "No
    // rampage during Sleep Talk": a sleeping user starts none.
    if (Effects.isThrash(effectId) && !mon.thrashing && !rampaging
        && mon.status !== 'sleep') {
      mon.thrashing = {
        turns: Effects.rampageTurns(this.rng),
        moveIndex: choice.move,
        move: called ? copyMove(move) : null,
      };
    }

    // `effectchance` reads the target's substitute before the hit can break it.
    const subAtChance = (defender.substitute || 0) > 0;

    // BattleCommand_OHKO, the OHKO script's only accuracy check: a matchup of
    // 0 and a user below the target's level miss with nothing drawn; otherwise
    // the accuracy byte gains twice the level gap, held at $ff, and CheckHit
    // rolls against it. A hit is $ffff damage.
    const isOhko = Effects.isOhko(effectId);
    let ohkoByte = null;
    if (isOhko) {
      if (this._immuneTo(move, defender)) {
        this._say(`It doesn't affect ${defender.species}`);
        this._markLastMove(mon, choice.move);
        return;
      }
      if (mon.level < defender.level) {
        this._say(`${defender.species}'s unaffected!`);
        this._markLastMove(mon, choice.move);
        return;
      }
      ohkoByte = Math.min(255, Accuracy.moveByte(move.accuracy) + 2 * (mon.level - defender.level));
    }

    // A 0-power script runs its own command after `checkhit` (`_statusMove`);
    // every damaging one runs the damage commands in its script's order
    // (`_damagingMove`).
    if (move.power <= 0 && !Effects.isFixedDamage(effectId)) {
      this._statusMove(fighter, mon, target, defender, move, effectId, targetSlot, called);
      return;
    }
    this._damagingMove(fighter, mon, target, defender, move, effectId, {
      struggling, ohkoByte, subAtChance,
    });
  }

  // A 0-power move after `usedmovetext` (the Lua twin explains): the field
  // moves Turn runs itself, or `checkhit` (none for Effects.NO_CHECKHIT), then
  // the script's own command.
  _statusMove(fighter, mon, target, defender, move, effectId, targetSlot, called) {
    const choice = fighter.choice;
    if (Effects.FIELD_MOVES[effectId]) {
      if (effectId === Effects.PROTECT || effectId === Effects.ENDURE) {
        this._protect(fighter, mon, effectId);
      } else if (Effects.WEATHER_OF[effectId]) {
        this._startWeather(effectId);
      } else {
        this._timeHeal(fighter, mon, effectId);
      }
      this._markLastMove(mon, choice.move);
      return;
    }

    let verdict = 'hit';
    if (!Effects.NO_CHECKHIT[effectId]) {
      verdict = this._checkHit(mon, defender, move, effectId);
    }

    // BattleCommand_CheckSafeguard, after `checkhit` in the status scripts.
    if (Effects.CHECKS_SAFEGUARD[effectId] && this._safeguarded(target)) {
      this._say(`${defender.species} is protected by SAFEGUARD!`);
      this._markLastMove(mon, choice.move);
      return;
    }

    if (verdict !== 'hit') {
      // The line a miss ends on: LOCK-ON's own, a primary stat-down's
      // StatDownFailText after the computer's byte, else this referee's.
      let line;
      if (effectId === Effects.LOCK_ON) {
        line = Effects.didntAffectLine(defender);
      } else {
        line = this._statDownAfterMiss(fighter, defender, effectId);
      }
      if (!line) line = verdict === 'vanished' ? 'But it failed' : `${mon.species} missed`;
      this._say(line);
      this.curDamage = 0;
      this._markLastMove(mon, choice.move);
      return;
    }

    if (Effects.isBide(effectId) && !mon.bide) {
      mon.bide = {
        turns: Effects.bideTurns(this.rng),
        stored: 0,
        moveIndex: choice.move,
        targetSlot,
        // A called BIDE releases as BIDE, not as a second call (`_lockedMove`).
        move: called ? copyMove(move) : null,
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
    let cleared = false;
    if (Effects.handlesPrimary(effectId)) {
      const result = this._applyPrimary(fighter, mon, target, defender, choice.move,
        effectId, move);
      cleared = result.clearLastMove === true;
    } else {
      this._say('But nothing happened');
    }
    // Transform's ClearLastMove forgets the slot as well.
    if (cleared) {
      mon.lastMoveIndex = 0;
    } else {
      this._markLastMove(mon, choice.move);
    }
  }

  // The roll and the commands between `damagevariation` and `checkhit`: the
  // doublings, PURSUIT's x2 on a switching target's seat, FALSE SWIPE's cut.
  _finishDamage(effectId, damage, target, defender) {
    let d = this._vary(damage);
    if (this._doublesDamage(effectId, defender)) d = Damage.double(d);
    if (effectId === Effects.PURSUIT && target.switching) d = Damage.double(d);
    if (effectId === Effects.FALSE_SWIPE) d = Items.focusBand(d, defender.hp).amount;
    return d;
  }

  // A damaging move after `usedmovetext`, in its script's order (the Lua twin
  // carries the notes): COUNTER / MIRROR COAT, FUTURE SIGHT's use and BEAT UP
  // apart; the one-hit KO; the ConstantDamage rows (no crit, no roll);
  // REVERSAL (no crit, no roll); THRASH, the traps, PRESENT and the loops
  // (`checkhit` first); RAGE, ROLLOUT, FURY CUTTER and THUNDER (the roll after
  // `checkhit`); every other the crit, damage and roll before `checkhit`.
  // Then `failuretext` and the hits.
  _damagingMove(fighter, mon, target, defender, move, effectId, ctx) {
    const choice = fighter.choice;
    const { struggling, subAtChance } = ctx;
    if (effectId === Effects.COUNTER || effectId === Effects.MIRROR_COAT) {
      this._counter(fighter, mon, target, defender, move, effectId);
      return;
    }
    if (effectId === Effects.FUTURE_SIGHT) {
      this._foresee(fighter, mon, target, defender, move, effectId);
      return;
    }

    const isFixed = Effects.isFixedDamage(effectId);
    const isOhko = Effects.isOhko(effectId);
    const loops = Effects.isMultihit(effectId) || effectId === Effects.BEAT_UP;
    const hitFirst = loops || Effects.HIT_FIRST[effectId] === true;
    const rollLate = Effects.ROLL_AFTER_CHECKHIT[effectId] === true;
    let struck;
    let verdict;

    if (isOhko) {
      verdict = this._checkHit(mon, defender, move, effectId, ctx.ohkoByte);
      struck = {
        damage: Damage.WORD_MAX, crit: false, percents: this._typePercents(move.type, defender),
      };
    } else if (isFixed) {
      const fixed = Effects.fixedDamage({
        effectId, userMon: mon, targetMon: defender, power: move.power, rng: this.rng,
      });
      verdict = this._checkHit(mon, defender, move, effectId);
      struck = {
        damage: fixed === null ? 0 : fixed, crit: false, percents: [100],
        immune: this._immuneTo(move, defender), failed: fixed === null,
      };
    } else if (effectId === Effects.REVERSAL) {
      struck = this._hitDamage(fighter, mon, target, defender, move, effectId, struggling,
        { noCrit: true });
      verdict = this._checkHit(mon, defender, move, effectId);
    } else if (hitFirst) {
      verdict = this._checkHit(mon, defender, move, effectId);
    } else {
      struck = this._hitDamage(fighter, mon, target, defender, move, effectId, struggling);
      if (!rollLate && !struck.immune) {
        struck.damage = this._finishDamage(effectId, struck.damage, target, defender);
      }
      verdict = this._checkHit(mon, defender, move, effectId);
    }
    // The script's `effectchance`, right after `checkhit`, hit or miss.
    const effectHit = this._effectChance(move, effectId, subAtChance);

    if (effectId === Effects.BEAT_UP) {
      this._beatUp(fighter, mon, target, defender, move, effectId, verdict);
      return;
    }
    if (hitFirst) {
      if (effectId === Effects.PRESENT) {
        struck = this._present(fighter, mon, target, defender, move, effectId, verdict);
        if (struck.healed) {
          this._markLastMove(mon, choice.move);
          return;
        }
      } else {
        struck = this._hitDamage(fighter, mon, target, defender, move, effectId, struggling,
          { kicks: effectId === Effects.TRIPLE_KICK ? 1 : null });
      }
      struck.damage = this._vary(struck.damage);
    } else if (rollLate) {
      // RolloutPower / FuryCutter read wAttackMissed: a miss or a matchup of 0.
      const missed = verdict !== 'hit' || struck.immune === true;
      if (effectId === Effects.ROLLOUT) {
        struck.damage = this._rolloutPower(mon, struck.damage, missed);
      } else if (effectId === Effects.FURY_CUTTER) {
        struck.damage = this._furyCutter(mon, struck.damage, missed);
      }
      struck.damage = this._vary(struck.damage);
    }

    // BattleCommand_Snore: a user that is not asleep fails the move.
    if (effectId === Effects.SNORE && mon.status !== 'sleep') {
      this._say('But it failed');
      this._markLastMove(mon, choice.move);
      return;
    }

    if (struck.immune) {
      this.curDamage = 0;
      this._say(`It doesn't affect ${defender.species}`);
      if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
      this._markLastMove(mon, choice.move);
      return;
    }
    if (verdict !== 'hit') {
      this._say(verdict === 'vanished' ? 'But it failed' : `${mon.species} missed`);
      this.curDamage = 0;
      if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
      if (Effects.isJumpKick(effectId)) {
        const crash = Math.max(1, Math.floor(Math.max(0, int(struck.damage, 0)) / 8));
        this._say(`${mon.species} kept going and crashed!`);
        this._damage(fighter, mon, crash, null, true);
        this.curDamage = crash;
      }
      this._markLastMove(mon, choice.move);
      return;
    }
    if (struck.failed) {
      this._say('But it failed');
      if (Effects.isExplode(effectId)) this._faintUser(fighter, mon);
      this._markLastMove(mon, choice.move);
      return;
    }

    let effectiveness = 1;
    for (const pct of struck.percents) effectiveness = (effectiveness * pct) / 100;

    // The hits: each its own `critical` / `damagevariation` (TRIPLE KICK's
    // kick one higher each time), Focus Band roll, `checkfaint` and
    // `buildopponentrage`; MULTI_HIT's and TRIPLE KICK's counts drawn after
    // the first, the target still standing. `curDamage` is wCurDamage after
    // the hit's `applydamage` -- 0 when a substitute took it -- which RECOIL
    // reads.
    const multihit = Effects.isMultihit(effectId);
    let hits = Effects.fixedHits(effectId);
    let totalDealt = 0;
    let curDamage = 0;
    let made = 0;
    for (let index = 1; index <= hits; index += 1) {
      if (index > 1) {
        if (defender.hp <= 0) break;
        struck = this._hitDamage(fighter, mon, target, defender, move, effectId, struggling,
          { kicks: effectId === Effects.TRIPLE_KICK ? index : null });
        struck.damage = this._vary(struck.damage);
      }
      if (struck.crit) this._say('A critical hit');
      if (index === 1) {
        // OneHitKOText: criticaltext with wCriticalHit 2.
        if (isOhko) this._say("It's a one-hit KO!");
        if (effectiveness > 1) {
          this._say("It's super effective");
        } else if (effectiveness < 1) {
          this._say("It's not very effective");
        }
      }
      const hpBefore = defender.hp;
      this._strike(target, defender, struck.damage);
      curDamage = hpBefore - defender.hp;
      totalDealt += curDamage;
      if (multihit) this._buildRage(defender);
      if (index === 1 && defender.hp > 0) {
        if (effectId === 29) {
          hits = Effects.multiHitCount(this.rng);
        } else if (effectId === Effects.TRIPLE_KICK) {
          hits = Effects.tripleKickCount(this.rng);
        }
      }
      made = index;
    }

    // BattleCommand_EndLoop's `.done_loop`: "Hit N times!" when the loop runs
    // out with the target standing.
    if (multihit && defender.hp > 0) {
      this._say(`Hit ${made} times!`);
    }

    // FLAME WHEEL's and SACRED FIRE's `defrost`, before `checkfaint`: a frozen
    // user thaws, the status byte with no rebuild.
    if (Effects.DEFROSTS_USER[effectId] && mon.status === 'freeze') {
      Effects.setStatusOn(mon, fighter, null);
      mon.statusTurns = 0;
      const text = `${mon.species} was defrosted`;
      this._say(text);
      // No token: a `status` event without one is a cure (events.js).
      this._emit('status', { slot: fighter.slot, side: fighter.side, text });
    }

    // SapHealth: half of wCurDamage, at least 1.
    if (Effects.isDrain(effectId)) {
      this._heal(fighter, mon, Math.max(1, Effects.drainAmount(totalDealt)));
    }

    // BattleCommand_PayDay, on every hit that did not miss, for whoever used
    // it: the fight's one pot (`_payDayOutcome`).
    if (Effects.isPayDay(effectId)) {
      this.payDay += Effects.payDayCoins(mon.level);
      this._say('Coins scattered');
    }

    // The Thief script's `thief`, right after the damage (Items.THIEF), when
    // its `effectchance` left wEffectFailed clear: the chance byte landed and
    // no substitute stood.
    if (Effects.moveKey(move) === Items.THIEF && effectHit && !subAtChance) {
      this._thief(fighter, mon, target, defender);
    }

    // BattleCommand_Recoil, on every hit that did not miss: a quarter of
    // wCurDamage, at least 1 -- so 1 when a substitute took the hit --
    // straight off the user's HP, past its own substitute.
    if (struggling || Effects.isRecoil(effectId)) {
      const recoil = Effects.recoilAmount(curDamage);
      this._say(`${mon.species} is hit with recoil`);
      this._damage(fighter, mon, recoil, null, true);
    }

    if (!multihit) this._buildRage(defender);

    // The secondary effect, after `checkfaint` in every *Hit script: a target
    // the hit knocked out is never burned, poisoned or confused. `checkfaint`
    // reads the monster's HP and not its substitute's, so a hit the substitute
    // took goes on to the effect command, which asks about the substitute
    // itself (Effects.applySide).
    if (defender.hp > 0) {
      this._applySide(fighter, mon, target, defender, effectId, effectHit, move);
    }

    // A substitute absorbs HP (including the breaking hit), so totalDealt
    // stays 0. Do not then apply a foe primary onto the mon behind it.
    if (Effects.handlesPrimary(effectId) && totalDealt > 0) {
      this._applyPrimary(fighter, mon, target, defender, choice.move, effectId, move);
    }

    // BattleCommand_Rage: SUBSTATUS_RAGE on the user of a Rage that connected.
    // No lock-in: it lasts while the seat keeps choosing Rage (`_resetRage`).
    if (Effects.isRage(effectId)) {
      mon.raging = true;
    }

    // BattleCommand_TrapTarget, after `checkfaint`: a target with a wrap count
    // already, or a substitute standing now, is not trapped; otherwise the
    // count and the move's name for HandleWrap, and the cart's line.
    if (Effects.isTrapping(effectId) && defender.hp > 0 && !defender.trapped
        && int(defender.substitute, 0) <= 0) {
      defender.trapped = {
        turns: Effects.wrapCount(this.rng),
        fromSlot: fighter.slot,
        label: moveLabel(move, 'the trap'),
      };
      this._say(trapLine(move, mon, defender));
    }

    // BattleCommand_RechargeNextTurn, before `checkfaint`: every hit that did
    // not miss -- a knockout and a substitute's included -- costs the user its
    // next turn on Gold, the move staying its wCurPlayerMove (`_priorityOf`).
    if (Effects.isHyperBeam(effectId)) {
      mon.mustRecharge = true;
      mon.rechargeMove = move;
    }

    if (Effects.isExplode(effectId)) {
      this._faintUser(fighter, mon);
    }

    // `kingsrock`, the last command of the scripts that hold one.
    this._kingsRock(mon, move, effectId, defender);

    this._markLastMove(mon, choice.move);
  }


  // BattleCommand_Counter / MirrorCoat (the Lua twin carries the notes): the
  // target's last move exists and is not the same command's, the user's own
  // matchup is not 0 ("It doesn't affect"), the target went first, that move
  // had power and the right category, wCurDamage is not 0 -- then twice it,
  // pinned at $ffff, through applydamage, `buildopponentrage`, `kingsrock`.
  _counter(fighter, mon, target, defender, move, effectId) {
    const choice = fighter.choice;
    const last = defender.lastCounterMove;
    let immune = false;
    let ok = !!last && int(last.effect, 0) !== effectId;
    if (ok && this._immuneTo(move, defender)) { ok = false; immune = true; }
    if (ok && !this._wentFirst(target, fighter)) ok = false;
    if (ok && int(last.power, 0) <= 0) ok = false;
    if (ok) {
      const special = last !== STRUGGLE && Effects.isSpecialType(last.type, this.specialTypes);
      if (special !== (effectId === Effects.MIRROR_COAT)) ok = false;
    }
    if (ok && this.curDamage <= 0) ok = false;
    if (!ok) {
      if (immune) this.curDamage = 0;
      this._say(immune ? `It doesn't affect ${defender.species}` : `${mon.species} missed`);
      this._markLastMove(mon, choice.move);
      return;
    }
    this._strike(target, defender, Math.min(Damage.WORD_MAX, this.curDamage * 2));
    this._buildRage(defender);
    this._kingsRock(mon, move, effectId, defender);
    this._markLastMove(mon, choice.move);
  }

  // FUTURE SIGHT's use: `damagestats` and `damagecalc` (no crit, no stab),
  // then a running count fails, or the count, the line and the stored hit.
  // Nothing is drawn.
  _foresee(fighter, mon, target, defender, move, effectId) {
    const choice = fighter.choice;
    const struck = this._hitDamage(fighter, mon, target, defender, move, effectId, false,
      { noCrit: true, noStab: true });
    this.curDamage = 0;
    const fs = fighter.futureSight;
    if (fs && fs.turns > 0) {
      this._say('But it failed');
      this._markLastMove(mon, choice.move);
      return;
    }
    fighter.futureSight = {
      turns: FUTURE_SIGHT_COUNT, damage: struck.damage,
      targetSlot: target.slot, move: copyMove(move),
    };
    this._say(`${mon.species} foresaw an attack!`);
    this._markLastMove(mon, choice.move);
  }

  // BEAT UP (the Lua twin carries the notes): the wild monster's one hit and
  // its "But it failed!"; otherwise a pass per party member -- `critical`, the
  // fainted / statused skip (the player's HP-low-byte bug), "<MEMBER>'s
  // attack!", DamageCalc on its level, base Attack and the target's base
  // Defense, the roll, a miss ending the move, applydamage, `checkfaint`,
  // `buildopponentrage` -- a party of one ending after the first pass with no
  // `kingsrock`, otherwise BeatUpFailText and `kingsrock`.
  _beatUp(fighter, mon, target, defender, move, effectId, verdict) {
    const choice = fighter.choice;
    if (isWildSeat(this.mode, fighter)) {
      const struck = this._hitDamage(fighter, mon, target, defender, move, effectId, false,
        { noStab: true });
      this._say(`${mon.species}'s attack!`);
      const damage = this._vary(struck.damage);
      if (verdict !== 'hit') {
        this.curDamage = 0;
        this._say(`${mon.species} missed`);
        this._markLastMove(mon, choice.move);
        return;
      }
      if (struck.crit) this._say('A critical hit');
      this._strike(target, defender, damage);
      if (defender.hp > 0) {
        this._buildRage(defender);
        this._say('But it failed');
      }
      this._markLastMove(mon, choice.move);
      return;
    }

    const playerBranch = isPlayerSeat(this.mode, fighter);
    const party = fighter.mons;
    const active = (fighter.active || 1) - 1;
    const targetBase = defender.transformBase || defender.base;
    const defense = (targetBase && typeof targetBase === 'object' && targetBase.def !== undefined
      && targetBase.def !== null) ? targetBase.def : Math.max(1, int(defender.stats.def, 1));
    const boost = Items.typeBoostPercent(mon, this._typeIdOf(move.type));
    let hitOnce = false;
    for (let i = 0; i < party.length; i += 1) {
      const member = party[i];
      const isCrit = this._critical(mon, move);
      let status = member.status;
      if (playerBranch && active === member.hp % 256) status = mon.status;
      if (member.hp > 0 && (status === null || status === undefined)) {
        hitOnce = true;
        this._say(`${member.species}'s attack!`);
        const base = member.base && typeof member.base === 'object' ? member.base : null;
        const attack = (base && base.atk !== undefined && base.atk !== null)
          ? base.atk : Math.max(1, int(member.stats.atk, 1));
        let d = Damage.calc(member.level, move.power, attack, defense, {
          crit: isCrit, itemBoostPercent: boost,
        });
        if (d === null) d = 0;
        d = this._vary(d);
        if (verdict !== 'hit') {
          this.curDamage = 0;
          this._say(`${mon.species} missed`);
          this._markLastMove(mon, choice.move);
          return;
        }
        if (isCrit) this._say('A critical hit');
        this._strike(target, defender, d);
        if (defender.hp <= 0) {
          this._markLastMove(mon, choice.move);
          return;
        }
        this._buildRage(defender);
      }
      if (party.length === 1) {
        if (!hitOnce) this._say('But it failed');
        this._markLastMove(mon, choice.move);
        return;
      }
    }
    if (!hitOnce) this._say('But it failed');
    this._kingsRock(mon, move, effectId, defender);
    this._markLastMove(mon, choice.move);
  }

  // PRESENT (the Lua twin carries the notes): `critical`, its own Stab call on
  // the 0 `damagestats` left (wTypeMatchup, and the wCurDamage DamageCalc adds
  // to), the byte unless the matchup is 0 or the move missed, the heal branch,
  // and DamageCalc on the registers that Stab call left -- on Gold / Silver,
  // and on Crystal in a link battle -- or on `damagestats`' own (Crystal).
  _present(fighter, mon, target, defender, move, effectId, verdict) {
    const isCrit = this._critical(mon, move);
    const percents = this._typePercents(move.type, defender);
    let matchup = 10;
    for (const pct of percents) matchup = Math.floor(matchup * Math.max(0, pct) / 100);
    const typeName = this._typeIdOf(move.type);
    const stabOpts = {
      weatherTenths: Effects.weatherTenths(this._weatherKind(), typeName, effectId),
      badgeTypeBoost: Effects.badgeTypeBoost(typeName, fighter.badges),
      stab: hasType(mon, move.type),
      typeEffect: percents,
    };
    const inner = Damage.stab(0, stabOpts);
    const failed = matchup === 0 || verdict !== 'hit';
    let power = null;
    if (!failed) {
      power = Effects.presentPower(this.rng.byte());
      if (power === null) {
        if (defender.hp >= defender.maxHp) {
          if (this.family === 'crystal') this._say(`${defender.species} refused the gift!`);
        } else {
          this._heal(target, defender, Items.quarter(defender.maxHp));
          this._say(`${defender.species} regained health!`);
        }
        return { healed: true };
      }
    }
    let level;
    let attack;
    let defense;
    const boost = Items.typeBoostPercent(mon, typeName);
    if (this.family !== 'crystal' || has(LINK_MODES, this.mode)) {
      const constant = (types, i) => {
        const t = types[i] === undefined || types[i] === null ? types[0] : types[i];
        return Effects.typeConstant(this._typeIdOf(t));
      };
      level = constant(defender.types, 1);
      attack = matchup;
      defense = inner.cReg !== null ? inner.cReg : constant(mon.types, 1);
      if (failed) power = constant(defender.types, 0);
    } else {
      level = mon.level;
      const stats = this._damageStats(fighter, mon, target, defender, move.type, effectId, isCrit);
      attack = stats.attack;
      defense = stats.defense;
      if (failed) power = Math.max(0, int(move.power, 0));
    }
    let d = Damage.calc(level, power, attack, defense, {
      crit: isCrit, itemBoostPercent: boost, carry: inner.damage,
    });
    if (d === null) d = inner.damage;
    const stabbed = Damage.stab(d, stabOpts);
    return { damage: stabbed.damage, crit: isCrit, percents, immune: stabbed.immune };
  }

  // ProtectChance for PROTECT / DETECT and ENDURE (the Lua twin explains):
  // fails when every standing foe already moved, behind the user's own
  // substitute, or on the consecutive-use odds; otherwise the count goes up
  // and the flag stands for the rest of the turn.
  _protect(fighter, mon, effectId) {
    let later = false;
    for (const foe of this._foes(fighter)) {
      if (activeMon(foe) && !this._wentFirst(foe, fighter)) later = true;
    }
    if (!later || int(mon.substitute, 0) > 0
        || !Effects.protectChance(this.rng, mon.protectCount)) {
      mon.protectCount = 0;
      this._say('But it failed');
      return;
    }
    mon.protectCount = Math.min(255, int(mon.protectCount, 0) + 1);
    if (effectId === Effects.ENDURE) {
      mon.endure = true;
      this._say(`${mon.species} braced itself!`);
    } else {
      mon.protect = true;
      this._say(`${mon.species} PROTECTED itself!`);
    }
  }

  // BattleCommand_StartRain / StartSun / StartSandstorm: five turns of the
  // weather; a SANDSTORM into a sandstorm fails.
  _startWeather(effectId) {
    const kind = Effects.WEATHER_OF[effectId];
    if (kind === 'sandstorm' && this._weatherKind() === 'sandstorm') {
      this._say('But it failed');
      return;
    }
    this.weather = { kind, turns: Effects.WEATHER_TURNS };
    this._say(Effects.WEATHER_LINES[kind].start);
  }

  // MORNING SUN / SYNTHESIS / MOONLIGHT: full HP fails, otherwise
  // Effects.timeHealAmount and "regained health!".
  _timeHeal(fighter, mon, effectId) {
    if (mon.hp >= mon.maxHp) {
      this._say(`${mon.species}'s HP is full!`);
      return;
    }
    const timeMatches = has(LINK_MODES, this.mode) || this.timeOfDay === null
      || this.timeOfDay === Effects.HEAL_TIME[effectId];
    this._heal(fighter, mon, Effects.timeHealAmount(mon.maxHp, timeMatches, this._weatherKind()));
    this._say(`${mon.species} regained health!`);
  }

  // BattleCommand_RolloutPower: nothing asleep; a miss ends the roll; a hit
  // counts, keeps rolling below ROLLOUT_MAX, and doubles once per roll after
  // the first (once more CURLED).
  _rolloutPower(mon, damage, missed) {
    const roll = mon.rollout;
    if (mon.status === 'sleep' || !roll) return damage;
    if (missed) {
      roll.active = false;
      return damage;
    }
    roll.count += 1;
    roll.active = roll.count < Effects.ROLLOUT_MAX;
    return Damage.doubleTimes(damage, roll.count - 1 + (mon.curled ? 1 : 0));
  }

  // BattleCommand_FuryCutter: a miss resets the count; a hit counts one more
  // (a byte) and doubles up to 16x (a wrapped 0 doubles 255 times).
  _furyCutter(mon, damage, missed) {
    if (missed) {
      mon.furyCutter = 0;
      return damage;
    }
    mon.furyCutter = (int(mon.furyCutter, 0) + 1) % 256;
    let b = mon.furyCutter;
    if (b >= 6) b = 5;
    return Damage.doubleTimes(damage, b === 0 ? 255 : b - 1);
  }

  // One place where HP comes off, so the faint that follows can never be
  // forgotten at one of the call sites. `ignoreSubstitute` is the cart's
  // DoPlayerDamage / DoEnemyDamage `c` flag: the confusion self-hit sets it,
  // so the damage reaches the HP behind the user's own substitute -- and so
  // does every SubtractHPFromUser (recoil, poison, burn, LEECH SEED, a wrap).
  // Bide's store is `_strike`'s: only a move's hit feeds it.
  _damage(fighter, mon, rawAmount, status, ignoreSubstitute) {
    let amount = Math.max(0, int(rawAmount, 0));

    if (amount > 0 && !ignoreSubstitute && mon.substitute && mon.substitute > 0) {
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

  // ------------------------------------------------------------------
  // participation (who fought the monster that fell)
  // ------------------------------------------------------------------

  /**
   * This seat's monster just changed (battle start, switch, replacement).
   *
   * Its own set resets, then the currently standing opposition marks into it --
   * and the incoming monster marks into each of THEIR sets: a switch-in joins
   * the standing foe's participants. A foe mid-replacement (nothing out) is
   * neither read nor written, the same way the engine has no enemy to mark
   * against.
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

    // ...and the mark the deferred send-out still owes (`_faint` explains why
    // it is held rather than taken here): whoever was standing when the monster
    // this one replaces went down was in against this one too. Only this
    // direction is owed -- the seat opposite re-derives its own set the next
    // time it refields, exactly as the engine keeps flags on one side only.
    // Consumed once: a seat that refields again later starts clean.
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
   * then runs its own generation's Experience over its own party, which is also
   * the only place the result can persist.
   *
   * The mode gate is not a shortcut for the owner check, it is the rule. A
   * seated fighter here carries a playerId whether a connection is behind it or
   * a synthetic wild / trainer seat is, so "does this seat have an owner" is
   * not a question the turn machine can ask -- but the *mode* answers it. 1v1
   * and coop_pvp are left out deliberately: paying a player for beating another
   * player is a farming loop, and it is not what vanilla does with a link
   * battle either.
   *
   * One event per PAID monster, in seat order and then party order. Order is
   * load-bearing twice over: the Lua twin emits the same list in the same
   * order, and a stream that differs by a permutation is a parity failure with
   * no symptom anyone could read.
   *
   * `slot` stays the owning FIGHTER's field slot -- that is the ownership gate.
   * `mon` says which of that party banks the share, 0-based, because a benched
   * participant has no field slot to be named by.
   *
   * No roll is drawn anywhere in here: the parity digest's rngState must not
   * move because a faint paid out.
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
        speciesId: mon.speciesId,
        level: mon.level,
        participants,
        mon: winner.index - 1,
      });
    }
  }

  /**
   * Pay for everything the action just felled, in the order it fell.
   *
   * Split from `_faint` because the engine splits it: knocking a monster *down*
   * clears its flag, and the payout is queued behind that -- so by the time
   * anybody is counted, every monster the action killed has already left the
   * set. Paying inside `_faint` instead put a self-KO'er in its own victim's
   * payout: an Explosion or a recoil that kills its user runs `_faintUser`
   * *after* the target's faint, so the user was still standing, still flagged,
   * and still in the divisor.
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
    // RemoveFaintedPlayerMon first: this one is out of every participation set
    // before anything below can pay anybody, so a mon that died on the way to
    // the KO is not in the divisor. Keyed off the seat's own party position
    // rather than `active`, which the recoil path has not cleared yet.
    for (let index = 1; index <= fighter.mons.length; index += 1) {
      if (fighter.mons[index - 1] === mon) { this._unfield(fighter, index); break; }
    }
    mon.charging = null;
    mon.invulnerable = false;
    mon.mustRecharge = false;
    mon.thrashing = null;
    mon.raging = false;
    mon.rageCounter = 0;
    mon.trapped = null;
    mon.bide = null;
    mon.substitute = 0;
    mon.minimized = false;
    mon.lastCounterMove = null;
    mon.mist = false;
    mon.focusEnergy = false;
    mon.xAccuracy = false;
    mon.leechSeed = null;
    mon.disable = null;
    // The fallen monster's substatus and Transform go with it.
    this._clearSubstatus(mon);
    // The fallen monster's stages go with it; the side's screens stay up.
    Effects.resetStages(mon);
    this._clearTrapsFrom(fighter.slot);

    // Living bench? Computed before clearing active; fainted mon already has hp 0.
    const next = firstLiving(fighter.mons);
    const faintEv = { slot: fighter.slot, side: fighter.side, text: mon.species };
    // amount=1 is the authoritative mustReplace signal (living bench). Clients
    // open the replace picker from this rather than guessing from local HP.
    if (next) faintEv.amount = 1;
    this._emit('faint', faintEv);
    // Inside the faint batch, so the ball goes dark in the same beat the
    // monster goes down -- and so a fight that ends here still said it.
    this._syncTeams();

    // Owed here, paid at the end of the action (`_drainExp`), with the fallen
    // sheet held in the queue so the payout still names the monster that fell
    // and the level it was. For an ordinary KO nothing moves: the faint, then
    // its spoils, and only then anything about what comes next. What changes is
    // the action that fells two: every one of them is out of the sets before
    // the first share is counted.
    this.pendingExp.push({ fallen: fighter, mon });

    fighter.active = null;
    if (next) {
      // Ask the seat for a switch on the next choice window; timeout / autoPick
      // still lands firstLiving (preferring an SE bench).
      fighter.mustReplace = true;
      // The successor's mark, taken now because the send-out is not now.
      //
      // Vanilla marks whoever is standing at the enemy's send-out, and the
      // engine sends out inside the faint itself, while the monster that landed
      // the KO is still on the field. This referee cannot: it asks the seat,
      // and the answer arrives on the next choice window, by which time side
      // a's own switches have already resolved. So the send-out's mark is taken
      // here, against the field the faint actually happened on, and held until
      // `_refield` puts the successor out.
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

  // The end of the turn: pokecrystal's HandleBetweenTurnEffects order (core.asm
  // :250-296, pokegold the same) -- the residual walk, Leftovers,
  // Mysteryberry, Defrost, Safeguard, the screens, the stat-boosting held
  // items, the healing held items -- a successor's share at the replace
  // phase's close (`_closeReplace`). The Lua twin's note has the rest.
  _resolveResiduals() {
    this._residualDamage();
    if (this.result) return;
    // The faint-checked block in the cart's order: FUTURE SIGHT, the
    // weather, HandleWrap (Perish Song is wave 4's).
    this._futureSightTick();
    if (this.result) return;
    this._weatherTick();
    if (this.result) return;
    this._wrapTick();
    if (this.result) return;
    this._heldLeftovers();
    this._heldMysteryberry();
    this._heldDefrost();
    this._tickSafeguard();
    this._tickScreens();
    this._heldStatBoosts();
    this._heldHealing();
  }

  // HandleDefrost: player then enemy, a frozen monster the freeze did not land
  // on this turn draws one BattleRandom and thaws under 10 percent (the Lua
  // twin explains). The status byte goes with no rebuild.
  _heldDefrost(only = null) {
    for (const fighter of this.fighters) {
      const mon = inSet(only, fighter) ? activeMon(fighter) : null;
      if (mon && mon.status === 'freeze' && !mon.justFrozen
          && Status.defrosts(this.rng.byte())) {
        Effects.setStatusOn(mon, fighter, null);
        mon.statusTurns = 0;
        const text = `${mon.species} was defrosted`;
        this._say(text);
        // No token: a `status` event without one is a cure (events.js).
        this._emit('status', { slot: fighter.slot, side: fighter.side, text });
      }
    }
  }

  // HandleSafeguard: side a then side b, a turn off each SAFEGUARD that is
  // up, and the cart's line when one runs out.
  _tickSafeguard() {
    for (const side of SIDES) {
      const screens = this.screens[side];
      if (screens.safeguard > 0) {
        screens.safeguard -= 1;
        if (screens.safeguard === 0) {
          const first = this.bySide[side][0];
          const name = first ? first.name : `side ${side}`;
          this._say(`${name}'s SAFEGUARD faded!`);
        }
      }
    }
  }

  // HandleScreens (core.asm:1620-1680): side a then side b, Light Screen before
  // Reflect within a side, one turn off each screen that is up, and the cart's
  // line when one runs out. The side is named by its first seat.
  _tickScreens() {
    for (const side of SIDES) {
      const screens = this.screens[side];
      const first = this.bySide[side][0];
      const name = first ? first.name : `side ${side}`;
      if (screens.lightScreen > 0) {
        screens.lightScreen -= 1;
        if (screens.lightScreen === 0) this._say(`${name}'s LIGHT SCREEN fell`);
      }
      if (screens.reflect > 0) {
        screens.reflect -= 1;
        if (screens.reflect === 0) this._say(`${name}'s REFLECT faded`);
      }
    }
  }

  // Per seat, in field order: ResidualDamage's poison / burn and LEECH SEED,
  // each a SubtractHPFromUser -- straight off the HP, a substitute never asked.
  // (HandleWrap and the Bide counter are `_wrapTick`'s; the Disable count is
  // CheckTurn's.)
  _residualDamage() {
    for (const fighter of this.fighters) {
      if (this.result) return;
      let mon = activeMon(fighter);
      if (mon && mon.status) {
        const amount = Status.residual({
          status: mon.status, maxHp: mon.maxHp, toxicCounter: mon.toxicCounter,
        });
        if (amount !== null && amount !== undefined) {
          // HurtByPoisonText for PSN and badly poisoned alike.
          const label = mon.status === 'toxic' ? 'poison' : mon.status;
          if (mon.status === 'toxic') mon.toxicCounter += 1;
          this._say(`${mon.species} is hurt by its ${label}`);
          this._damage(fighter, mon, amount, mon.status, true);
        }
      }
      if (this.result) return;
      mon = activeMon(fighter);
      if (mon && mon.leechSeed) {
        // GetEighthMaxHP through SubtractHPFromUser, then RestoreHP on the seat
        // opposite with what SubtractHP hands back: the whole eighth, or just
        // the HP that was left. Read before the sap: a sap that knocks the
        // seeded monster out faints it, and `_faint` clears its leechSeed. The
        // seeder is still healed (RestoreHP comes before HasUserFainted).
        const amount = Items.eighth(mon.maxHp);
        const taken = Math.min(amount, mon.hp);
        const from = mon.leechSeed.fromSlot;
        this._say(`${mon.species} is seeded`);
        this._damage(fighter, mon, amount, null, true);
        const seeder = from !== null && from !== undefined
          ? this._fighterAtSlot(from) : null;
        const sMon = seeder && activeMon(seeder);
        if (sMon && sMon.hp > 0) this._heal(seeder, sMon, taken);
      }
    }
  }

  // HandleWrap per seat in field order (the Lua twin explains), and the Bide
  // counter's between-turn tick.
  _wrapTick() {
    for (const fighter of this.fighters) {
      if (this.result) return;
      let mon = activeMon(fighter);
      if (mon && mon.trapped && mon.trapped.turns > 0 && int(mon.substitute, 0) <= 0) {
        const trap = mon.trapped;
        const label = trap.label || 'the trap';
        trap.turns -= 1;
        if (trap.turns <= 0) {
          mon.trapped = null;
          this._say(`${mon.species} was released from ${label}`);
        } else {
          this._say(`${mon.species} is hurt by ${label}`);
          this._damage(fighter, mon, Items.sixteenth(mon.maxHp), null, true);
        }
      }
      mon = activeMon(fighter);
      if (mon && mon.bide && mon.bide.turns > 0) {
        mon.bide.turns -= 1;
      }
    }
  }

  // HandleFutureSight, every seat in field order (the Lua twin explains): the
  // count goes down and at 1 the stored hit lands -- its roll, its
  // `checkhit` ("But it failed" on a miss), applydamage, `checkfaint`,
  // `buildopponentrage` -- on the aimed seat or the one `_retarget` finds;
  // wCurDamage is zeroed after.
  _futureSightTick() {
    for (const fighter of this.fighters) {
      if (this.result) return;
      const fs = fighter.futureSight;
      if (fs && fs.turns > 0) {
        fs.turns -= 1;
        if (fs.turns === 1) {
          fighter.futureSight = null;
          const target = this._retarget(fighter, fs.targetSlot);
          const defender = target && activeMon(target);
          if (defender) {
            this._say(`${defender.species} was hit by FUTURE SIGHT!`);
            const damage = this._vary(fs.damage);
            const user = activeMon(fighter) || { stages: {}, xAccuracy: false };
            if (this._checkHit(user, defender, fs.move, Effects.FUTURE_SIGHT) !== 'hit') {
              this._say('But it failed');
            } else {
              this._strike(target, defender, damage);
              this._buildRage(defender);
            }
          }
          this.curDamage = 0;
        }
      }
    }
  }

  // The weather standing on the field, or null.
  _weatherKind() {
    return this.weather ? this.weather.kind : null;
  }

  // Whether one of a monster's battle types is named in `set`.
  _hasNamedType(mon, set) {
    for (const t of mon.types) {
      const name = this._typeIdOf(t);
      if (name && has(set, name)) return true;
    }
    return false;
  }

  // HandleWeather (the Lua twin explains): the count goes down; at 0 the end
  // line, otherwise the continuation line and, for a SANDSTORM, an eighth of
  // the max HP off every monster not underground and not ROCK / GROUND /
  // STEEL, in field order.
  _weatherTick() {
    const weather = this.weather;
    if (!weather) return;
    const lines = Effects.WEATHER_LINES[weather.kind];
    weather.turns -= 1;
    if (weather.turns <= 0) {
      this.weather = null;
      this._say(lines.ended);
      return;
    }
    this._say(lines.continues);
    if (weather.kind !== 'sandstorm') return;
    for (const fighter of this.fighters) {
      if (this.result) return;
      const mon = activeMon(fighter);
      if (mon && this._vanishedInto(mon) !== 'DIG'
          && !this._hasNamedType(mon, Effects.SANDSTORM_IMMUNE)) {
        this._say(`The SANDSTORM hits ${mon.species}!`);
        this._damage(fighter, mon, Items.eighth(mon.maxHp), null, true);
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
      this._payDayOutcome(this._finish('win', this._sidePlayers('a'), this._sidePlayers('b'), 'ko'));
    } else {
      this._finish('win', this._sidePlayers('b'), this._sidePlayers('a'), 'ko');
    }
    return true;
  }

  // CheckPayDay, run only outside a link battle and only on a WIN -- a
  // knockout or a catch: the fight's one wPayDayMoney is the player's, the
  // computer's own PAY DAY coins included. Contract K11: `payDay` on side a's
  // win against the computer (BADGE_MODES), never in a link fight; the Amulet
  // Coin doubling and the wallet are the client's.
  _payDayOutcome(result) {
    if (!result || typeof result !== 'object' || !BADGE_MODES[this.mode]) return;
    if (this.payDay > 0) result.payDay = this.payDay;
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
  // a level gained mid-fight (contract K9; the Lua twin carries the notes)
  // ----------------------------------------------------------------
  //
  // `levelUp(playerId, monIndex, level, stats, maxHp)`: the party's stats
  // become the reported ones (CalcMonStats over the K7 blocks when a level
  // comes with no stats), the HP rises by the max-HP step, and a fielded
  // monster's battle stats are rebuilt as GiveExperiencePoints does --
  // stages, then the status, then the badge -- from wPlayerStats, which a
  // Transform keeps copied. Never throws; returns whether anything changed.
  levelUp(playerId, monIndex, level, stats, maxHp) {
    if (this.result) return false;
    const fighter = this.byId.get(str(playerId) || '');
    if (!fighter) return false;
    const index = int(monIndex, null);
    const mon = index !== null ? monAt(fighter, index) : null;
    if (!mon) return false;

    let newLevel = mon.level;
    if (level !== undefined && level !== null) {
      newLevel = int(level, null);
      if (newLevel === null || newLevel < mon.level || newLevel > LEVEL_MAX) return false;
    }
    let partyStats = null;
    if (stats !== undefined && stats !== null) {
      if (!isTable(stats)) return false;
      partyStats = {};
      for (const key of Effects.STAT_KEYS) {
        const value = int(stats[key], null);
        if (value === null) return false;
        partyStats[key] = Math.max(1, Math.min(Effects.MAX_STAT_VALUE, value));
      }
    }
    let newMax = null;
    if (maxHp !== undefined && maxHp !== null) {
      newMax = int(maxHp, null);
      if (newMax === null) return false;
      newMax = Math.max(1, Math.min(Damage.WORD_MAX, newMax));
    }
    if (!partyStats && level !== undefined && level !== null) {
      const saved = mon.preTransform;
      const computed = Effects.calcMonStats(mon.base, saved ? saved.dvs : mon.dvs,
        mon.statExp, newLevel);
      if (computed) {
        partyStats = computed.stats;
        if (newMax === null) newMax = computed.maxHp;
      }
    }
    if (newLevel === mon.level && !partyStats && newMax === null) return false;

    mon.level = newLevel;
    if (partyStats) {
      if (mon.transformed && mon.preTransform) {
        mon.preTransform.stats = partyStats;
      } else if (!mon.transformed) {
        mon.stats = partyStats;
      }
    }
    if (newMax !== null) {
      const step = newMax - mon.maxHp;
      mon.maxHp = newMax;
      if (mon.hp > 0) mon.hp = Math.max(1, Math.min(newMax, mon.hp + step));
    }
    if (activeMon(fighter) === mon) {
      Effects.snapStats(mon, fighter.badges, Effects.calcStats(mon, fighter.badges, 'init'));
    }
    return true;
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
    // A leftover or forced fill was held open by `_maybeResolve`'s disconnect
    // gate; close it now that everyone is back.
    this._maybeResolve();
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

    // A side that is already down must not sit out a choice window. Solo's
    // clock is 0, so a faint that left the field in `choice` used to wait
    // forever for an answer nobody can file -- the band on "Waiting for WILD...".
    if ((this.phase === 'choice' || this.phase === 'replace') && this._checkOver()) {
      return true;
    }

    // Forced-only turns opened by the previous resolve wait here so one drain
    // does not swallow a whole recharge / rampage / charge chain. Keep the flag
    // while a seat is away; reconnect()'s `_maybeResolve` closes the turn.
    if (this.forcedPending && this.phase === 'choice' && !this._anyDisconnected()) {
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
    // The same sweep covers the replace phase: `_autoChoice` answers a
    // `mustReplace` seat with a bench switch (it is the branch the NPC side
    // takes), so an unanswered replacement fills like an unanswered move,
    // `_maybeResolve` closes the phase, and the fight carries on one monster
    // down rather than wedging.
    if ((this.phase === 'choice' || this.phase === 'replace')
        && this.deadline !== null && this.now >= this.deadline
        && !this._anyDisconnected()) {
      for (const fighter of this.fighters) {
        if (this._owes(fighter)) {
          const auto = this._autoChoiceOrSkip(fighter);
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
      // The field's weather (wave 3), for a test or a log line.
      weather: this.weather ? { kind: this.weather.kind, turns: this.weather.turns } : null,
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
 *   id, mode, seed, chart, specialTypes, typeIds, metronomePool,
 *   choiceTimeout, reconnectGrace, resolveTimeout, now
 *   sides = { a: [ { playerId, name, mons, bag, badges } ], b: [ ... ] }
 *
 * `badges` is kept only on side a of a BADGE_MODES fight and dropped
 * everywhere else, silently: a PvP upload that carries one is a well-formed
 * upload the cart would simply not have boosted.
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
    // Hub opens coop_wild for 2 or 3 humans; a lone human is a solo wild.
    if (self.mode === 'coop_wild' && side === 'a' && roster.length < 2) {
      return refuse('side a has fewer fighters than coop_wild allows');
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
        badges: seatBadges(self.mode, side, entry.badges),
        // The cart's player in a fight against the computer, as BattleSim3
        // keeps it: obedience and the flinch-reset exception ask this.
        badgeRules: (side === BADGE_SIDE && has(BADGE_MODES, self.mode)) ? true : null,
        // Contract K6; the fight reads side a's first seat's (`self.family`).
        family: has(FAMILIES, entry.family) ? entry.family : DEFAULT_FAMILY,
        // wPlayerConfuseCount for this field position (`_berserkGene`).
        confuseCount: 0,
        bag: copyBag(entry.bag),
        active: firstLiving(mons),
        connected: true,
        graceEndsAt: null,
        choice: null,
        // The roster last published for this seat (`_syncTeams`). null rather
        // than the opening string, so the first sync always publishes.
        team: null,
        // Who has been in against THIS seat's current monster; see `_refield`.
        // Null-prototype, matching the Gen 1 twin: the keys are attacker-shaped
        // only in the sense that they are built from slot/index, but the two
        // files are hand-mirrored and an unexplained divergence at a hardened
        // site is what the twin-parity rule exists to stop.
        fought: Object.create(null),
      };
      self.fighters.push(fighter);
      self.byId.set(playerId, fighter);
      self.bySide[side].push(fighter);
    }
  }

  // The fight's cart (K6): side a's first seat speaks for it.
  self.family = self.bySide.a[0] ? self.bySide.a[0].family : DEFAULT_FAMILY;

  // The opening field's battle stats, each lead loaded the way its seat's
  // cart loads it (`_switchInStats`).
  for (const fighter of self.fighters) {
    const mon = activeMon(fighter);
    if (mon) self._switchInStats(fighter, mon);
  }

  // Everybody is fielded at once, so the opening participation sets are the
  // opening field. `_refield` re-adds the standing opposition every time it
  // runs, so walking the roster once is enough: a later seat's reset cannot
  // lose an earlier seat's entry, it re-derives it.
  for (const fighter of self.fighters) self._refield(fighter);

  // `mon` is the party index the referee itself fielded (here: `firstLiving`),
  // zero-based like the `exp` event's. A client cannot re-derive it from
  // `text`: a party may hold the same species twice, and resolving the name
  // against the party then picks whichever copy comes first -- which is how a
  // fainted duplicate came back onto the field. The index is unambiguous.
  for (const fighter of self.fighters) {
    const mon = activeMon(fighter);
    if (mon) {
      self._emit('send', {
        slot: fighter.slot, side: fighter.side, hp: mon.hp, maxHp: mon.maxHp,
        text: mon.species,
        speciesId: mon.speciesId, level: mon.level,
        mon: fighter.active - 1,
        status: mon.status && has(STATUS_TO_WIRE, mon.status)
          ? STATUS_TO_WIRE[mon.status] : undefined,
        confused: (mon.confusion && mon.confusion > 0) ? 1 : undefined,
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
  AIM_SEED_OFFSET,
  DEFAULT_NPC_BAG,
  MODES,
  SIDES,
  BADGE_MODES,
  BADGE_SIDE,
  LINK_MODES,
  FAMILIES,
  DEFAULT_FAMILY,
  BERSERK_CONFUSION,
  REDRAW_LIMIT,
  LEVEL_MAX,
  SHEET_BLOCKS,
  LOAF_LINES,
  STATUS_FROM_WIRE,
  STATUS_TO_WIRE,
};
