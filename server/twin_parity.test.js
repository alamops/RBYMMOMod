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
// Referee gaps (docs/plans/gen12-referee-gaps-fix.md K7-K11, K13): the Gen 1 /
// Gen 2 sheet's base / dvs / statExp, a move row's ppUps and Gold priority, the
// moveset's level-up, the older `stat` event's signed stage, the Gen 1 / Gen 2
// Pay Day bound, the 40-character id and the Metronome pool cap. The hub
// protocol parity driver (referee_gaps_dialect, levelup_moveset_forward,
// gen12_payday_forward) holds the twins to one answer case by case; this pins
// the numbers, the key lists and the event field set they are written against.
// ---------------------------------------------------------------------------

test('the referee-gap bounds and the Metronome pool cap match Config / Wire / sanitize', () => {
  // A one-sided bound is a sheet, a learn or a coin count one hosting path
  // takes and the other refuses.
  const wire = read('src/Wire.lua');
  for (const name of ['BASE_STAT_MAX', 'DV_MAX', 'STAT_EXP_MAX', 'PP_UPS_MAX', 'PRIORITY2_MAX',
    'STAGE12_MAX', 'PAYDAY12_MAX']) {
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
      assert.ok(OLDER.includes(key), `${rel} FIELDS.${key} is a field an older reader keeps`);
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
