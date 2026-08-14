#!/usr/bin/env node
'use strict';

function testPlayerId(seed) {
  const crypto = require('node:crypto');
  return crypto.createHash('sha256').update(String(seed)).digest('hex').slice(0, 32);
}

/*
 * Unit tests for ranked PVP: `lib/rank.js`, and the part of `lib/relay.js`
 * that decides whether to believe a result.
 *
 * Two things are being pinned here, and the second is the one that matters.
 *
 * The arithmetic is asserted against numbers written out by hand -- the same
 * numbers `mods/rby_mmo/tests/rby_mmo_test.lua` asserts on the Lua side.
 * Both hubs price a win, and a win worth 27 points on a dedicated hub and 16
 * on a game hosted from inside somebody's copy is not one ranking but two.
 * The only thing that keeps them together is two suites checking the same
 * table, which is why the cases below are duplicated rather than derived.
 *
 * The relay half is the anti-cheat. A result is a claim by a stranger's
 * process; the whole defence is that two independent claims have to agree.
 * Every way of getting points without winning a battle is tried below.
 *
 * Socket-free by construction: `Relay` talks to peer handles, so the clients
 * here are objects with a `send`, and the clock is injected.
 *
 * Run: node server/rank.test.js
 */

const {
  Board, expected, swing, discount, keyOf, clampPoints,
  RANK_K, RANK_MAX, RANK_TOP, RANK_REPEAT_WINDOW_MS, RANK_REPEAT_FADE,
  RANK_REPORT_GRACE_MS, RANK_QUERY_GATE_MS,
} = require('./lib/rank.js');
const { MESSAGE_MAX, MOTD_MAX } = require('./lib/sanitize.js');
const { Relay, PROTOCOL, DEFAULT_SPRITE, presenceOf } = require('./lib/relay.js');
const { createLog } = require('./lib/log.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

const quiet = createLog({ level: 'error' });

// --------------------------------------------------------------- the curve

function testExpected() {
  ok(expected(0, 0) === 0.5, 'two unranked players are even');
  ok(expected(500, 500) === 0.5, 'and so are two equal ratings anywhere');
  ok(expected(400, 0) > 0.9, '400 points of gap is a heavy favourite');
  ok(expected(0, 400) < 0.1, 'seen from the other side');
}

function testSwing() {
  const even = swing(0, 0);
  ok(even.gain === 16, 'an even match is worth half of RANK_K');
  ok(even.loss === 16, 'and costs the loser the same');

  const upset = swing(0, 300);
  const farm = swing(300, 0);
  ok(upset.gain > even.gain, 'beating somebody far above you is worth more');
  ok(farm.gain < even.gain, 'and beating somebody far below you is worth less');
  ok(upset.gain + upset.loss === RANK_K,
    'the two halves of one match add up to RANK_K');
  ok(upset.loss === farm.gain, 'and the curve is symmetric about the gap');

  // The numbers themselves, so a change to either implementation has to be
  // a change to both.
  ok(upset.gain === 27, 'a 300-point upset pays 27');
  ok(farm.gain === 5, 'and the same gap the other way pays 5');
}

function testDiscount() {
  ok(discount(16, 0) === 16, 'a first meeting is worth full price');
  ok(discount(16, 1) === 8, 'the rematch is worth half');
  ok(discount(16, 2) === 4, 'and the one after that a quarter');
  ok(discount(16, RANK_REPEAT_FADE) === 0,
    'far enough in, a rematch is worth nothing at all');
  ok(discount(16, 9e9) === 0,
    'and an absurd count is zero rather than a division by an infinity');
}

function testClamps() {
  ok(keyOf('e205b6cb7748495220a60ff4020fc86f') === 'e205b6cb7748495220a60ff4020fc86f', 'a playerId is the board key');
  ok(keyOf(' ash ') === null, 'a trainer name is not a playerId');
  ok(clampPoints(-5) === 0, 'ratings floor at zero');
  ok(clampPoints(RANK_MAX + 10) === RANK_MAX, 'and stop at the ceiling');
  ok(clampPoints('nonsense') === 0, 'a non-number is zero');
}

// --------------------------------------------------------------- the board

function testBoardBasics() {
  const season = new Board();
  const ash = 'e205b6cb7748495220a60ff4020fc86f';
  const gary = '07e58dcec01bf48633cbb75e2d68da78';
  ok(season.points(ash) === 0, 'everybody starts unranked');

  const first = season.record(ash, gary, 0);
  ok(first !== null, 'a match between two players settles');
  ok(first.winner.points === 16, 'the winner is on the board');
  ok(first.loser.points === 0, 'and the loser cannot go below zero');
  ok(season.points(ash) === 16, 'the same playerId matches');
  ok(season.record(ash, ash, 0) === null, 'and nobody can beat themselves');
  ok(season.record(ash, null, 0) === null, 'a nameless opponent is not a match');
}

function testFarmingIsWorthless() {
  const farm = new Board();
  const earned = [];
  for (let i = 1; i <= RANK_REPEAT_FADE; i += 1) {
    earned.push(farm.record('73ab66a033c267e00b7429bb256f6deb', 'f3233097bacb2526cb78cb72d2e1bbeb', i * 10).winner.gained);
  }
  ok(earned[0] > 0, 'the first win pays');
  ok(earned[1] < earned[0], 'the rematch pays less');
  ok(earned[2] < earned[1], 'and so on down');
  ok(earned[earned.length - 1] === 0,
    'until a rematch inside the window is worth nothing');
  ok(farm.points('f3233097bacb2526cb78cb72d2e1bbeb') === 0, 'and the loser bottoms out at zero');

  // The discount does not care which way round the wins go, so two friends
  // cannot take turns.
  const swapped = new Board();
  const there = swapped.record('73ab66a033c267e00b7429bb256f6deb', 'f3233097bacb2526cb78cb72d2e1bbeb', 0).winner.gained;
  const back = swapped.record('f3233097bacb2526cb78cb72d2e1bbeb', '73ab66a033c267e00b7429bb256f6deb', 1).winner.gained;
  ok(back < there, 'alternating wins is the same pairing, and is discounted');

  // Two boards played identically up to the rematch, so the ratings are the
  // same at that point and the only difference is how long they waited.
  const soon = new Board();
  const later = new Board();
  soon.record('73ab66a033c267e00b7429bb256f6deb', 'f3233097bacb2526cb78cb72d2e1bbeb', 0);
  later.record('73ab66a033c267e00b7429bb256f6deb', 'f3233097bacb2526cb78cb72d2e1bbeb', 0);
  const sooner = soon.record('73ab66a033c267e00b7429bb256f6deb', 'f3233097bacb2526cb78cb72d2e1bbeb', 1).winner.gained;
  const waited = later.record('73ab66a033c267e00b7429bb256f6deb', 'f3233097bacb2526cb78cb72d2e1bbeb',
    RANK_REPEAT_WINDOW_MS + 1).winner.gained;
  ok(waited > sooner, 'a rematch after the window is worth full price again');
}

function testBoardPersistenceByPlayerId() {
  const board = new Board();
  const winner = testPlayerId('ASH');
  const loser = testPlayerId('GARY');
  ok(board.get(winner) === null, 'sanity: neither id is on the board yet');
  board.seen(winner, 'ASH', 'SPRITE_RED');
  board.seen(loser, 'GARY', 'SPRITE_BLUE');
  board.record(winner, loser, 0);
  ok(board.points(winner) === 16, 'a win is scored by playerId');
  ok(board.points(loser) === 0, 'and the loser floors at zero by playerId');

  const saved = board.export();
  ok(saved.every((row) => row.id && row.id.length === 32),
    'exported rows carry a 32-hex playerId');
  ok(saved.every((row) => row.tokenHash === undefined),
    'and no legacy claim digests');

  const restored = new Board().import(saved);
  ok(restored.points(winner) === 16,
    'a rating survives a round trip through the file keyed by id');
  ok(restored.get(winner).name === 'ASH',
    'along with the display name that was seen at hello');

  const skipped = new Board().import([
    { name: 'LEGACY', points: 40, played: 3, won: 2 },
  ]);
  ok(skipped.points(testPlayerId('LEGACY')) === 0,
    'name-only legacy rows without an id are not imported');
}

function testLeaderboard() {
  const ladder = new Board();
  const winnerIds = [];
  for (let i = 1; i <= 14; i += 1) {
    const wid = testPlayerId(`WINNER${i}`);
    const pid = testPlayerId(`PUNCHBAG${i}`);
    winnerIds.push(wid);
    ladder.seen(wid, `WINNER${i}`, 'SPRITE_RED');
    ladder.seen(pid, `PUNCHBAG${i}`, 'SPRITE_RED');
    ladder.record(wid, pid, i);
  }
  const lurker = testPlayerId('LURKER');
  ladder.seen(lurker, 'LURKER', 'SPRITE_LASS');

  const top = ladder.top(RANK_TOP);
  ok(top.length === RANK_TOP, 'the board is cut to the top ten');
  ok(top[0].points >= top[1].points, 'best first');
  ok(top.every((row) => row.points > 0),
    'and nobody with nothing to show is on it');
  ok(!top.some((row) => row.name === 'LURKER'),
    'a player who has never won is not ranked');
  ok(!top.some((row) => row.name && row.name.startsWith('PUNCHBAG')),
    'and neither is one who only lost');

  const saved = ladder.export();
  ok(saved.length > top.length,
    'everything is exported, not only the visible ten');
  const restored = new Board().import(saved);
  const topId = saved.find((r) => r.name === top[0].name).id;
  ok(restored.points(topId) === top[0].points,
    'a rating survives a round trip through the file');
  ok(restored.top(RANK_TOP).length === top.length,
    'and so does the board it makes');

  const okId = testPlayerId('OK');
  const mangled = new Board().import([
    'not a row', { id: okId, name: 'OK', points: 40 }, { points: 9 }, null,
  ]);
  ok(mangled.points(okId) === 40,
    "a corrupt row costs its own rating, not the whole file's");
}

// --------------------------------------------------------------- the relay

function makeClock(start = 1000) {
  let t = start;
  return { now: () => t, advance(ms) { t += ms; } };
}

function dial(relay, name, opts) {
  const o = opts || {};
  const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => { peer.closed = true; };
  const ephemeralId = relay.accept(peer);
  const playerId = o.playerId || testPlayerId(name);
  relay.handle(ephemeralId, {
    type: 'mmo.hello',
    proto: PROTOCOL,
    name,
    sprite: o.sprite || DEFAULT_SPRITE,
    map: o.map === undefined ? 'PALLET' : o.map,
    x: o.x === undefined ? 1 : o.x,
    y: o.y === undefined ? 1 : o.y,
    facing: 'down',
    playerId,
  });
  const welcome = peer.outbox.find((m) => m.type === 'mmo.welcome');
  // Wire id is the persistent playerId; ephemeral accept id still routes handle().
  return { id: playerId, peer, name, welcome, ephemeralId };
}

/*
 * A hub with two players on it, driven through the same entry point a socket
 * would use. Peers keep an outbox instead of a socket; `take` pulls the first
 * message of a type so a later assertion is not confused by earlier traffic.
 */
function makeHub(clock, names) {
  const relay = new Relay({ maxPlayers: 8, log: quiet, now: clock.now });
  const players = names.map((name) => dial(relay, name, { sprite: 'SPRITE_RED' }));
  return { relay, players };
}

function take(player, type) {
  const index = player.peer.outbox.findIndex((m) => m.type === type);
  if (index < 0) return null;
  return player.peer.outbox.splice(index, 1)[0];
}

/*
 * Both sides out of whatever they were in first: the relay refuses a request
 * from a player who is already paired, and a fight that never started would
 * make every assertion after it pass by doing nothing.
 */
function fight(relay, a, b) {
  relay.handle(a.id, { type: 'mmo.session_leave' });
  relay.handle(b.id, { type: 'mmo.session_leave' });
  a.peer.outbox = [];
  b.peer.outbox = [];
  relay.handle(a.id, { type: 'mmo.request', to: b.id, kind: 'battle' });
  relay.handle(b.id, {
    type: 'mmo.respond', to: a.id, kind: 'battle', accept: true,
  });
  const session = take(a, 'mmo.session');
  take(b, 'mmo.session');
  ok(session !== null, 'the battle this scenario needs actually started');
  return session && session.id;
}

function testDuplicatePlayerIdRefused() {
  const clock = makeClock();
  const relay = new Relay({ maxPlayers: 8, log: quiet, now: clock.now });
  const owner = dial(relay, 'DUPE', { sprite: 'SPRITE_RED' });
  ok(owner.welcome.ranked === true, 'sanity: a valid playerId is ranked');
  ok(owner.welcome.rankToken === undefined,
    'and no claim ticket rides the welcome under PROTOCOL 16');

  const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => { peer.closed = true; };
  const ephemeralId = relay.accept(peer);
  relay.handle(ephemeralId, {
    type: 'mmo.hello', proto: PROTOCOL, name: 'DUPE',
    playerId: owner.id, sprite: 'SPRITE_GREEN',
    map: 'PALLET', x: 1, y: 1, facing: 'down',
  });
  const err = take({ peer }, 'mmo.error');
  ok(err && /already connected/i.test(err.message),
    'a second live connection with the same playerId is refused');
  ok(peer.closed === true, 'and the duplicate connection is closed');
  ok(relay.board.points(owner.id) === 0,
    'the refused duplicate cannot touch the owner\'s rating');
}

function testResultsNeedTwoVoices() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['ONE', 'TWO', 'THREE']);
  const [one, two, three] = players;

  const welcome = take(one, 'mmo.welcome');
  ok(welcome.points === 0,
    'a welcome carries your own rating, which starts at zero');
  const joined = take(one, 'mmo.join');
  ok(joined.player.points === 0, "and presence carries everybody else's");

  const matchId = fight(relay, one, two);

  relay.handle(one.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  ok(relay.board.points(one.id) === 0, 'one report on its own scores nothing');
  ok(take(one, 'mmo.rank') === null, 'and moves nobody');

  relay.handle(three.id,
    { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(relay.board.points(one.id) === 0,
    'a player who was not in the battle is ignored');

  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(relay.board.points(one.id) === 16, 'two agreeing reports settle the match');
  ok(relay.board.points(two.id) === 0, 'and the loser floors at zero');
  const moved = take(one, 'mmo.rank');
  ok(moved && moved.points === 16, 'the winner is told their new rating');
  ok(take(two, 'mmo.rank') !== null,
    'and so is the loser -- both, in the same breath');
  ok(take(three, 'mmo.rank') !== null,
    'while everybody else hears it too, so their rosters and cards move');

  relay.handle(one.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(relay.board.points(one.id) === 16, 'a settled match cannot be settled twice');
}

function testLiesScoreNothing() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['ONE', 'TWO']);
  const [one, two] = players;

  const bothClaim = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: bothClaim, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: bothClaim, outcome: 'win' });
  ok(relay.board.points(one.id) === 0,
    'two players both claiming the win score nothing');
  ok(relay.board.points(two.id) === 0, 'neither of them');

  const revised = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: revised, outcome: 'loss' });
  relay.handle(one.id, { type: 'mmo.result', session: revised, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: revised, outcome: 'loss' });
  ok(relay.board.points(one.id) === 0 && relay.board.points(two.id) === 0,
    'the first answer stands, so a retraction cannot manufacture agreement');

  const drawn = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: drawn, outcome: 'draw' });
  relay.handle(two.id, { type: 'mmo.result', session: drawn, outcome: 'draw' });
  ok(relay.board.points(one.id) === 0, 'a draw moves nobody');

  // A trade is not a battle, so there is nothing to report on one.
  relay.handle(one.id, { type: 'mmo.session_leave' });
  relay.handle(two.id, { type: 'mmo.session_leave' });
  one.peer.outbox = [];
  relay.handle(one.id, { type: 'mmo.request', to: two.id, kind: 'trade' });
  relay.handle(two.id,
    { type: 'mmo.respond', to: one.id, kind: 'trade', accept: true });
  const trade = take(one, 'mmo.session');
  ok(trade !== null, 'a trade session starts like any other');
  relay.handle(one.id, { type: 'mmo.result', session: trade.id, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: trade.id, outcome: 'loss' });
  ok(relay.board.points(one.id) === 0,
    'a trade cannot be reported as a won battle');

  // And an outcome that is not one is not a report at all.
  const nonsense = fight(relay, one, two);
  relay.handle(one.id,
    { type: 'mmo.result', session: nonsense, outcome: 'victory' });
  relay.handle(two.id, { type: 'mmo.result', session: nonsense, outcome: 'loss' });
  ok(relay.board.points(two.id) === 0, 'an invented outcome is refused outright');
}

function testReportWindow() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['ONE', 'TWO']);
  const [one, two] = players;

  const late = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: late, outcome: 'win' });
  relay.handle(one.id, { type: 'mmo.session_leave' });
  clock.advance(1000);
  relay.handle(two.id, { type: 'mmo.result', session: late, outcome: 'loss' });
  ok(relay.board.points(one.id) === 16,
    'a report that lands after the session ended still counts');

  const stale = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: stale, outcome: 'win' });
  relay.handle(one.id, { type: 'mmo.session_leave' });
  clock.advance(RANK_REPORT_GRACE_MS + 1000);
  // the sweep runs when a battle starts, which is the only moment the table
  // can grow -- so start one, and then report into the expired match
  fight(relay, one, two);
  relay.handle(two.id, { type: 'mmo.result', session: stale, outcome: 'loss' });
  ok(relay.board.points(one.id) === 16,
    'but a report long after the grace period has nothing left to settle');
  ok(!relay.matches.has(stale), 'and the paperwork is not kept forever');
}

function testLeaderboardOverTheWire() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['ONE', 'TWO']);
  const [one, two] = players;

  const matchId = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });

  one.peer.outbox = [];
  relay.handle(one.id, { type: 'mmo.ranks' });
  const answer = take(one, 'mmo.ranking');
  ok(answer !== null, 'asking for the ranking is answered');
  ok(answer.entries.length === 1, 'with the players who have won something');
  ok(answer.entries[0].name === 'ONE', 'best first');
  ok(answer.entries[0].id === one.id,
    'and the row carries the persistent player id');
  ok(answer.entries[0].sprite === 'SPRITE_RED',
    'carrying the character, so the row can draw a portrait');
  ok(!answer.entries.some((row) => row.name === 'TWO'),
    'and a player who has only lost is not ranked');

  relay.handle(one.id, { type: 'mmo.ranks' });
  ok(take(one, 'mmo.ranking') === null,
    'a second request inside the gate is dropped');
  clock.advance(RANK_QUERY_GATE_MS + 10);
  relay.handle(one.id, { type: 'mmo.ranks' });
  ok(take(one, 'mmo.ranking') !== null,
    'and answered again once the gate opens');
}

function testRatingBelongsToPlayerId() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['COMEBACK', 'VICTIM']);
  const [one, two] = players;
  const playerId = one.id;

  const matchId = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });
  const won = relay.board.points(playerId);
  ok(won > 0, 'the winner has a rating');

  relay.drop(one.id);
  const back = dial(relay, 'COMEBACK', { playerId, sprite: 'SPRITE_RED' });
  ok(back.welcome && back.welcome.points === won,
    'which is still theirs when they come back with the same playerId, and the ' +
    'welcome says so');
  ok(back.welcome.ranked === true, 'and they remain ranked');
  ok(back.welcome.rankToken === undefined, 'with no claim ticket on the wire');
}

function testPersistenceHook() {
  const clock = makeClock();
  const seen = [];
  const relay = new Relay({
    maxPlayers: 4, log: quiet, now: clock.now,
    onRankChange: (settled) => seen.push(settled),
  });
  const a = dial(relay, 'A');
  const b = dial(relay, 'B');
  ok(seen.length === 0, 'joining does not flush the persistence hook');

  const matchId = fight(relay, a, b);
  relay.handle(a.id,
    { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(b.id,
    { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(seen.length === 1, 'a settled match does tell the caller');
  ok(seen[0].winner.name === 'A', 'naming who won');

  relay.drop(a.id);
  dial(relay, 'A', { playerId: a.id });
  ok(seen.length === 1,
    'reconnecting with the same playerId changes nothing and writes nothing');

  // A hook that throws is the disk being full, and must not cost the players
  // their result: the ratings are already correct in memory.
  const angry = new Relay({
    maxPlayers: 4,
    log: quiet,
    now: clock.now,
    onRankChange: () => { throw new Error('disk full'); },
  });
  const pair = [dial(angry, 'C'), dial(angry, 'D')];
  const angryMatch = fight(angry, pair[0], pair[1]);
  angry.handle(pair[0].id,
    { type: 'mmo.result', session: angryMatch, outcome: 'win' });
  angry.handle(pair[1].id,
    { type: 'mmo.result', session: angryMatch, outcome: 'loss' });
  ok(angry.board.points(pair[0].id) === 16,
    'a failing persistence hook does not undo the match');
}

// --------------------------------------------------------------- the roster
//
// `Relay#roster()` and `#noteRosterChange()` are lib/server.js's whole window
// onto "who is here" (docs/plans/server-side-listing.md §3) -- server.test.js
// proves the file that gets written from it; this is the relay-level half,
// socket-free like everything else above.

const ROSTER_CONTRACT_FIELDS = [
  'name', 'sprite', 'map', 'x', 'y', 'busy', 'party', 'points', 'ranked',
  'admin',  // 0.9.0: which connection holds an admin code -- operator surfaces only
].sort();

/*
 * Only greeted players appear, and each one is exactly the fields the plan
 * names, plus 0.9.0's `admin` -- no client id, no session or party id, no
 * address. Any of those on a snapshot that outlives the process is the last
 * place an id worth guessing should turn up.
 */
function testRosterFieldsAndReadyOnly() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['RED', 'BLUE']);

  // A socket that connected but never said hello: not a player, and on
  // nobody's roster, here least of all.
  const ghost = { outbox: [], remoteAddress: '127.0.0.1' };
  ghost.send = (msg) => ghost.outbox.push(msg);
  ghost.close = () => {};
  relay.accept(ghost);

  const roster = relay.roster();
  ok(roster.length === players.length,
    'only the greeted players appear; the silent socket does not');

  for (const entry of roster) {
    const keys = Object.keys(entry).sort();
    ok(JSON.stringify(keys) === JSON.stringify(ROSTER_CONTRACT_FIELDS),
      `the roster entry for ${entry.name} carries exactly the ` +
      `${ROSTER_CONTRACT_FIELDS.length} contract fields`);
  }
  ok(!roster.some((entry) => 'id' in entry), 'no roster entry carries a client id');
  ok(!roster.some((entry) => 'sessionId' in entry), 'nor a session id');
  ok(!roster.some((entry) => 'partyId' in entry), 'nor a party id');
  ok(!roster.some((entry) => 'address' in entry), 'nor the connecting address');
}

/*
 * busy and party track a session and a party exactly, and clear again once
 * either ends -- the same two booleans presenceOf() publishes over the wire,
 * read back through the operator's window instead.
 */
function testRosterBusyAndPartyFlags() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['ONE', 'TWO']);
  const [one, two] = players;

  const byName = (name) => relay.roster().find((entry) => entry.name === name);

  ok(byName('ONE').busy === false && byName('ONE').party === false,
    'a freshly-joined player is neither busy nor partied');

  fight(relay, one, two);
  ok(byName('ONE').busy === true && byName('TWO').busy === true,
    'both sides of a session show busy');
  ok(byName('ONE').party === false,
    'and a session alone does not make them appear partied');

  relay.handle(one.id, { type: 'mmo.session_leave' });
  ok(byName('ONE').busy === false && byName('TWO').busy === false,
    'ending the session clears busy for both');

  relay.handle(one.id, { type: 'mmo.party_invite', to: two.id });
  relay.handle(two.id, { type: 'mmo.party_respond', to: one.id, accept: true });
  ok(byName('ONE').party === true && byName('TWO').party === true,
    'forming a party shows party for both members');

  relay.handle(one.id, { type: 'mmo.party_leave' });
  ok(byName('ONE').party === false && byName('TWO').party === false,
    'and leaving it clears party for both, not just the one who left');
}

/*
 * Every event that can change what roster() would answer tells
 * onRosterChange -- and, just as deliberately, a step that only moves a
 * player around the same map does not. lib/server.js debounces on this
 * signal; a hook that fired on every footstep would turn an idle hub into a
 * file the disk never stops being asked about.
 */
function testRosterChangeNotifications() {
  const clock = makeClock();
  let changes = 0;
  const relay = new Relay({
    maxPlayers: 8, log: quiet, now: clock.now,
    onRosterChange: () => { changes += 1; },
  });

  const dialLocal = (name) => dial(relay, name);

  ok(changes === 0, 'sanity: nothing has happened yet');

  const one = dialLocal('ONE');
  ok(changes === 1, 'admitting a player fires the hook');

  const two = dialLocal('TWO');
  ok(changes === 2, 'and so does the next one');

  const beforeStep = changes;
  relay.handle(one.id, { type: 'mmo.move', map: 'PALLET', x: 2, y: 2, facing: 'down' });
  ok(changes === beforeStep,
    'a step that stays on the same map does not fire the hook');

  const beforeCross = changes;
  relay.handle(one.id, { type: 'mmo.move', map: 'VIRIDIAN', x: 0, y: 0, facing: 'up' });
  ok(changes === beforeCross + 1, 'crossing into another map fires it exactly once');

  const beforeMenu = changes;
  // No map/x/y at all -- the client saying "not in the world right now" (a
  // battle or a menu), which is a change of place just as much as a warp.
  relay.handle(one.id, { type: 'mmo.move', facing: 'up' });
  ok(changes === beforeMenu + 1,
    'leaving the world for a battle or a menu counts as a crossing too');

  const beforeSession = changes;
  const matchId = fight(relay, one, two);
  ok(changes === beforeSession + 1, 'starting a session fires the hook');

  const beforeSessionEnd = changes;
  relay.handle(one.id, { type: 'mmo.session_leave' });
  ok(changes === beforeSessionEnd + 1, 'ending it fires the hook again');

  const beforeParty = changes;
  relay.handle(one.id, { type: 'mmo.party_invite', to: two.id });
  relay.handle(two.id, { type: 'mmo.party_respond', to: one.id, accept: true });
  ok(changes === beforeParty + 1, 'forming a party fires the hook');

  const beforePartyEnd = changes;
  relay.handle(one.id, { type: 'mmo.party_leave' });
  ok(changes === beforePartyEnd + 1, 'ending the party fires it once more, not twice');

  const beforePoints = changes;
  relay.publishPoints(one.id, 50);
  ok(changes === beforePoints + 1, 'publishing a new rating fires the hook');

  const beforeDrop = changes;
  relay.drop(two.id);
  ok(changes === beforeDrop + 1, 'a player leaving the hub fires the hook');
}

// ----------------------------------------------------------- operator primitives
//
// Wave 1's five relay-level additions from docs/plans/server-live-ops.md §3:
// the reserved HUB name, the MOTD riding mmo.welcome, the onMatchSettled
// history hook, kickByName, and announce. Same socket-free style as
// everything above -- peer fakes with an outbox, driven through relay.handle.

/*
 * The name a hub speaks under cannot be worn by a player, or a hub-originated
 * chat line (MOTD, an operator's announcement) could be forged by anyone who
 * typed it first. Checked case-insensitively, the same "same name" the rest
 * of the hub already means.
 */
function testHubNameReserved() {
  const clock = makeClock();
  const relay = new Relay({ maxPlayers: 8, log: quiet, now: clock.now });

  for (const attempt of ['HUB', 'hub', ' hub ']) {
    const { peer } = dial(relay, attempt);
    const error = peer.outbox.find((m) => m.type === 'mmo.error');
    ok(error !== undefined, `"${attempt}" is refused with an mmo.error`);
    ok(/hub itself/i.test(error.message),
      `the refusal for "${attempt}" names the reason`);
    ok(!peer.outbox.some((m) => m.type === 'mmo.welcome'),
      `"${attempt}" is never welcomed`);
    ok(peer.closed === true, `and the connection for "${attempt}" is closed`);
  }

  const normal = dial(relay, 'RED');
  ok(normal.peer.outbox.some((m) => m.type === 'mmo.welcome'),
    'an ordinary name still admits');
}

/*
 * The message of the day rides mmo.welcome. Empty means nothing to say and
 * the field is absent entirely -- not just falsy -- which is what lets a
 * client from before this feature existed read straight past it. It is read
 * fresh at admit time, so an operator's SIGHUP-and-edit is visible to the
 * very next hello without a restart.
 */
function testWelcomeMotd() {
  const clock = makeClock();
  const relay = new Relay({ maxPlayers: 8, log: quiet, now: clock.now, motd: '' });

  // The value on the in-memory message object may still carry the key with
  // an `undefined` value (Object.assign copies it regardless) -- only a trip
  // through JSON, which is what a real socket does to every message, drops
  // an `undefined` field outright. This is the check that matches what an
  // actual client on the wire receives.
  const wireOf = (msg) => JSON.parse(JSON.stringify(msg));

  const first = dial(relay, 'MOTDONE');
  ok(first.welcome.motd === undefined,
    'no motd configured: the welcome carries no motd value');
  ok(!('motd' in wireOf(first.welcome)),
    'and on the wire the key is not present at all when there is nothing to say');

  relay.motd = '  Server   restarts   nightly \x01\x02 at 3am!! ';
  const second = dial(relay, 'MOTDTWO');
  ok(typeof second.welcome.motd === 'string' && second.welcome.motd.length > 0,
    'setting relay.motd is picked up by the very next hello -- the SIGHUP contract');
  ok(!/\s\s/.test(second.welcome.motd),
    'internal whitespace is collapsed to single spaces');
  ok(!/[\x00-\x1f]/.test(second.welcome.motd), 'control characters are stripped');
  ok('motd' in wireOf(second.welcome),
    'and the key is present on the wire once there is something to say');

  relay.motd = 'B'.repeat(200);
  const third = dial(relay, 'MOTDTHREE');
  ok(third.welcome.motd.length === MOTD_MAX,
    'an over-long motd is capped at MOTD_MAX');
  ok(third.welcome.motd === 'B'.repeat(MOTD_MAX),
    'by plain truncation, not by an ellipsis or anything cleverer');

  relay.motd = 'Back to something short';
  const fourth = dial(relay, 'MOTDFOUR');
  ok(fourth.welcome.motd === 'Back to something short',
    'a second mutation between hellos is picked up too, not just the first one');

  relay.motd = '';
  const fifth = dial(relay, 'MOTDFIVE');
  ok(fifth.welcome.motd === undefined,
    'and clearing it back to empty removes the field again for the next joiner');
}

/*
 * onMatchSettled: told once, and only for a battle that actually paid out --
 * both sides agreed, both were ranked, and neither claim moved mid-battle.
 * Every other outcome settleMatch() already refuses points for; this pins
 * that none of them fire the history hook either, and that the one case
 * that does fire carries exactly the record shape docs/plans/
 * server-live-ops.md §3 promises.
 */
function testMatchSettledHook() {
  const clock = makeClock();
  const records = [];
  const relay = new Relay({
    maxPlayers: 8, log: quiet, now: clock.now,
    onMatchSettled: (record) => records.push(record),
  });

  const one = dial(relay, 'MATCHONE');
  const two = dial(relay, 'MATCHTWO');
  const startedAt = clock.now();
  const matchId = fight(relay, one, two);
  clock.advance(50);
  const beforeWinner = relay.board.points(one.id);
  const beforeLoser = relay.board.points(two.id);
  relay.handle(one.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });

  ok(records.length === 1,
    'an agreed, both-ranked settlement fires the hook exactly once');
  const record = records[0];
  ok(Object.keys(record).sort().join(',') === 'at,loser,repeats,startedAt,winner',
    'the record carries exactly the contract fields, nothing else');
  ok(Object.keys(record.winner).sort().join(',') === 'gained,id,name,points',
    'the winner sub-record is id, name, points and gained');
  ok(Object.keys(record.loser).sort().join(',') === 'id,lost,name,points',
    'the loser sub-record is id, name, points and lost');
  ok(record.winner.id === one.id && record.loser.id === two.id,
    'history sides are keyed by persistent player id');
  ok(record.startedAt === startedAt,
    'startedAt is the moment the session (and its match paperwork) started');
  // Both sides reported while still in the session -- neither left it -- so
  // match.endedAt was never set, and settleMatch's fallback is the settlement
  // instant itself.
  ok(record.at === clock.now(),
    'endedAt was never set, so at falls back to the settlement instant');
  ok(record.at >= record.startedAt, 'at never precedes startedAt');
  ok(record.repeats === 0, 'a first meeting between these two has no repeats');
  ok(record.winner.name === 'MATCHONE' && record.loser.name === 'MATCHTWO',
    'winner and loser are named correctly');
  ok(record.winner.points === beforeWinner + record.winner.gained,
    "the winner's points are exactly before + gained");
  ok(record.loser.points === beforeLoser - record.loser.lost,
    "the loser's points are exactly before - lost");
  ok(record.winner.points >= 0 && record.loser.points >= 0,
    'neither side is ever negative');
  ok(record.winner.points === relay.board.points(one.id),
    'the record agrees with the board it was drawn from');

  // -------- disagreeing reports: no record --------
  const disputeId = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: disputeId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: disputeId, outcome: 'win' });
  ok(records.length === 1,
    'two sides both claiming the win settles nothing, so no history record either');

  // -------- one-sided report: no record --------
  const oneSidedId = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: oneSidedId, outcome: 'win' });
  ok(records.length === 1, 'a lone report is not a settlement, so no record either');
  relay.handle(one.id, { type: 'mmo.session_leave' });
  relay.handle(two.id, { type: 'mmo.session_leave' });

  // -------- an immediate rematch: repeats increments, the payout is discounted --------
  const rematchId = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: rematchId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: rematchId, outcome: 'loss' });
  ok(records.length === 2, 'the rematch settles and is recorded too');
  const rematch = records[1];
  ok(rematch.repeats === 1, 'an immediate rematch is the second meeting in the window');
  ok(rematch.winner.gained < record.winner.gained,
    'and the repeat discount means it pays less than the first meeting did');
}

/*
 * The OTHER way a ranked 1v1 reaches the ledger, and the one nothing covered.
 *
 * `settleMatch` (above) is both players reporting and agreeing. `settleMediated`
 * is the intermediator's verdict -- the referee ran the fight, so there is
 * nothing to agree about -- and it wrote its own copy of the history record,
 * spelled out by hand, byte-identical to the other except for the timestamp.
 * Neither this suite nor `server.test.js` ever executed that copy: server.test
 * drives the agreed path, and the mediated suites build a Relay with no
 * `onMatchSettled`, so the record was never built at all.
 *
 * That is a bad thing to leave untested about an append-only, operator-facing
 * file that `lib/cli.js` reads back: a field added or dropped on one side alone
 * would have shipped silently, and `history.jsonl` would have carried two
 * shapes depending on how each battle happened to end. Both sites now go
 * through `noteMatchSettled`, which owns the shape; this is the test that
 * proves the second one really does produce the first one's record.
 */
function testMediatedSettleWritesTheSameHistoryShape() {
  const clock = makeClock();
  const records = [];
  const relay = new Relay({
    maxPlayers: 8, log: quiet, now: clock.now,
    onMatchSettled: (record) => records.push(record),
  });

  const one = dial(relay, 'REFONE');
  const two = dial(relay, 'REFTWO');
  const startedAt = clock.now();
  const matchId = fight(relay, one, two);
  clock.advance(50);

  // A refereed battle over the session the match paperwork is keyed by --
  // `settleMediated` looks the match up by the battle's own id, which is what
  // ties a hub-run fight back to the two ranked seats that started it.
  const battle = {
    id: matchId, mode: '1v1', hostId: one.id,
    memberIds: [one.id, two.id],
    sides: { a: [one.id], b: [two.id] },
    npcIds: [], ruleset: null,
    parties: new Map(), bags: new Map(), bagHold: Object.create(null),
    sim: null, settled: false,
  };
  relay.battles.set(battle.id, battle);
  relay.settleMediated(battle, {
    outcome: 'win', winners: [one.id], losers: [two.id],
  });

  ok(records.length === 1,
    'a refereed 1v1 between two ranked players writes exactly one history line');
  const record = records[0];

  // The same four assertions testMatchSettledHook makes about the agreed
  // path. They are repeated rather than shared on purpose: the point is that
  // two DIFFERENT code paths produce one shape, and a helper both call would
  // pass just as happily if they had diverged and the helper were wrong.
  ok(Object.keys(record).sort().join(',') === 'at,loser,repeats,startedAt,winner',
    'the record carries exactly the contract fields, nothing else');
  ok(Object.keys(record.winner).sort().join(',') === 'gained,id,name,points',
    'the winner sub-record is id, name, points and gained');
  ok(Object.keys(record.loser).sort().join(',') === 'id,lost,name,points',
    'the loser sub-record is id, name, points and lost');
  ok(record.winner.id === one.id && record.loser.id === two.id,
    'history sides are keyed by persistent player id, exactly as the agreed '
    + 'path keys them -- this is what cli.js tags a ledger row from');

  ok(record.startedAt === startedAt,
    'startedAt is the moment the session started, not the moment it settled');
  // Deliberately the settlement instant and not `match.endedAt`: a refereed
  // outcome routinely lands while both players are still in the session, so
  // endedAt is usually unset here -- and where it is set, the referee's
  // verdict is the moment that matters, not whenever a socket went.
  ok(record.at === clock.now(),
    'at is the moment the referee settled it');
  ok(record.at >= record.startedAt, 'at never precedes startedAt');
  ok(record.winner.name === 'REFONE' && record.loser.name === 'REFTWO',
    'winner and loser are named correctly');
  ok(record.winner.gained > 0, 'the winner actually gained points');
}

/*
 * kickByName: the operator's half of a refusal. Everybody playing under that
 * name goes, not somebody -- a name is only unique among ranked players -- and
 * the caller is told exactly how many and who.
 */
function testKickByName() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['RED', 'BLUE', 'GREEN']);
  const [red, blue, green] = players;

  // -------- no match --------
  for (const p of players) p.peer.outbox = [];
  const rosterAtStart = relay.roster().length;
  const nothing = relay.kickByName('NOBODY');
  ok(nothing.kicked === 0 && nothing.names.length === 0,
    'kicking a name nobody plays under does nothing, reported honestly');
  ok(relay.roster().length === rosterAtStart, 'and the roster is untouched');
  ok(players.every((p) => p.peer.outbox.length === 0),
    'nobody hears anything about a kick that never happened');

  // -------- one match, default reason --------
  for (const p of players) p.peer.outbox = [];
  const rosterBefore = relay.roster().length;
  const result = relay.kickByName('red'); // matched case-insensitively
  ok(result.kicked === 1 && result.names[0] === 'RED',
    'one player matched, case-insensitively');
  const error = take(red, 'mmo.error');
  ok(error !== null && /operator/i.test(error.message),
    'the kicked player gets an mmo.error with a default remediation message');
  ok(red.peer.closed === true, "and their connection is closed");
  ok(relay.roster().length === rosterBefore - 1, 'the roster shrinks by one');
  const partedAtBlue = take(blue, 'mmo.part');
  ok(partedAtBlue !== null && partedAtBlue.id === red.id,
    'everyone still connected is told the kicked player left');
  ok(take(green, 'mmo.part') !== null, 'both of the remaining players hear it');

  // -------- custom reason, cleaned like any other chat line --------
  const { relay: relay2, players: players2 } = makeHub(clock, ['ONE', 'TWO']);
  const [pOne] = players2;
  pOne.peer.outbox = [];
  const messy = '  You    were  \x07 kicked for spamming!!! '.padEnd(200, 'x');
  const custom = relay2.kickByName('ONE', messy);
  ok(custom.kicked === 1, 'a custom reason still kicks');
  const customError = take(pOne, 'mmo.error');
  ok(customError.message.length === MESSAGE_MAX,
    'the reason is capped like any chat line (MESSAGE_MAX)');
  ok(!/[\x00-\x1f]/.test(customError.message),
    'and control characters are stripped from it');
  ok(/spamming/i.test(customError.message),
    'the cleaned custom text is what actually reaches the kicked player');

  // -------- two players sharing a display name: both kicked --------
  const clock3 = makeClock();
  const relay3 = new Relay({ maxPlayers: 8, log: quiet, now: clock3.now });
  const holder = dial(relay3, 'RED', { playerId: testPlayerId('kick-holder') });
  const twin = dial(relay3, 'red', { playerId: testPlayerId('kick-twin') });
  ok(relay3.get(holder.id).ranked === true, 'sanity: the first RED is ranked');
  ok(relay3.get(twin.id).ranked === true,
    'sanity: a different playerId with the same display name is ranked too');
  const both = relay3.kickByName('Red');
  ok(both.kicked === 2,
    'both connections playing under the same display name are kicked together');
  ok(holder.peer.closed === true && twin.peer.closed === true,
    'and both connections are closed');

  // -------- kicked mid-session: the partner gets session_end --------
  const clock4 = makeClock();
  const { relay: relay4, players: players4 } = makeHub(clock4, ['HOST', 'GUEST']);
  const [host, guest] = players4;
  fight(relay4, host, guest);
  guest.peer.outbox = [];
  relay4.kickByName('HOST');
  ok(take(guest, 'mmo.session_end') !== null,
    'the partner of a kicked mid-session player is told the session ended');
}

/*
 * announce: an ordinary mmo.chat line spoken as the hub, to everyone ready --
 * with no `from` at all, which is what makes it safe on a client that predates
 * this feature (no id means no bubble, and no words in a real player's mouth).
 */
function testAnnounce() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['ONE', 'TWO', 'THREE']);
  for (const p of players) p.peer.outbox = [];

  const result = relay.announce('Server restarts in five minutes');
  ok(result.delivered === 3, 'all three ready players are counted');
  for (const p of players) {
    const chat = take(p, 'mmo.chat');
    ok(chat !== null, `${p.name} receives the announcement as an ordinary chat line`);
    ok(chat.name === 'HUB' && chat.scope === 'global',
      'spoken as the hub, to everyone');
    ok(chat.text === 'Server restarts in five minutes',
      'the text arrives as sent, once cleaned');
    ok(!('from' in chat),
      'and carries no sender id at all -- not even as an explicit undefined');
  }

  // -------- cleaned and truncated to MESSAGE_MAX --------
  for (const p of players) p.peer.outbox = [];
  relay.announce('A'.repeat(200));
  const long = take(players[0], 'mmo.chat');
  ok(long.text.length === MESSAGE_MAX,
    'an over-long announcement is capped at MESSAGE_MAX');

  // -------- text that cleans to empty is refused outright --------
  for (const p of players) p.peer.outbox = [];
  const empty = relay.announce('\x01\x02\x03');
  ok(empty.delivered === 0, 'text that cleans to nothing delivers to nobody');
  for (const p of players) {
    ok(take(p, 'mmo.chat') === null, 'and nothing is sent to anybody either');
  }

  // -------- a client mid-handshake is not counted or sent to --------
  const ghost = { outbox: [], remoteAddress: '127.0.0.1' };
  ghost.send = (msg) => ghost.outbox.push(msg);
  ghost.close = () => {};
  relay.accept(ghost); // accepted, but never said hello -- not ready
  for (const p of players) p.peer.outbox = [];
  const withGhost = relay.announce('hello everyone');
  ok(withGhost.delivered === 3,
    'a connection that never said hello is not counted');
  ok(ghost.outbox.length === 0, 'nor sent anything at all');
}

// --------------------------------------------------------- the admin flag
//
// docs/plans/admin-join-code.md §5 T1, the relay half: a credential's
// `admin` bit rides mmo.auth's verdict (handlers['mmo.auth'], relay.js:236)
// into `client.admin`, and from there to three places -- the operator's own
// welcome, roster() for operator views, and nowhere else. Socket-free, like
// everything above: `relay.auth` is stubbed at the same seam
// authPort(lib/server.js) implements for a real hub, answering `newNonce`
// and `verify(nonce, response)` with a verdict object that already carries
// `admin` -- exactly what server.js's wrapper hands the relay after reading
// auth.isAdminCredential() itself. What is under test here is what the relay
// does with that verdict, not the credential lookup, which is auth.test.js's
// job.

/*
 * A minimal `relay.auth` stub: `verify` reads the response string as a key
 * into a table of verdicts, so a test can hand out a distinct 64-hex-char
 * "response" per dial and get back whatever verdict it wants -- admin,
 * player, or a rejection -- without a real credential or HMAC anywhere in
 * the picture. `newNonce` only has to look like one; the relay never
 * inspects it beyond storing and echoing it back to verify().
 */
function stubAuth(verdicts) {
  let nonces = 0;
  return {
    newNonce: () => `${'a'.repeat(31)}${(nonces++ % 10)}`,
    verify: (nonce, response) =>
      verdicts[response] || { ok: false, credentialId: null, reason: 'rejected' },
  };
}

const ADMIN_RESPONSE = 'a'.repeat(64);
const PLAYER_RESPONSE = 'b'.repeat(64);

/*
 * Drives the full mmo.hello -> mmo.challenge -> mmo.auth handshake a real
 * client goes through against an authenticated hub -- makeHub's dial()
 * skips this because its hub has no auth configured at all.
 */
function dialAuthed(relay, name, response) {
  const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => { peer.closed = true; };
  const ephemeralId = relay.accept(peer);
  const playerId = testPlayerId(name);
  relay.handle(ephemeralId, {
    type: 'mmo.hello', proto: PROTOCOL, playerId, name, sprite: 'SPRITE_RED',
    map: 'PALLET', x: 1, y: 1, facing: 'down',
  });
  const challenge = peer.outbox.find((m) => m.type === 'mmo.challenge');
  if (challenge) relay.handle(ephemeralId, { type: 'mmo.auth', response });
  const welcome = peer.outbox.find((m) => m.type === 'mmo.welcome');
  return { id: playerId, peer, welcome, ephemeralId };
}

// The value on the in-memory message object may still carry a key with an
// `undefined` value (Object.assign copies it regardless) -- only a trip
// through JSON, which is what a real socket does to every message, drops an
// `undefined` field outright. Same idiom testWelcomeMotd uses above.
const wireOf = (msg) => JSON.parse(JSON.stringify(msg));

/*
 * The admin verdict, end to end: one client whose stubbed verify() answers
 * `admin: true`, one whose verdict answers `admin: false`, admitted onto the
 * same hub. The welcome, the roster, and every presence-shaped message they
 * generate along the way are all checked in one pass.
 */
function testAdminFlagOverTheWire() {
  const clock = makeClock();
  const relay = new Relay({
    maxPlayers: 8, log: quiet, now: clock.now,
    auth: stubAuth({
      [ADMIN_RESPONSE]: { ok: true, credentialId: 'cred-admin', reason: null, admin: true },
      [PLAYER_RESPONSE]: { ok: true, credentialId: 'cred-player', reason: null, admin: false },
    }),
  });

  const admin = dialAuthed(relay, 'OPERATOR', ADMIN_RESPONSE);
  ok(admin.welcome !== undefined, 'the admin credential is admitted');
  ok(admin.welcome.admin === true,
    'the admin\'s own welcome carries admin: true');
  ok(wireOf(admin.welcome).admin === true,
    'and the flag survives a JSON round trip -- a real socket would send true, not drop it');

  const player = dialAuthed(relay, 'CIVILIAN', PLAYER_RESPONSE);
  ok(player.welcome !== undefined, 'the player credential is admitted too');
  ok(player.welcome.admin === undefined,
    'a non-admin welcome carries no admin value at all -- the motd idiom, not admin: false');
  ok(!('admin' in wireOf(player.welcome)),
    'and on the wire the key is entirely absent, matching what an older client already expects');

  const byName = (name) => relay.roster().find((entry) => entry.name === name);
  ok(byName('OPERATOR').admin === true,
    'roster() carries admin: true for the admin connection');
  ok(byName('CIVILIAN').admin === false,
    'and admin: false -- never absent -- for the player, so a row is never read as "absent means no"');

  // presenceOf() is what every player-visible message is built from --
  // the welcome's own players[] array, the mmo.join broadcast, and every
  // mmo.move -- and it must never carry the flag, admin or not.
  const adminPresence = presenceOf(relay.get(admin.id));
  ok(!('admin' in adminPresence),
    'presenceOf() for the admin connection carries no admin key at all');
  ok(!('admin' in wireOf(adminPresence)), 'nor once it has been round-tripped through JSON');

  // The welcome the player received named the admin among `players[]` --
  // sent before the player's own hello, so it is presence of someone else,
  // exactly the shape other players are told about each other.
  const adminAsSeenByPlayer = player.welcome.players.find((p) => p.name === 'OPERATOR');
  ok(adminAsSeenByPlayer !== undefined, 'sanity: the player\'s welcome lists the admin as a peer');
  ok(!('admin' in adminAsSeenByPlayer),
    'and that presence entry carries no admin key -- other players never learn who holds power');

  // mmo.join: broadcast to everyone already on the hub when a new player is
  // admitted. The admin joined first, so it is the player's arrival that is
  // heard, and it is the player's own presence being broadcast -- checked
  // for completeness even though this one is never an admin.
  admin.peer.outbox = [];
  const third = dialAuthed(relay, 'BYSTANDER', PLAYER_RESPONSE);
  const joinSeenByAdmin = admin.peer.outbox.find((m) => m.type === 'mmo.join');
  ok(joinSeenByAdmin !== undefined, 'the admin hears the new arrival as an ordinary mmo.join');
  ok(!('admin' in joinSeenByAdmin.player),
    'and the broadcast presence carries no admin key either');

  // mmo.move: the admin steps, and everyone else is told where -- again as
  // ordinary presence, with no hint that the stepping player is an operator.
  player.peer.outbox = [];
  relay.handle(admin.id, { type: 'mmo.move', map: 'PALLET', x: 2, y: 2, facing: 'down' });
  const moveSeenByPlayer = player.peer.outbox.find((m) => m.type === 'mmo.move');
  ok(moveSeenByPlayer !== undefined, 'the player hears the admin move');
  ok(!('admin' in moveSeenByPlayer),
    'and the mmo.move payload -- itself a bare presenceOf() -- carries no admin key');
  ok(!('admin' in wireOf(moveSeenByPlayer)), 'nor once round-tripped through JSON');

  relay.drop(third.id);
}

/*
 * A hub with no `auth` option at all -- the unauthenticated legacy path
 * (plan §3.5: "nobody is admin -- the flag rides the credential, no
 * credential means no admin"). makeHub()'s dial already exercises exactly
 * this hub shape; this pins what it means for the admin flag specifically.
 */
function testNoAuthHubNeverAdmits() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['NOAUTH']);
  const [solo] = players;

  ok(relay.get(solo.id).admin === false,
    'with no auth configured, the connection is never marked admin');
  const welcome = take(solo, 'mmo.welcome');
  ok(welcome.admin === undefined,
    'and its welcome carries no admin value -- an unauthenticated hub has no ' +
    'credential to derive one from');
  ok(!('admin' in wireOf(welcome)), 'the key is absent on the wire too');

  const row = relay.roster().find((entry) => entry.name === 'NOAUTH');
  ok(row.admin === false,
    'roster() still answers a plain false, never absent, for an unauthenticated connection');
}

/*
 * A rejected auth attempt never reaches admit() at all, so it must never
 * appear on the roster or be handed a welcome -- the admin flag is moot for
 * a connection that was never let in, but a failing verify() must not leave
 * `client.admin` set from some earlier state either.
 */
function testRejectedAuthNeverAdmits() {
  const clock = makeClock();
  const relay = new Relay({
    maxPlayers: 8, log: quiet, now: clock.now,
    auth: stubAuth({
      [ADMIN_RESPONSE]: { ok: true, credentialId: 'cred-admin', reason: null, admin: true },
    }),
  });

  const rejected = dialAuthed(relay, 'INTRUDER', 'c'.repeat(64));
  ok(rejected.welcome === undefined, 'a response with no matching verdict is never welcomed');
  ok(relay.roster().length === 0, 'and never appears on the roster');
  ok(rejected.peer.closed === true, 'the connection is closed on refusal');
  // refuse() drops the client outright (relay.js:973-977), so there is no
  // lingering client object to have been left with a stray admin flag on it
  // -- confirmed here rather than by reading a field that no longer exists.
  ok(relay.get(rejected.id) === null,
    'and the client is gone from the relay entirely, not merely unmarked');
}

function main() {
  testExpected();
  testSwing();
  testDiscount();
  testClamps();
  testBoardBasics();
  testBoardPersistenceByPlayerId();
  testFarmingIsWorthless();
  testLeaderboard();

  testDuplicatePlayerIdRefused();
  testResultsNeedTwoVoices();
  testLiesScoreNothing();
  testReportWindow();
  testLeaderboardOverTheWire();
  testRatingBelongsToPlayerId();
  testPersistenceHook();

  testRosterFieldsAndReadyOnly();
  testRosterBusyAndPartyFlags();
  testRosterChangeNotifications();

  testHubNameReserved();
  testWelcomeMotd();
  testMatchSettledHook();
  testMediatedSettleWritesTheSameHistoryShape();
  testKickByName();
  testAnnounce();

  testAdminFlagOverTheWire();
  testNoAuthHubNeverAdmits();
  testRejectedAuthNeverAdmits();

  console.log(`\n  ${passed}/${passed} checks passed  (rank)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + ((err && err.stack) || err) + '\n');
  process.exit(1);
}
