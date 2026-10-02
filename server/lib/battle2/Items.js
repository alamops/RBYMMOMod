'use strict';

/*
 * Gold / Silver / Crystal held items: the static rules the referee keys on a
 * sheet's item.
 *
 * Node twin of src/BattleSim2/Items.lua, line for line; the Lua header carries
 * the reasoning and every pokecrystal citation, and only what the port has to
 * keep true is restated here. The referee holds no item table -- the sheet
 * carries the engine row's hold effect (`holdEffect`, a HELD_* name), its
 * parameter (`holdParam`), the display name and the Mail flag (contract K2) --
 * so what lives here is the cart's code, not its data: which HELD_* name a rule
 * answers to, the rules the cart writes against an item ID, and the arithmetic.
 * Every rule is identical between pokecrystal and pokegold.
 *
 * Nothing here holds state or draws a byte.
 */

const int = (value, fallback) => {
  if (value === null || value === undefined || typeof value === 'boolean') return fallback;
  const n = Number(value);
  if (Number.isNaN(n)) return fallback;
  return Math.floor(n);
};

const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
const isTable = (value) => typeof value === 'object' && value !== null;

// ------------------------------------------------------------------
// the HELD_* names a rule answers to (constants/item_data_constants.asm)
// ------------------------------------------------------------------

const QUICK_CLAW = 'HELD_QUICK_CLAW'; // DetermineMoveOrder .equal_priority
const BRIGHTPOWDER = 'HELD_BRIGHTPOWDER'; // BattleCommand_CheckHit .BrightPowder
const CRITICAL_UP = 'HELD_CRITICAL_UP'; // BattleCommand_Critical .ScopeLens
const FOCUS_BAND = 'HELD_FOCUS_BAND'; // BattleCommand_ApplyDamage .focus_band
const FLINCH = 'HELD_FLINCH'; // BattleCommand_HeldFlinch (kingsrock)
const LEFTOVERS = 'HELD_LEFTOVERS'; // HandleLeftovers
const BERRY = 'HELD_BERRY'; // HandleHPHealingItem
const RESTORE_PP = 'HELD_RESTORE_PP'; // HandleMysteryberry
const HEAL_CONFUSION = 'HELD_HEAL_CONFUSION'; // UseConfusionHealingItem
const HEAL_STATUS = 'HELD_HEAL_STATUS'; // both status routines

// data/types/type_boost_items.asm, as the type's registry id.
const TYPE_BOOST = {
  HELD_NORMAL_BOOST: 'NORMAL', HELD_FIGHTING_BOOST: 'FIGHTING',
  HELD_FLYING_BOOST: 'FLYING', HELD_POISON_BOOST: 'POISON',
  HELD_GROUND_BOOST: 'GROUND', HELD_ROCK_BOOST: 'ROCK',
  HELD_BUG_BOOST: 'BUG', HELD_GHOST_BOOST: 'GHOST',
  HELD_FIRE_BOOST: 'FIRE', HELD_WATER_BOOST: 'WATER',
  HELD_GRASS_BOOST: 'GRASS', HELD_ELECTRIC_BOOST: 'ELECTRIC',
  HELD_PSYCHIC_BOOST: 'PSYCHIC_TYPE', HELD_ICE_BOOST: 'ICE',
  HELD_DRAGON_BOOST: 'DRAGON', HELD_DARK_BOOST: 'DARK',
  HELD_STEEL_BOOST: 'STEEL',
};

// data/battle/held_heal_status.asm, in the referee's spelling.
const ALL = {
  poison: true, toxic: true, burn: true, freeze: true, sleep: true, paralysis: true,
};
const STATUS_CURE = {
  HELD_HEAL_POISON: { poison: true, toxic: true },
  HELD_HEAL_FREEZE: { freeze: true },
  HELD_HEAL_BURN: { burn: true },
  HELD_HEAL_SLEEP: { sleep: true },
  HELD_HEAL_PARALYZE: { paralysis: true },
  HELD_HEAL_STATUS: ALL,
};

// data/battle/held_stat_up.asm (HandleStatBoostingHeldItems).
const STAT_UP = {
  HELD_ATTACK_UP: 'atk', HELD_DEFENSE_UP: 'def', HELD_SPEED_UP: 'spe',
  HELD_SP_ATTACK_UP: 'spa', HELD_SP_DEFENSE_UP: 'spd',
  HELD_ACCURACY_UP: 'acc', HELD_EVASION_UP: 'eva',
};

// ------------------------------------------------------------------
// the rules the cart writes against an item ID
// ------------------------------------------------------------------

const BERSERK_GENE = 'BERSERK_GENE';
const METAL_POWDER = 'METAL_POWDER';
const DITTO = 'DITTO';

const SPECIES_ATTACK = {
  THICK_CLUB: { special: false, species: { CUBONE: true, MAROWAK: true } },
  LIGHT_BALL: { special: true, species: { PIKACHU: true } },
};

const CRIT_ITEM = { LUCKY_PUNCH: 'CHANSEY', STICK: 'FARFETCH_D' };
const CRIT_ITEM_LEVEL = 2;

// data/items/mail_items.asm (ItemIsMail).
const MAIL = {
  FLOWER_MAIL: true, SURF_MAIL: true, LITEBLUEMAIL: true, PORTRAITMAIL: true,
  LOVELY_MAIL: true, EON_MAIL: true, MORPH_MAIL: true, BLUESKY_MAIL: true,
  MUSIC_MAIL: true, MIRAGE_MAIL: true,
};

// ------------------------------------------------------------------
// move-keyed answers the item rules need
// ------------------------------------------------------------------

const SLEEP_BYPASS = { SNORE: true, SLEEP_TALK: true };
const THIEF = 'THIEF';

// The move effects whose script runs `kingsrock`, in this referee's effect ids
// (the Lua header lists the Crystal names behind each), and the damaging moves
// whose effect folds to 0 on a Gold sheet but runs no `kingsrock`.
const KINGS_ROCK_EFFECTS = {
  0: true, 3: true, 7: true, 16: true, 17: true, 26: true,
  27: true, 29: true, 39: true, 40: true, 41: true, 43: true,
  44: true, 45: true, 48: true, 77: true, 81: true,
};
const KINGS_ROCK_FOLDED_EXCEPTIONS = {
  GUST: true, STOMP: true, THUNDER: true, EARTHQUAKE: true, PSYCHIC_M: true,
  TRI_ATTACK: true, FLAME_WHEEL: true, MUD_SLAP: true, OCTAZOOKA: true,
  STEEL_WING: true, SACRED_FIRE: true, METAL_CLAW: true, TWISTER: true,
  CRUNCH: true, ANCIENTPOWER: true, SHADOW_BALL: true, FUTURE_SIGHT: true,
};

// ------------------------------------------------------------------
// obedience (BattleCommand_CheckObedience)
// ------------------------------------------------------------------

const OBEDIENCE_CAPS = [
  { badge: 'RISING', cap: 101 },
  { badge: 'STORM', cap: 70 },
  { badge: 'FOG', cap: 50 },
  { badge: 'HIVE', cap: 30 },
];
const OBEDIENCE_FLOOR = 10;

function obedienceCap(badges) {
  if (isTable(badges)) {
    for (const row of OBEDIENCE_CAPS) {
      if (badges[row.badge]) return row.cap;
    }
  }
  return OBEDIENCE_FLOOR;
}

// `swap a`: the cart's nibble swap of a random byte.
function swap(byte) {
  const b = ((int(byte, 0) % 256) + 256) % 256;
  return (b % 16) * 16 + Math.floor(b / 16);
}

// `.Nap`: BattleRandom, `add a`, `swap a`, `and SLP_MASK` -- 0 means draw again.
function napTurns(byte) {
  return swap((int(byte, 0) * 2) % 256) % 8;
}

// ------------------------------------------------------------------
// reading a sheet
// ------------------------------------------------------------------

// { effect, param }: the hold effect and its parameter, effect null when the
// monster holds nothing or an item whose row names no effect.
function effect(mon) {
  if (!isTable(mon) || !mon.heldItem) return { effect: null, param: 0 };
  return { effect: mon.holdEffect || null, param: int(mon.holdParam, 0) };
}

function holds(mon, token) {
  const held = effect(mon).effect;
  return held !== null && held === token;
}

function label(mon) {
  if (!isTable(mon)) return 'ITEM';
  return mon.itemName || mon.heldItem || 'ITEM';
}

function isMail(mon) {
  if (!isTable(mon) || !mon.heldItem) return false;
  return mon.mail === true || own(MAIL, mon.heldItem);
}

function take(mon) {
  const item = {
    heldItem: mon.heldItem, holdEffect: mon.holdEffect, holdParam: mon.holdParam,
    itemName: mon.itemName, mail: mon.mail,
  };
  mon.heldItem = null;
  mon.holdEffect = null;
  mon.holdParam = null;
  mon.itemName = null;
  mon.mail = null;
  return item;
}

function give(mon, item) {
  mon.heldItem = item.heldItem;
  mon.holdEffect = item.holdEffect;
  mon.holdParam = item.holdParam;
  mon.itemName = item.itemName;
  mon.mail = item.mail;
}

// ------------------------------------------------------------------
// the arithmetic
// ------------------------------------------------------------------

// DamageCalc .DoneItem: (100 + parameter) mod 256 out of 100, returned as the
// percent Damage.compute adds to 100, or null when nothing boosts this type.
function typeBoostPercent(mon, typeId) {
  const held = effect(mon);
  const boosts = held.effect && own(TYPE_BOOST, held.effect) ? TYPE_BOOST[held.effect] : null;
  if (!boosts || typeof typeId !== 'string' || boosts !== typeId) return null;
  return ((100 + held.param) % 256) - 100;
}

// `.equal_priority`: BattleRandom against the parameter (60 -> 60/256).
function quickClawFires(param, byte) {
  return int(byte, 255) < int(param, 0);
}

// `.BrightPowder`, in the referee's percent domain (the Lua twin explains).
function brightPowder(effectivePercent, param) {
  const percent = int(effectivePercent, 0);
  let byte = Math.floor((percent * 255) / 100) - int(param, 0);
  if (byte < 0) byte = 0;
  if (byte >= 255) return percent;
  return Math.floor((byte * 100 + 254) / 255);
}

// SpeciesItemBoost: the stat doubled as a 16-bit value.
function speciesAttack(mon, special, attack) {
  if (!isTable(mon) || !mon.heldItem) return attack;
  const rule = own(SPECIES_ATTACK, mon.heldItem) ? SPECIES_ATTACK[mon.heldItem] : null;
  if (!rule || rule.special !== (special === true)) return attack;
  if (!(mon.speciesId && own(rule.species, mon.speciesId))) return attack;
  return (int(attack, 0) * 2) % 65536;
}

// DittoMetalPowder on the folded pair. Returns { attack, defense }.
function metalPowder(defender, attack, defense) {
  if (!isTable(defender) || defender.heldItem !== METAL_POWDER
      || defender.speciesId !== DITTO) {
    return { attack, defense };
  }
  let b = int(attack, 0);
  const c = int(defense, 0);
  const sum = c + Math.floor(c / 2);
  if (sum < 256) return { attack: b, defense: sum };
  b = Math.floor(b / 2);
  if (b === 0) b = 1;
  return { attack: b, defense: Math.floor(sum / 2) };
}

// BattleCommand_Critical's `.Item` check on the battle species.
function critSpeciesItem(battleSpeciesId, itemId) {
  if (typeof itemId !== 'string' || !own(CRIT_ITEM, itemId)) return false;
  return CRIT_ITEM[itemId] === battleSpeciesId;
}

// BattleCommand_FalseSwipe as Focus Band calls it. Returns { amount, held }.
function focusBand(amount, hp) {
  const a = int(amount, 0);
  const h = int(hp, 0);
  if (a < h) return { amount: a, held: false };
  return { amount: Math.max(0, h - 1), held: true };
}

// GetSixteenthMaxHP: the quarter's low byte (at least 1), quartered again.
function sixteenth(maxHp) {
  let quarter = Math.floor(Math.max(0, int(maxHp, 0)) / 4) % 256;
  if (quarter === 0) quarter = 1;
  const out = Math.floor(quarter / 4);
  return out === 0 ? 1 : out;
}

// HandleHPHealingItem: HP less than half the maximum.
function berryWants(hp, maxHp) {
  return int(hp, 0) * 2 < int(maxHp, 0);
}

// Whether King's Rock rolls after a move.
function kingsRockMove(effectId, moveId) {
  const id = int(effectId, 0);
  if (!own(KINGS_ROCK_EFFECTS, id)) return false;
  if (id === 0 && typeof moveId === 'string' && own(KINGS_ROCK_FOLDED_EXCEPTIONS, moveId)) {
    return false;
  }
  return true;
}

module.exports = {
  QUICK_CLAW,
  BRIGHTPOWDER,
  CRITICAL_UP,
  FOCUS_BAND,
  FLINCH,
  LEFTOVERS,
  BERRY,
  RESTORE_PP,
  HEAL_CONFUSION,
  HEAL_STATUS,
  TYPE_BOOST,
  STATUS_CURE,
  STAT_UP,
  BERSERK_GENE,
  METAL_POWDER,
  DITTO,
  SPECIES_ATTACK,
  CRIT_ITEM,
  CRIT_ITEM_LEVEL,
  MAIL,
  SLEEP_BYPASS,
  THIEF,
  KINGS_ROCK_EFFECTS,
  KINGS_ROCK_FOLDED_EXCEPTIONS,
  OBEDIENCE_CAPS,
  OBEDIENCE_FLOOR,
  obedienceCap,
  swap,
  napTurns,
  effect,
  holds,
  label,
  isMail,
  take,
  give,
  typeBoostPercent,
  quickClawFires,
  brightPowder,
  speciesAttack,
  metalPowder,
  critSpeciesItem,
  focusBand,
  sixteenth,
  berryWants,
  kingsRockMove,
};
