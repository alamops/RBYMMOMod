#!/usr/bin/env node
'use strict';

/*
 * Twin-constant gate for Hub.lua ↔ relay.js (and Wire ↔ sanitize).
 *
 * The hubs are deliberately two implementations of one protocol. Suites pin
 * behaviour; this file pins the *numbers and vocabulary* that must move
 * together on every PROTOCOL bump or identity-length change — so a one-sided
 * edit fails `npm test` before a player notices.
 *
 * Node-only live-ops (admin socket, bans, allowlist, auth throttle, UPnP)
 * are intentionally not twins — see docs/plans/hub-twin-parity.md.
 *
 * Run: node --test server/twin_parity.test.js
 */

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const {
  PROTOCOL, DEFAULT_SPRITE, DEFAULT_SPRITE_GEN2, DEFAULT_SPRITE_GEN3,
  defaultSpriteFor, SPRITE_GATE_MS,
} = require('./lib/relay.js');
const {
  PLAYER_ID_HEX, BATTLE_EVENT_TYPES, DECLINE_REASONS,
  TEAM_TOKENS, cleanBattleTeam, BATTLE_MON_MAX,
  MOVE_NAME_MAX, cleanBattleMove, cleanBattleMon,
  GENERATION_MAX, VERSIONS, cleanGeneration, cleanVersion,
} = require('./lib/sanitize.js');

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

function luaAssignNumber(src, name) {
  const re = new RegExp(`M\\.${name}\\s*=\\s*(-?\\d+(?:\\.\\d+)?)`);
  const m = src.match(re);
  assert.ok(m, `Config.lua must assign M.${name}`);
  return Number(m[1]);
}

function luaAssignString(src, name) {
  const re = new RegExp(`M\\.${name}\\s*=\\s*"([^"]+)"`);
  const m = src.match(re);
  assert.ok(m, `Config.lua must assign M.${name}`);
  return m[1];
}

function jsConstNumber(src, name) {
  const re = new RegExp(`(?:const|let)\\s+${name}\\s*=\\s*(-?\\d+(?:\\.\\d+)?)`);
  const m = src.match(re);
  assert.ok(m, `relay.js must declare ${name}`);
  return Number(m[1]);
}

test('PROTOCOL matches Config.lua and relay.js', () => {
  const config = read('src/Config.lua');
  assert.strictEqual(
    luaAssignNumber(config, 'PROTOCOL'), PROTOCOL,
    'bump Config.PROTOCOL and server/lib/relay.js PROTOCOL together',
  );
});

test('PLAYER_ID_HEX matches Config / Wire / sanitize', () => {
  const config = read('src/Config.lua');
  assert.strictEqual(
    luaAssignNumber(config, 'PLAYER_ID_HEX'), PLAYER_ID_HEX,
    'bump Config.PLAYER_ID_HEX and sanitize.PLAYER_ID_HEX together',
  );
  assert.strictEqual(PLAYER_ID_HEX, 32, 'PROTOCOL 16 player ids are 32 hex chars');
});

test('DEFAULT_SPRITE matches', () => {
  const config = read('src/Config.lua');
  assert.strictEqual(
    luaAssignString(config, 'DEFAULT_SPRITE'), DEFAULT_SPRITE,
    'DEFAULT_SPRITE must match on both hubs',
  );
});

test('DEFAULT_SPRITE_GEN2 matches', () => {
  const config = read('src/Config.lua');
  assert.strictEqual(
    luaAssignString(config, 'DEFAULT_SPRITE_GEN2'), DEFAULT_SPRITE_GEN2,
    'DEFAULT_SPRITE_GEN2 must match on both hubs',
  );
  assert.strictEqual(defaultSpriteFor(2), DEFAULT_SPRITE_GEN2);
  assert.strictEqual(defaultSpriteFor(1), DEFAULT_SPRITE);
});

test('DEFAULT_SPRITE_GEN3 matches, and each generation stamps its own', () => {
  // A Gen 3 hub stamps a token rather than an engine name (Config.lua says
  // why: FireRed and Emerald share no player graphic name). A one-sided
  // spelling is an avatar one hosting path draws and the other cannot.
  const config = read('src/Config.lua');
  assert.strictEqual(
    luaAssignString(config, 'DEFAULT_SPRITE_GEN3'), DEFAULT_SPRITE_GEN3,
    'DEFAULT_SPRITE_GEN3 must match on both hubs',
  );
  assert.strictEqual(DEFAULT_SPRITE_GEN3, 'GEN3_PLAYER');
  assert.strictEqual(defaultSpriteFor(3), DEFAULT_SPRITE_GEN3);
  assert.strictEqual(defaultSpriteFor('3'), DEFAULT_SPRITE_GEN3,
    'a numeric string reads as its number, the way Config.defaultSpriteFor tonumbers it');
  assert.strictEqual(defaultSpriteFor(undefined), DEFAULT_SPRITE,
    'no generation is the Gen 1 fallback, as on the Lua side');
  // Config.defaultSpriteFor carries the same three arms; read them off the
  // source so a fourth generation cannot be added to one side only.
  const body = config.match(/function M\.defaultSpriteFor\(generation\)([\s\S]*?)\nend/);
  assert.ok(body, 'Config.lua must define M.defaultSpriteFor(generation)');
  assert.ok(/g == 2 then return M\.DEFAULT_SPRITE_GEN2/.test(body[1]),
    'Config.defaultSpriteFor(2) is DEFAULT_SPRITE_GEN2');
  assert.ok(/g == 3 then return M\.DEFAULT_SPRITE_GEN3/.test(body[1]),
    'Config.defaultSpriteFor(3) is DEFAULT_SPRITE_GEN3');
});

test('the hello generation range and cart vocabulary match Wire', () => {
  // PROTOCOL 30. The range is what a hub may be locked to and what a hello
  // may claim; the carts are what a viewer maps a partner's sprite through.
  // Both are closed on both hubs, and a one-sided entry is a FireRed player
  // admitted by one hosting path and refused by the other -- the very drift
  // the PROTOCOL 29 clamp was.
  const wire = read('src/Wire.lua');
  const max = wire.match(/M\.GENERATION_MAX\s*=\s*(\d+)/);
  assert.ok(max, 'Wire.lua must assign M.GENERATION_MAX');
  assert.strictEqual(Number(max[1]), GENERATION_MAX,
    'Wire.GENERATION_MAX and sanitize.GENERATION_MAX must match');
  assert.strictEqual(GENERATION_MAX, 3, 'PROTOCOL 30 hubs know generations 1..3');

  const tableMatch = wire.match(/M\.VERSIONS\s*=\s*\{([\s\S]*?)\}/);
  assert.ok(tableMatch, 'Wire.lua must assign M.VERSIONS as a table');
  const lua = [...tableMatch[1].matchAll(/(\w+)\s*=\s*(\d+)/g)]
    .map((m) => [m[1], Number(m[2])]).sort();
  const js = [...VERSIONS.entries()].sort();
  assert.deepStrictEqual(js, lua,
    'Wire.VERSIONS and sanitize.js VERSIONS must name the same carts in the '
    + 'same generations -- add a cart to both in the same change');
  for (const [, gen] of js) {
    assert.ok(gen >= 1 && gen <= GENERATION_MAX, 'every cart is a known generation');
  }

  // The JS half's readings, pinned here beside the vocabulary they read.
  // The Lua half of the same table is tests/rby_mmo_test.lua's Wire section
  // and the hub parity fixture's generation cases.
  assert.strictEqual(cleanGeneration(undefined), 1, 'missing is the Gen 1 compat default');
  assert.strictEqual(cleanGeneration(null), 1, 'JSON null decodes to nil in Lua: missing too');
  assert.strictEqual(cleanGeneration(3), 3, 'Gen 3 is a generation, not a clamp to 1');
  assert.strictEqual(cleanGeneration(4), null, 'an unknown generation is refused, not guessed');
  assert.strictEqual(cleanGeneration(0), null);
  assert.strictEqual(cleanGeneration('3'), null, 'a string is not a JSON number');
  assert.strictEqual(cleanGeneration(true), null, 'Number(true) is 1; Lua tonumber(true) is nil');
  assert.strictEqual(cleanGeneration([2]), null, 'Number([2]) is 2; Lua says nil');
  assert.strictEqual(cleanVersion('emerald', 3), 'emerald');
  assert.strictEqual(cleanVersion('red', 3), null, 'a Gen 3 room relays no Gen 1 cart');
  assert.strictEqual(cleanVersion('firered'), 'firered', 'no generation: vocabulary only');
  assert.strictEqual(cleanVersion('constructor'), null, 'a prototype key is not a cart');
  assert.strictEqual(cleanVersion('FIRERED', 3), null, 'GameVersion ids are lower case');
});

test('battle reconnect grace and choice timeout match', () => {
  const config = read('src/Config.lua');
  const relay = read('server/lib/relay.js');
  assert.strictEqual(
    luaAssignNumber(config, 'BATTLE_RECONNECT_GRACE'),
    jsConstNumber(relay, 'BATTLE_RECONNECT_GRACE'),
    'BATTLE_RECONNECT_GRACE must match (seconds)',
  );
  assert.strictEqual(
    luaAssignNumber(config, 'BATTLE_CHOICE_TIMEOUT'),
    jsConstNumber(relay, 'BATTLE_CHOICE_TIMEOUT'),
    'BATTLE_CHOICE_TIMEOUT must match (seconds)',
  );
});

test('sprite gate is half a second on both sides', () => {
  // Hub.lua keeps SPRITE_GATE local (0.5 s); relay exports SPRITE_GATE_MS.
  const hub = read('src/Hub.lua');
  assert.ok(
    /local SPRITE_GATE\s*=\s*0\.5/.test(hub),
    'Hub.lua SPRITE_GATE must stay 0.5 s to match SPRITE_GATE_MS',
  );
  assert.strictEqual(SPRITE_GATE_MS, 500);
});

test('MOVE_NAME_MAX matches Config / Wire / sanitize', () => {
  // PROTOCOL 26's `name` is prose, and a limit that differs by one character is
  // a hub and a client that narrate a fight under two different spellings of the
  // same move -- the exact defect the field was added to remove. It is its own
  // number rather than NAME_MAX because ten characters cuts "THUNDERSHOCK".
  const config = read('src/Config.lua');
  assert.strictEqual(
    luaAssignNumber(config, 'MOVE_NAME_MAX'), MOVE_NAME_MAX,
    'bump Config.MOVE_NAME_MAX and sanitize.MOVE_NAME_MAX together',
  );
  assert.ok(MOVE_NAME_MAX >= 12,
    'both generations ship twelve-character move names ("THUNDERSHOCK")');
});

test('a battle move sheet accepts a display name and survives without one', () => {
  // Both halves of the optional, on the JS hub. The Lua half of the same pair
  // is tests/rby_mmo_test.lua's Wire section.
  const base = {
    id: 'THUNDER_SHOCK', pp: 30, power: 40, accuracy: 255,
    type: 3, effect: 0, chance: 0,
  };
  assert.strictEqual(cleanBattleMove({ ...base, name: 'THUNDERSHOCK' }).name,
    'THUNDERSHOCK', 'a stated name comes through');
  assert.strictEqual(cleanBattleMove(base).name, undefined,
    'a protocol-25 sheet states none, and that is not a refusal');
  assert.strictEqual(cleanBattleMove({ ...base, name: 42 }), null,
    'present-but-unreadable refuses the move rather than narrating under the id');
});

test('highCrit and baseSpd ride the battle sheet as optional fields', () => {
  const move = {
    id: 'SLASH', pp: 20, power: 70, accuracy: 255,
    type: 0, effect: 0, chance: 0,
  };
  assert.strictEqual(cleanBattleMove({ ...move, highCrit: true }).highCrit, true,
    'highCrit = true comes through');
  assert.strictEqual(cleanBattleMove(move).highCrit, undefined,
    'absent highCrit is not a refusal');
  assert.strictEqual(cleanBattleMove({ ...move, highCrit: false }).highCrit, undefined,
    'highCrit = false is omitted');
  assert.strictEqual(cleanBattleMove({ ...move, highCrit: 'yes' }), null,
    'a non-boolean highCrit refuses the move');

  const mon = {
    species: 'PERSIAN', level: 20, hp: 50, maxHp: 50,
    stats: { atk: 1, def: 1, spd: 1, spc: 1 },
    moves: [move],
  };
  assert.strictEqual(cleanBattleMon({ ...mon, baseSpd: 115 }).baseSpd, 115,
    'species base Speed comes through');
  assert.strictEqual(cleanBattleMon(mon).baseSpd, undefined,
    'absent baseSpd is not a refusal');
  assert.strictEqual(cleanBattleMon({ ...mon, baseSpd: 'fast' }), null,
    'an unreadable baseSpd refuses the battler');
  // `traded` is Gen 1's too from contract K1 of
  // docs/plans/gen12-referee-fidelity.md (the cart's obedience check);
  // `unfateful` stays a Gen 3 rule the Gen 1 reader never copies.
  const gen1 = cleanBattleMon({ ...mon, traded: true, unfateful: true });
  assert.ok(gen1 && gen1.traded === true && gen1.unfateful === undefined,
    'the Gen 1 dialect keeps traded and strips unfateful');
});

test('Gen 3 obedience facts: true or absent, twin of Wire.battleMon3', () => {
  // docs/plans/gen3-badge-rules.md contract K2: `traded` / `unfateful` on a
  // player's own Gen 3 sheet, read the way the ruleset's `underwater` is.
  // `unfateful` names a Mew / Deoxys whose fateful-encounter bit is explicitly
  // clear; the retired `fateful` is neither copied nor read.
  const move3 = {
    num: 33, id: 'MOVE_33', pp: 35, maxPp: 35, power: 40, type: 0,
    accuracy: 100, effect: 0, chance: 0, target: 0, priority: 0, flags: 0,
  };
  const mon3 = {
    generation: 3, species: 'MEW', speciesNum: 151, level: 20, hp: 60, maxHp: 60,
    stats: { atk: 40, def: 40, spe: 40, spa: 40, spd: 40 },
    types: [14], ability: 28, heldItem: 0, holdEffect: 0, holdEffectParam: 0,
    gender: 'U', friendship: 70, nature: 0, weight: 40,
    hiddenPower: { type: 1, power: 50 }, beatUp: { atk: 20, def: 20 },
    moves: [move3],
  };
  const base = cleanBattleMon(mon3);
  assert.ok(base, '(a well-formed Gen 3 sheet on its own)');
  assert.strictEqual(base.traded, undefined, 'absent traded stays absent');
  assert.strictEqual(base.unfateful, undefined, 'absent unfateful stays absent');
  const both = cleanBattleMon({ ...mon3, traded: true, unfateful: true });
  assert.strictEqual(both.traded, true, 'traded = true comes through');
  assert.strictEqual(both.unfateful, true, 'unfateful = true comes through');
  const off = cleanBattleMon({ ...mon3, traded: false, unfateful: false });
  assert.ok(off && off.traded === undefined && off.unfateful === undefined,
    'a false is kept as absent');
  assert.strictEqual(cleanBattleMon({ ...mon3, traded: 'yes' }), null,
    'a non-boolean traded refuses the mon');
  assert.strictEqual(cleanBattleMon({ ...mon3, unfateful: 1 }), null,
    'a non-boolean unfateful refuses the mon');
  assert.strictEqual(cleanBattleMon({ ...mon3, traded: null }).traded, undefined,
    'a null traded is absent, as Lua reads a JSON null');
  assert.strictEqual(cleanBattleMon({ ...mon3, unfateful: null }).unfateful, undefined,
    'a null unfateful is absent too');
  const retired = cleanBattleMon({ ...mon3, fateful: true });
  assert.ok(retired && retired.fateful === undefined && retired.unfateful === undefined,
    'the retired fateful is dropped, not copied');
  assert.ok(cleanBattleMon({ ...mon3, fateful: 1 }),
    '...and never read, so a non-boolean one refuses nothing');
});

test('shared hello refuse strings stay twin-worded', () => {
  const hub = read('src/Hub.lua');
  const relay = read('server/lib/relay.js');
  const needles = [
    "You're already connected.",
    "That player id can't be used here.",
    "That trainer name can't be used here.",
    'This game speaks protocol',
    // PROTOCOL 20 generation lock — same template on both hubs.
    'This hub is for generation',
    // PROTOCOL 30: a generation neither hub knows is refused, never clamped.
    'is not a generation it knows.',
  ];
  for (const needle of needles) {
    assert.ok(hub.includes(needle), `Hub.lua must contain: ${needle}`);
    assert.ok(relay.includes(needle), `relay.js must contain: ${needle}`);
  }
});

test('Wire.BATTLE_EVENTS matches sanitize.js BATTLE_EVENT_TYPES', () => {
  // A one-sided add here is silent both ways: Wire.lua would sanitise a kind
  // the JS hub refuses (mediated_battle_client.test.js catches that from the
  // Lua side only), and sanitize.js would accept a kind Wire.lua's own
  // battleEvent() never lets a Lua-side sender produce. Neither direction has
  // a suite that reads both vocabularies side by side except this one.
  const wire = read('src/Wire.lua');
  const tableMatch = wire.match(/M\.BATTLE_EVENTS\s*=\s*\{([\s\S]*?)\}/);
  assert.ok(tableMatch, 'Wire.lua must assign M.BATTLE_EVENTS as a table');
  const luaKinds = [...tableMatch[1].matchAll(/(\w+)\s*=\s*true/g)].map((m) => m[1]).sort();
  assert.ok(luaKinds.length > 0, 'Wire.BATTLE_EVENTS parsed at least one kind');

  const jsKinds = [...BATTLE_EVENT_TYPES].sort();

  assert.deepStrictEqual(
    jsKinds, luaKinds,
    'Wire.BATTLE_EVENTS and sanitize.js BATTLE_EVENT_TYPES must name the same '
    + 'closed vocabulary -- add a new battle event kind to both in the same change',
  );
});

test('Wire.DECLINE_REASONS matches sanitize.js DECLINE_REASONS', () => {
  // Why an invite came back refused. Each value picks a different sentence on
  // the asker's screen, so a one-sided add is a refusal that reads correctly
  // on one hosting path and falls back to "they refused" on the other -- for
  // the same event, with nothing to tell the two apart from inside the game.
  const wire = read('src/Wire.lua');
  const tableMatch = wire.match(/M\.DECLINE_REASONS\s*=\s*\{([\s\S]*?)\}/);
  assert.ok(tableMatch, 'Wire.lua must assign M.DECLINE_REASONS as a table');
  const luaReasons = [...tableMatch[1].matchAll(/(\w+)\s*=\s*true/g)]
    .map((m) => m[1]).sort();
  assert.ok(luaReasons.length > 0, 'Wire.DECLINE_REASONS parsed at least one reason');

  assert.deepStrictEqual(
    Object.keys(DECLINE_REASONS).sort(), luaReasons,
    'Wire.DECLINE_REASONS and sanitize.js DECLINE_REASONS must name the same '
    + 'closed vocabulary -- add a new refusal reason to both in the same change',
  );
});

test('the team roster alphabet is the same three tokens on both sides', () => {
  // A one-sided token is the quiet kind of drift: the referee would publish a
  // roster its own hub sanitises away, or a client would draw a state the other
  // runtime can never produce. Both halves spell the set out longhand (the sim
  // directories run with no Config), so this is the only place they are read
  // side by side.
  const wire = read('src/Wire.lua');
  const tableMatch = wire.match(/M\.TEAM_TOKENS\s*=\s*\{([\s\S]*?)\}/);
  assert.ok(tableMatch, 'Wire.lua must assign M.TEAM_TOKENS as a table');
  const luaTokens = [...tableMatch[1].matchAll(/(\w+)\s*=\s*true/g)].map((m) => m[1]).sort();
  assert.deepStrictEqual([...TEAM_TOKENS].sort(), luaTokens,
    'Wire.TEAM_TOKENS and sanitize.js TEAM_TOKENS must name the same alphabet');

  // ...and the two sim mirrors, which are where the tokens are actually
  // produced. They mirror rather than import, so they can drift silently.
  for (const rel of ['src/BattleSim/events.lua', 'src/BattleSim2/events.lua',
    'src/BattleSim3/events.lua']) {
    const src = read(rel);
    const mirror = src.match(/M\.TEAM_TOKENS\s*=\s*\{([\s\S]*?)\}/);
    assert.ok(mirror, `${rel} must assign M.TEAM_TOKENS`);
    const kinds = [...mirror[1].matchAll(/(\w+)\s*=\s*true/g)].map((m) => m[1]).sort();
    assert.deepStrictEqual(kinds, luaTokens, `${rel} mirrors Wire's roster alphabet`);
  }
});

test('a roster is refused whole rather than trimmed to what parses', () => {
  // The twin of Wire.battleTeam, and the assertion that matters is the refusal:
  // a truncated sentence is a shorter sentence, but a truncated roster is a
  // different party -- three balls where the seat holds five -- and the chip
  // would tell a player their opponent is two monsters closer to beaten than
  // they are.
  assert.strictEqual(cleanBattleTeam('oxs'), 'oxs');
  assert.strictEqual(cleanBattleTeam('o'), 'o');
  assert.strictEqual(cleanBattleTeam('o'.repeat(BATTLE_MON_MAX)), 'o'.repeat(BATTLE_MON_MAX));

  assert.strictEqual(cleanBattleTeam(''), null, 'an empty roster is not a seat');
  assert.strictEqual(cleanBattleTeam('o'.repeat(BATTLE_MON_MAX + 1)), null,
    'past BATTLE_MON_MAX is refused, not cut to six');
  assert.strictEqual(cleanBattleTeam('ooq'), null, 'one unreadable token refuses the row');
  assert.strictEqual(cleanBattleTeam('OOO'), null, 'the alphabet is exact');
  assert.strictEqual(cleanBattleTeam(3), null, 'a count is not a roster');
  assert.strictEqual(cleanBattleTeam(null), null, 'and nothing is not a roster');
});

test('inbound client→hub message types match on both hubs', () => {
  // Hub-outbound types (welcome/join/…) are not handlers. This gate is the
  // vocabulary a client can *send* — a one-sided add is silent on the other
  // hosting path.
  const inbound = [
    'mmo.hello', 'mmo.move', 'mmo.chat', 'mmo.request', 'mmo.respond',
    'mmo.request_cancel', 'mmo.relay', 'mmo.session_leave', 'mmo.ping',
    'mmo.party_invite', 'mmo.party_respond', 'mmo.party_leave', 'mmo.party_event',
    'mmo.auth', 'mmo.result', 'mmo.ranks',
    'mmo.coop_wait', 'mmo.coop_cancel', 'mmo.coop_join', 'mmo.coop_challenge',
    'mmo.coop_answer', 'mmo.coop_relay', 'mmo.coop_leave',
    'mmo.sprite',
    'mmo.friend_ask', 'mmo.friend_answer', 'mmo.friend_remove',
    'mmo.battle_ruleset', 'mmo.battle_party', 'mmo.battle_choice',
    'mmo.battle_reconnect', 'mmo.battle_moveset',
  ];
  const hub = read('src/Hub.lua');
  const relay = read('server/lib/relay.js');
  const wire = read('src/Wire.lua');
  for (const type of inbound) {
    assert.ok(
      wire.includes(`"${type}"`),
      `Wire.lua must declare ${type}`,
    );
    assert.ok(
      hub.includes(`handlers[Wire.`) || hub.includes(type),
      `Hub.lua must handle ${type}`,
    );
    // Hub uses Wire.CONST → string; assert the string appears in a handlers=
    // assignment via the Wire constant body living in Wire.lua already checked.
    assert.ok(
      relay.includes(`handlers['${type}']`) || relay.includes(`handlers["${type}"]`),
      `relay.js must handle ${type}`,
    );
  }
  // Every Wire client→hub constant above must resolve; spot-check Hub wires
  // the same set by counting handlers[Wire.] sites against inbound length.
  const hubHandlers = hub.match(/handlers\[Wire\.[A-Z0-9_]+\]/g) || [];
  assert.ok(
    hubHandlers.length >= inbound.length,
    `Hub.lua handler count (${hubHandlers.length}) under-covers inbound (${inbound.length})`,
  );
});

// ---------------------------------------------------------------------------
// Gen 3 (PROTOCOL 30): the battle3 twin, the Gen 3 sheet dialect, the caps
// ---------------------------------------------------------------------------

const Battle3 = require('./lib/battle3');
const sanitize = require('./lib/sanitize.js');

// Every `key = true` in a Lua table literal assigned to `M.<name>`.
function luaSet(src, name) {
  const m = src.match(new RegExp(`M\\.${name}\\s*=\\s*\\{([\\s\\S]*?)\\}`));
  assert.ok(m, `must assign M.${name} as a table`);
  return [...m[1].matchAll(/(\w+)\s*=\s*true/g)].map((x) => x[1]).sort();
}

// Every `key = "type"` in a Lua table literal.
function luaTypedKeys(src, pattern) {
  const m = src.match(pattern);
  assert.ok(m, `table ${pattern} not found`);
  return Object.fromEntries([...m[1].matchAll(/(\w+)\s*=\s*"(\w+)"/g)].map((x) => [x[1], x[2]]));
}

function luaNumber(src, name, label) {
  const m = src.match(new RegExp(`M\\.${name}\\s*=\\s*(-?\\d+)`));
  assert.ok(m, `${label} must assign M.${name}`);
  return Number(m[1]);
}

test('Gen 3 battle caps match Config.lua and sanitize.js', () => {
  // The ruleset's two lists and the sheet's id caps. A one-sided cap is a
  // ruleset or a sheet one hosting path fights and the other refuses.
  const config = read('src/Config.lua');
  for (const name of ['BATTLE_TYPE_TABLE3_MAX', 'BATTLE_MOVE_POOL3_MAX', 'GEN3_SPECIES_MAX',
    'GEN3_MOVE_MAX', 'GEN3_ITEM_MAX', 'GEN3_ABILITY_MAX', 'GEN3_NATURE_COUNT', 'GEN3_IV_MAX',
    'GEN3_EV_MAX']) {
    assert.strictEqual(luaNumber(config, name, 'Config.lua'), sanitize[name],
      `Config.${name} and sanitize.${name} must match`);
  }
  assert.strictEqual(sanitize.BATTLE_TYPE_TABLE3_MAX, 150, 'docs/plans/gen3-battle-sheet.md §3.1');
  assert.strictEqual(sanitize.BATTLE_MOVE_POOL3_MAX, 360, 'docs/plans/gen3-battle-sheet.md §3.3');
});

test('Gen 3 sheet bounds match Wire.lua and sanitize.js', () => {
  const wire = read('src/Wire.lua');
  for (const name of ['MOVE_TYPE_MAX', 'POWER3_MAX', 'ACCURACY3_MAX', 'EFFECT3_MAX',
    'TARGET3_MAX', 'PRIORITY3_MAX', 'FLAGS3_MAX', 'HOLD_EFFECT3_MAX', 'HOLD_PARAM3_MAX',
    'WEIGHT3_MAX', 'SLEEP3_MAX', 'U32_MAX', 'TYPE_CELL3_MIN', 'TYPE_MULT3_MAX', 'TERRAIN3_MAX',
    'POOL_ENTRY3_MAX', 'STAGE3_MAX', 'DELTA3_MAX', 'PAYDAY3_MAX']) {
    assert.strictEqual(luaNumber(wire, name, 'Wire.lua'), sanitize[name],
      `Wire.${name} and sanitize.${name} must match`);
  }
  assert.strictEqual(sanitize.MOVE_TYPE_MAX, 31, 'the move type keeps the older dialects\' width');
  assert.strictEqual(sanitize.PAYDAY3_MAX, 65535, 'pret gPaydayMoney is a u16 that saturates');
  assert.deepStrictEqual([...sanitize.GENDERS3].sort(), luaSet(wire, 'GENDERS3'),
    'the Gen 3 genders are one closed set on both sides');
  assert.deepStrictEqual([...sanitize.WEATHERS3].sort(), luaSet(wire, 'WEATHERS3'),
    'the ruleset weathers are one closed set on both sides');
  assert.deepStrictEqual([...sanitize.EVENT_STATS3].sort(), luaSet(wire, 'EVENT_STATS3'),
    'a stat event names the same seven stats on both sides');
});

test('the Gen 3 event vocabulary is one vocabulary across Wire and both sims', () => {
  // Wire (the client's sanitiser) must know every kind BattleSim3 emits, and
  // the Node twin must emit exactly the Lua sim's kinds with the Lua sim's
  // fields -- the parity fixtures prove the streams equal, this proves the
  // whitelists they are checked against are too.
  const wire = read('src/Wire.lua');
  const sim = read('src/BattleSim3/events.lua');
  const wireKinds3 = luaSet(wire, 'BATTLE_EVENTS3');
  assert.deepStrictEqual([...sanitize.BATTLE_EVENT_TYPES3].sort(), wireKinds3,
    'Wire.BATTLE_EVENTS3 and sanitize.js BATTLE_EVENT_TYPES3 name the same Gen 3 kinds');
  const wireKinds = luaSet(wire, 'BATTLE_EVENTS').concat(wireKinds3).sort();
  const simKinds = luaSet(sim, 'KINDS');
  assert.deepStrictEqual(Object.keys(Battle3.Events.KINDS).sort(), simKinds,
    'lib/battle3/events.js KINDS mirrors src/BattleSim3/events.lua');
  assert.deepStrictEqual(simKinds, wireKinds,
    "BattleSim3 speaks exactly Wire's two tables: BATTLE_EVENTS plus BATTLE_EVENTS3");
  for (const kind of ['ability', 'weather', 'held', 'form', 'sub', 'ball', 'obey']) {
    assert.ok(simKinds.includes(kind), `BattleSim3 speaks ${kind} (C5)`);
  }
  const fields = luaTypedKeys(sim, /M\.FIELDS\s*=\s*\{([\s\S]*?)\}/);
  assert.deepStrictEqual(Battle3.Events.FIELDS, fields,
    'lib/battle3/events.js FIELDS mirrors the Lua whitelist, types included');
  const moveFields = luaTypedKeys(sim, /local MOVE_FIELDS\s*=\s*\{([\s\S]*?)\}/);
  assert.deepStrictEqual(Battle3.Events.MOVE_FIELDS, moveFields,
    'and the Gen 3 move row a `moves` event carries');
  // The Gen 3 fields each have a Wire sanitiser (battleEvent reads raw.<field>).
  for (const field of ['target', 'spread', 'stat', 'stage', 'delta', 'holding']) {
    assert.ok(new RegExp(`raw\\.${field}\\b`).test(wire), `Wire.battleEvent must read ${field}`);
  }
});

test('lib/battle3 Turn constants match src/BattleSim3/Turn.lua', () => {
  const turn = read('src/BattleSim3/Turn.lua');
  for (const name of ['VERSION', 'GENERATION', 'MONS_PER_PARTY', 'FIGHTERS_PER_SIDE', 'SEATS_PER_PARTY',
    'CHOICE_TIMEOUT', 'RECONNECT_GRACE', 'RESOLVE_TIMEOUT', 'TIE_BREAK_ROLL', 'AIM_SEED_OFFSET']) {
    assert.strictEqual(luaNumber(turn, name, 'BattleSim3/Turn.lua'), Battle3.Turn[name],
      `BattleSim3 Turn.${name} and lib/battle3 Turn.${name} must match`);
  }
  assert.deepStrictEqual(Object.keys(Battle3.Turn.MODES).sort(),
    ['1v1', 'coop_npc', 'coop_pvp', 'coop_wild', 'wild'], 'the same five modes');
  assert.strictEqual(Battle3.GENERATION, 3);
  const config = read('src/Config.lua');
  assert.strictEqual(luaNumber(config, 'BATTLE_MON_MAX', 'Config.lua'), Battle3.Turn.MONS_PER_PARTY);
  assert.strictEqual(luaNumber(config, 'BATTLE_CHOICE_TIMEOUT', 'Config.lua'),
    Battle3.Turn.CHOICE_TIMEOUT);
});

test('the Gen 3 bag catalog is one table on both sims', () => {
  // docs/plans/gen3-battle-sheet.md §4. Wire / sanitize prove an upload
  // against it and both hubs spend against it, so a one-sided id is an item
  // one hosting path accepts and the other refuses.
  const items = read('src/BattleSim3/Items.lua');
  const body = items.match(/M\.BAG\s*=\s*\{([\s\S]*?)\n\}/);
  assert.ok(body, 'BattleSim3/Items.lua must assign M.BAG');
  // Top-level fields of each row, scalars by value; a nested cure set reads
  // as "set" (its members are pinned by the turn fixtures, which cure).
  const lua = {};
  for (const m of body[1].matchAll(/\[(\d+)\]\s*=\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}/g)) {
    const flat = m[2].replace(/\{[^{}]*\}/g, 'SET');
    const row = {};
    for (const f of flat.matchAll(/(\w+)\s*=\s*("?[\w]+"?)/g)) {
      let v = f[2];
      if (v === 'true') v = true;
      else if (v === 'SET' || v === 'ALL') v = 'set';
      else if (/^"/.test(v)) v = v.slice(1, -1);
      else if (/^\d+$/.test(v)) v = Number(v);
      row[f[1]] = v;
    }
    lua[m[1]] = row;
  }
  const js = {};
  for (const id of Object.keys(Battle3.Items.BAG)) {
    const row = {};
    for (const [k, v] of Object.entries(Battle3.Items.BAG[id])) {
      row[k] = (v !== null && typeof v === 'object') ? 'set' : v;
    }
    js[id] = row;
  }
  assert.deepStrictEqual(js, lua, 'the same ids with the same effects');
  assert.strictEqual(Battle3.Items.bagEffect(5), null, 'the Safari Ball stays unmediated');
  assert.strictEqual(sanitize.effectsFor(3).itemEffect('350').noConsume, true,
    'the Poke Flute is proved but never spent');
});

test('Pay Day rides the outcome of the same fights on both hubs and both sims', () => {
  // Both hubs copy the referee's coins onto an outcome only in the fights the
  // referee counts them for (docs/plans/gen3-battle-sheet.md §6): the three
  // where side a is players and side b is the hub's NPC seats. A one-sided
  // mode is a fight one hosting path pays and the other does not.
  const keys = (body) => [...body.matchAll(/(\w+)\s*=\s*true/g)].map((x) => x[1]).sort();
  const hub = read('src/Hub.lua').match(/local PAY_DAY_MODES\s*=\s*\{([^}]*)\}/);
  assert.ok(hub, 'Hub.lua must declare local PAY_DAY_MODES');
  const relay = read('server/lib/relay.js').match(/const PAY_DAY_MODES\s*=\s*new Set\(\[([^\]]*)\]\)/);
  assert.ok(relay, 'relay.js must declare const PAY_DAY_MODES');
  const relayModes = [...relay[1].matchAll(/'(\w+)'/g)].map((x) => x[1]).sort();
  const sim = read('src/BattleSim3/Turn.lua').match(/local EXP_MODES\s*=\s*\{([^}]*)\}/);
  assert.ok(sim, 'src/BattleSim3/Turn.lua must declare local EXP_MODES');
  const simJs = read('server/lib/battle3/Turn.js').match(/const EXP_MODES\s*=\s*\{([^}]*)\}/);
  assert.ok(simJs, 'lib/battle3/Turn.js must declare const EXP_MODES');
  const simJsModes = [...simJs[1].matchAll(/(\w+):\s*true/g)].map((x) => x[1]).sort();
  assert.deepStrictEqual(keys(hub[1]), relayModes, 'Hub.lua and relay.js pay Pay Day in the same modes');
  assert.deepStrictEqual(keys(hub[1]), keys(sim[1]), "and they are BattleSim3's EXP_MODES");
  assert.deepStrictEqual(simJsModes, keys(sim[1]), 'which the Node sim mirrors');
  assert.deepStrictEqual(relayModes, ['coop_npc', 'coop_wild', 'wild'], 'never a player-vs-player mode');
});

test('a moveset is heard in the fights against the computer alone, on both hubs', () => {
  // No cart levels or learns in a link battle (pokered GainExperience returns
  // on LINK_STATE_BATTLING, pokecrystal / pokegold GiveExperiencePoints on
  // wLinkMode, pokeemerald Cmd_getexp under BATTLE_TYPE_LINK), so both hubs
  // drop `mmo.battle_moveset` whole outside LEARN_MODES -- a Gold 1v1 used to
  // hand forged 999 stats to the referee's levelUp. The hub parity driver
  // (k9_pvp_dropped) pins the behaviour on the real referees; this pins the
  // one set and the one gate on each hub.
  const keys = (body) => [...body.matchAll(/(\w+)\s*=\s*true/g)].map((x) => x[1]).sort();
  const hubSrc = read('src/Hub.lua');
  const relaySrc = read('server/lib/relay.js');
  const hub = hubSrc.match(/local LEARN_MODES\s*=\s*\{([^}]*)\}/);
  assert.ok(hub, 'Hub.lua must declare local LEARN_MODES');
  const relay = relaySrc.match(/const LEARN_MODES\s*=\s*new Set\(\[([^\]]*)\]\)/);
  assert.ok(relay, 'relay.js must declare const LEARN_MODES');
  const relayModes = [...relay[1].matchAll(/'(\w+)'/g)].map((x) => x[1]).sort();
  assert.deepStrictEqual(keys(hub[1]), relayModes, 'Hub.lua and relay.js hear a moveset in the same modes');
  assert.deepStrictEqual(relayModes, ['coop_npc', 'coop_wild', 'wild'], 'never a player-vs-player mode');
  const payDay = hubSrc.match(/local PAY_DAY_MODES\s*=\s*\{([^}]*)\}/);
  assert.deepStrictEqual(keys(hub[1]), keys(payDay[1]), "the fights the referees give experience in, Pay Day's");
  const hubFn = hubSrc.match(/function M:applyBattleMoveset\(record, client, payload\)\n([^\n]*)\n([^\n]*)\n/);
  assert.ok(hubFn, 'Hub.lua must define M:applyBattleMoveset');
  assert.strictEqual(hubFn[2].trim(), 'if not LEARN_MODES[record.mode] then return false end',
    "Hub.lua: the mode gate is the method's first rule after its argument check");
  const relayFn = relaySrc.match(/  applyBattleMoveset\(record, client, payload\) \{\n([^\n]*)\n([^\n]*)\n/);
  assert.ok(relayFn, 'relay.js must define applyBattleMoveset');
  assert.strictEqual(relayFn[2].trim(), 'if (!LEARN_MODES.has(record.mode)) return false;',
    "relay.js: the same gate in the same place");
});

test('cleanInt is Wire.int\'s reading: what LuaJIT\'s tonumber refuses, it refuses', () => {
  // cleanInt was Number(value): true read as 1, false / null / '' / [] as 0,
  // [5] as 5, where Wire.int (tonumber) says nil to every one -- so a Gen 1 /
  // Gen 2 `maxPp: true`, or a `pp: null`, was a sheet one hub kept and the
  // other refused (the review's differential fuzzer). It is luaInt now; the hub
  // parity driver (review_twin_readings) pins the fields, this the reading.
  const values = [true, false, null, undefined, '', ' ', [], [5], {}, { a: 1 }, '0x1p4', ' 7 ',
    '0b11', '+9', '9.', 7.9, -0.5, 'nan', 'Infinity', '1e1', '\u00a05', 0, 100, 101, -1];
  for (const v of values) {
    assert.strictEqual(sanitize.cleanInt(v, 0, 100), sanitize.luaInt(v, 0, 100),
      `cleanInt(${JSON.stringify(v)}) reads as luaInt`);
  }
  for (const v of [true, false, null, '', [], [5], {}]) {
    assert.strictEqual(sanitize.cleanInt(v, 0, 100), null, `${JSON.stringify(v)} is no number`);
  }
  const row = {
    id: 'm', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  assert.strictEqual(sanitize.cleanBattleMove({ ...row, maxPp: true }, 1), null, 'maxPp: true refuses a Gen 1 row');
  assert.strictEqual(sanitize.cleanBattleMove({ ...row, maxPp: true }, 2), null, '...and a Gold one');
  assert.strictEqual(sanitize.cleanBattleMove({ ...row, pp: null }, 1), null, 'a null PP is no PP');
  assert.ok(sanitize.cleanBattleMove({ ...row, maxPp: ' 30 ' }, 1), 'while a string tonumber reads is a number');
});

test('a monster\'s own generation refuses the party when it is no generation, hub or none', () => {
  // Wire.battleParty let an unreadable tag (6, -6, "day") fall through to its
  // stat-key sniff when no hub generation was given, where cleanBattleParty
  // refused -- one upload, two answers. Both refuse now (the stricter reading;
  // every hub passes its generation, so no caller read the fallback).
  const lua = read('src/Wire.lua');
  assert.ok(/if hadExplicit then\n\s*local monGen = M\.int\(entry\.generation, 1, M\.GENERATION_MAX\)\n\s*if not monGen or \(hubGen and monGen ~= hubGen\) then return nil end/
    .test(lua), 'Wire.battleParty: an explicit tag is a generation or the party is refused');
  const sheet = (generation) => ({
    species: 'ALPHA',
    level: 50,
    hp: 100,
    maxHp: 100,
    generation,
    stats: {
      atk: 90, def: 90, spd: 90, spc: 90,
    },
    moves: [{
      id: 'm', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  });
  for (const g of [6, -6, 0, 'day', true]) {
    assert.strictEqual(sanitize.cleanBattleParty({ battle: 'b1', mons: [sheet(g)] }), null,
      `a sheet tagged ${JSON.stringify(g)} refuses the party`);
  }
  assert.ok(sanitize.cleanBattleParty({ battle: 'b1', mons: [sheet(1)] }), 'a real one is read');
});

test('Hub.lua and relay.js name a seat\'s cart family the same way', () => {
  // The referees read a fighter's `family` -- Gen 3's obedience (Focus Punch
  // is exempt on FireRed / LeafGreen, not on Emerald; gen3-battle-sheet.md
  // §1.1), Gen 2's TruncateHL_BC (a loop on Crystal, one pass on Gold /
  // Silver; contract K6 of docs/plans/gen12-referee-fidelity.md) -- and each
  // hub stamps it from the client's own hello version. A cart one hub maps and
  // the other does not is a fight that differs by host.
  const hub = read('src/Hub.lua').match(/local CART_FAMILY\s*=\s*\{([^}]*)\}/);
  assert.ok(hub, 'Hub.lua must declare local CART_FAMILY');
  const relay = read('server/lib/relay.js').match(/const CART_FAMILY\s*=\s*new Map\(\[([\s\S]*?)\]\);/);
  assert.ok(relay, 'relay.js must declare const CART_FAMILY');
  const hubPairs = [...hub[1].matchAll(/(\w+)\s*=\s*"(\w+)"/g)].map((x) => `${x[1]}=${x[2]}`).sort();
  const relayPairs = [...relay[1].matchAll(/\['(\w+)',\s*'(\w+)'\]/g)].map((x) => `${x[1]}=${x[2]}`).sort();
  assert.deepStrictEqual(hubPairs, relayPairs, 'one cart -> family table on both hubs');
  assert.deepStrictEqual(hubPairs, [
    'crystal=crystal', 'emerald=rse', 'firered=frlg', 'gold=gs', 'leafgreen=frlg', 'silver=gs',
  ], 'the three Gold carts (Gen.family names) and the three Gen 3 carts -- never a Kanto one');
  // Both stamp it on a Gen 2 or a Gen 3 hub's human seats and nowhere else.
  const hubGate = read('src/Hub.lua').match(/family = \(\(self\.generation == 2 or self\.generation == 3\) and client\)/);
  assert.ok(hubGate, 'Hub.lua stamps family on generation 2 and 3 seats only');
  const relayGate = read('server/lib/relay.js').match(/const familyGen = this\.generation === 2 \|\| this\.generation === 3;/);
  assert.ok(relayGate, 'relay.js stamps family on generation 2 and 3 seats only');
});

test('the Gen 3 badge rules are one rule on both sims', () => {
  // docs/plans/gen3-badge-rules.md K1-K3: the modes in which side a keeps its
  // trainers' badge boosts and obedience, the cart families whose obedience
  // differs (Focus Punch), and the `obey` event's outcome tokens -- the text
  // Wire / sanitize accept and both screens phrase. The turn fixture proves the
  // two sims fight the same; this proves they name the same things.
  const keys = (body) => [...body.matchAll(/(\w+)\s*=\s*true/g)].map((x) => x[1]).sort();
  const turn = read('src/BattleSim3/Turn.lua');
  const badgeModes = turn.match(/M\.BADGE_MODES\s*=\s*\{([^}]*)\}/);
  assert.ok(badgeModes, 'src/BattleSim3/Turn.lua must assign M.BADGE_MODES');
  assert.deepStrictEqual(Object.keys(Battle3.Turn.BADGE_MODES).sort(), keys(badgeModes[1]),
    'lib/battle3 Turn.BADGE_MODES mirrors the Lua');
  assert.deepStrictEqual(keys(badgeModes[1]), ['coop_npc', 'coop_wild', 'wild'],
    'badge rules never reach a player-vs-player mode');
  const expModes = turn.match(/local EXP_MODES\s*=\s*\{([^}]*)\}/);
  assert.ok(expModes, 'src/BattleSim3/Turn.lua must declare local EXP_MODES');
  assert.deepStrictEqual(keys(badgeModes[1]), keys(expModes[1]), 'the same non-link fights as EXP_MODES');
  const families = turn.match(/M\.FAMILIES\s*=\s*\{([^}]*)\}/);
  assert.ok(families, 'src/BattleSim3/Turn.lua must assign M.FAMILIES');
  assert.deepStrictEqual(Object.keys(Battle3.Turn.FAMILIES).sort(), keys(families[1]),
    'lib/battle3 Turn.FAMILIES mirrors the Lua');
  assert.deepStrictEqual(keys(families[1]), ['frlg', 'rse'], 'the engine BattleProfile families');

  const OBEY_TOKENS = ['falls_asleep', 'hits_itself', 'ignores_asleep', 'loafing',
    'pretend_not_notice', 'turned_away', 'uses_random_move', 'wont_obey'];
  const move = read('src/BattleSim3/Move.lua');
  const loaf = move.match(/local LOAF_LINES\s*=\s*\{([\s\S]*?)\n\}/);
  assert.ok(loaf, 'src/BattleSim3/Move.lua must declare local LOAF_LINES');
  const luaLoaf = [...loaf[1].matchAll(/\{\s*"(\w+)"/g)].map((m) => m[1]);
  assert.deepStrictEqual(Battle3.Move.LOAF_LINES.map(([token]) => token), luaLoaf,
    'the four loaf lines, in the cart order the roll indexes');
  // ...and the closed set the two sanitisers hold an `obey`'s text to.
  assert.deepStrictEqual(luaSet(read('src/Wire.lua'), 'OBEY_TOKENS3'), OBEY_TOKENS,
    'Wire.OBEY_TOKENS3 is the eight outcomes');
  assert.deepStrictEqual([...sanitize.OBEY_TOKENS3].sort(), OBEY_TOKENS,
    'and so is sanitize.js OBEY_TOKENS3');
  const luaTokens = new Set(luaLoaf);
  for (const m of move.matchAll(/_obeyLine\(user, "(\w+)"/g)) luaTokens.add(m[1]);
  const jsTokens = new Set(Battle3.Move.LOAF_LINES.map(([token]) => token));
  const moveJs = read('server/lib/battle3/Move.js');
  for (const m of moveJs.matchAll(/_obeyLine\(user, '(\w+)'/g)) jsTokens.add(m[1]);
  assert.deepStrictEqual([...luaTokens].sort(), OBEY_TOKENS, 'BattleSim3 says the eight outcomes');
  assert.deepStrictEqual([...jsTokens].sort(), OBEY_TOKENS, 'and so does lib/battle3');
  assert.ok(Battle3.Events.KINDS.obey === true, 'an outcome rides its own event kind, `obey`');
});

test("sanitize's luaNumber reads a string as LuaJIT's tonumber does", (t) => {
  // Wire.int is LuaJIT's tonumber, floored and bounded; luaInt spells that
  // reading out (luaNumber) for every Gen 3 field. They used to part on signed
  // hex ("-0x1"), hex fractions and binary, a no-break space (which String#trim
  // strips and Lua does not) and a written exponent past 2^20. Hold the two to
  // one answer over those forms and a seeded spread of generated strings --
  // when luajit is here to ask; skipped (not failed) without it, as the parity
  // suites are.
  const { spawnSync } = require('node:child_process');
  const probe = spawnSync('luajit', ['-v'], { encoding: 'utf8' });
  if (probe.error || probe.status !== 0) {
    t.skip('luajit not on PATH');
    return;
  }
  const cases = new Set([
    '-0x1', '+0x1', '0x1p4', '0x1.8', '0X1F', '0x.8', '0x8.', '0x', '0x-1', '0x1P-1',
    '0x1.8p-1075', '0x1p-1075', '0x1p-1074', '-0x1000000000000000p-1100',
    '0x0.fffffffffffffffffff', '0x1.00000000000008', '0x1.00000000000018', '-0x0', '-0x0p1',
    '0b1', '0b', '0b2', '-0b11', '0B11', '-0b0', `0b0${'1'.repeat(64)}`, `0b${'1'.repeat(65)}`,
    'inf', 'nan', 'Infinity', '1e400', '1e1048576', '1e-1048576', '1e-1048575', '0x0p1048576',
    '  12  ', '\v12\f', ' 12', '12 ', '﻿12', '12\u0000', '1.', '.5', '+.5', '-', '+',
    '1e+', '- 1', '00012', '1_000', '0o7', '-0', '', ' ', `0.${'0'.repeat(900)}1e901`,
    '4294967295.99999999999999999', '0x100000000.0000000001p-4', '0x7fffffff.ffffffff',
  ]);
  let seed = 20260930;
  const rand = () => {
    seed = (seed + 0x6D2B79F5) >>> 0;
    let x = seed;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const run = (alphabet, max) => {
    let out = '';
    for (let n = Math.floor(rand() * max); n > 0; n -= 1) out += pick(alphabet);
    return out;
  };
  const DEC = [...'0123456789'];
  const HEX = [...'0123456789abcdefABCDEF'];
  const SPACE = [' ', '\t', '\n', '\v', '\f', '\r', ' ', ' ', '', ''];
  for (let i = 0; i < 4000; i += 1) {
    let body;
    const kind = Math.floor(rand() * 5);
    if (kind === 0) {
      body = run(DEC, 20) + (rand() < 0.5 ? '.' : '') + run(DEC, 12);
      if (rand() < 0.4) body += pick(['e', 'E']) + pick(['', '+', '-']) + run(DEC, 8);
    } else if (kind === 1) {
      body = pick(['0x', '0X']) + run(HEX, 20) + (rand() < 0.5 ? '.' : '') + run(HEX, 20);
      if (rand() < 0.5) body += pick(['p', 'P']) + pick(['', '+', '-']) + run(DEC, 5);
    } else if (kind === 2) {
      body = pick(['0b', '0B']) + run(['0', '1'], 70);
    } else if (kind === 3) {
      body = run([...'0123456789.eEpPxXbB+- abcdef'], 8);
    } else {
      body = String(Math.floor(rand() * 2000000) - 1000000);
    }
    cases.add(pick(SPACE) + pick(['', '', '+', '-']) + body + pick(SPACE));
  }
  const list = [...cases];
  const script = [
    'for line in io.lines() do',
    "  local s = line:gsub('..', function(h) return string.char(tonumber(h, 16)) end)",
    '  local n = tonumber(s)',
    "  if n == nil or n ~= n or n == math.huge or n == -math.huge then io.write('null\\n')",
    "  else io.write(string.format('%.17g\\n', n)) end",
    'end',
  ].join('\n');
  const lua = spawnSync('luajit', ['-e', script], {
    input: `${list.map((s) => Buffer.from(s, 'utf8').toString('hex')).join('\n')}\n`,
    encoding: 'utf8',
    maxBuffer: 1 << 26,
  });
  assert.strictEqual(lua.status, 0, `luajit failed: ${lua.stderr}`);
  const answers = lua.stdout.trim().split('\n');
  assert.strictEqual(answers.length, list.length, 'one answer per string');
  const differ = [];
  list.forEach((s, i) => {
    const mine = sanitize.luaNumber(s);
    const js = mine === null || !Number.isFinite(mine) ? 'null' : mine;
    const want = answers[i] === 'null' ? 'null' : Number(answers[i]);
    if (js !== want) differ.push(`${JSON.stringify(s)} lua=${answers[i]} js=${js}`);
  });
  assert.deepStrictEqual(differ.slice(0, 10), [], `${differ.length} of ${list.length} strings read differently`);
});

// ---------------------------------------------------------------------------
// Referee fidelity (docs/plans/gen12-referee-fidelity.md K1-K3): the Gen 1 /
// Gen 2 sheet's `traded`, Gold's held-item data, and Gold's own `held` event.
// The hub protocol parity driver (referee_fidelity_dialect) holds the two
// sanitisers to one answer case by case; this pins the bounds and the
// vocabulary they are written against, and the acceptance on the JS side.
// ---------------------------------------------------------------------------

test('the Gold held-item bounds match Wire.lua and sanitize.js', () => {
  // A one-sided bound is a sheet one hosting path fights and the other refuses.
  const wire = read('src/Wire.lua');
  for (const name of ['HOLD_EFFECT2_MAX', 'HOLD_PARAM2_MAX', 'ITEM_NAME2_MAX']) {
    assert.strictEqual(luaNumber(wire, name, 'Wire.lua'), sanitize[name],
      `Wire.${name} and sanitize.${name} must match`);
  }
  assert.strictEqual(sanitize.HOLD_PARAM2_MAX, 255, 'the u8 beside the effect in the cart\'s item attributes');
  assert.strictEqual(sanitize.ITEM_NAME2_MAX, 12, 'pokecrystal ITEM_NAME_LENGTH 13, terminator included');
});

test('Gold\'s event vocabulary: BATTLE_EVENTS2 twins, and both Gen 2 sims speak inside it', () => {
  // K3: a Gen 2-only table, so the Gen 1 sim's exact mirror of BATTLE_EVENTS
  // (tests/battle_sim_turn.lua) never learns a kind its cart cannot produce.
  const wire = read('src/Wire.lua');
  const wireKinds2 = luaSet(wire, 'BATTLE_EVENTS2');
  assert.deepStrictEqual([...sanitize.BATTLE_EVENT_TYPES2].sort(), wireKinds2,
    'Wire.BATTLE_EVENTS2 and sanitize.js BATTLE_EVENT_TYPES2 name the same Gold kinds');
  assert.deepStrictEqual(wireKinds2, ['held'], 'Gold adds exactly one kind, `held`');
  const wireKinds = luaSet(wire, 'BATTLE_EVENTS');
  for (const kind of wireKinds2) {
    assert.ok(!wireKinds.includes(kind), `${kind} is not in the Gen 1 vocabulary`);
    assert.ok(!luaSet(read('src/BattleSim/events.lua'), 'KINDS').includes(kind),
      `the Gen 1 sim does not speak ${kind}`);
  }
  // The Gen 2 sims: the Lua and Node twins name the same kinds, and every one
  // of them is a kind a Gold reader accepts -- BATTLE_EVENTS plus
  // BATTLE_EVENTS2. A subset rather than an equality on purpose: the Gen 2 sim
  // has never spoken every Wire kind (its own header says so), and `held` lands
  // in it after the sanitisers learn it, so this holds before and after.
  const sim2 = luaSet(read('src/BattleSim2/events.lua'), 'KINDS');
  const Events2 = require('./lib/battle2/events.js');
  assert.deepStrictEqual(Object.keys(Events2.KINDS).sort(), sim2,
    'lib/battle2/events.js KINDS mirrors src/BattleSim2/events.lua');
  const gold = new Set([...wireKinds, ...wireKinds2]);
  for (const kind of sim2) {
    assert.ok(gold.has(kind), `BattleSim2 speaks ${kind}, which a Gold reader would refuse`);
  }
});

test('the Gen 1 / Gen 2 sheet: traded (K1) and Gold held-item data (K2)', () => {
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const red = {
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100,
    stats: { atk: 90, def: 90, spd: 90, spc: 90 }, moves: [move],
  };
  const gold = {
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100,
    stats: { atk: 90, def: 90, spe: 90, spa: 90, spd: 90 }, moves: [move],
  };
  for (const [label, mon] of [['Gen 1', red], ['Gen 2', gold]]) {
    assert.strictEqual(cleanBattleMon({ ...mon, traded: true }).traded, true,
      `${label}: traded = true comes through`);
    const off = cleanBattleMon({ ...mon, traded: false });
    assert.ok(off && off.traded === undefined, `${label}: a false is kept as absent`);
    assert.strictEqual(cleanBattleMon({ ...mon, traded: null }).traded, undefined,
      `${label}: a null traded is absent, as Lua reads a JSON null`);
    assert.strictEqual(cleanBattleMon({ ...mon, traded: 'yes' }), null,
      `${label}: a non-boolean traded refuses the mon`);
    assert.strictEqual(cleanBattleMon({ ...mon, traded: 1 }), null,
      `${label}: ...a number included`);
    assert.strictEqual(cleanBattleMon({ ...mon, unfateful: true }).unfateful, undefined,
      `${label}: unfateful stays Gen 3's`);
  }

  const held = {
    heldItem: 'LEFTOVERS', holdEffect: 'HELD_LEFTOVERS', holdParam: 10, itemName: 'LEFTOVERS',
  };
  const kept = cleanBattleMon({ ...gold, ...held, mail: true });
  assert.deepStrictEqual(
    {
      heldItem: kept.heldItem,
      holdEffect: kept.holdEffect,
      holdParam: kept.holdParam,
      itemName: kept.itemName,
      mail: kept.mail,
    },
    { ...held, mail: true },
    'a Gold sheet carries the item\'s effect, parameter, name and Mail flag',
  );
  assert.strictEqual(cleanBattleMon({ ...gold, ...held, mail: false }).mail, undefined,
    'mail = false is kept as absent');
  assert.strictEqual(cleanBattleMon({ ...gold, ...held, mail: 'yes' }), null,
    'a non-boolean mail refuses the mon');
  const bare = cleanBattleMon(gold);
  for (const key of ['holdEffect', 'holdParam', 'itemName', 'mail', 'traded']) {
    assert.strictEqual(bare[key], undefined, `no item, no ${key}: every K1 / K2 field is optional`);
  }
  for (const holdEffect of ['LEFTOVERS', 'HELD_leftovers', 'HELD_', 7,
    `HELD_${'X'.repeat(sanitize.HOLD_EFFECT2_MAX - 4)}`]) {
    assert.strictEqual(cleanBattleMon({ ...gold, holdEffect }), null,
      `an unreadable hold effect (${JSON.stringify(holdEffect)}) refuses the mon`);
  }
  assert.strictEqual(
    cleanBattleMon({ ...gold, holdEffect: `HELD_${'X'.repeat(sanitize.HOLD_EFFECT2_MAX - 5)}` }).holdEffect.length,
    sanitize.HOLD_EFFECT2_MAX, 'a token exactly HOLD_EFFECT2_MAX long comes through',
  );
  assert.strictEqual(cleanBattleMon({ ...gold, holdParam: 256 }), null, 'holdParam past 255 refuses');
  assert.strictEqual(cleanBattleMon({ ...gold, holdParam: true }), null,
    'holdParam is read as Wire.int reads it: a boolean is not a number');
  assert.strictEqual(cleanBattleMon({ ...gold, itemName: 'KINGS ROCK OF OLD' }).itemName,
    'KINGS ROCK O', 'the display name is cut to ITEM_NAME2_MAX, as prose is');
  assert.strictEqual(cleanBattleMon({ ...gold, itemName: '@@@' }), null,
    'a name with nothing drawable left refuses the mon');

  // Gen 1 has no held item to describe: its reader copies none of K2 and
  // refuses nothing over it.
  const redHeld = cleanBattleMon({
    ...red, ...held, holdParam: 999, mail: 'yes',
  });
  assert.ok(redHeld, 'K2 fields on a Gen 1 sheet are ignored, not refused');
  for (const key of ['holdEffect', 'holdParam', 'itemName', 'mail']) {
    assert.strictEqual(redHeld[key], undefined, `the Gen 1 dialect does not copy ${key}`);
  }
});

test('Gold\'s held event (K3): a Gen 2 reader only, id text and a 0 / 1 amount', () => {
  const ev = {
    battle: 'b1', seq: 4, t: 'held', slot: 0, side: 'a', mon: 0, text: 'LEFTOVERS', amount: 1,
  };
  const two = sanitize.cleanBattleEvent(ev, 2);
  assert.ok(two && two.text === 'LEFTOVERS' && two.amount === 1 && two.mon === 0,
    'a Gold reader keeps the item id and the still-held flag');
  assert.strictEqual(sanitize.cleanBattleEvent({ ...ev, amount: 0 }, 2).amount, 0, '0 = the item is gone');
  const bad = sanitize.cleanBattleEvent({
    ...ev, amount: 2, text: 'GOLD BERRY', holding: 3,
  }, 2);
  assert.ok(bad && bad.amount === undefined && bad.text === undefined && bad.holding === undefined,
    'an amount past 1, prose for an id and Gen 3\'s holding are dropped; the event is kept');
  assert.strictEqual(sanitize.cleanBattleEvent(ev, 1), null, 'a Gen 1 reader refuses it');
  const gen3 = {
    battle: 'b1', seq: 5, t: 'held', slot: 3, side: 'b', mon: 0, amount: 139, holding: 0, text: 'ORAN BERRY',
  };
  for (const reader of [3, undefined]) {
    const read3 = sanitize.cleanBattleEvent(gen3, reader);
    assert.ok(read3 && read3.amount === 139 && read3.holding === 0 && read3.text === 'ORAN BERRY',
      `Gen 3's held reads as it always did (reader ${reader})`);
  }
});

// ---------------------------------------------------------------------------
// Referee gaps (docs/plans/gen12-referee-gaps-fix.md K7-K11, K13, K14): the
// Gen 1 / Gen 2 sheet's base / dvs / statExp, a move row's ppUps and Gold
// priority, the moveset's level-up, the older `stat` event's signed stage, the
// Gen 1 / Gen 2 Pay Day bound and Red's Pay Day on an escape, the 40-character
// id and the 64-character map id, the Metronome pool cap and Gold's happiness.
// The hub protocol parity driver (referee_gaps_dialect, levelup_moveset_forward,
// gen12_payday_forward, map_id_bound) holds the twins to one answer case by
// case; this pins the numbers, the key lists and the event field set they are
// written against.
// ---------------------------------------------------------------------------

test('the referee-gap bounds and the Metronome pool cap match Config / Wire / sanitize', () => {
  // A one-sided bound is a sheet, a learn or a coin count one hosting path
  // takes and the other refuses.
  const wire = read('src/Wire.lua');
  for (const name of ['BASE_STAT_MAX', 'DV_MAX', 'STAT_EXP_MAX', 'PP_UPS_MAX', 'PRIORITY2_MAX',
    'STAGE12_MAX', 'PAYDAY12_MAX', 'HAPPINESS2_MAX']) {
    assert.strictEqual(luaNumber(wire, name, 'Wire.lua'), sanitize[name],
      `Wire.${name} and sanitize.${name} must match`);
  }
  assert.strictEqual(sanitize.BASE_STAT_MAX, 255, 'a base stat is one byte on both carts');
  assert.strictEqual(sanitize.DV_MAX, sanitize.IV_MAX, 'a DV is the nibble the `ivs` block already bounds');
  assert.strictEqual(sanitize.STAT_EXP_MAX, sanitize.EV_MAX, 'a stat-exp word is the `evs` block\'s 16 bits');
  assert.strictEqual(sanitize.PP_UPS_MAX, 3, 'PP_UP_MASK is the top two bits of the PP byte');
  assert.strictEqual(sanitize.STAGE12_MAX, sanitize.STAGE3_MAX, 'a stat stage is -6..6 on every cart');
  assert.strictEqual(sanitize.PAYDAY12_MAX, 999999,
    'Red\'s three BCD bytes saturate there, and Gold pays into a MAX_MONEY 999999 wallet');
  assert.ok(sanitize.PAYDAY12_MAX > sanitize.PAYDAY3_MAX, 'the Kanto / Johto bound is the wider one');
  assert.strictEqual(sanitize.HAPPINESS2_MAX, 255, 'MON_HAPPINESS is one byte (K14)');

  const config = read('src/Config.lua');
  assert.strictEqual(luaAssignNumber(config, 'BATTLE_METRONOME_POOL_MAX'), sanitize.METRONOME_POOL_MAX,
    'bump Config.BATTLE_METRONOME_POOL_MAX and sanitize METRONOME_POOL_MAX together');
  assert.ok(sanitize.METRONOME_POOL_MAX >= 251, 'every one of Gold\'s 251 moves fits the pool');
  assert.ok(sanitize.METRONOME_POOL_MAX <= 256,
    'and no more than the 64 KiB line was measured for (Config.lua says how)');
});

test('the K7 key lists are one list per dialect on Wire and sanitize', () => {
  // `base` keyed like `stats` plus hp; `dvs` the cart's four DVs; `statExp` the
  // cart's five stat-exp words. A key one side reads and the other does not is
  // a sheet one hub refuses whole.
  const wire = read('src/Wire.lua');
  const luaKeys = (name) => {
    const m = wire.match(new RegExp(`local ${name}\\s*=\\s*\\{([\\s\\S]*?)\\n\\}`));
    assert.ok(m, `Wire.lua must declare local ${name}`);
    return Object.fromEntries([...m[1].matchAll(/(\w+)\s*=\s*\{([^}]*)\}/g)]
      .map((x) => [x[1], [...x[2].matchAll(/"(\w+)"/g)].map((y) => y[1])]));
  };
  assert.deepStrictEqual(luaKeys('K7_KEYS1'), sanitize.K7_KEYS1, 'the Gen 1 blocks');
  assert.deepStrictEqual(luaKeys('K7_KEYS2'), sanitize.K7_KEYS2, 'the Gen 2 blocks');
  assert.deepStrictEqual(sanitize.K7_KEYS1.base, ['hp', ...sanitize.BATTLE_STATS_GEN1],
    'Gen 1 `base` is `stats` plus hp');
  assert.deepStrictEqual(sanitize.K7_KEYS2.base, ['hp', ...sanitize.BATTLE_STATS_GEN2],
    'Gen 2 `base` is `stats` plus hp, Special split');
  for (const keys of [sanitize.K7_KEYS1, sanitize.K7_KEYS2]) {
    assert.deepStrictEqual(keys.statExp, ['hp', ...keys.dvs], '`statExp` is hp plus the DV keys');
    assert.strictEqual(keys.dvs.length, 4, 'four stored DVs; the HP DV is derived');
  }
});

test('the Gen 1 / Gen 2 event field set (K10): one whitelist on Wire, sanitize and both older sims', () => {
  // Every field an event may carry, each at a value every reader keeps.
  const every = {
    battle: 'b1', seq: 1, t: 'stat', text: 'ATK fell', amount: 2, slot: 0, hp: 5, maxHp: 9,
    species: 'ALPHA', speciesId: 'ALPHA', level: 5, participants: 1, mon: 0, team: 'o',
    side: 'a', status: 'PSN', confused: 1, target: 2, spread: 1, stat: 'atk', stage: -2,
    delta: -2, holding: 3,
    moves: [{
      id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
  const OLDER = ['amount', 'battle', 'confused', 'hp', 'level', 'maxHp', 'mon', 'moves',
    'participants', 'seq', 'side', 'slot', 'species', 'speciesId', 'stage', 'status', 't',
    'team', 'text'];
  const GEN3_ONLY = ['delta', 'holding', 'spread', 'stat', 'target'];
  // K22's `quiet`, which an older reader keeps on an `anim` alone.
  const ANIM_ONLY = ['quiet'];
  for (const reader of [1, 2]) {
    const got = sanitize.cleanBattleEvent(every, reader);
    assert.deepStrictEqual(Object.keys(got).sort(), OLDER,
      `a generation ${reader} reader keeps exactly the older field set`);
    assert.strictEqual(got.stage, -2, `...the signed stage among them (K10, reader ${reader})`);
  }
  // A reader naming none keeps the union; a Gen 3 reader the same, less the
  // older-dialect `moves` row (it has no `num`, so the Gen 3 row refuses it).
  const union = [...OLDER, ...GEN3_ONLY].sort();
  assert.deepStrictEqual(Object.keys(sanitize.cleanBattleEvent(every)).sort(), union,
    'a reader naming none keeps the older set and Gen 3\'s five');
  assert.deepStrictEqual(Object.keys(sanitize.cleanBattleEvent(every, 3)).sort(),
    union.filter((key) => key !== 'moves'), 'a Gen 3 reader keeps the same, less an older move row');
  // Wire.lua reads the same field for the older dialect, in its own branch.
  const wire = read('src/Wire.lua');
  assert.ok(/if older and raw\.stage ~= nil then/.test(wire),
    'Wire.battleEvent reads `stage` for an older reader');
  assert.ok(/-M\.STAGE12_MAX, M\.STAGE12_MAX/.test(wire), '...bounded by STAGE12_MAX');
  // Both older sims (and their Node twins) emit only fields an older reader
  // keeps, so nothing a referee says is dropped on the way to the screen. A
  // subset, so it holds before and after the referees learn `stage`.
  for (const [rel, js] of [['src/BattleSim/events.lua', './lib/battle/events.js'],
    ['src/BattleSim2/events.lua', './lib/battle2/events.js']]) {
    const fields = luaTypedKeys(read(rel), /M\.FIELDS\s*=\s*\{([\s\S]*?)\}/);
    for (const key of Object.keys(fields)) {
      assert.ok(OLDER.includes(key) || ANIM_ONLY.includes(key),
        `${rel} FIELDS.${key} is a field an older reader keeps`);
    }
    const Events = require(js);
    if (Events.FIELDS) {
      assert.deepStrictEqual(Object.keys(Events.FIELDS).sort(), Object.keys(fields).sort(),
        `${js} FIELDS mirrors ${rel}`);
    }
  }
});

test('K13: an id is refused past 40 characters on both twins, never cut', () => {
  // Lua's Wire.id used to cut a long id to 40 where cleanId refused it -- one
  // party fought on the LAN host and refused on the dedicated hub.
  const wire = read('src/Wire.lua');
  const body = wire.match(/function M\.id\(value\)([\s\S]*?)\nend/);
  assert.ok(body, 'Wire.lua must define M.id(value)');
  assert.ok(/#value > 40 then return nil/.test(body[1]), 'Wire.id refuses past 40');
  assert.ok(!/sub\(1, 40\)/.test(body[1]), 'and no longer cuts');
  assert.strictEqual(sanitize.cleanId('i'.repeat(40)), 'i'.repeat(40));
  assert.strictEqual(sanitize.cleanId('i'.repeat(41)), null);
});

test('K13\'s twin: a map id is refused past 64 characters on both twins, never cut', () => {
  // Lua's Wire.mapId used to cut a long map id to 64 where cleanMapId refused
  // it -- a player the node hub left unplaced stood on a truncated map on the
  // LAN host.
  const wire = read('src/Wire.lua');
  const body = wire.match(/function M\.mapId\(value\)([\s\S]*?)\nend/);
  assert.ok(body, 'Wire.lua must define M.mapId(value)');
  assert.ok(/#value > 64 then return nil/.test(body[1]), 'Wire.mapId refuses past 64');
  assert.ok(!/sub\(1, 64\)/.test(body[1]), 'and no longer cuts');
  assert.strictEqual(sanitize.cleanMapId('m'.repeat(64)), 'm'.repeat(64));
  assert.strictEqual(sanitize.cleanMapId('m'.repeat(65)), null);
});

test('K14: Gold\'s happiness rides a Gen 2 sheet only, and refuses the sheet when unreadable', () => {
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const red = {
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100,
    stats: { atk: 90, def: 90, spd: 90, spc: 90 }, moves: [move],
  };
  const gold = {
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100,
    stats: { atk: 90, def: 90, spe: 90, spa: 90, spd: 90 }, moves: [move],
  };
  for (const happiness of [0, 70, 255]) {
    assert.strictEqual(cleanBattleMon({ ...gold, happiness }).happiness, happiness,
      `a Gold sheet carries happiness ${happiness}`);
  }
  assert.strictEqual(cleanBattleMon(gold).happiness, undefined, 'absent stays absent');
  assert.strictEqual(cleanBattleMon({ ...gold, happiness: null }).happiness, undefined,
    'a null is absent, as Lua reads a JSON null');
  for (const happiness of [256, -1, true, 'fond', [70]]) {
    assert.strictEqual(cleanBattleMon({ ...gold, happiness }), null,
      `an unreadable happiness (${JSON.stringify(happiness)}) refuses the sheet, K7's posture`);
  }
  // Red has no happiness byte: its reader neither copies nor refuses one.
  for (const happiness of [70, 999, 'fond']) {
    const read = cleanBattleMon({ ...red, happiness });
    assert.ok(read && read.happiness === undefined,
      `a Gen 1 sheet ignores happiness ${JSON.stringify(happiness)}`);
  }
  // Wire.lua reads it under the same gate, by the same bound.
  const wire = read('src/Wire.lua');
  assert.ok(/if generation == 2 and raw\.happiness ~= nil then/.test(wire),
    'Wire.battleMon reads happiness on a Gen 2 sheet only');
  assert.ok(/M\.int\(raw\.happiness, 0, M\.HAPPINESS2_MAX\)/.test(wire), '...bounded by HAPPINESS2_MAX');
});

test('K11 on an escape: both hubs carry Pay Day on a run on Red alone', () => {
  // pokered pays wTotalPayDayMoney on a Teleport / Whirlwind / Roar / POKE DOLL
  // escape (wBattleResult stays 0); Gold calls every escape a DRAW and Gen 3
  // pays only on a win. The hub parity driver pins the behaviour
  // (gen12_payday_forward); this pins that each hub has the one gate.
  const hub = read('src/Hub.lua').match(/local function paysDay\(generation, mode, outcome\)([\s\S]*?)\nend/);
  assert.ok(hub, 'Hub.lua must define paysDay(generation, mode, outcome)');
  assert.ok(/if outcome\.reason == "run" then return generation == 1 end/.test(hub[1]),
    'Hub.lua: a run pays on generation 1 alone');
  const relay = read('server/lib/relay.js').match(/function paysDay\(generation, mode, outcome\) \{([\s\S]*?)\n\}/);
  assert.ok(relay, 'relay.js must define paysDay(generation, mode, outcome)');
  assert.ok(/if \(outcome\.reason === 'run'\) return generation === 1;/.test(relay[1]),
    'relay.js: a run pays on generation 1 alone');
  assert.ok(/paysDay\(self\.generation, record\.mode, outcome\)/.test(read('src/Hub.lua')),
    'Hub.lua settles through it');
  assert.ok(/paysDay\(this\.generation, record\.mode, outcome\)/.test(read('server/lib/relay.js')),
    'relay.js settles through it');
});

// ---------------------------------------------------------------------------
// Wave 4 of docs/plans/gen12-referee-gaps-fix.md: Red's MIMIC pick on a Gen 1
// choice (`mimic`) and Gold's wTimeOfDay on a Gen 2 ruleset (`timeOfDay`). The
// hub protocol parity driver (referee_gaps_wave4_dialect, overlay_learn_and_time)
// holds the twins to one answer case by case; this pins the vocabulary, the
// generation gates and the hand-off to the Gold referee's create.
// ---------------------------------------------------------------------------

test('Gold\'s time of day: one closed set on Wire, sanitize and both Gold referees', () => {
  // pokecrystal / pokegold ram_constants MORN_F / DAY_F / NITE_F, spelled as the
  // Gold referee's Turn TIMES keys (what `create` reads as opts.timeOfDay). A
  // spelling one side takes and the other refuses is a ruleset one hosting path
  // fights under and the other refuses.
  const wire = read('src/Wire.lua');
  const times = luaSet(wire, 'TIMES_OF_DAY2');
  assert.deepStrictEqual([...sanitize.TIMES_OF_DAY2].sort(), times, 'Wire and sanitize name the same times');
  assert.deepStrictEqual(times, ['day', 'morn', 'nite'], 'MORN_F, DAY_F and NITE_F -- no DARKNESS_F palette');
  assert.deepStrictEqual(luaSet(read('src/BattleSim2/Turn.lua'), 'TIMES'), times,
    'the Lua Gold referee reads the same spellings');
  const js = read('server/lib/battle2/Turn.js').match(/const TIMES = \{([^}]*)\}/);
  assert.ok(js, 'lib/battle2 Turn.js must declare TIMES');
  assert.deepStrictEqual([...js[1].matchAll(/(\w+):\s*true/g)].map((x) => x[1]).sort(), times,
    'and so does the Node one');
});

test('Gold\'s time of day rides a Gen 2 ruleset only, and refuses it when unknown', () => {
  const chart = [[100, 100], [100, 100]];
  for (const time of ['morn', 'day', 'nite']) {
    assert.strictEqual(sanitize.cleanBattleRuleset({ chart, timeOfDay: time }, 2).timeOfDay, time,
      `a Gold ruleset carries ${time}`);
  }
  assert.strictEqual(sanitize.cleanBattleRuleset({ chart }, 2).timeOfDay, undefined, 'absent stays absent');
  assert.strictEqual(sanitize.cleanBattleRuleset({ chart, timeOfDay: null }, 2).timeOfDay, undefined,
    'a null is absent, as Lua reads a JSON null');
  for (const time of ['NITE', 'night', 'eve', 'darkness', '', 2, true, ['nite']]) {
    assert.strictEqual(sanitize.cleanBattleRuleset({ chart, timeOfDay: time }, 2), null,
      `an unknown time (${JSON.stringify(time)}) refuses the Gold ruleset`);
  }
  for (const gen of [1, undefined]) {
    for (const time of ['nite', 'evening']) {
      const read1 = sanitize.cleanBattleRuleset({ chart, timeOfDay: time }, gen);
      assert.ok(read1 && read1.timeOfDay === undefined,
        `a ruleset read for generation ${gen} neither keeps nor refuses ${time}`);
    }
  }
  const wire = read('src/Wire.lua');
  assert.ok(/if M\.int\(generation, 2, 2\) and raw\.timeOfDay ~= nil then/.test(wire),
    'Wire.battleRuleset reads timeOfDay on a Gen 2 hub only');
  assert.ok(/if not M\.TIMES_OF_DAY2\[raw\.timeOfDay\] then return nil end/.test(wire),
    '...and refuses the ruleset on an unknown one');
  // Both hubs hand it to the Gold referee's create, and only there.
  const hub = read('src/Hub.lua');
  assert.ok(/if self\.generation == 2 then\s+createOpts\.timeOfDay = rules\.timeOfDay\s+end/.test(hub),
    'Hub.lua passes timeOfDay into Turn.create on a Gen 2 hub');
  const relay = read('server/lib/relay.js');
  assert.ok(/if \(this\.generation === 2\) \{\s+createOpts\.timeOfDay = rules\.timeOfDay;\s+\}/.test(relay),
    'relay.js passes timeOfDay into Turn.attempt on a Gen 2 hub');
});

test('Red\'s MIMIC pick rides a Gen 1 choice only, 0..3, and refuses the choice out of range', () => {
  const fight = (mimic) => ({
    battle: 'b1', action: 'fight', move: 0, mimic,
  });
  for (const pick of [0, 1, 2, 3]) {
    assert.strictEqual(sanitize.cleanBattleChoice(fight(pick), 1).mimic, pick, `a Gen 1 choice carries ${pick}`);
  }
  assert.strictEqual(sanitize.cleanBattleChoice(fight('2'), 1).mimic, 2, 'a numeric string reads as Lua reads it');
  assert.strictEqual(sanitize.cleanBattleChoice(fight(null), 1).mimic, undefined, 'a null is absent');
  for (const pick of [4, -1, true, 'one', [1]]) {
    assert.strictEqual(sanitize.cleanBattleChoice(fight(pick), 1), null,
      `an unreadable pick (${JSON.stringify(pick)}) refuses the Gen 1 choice`);
  }
  for (const gen of [2, 3, undefined]) {
    const read2 = sanitize.cleanBattleChoice(fight(9), gen);
    assert.ok(read2 && read2.mimic === undefined, `a choice read for generation ${gen} ignores mimic`);
  }
  assert.strictEqual(sanitize.BATTLE_MOVE_MAX - 1, 3, 'the pick is bounded by the move list\'s own width');
  const wire = read('src/Wire.lua');
  assert.ok(/if M\.int\(generation, 1, 1\) and raw\.mimic ~= nil then/.test(wire),
    'Wire.battleChoice reads mimic on a Gen 1 hub only');
  assert.ok(/out\.mimic = M\.int\(raw\.mimic, 0, Config\.BATTLE_MOVE_MAX - 1\)/.test(wire),
    '...bounded by BATTLE_MOVE_MAX - 1');
  // The Red referee is what reads it (`_normaliseChoice`, then `_mimicPick`).
  assert.ok(/choice\.mimic ~= nil/.test(read('src/BattleSim/Turn.lua')), 'BattleSim reads choice.mimic');
  assert.ok(/choice\.mimic/.test(read('server/lib/battle/Turn.js')), 'lib/battle reads choice.mimic');
});

// ---------------------------------------------------------------------------
// Wave 5 of docs/plans/gen12-referee-gaps-fix.md: Red's TypeEffects order on a
// Gen 1 ruleset (`chartOrder`), Gold's BASE_GENDER in a Gen 2 sheet's `base`
// (K15), Gold's BATON PASS successor on a Gen 2 choice (`pass`) and a Gold
// Metronome pool row's cart number (`num`). The hub protocol parity driver
// (referee_gaps_wave5_dialect, wave5_hub_fields) holds the twins to one answer
// case by case; this pins the numbers, the generation gates and the hand-off
// to each referee.
// ---------------------------------------------------------------------------

test('wave 5 bounds: chartOrder and the Gold pool number match Wire, sanitize and both referees', () => {
  const wire = read('src/Wire.lua');
  assert.strictEqual(luaNumber(wire, 'CHART_ORDER_MAX', 'Wire.lua'), sanitize.CHART_ORDER_MAX,
    'Wire.CHART_ORDER_MAX and sanitize.CHART_ORDER_MAX must match');
  assert.strictEqual(luaNumber(wire, 'NUM_ATTACKS2', 'Wire.lua'), sanitize.NUM_ATTACKS2,
    'Wire.NUM_ATTACKS2 and sanitize.NUM_ATTACKS2 must match');
  // Two integers a TypeEffects row: the wire takes exactly the rows the Red
  // referee's chartRowsOf takes, on both twins.
  const rows1 = luaNumber(read('src/BattleSim/Turn.lua'), 'CHART_ORDER_MAX', 'BattleSim/Turn.lua');
  assert.strictEqual(sanitize.CHART_ORDER_MAX, 2 * rows1, 'twice BattleSim Turn.CHART_ORDER_MAX');
  assert.strictEqual(sanitize.CHART_ORDER_MAX, 2 * require('./lib/battle/Turn.js').CHART_ORDER_MAX,
    'twice lib/battle Turn CHART_ORDER_MAX');
  assert.ok(sanitize.CHART_ORDER_MAX >= 164, 'pokered TypeEffects (82 rows) fits');
  // pokecrystal / pokegold NUM_ATTACKS, which `.GetMove` compares its byte with.
  assert.strictEqual(sanitize.NUM_ATTACKS2, 251, 'Gold has 251 moves');
  assert.strictEqual(luaNumber(read('src/BattleSim2/Turn.lua'), 'NUM_ATTACKS', 'BattleSim2/Turn.lua'),
    sanitize.NUM_ATTACKS2, 'the Lua Gold referee redraws past the same number');
  const js2 = read('server/lib/battle2/Turn.js').match(/const NUM_ATTACKS = (\d+);/);
  assert.ok(js2, 'lib/battle2 Turn.js must declare NUM_ATTACKS');
  assert.strictEqual(Number(js2[1]), sanitize.NUM_ATTACKS2, 'and so does the Node one');
  assert.ok(sanitize.NUM_ATTACKS2 <= sanitize.METRONOME_POOL_MAX, 'every numbered Gold move fits the pool');
});

test('Red\'s chartOrder rides a Gen 1 ruleset only, refused whole when unreadable', () => {
  const chart = [[100, 100], [100, 100]];
  const read1 = (chartOrder) => sanitize.cleanBattleRuleset({ chart, chartOrder }, 1);
  assert.deepStrictEqual(read1([0, 1, 1, 0]).chartOrder, [0, 1, 1, 0], 'a Red ruleset carries its order');
  assert.deepStrictEqual(read1([0, null, 1]).chartOrder, [0, 1], 'a JSON null is closed up, as Lua decodes it');
  assert.deepStrictEqual(read1(['3', 2]).chartOrder, [3, 2], 'a numeric string reads as Wire.int reads it');
  assert.strictEqual(read1(null).chartOrder, undefined, 'a null is absent');
  assert.strictEqual(read1(undefined).chartOrder, undefined, 'absent stays absent');
  for (const bad of [[0, 1, 1], [], [null], [sanitize.BATTLE_TYPE_MAX, 0], [-1, 0], [true, 0], ['x', 0],
    [[1], 0], { a: 1 }, '0,1', 7, new Array(sanitize.CHART_ORDER_MAX + 2).fill(0)]) {
    assert.strictEqual(read1(bad), null, `an unreadable order (${JSON.stringify(bad).slice(0, 30)}) refuses the ruleset`);
  }
  assert.strictEqual(read1(new Array(sanitize.CHART_ORDER_MAX).fill(1)).chartOrder.length,
    sanitize.CHART_ORDER_MAX, 'an order at the cap is taken whole');
  for (const gen of [2, undefined]) {
    for (const order of [[0, 1], 'bad']) {
      const got = sanitize.cleanBattleRuleset({ chart, chartOrder: order }, gen);
      assert.ok(got && got.chartOrder === undefined,
        `a ruleset read for generation ${gen} neither keeps nor refuses ${JSON.stringify(order)}`);
    }
  }
  const wire = read('src/Wire.lua');
  assert.ok(/if M\.int\(generation, 1, 1\) and raw\.chartOrder ~= nil then/.test(wire),
    'Wire.battleRuleset reads chartOrder on a Gen 1 hub only');
  assert.ok(/out\.chartOrder = chartOrderOf\(raw\.chartOrder\)\s+if out\.chartOrder == nil then return nil end/
    .test(wire), '...and refuses the ruleset on an unreadable one');
  // Both hubs hand it to the Red referee's create, and only there.
  assert.ok(/if self\.generation == 1 then\s+createOpts\.chartOrder = rules\.chartOrder\s+end/
    .test(read('src/Hub.lua')), 'Hub.lua passes chartOrder into Turn.create on a Gen 1 hub');
  assert.ok(/if \(this\.generation === 1\) \{\s+createOpts\.chartOrder = rules\.chartOrder;\s+\}/
    .test(read('server/lib/relay.js')), 'relay.js passes chartOrder into Turn.attempt on a Gen 1 hub');
  assert.ok(/chartRowsOf\(opts\.chartOrder\)/.test(read('src/BattleSim/Turn.lua')), 'BattleSim reads opts.chartOrder');
  assert.ok(/chartRowsOf\(opts\.chartOrder\)/.test(read('server/lib/battle/Turn.js')),
    'lib/battle reads opts.chartOrder');
});

test('K15: Gold\'s BASE_GENDER rides a Gen 2 sheet\'s base block, refusing the sheet when unreadable', () => {
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const B1 = {
    hp: 41, atk: 52, def: 63, spd: 74, spc: 85,
  };
  const B2 = {
    hp: 41, atk: 52, def: 63, spe: 74, spa: 85, spd: 96,
  };
  const red = (base) => ({
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100, stats: { atk: 90, def: 90, spd: 90, spc: 90 }, moves: [move], base,
  });
  const gold = (base) => ({
    species: 'ALPHA',
    level: 50,
    hp: 100,
    maxHp: 100,
    stats: {
      atk: 90, def: 90, spe: 90, spa: 90, spd: 90,
    },
    moves: [move],
    base,
  });
  for (const gender of [0, 31, 254, 255]) {
    assert.strictEqual(cleanBattleMon(gold({ ...B2, gender })).base.gender, gender,
      `a Gold sheet carries ratio ${gender}`);
  }
  assert.deepStrictEqual(cleanBattleMon(gold(B2)).base, B2, 'a base block with no ratio reads as before (K7)');
  assert.strictEqual(cleanBattleMon(gold({ ...B2, gender: null })).base.gender, undefined, 'a null is absent');
  for (const gender of [256, -1, true, 'male', [31]]) {
    assert.strictEqual(cleanBattleMon(gold({ ...B2, gender })), null,
      `an unreadable ratio (${JSON.stringify(gender)}) refuses the sheet, K7's posture`);
  }
  assert.strictEqual(cleanBattleMon(gold({ gender: 31 })), null, 'a ratio is no base block without the base stats');
  for (const gender of [254, 'male']) {
    const got = cleanBattleMon(red({ ...B1, gender }));
    assert.ok(got && got.base.gender === undefined, `a Red sheet ignores ratio ${JSON.stringify(gender)}`);
  }
  assert.ok(!sanitize.K7_KEYS2.base.includes('gender'), 'the ratio is optional: not a K7 key the block needs');
  const wire = read('src/Wire.lua');
  assert.ok(/if generation == 2 and raw\.base\.gender ~= nil then/.test(wire),
    'Wire.battleMon reads base.gender on a Gen 2 sheet only');
  assert.ok(/out\.base\.gender = M\.int\(raw\.base\.gender, 0, M\.BASE_STAT_MAX\)/.test(wire),
    '...bounded by BASE_STAT_MAX');
  // Both Gold referees copy it with the base block, for Effects.gender.
  assert.ok(/base = \{ keys = \{[^}]*"gender" \}/.test(read('src/BattleSim2/Turn.lua')),
    'BattleSim2 keeps base.gender');
  assert.ok(require('./lib/battle2/Turn.js').SHEET_BLOCKS.base.keys.includes('gender'), 'lib/battle2 keeps base.gender');
});

test('Gold\'s BATON PASS `pass` rides a Gen 2 choice as Gen 3\'s, and a Gen 1 hub ignores it', () => {
  const fight = (pass) => ({
    battle: 'b1', action: 'fight', move: 0, pass,
  });
  for (const pass of [0, 2, sanitize.SLOT_MAX]) {
    assert.strictEqual(sanitize.cleanBattleChoice(fight(pass), 2).pass, pass, `a Gold choice carries ${pass}`);
  }
  assert.strictEqual(sanitize.cleanBattleChoice(fight('2'), 2).pass, 2, 'a numeric string reads as Lua reads it');
  assert.strictEqual(sanitize.cleanBattleChoice(fight(null), 2).pass, undefined, 'a null is absent');
  for (const pass of [sanitize.SLOT_MAX + 1, -1, true, 'two', [1]]) {
    for (const gen of [2, 3]) {
      assert.strictEqual(sanitize.cleanBattleChoice(fight(pass), gen), null,
        `an unreadable pass (${JSON.stringify(pass)}) refuses the generation ${gen} choice`);
    }
  }
  for (const gen of [1, undefined]) {
    const got = sanitize.cleanBattleChoice(fight(9), gen);
    assert.ok(got && got.pass === undefined, `a choice read for generation ${gen} ignores pass`);
  }
  assert.strictEqual(sanitize.cleanBattleChoice({ ...fight(2), dexCaught: true }, 2).dexCaught, undefined,
    'the dex word stays Gen 3\'s');
  const wire = read('src/Wire.lua');
  assert.ok(/if M\.int\(generation, 2, 3\) and raw\.pass ~= nil then/.test(wire),
    'Wire.battleChoice reads pass on a Gen 2 or Gen 3 hub');
  assert.ok(/out\.pass = M\.int\(raw\.pass, 0, M\.SLOT_MAX\)/.test(wire), '...bounded by SLOT_MAX');
  assert.ok(/choice\.pass/.test(read('src/BattleSim2/Turn.lua')), 'BattleSim2 reads choice.pass');
  assert.ok(/choice\.pass/.test(read('server/lib/battle2/Turn.js')), 'lib/battle2 reads choice.pass');
});

test('a Gold Metronome pool row\'s `num` rides a Gen 2 ruleset only, refusing it when unreadable', () => {
  const chart = [[100, 100], [100, 100]];
  const row = (num) => ({
    id: 'm', pp: 10, power: 0, accuracy: 255, type: 0, effect: 0, chance: 0, num,
  });
  const read2 = (num) => sanitize.cleanBattleRuleset({ chart, metronomePool: [row(num)] }, 2);
  for (const num of [1, 7, sanitize.NUM_ATTACKS2]) {
    assert.strictEqual(read2(num).metronomePool[0].num, num, `a Gold pool row carries ${num}`);
  }
  assert.strictEqual(read2('7').metronomePool[0].num, 7, 'a numeric string reads as Wire.int reads it');
  assert.strictEqual(read2(null).metronomePool[0].num, undefined, 'a null is absent');
  for (const num of [0, -1, sanitize.NUM_ATTACKS2 + 1, true, 'x', [7]]) {
    assert.strictEqual(read2(num), null, `an unreadable number (${JSON.stringify(num)}) refuses the Gold ruleset`);
  }
  for (const gen of [1, undefined]) {
    for (const num of [7, 999]) {
      const got = sanitize.cleanBattleRuleset({ chart, metronomePool: [row(num)] }, gen);
      assert.ok(got && got.metronomePool[0].num === undefined,
        `a ruleset read for generation ${gen} neither keeps nor refuses pool num ${num}`);
    }
  }
  const sheet = cleanBattleMon({
    species: 'ALPHA',
    level: 50,
    hp: 100,
    maxHp: 100,
    stats: {
      atk: 90, def: 90, spe: 90, spa: 90, spd: 90,
    },
    moves: [row(7)],
  });
  assert.ok(sheet && sheet.moves[0].num === undefined, 'a Gold sheet\'s own move rows still leave num behind');
  // The pool is one list on both twins: a JSON null row closed up (the engine's
  // decoder does it before Wire.lua sees the list), a non-empty object refused.
  assert.strictEqual(sanitize.cleanBattleRuleset({ chart, metronomePool: [row(3), null, row(4)] }, 2)
    .metronomePool.length, 2, 'a null pool row is closed up, as Lua decodes it');
  assert.strictEqual(sanitize.cleanBattleRuleset({ chart, metronomePool: { a: row(3) } }, 2), null,
    'an object where the pool belongs is refused');
  const wire = read('src/Wire.lua');
  assert.ok(/if not isList\(raw\.metronomePool\) then return nil end/.test(wire),
    'Wire.battleRuleset reads the Gen 1 / Gen 2 pool as a list');
  assert.ok(/if rowGeneration == 2 and entry\.num ~= nil then\s+move\.num = M\.int\(entry\.num, 1, M\.NUM_ATTACKS2\)/
    .test(wire), 'Wire.battleRuleset reads a pool row\'s num on a Gen 2 hub only, bounded by NUM_ATTACKS2');
  assert.ok(/opts\.metronomePool\[i\]\.num/.test(read('src/BattleSim2/Turn.lua')), 'BattleSim2 reads the pool num');
  assert.ok(/\.num/.test(read('server/lib/battle2/Turn.js')), 'lib/battle2 reads it too');
});

// ---------------------------------------------------------------------------
// Wave 6 of docs/plans/gen12-referee-gaps-fix.md: the carts' battle glyphs in a
// Red / Gold `msg`, an NPC party's Red `aiMods` and Red / Gold `name`, and the
// chart / specialTypes nulls closed up alike. The hub parity driver
// (referee_gaps_wave6_dialect, wave6_hub_fields) holds the readers to one
// answer case by case; this pins the bounds, the glyph set and the hub lines.
// ---------------------------------------------------------------------------

test('wave 6 bounds: the NPC name cap and the aiMods bounds match Wire, sanitize and both Red referees', () => {
  const wire = read('src/Wire.lua');
  for (const name of ['NPC_NAME_MAX', 'AI_MOD_MAX', 'AI_MODS_MAX']) {
    assert.strictEqual(luaNumber(wire, name, 'Wire.lua'), sanitize[name],
      `Wire.${name} and sanitize.${name} must match`);
  }
  // pokered TRAINER_NAME_LENGTH 13 (twelve: "COOLTRAINER♂"); Gold's
  // PlaceEnemysName prints wOTClassName, a space, then the trainer's name
  // (TRAINER_CLASS_NAME_LENGTH 13, NAME_LENGTH 11): 12 + 1 + 10.
  assert.strictEqual(sanitize.NPC_NAME_MAX, 23, 'the longest name either cart prints for its computer');
  assert.ok(sanitize.NPC_NAME_MAX > sanitize.NAME_MAX, 'wider than a player name, which cuts COOLTRAINER');
  assert.strictEqual(sanitize.AI_MOD_MAX, 4, 'pokered has four AIMoveChoiceModification pointers');
  assert.strictEqual(luaNumber(read('src/BattleSim/Turn.lua'), 'MAX_AI_MODS', 'BattleSim/Turn.lua'),
    sanitize.AI_MODS_MAX, 'the wire takes exactly the layers BattleSim keeps');
  assert.strictEqual(require('./lib/battle/Turn.js').MAX_AI_MODS, sanitize.AI_MODS_MAX,
    'and lib/battle keeps');
});

test('a Red / Gold msg keeps the carts\' battle glyphs; player-typed text does not', () => {
  const msg = (text, gen) => {
    const event = sanitize.cleanBattleEvent({
      battle: 'b1', seq: 1, t: 'msg', text,
    }, gen);
    return event ? event.text : undefined;
  };
  for (const gen of [1, 2]) {
    assert.strictEqual(msg('Both POKéMON will faint in 3 turns!', gen), 'Both POKéMON will faint in 3 turns!',
      `a Gen ${gen} reader keeps é`);
    assert.strictEqual(msg('X ignored orders…sleeping!', gen), 'X ignored orders…sleeping!', '...and …');
    assert.strictEqual(msg('JR.TRAINER♂ used X ATTACK on COOLTRAINER♀!', gen),
      'JR.TRAINER♂ used X ATTACK on COOLTRAINER♀!', '...and ♂ ♀');
    assert.strictEqual(msg('TWINS AMY & MAY used an item', gen), 'TWINS AMY & MAY used an item', '...and &');
    assert.strictEqual(msg('é'.repeat(90), gen), 'é'.repeat(sanitize.BATTLE_LINE_MAX),
      'the cut counts glyphs, at BATTLE_LINE_MAX (K18; MESSAGE_MAX before)');
    assert.strictEqual(msg('POKÉMON ¥ <PK> _ \u{1F600}', gen), 'POKMON PK', 'nothing else past the old set');
  }
  for (const gen of [3, undefined]) {
    assert.strictEqual(msg('Both POKéMON will faint…', gen), 'Both POKMON will faint',
      `a reader for generation ${gen} reads a msg as before`);
  }
  assert.strictEqual(sanitize.cleanBattleEvent({
    battle: 'b1', seq: 1, t: 'chose', text: 'COOLTRAINER♂',
  }, 1).text, 'COOLTRAINER', 'every other kind\'s text reads as before');
  assert.strictEqual(sanitize.cleanText('POKéMON & …', 60), 'POKMON', 'chat, names and rooms stay narrow');
  const wire = read('src/Wire.lua');
  assert.ok(/elseif older and raw\.t == "msg" then\s+out\.text = M\.battleLine\(raw\.text\)/
    .test(wire), 'Wire.battleEvent reads an older msg through M.battleLine (K17 / K18)');
  assert.ok(/local ALLOWED = "\[\^A-Za-z0-9 %\.,!%\?'%-:;%\(%\)\/\]"/.test(wire), 'Wire.text\'s set is unchanged');
  assert.ok(/local BATTLE_ASCII = "\[A-Za-z0-9 %\.,!%\?'%-:;%\(%\)\/&\]"/.test(wire),
    'Wire.battleText\'s ASCII is M.text\'s plus &');
  // The multi-byte glyphs, as the byte escapes Wire.lua lists them.
  const block = wire.match(/M\.BATTLE_GLYPHS = \{([\s\S]*?)\n\}/);
  assert.ok(block, 'Wire.lua must define M.BATTLE_GLYPHS');
  const luaGlyphs = [...block[1].matchAll(/\["((?:\\\d+)+)"\] = true/g)]
    .map((m) => Buffer.from(m[1].split('\\').filter(Boolean).map(Number)).toString('utf8'))
    .sort();
  assert.deepStrictEqual(luaGlyphs, ['é', '…', '♀', '♂'].sort(), 'é … ♂ ♀, as whole UTF-8 sequences');
  for (const glyph of luaGlyphs) {
    assert.strictEqual(sanitize.cleanBattleText(glyph), glyph, `cleanBattleText keeps ${glyph}`);
  }
});

test('battle lines read byte for byte alike on Wire.battleText and cleanBattleText', (t) => {
  // Each string is bytes as a hub receives them: Lua reads the bytes, Node the
  // string its UTF-8 decoding makes of them (a stray sequence is U+FFFD). Skipped
  // (not failed) without luajit, as the parity suites are.
  const { spawnSync } = require('node:child_process');
  const probe = spawnSync('luajit', ['-v'], { encoding: 'utf8' });
  if (probe.error || probe.status !== 0) {
    t.skip('luajit not on PATH');
    return;
  }
  const pieces = ['c3a9', 'e280a6', 'e29982', 'e29980', 'c3', 'a9', 'e280', 'e299', 'e2', '80', 'a6',
    'f09f9880', 'f09f98', 'eda080', 'c0a9', 'c2a0', 'efbbbf', 'ff', 'c389', 'c3a8', 'c2a5', '20', '2020',
    '09', '0a', '00', '26', '23', '3c', '5f', '50', '4f', '4b', '41', '39', '2e', '21', '27', '2d', '7e'];
  let seed = 20261005;
  const rand = () => {
    seed = (seed + 0x6D2B79F5) >>> 0;
    let x = seed;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
  const cases = [];
  for (let i = 0; i < 3000; i += 1) {
    let hex = '';
    for (let n = Math.floor(rand() * 40); n > 0; n -= 1) hex += pieces[Math.floor(rand() * pieces.length)];
    if (i % 50 === 0) hex = 'c3a9'.repeat(30 + (i % 7)) + '2078'.repeat(i % 5);
    const limit = [0, 1, 5, 23, 60, 61][i % 6];
    cases.push({ hex, limit });
  }
  const script = [
    `package.path = "${ROOT}/?.lua;" .. package.path`,
    'local cache = {}',
    'local function need(name)',
    '  if cache[name] ~= nil then return cache[name] end',
    `  local h = assert(io.open("${ROOT}/src/" .. name .. ".lua", "rb"))`,
    '  local body = h:read("*a"); h:close()',
    '  cache[name] = assert((loadstring or load)(body, "@" .. name))(need)',
    '  return cache[name]',
    'end',
    'local Wire = need("Wire")',
    'for line in io.lines() do',
    '  local limit, hex = line:match("^(%d+) (%x*)$")',
    "  local s = hex:gsub('..', function(h) return string.char(tonumber(h, 16)) end)",
    '  local out = Wire.battleText(s, limit ~= "0" and tonumber(limit) or nil)',
    "  io.write(out and (out:gsub('.', function(c) return string.format('%02x', c:byte()) end)) or 'nil', '\\n')",
    'end',
  ].join('\n');
  const lua = spawnSync('luajit', ['-e', script], {
    input: `${cases.map((c) => `${c.limit} ${c.hex}`).join('\n')}\n`,
    encoding: 'utf8',
    maxBuffer: 1 << 26,
  });
  assert.strictEqual(lua.status, 0, `luajit failed: ${lua.stderr}`);
  const answers = lua.stdout.trim().split('\n');
  assert.strictEqual(answers.length, cases.length, 'one answer per string');
  const differ = [];
  cases.forEach((c, i) => {
    const js = sanitize.cleanBattleText(Buffer.from(c.hex, 'hex').toString('utf8'), c.limit || undefined);
    const mine = js === null ? 'nil' : Buffer.from(js, 'utf8').toString('hex');
    if (mine !== answers[i]) differ.push(`${c.hex}/${c.limit}: lua=${answers[i]} js=${mine}`);
  });
  assert.deepStrictEqual(differ.slice(0, 10), [], `${differ.length} of ${cases.length} lines read differently`);
});

test('an NPC party\'s Red aiMods and Red / Gold name: read by dialect, carried to NPC seats alone', () => {
  const sheet1 = {
    species: 'ALPHA',
    level: 50,
    hp: 100,
    maxHp: 100,
    stats: {
      atk: 90, def: 90, spd: 90, spc: 90,
    },
    moves: [{
      id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
    }],
  };
  const sheet2 = {
    ...sheet1,
    stats: {
      atk: 90, def: 90, spe: 90, spa: 90, spd: 90,
    },
  };
  const party = (extra, gen) => sanitize.cleanBattleParty({
    battle: 'b1', mons: [gen === 2 ? sheet2 : sheet1], ...extra,
  }, gen);
  assert.deepStrictEqual(party({ aiMods: [1, 3] }, 1).aiMods, [1, 3], 'a Red party carries its layers');
  assert.deepStrictEqual(party({ aiMods: [] }, 1).aiMods, [], 'an empty list is a class with no layer');
  assert.deepStrictEqual(party({ aiMods: [2, null, '3'] }, 1).aiMods, [2, 3],
    'a JSON null is closed up and a numeric string read as Wire.int reads it');
  for (const bad of [[0], [5], [true], [[1]], [''], new Array(sanitize.AI_MODS_MAX + 1).fill(1), { a: 1 }, '1,2', 3]) {
    assert.strictEqual(party({ aiMods: bad }, 1), null,
      `unreadable layers (${JSON.stringify(bad)}) refuse the Red party`);
  }
  assert.strictEqual(party({ aiMods: new Array(sanitize.AI_MODS_MAX).fill(4) }, 1).aiMods.length,
    sanitize.AI_MODS_MAX, 'a list at the cap is taken whole');
  for (const gen of [2, undefined]) {
    const got = party({ aiMods: [9] }, gen);
    assert.ok(got && got.aiMods === undefined, `a party read for generation ${gen} neither keeps nor refuses layers`);
  }
  assert.strictEqual(party({ name: 'COOLTRAINER♂' }, 1).name, 'COOLTRAINER♂', 'a Red trainer\'s name, ♂ and all');
  assert.strictEqual(party({ name: 'TWINS AMY & MAY' }, 2).name, 'TWINS AMY & MAY', 'a Gold "<CLASS> <NAME>"');
  assert.strictEqual(party({ name: 'FIREBREATHER ABCDEFGHIJK' }, 2).name, 'FIREBREATHER ABCDEFGHIJ',
    'cut at NPC_NAME_MAX');
  for (const bad of [42, '', '\u{1F600}', ['A'], true]) {
    const got = party({ name: bad }, 1);
    assert.ok(got && got.name === undefined, `an unreadable name (${JSON.stringify(bad)}) is dropped, not fatal`);
  }
  assert.strictEqual(party({ name: 'ROCKET' }).name, undefined, 'a party read for no generation reads no name');

  const wire = read('src/Wire.lua');
  assert.ok(/if partyGen == 1 and raw\.aiMods ~= nil then\s+out\.aiMods = aiModsOf\(raw\.aiMods\)\s+if out\.aiMods == nil then return nil end/
    .test(wire), 'Wire.battleParty reads aiMods on a Red party and refuses it unreadable');
  assert.ok(/if \(partyGen == 1 or partyGen == 2\) and raw\.name ~= nil then\s+out\.name = M\.npcName\(raw\.name\)/
    .test(wire), 'Wire.battleParty reads the name on a Red / Gold party');
  // Both hubs deal both facts onto every NPC seat, and hand them to the referee
  // from there alone.
  const hub = read('src/Hub.lua');
  assert.ok(/name = party\.name, aiMods = party\.aiMods,/.test(hub), 'Hub:fillBattleParty copies both onto NPC seats');
  assert.ok(/or \(npc and \(party\.name or "TRAINER"\) or seat\),\s+aiMods = npc and party\.aiMods or nil,/.test(hub),
    'Hub:tryStartSim names an NPC seat from its party and passes its layers');
  const relay = read('server/lib/relay.js');
  assert.ok(/if \(party\.name\) seatParty\.name = party\.name;\s+if \(party\.aiMods\) seatParty\.aiMods = party\.aiMods;/
    .test(relay), 'relay fillBattleParty copies both onto NPC seats');
  assert.ok(/\|\| \(npc \? \(party\.name \|\| 'TRAINER'\) : seat\),[\s\S]{0,200}if \(npc && party\.aiMods\) entry\.aiMods = party\.aiMods;/
    .test(relay), 'relay tryStartSim names an NPC seat from its party and passes its layers');
  // ...and both Red referees read them off the roster entry.
  assert.ok(/copyAiMods\(entry\.aiMods\)/.test(read('src/BattleSim/Turn.lua')), 'BattleSim reads entry.aiMods');
  assert.ok(/copyAiMods\(entry\.aiMods\)/.test(read('server/lib/battle/Turn.js')), 'lib/battle reads entry.aiMods');
});

// ---------------------------------------------------------------------------
// Contracts K16-K18 and K21 of docs/plans/gen12-referee-remaining-gaps.md: a
// Red / Gold battle line's `^a` / `^b` name marks and `\n` breaks, cut at
// BATTLE_LINE_MAX (and `^` in no name); the computer's item / switch facts on
// an NPC party (Red `aiClass`, Gold `trainerItems` / `aiFlags` / `itemSwitch` /
// `baseReward`); Gold's sheet `weight` and ruleset `battleType`. The hub parity
// driver (remaining_gaps_dialect, remaining_gaps_hub_fields) holds the readers
// and both hubs to one answer case by case; this pins the bounds, the gates and
// the hand-offs.
// ---------------------------------------------------------------------------

test('K18: BATTLE_LINE_MAX matches Config.lua, and chat keeps MESSAGE_MAX', () => {
  const config = read('src/Config.lua');
  assert.strictEqual(luaAssignNumber(config, 'BATTLE_LINE_MAX'), sanitize.BATTLE_LINE_MAX,
    'bump Config.BATTLE_LINE_MAX and sanitize BATTLE_LINE_MAX together');
  assert.strictEqual(sanitize.BATTLE_LINE_MAX, 80, 'a battle line is 80 glyphs, marks and breaks included');
  assert.strictEqual(luaAssignNumber(config, 'MESSAGE_MAX'), 60, 'chat keeps its sixty');
  assert.strictEqual(sanitize.MESSAGE_MAX, 60, '...on both twins');
  assert.strictEqual(sanitize.BATTLE_MARK, '^', 'one mark glyph');
  const wire = read('src/Wire.lua');
  assert.ok(/M\.BATTLE_MARK = "\^"/.test(wire), 'Wire spells the same mark');
  assert.deepStrictEqual(luaSet(wire, 'BATTLE_MARK_SIDES'), [...sanitize.BATTLE_MARK_SIDES].sort(),
    'and the same two side letters');
  assert.deepStrictEqual([...sanitize.BATTLE_MARK_SIDES].sort(), ['A', 'B', 'a', 'b'],
    'a and b, the two sides -- and A and B, K17\'s side-word marks');
  assert.ok(/function M\.battleLine\(value, limit\)\s+return battleGlyphs\(value, limit or Config\.BATTLE_LINE_MAX, true\)/
    .test(wire), 'Wire.battleLine cuts at Config.BATTLE_LINE_MAX');
});

test('K17 / K18: a Red / Gold msg keeps its name marks and breaks; nothing else does', () => {
  const msg = (text, gen, t = 'msg') => {
    const event = sanitize.cleanBattleEvent({
      battle: 'b1', seq: 1, t, text,
    }, gen);
    return event ? event.text : undefined;
  };
  for (const gen of [1, 2]) {
    assert.strictEqual(msg('^bRATTATA used\nTACKLE!', gen), '^bRATTATA used\nTACKLE!',
      `a Gen ${gen} line keeps a mark and a break`);
    assert.strictEqual(msg('^aPIKA\'s\nattack missed!', gen), '^aPIKA\'s\nattack missed!', '...either side');
    assert.strictEqual(msg('  ^bX \n  used \n\n Y ! \n ', gen), '^bX\nused\nY !',
      'a space beside a break collapses into it; never leading, trailing or doubled');
    assert.strictEqual(msg('\n\nX\n', gen), 'X', 'a break alone at either end is dropped');
    assert.strictEqual(msg('^cX ^^aY ^', gen), 'cX ^aY', 'a ^ without its side letter is dropped, alone');
    assert.strictEqual(msg('^AX', gen), '^AX', 'a side-word mark (K17, wave 2) is kept as a name mark is');
    assert.strictEqual(msg('^BPOKéMON\'s\nLIGHT SCREEN fell!', gen), '^BPOKéMON\'s\nLIGHT SCREEN fell!',
      '...either side (HandleScreens\' `.Your` / `.Enemy` ahead of BattleText_MonsLightScreenFell)');
    assert.strictEqual(msg('^C ^^BY', gen), 'C ^BY', '...and a ^ before any other capital is dropped, alone');
    assert.strictEqual(msg(`${'A'.repeat(78)}^BXY`, gen), 'A'.repeat(78), '...cut as a name mark is');
    assert.strictEqual(msg('A\r\nB\tC', gen), 'A\nBC', 'a CR or a tab is no break');
    assert.strictEqual(msg(`${'A'.repeat(78)}^bXY`, gen), 'A'.repeat(78),
      'a cut that leaves a mark with no name drops the mark');
    assert.strictEqual(msg(`${'A'.repeat(79)}^bXY`, gen), 'A'.repeat(79), '...and a ^ with no letter');
    assert.strictEqual(msg(`${'A'.repeat(79)} B`, gen), 'A'.repeat(79), '...and the gap it was waiting for');
    assert.strictEqual(msg(`${'A'.repeat(79)}\nB`, gen), 'A'.repeat(79), '...a break included');
    assert.strictEqual(msg('X'.repeat(81), gen), 'X'.repeat(80), 'cut at 80');
  }
  for (const gen of [3, undefined]) {
    assert.strictEqual(msg('^bRATTATA used\nTACKLE!', gen), 'bRATTATA usedTACKLE!',
      `a reader for generation ${gen} reads a msg as before: no mark, no break`);
  }
  for (const gen of [1, 2]) {
    for (const t of ['run', 'send', 'chose']) {
      assert.strictEqual(msg('^aANN\nX', gen, t), 'aANNX', `a ${t}'s text is a name: no mark, no break`);
    }
  }
  // The walker, as Wire.battleLine / cleanBattleLine, and the plain reading.
  assert.strictEqual(sanitize.cleanBattleLine('^aX'), '^aX');
  assert.strictEqual(sanitize.cleanBattleLine('^aXY', 2), null, 'a line that is only a cut mark is no line');
  assert.strictEqual(sanitize.cleanBattleText('^aX\nY'), 'aXY', 'cleanBattleText reads no mark and no break');
  assert.strictEqual(sanitize.plainBattleLine('^aPIKA used\nTHUNDER on ^bONIX!'), 'PIKA used THUNDER on ONIX!',
    'the plain reading: marks gone, breaks spaces');
  assert.strictEqual(sanitize.plainBattleLine('It\'s super-\neffective!'), 'It\'s super-effective!',
    'a word split over two rows after a hyphen joins with no space');
  assert.strictEqual(sanitize.plainBattleLine('^APOKéMON\'s\nLIGHT SCREEN fell!'), 'POKéMON\'s LIGHT SCREEN fell!',
    'the plain reading drops a side-word mark too');
  assert.strictEqual(sanitize.plainBattleLine('^B^bX'), 'X', '...all four of them');
  const wire = read('src/Wire.lua');
  assert.ok(/text:gsub\("%\^\[abAB\]", ""\)/.test(wire), 'Wire.plainBattleLine drops all four marks');
  assert.strictEqual(sanitize.plainBattleLine(undefined), undefined, 'not a string: back as it came');
});

test('K17: a ^ reaches no name field on either twin', () => {
  const caret = '^aANN^b';
  assert.strictEqual(sanitize.cleanText(caret, sanitize.NAME_MAX), 'aANNb', 'a player name (hello, presence)');
  assert.strictEqual(sanitize.cleanNpcName(caret), 'aANNb', 'an NPC seat\'s trainer name');
  assert.strictEqual(sanitize.cleanBattleText(caret), 'aANNb', 'the glyph reader names are read through');
  assert.strictEqual(sanitize.cleanMoveName(caret), 'aANNb', 'a move or item name');
  assert.strictEqual(sanitize.cleanLabel(caret), 'aANNb', 'a fight label');
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const red = {
    species: caret, level: 50, hp: 100, maxHp: 100, stats: { atk: 90, def: 90, spd: 90, spc: 90 }, moves: [move],
  };
  const gold = { ...red, stats: { atk: 90, def: 90, spe: 90, spa: 90, spd: 90 }, itemName: caret, heldItem: 'BERRY' };
  assert.strictEqual(cleanBattleMon(red).species, 'aANNb', 'a Red monster\'s name (its nickname)');
  assert.strictEqual(cleanBattleMon(gold).species, 'aANNb', 'a Gold monster\'s name');
  assert.strictEqual(cleanBattleMon(gold).itemName, 'aANNb', '...and its held item\'s');
  const party = sanitize.cleanBattleParty({ battle: 'b1', mons: [red], name: caret }, 1);
  assert.strictEqual(party.name, 'aANNb', 'the party\'s trainer name');
  for (const gen of [1, 2, 3]) {
    const exp = sanitize.cleanBattleEvent({
      battle: 'b1', seq: 1, t: 'exp', species: caret, level: 5, participants: 1,
    }, gen);
    assert.strictEqual(exp.species, 'aANNb', `an exp event's species, generation ${gen}`);
  }
});

test('battle lines read byte for byte alike on Wire.battleLine and cleanBattleLine', (t) => {
  // Wire.battleText's differential run, with the two marks' bytes in the mix:
  // `^`, its side letters, a break, a CR, and every cap a cut can leave a mark,
  // a ^ or a gap hanging at. Each line also runs through the plain reading
  // (Wire.plainBattleLine / plainBattleLine) on both sides.
  const { spawnSync } = require('node:child_process');
  const probe = spawnSync('luajit', ['-v'], { encoding: 'utf8' });
  if (probe.error || probe.status !== 0) {
    t.skip('luajit not on PATH');
    return;
  }
  const pieces = ['5e', '5e61', '5e62', '5e63', '5e41', '5e42', '5e43', '5e5e', '61', '62', '0a', '0a0a', '200a', '0a20', '0d0a', '2d0a',
    '0d', '09', '20', '2020', 'c3a9', 'e280a6', 'e29982', 'e29980', 'c3', 'a9', 'e2', '80', 'f09f9880', 'c0a9',
    'ff', 'c389', '26', '23', '3c', '5f', '50', '4f', '4b', '41', '39', '2e', '21', '27', '2d', '7e', '00'];
  let seed = 20261006;
  const rand = () => {
    seed = (seed + 0x6D2B79F5) >>> 0;
    let x = seed;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
  const cases = [];
  for (let i = 0; i < 4000; i += 1) {
    let hex = '';
    for (let n = Math.floor(rand() * 50); n > 0; n -= 1) hex += pieces[Math.floor(rand() * pieces.length)];
    if (i % 40 === 0) hex = '41'.repeat(70 + (i % 13)) + ['5e6142', '0a42', '2042', '5e42'][i % 4].repeat(4);
    const limit = [0, 1, 2, 3, 5, 23, 60, 79, 80, 81][i % 10];
    cases.push({ hex, limit });
  }
  const script = [
    `package.path = "${ROOT}/?.lua;" .. package.path`,
    'local cache = {}',
    'local function need(name)',
    '  if cache[name] ~= nil then return cache[name] end',
    `  local h = assert(io.open("${ROOT}/src/" .. name .. ".lua", "rb"))`,
    '  local body = h:read("*a"); h:close()',
    '  cache[name] = assert((loadstring or load)(body, "@" .. name))(need)',
    '  return cache[name]',
    'end',
    'local Wire = need("Wire")',
    "local function hex(s) return s and (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) or 'nil' end",
    'for line in io.lines() do',
    '  local limit, h = line:match("^(%d+) (%x*)$")',
    "  local s = h:gsub('..', function(x) return string.char(tonumber(x, 16)) end)",
    '  local out = Wire.battleLine(s, limit ~= "0" and tonumber(limit) or nil)',
    "  io.write(hex(out), ' ', hex(out and Wire.plainBattleLine(out)), '\\n')",
    'end',
  ].join('\n');
  const lua = spawnSync('luajit', ['-e', script], {
    input: `${cases.map((c) => `${c.limit} ${c.hex}`).join('\n')}\n`,
    encoding: 'utf8',
    maxBuffer: 1 << 26,
  });
  assert.strictEqual(lua.status, 0, `luajit failed: ${lua.stderr}`);
  const answers = lua.stdout.trim().split('\n');
  assert.strictEqual(answers.length, cases.length, 'one answer per string');
  const hexOf = (s) => (s === null ? 'nil' : Buffer.from(s, 'utf8').toString('hex'));
  const differ = [];
  let marks = 0;
  let breaks = 0;
  cases.forEach((c, i) => {
    const js = sanitize.cleanBattleLine(Buffer.from(c.hex, 'hex').toString('utf8'), c.limit || undefined);
    const mine = `${hexOf(js)} ${hexOf(js === null ? null : sanitize.plainBattleLine(js))}`;
    if (js && js.includes('^')) marks += 1;
    if (js && js.includes('\n')) breaks += 1;
    if (mine !== answers[i]) differ.push(`${c.hex}/${c.limit}: lua=${answers[i]} js=${mine}`);
  });
  assert.deepStrictEqual(differ.slice(0, 10), [], `${differ.length} of ${cases.length} lines read differently`);
  assert.ok(marks > 100 && breaks > 100, `the run reached marks (${marks}) and breaks (${breaks})`);
});

test('K16: an NPC party\'s Red aiClass and Gold trainer facts, read by dialect, carried to NPC seats alone', () => {
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const sheet1 = {
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100, stats: { atk: 90, def: 90, spd: 90, spc: 90 }, moves: [move],
  };
  const sheet2 = { ...sheet1, stats: { atk: 90, def: 90, spe: 90, spa: 90, spd: 90 } };
  const party = (extra, gen) => sanitize.cleanBattleParty({
    battle: 'b1', mons: [gen === 2 ? sheet2 : sheet1], ...extra,
  }, gen);
  // Red: the engine's ai_classes record, field by field.
  assert.deepStrictEqual(party({
    aiClass: {
      uses: 2, chance: 64, item: 'X_ATTACK', bogus: 1,
    },
  }, 1).aiClass, { uses: 2, chance: 64, item: 'X_ATTACK' }, 'BLACKBELT-shaped, an unknown key dropped');
  assert.deepStrictEqual(party({
    aiClass: {
      uses: 2, switchChance: 20, chance: 128, item: 'SUPER_POTION', hpBelow: 4,
    },
  }, 1).aiClass, {
    uses: 2, switchChance: 20, chance: 128, item: 'SUPER_POTION', hpBelow: 4,
  }, 'AGATHA-shaped');
  assert.deepStrictEqual(party({
    aiClass: {
      uses: 1, item: 'HYPER_POTION', hpBelow: 10, switchBelow: 5, switch: false,
    },
  }, 1).aiClass, {
    uses: 1, item: 'HYPER_POTION', hpBelow: 10, switchBelow: 5,
  }, 'COOLTRAINER_F-shaped, a false flag absent');
  assert.deepStrictEqual(party({ aiClass: { uses: '5', onStatus: true, item: 'FULL_HEAL' } }, 1).aiClass,
    { uses: 5, onStatus: true, item: 'FULL_HEAL' }, 'BROCK-shaped, a numeric string read as Wire.int');
  assert.deepStrictEqual(party({ aiClass: { uses: 3, chance: 256, switch: true } }, 1).aiClass,
    { uses: 3, chance: 256, switch: true }, 'JUGGLER-shaped, chance at its 256');
  assert.strictEqual(party({ aiClass: null }, 1).aiClass, undefined, 'a null is absent');
  for (const bad of [{}, { chance: 64 }, { uses: 0 }, { uses: 256 }, { uses: true }, { uses: 1, chance: 257 },
    { uses: 1, chance: -1 }, { uses: 1, switchChance: 300 }, { uses: 1, hpBelow: 0 }, { uses: 1, switchBelow: 256 },
    { uses: 1, item: 'X ATTACK' }, { uses: 1, item: 7 }, { uses: 1, switch: 1 }, { uses: 1, onStatus: 'yes' },
    [3], 'GenericAI', 3]) {
    assert.strictEqual(party({ aiClass: bad }, 1), null,
      `an unreadable record (${JSON.stringify(bad)}) refuses the Red party`);
  }
  for (const gen of [2, undefined]) {
    const got = party({ aiClass: { uses: 0 } }, gen);
    assert.ok(got && got.aiClass === undefined, `a party read for generation ${gen} neither keeps nor refuses one`);
  }
  // Gold: TrainerClassAttributes' item slots, AI words and base reward.
  assert.deepStrictEqual(party({
    trainerItems: ['FULL_HEAL', 'POTION'], aiFlags: 0, itemSwitch: 513, baseReward: 25,
  }, 2), {
    ...party({}, 2), trainerItems: ['FULL_HEAL', 'POTION'], aiFlags: 0, itemSwitch: 513, baseReward: 25,
  }, 'all four, the item slots in order and a zero kept');
  assert.deepStrictEqual(party({ trainerItems: [] }, 2).trainerItems, [], 'no item at all is a list');
  assert.deepStrictEqual(party({ trainerItems: [null, 'POTION'] }, 2).trainerItems, ['POTION'],
    'a JSON null closed up, as the Lua decoder does');
  assert.deepStrictEqual(party({ aiFlags: 65535, itemSwitch: '4', baseReward: 255 }, 2),
    { ...party({}, 2), aiFlags: 65535, itemSwitch: 4, baseReward: 255 }, 'at their bounds');
  for (const bad of [{ trainerItems: ['A', 'B', 'C'] }, { trainerItems: ['FULL HEAL'] }, { trainerItems: [7] },
    { trainerItems: { a: 'POTION' } }, { trainerItems: 'POTION' }, { aiFlags: 65536 }, { aiFlags: -1 },
    { aiFlags: true }, { itemSwitch: [1] }, { itemSwitch: '' }, { baseReward: 256 }, { baseReward: 'x' }]) {
    assert.strictEqual(party(bad, 2), null, `${JSON.stringify(bad)} refuses the Gold party`);
  }
  for (const gen of [1, undefined]) {
    const got = party({
      trainerItems: ['A', 'B', 'C'], aiFlags: -1, itemSwitch: -1, baseReward: -1,
    }, gen);
    assert.ok(got && ['trainerItems', 'aiFlags', 'itemSwitch', 'baseReward'].every((k) => got[k] === undefined),
      `a party read for generation ${gen} neither keeps nor refuses Gold's four`);
  }
  // The bounds, on both twins.
  const wire = read('src/Wire.lua');
  for (const name of ['AI_USES_MAX', 'AI_CHANCE_MAX', 'AI_DIVISOR_MAX', 'TRAINER_ITEMS2_MAX', 'AI_FLAGS2_MAX',
    'BASE_REWARD2_MAX']) {
    assert.strictEqual(luaNumber(wire, name, 'Wire.lua'), sanitize[name], `Wire.${name} and sanitize.${name} must match`);
  }
  assert.ok(/if partyGen == 1 and raw\.aiClass ~= nil then\s+out\.aiClass = aiClassOf\(raw\.aiClass\)\s+if out\.aiClass == nil then return nil end/
    .test(wire), 'Wire.battleParty reads aiClass on a Red party and refuses it unreadable');
  assert.ok(/if partyGen == 2 then\s+if raw\.trainerItems ~= nil then/.test(wire),
    'Wire.battleParty reads Gold\'s four on a Gold party');
  // Both hubs deal them onto every NPC seat and hand them to the referee from
  // there alone.
  const hub = read('src/Hub.lua');
  assert.ok(/aiClass = party\.aiClass, trainerItems = party\.trainerItems,\s+aiFlags = party\.aiFlags, itemSwitch = party\.itemSwitch,\s+baseReward = party\.baseReward,/
    .test(hub), 'Hub:fillBattleParty copies all five onto NPC seats');
  for (const key of ['aiClass', 'trainerItems', 'aiFlags', 'itemSwitch', 'baseReward']) {
    assert.ok(new RegExp(`${key} = npc and party\\.${key} or nil,`).test(hub), `Hub:tryStartSim hands ${key} on`);
  }
  const relay = read('server/lib/relay.js');
  for (const key of ['aiClass', 'trainerItems']) {
    assert.ok(new RegExp(`if \\(party\\.${key}\\) seatParty\\.${key} = party\\.${key};`).test(relay),
      `relay fillBattleParty copies ${key}`);
    assert.ok(new RegExp(`if \\(npc && party\\.${key}\\) entry\\.${key} = party\\.${key};`).test(relay),
      `relay tryStartSim hands ${key} on`);
  }
  for (const key of ['aiFlags', 'itemSwitch', 'baseReward']) {
    assert.ok(new RegExp(`if \\(party\\.${key} !== undefined\\) seatParty\\.${key} = party\\.${key};`).test(relay),
      `relay fillBattleParty copies ${key}, a zero included`);
    assert.ok(new RegExp(`if \\(npc && party\\.${key} !== undefined\\) entry\\.${key} = party\\.${key};`).test(relay),
      `relay tryStartSim hands ${key} on, a zero included`);
  }
});

test('K21: Gold\'s sheet weight and ruleset battleType ride Gen 2 alone, and reach the Gold referee', () => {
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const red = {
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100, stats: { atk: 90, def: 90, spd: 90, spc: 90 }, moves: [move],
  };
  const gold = { ...red, stats: { atk: 90, def: 90, spe: 90, spa: 90, spd: 90 } };
  for (const weight of [0, 4600, 65535]) {
    assert.strictEqual(cleanBattleMon({ ...gold, weight }).weight, weight, `a Gold sheet carries weight ${weight}`);
  }
  assert.strictEqual(cleanBattleMon({ ...gold, weight: '300' }).weight, 300, 'read as Wire.int reads it');
  assert.strictEqual(cleanBattleMon({ ...gold, weight: null }).weight, undefined, 'a null is absent');
  for (const weight of [65536, -1, true, 'heavy', [300]]) {
    assert.strictEqual(cleanBattleMon({ ...gold, weight }), null,
      `an unreadable weight (${JSON.stringify(weight)}) refuses the sheet`);
  }
  for (const weight of [300, 70000, 'heavy']) {
    const got = cleanBattleMon({ ...red, weight });
    assert.ok(got && got.weight === undefined, `a Gen 1 sheet ignores weight ${JSON.stringify(weight)}`);
  }
  const chart = [[100, 100], [100, 100]];
  for (const battleType of [0, 4, 255, '4']) {
    assert.strictEqual(sanitize.cleanBattleRuleset({ chart, battleType }, 2).battleType, Number(battleType),
      `a Gold ruleset carries battleType ${JSON.stringify(battleType)}`);
  }
  assert.strictEqual(sanitize.cleanBattleRuleset({ chart, battleType: null }, 2).battleType, undefined,
    'a null is absent');
  for (const battleType of [256, -1, true, 'FISH', [4]]) {
    assert.strictEqual(sanitize.cleanBattleRuleset({ chart, battleType }, 2), null,
      `an unreadable battleType (${JSON.stringify(battleType)}) refuses the Gold ruleset`);
  }
  for (const gen of [1, undefined]) {
    const got = sanitize.cleanBattleRuleset({ chart, battleType: 'FISH' }, gen);
    assert.ok(got && got.battleType === undefined, `a ruleset read for generation ${gen} neither keeps nor refuses one`);
  }
  const wire = read('src/Wire.lua');
  for (const name of ['WEIGHT2_MAX', 'BATTLE_TYPE2_MAX']) {
    assert.strictEqual(luaNumber(wire, name, 'Wire.lua'), sanitize[name], `Wire.${name} and sanitize.${name} must match`);
  }
  assert.ok(/if generation == 2 and raw\.weight ~= nil then\s+out\.weight = M\.int\(raw\.weight, 0, M\.WEIGHT2_MAX\)/
    .test(wire), 'Wire.battleMon reads weight on a Gen 2 sheet only');
  assert.ok(/if M\.int\(generation, 2, 2\) and raw\.battleType ~= nil then/.test(wire),
    'Wire.battleRuleset reads battleType on a Gen 2 hub only');
  // Both hubs hand the ruleset's battleType to the Gold referee's create, which
  // reads it (and a sheet's weight) itself.
  assert.ok(/if self\.generation == 2 then\s+createOpts\.battleType = rules\.battleType\s+end/.test(read('src/Hub.lua')),
    'Hub.lua passes battleType into Turn.create on a Gen 2 hub');
  assert.ok(/if \(this\.generation === 2\) \{\s+createOpts\.battleType = rules\.battleType;\s+\}/
    .test(read('server/lib/relay.js')), 'relay.js passes it too');
  assert.ok(/battleType\s+= optInt\(opts\.battleType, 0, 255\)/.test(read('src/BattleSim2/Turn.lua')),
    'BattleSim2 reads opts.battleType');
  assert.ok(/this\.battleType = optInt\(opts\.battleType, 0, 255\)/.test(read('server/lib/battle2/Turn.js')),
    'lib/battle2 reads opts.battleType');
  assert.ok(/weight = optInt\(raw\.weight, 0, 65535\)/.test(read('src/BattleSim2/Turn.lua')),
    'BattleSim2 keeps a sheet\'s weight');
  assert.ok(/const weight = optInt\(raw\.weight, 0, 65535\)/.test(read('server/lib/battle2/Turn.js')),
    'lib/battle2 keeps it');
  assert.strictEqual(sanitize.WEIGHT2_MAX, 65535, 'the dex weight word');
  assert.strictEqual(sanitize.BATTLE_TYPE2_MAX, 255, 'wBattleType is one byte');
});

test('a Gen 1 / Gen 2 chart and specialTypes close a JSON null up, as the Lua decoder does', () => {
  const rules = (extra, gen = 1) => sanitize.cleanBattleRuleset({ chart: [[100, 100], [100, 100]], ...extra }, gen);
  assert.deepStrictEqual(sanitize.cleanChart([[100, null, 50], null, [0, 200]]), [[100, 50], [0, 200]],
    'a null row and a null cell are closed up');
  assert.strictEqual(sanitize.cleanChart([[null, null]]), null, 'a row of nulls is an empty row');
  for (const bad of [[[true, 100]], [[[100], 50]], [['', 50]], [[100, 50], { a: 1 }], { a: [100] }]) {
    assert.strictEqual(sanitize.cleanChart(bad), null, `${JSON.stringify(bad)} is no chart on either twin`);
  }
  assert.deepStrictEqual(sanitize.cleanChart([['100', ' 50 ']]), [[100, 50]], 'a numeric string reads as Wire.int');
  assert.deepStrictEqual(rules({ specialTypes: [1, null, 0] }).specialTypes, [1, 0], 'a null index is closed up');
  assert.deepStrictEqual(rules({ specialTypes: [null] }, 2).specialTypes, [], '...to the empty list');
  assert.deepStrictEqual(rules({ specialTypes: {} }).specialTypes, [], 'an empty object is the empty list');
  for (const bad of [{ a: 1 }, [true], [[1]], [''], '1']) {
    assert.strictEqual(rules({ specialTypes: bad }), null, `${JSON.stringify(bad)} refuses the ruleset`);
  }
  const wire = read('src/Wire.lua');
  assert.ok(/if raw\.specialTypes ~= nil then\s+if not isList\(raw\.specialTypes\) then return nil end/.test(wire),
    'Wire.battleRuleset reads specialTypes as a list');
  const src = read('server/lib/sanitize.js');
  assert.ok(/function cleanChart\(value\) \{\s+const list = luaList\(value\);/.test(src), 'cleanChart closes rows up');
  assert.ok(/const row = luaList\(entry\);/.test(src), '...and each row\'s cells');
});

test('a Gen 1 / Gen 2 moves event keeps a row\'s ppUps for the client to mirror', () => {
  const rows = [
    {
      id: 'TAP', pp: 0, maxPp: 35, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0, ppUps: 3,
    },
    {
      id: 'HUSH', pp: 5, power: 0, accuracy: 255, type: 0, effect: 0, chance: 0, ppUps: 4,
    },
  ];
  for (const gen of [1, 2]) {
    const event = sanitize.cleanBattleEvent({
      battle: 'b1', seq: 1, t: 'moves', slot: 0, side: 'a', mon: 0, moves: rows,
    }, gen);
    assert.strictEqual(event.moves.length, 1, `a row past PP_UPS_MAX is dropped on Gen ${gen}`);
    assert.strictEqual(event.moves[0].ppUps, 3, `...and a readable one kept on Gen ${gen}`);
  }
});

// ---------------------------------------------------------------------------
// Wave 2 of docs/plans/gen12-referee-remaining-gaps.md: K22's `quiet` on a
// Red / Gold `anim`, and K23's Gold `countSpeciesTypes` on an NPC party. The
// hub parity driver's remaining_gaps_wave2 cases hold both hubs and both
// readers to one answer case by case; this pins the gates and the hand-offs.
// ---------------------------------------------------------------------------

test('K22: a Red / Gold anim keeps quiet: true; anything else, any other kind and Gen 3 drop it', () => {
  const event = (extra, gen) => sanitize.cleanBattleEvent({
    battle: 'b1', seq: 1, t: 'anim', slot: 3, side: 'b', text: 'ABSORB', ...extra,
  }, gen);
  for (const gen of [1, 2]) {
    assert.strictEqual(event({ quiet: true }, gen).quiet, true, `Gen ${gen}: a quiet anim says so`);
    for (const bad of [false, 1, 'true', 'yes', [true], { a: true }, null, 0]) {
      const got = event({ quiet: bad }, gen);
      assert.ok(got && got.quiet === undefined, `Gen ${gen}: quiet ${JSON.stringify(bad)} is dropped, never refused`);
    }
    for (const t of ['msg', 'item', 'stat', 'faint']) {
      const got = event({ t, quiet: true }, gen);
      assert.ok(got && got.quiet === undefined, `Gen ${gen}: a ${t} carries no quiet`);
    }
  }
  for (const gen of [3, undefined]) {
    const got = event({ quiet: true }, gen);
    assert.ok(got && got.quiet === undefined, `a reader for generation ${gen} reads no quiet`);
  }
  const wire = read('src/Wire.lua');
  assert.ok(/if older and raw\.t == "anim" and raw\.quiet == true then out\.quiet = true end/.test(wire),
    'Wire.battleEvent reads quiet on an older reader\'s anim alone');
});

test('K23: Gold\'s countSpeciesTypes rides a Gen 2 NPC party, refusing it unreadable, onto a whole-party NPC seat', () => {
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const sheet1 = {
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100, stats: { atk: 90, def: 90, spd: 90, spc: 90 }, moves: [move],
  };
  const sheet2 = { ...sheet1, stats: { atk: 90, def: 90, spe: 90, spa: 90, spd: 90 } };
  const party = (extra, gen) => sanitize.cleanBattleParty({
    battle: 'b1', mons: [gen === 2 ? sheet2 : sheet1], ...extra,
  }, gen);
  assert.deepStrictEqual(party({ countSpeciesTypes: [3, 7] }, 2).countSpeciesTypes, [3, 7], 'two type bytes');
  assert.deepStrictEqual(party({ countSpeciesTypes: [0, 0] }, 2).countSpeciesTypes, [0, 0],
    'a mono-typed species states its byte twice, as BaseData does');
  assert.deepStrictEqual(party({ countSpeciesTypes: ['19'] }, 2).countSpeciesTypes, [19],
    'one, at BATTLE_TYPE_MAX - 1, read as Wire.int reads it');
  assert.deepStrictEqual(party({ countSpeciesTypes: [null, 4] }, 2).countSpeciesTypes, [4],
    'a JSON null closed up, as the Lua decoder does');
  assert.strictEqual(party({ countSpeciesTypes: null }, 2).countSpeciesTypes, undefined, 'a null is absent');
  for (const bad of [[], {}, [1, 2, 3], [20], [-1], [true], ['x'], [[1]], { a: 1 }, 'FIRE', 7]) {
    assert.strictEqual(party({ countSpeciesTypes: bad }, 2), null,
      `${JSON.stringify(bad)} refuses the Gold party`);
  }
  for (const gen of [1, undefined]) {
    const got = party({ countSpeciesTypes: [1, 2, 3] }, gen);
    assert.ok(got && got.countSpeciesTypes === undefined,
      `a party read for generation ${gen} neither keeps nor refuses one`);
  }
  assert.strictEqual(sanitize.COUNT_SPECIES_TYPES2_MAX, 2, 'a species has two type bytes');
  const wire = read('src/Wire.lua');
  assert.strictEqual(luaNumber(wire, 'COUNT_SPECIES_TYPES2_MAX', 'Wire.lua'), sanitize.COUNT_SPECIES_TYPES2_MAX,
    'Wire.COUNT_SPECIES_TYPES2_MAX and sanitize.COUNT_SPECIES_TYPES2_MAX must match');
  assert.ok(/if raw\.countSpeciesTypes ~= nil then\s+out\.countSpeciesTypes = countSpeciesTypesOf\(raw\.countSpeciesTypes\)\s+if out\.countSpeciesTypes == nil then return nil end/
    .test(wire), 'Wire.battleParty reads it on a Gold party and refuses it unreadable');
  // Both hubs: onto an NPC seat dealt the whole party alone, then to the referee.
  const hub = read('src/Hub.lua');
  assert.ok(/local whole = #dealt\[at\] == #party\.mons/.test(hub), 'Hub:fillBattleParty knows a whole-party seat');
  assert.ok(/countSpeciesTypes = whole and party\.countSpeciesTypes or nil,/.test(hub),
    'Hub:fillBattleParty copies it onto that seat alone');
  assert.ok(/countSpeciesTypes = npc and party\.countSpeciesTypes or nil,/.test(hub), 'Hub:tryStartSim hands it on');
  const relay = read('server/lib/relay.js');
  assert.ok(/const whole = dealt\[at\]\.length === party\.mons\.length;/.test(relay),
    'relay fillBattleParty knows a whole-party seat');
  assert.ok(/if \(whole && party\.countSpeciesTypes\) seatParty\.countSpeciesTypes = party\.countSpeciesTypes;/.test(relay),
    'relay fillBattleParty copies it onto that seat alone');
  assert.ok(/if \(npc && party\.countSpeciesTypes\) entry\.countSpeciesTypes = party\.countSpeciesTypes;/.test(relay),
    'relay tryStartSim hands it on');
});

test('a Gen 1 / Gen 2 sheet\'s moves and types close a JSON null up, as the Lua decoder does', () => {
  // Wave 2's differential fuzzer: `types: [null, 12]` and `moves: [null, m]`
  // were sheets the Lua hub kept (its decoder appends nothing for a null) and
  // this one refused. Both read through luaList now.
  const move = {
    id: 'thump', pp: 20, power: 40, accuracy: 255, type: 0, effect: 0, chance: 0,
  };
  const sheet = (extra) => ({
    species: 'ALPHA', level: 50, hp: 100, maxHp: 100, stats: { atk: 90, def: 90, spd: 90, spc: 90 }, ...extra,
  });
  assert.deepStrictEqual(cleanBattleMon(sheet({ moves: [move], types: [null, 12] })).types, [12],
    'a null in types is no entry');
  assert.strictEqual(cleanBattleMon(sheet({ moves: [null, move] })).moves.length, 1, 'a null in moves is no entry');
  assert.strictEqual(cleanBattleMon(sheet({ moves: [move, move, move, move, null] })).moves.length, 4,
    '...and does not count against BATTLE_MOVE_MAX');
  for (const bad of [{ a: move }, { a: null }, [], [null]]) {
    assert.strictEqual(cleanBattleMon(sheet({ moves: bad })), null, `moves ${JSON.stringify(bad)} refuses the sheet`);
  }
  for (const bad of [{ a: 1 }, {}, [null]]) {
    assert.strictEqual(cleanBattleMon(sheet({ moves: [move], types: bad })), null,
      `types ${JSON.stringify(bad)} refuses the sheet`);
  }
  const src = read('server/lib/sanitize.js');
  assert.ok(/const moveList = luaList\(raw\.moves\);/.test(src) && /const typeList = luaList\(raw\.types\);/.test(src),
    'cleanBattleMon reads both lists through luaList');
});
