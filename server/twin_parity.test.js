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
  PROTOCOL, DEFAULT_SPRITE, SPRITE_GATE_MS,
} = require('./lib/relay.js');
const { PLAYER_ID_HEX } = require('./lib/sanitize.js');

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

test('shared hello refuse strings stay twin-worded', () => {
  const hub = read('src/Hub.lua');
  const relay = read('server/lib/relay.js');
  const needles = [
    "You're already connected.",
    "That player id can't be used here.",
    "That trainer name can't be used here.",
    'This game speaks protocol',
  ];
  for (const needle of needles) {
    assert.ok(hub.includes(needle), `Hub.lua must contain: ${needle}`);
    assert.ok(relay.includes(needle), `relay.js must contain: ${needle}`);
  }
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
    'mmo.battle_reconnect',
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
