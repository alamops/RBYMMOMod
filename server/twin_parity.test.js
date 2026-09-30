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
  for (const kind of ['ability', 'weather', 'held', 'form', 'sub', 'ball']) {
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
  for (const name of ['VERSION', 'GENERATION', 'MONS_PER_PARTY', 'FIGHTERS_PER_SIDE',
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
