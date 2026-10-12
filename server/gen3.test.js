#!/usr/bin/env node
'use strict';

/*
 * The Gen 3 generation lock, over real TCP sockets (PROTOCOL 30).
 *
 * One Gen 3 hub seats FireRed, LeafGreen and Emerald together and refuses
 * every other generation; a Gen 1 or Gen 2 hub refuses Gen 3. The hub
 * parity suite pins the same rules against both hub implementations in
 * process; this one starts hub.js as a child the way a host does -- through
 * `--generation 3` on the command line and through RBY_MMO_GENERATION=3 --
 * and dials it with the newline JSON the mod speaks, so a lock that only
 * held in the relay and never reached the process would fail here.
 *
 * Sprite names and map ids below are synthetic engine-shaped strings; nothing
 * is read off a cart.
 *
 * Run: node server/gen3.test.js
 */

const net = require('node:net');
const crypto = require('node:crypto');
const path = require('node:path');
const { spawn } = require('node:child_process');

const HUB = path.join(__dirname, 'hub.js');
const { PROTOCOL, DEFAULT_SPRITE_GEN3 } = require('./lib/relay');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function playerId(seed) {
  return crypto.createHash('sha256').update(String(seed)).digest('hex').slice(0, 32);
}

// A port nobody holds right now: bind 0, read what the OS picked, let it go.
// Cheaper than a fixed range and it cannot collide with hub.test.js's.
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

class Client {
  constructor(port) {
    this.socket = net.createConnection({ port, host: '127.0.0.1' });
    this.socket.setEncoding('utf8');
    this.buffer = '';
    this.inbox = [];
    this.closed = false;
    this.socket.on('data', (chunk) => {
      this.buffer += chunk;
      let i;
      while ((i = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, i);
        this.buffer = this.buffer.slice(i + 1);
        if (line) this.inbox.push(JSON.parse(line));
      }
    });
    this.socket.on('close', () => { this.closed = true; });
    this.socket.on('error', () => {});
  }
  ready() {
    return new Promise((resolve, reject) => {
      this.socket.once('connect', resolve);
      this.socket.once('error', reject);
    });
  }
  send(type, payload) {
    this.socket.write(JSON.stringify(Object.assign({}, payload, { type })) + '\n');
  }
  async expect(type, timeoutMs = 2000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const index = this.inbox.findIndex((m) => m.type === type);
      if (index >= 0) return this.inbox.splice(index, 1)[0];
      await sleep(10);
    }
    throw new Error(`timed out waiting for ${type}; saw ` +
      JSON.stringify(this.inbox.map((m) => m.type)));
  }
  async expectClosed(timeoutMs = 2000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.closed) return true;
      await sleep(10);
    }
    return false;
  }
  close() { this.socket.destroy(); }
}

// Start hub.js and keep everything it prints, so the startup line that names
// the lock can be read back. `args` is what follows the port on argv.
async function startHub(args, env) {
  const port = await freePort();
  const hub = spawn(process.execPath, [HUB, String(port), ...(args || [])], {
    stdio: 'pipe',
    // Headroom over the four admitted below plus the refused dials, so a
    // refusal is the generation's and never the cap's. The inherited
    // RBY_MMO_GENERATION is blanked so the host shell cannot pick the lock.
    env: Object.assign({}, process.env,
      { RBY_MMO_GENERATION: '', RBY_MMO_MAX: '16' }, env || {}),
  });
  let output = '';
  hub.stdout.on('data', (d) => { output += String(d); });
  hub.stderr.on('data', (d) => { output += String(d); });
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`hub never started:\n${output}`)), 5000);
    const poll = setInterval(() => {
      if (output.includes('listening')) {
        clearTimeout(timer);
        clearInterval(poll);
        resolve();
      }
    }, 10);
    hub.once('exit', (code) => {
      clearTimeout(timer);
      clearInterval(poll);
      reject(new Error(`hub exited ${code} before listening:\n${output}`));
    });
  });
  return { hub, port, output: () => output };
}

function stopHub(handle) {
  return new Promise((resolve) => {
    if (handle.hub.exitCode !== null) return resolve();
    handle.hub.once('exit', () => resolve());
    handle.hub.kill('SIGTERM');
  });
}

// One hello; the fields a test leaves out stay off the wire entirely, which
// is how "missing generation" is sent.
async function hello(port, name, fields) {
  const client = new Client(port);
  await client.ready();
  client.send('mmo.hello', Object.assign({
    proto: PROTOCOL, playerId: playerId(name), name,
    map: 'FR_PALLET_TOWN', x: 5, y: 5, facing: 'down',
  }, fields));
  return client;
}

async function refusedWith(port, name, fields) {
  const client = await hello(port, name, fields);
  const error = await client.expect('mmo.error');
  const closed = await client.expectClosed();
  client.close();
  return { message: error.message, closed };
}

async function gen3HubByFlag() {
  const handle = await startHub(['--generation', '3']);
  const clients = [];
  try {
    ok(/listening on .*\(protocol \d+, gen 3\)/.test(handle.output()),
      'a --generation 3 hub says gen 3 on its startup line');
    ok(!handle.output().includes('generation defaulted to 1'),
      'an explicit Gen 3 lock draws no default-generation warning');

    // FireRed and Emerald in one room
    const leaf = await hello(handle.port, 'LEAF', {
      generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_GREEN_NORMAL',
      map: 'FR_PALLET_TOWN',
    });
    clients.push(leaf);
    const leafWelcome = await leaf.expect('mmo.welcome');
    ok(leafWelcome.id === playerId('LEAF'), 'a FireRed client is admitted by a Gen 3 hub');

    const may = await hello(handle.port, 'MAY', {
      generation: 3, version: 'emerald', sprite: 'OBJ_EVENT_GFX_MAY_NORMAL',
      map: 'EM_LITTLEROOT_TOWN',
    });
    clients.push(may);
    const mayWelcome = await may.expect('mmo.welcome');
    ok(mayWelcome.id === playerId('MAY'), 'an Emerald client is admitted by the same hub');
    const seen = mayWelcome.players.find((p) => p.name === 'LEAF');
    ok(seen, 'the Emerald player finds the FireRed player on the roster');
    ok(seen.version === 'firered', 'with the cart they said hello from');
    ok(seen.sprite === 'OBJ_EVENT_GFX_GREEN_NORMAL', 'and the graphic their own cart drew');

    const join = await leaf.expect('mmo.join');
    ok(join.player.name === 'MAY' && join.player.version === 'emerald',
      'the FireRed player is told an Emerald player joined, cart and all');
    ok(join.player.map === 'EM_LITTLEROOT_TOWN',
      'presence is relayed as sent; region scoping is the map id, not the hub');

    // LeafGreen with no sprite: the hub stamps the Gen 3 token, never Red
    const green = await hello(handle.port, 'GREEN', {
      generation: 3, version: 'leafgreen', map: 'FR_VIRIDIAN_CITY',
    });
    clients.push(green);
    await green.expect('mmo.welcome');
    const greenJoin = await leaf.expect('mmo.join');
    ok(greenJoin.player.sprite === DEFAULT_SPRITE_GEN3,
      'a sprite-less Gen 3 hello is stamped with the Gen 3 token');
    ok(greenJoin.player.version === 'leafgreen', 'LeafGreen is a Gen 3 cart too');

    // A Gen 3 hello naming a Gen 1 cart: admitted, the contradiction dropped
    const liar = await hello(handle.port, 'LIAR', {
      generation: 3, version: 'red', sprite: 'OBJ_EVENT_GFX_RED_NORMAL',
    });
    clients.push(liar);
    await liar.expect('mmo.welcome');
    const liarJoin = await leaf.expect('mmo.join');
    ok(liarJoin.player.name === 'LIAR' && liarJoin.player.version === undefined,
      'a version from another generation is not relayed into a Gen 3 room');

    // Cross-version chat
    leaf.send('mmo.chat', { scope: 'global', text: 'hello from kanto' });
    const heard = await may.expect('mmo.chat');
    ok(heard.text === 'hello from kanto' && heard.name === 'LEAF',
      'FireRed and Emerald players chat across carts');

    // Every other generation is refused, in the shared sentence
    const red = await refusedWith(handle.port, 'RED', {
      generation: 1, version: 'red', sprite: 'SPRITE_RED',
    });
    ok(red.message === 'This hub is for generation 3; yours is generation 1.',
      `a Gen 1 client is refused by a Gen 3 hub (${red.message})`);
    ok(red.closed, 'and the connection is closed behind the refusal');

    const legacy = await refusedWith(handle.port, 'OLDRED', { sprite: 'SPRITE_RED' });
    ok(legacy.message === 'This hub is for generation 3; yours is generation 1.',
      'a hello that names no generation is Gen 1 (compat) and refused here');

    const gold = await refusedWith(handle.port, 'GOLD', {
      generation: 2, version: 'gold', sprite: 'SPRITE_CHRIS',
    });
    ok(gold.message === 'This hub is for generation 3; yours is generation 2.',
      'a Gen 2 client is refused by a Gen 3 hub');

    const future = await refusedWith(handle.port, 'NEXT', { generation: 4 });
    ok(future.message === 'This hub is for generation 3; yours is not a generation it knows.',
      'an unknown generation is refused rather than guessed');

    // A battle ask on a Gen 3 hub must not take the hub down, whatever the
    // referee makes of it -- the Gen 3 intermediator is its own work.
    leaf.send('mmo.request', { to: playerId('MAY'), kind: 'battle' });
    await may.expect('mmo.request');
    may.send('mmo.respond', { to: playerId('LEAF'), kind: 'battle', accept: true });
    const session = await leaf.expect('mmo.session');
    leaf.send('mmo.battle_party', {
      battle: session.id,
      mons: [{
        species: 'ALPHA', level: 5, hp: 20, maxHp: 20,
        stats: { atk: 10, def: 10, spe: 10, spa: 10, spd: 10 },
        moves: [{ id: 'THUMP', pp: 35, power: 40, accuracy: 100, type: 0, effect: 0, chance: 0 }],
      }],
    });
    await sleep(100);
    may.send('mmo.chat', { scope: 'global', text: 'still here' });
    const after = await leaf.expect('mmo.chat');
    ok(after.text === 'still here', 'the hub is still relaying after a battle upload');
    ok(handle.hub.exitCode === null, 'and the process is still running');
  } finally {
    for (const client of clients) client.close();
    await stopHub(handle);
  }
}

async function gen3HubByEnv() {
  const handle = await startHub([], { RBY_MMO_GENERATION: '3' });
  const clients = [];
  try {
    ok(/\(protocol \d+, gen 3\)/.test(handle.output()),
      'RBY_MMO_GENERATION=3 locks a Gen 3 hub too');
    const leaf = await hello(handle.port, 'LEAF', { generation: 3, version: 'firered' });
    clients.push(leaf);
    const welcome = await leaf.expect('mmo.welcome');
    ok(welcome.id === playerId('LEAF'), 'a FireRed client is admitted by an env-locked Gen 3 hub');
    const red = await refusedWith(handle.port, 'RED', { generation: 1 });
    ok(red.message === 'This hub is for generation 3; yours is generation 1.',
      'and a Gen 1 client is refused by it');
  } finally {
    for (const client of clients) client.close();
    await stopHub(handle);
  }
}

async function gen3RefusedElsewhere() {
  // The default hub is Gen 1 (compat), and says so once
  const gen1 = await startHub([]);
  try {
    ok(/\(protocol \d+, gen 1\)/.test(gen1.output()), 'an unlocked hub.js runs as gen 1');
    ok(gen1.output().includes('Gen 2 and Gen 3 hubs must pass'),
      'and its default warning names the Gen 3 flag as well as Gen 2');
    const leaf = await refusedWith(gen1.port, 'LEAF', {
      generation: 3, version: 'firered', sprite: 'OBJ_EVENT_GFX_GREEN_NORMAL',
    });
    ok(leaf.message === 'This hub is for generation 1; yours is generation 3.',
      `a FireRed client is refused by a Gen 1 hub, not read as Gen 1 (${leaf.message})`);
    ok(leaf.closed, 'and closed');
    const red = await hello(gen1.port, 'RED', { generation: 1, version: 'red' });
    const welcome = await red.expect('mmo.welcome');
    ok(welcome.id === playerId('RED'), 'while a Gen 1 client still walks in');
    red.close();
  } finally {
    await stopHub(gen1);
  }

  const gen2 = await startHub(['--generation=2']);
  try {
    ok(/\(protocol \d+, gen 2\)/.test(gen2.output()), 'a --generation=2 hub runs as gen 2');
    const may = await refusedWith(gen2.port, 'MAY', {
      generation: 3, version: 'emerald', sprite: 'OBJ_EVENT_GFX_MAY_NORMAL',
    });
    ok(may.message === 'This hub is for generation 2; yours is generation 3.',
      'an Emerald client is refused by a Gen 2 hub');
  } finally {
    await stopHub(gen2);
  }

  // A lock the hub does not know is pulled to 1 out loud, never silently
  const bogus = await startHub(['--generation', '4']);
  try {
    ok(bogus.output().includes('generation: "4" is not 1, 2 or 3, using 1'),
      'an unknown --generation is named in a warning');
    ok(/\(protocol \d+, gen 1\)/.test(bogus.output()), 'and the hub says the lock it did take');
  } finally {
    await stopHub(bogus);
  }
}

(async () => {
  try {
    await gen3HubByFlag();
    await gen3HubByEnv();
    await gen3RefusedElsewhere();
    console.log(`\n  ${passed}/${passed} checks passed  (gen3)\n`);
    process.exit(0);
  } catch (err) {
    console.error(err && err.stack ? err.stack : err);
    console.error(`\n  failed after ${passed} passing checks  (gen3)\n`);
    process.exit(1);
  }
})();
