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

/*
 * A claim is provisional until it is proved -- see Board.claim's own header
 * for why. What follows pins that rule case by case: a fresh claim starts
 * unproved, proving it locks the name down (even with nothing scored), an
 * unproved and unscored claim moves rather than locking anyone out, and a
 * name that has settled a battle is never up for grabs regardless.
 */
function testFreshClaimIsUnconfirmed() {
  const board = new Board();
  const token = mintToken();
  ok(board.claim('ASH', null, token) === 'claimed', 'the name is free, so it is claimed');
  const entry = board.get('ASH');
  ok(entry.confirmed === false,
    'but a mint only says a ticket was posted, not that anyone proved holding it');
  // ...and it is not written down. A row nobody has proved, played or scored
  // under is one claim() will hand to the next player who asks, so persisting
  // it buys nothing -- and a hub anybody can dial would otherwise grow (and
  // rewrite) a row per passing hello.
  ok(board.export().find((row) => row.name === 'ASH') === undefined,
    'and an unproved, unplayed, unrated claim is not written to the file at all');
}

/*
 * The claim moves for a name nobody is *using*. A holder who is connected and
 * ranked under it right now is the one thing board state cannot see, and
 * without it the leniency above is a theft: the second player takes the
 * claim, and the first player's next win lands on it.
 */
function testLiveHolderBlocksReclaim() {
  const board = new Board();
  const held = mintToken();
  ok(board.claim('ASH', null, held) === 'claimed', 'first visit mints a claim');

  ok(board.claim('ASH', null, mintToken(), true) === 'impostor',
    'a tokenless hello while the holder is connected and ranked is an impostor');
  ok(board.claim('ASH', mintToken(), mintToken(), true) === 'impostor',
    'and so is a wrong ticket');
  ok(board.claim('ASH', held, mintToken(), true) === 'owner',
    'the holder themselves is still the owner, live or not');

  // The lockout this whole branch exists to fix has the owner *gone*, so it
  // is untouched: same board, nobody connected, same tokenless hello.
  const gone = new Board();
  gone.claim('ASH', null, mintToken());
  const fresh = mintToken();
  ok(gone.claim('ASH', null, fresh, false) === 'claimed',
    'with the holder disconnected the reclaim still works');
  ok(gone.claim('ASH', fresh, mintToken()) === 'owner',
    'and the ticket it minted is the one that answers');
}

/*
 * A row with a rating but no games behind it is not reclaimable either.
 * `played` is the rule; this is the belt on top of it, for a hand-edited
 * ranking.json where the two disagree.
 */
function testPointsWithoutGamesBlockReclaim() {
  const hashed = new Board();
  const token = mintToken();
  hashed.claim('EDITED', null, token);
  const row = hashed.export().find((r) => r.name === 'EDITED');
  ok(row === undefined, 'sanity: an unproved, unplayed, unrated row is not exported');

  const edited = new Board().import([{
    name: 'EDITED', points: 500, played: 0, won: 0, confirmed: false,
    tokenHash: 'a'.repeat(64),
  }]);
  ok(edited.get('EDITED').points === 500 && edited.get('EDITED').played === 0,
    'sanity: the imported row has a rating and no games');
  ok(edited.claim('EDITED', null, mintToken()) === 'impostor',
    'points above the starting value block a reclaim on their own');
}

function testOwnerReturnConfirmsAndBlocksReclaim() {
  const board = new Board();
  const token = mintToken();
  ok(board.claim('ASH', null, token) === 'claimed', 'first visit mints a claim');
  ok(board.get('ASH').confirmed === false, 'not proved yet');

  ok(board.claim('ASH', token, mintToken()) === 'owner',
    'the ticket holder returns and is recognised');
  ok(board.get('ASH').confirmed === true,
    'a proved ticket confirms the claim, even though nothing has scored');

  ok(board.claim('ASH', null, mintToken()) === 'impostor',
    'and a confirmed claim is never reclaimed, even at zero games played');
}

function testUnconfirmedUnscoredReclaims() {
  const board = new Board();
  const oldToken = mintToken();
  ok(board.claim('ASH', null, oldToken) === 'claimed', 'first visit mints a claim');
  ok(board.get('ASH').confirmed === false, 'nobody has proved it yet');

  const newToken = mintToken();
  ok(board.claim('ASH', null, newToken) === 'claimed',
    'a second tokenless hello for an unconfirmed, unscored name re-mints ' +
    'rather than locking the name shut');

  // The claim is still unproved, so even a *wrong* ticket moves it again
  // instead of being told apart from a missing one -- "unconfirmed and
  // unscored" is the whole test, not which ticket was presented.
  const staleToken = mintToken();
  ok(board.claim('ASH', oldToken, staleToken) === 'claimed',
    'a wrong ticket on a still-unconfirmed, unscored name reclaims once ' +
    'more rather than answering impostor');

  ok(board.claim('ASH', staleToken, mintToken()) === 'owner',
    'the latest ticket is the one that answers now');
  ok(board.get('ASH').confirmed === true, 'and proving it confirms the claim');

  ok(board.claim('ASH', newToken, mintToken()) === 'impostor',
    'now that it is proved, an earlier ticket is worthless');
}

function testScoredNameNeverReclaimed() {
  const board = new Board();
  const token = mintToken();
  board.claim('ASH', null, token);
  board.record('ASH', 'GARY', 0);
  const row = board.export().find((r) => r.name === 'ASH');
  ok(row.played === 1 && row.confirmed === true,
    'sanity: this name has scored, and settling confirmed it too');

  // Even a row that somehow reached disk unconfirmed -- a legacy file, a
  // hand-edited one -- must not reopen a name that has already scored:
  // `played` alone is the gate, `confirmed` is the belt on top of it.
  row.confirmed = false;
  const reloaded = new Board().import([row]);
  ok(reloaded.get('ASH').confirmed === false && reloaded.get('ASH').played === 1,
    'the imported state: unconfirmed on file, but already scored');
  ok(reloaded.claim('ASH', null, mintToken()) === 'impostor',
    'played > 0 blocks reclaim on its own, independent of confirmed');
}

function testSettlementConfirmsBothSides() {
  const board = new Board();
  ok(board.get('ALPHA') === null, 'sanity: neither name is on the board yet');
  board.record('ALPHA', 'BRAVO', 0);
  ok(board.get('ALPHA').confirmed === true,
    'the winner is confirmed by having played, ticket or not');
  ok(board.get('BRAVO').confirmed === true,
    'and so is the loser -- a settled battle proves both names at once');
}

function testConfirmedRoundTrips() {
  // The unconfirmed side of the trip has to be a row the file actually keeps,
  // and export() drops the throwaway ones -- so this is an unproved claim on a
  // name that has played, which is what a legacy file looks like.
  const board = new Board().import([{
    name: 'PROVISIONAL', points: 12, played: 1, won: 1, confirmed: false,
    tokenHash: 'b'.repeat(64),
  }]);
  ok(board.get('PROVISIONAL').confirmed === false, 'sanity: unconfirmed');

  const provenToken = mintToken();
  board.claim('PROVEN', null, provenToken);
  board.claim('PROVEN', provenToken, mintToken());
  ok(board.get('PROVEN').confirmed === true, 'sanity: confirmed by its owner');

  const reloaded = new Board().import(board.export());
  ok(reloaded.get('PROVISIONAL').confirmed === false,
    'an unconfirmed claim comes back unconfirmed');
  ok(reloaded.get('PROVEN').confirmed === true,
    'and a confirmed one comes back confirmed -- both directions of the trip');
}

/*
 * What the file is allowed to grow. Every first hello under a new name claims
 * it, so a hub anybody can dial would otherwise write a row per connection --
 * and rewrite the whole file each time. Only claims worth surviving a restart
 * are written: proved, played, or carrying a rating.
 */
function testThrowawayClaimsAreNotExported() {
  const board = new Board();
  board.claim('DRIFTER', null, mintToken());
  board.seen('WATCHER', 'SPRITE_RED');
  ok(board.export().length === 0,
    'a board of nothing but fresh claims and passers-by writes no rows at all');

  const proved = mintToken();
  board.claim('PROVER', null, proved);
  board.claim('PROVER', proved, mintToken());
  board.record('WINNER', 'LOSER', 0);
  const names = board.export().map((row) => row.name).sort();
  ok(names.join(',') === 'LOSER,PROVER,WINNER',
    'and a proved claim, a win and a loss are all kept -- those are what a ' +
    'restart has to survive');
}

function testLegacyImportInfersConfirmed() {
  const fakeHash = (c) => c.repeat(64);
  const legacy = new Board().import([
    { name: 'VETERAN', points: 40, played: 3, won: 2, tokenHash: fakeHash('a') },
    { name: 'ROOKIE', points: 0, played: 0, won: 0, tokenHash: fakeHash('b') },
  ]);
  ok(legacy.get('VETERAN').confirmed === true,
    'a legacy row with no confirmed field, but with results, is read as confirmed');
  ok(legacy.get('ROOKIE').confirmed === false,
    'and one with no results yet is read as provisional -- the same leniency ' +
    'a fresh claim gets');
  ok(legacy.claim('VETERAN', null, mintToken()) === 'impostor',
    'so the veteran cannot be reclaimed');
  ok(legacy.claim('ROOKIE', null, mintToken()) === 'claimed',
    'but the rookie can be -- nothing has scored under that name yet');
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

/*
 * The reclaim rule again, but through the relay and the wire fields a
 * client actually reads -- welcome.ranked, welcome.rankToken -- and with
 * the persistence hook wired up, so the reclaim is pinned as a board change
 * the hub must be told about, not only as a Board return value.
 */
function testReclaimOverTheWire() {
  const clock = makeClock();
  const seen = [];
  const relay = new Relay({
    maxPlayers: 8, log: quiet, now: clock.now,
    onRankChange: (settled) => seen.push(settled),
  });

  const dial = (name, token) => {
    const peer = { outbox: [], remoteAddress: '127.0.0.1' };
    peer.send = (msg) => peer.outbox.push(msg);
    peer.close = () => {};
    const id = relay.accept(peer);
    relay.handle(id, { type: 'mmo.hello', proto: PROTOCOL, name, rankToken: token });
    const welcome = peer.outbox.find((m) => m.type === 'mmo.welcome');
    return { id, peer, welcome };
  };

  const first = dial('DELTA');
  const oldTicket = first.welcome.rankToken;
  ok(cleanToken(oldTicket) !== null, 'a first visit mints a claim');
  ok(seen.length === 0,
    'and nothing is flushed for it: an unproved claim is a row export() ' +
    'drops, so the write would rewrite the file to what it already says');
  relay.drop(first.id);

  // The player is back without the ticket -- a save that never carried it,
  // say -- before ever proving it or playing a scored battle.
  const back = dial('DELTA');
  ok(back.welcome.ranked === true,
    'an unconfirmed, unscored name follows the player who is here now');
  const newTicket = back.welcome.rankToken;
  ok(cleanToken(newTicket) !== null, 'a fresh ticket goes out with the reclaim');
  ok(newTicket !== oldTicket, 'and it is not the one that got lost');
  ok(seen.length === 0, 'a transfer is not flushed either, for the same reason');
  relay.drop(back.id);

  // Prove the fresh ticket, which is the moment the claim stops moving --
  // and the moment it becomes a row the file keeps, so this is the one that
  // is flushed.
  const proving = dial('DELTA', newTicket);
  ok(proving.welcome.ranked === true, 'the new ticket is recognised');
  ok(seen.length === 1 && seen[0] === null,
    'being proved for the first time tells the persistence hook, with no ' +
    'match behind it');
  relay.drop(proving.id);

  const provenAgain = dial('DELTA', newTicket);
  ok(seen.length === 1,
    'and an owner returning to a claim that was already proved changes ' +
    'nothing, so it writes nothing');
  relay.drop(provenAgain.id);

  const withOld = dial('DELTA', oldTicket);
  ok(withOld.welcome.ranked === false,
    'the ticket that got lost is worthless once the claim has moved on and ' +
    'been proved');
  ok(withOld.welcome.rankToken === undefined,
    'no ticket is handed to somebody presenting a stale one');
  relay.drop(withOld.id);

  const withNew = dial('DELTA', newTicket);
  ok(withNew.welcome.ranked === true, 'the proven ticket is the one that answers now');
  ok(withNew.welcome.rankToken === undefined,
    'and a confirmed owner is not re-sent a ticket they already hold');
}

/*
 * The impostor gate the board cannot see for itself, through the relay that
 * computes it: a second player typing a name somebody is connected and ranked
 * under does not take the claim. Reachable by accident -- two copies that
 * never changed the default trainer name -- and permanent if it went through,
 * because the first player's next settled win would confirm the taker's claim.
 */
function testLiveHolderOverTheWire() {
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

  const holder = dial('ECHO');
  ok(holder.welcome.ranked === true, 'the first ECHO is ranked');
  const held = relay.claimHash('ECHO');
  ok(held !== null, 'and holds an unproved claim on the name');

  const second = dial('ECHO');
  ok(second.welcome.ranked === false,
    'a second ECHO arriving while the first is still here is not scored');
  ok(second.welcome.rankToken === undefined, 'and is handed no ticket');
  ok(relay.claimHash('ECHO') === held, 'the claim did not move');
  ok(relay.get(holder.id).ranked === true, 'and the holder is still ranked');
  relay.drop(second.id);

  // The lockout this branch exists to fix is the *disconnected* owner, and it
  // still works: same tokenless hello, once the holder is gone.
  relay.drop(holder.id);
  const later = dial('ECHO');
  ok(later.welcome.ranked === true,
    'with the holder gone, an unproved, unscored claim follows whoever is here');
  ok(cleanToken(later.welcome.rankToken) !== null, 'and a fresh ticket goes out');
  ok(relay.claimHash('ECHO') !== held, 'the claim moved this time');
}

/*
 * A battle is scored into the claims it started against, or not at all. A
 * claim that moved in between belongs to somebody else now, and record()
 * would confirm it into permanence on the way past.
 */
function testClaimMovedMidMatch() {
  const clock = makeClock();
  const relay = new Relay({ maxPlayers: 8, log: quiet, now: clock.now });

  const dial = (name, token) => {
    const peer = { outbox: [], remoteAddress: '127.0.0.1' };
    peer.send = (msg) => peer.outbox.push(msg);
    peer.close = () => {};
    const id = relay.accept(peer);
    relay.handle(id, { type: 'mmo.hello', proto: PROTOCOL, name, rankToken: token });
    return { id, peer };
  };

  // The control: the same battle, nobody's claim touched, settles normally.
  const control = dial('CONTROL');
  const sparring = dial('SPARRING');
  const first = fight(relay, control, sparring);
  relay.handle(control.id, { type: 'mmo.result', session: first, outcome: 'win' });
  relay.handle(sparring.id, { type: 'mmo.result', session: first, outcome: 'loss' });
  ok(relay.board.points('CONTROL') === 16, 'sanity: an untouched match scores');

  const nova = dial('NOVA');
  const vega = dial('VEGA');
  const matchId = fight(relay, nova, vega);
  const startedWith = relay.claimHash('NOVA');

  // NOVA reports and leaves -- the paperwork outlives the session by design --
  // and with nobody connected under the name, its unproved claim is up for
  // grabs again.
  relay.handle(nova.id, { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.drop(nova.id);
  const taker = dial('NOVA');
  ok(relay.claimHash('NOVA') !== startedWith, 'sanity: the claim moved');

  relay.handle(vega.id, { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(relay.board.points('NOVA') === 0,
    'the settlement is dropped: those points would have landed on a claim ' +
    'the winner does not hold');
  ok(relay.board.points('VEGA') === 0, 'and the loser pays nothing for it');
  ok(relay.board.get('NOVA').confirmed === false,
    'nor is the new claim confirmed by somebody else\'s battle');
  ok(relay.get(taker.id).ranked === true, 'sanity: the taker is a normal player');
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
  // Two fresh hellos, two fresh claims -- and neither is flushed. Both leave a
  // row export() drops on purpose, so the file would be rewritten to exactly
  // what it already holds, once per hello, on a hub anybody can dial in a
  // loop.
  ok(seen.length === 0, 'a fresh claim is not a change the file can hold');

  // Kept before the fight, which clears the outboxes it works in.
  const ticket = players[0].peer.outbox
    .find((m) => m.type === 'mmo.welcome').rankToken;

  const matchId = fight(relay, players[0], players[1]);
  relay.handle(players[0].id,
    { type: 'mmo.result', session: matchId, outcome: 'win' });
  relay.handle(players[1].id,
    { type: 'mmo.result', session: matchId, outcome: 'loss' });
  ok(seen.length === 1, 'a settled match does tell the caller');
  ok(seen[0].winner.name === 'A', 'naming who won');

  // A ticket proved for the first time is the other way a row starts being
  // written -- but this name was already confirmed by its own battle, so
  // returning with the ticket changes nothing and writes nothing. (Claim-time
  // changes carry no match, which is how a caller tells "a name was claimed"
  // from "a name was settled" apart; testReclaimOverTheWire pins the flush
  // itself.)
  relay.drop(players[0].id);
  const peer = { outbox: [], remoteAddress: '127.0.0.1' };
  peer.send = (msg) => peer.outbox.push(msg);
  peer.close = () => {};
  const backId = relay.accept(peer);
  relay.handle(backId,
    { type: 'mmo.hello', proto: PROTOCOL, name: 'A', rankToken: ticket });
  ok(seen.length === 1, 'so the hook has still been called exactly once');

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
  testFreshClaimIsUnconfirmed();
  testLiveHolderBlocksReclaim();
  testPointsWithoutGamesBlockReclaim();
  testOwnerReturnConfirmsAndBlocksReclaim();
  testUnconfirmedUnscoredReclaims();
  testScoredNameNeverReclaimed();
  testSettlementConfirmsBothSides();
  testConfirmedRoundTrips();
  testThrowawayClaimsAreNotExported();
  testLegacyImportInfersConfirmed();
  testLiveHolderOverTheWire();
  testClaimMovedMidMatch();
  testFarmingIsWorthless();
  testLeaderboard();
  testResultsNeedTwoVoices();
  testLiesScoreNothing();
  testReportWindow();
  testLeaderboardOverTheWire();
  testRatingBelongsToTheName();
  testClaimsOverTheWire();
  testReclaimOverTheWire();
  testPersistenceHook();

  console.log(`\n  ${passed}/${passed} checks passed  (rank)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + ((err && err.stack) || err) + '\n');
  process.exit(1);
}
