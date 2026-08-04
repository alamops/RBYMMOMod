#!/usr/bin/env node
'use strict';

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
  Board, mintToken, expected, swing, discount, keyOf, clampPoints,
  RANK_K, RANK_MAX, RANK_TOP, RANK_REPEAT_WINDOW_MS, RANK_REPEAT_FADE,
  RANK_REPORT_GRACE_MS, RANK_QUERY_GATE_MS,
} = require('./lib/rank.js');
const { cleanToken } = require('./lib/sanitize.js');
const { Relay, PROTOCOL } = require('./lib/relay.js');
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
  ok(keyOf(' ash ') === 'ASH', 'a name is trimmed and folded to one identity');
  ok(keyOf('   ') === null, 'and a name of nothing is not one');
  ok(clampPoints(-5) === 0, 'ratings floor at zero');
  ok(clampPoints(RANK_MAX + 10) === RANK_MAX, 'and stop at the ceiling');
  ok(clampPoints('nonsense') === 0, 'a non-number is zero');
}

// --------------------------------------------------------------- the board

function testBoardBasics() {
  const season = new Board();
  ok(season.points('ASH') === 0, 'everybody starts unranked');

  const first = season.record('ASH', 'GARY', 0);
  ok(first !== null, 'a match between two players settles');
  ok(first.winner.points === 16, 'the winner is on the board');
  ok(first.loser.points === 0, 'and the loser cannot go below zero');
  ok(season.points('ash') === 16, 'a name is matched case-insensitively');
  ok(season.record('ASH', 'ash', 0) === null, 'and nobody can beat themselves');
  ok(season.record('ASH', null, 0) === null, 'a nameless opponent is not a match');
}

function testFarmingIsWorthless() {
  const farm = new Board();
  const earned = [];
  for (let i = 1; i <= RANK_REPEAT_FADE; i += 1) {
    earned.push(farm.record('ALPHA', 'BRAVO', i * 10).winner.gained);
  }
  ok(earned[0] > 0, 'the first win pays');
  ok(earned[1] < earned[0], 'the rematch pays less');
  ok(earned[2] < earned[1], 'and so on down');
  ok(earned[earned.length - 1] === 0,
    'until a rematch inside the window is worth nothing');
  ok(farm.points('BRAVO') === 0, 'and the loser bottoms out at zero');

  // The discount does not care which way round the wins go, so two friends
  // cannot take turns.
  const swapped = new Board();
  const there = swapped.record('ALPHA', 'BRAVO', 0).winner.gained;
  const back = swapped.record('BRAVO', 'ALPHA', 1).winner.gained;
  ok(back < there, 'alternating wins is the same pairing, and is discounted');

  // Two boards played identically up to the rematch, so the ratings are the
  // same at that point and the only difference is how long they waited.
  const soon = new Board();
  const later = new Board();
  soon.record('ALPHA', 'BRAVO', 0);
  later.record('ALPHA', 'BRAVO', 0);
  const sooner = soon.record('ALPHA', 'BRAVO', 1).winner.gained;
  const waited = later.record('ALPHA', 'BRAVO',
    RANK_REPEAT_WINDOW_MS + 1).winner.gained;
  ok(waited > sooner, 'a rematch after the window is worth full price again');
}

/*
 * Claiming a name.
 *
 * A rating is keyed by trainer name, so without this anybody who knows your
 * nickname can put your rating on and spend it. The ticket is what turns
 * "types the same name" into "is the same player".
 */
function testClaims() {
  const token = mintToken();
  ok(cleanToken(token) === token,
    'a minted token is exactly the shape the wire sanitiser accepts');
  ok(mintToken() !== token, 'and two of them differ');

  const board = new Board();
  const other = mintToken();
  ok(board.claimed('ASH') === false, 'a name nobody has used is unclaimed');
  ok(board.claim('ASH', null, token) === 'claimed',
    'the first player to use it claims it');
  ok(board.claimed('ASH') === true, 'and it is claimed from then on');
  ok(board.claim('ASH', token, other) === 'owner',
    'the holder of the ticket is the owner, and does not re-claim it');
  ok(board.claim('ash', token, other) === 'owner',
    'whatever case they type it in');
  ok(board.claim('ASH', null, other) === 'impostor',
    'somebody typing the name with no ticket is not the owner');
  ok(board.claim('ASH', other, null) === 'impostor', 'nor is a wrong ticket');
  ok(board.claim('ASH', `${token}ff`, null) === 'impostor',
    'and neither is one with something stuck on the end');

  const stored = board.get('ASH');
  ok(stored.tokenHash && stored.tokenHash !== token,
    'only a digest is kept, never the ticket');
  ok(!stored.tokenHash.includes(token), 'and it does not contain it');

  const unmintable = new Board();
  ok(unmintable.claim('NOBODY', null, null) === 'open',
    'a hub that cannot mint leaves the name open rather than locking it');
  ok(unmintable.claimed('NOBODY') === false, 'so the next player can claim it');

  const reloaded = new Board().import(board.export());
  ok(reloaded.claim('ASH', token, other) === 'owner',
    'a ticket still works after a trip through the file');
  ok(reloaded.claim('ASH', other, null) === 'impostor',
    'and a wrong one still does not');
  const corrupt = new Board().import([
    { name: 'ASH', points: 10, tokenHash: 'not a digest' },
  ]);
  ok(corrupt.claimed('ASH') === false,
    'a hash that is not a hash is dropped -- a name nobody can claim would ' +
    'be worse than one anybody can');

  board.record('ASH', 'GARY', 0);
  ok(board.top(RANK_TOP).every((row) => row.tokenHash === undefined),
    'the leaderboard sent to clients carries no digests');
}

/* The same story through the relay, which is where a player meets it. */
function testClaimsOverTheWire() {
  const clock = makeClock();
  const relay = new Relay({ maxPlayers: 8, log: quiet, now: clock.now });

  const dial = (name, token) => {
    const peer = { outbox: [], remoteAddress: '127.0.0.1' };
    peer.send = (msg) => peer.outbox.push(msg);
    peer.close = () => {};
    const id = relay.accept(peer);
    relay.handle(id, { type: 'mmo.hello', proto: PROTOCOL, name, rankToken: token });
    const welcome = peer.outbox.find((m) => m.type === 'mmo.welcome');
    return { id, peer, welcome };
  };

  const first = dial('ALPHA');
  ok(cleanToken(first.welcome.rankToken) !== null,
    'a first visit is handed a claim ticket in the welcome');
  ok(first.welcome.ranked === true, 'and is scored');
  const ticket = first.welcome.rankToken;
  relay.drop(first.id);

  const again = dial('ALPHA', ticket);
  ok(again.welcome.ranked === true, 'coming back with the ticket is the same player');
  ok(again.welcome.rankToken === undefined,
    'and the ticket is not re-sent: a hub that handed it to whoever asked ' +
    'would not be checking anything');
  relay.drop(again.id);

  const faker = dial('ALPHA');
  ok(faker.welcome.ranked === false,
    'a stranger typing a claimed name is told they will not be scored');
  ok(faker.welcome.points === 0, 'and wears none of that name\'s rating');
  ok(faker.welcome.rankToken === undefined,
    'no ticket is handed out for a name already claimed');

  // ...and their battles cannot move the real player's rating.
  const victim = dial('BETA');
  const match = fight(relay,
    { id: faker.id, peer: faker.peer }, { id: victim.id, peer: victim.peer });
  relay.handle(faker.id, { type: 'mmo.result', session: match, outcome: 'win' });
  relay.handle(victim.id, { type: 'mmo.result', session: match, outcome: 'loss' });
  ok(relay.board.points('ALPHA') === 0,
    'an unranked player cannot add to the rating of the name they borrowed');
  ok(relay.board.points('BETA') === 0,
    'and their opponent loses nothing to a match that was never scored');
}

function testLeaderboard() {
  const ladder = new Board();
  for (let i = 1; i <= 14; i += 1) {
    ladder.seen(`WINNER${i}`, 'SPRITE_RED');
    ladder.record(`WINNER${i}`, `PUNCHBAG${i}`, i);
  }
  ladder.seen('LURKER', 'SPRITE_LASS');

  const top = ladder.top(RANK_TOP);
  ok(top.length === RANK_TOP, 'the board is cut to the top ten');
  ok(top[0].points >= top[1].points, 'best first');
  ok(top.every((row) => row.points > 0),
    'and nobody with nothing to show is on it');
  ok(!top.some((row) => row.name === 'LURKER'),
    'a player who has never won is not ranked');
  ok(!top.some((row) => row.name.startsWith('PUNCHBAG')),
    'and neither is one who only lost');

  const saved = ladder.export();
  ok(saved.length > top.length,
    'everything is exported, not only the visible ten');
  const restored = new Board().import(saved);
  ok(restored.points(top[0].name) === top[0].points,
    'a rating survives a round trip through the file');
  ok(restored.top(RANK_TOP).length === top.length,
    'and so does the board it makes');

  const mangled = new Board().import([
    'not a row', { name: 'OK', points: 40 }, { points: 9 }, null,
  ]);
  ok(mangled.points('OK') === 40,
    "a corrupt row costs its own rating, not the whole file's");
}

// --------------------------------------------------------------- the relay

function makeClock(start = 1000) {
  let t = start;
  return { now: () => t, advance(ms) { t += ms; } };
}

/*
 * A hub with two players on it, driven through the same entry point a socket
 * would use. Peers keep an outbox instead of a socket; `take` pulls the first
 * message of a type so a later assertion is not confused by earlier traffic.
 */
function makeHub(clock, names) {
  const relay = new Relay({ maxPlayers: 8, log: quiet, now: clock.now });
  const players = names.map((name) => {
    const peer = { outbox: [], closed: false, remoteAddress: '127.0.0.1' };
    peer.send = (msg) => peer.outbox.push(msg);
    peer.close = () => { peer.closed = true; };
    const id = relay.accept(peer);
    // no rankToken: every name in these scenarios is used for the first time,
    // so the hub claims it and hands the ticket back in the welcome
    relay.handle(id, {
      type: 'mmo.hello', proto: PROTOCOL, name, sprite: 'SPRITE_RED',
      map: 'PALLET', x: 1, y: 1, facing: 'down',
    });
    return { id, peer, name };
  });
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
  ok(relay.board.points('ONE') === 0, 'one report on its own scores nothing');
  ok(take(one, 'mmo.rank') === null, 'and moves nobody');

  relay.handle(three.id,
    { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(relay.board.points('ONE') === 0,
    'a player who was not in the battle is ignored');

  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(relay.board.points('ONE') === 16, 'two agreeing reports settle the match');
  ok(relay.board.points('TWO') === 0, 'and the loser floors at zero');
  const moved = take(one, 'mmo.rank');
  ok(moved && moved.points === 16, 'the winner is told their new rating');
  ok(take(two, 'mmo.rank') !== null,
    'and so is the loser -- both, in the same breath');
  ok(take(three, 'mmo.rank') !== null,
    'while everybody else hears it too, so their rosters and cards move');

  relay.handle(one.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(relay.board.points('ONE') === 16, 'a settled match cannot be settled twice');
}

function testLiesScoreNothing() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['ONE', 'TWO']);
  const [one, two] = players;

  const bothClaim = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: bothClaim, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: bothClaim, outcome: 'win' });
  ok(relay.board.points('ONE') === 0,
    'two players both claiming the win score nothing');
  ok(relay.board.points('TWO') === 0, 'neither of them');

  const revised = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: revised, outcome: 'loss' });
  relay.handle(one.id, { type: 'mmo.result', session: revised, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: revised, outcome: 'loss' });
  ok(relay.board.points('ONE') === 0 && relay.board.points('TWO') === 0,
    'the first answer stands, so a retraction cannot manufacture agreement');

  const drawn = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: drawn, outcome: 'draw' });
  relay.handle(two.id, { type: 'mmo.result', session: drawn, outcome: 'draw' });
  ok(relay.board.points('ONE') === 0, 'a draw moves nobody');

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
  ok(relay.board.points('ONE') === 0,
    'a trade cannot be reported as a won battle');

  // And an outcome that is not one is not a report at all.
  const nonsense = fight(relay, one, two);
  relay.handle(one.id,
    { type: 'mmo.result', session: nonsense, outcome: 'victory' });
  relay.handle(two.id, { type: 'mmo.result', session: nonsense, outcome: 'loss' });
  ok(relay.board.points('TWO') === 0, 'an invented outcome is refused outright');
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
  ok(relay.board.points('ONE') === 16,
    'a report that lands after the session ended still counts');

  const stale = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: stale, outcome: 'win' });
  relay.handle(one.id, { type: 'mmo.session_leave' });
  clock.advance(RANK_REPORT_GRACE_MS + 1000);
  // the sweep runs when a battle starts, which is the only moment the table
  // can grow -- so start one, and then report into the expired match
  fight(relay, one, two);
  relay.handle(two.id, { type: 'mmo.result', session: stale, outcome: 'loss' });
  ok(relay.board.points('ONE') === 16,
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

function testRatingBelongsToTheName() {
  const clock = makeClock();
  const { relay, players } = makeHub(clock, ['COMEBACK', 'VICTIM']);
  const [one, two] = players;
  // the ticket the hub minted for this name, handed over exactly once
  const ticket = one.peer.outbox.find((m) => m.type === 'mmo.welcome').rankToken;
  ok(ticket, 'a first visit is handed a claim ticket');

  const matchId = fight(relay, one, two);
  relay.handle(one.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(two.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });
  const won = relay.board.points('COMEBACK');
  ok(won > 0, 'the winner has a rating');

  relay.drop(one.id);
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const backId = relay.accept(peer);
  relay.handle(backId, {
    type: 'mmo.hello', proto: PROTOCOL, name: 'COMEBACK', sprite: 'SPRITE_RED',
    rankToken: ticket,
  });
  const welcome = peer.outbox.find((m) => m.type === 'mmo.welcome');
  ok(welcome && welcome.points === won,
    'which is still theirs when they come back with the ticket, and the ' +
    'welcome says so');
}

function testPersistenceHook() {
  const clock = makeClock();
  const seen = [];
  const relay = new Relay({
    maxPlayers: 4, log: quiet, now: clock.now,
    onRankChange: (settled) => seen.push(settled),
  });
  const players = ['A', 'B'].map((name) => {
    const peer = { outbox: [], remoteAddress: '127.0.0.1' };
    peer.send = (msg) => peer.outbox.push(msg);
    peer.close = () => {};
    const id = relay.accept(peer);
    relay.handle(id, { type: 'mmo.hello', proto: PROTOCOL, name });
    return { id, peer };
  });
  const matchId = fight(relay, players[0], players[1]);
  relay.handle(players[0].id,
    { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(players[1].id,
    { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(seen.length === 1, 'a settled match tells the caller so, once');
  ok(seen[0].winner.name === 'A', 'naming who won');

  // A hook that throws is the disk being full, and must not cost the players
  // their result: the ratings are already correct in memory.
  const angry = new Relay({
    maxPlayers: 4,
    log: quiet,
    now: clock.now,
    onRankChange: () => { throw new Error('disk full'); },
  });
  const pair = ['C', 'D'].map((name) => {
    const peer = { outbox: [], remoteAddress: '127.0.0.1' };
    peer.send = (msg) => peer.outbox.push(msg);
    peer.close = () => {};
    const id = angry.accept(peer);
    angry.handle(id, { type: 'mmo.hello', proto: PROTOCOL, name });
    return { id, peer };
  });
  const angryMatch = fight(angry, pair[0], pair[1]);
  angry.handle(pair[0].id,
    { type: 'mmo.result', session: angryMatch, outcome: 'win' });
  angry.handle(pair[1].id,
    { type: 'mmo.result', session: angryMatch, outcome: 'loss' });
  ok(angry.board.points('C') === 16,
    'a failing persistence hook does not undo the match');
}

function main() {
  testExpected();
  testSwing();
  testDiscount();
  testClamps();
  testBoardBasics();
  testClaims();
  testFarmingIsWorthless();
  testLeaderboard();
  testResultsNeedTwoVoices();
  testLiesScoreNothing();
  testReportWindow();
  testLeaderboardOverTheWire();
  testRatingBelongsToTheName();
  testClaimsOverTheWire();
  testPersistenceHook();

  console.log(`\n  ${passed}/${passed} checks passed  (rank)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + ((err && err.stack) || err) + '\n');
  process.exit(1);
}
