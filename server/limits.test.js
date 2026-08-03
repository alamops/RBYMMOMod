#!/usr/bin/env node
'use strict';

/*
 * Unit tests for `lib/limits.js`, the module that decides whether the hub
 * survives contact with the open internet.
 *
 * Everything here is socket-free and timer-free by construction: `Limits`
 * takes an injected clock, so every scenario below drives time by hand
 * through a plain variable and a `now: () => clock` closure. No `setTimeout`,
 * no real sleep, no port opened.
 *
 * Idiom matches `hub.test.js`: a bespoke, dependency-free runner with a
 * throwing `ok(cond, label)`, scenario functions, and a final pass count.
 * No test framework, no dependencies -- this both runs directly
 * (`node server/limits.test.js`) and is discovered by `node --test`
 * (`server/package.json`'s `test` script), which just executes the file as
 * a script and treats an uncaught throw / non-zero exit as the failure
 * signal.
 *
 * Run: node server/limits.test.js
 */

const assert = require('assert');
const {
  Limits, normalizeIp, ipCountKey, DEFAULTS, BOUNDS,
} = require('./lib/limits.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

// A clock the test drives by hand. `tick()` advances it; `now` is what gets
// injected into `new Limits({ now })`.
function makeClock(start = 0) {
  let t = start;
  return {
    now: () => t,
    set(value) { t = value; },
    advance(ms) { t += ms; },
  };
}

function freshLimits(overrides, clock) {
  return new Limits(Object.assign({ now: clock.now }, overrides));
}

// -------------------------------------------------------------- normalizeIp

function testNormalizeIp() {
  // Dual-stack spellings fold to the same key.
  ok(normalizeIp('::ffff:203.0.113.7') === '203.0.113.7',
    'IPv4-mapped IPv6 folds to the bare dotted quad');
  ok(normalizeIp('203.0.113.7') === '203.0.113.7',
    'a bare dotted quad passes through unchanged');
  ok(normalizeIp('::ffff:203.0.113.7') === normalizeIp('203.0.113.7'),
    'both spellings produce the identical key');

  // The hex-mapped spelling some stacks emit.
  ok(normalizeIp('::ffff:cb00:7107') === '203.0.113.7',
    'the hex-mapped IPv4-in-IPv6 form decodes to the same dotted quad');

  // The deprecated IPv4-compatible form.
  ok(normalizeIp('::203.0.113.7') === '203.0.113.7',
    'the deprecated ::a.b.c.d compatible form folds too');

  // Bracketed forms.
  ok(normalizeIp('[203.0.113.7]') === '203.0.113.7',
    'a bracketed IPv4 address is unwrapped');
  ok(normalizeIp('[::ffff:203.0.113.7]') === '203.0.113.7',
    'a bracketed mapped IPv6 address is unwrapped and folded');

  // Zone index stripped.
  ok(normalizeIp('fe80::1%en0') === 'fe80::1',
    'a %zone suffix is stripped');
  ok(normalizeIp('[fe80::1%en0]') === 'fe80::1',
    'a %zone suffix inside brackets is stripped too');

  // Case-insensitivity.
  ok(normalizeIp('FE80::1') === 'fe80::1', 'IPv6 is lowercased for comparison');

  // Plain IPv6, unmapped. Lowercased -- and canonicalised, which for an
  // address already in RFC 5952 form is a no-op. (This assertion predates
  // canonicalisation, where its label read "unchanged shape"; the value it
  // pins is identical, but the reason it holds is now the round trip through
  // the parser rather than the absence of one. testNormalizeIpv6Canonical
  // below is where the shape is actually exercised.)
  ok(normalizeIp('2001:DB8::1') === '2001:db8::1',
    'a non-mapped IPv6 address is lowercased and left in its canonical shape');

  // Non-string / empty input.
  ok(normalizeIp(undefined) === '', 'a non-string input normalizes to empty');
  ok(normalizeIp(123) === '', 'a number input normalizes to empty');
  ok(normalizeIp('   ') === '', 'whitespace-only input normalizes to empty');
  ok(normalizeIp('') === '', 'empty string normalizes to empty');

  // ------- the consequence: a ban/count on one spelling hits the other

  const clock = makeClock();
  const limits = freshLimits({}, clock);

  limits.setBans(['::ffff:203.0.113.7']);
  ok(limits.admit('203.0.113.7').reason === 'banned',
    'a ban entered as the mapped spelling catches the bare dotted quad');
  ok(limits.admit('::ffff:203.0.113.7').reason === 'banned',
    'and catches its own spelling too, obviously');

  const limits2 = freshLimits({ perIpConnections: 100 }, clock);
  limits2.register('sock-a', '203.0.113.7');
  ok(limits2.connectionsFrom('::ffff:203.0.113.7') === 1,
    'a count taken under the bare spelling is visible under the mapped one');
  limits2.register('sock-b', '::ffff:203.0.113.7');
  ok(limits2.connectionsFrom('203.0.113.7') === 2,
    'and registrations under either spelling accumulate into one bucket');
}

// ------------------------------------------------- IPv6 canonicalisation
//
// One host, many legal spellings. Before canonicalisation these all came out
// of normalizeIp as different strings, which meant a ban typed from an
// expanded log line stored a key `socket.remoteAddress` never produces: the
// CLI printed "Banned ..." and nothing was ever banned. Each RFC 5952 rule
// is pinned separately below, and then the consequence is pinned directly.

function testNormalizeIpv6Canonical() {
  // ---- the exact spellings from the confirmed failure, folded to one key
  const spellings = [
    '2001:db8::1',
    '2001:0db8:0000:0000:0000:0000:0000:0001',
    '2001:DB8:0:0:0:0:0:1',
    '2001:0DB8::0001',
    '[2001:0db8:0000:0000:0000:0000:0000:0001]',
    '2001:0db8::1%eth0',
  ];
  for (const spelling of spellings) {
    ok(normalizeIp(spelling) === '2001:db8::1',
      `"${spelling}" canonicalises to 2001:db8::1`);
  }

  const loopbacks = ['::1', '0:0:0:0:0:0:0:1', '0000:0000:0000:0000:0000:0000:0000:0001'];
  for (const spelling of loopbacks) {
    ok(normalizeIp(spelling) === '::1', `"${spelling}" canonicalises to ::1`);
  }

  // ---- rule: leading zeros in a group are dropped
  ok(normalizeIp('2001:0db8:0001:0002:0003:0004:0005:0006') ===
      '2001:db8:1:2:3:4:5:6',
    'leading zeros are suppressed in every group');
  ok(normalizeIp('0001:0002:0003:0004:0005:0006:0007:0008') ===
      '1:2:3:4:5:6:7:8',
    'a group of all zeros but one digit collapses to that digit, not to empty');

  // ---- rule: hex is lowercase
  ok(normalizeIp('2001:DB8:ABCD:EF01::FE') === '2001:db8:abcd:ef01::fe',
    'hex digits are lowercased');

  // ---- rule: the LONGEST run of zero groups is the one compressed
  ok(normalizeIp('1:0:0:1:0:0:0:1') === '1:0:0:1::1',
    'the longer zero run is compressed and the shorter one is written out');
  ok(normalizeIp('1:0:0:0:1:0:0:1') === '1::1:0:0:1',
    'and that holds when the longest run comes first');

  // ---- rule: on a tie, the LEFTMOST run wins
  ok(normalizeIp('2001:db8:0:0:1:0:0:1') === '2001:db8::1:0:0:1',
    'two zero runs of equal length: the leftmost is the one compressed');
  ok(normalizeIp('1:0:0:2:0:0:3:4') === '1::2:0:0:3:4',
    'leftmost-on-tie again, with the runs in the middle of the address');

  // ---- rule: a single zero group is NEVER compressed
  ok(normalizeIp('2001:db8:0:1:1:1:1:1') === '2001:db8:0:1:1:1:1:1',
    'a lone zero group is written as 0, not compressed to ::');
  ok(normalizeIp('1:2:3:4:5:6:0:8') === '1:2:3:4:5:6:0:8',
    'a lone trailing zero group is not compressed either');
  ok(normalizeIp('1:2:3:0:0:6:7:8') === '1:2:3::6:7:8',
    'but a run of two is: the "never compress one" rule stops at one');

  // ---- the all-zeros address, and a run that reaches an edge
  ok(normalizeIp('0:0:0:0:0:0:0:0') === '::',
    'the unspecified address canonicalises to ::');
  ok(normalizeIp('1:2:3:4:5:6:7:0') === '1:2:3:4:5:6:7:0',
    'one trailing zero stays spelled out');
  ok(normalizeIp('1:2:3:4:5:6:0:0') === '1:2:3:4:5:6::',
    'a trailing run of two compresses to a trailing ::');
  ok(normalizeIp('0:0:1:2:3:4:5:6') === '::1:2:3:4:5:6',
    'a leading run compresses to a leading ::');

  // ---- idempotence: canonical in, canonical out
  for (const addr of ['2001:db8::1', '::1', '::', '1:0:0:1::1', 'fe80::1']) {
    ok(normalizeIp(normalizeIp(addr)) === normalizeIp(addr),
      `normalizing "${addr}" twice is the same as normalizing it once`);
  }

  // ---- expanded spellings of the IPv4-mapped forms fold too, now that the
  // decision is made on the parsed groups rather than on a text prefix
  ok(normalizeIp('0:0:0:0:0:ffff:cb00:7107') === '203.0.113.7',
    'a fully expanded IPv4-mapped address still folds to the dotted quad');
  ok(normalizeIp('0000:0000:0000:0000:0000:ffff:203.0.113.7') === '203.0.113.7',
    'expanded, with a dotted tail, folds too');

  // ---- ::1 must NOT be mistaken for the deprecated ::0.0.0.1
  ok(normalizeIp('::1') === '::1',
    'the IPv6 loopback stays IPv6 and is never folded to 0.0.0.1');
  ok(normalizeIp('::') === '::',
    'the unspecified address is not folded to 0.0.0.0 either');
}

// ------------------------------------------------- hostile / malformed input
//
// normalizeIp runs on the accept path, on whatever string arrives, before any
// client state exists. A throw here is a crash in the DoS guard itself, so
// the contract is: never throw, and hand anything unparseable back untouched
// rather than mangling it into a key that might collide with a real address.

function testNormalizeIpMalformed() {
  const hostile = [
    ':::',
    '::::::::',
    '1:2:3:4:5:6:7:8:9',
    '2001:db8::1::2',
    'gggg::1',
    '2001:db8:',
    ':',
    '::ffff:999.1.1.1',
    '::999.1.1.1',
    'not an ip',
    'localhost',
    '203.0.113.7:1234',
    '[2001:db8::1',
    '[]',
    '%',
    '::%',
    ' ',
    '2001:db8::1\n2001:db8::2',
  ];
  for (const bad of hostile) {
    let threw = false;
    let out;
    try {
      out = normalizeIp(bad);
    } catch (err) {
      threw = true;
    }
    ok(!threw, `normalizeIp(${JSON.stringify(bad)}) does not throw`);
    ok(typeof out === 'string',
      `normalizeIp(${JSON.stringify(bad)}) still returns a string`);
  }

  // A long hostile string must be cheap, not a regex bomb: the parse is
  // gated on net.isIPv6, which is a linear C-level check.
  const long = '2001:db8:' + '0:'.repeat(200000) + '1';
  const started = process.hrtime.bigint();
  let longOut;
  let longThrew = false;
  try {
    longOut = normalizeIp(long);
  } catch (err) {
    longThrew = true;
  }
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  ok(!longThrew, 'a 400KB pseudo-address does not throw');
  ok(longOut === long.toLowerCase(),
    'and is handed back unchanged rather than mangled into a key');
  ok(elapsedMs < 1000,
    `and is rejected in bounded time (${elapsedMs.toFixed(1)}ms), not by backtracking`);

  // Non-strings and empties keep returning '' (also pinned in
  // testNormalizeIp; repeated here because ipCountKey shares the path).
  for (const value of [undefined, null, 123, {}, [], () => {}, Symbol.iterator]) {
    let threw = false;
    let out;
    try {
      out = normalizeIp(value);
    } catch (err) {
      threw = true;
    }
    ok(!threw && out === '',
      `normalizeIp(${String(value)}) returns '' without throwing`);

    let keyThrew = false;
    let keyOut;
    try {
      keyOut = ipCountKey(value);
    } catch (err) {
      keyThrew = true;
    }
    ok(!keyThrew && keyOut === '',
      `ipCountKey(${String(value)}) returns '' without throwing`);
  }

  // An unparseable string must never acquire a /64 suffix -- that would be a
  // key claiming to be a prefix when nothing was parsed.
  ok(ipCountKey(':::') === ':::',
    'an unparseable colon string keeps its exact value as a count key');
  ok(ipCountKey('not an ip') === 'not an ip',
    'and so does a string with no colons at all');
}

// ------------------------------------------------------------- IPv4 is intact
//
// The whole IPv6 change must be invisible to IPv4. Every dual-stack fold that
// worked before still works, and an IPv4 address is still counted per exact
// address -- an IPv4 host is one address, not a block.

function testIpv4Unchanged() {
  const pairs = [
    ['203.0.113.7', '203.0.113.7'],
    ['::ffff:203.0.113.7', '203.0.113.7'],
    ['::ffff:cb00:7107', '203.0.113.7'],
    ['::203.0.113.7', '203.0.113.7'],
    ['[203.0.113.7]', '203.0.113.7'],
    ['[::ffff:203.0.113.7]', '203.0.113.7'],
    ['::FFFF:203.0.113.7', '203.0.113.7'],
    ['  203.0.113.7  ', '203.0.113.7'],
    ['127.0.0.1', '127.0.0.1'],
    ['::ffff:127.0.0.1', '127.0.0.1'],
    ['0.0.0.0', '0.0.0.0'],
    ['255.255.255.255', '255.255.255.255'],
    ['::ffff:255.255.255.255', '255.255.255.255'],
    ['1.2.3.4', '1.2.3.4'],
  ];
  for (const [input, expected] of pairs) {
    ok(normalizeIp(input) === expected,
      `IPv4 behaviour is unchanged: "${input}" -> ${expected}`);
    ok(ipCountKey(input) === expected,
      `and its count key is the exact address, not a prefix: "${input}"`);
  }

  // The per-IP cap for IPv4 is still per exact address: neighbours in the
  // same /24 (or any block) do not share a budget.
  const clock = makeClock();
  const limits = freshLimits(
    { perIpConnections: 1, connectBurst: 100, maxPending: 100 }, clock);
  limits.register('a', '203.0.113.7');
  ok(limits.admit('203.0.113.7').reason === 'per_ip',
    'an IPv4 address at its cap is refused');
  ok(limits.admit('203.0.113.8').ok,
    'and the address next to it is completely unaffected');
}

// -------------------------------------------------- the point: bans that fire
//
// The reason canonicalisation matters at all. A host bans the address their
// log showed them; the peer connects and the kernel reports a different
// spelling of the same address. Before the fix these were different keys.

function testBanAcrossSpellings() {
  const clock = makeClock();

  {
    const limits = freshLimits({}, clock);
    limits.setBans(['2001:0db8:0000:0000:0000:0000:0000:0001']);
    ok(limits.admit('2001:db8::1').reason === 'banned',
      'a ban stored from an expanded log line fires against the compressed ' +
      'spelling the kernel actually reports');
  }

  {
    const limits = freshLimits({}, clock);
    limits.setBans(['2001:db8::1']);
    for (const spelling of [
      '2001:0db8:0000:0000:0000:0000:0000:0001',
      '2001:DB8:0:0:0:0:0:1',
      '[2001:db8::1]',
      '2001:db8::1%eth0',
      '2001:0DB8::0001',
    ]) {
      ok(limits.admit(spelling).reason === 'banned',
        `a ban on 2001:db8::1 catches a peer reporting "${spelling}"`);
    }
  }

  // ...and in the other direction, for the allowlist.
  {
    const limits = freshLimits({}, clock);
    limits.setAllowlist(['2001:0db8:0000:0000:0000:0000:0000:0001']);
    ok(limits.admit('2001:db8::1').ok,
      'an allowlist entry typed in expanded form still admits the peer');
  }
}

// ------------------------------------------- bans stay exact; the cap does not
//
// This is the deliberate split, pinned so a later reader cannot mistake it
// for an oversight:
//
//   * bans and the allowlist match ONE address. A host banning a griefer must
//     not silently ban every other customer of that ISP -- an IPv6 /64 is a
//     whole household and a /48 a whole subscriber, and the config file gives
//     no hint that a single-address entry had been widened.
//   * `perIpConnections` counts per /64, because a /128 cap is not a cap: a
//     client with an ordinary residential /64 has 2^64 source addresses to
//     rotate through and would never trip it.
//
// Different keys for different jobs, on purpose.

function testBansStayExact() {
  const clock = makeClock();

  {
    const limits = freshLimits({}, clock);
    limits.setBans(['2001:db8:1:2::5']);
    ok(limits.admit('2001:db8:1:2::5').reason === 'banned',
      'the banned address itself is refused');
    ok(limits.admit('2001:db8:1:2::6').ok,
      'a DIFFERENT address in the same /64 is NOT banned -- bans are exact, ' +
      'so banning one peer never bans their whole household or ISP block');
    ok(limits.admit('2001:db8:1:3::5').ok,
      'and neither is the neighbouring /64, obviously');
  }

  {
    const limits = freshLimits({}, clock);
    limits.setAllowlist(['2001:db8:1:2::5']);
    ok(limits.admit('2001:db8:1:2::5').ok, 'the allow-listed address is admitted');
    ok(limits.admit('2001:db8:1:2::6').reason === 'not_allowed',
      'an address sharing its /64 is NOT allow-listed -- the allowlist is ' +
      'exact too, so one entry never opens a whole block');
  }

  // The same two addresses that bans keep apart share one connection budget.
  {
    const limits = freshLimits(
      { perIpConnections: 1, connectBurst: 100, maxPending: 100 }, clock);
    limits.register('k', '2001:db8:1:2::5');
    ok(limits.admit('2001:db8:1:2::6').reason === 'per_ip',
      'the cap, unlike the ban, DOES span the /64: the same pair of addresses ' +
      'that bans treat as two peers count as one household here');
  }
}

// ------------------------------------------------------- /64 connection cap

function testIpv6PrefixCap() {
  const clock = makeClock();

  // ---- the export exists and says what it counts
  ok(typeof ipCountKey === 'function', 'ipCountKey is exported');
  ok(ipCountKey('2001:db8:1:2:3:4:5:6') === '2001:db8:1:2::/64',
    'the count key for an IPv6 address is its /64 prefix');
  ok(ipCountKey('2001:0DB8:0001:0002::abcd') === '2001:db8:1:2::/64',
    'and it is derived from the canonical form, so every spelling agrees');
  ok(ipCountKey('2001:db8:1:2::') === '2001:db8:1:2::/64',
    'the first address of a block is counted under that block like any other');
  ok(ipCountKey('2001:db8:1:2::') !== normalizeIp('2001:db8:1:2::'),
    'the /64 suffix keeps a prefix key from ever colliding with the exact ' +
    'address that starts the block -- the two maps can never be confused');
  ok(ipCountKey('::1') === '::/64',
    'the loopback is counted under ::/64 (it has a /64 like anything else)');

  // ---- two different addresses inside one /64 share the budget
  {
    const limits = freshLimits(
      { perIpConnections: 2, connectBurst: 100, maxPending: 100 }, clock);
    ok(limits.admit('2001:db8:1:2::1').ok, 'first address in the /64 is admitted');
    limits.register('k1', '2001:db8:1:2::1');
    ok(limits.admit('2001:db8:1:2::2').ok,
      'a second, different address in the same /64 is admitted (cap is 2)');
    limits.register('k2', '2001:db8:1:2::2');

    const third = limits.admit('2001:db8:1:2::dead:beef');
    ok(third.ok === false && third.reason === 'per_ip',
      'a third address in that /64 is refused as per_ip: rotating the low 64 ' +
      'bits does not buy a fresh budget');

    ok(limits.connectionsFrom('2001:db8:1:2::1') === 2,
      'connectionsFrom reports the whole /64 count, whichever member is asked');
    ok(limits.connectionsFrom('2001:db8:1:2::ffff') === 2,
      'including for an address in the block that has never connected');

    // ---- and a different /64 does not share it
    ok(limits.admit('2001:db8:1:3::1').ok,
      'an address in a neighbouring /64 has its own budget');
    ok(limits.admit('2001:db8:1:2:8000::1').ok === false,
      'while a bit flipped BELOW the /64 boundary is still the same household');

    // release frees the shared slot
    ok(limits.release('k1') === true, 'releasing one member of the /64 succeeds');
    ok(limits.connectionsFrom('2001:db8:1:2::2') === 1,
      'and the shared count drops by exactly one');
    ok(limits.admit('2001:db8:1:2::3').ok,
      'freeing a slot lets another address in the same /64 in');
  }

  // ---- stats() reports the key it counted under
  {
    const statsLimits = freshLimits({ perIpConnections: 10 }, clock);
    statsLimits.register('s1', '2001:db8:1:2::1');
    statsLimits.register('s2', '2001:db8:1:2::2');
    statsLimits.register('s3', '203.0.113.7');
    const snapshot = statsLimits.stats();
    ok(snapshot.perIp['2001:db8:1:2::/64'] === 2,
      'stats().perIp reports the /64 for IPv6, with both members counted');
    ok(snapshot.perIp['203.0.113.7'] === 1,
      'and the exact address for IPv4');
    ok(snapshot.connections === 3, 'and the raw connection total is unaffected');
  }

  // ---- the rate bucket is keyed the same way, for the same reason: a
  // per-/128 bucket would let one client mint a fresh burst per connection
  // (and churn the hub's bucket map while doing it).
  {
    const clock2 = makeClock(0);
    const limits = freshLimits(
      { connectBurst: 2, connectPerMinute: 60, perIpConnections: 1000, maxPending: 1000 },
      clock2);
    ok(limits.admit('2001:db8:9:9::1').ok, 'burst 1 of 2, from one address');
    ok(limits.admit('2001:db8:9:9::2').ok, 'burst 2 of 2, from a different one');
    ok(limits.admit('2001:db8:9:9::3').reason === 'rate',
      'a third address in the same /64 is rate-limited: rotating addresses ' +
      'does not mint a fresh token bucket');
    ok(limits.admit('2001:db8:9:a::1').ok,
      'while a genuinely different /64 still gets its own full burst');
  }
}

// -------------------------------------------------------------- per-IP cap

function testPerIpCap() {
  const clock = makeClock();
  const limits = freshLimits(
    { perIpConnections: 2, connectBurst: 100, maxPending: 100 }, clock);

  ok(limits.admit('1.1.1.1').ok, 'first connection from an address is admitted');
  limits.register('k1', '1.1.1.1');
  ok(limits.admit('1.1.1.1').ok, 'second connection from the same address is admitted');
  limits.register('k2', '1.1.1.1');

  const third = limits.admit('1.1.1.1');
  ok(third.ok === false && third.reason === 'per_ip',
    'a third connection from the same address is refused as per_ip');

  // a different address does not share the budget
  const other = limits.admit('2.2.2.2');
  ok(other.ok, 'a different address is unaffected by the first one being at cap');

  // release frees a slot
  ok(limits.release('k1') === true, 'release reports success for a live key');
  const fourth = limits.admit('1.1.1.1');
  ok(fourth.ok, 'freeing a slot lets the next connection from that address in');
}

// -------------------------------------------------------------- token bucket

function testTokenBucket() {
  const clock = makeClock();
  const limits = freshLimits(
    { connectBurst: 3, connectPerMinute: 60, perIpConnections: 1000, maxPending: 1000 },
    clock);

  ok(limits.admit('9.9.9.1').ok, 'burst admission 1 of 3 succeeds immediately');
  ok(limits.admit('9.9.9.1').ok, 'burst admission 2 of 3 succeeds immediately');
  ok(limits.admit('9.9.9.1').ok, 'burst admission 3 of 3 succeeds immediately');
  const fourth = limits.admit('9.9.9.1');
  ok(fourth.ok === false && fourth.reason === 'rate',
    'the next admission beyond the burst is refused as rate');

  // connectPerMinute: 60 => exactly one token refills per second
  clock.advance(500);
  ok(limits.admit('9.9.9.1').reason === 'rate',
    'half a second is not enough time to refill one token');
  clock.advance(500); // now a full second since the last spend
  ok(limits.admit('9.9.9.1').ok, 'a full second refills exactly one token');
  ok(limits.admit('9.9.9.1').reason === 'rate',
    'and only one token was refilled, not more');

  // the bucket never exceeds capacity, however long you wait
  clock.advance(3600000); // one hour of accumulated "tokens" if unbounded
  let admitted = 0;
  for (let i = 0; i < 10; i++) {
    if (limits.admit('9.9.9.1').ok) admitted++;
  }
  ok(admitted === 3,
    'after an hour of idle refill, only connectBurst (3) admissions succeed');
  ok(limits.admit('9.9.9.1').reason === 'rate',
    'the one after that is refused: the bucket capped out at capacity');

  // ------- a rejected connection still costs a token
  //
  // Construct a case where the *rate* check would pass but the connection is
  // ultimately refused for a different reason (per_ip). The rate bucket must
  // still be charged on that call, or an attacker already pinned at their
  // per-IP cap gets unlimited free retries.
  const clock2 = makeClock();
  const gate = freshLimits(
    { perIpConnections: 1, connectBurst: 3, connectPerMinute: 60, maxPending: 100 },
    clock2);

  const first = gate.admit('9.9.9.2');
  ok(first.ok, 'first admission for the pinned address succeeds (spends token 1/3)');
  gate.register('pinned', '9.9.9.2'); // now at the per-ip cap

  const second = gate.admit('9.9.9.2');
  ok(second.reason === 'per_ip',
    'over the per-ip cap: refused as per_ip, not rate (spends token 2/3)');
  const third = gate.admit('9.9.9.2');
  ok(third.reason === 'per_ip',
    'still per_ip (spends token 3/3, exhausting the burst)');

  // no time has passed, so if those two per_ip rejections had not spent a
  // token, the bucket would still show 1 token left and this would also be
  // 'per_ip'. Getting 'rate' here proves they did spend one each.
  const fourthGate = gate.admit('9.9.9.2');
  ok(fourthGate.reason === 'rate',
    'once the burst is exhausted by rejected attempts too, the verdict flips to rate');
}

// -------------------------------------------------------------- admit order

function testAdmitOrdering() {
  const clock = makeClock();

  // banned beats everything, including an explicit allowlist entry
  {
    const limits = freshLimits(
      { perIpConnections: 1, connectBurst: 1, maxPending: 1 }, clock);
    limits.setAllowlist(['6.6.6.6']);
    limits.setBans(['6.6.6.6']);
    const verdict = limits.admit('6.6.6.6');
    ok(verdict.ok === false && verdict.reason === 'banned',
      'a ban on an allow-listed address still wins: banned beats not_allowed');
  }

  // not_allowed, on its own, with nothing else in play
  {
    const limits = freshLimits({}, clock);
    limits.setAllowlist(['7.7.7.7']);
    const verdict = limits.admit('8.8.8.8');
    ok(verdict.ok === false && verdict.reason === 'not_allowed',
      'an address outside a non-empty allowlist is refused as not_allowed');
  }

  // rate beats per_ip: exhaust the bucket, and the still-open per_ip slot
  // must not be reached
  {
    const limits = freshLimits(
      { perIpConnections: 100, connectBurst: 1, maxPending: 100 }, clock);
    ok(limits.admit('9.1.1.1').ok, 'spend the single token');
    const verdict = limits.admit('9.1.1.1');
    ok(verdict.reason === 'rate',
      'with tokens exhausted and the per_ip slot still free, rate wins');
  }

  // per_ip beats pending: the same address is over its own cap while the
  // global pending pool is also full
  {
    const limits = freshLimits(
      { perIpConnections: 1, connectBurst: 100, maxPending: 1 }, clock);
    ok(limits.admit('9.2.2.2').ok, 'first admission for A succeeds');
    limits.register('a', '9.2.2.2'); // perIp[A] = 1 (at cap), pending = 1 (at cap)
    const verdict = limits.admit('9.2.2.2');
    ok(verdict.reason === 'per_ip',
      'over its own per-ip cap and over the global pending cap: per_ip wins');
  }

  // pure pending: a *different* address, under its own per-ip cap, refused
  // only because the global pending pool is full
  {
    const limits = freshLimits(
      { perIpConnections: 100, connectBurst: 100, maxPending: 1 }, clock);
    ok(limits.admit('9.3.3.3').ok, 'A is admitted and fills the one pending slot');
    limits.register('a', '9.3.3.3');
    const verdict = limits.admit('9.4.4.4');
    ok(verdict.reason === 'pending',
      'B, unrelated to A, is refused as pending once the global pool is full');
  }
}

// ------------------------------------------------------------------- allow

function testAllowlist() {
  const clock = makeClock();

  const empty = freshLimits({}, clock);
  ok(empty.admit('1.2.3.4').ok, 'an empty allowlist means everyone is allowed');
  ok(empty.admit('99.99.99.99').ok, 'including an address nobody configured');

  const restricted = freshLimits({}, clock);
  restricted.setAllowlist(['1.2.3.4']);
  ok(restricted.admit('1.2.3.4').ok, 'a listed address is allowed');
  ok(restricted.admit('5.6.7.8').reason === 'not_allowed',
    'an unlisted address is refused');

  // allowlist entries are normalized the same way ban/perIp keys are
  const normalized = freshLimits({}, clock);
  normalized.setAllowlist(['::ffff:1.2.3.4']);
  ok(normalized.admit('1.2.3.4').ok,
    'an allowlist entered as the mapped spelling still matches the bare one');
}

// ------------------------------------------------------------- maxPending

function testMaxPending() {
  const clock = makeClock();
  const limits = freshLimits(
    { maxPending: 2, perIpConnections: 100, connectBurst: 100 }, clock);

  ok(limits.admit('a').ok, 'first pending slot admitted');
  limits.register('ka', 'a');
  ok(limits.pendingCount === 1, 'pendingCount reflects the one registration');

  ok(limits.admit('b').ok, 'second pending slot admitted');
  limits.register('kb', 'b');
  ok(limits.pendingCount === 2, 'pendingCount reflects both');

  const third = limits.admit('c');
  ok(third.reason === 'pending', 'a third ungreeted registration is capped');

  ok(limits.markGreeted('ka') === true, 'markGreeted succeeds for a pending key');
  ok(limits.pendingCount === 1, 'markGreeted frees one pending slot');

  ok(limits.admit('c').ok, 'the freed slot lets the next registration in');
  ok(limits.markGreeted('ka') === false,
    'markGreeted on an already-greeted key is a no-op (returns false)');
  ok(limits.pendingCount === 1, 'and does not free a slot twice');
}

// ------------------------------------------------------------------- sweep

function testSweep() {
  // ---- handshake timeout: fires strictly after the budget, not at it
  {
    const clock = makeClock(0);
    const limits = freshLimits({ handshakeTimeoutMs: 1000 }, clock);
    limits.register('k', '1.1.1.1');

    clock.set(1000); // exactly at the budget
    ok(limits.sweep().length === 0,
      'handshake_timeout does not fire at exactly the budget');

    clock.set(1001); // one tick past
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'handshake_timeout',
      'handshake_timeout fires one tick after the budget');

    // sweep reports, it does not release
    ok(limits.connectionsFrom('1.1.1.1') === 1,
      'sweep does not release the connection it reports');
    ok(limits.pendingCount === 1, 'the pending slot is still held after sweep');
    limits.release('k');
    ok(limits.connectionsFrom('1.1.1.1') === 0,
      'the caller releasing it afterward is what actually frees the slot');
  }

  // ---- idle timeout: same boundary discipline, for a greeted connection
  {
    const clock = makeClock(0);
    const limits = freshLimits({ idleTimeoutMs: 5000 }, clock);
    limits.register('k', '2.2.2.2');
    limits.markGreeted('k'); // lastActivity = 0

    clock.set(5000);
    ok(limits.sweep().length === 0, 'idle_timeout does not fire at exactly the budget');
    clock.set(5001);
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'idle_timeout',
      'idle_timeout fires one tick after the budget');
  }

  // ---- a greeted, active connection is never swept
  {
    const clock = makeClock(0);
    const limits = freshLimits(
      { idleTimeoutMs: 5000, handshakeTimeoutMs: 1000 }, clock);
    limits.register('k', '3.3.3.3');
    limits.markGreeted('k');

    for (let i = 0; i < 10; i++) {
      clock.advance(4000); // always well under the 5000ms idle budget
      limits.noteActivity('k', { completedLine: true });
      ok(limits.sweep().length === 0,
        'a connection kept active never gets swept, however long it runs');
    }
  }

  // ---- an ungreeted connection is judged only on the handshake budget,
  // never on the slowloris partial-line clock -- even if it has one
  {
    const clock = makeClock(0);
    const limits = freshLimits(
      { handshakeTimeoutMs: 5000, partialLineTimeoutMs: 1000 }, clock);
    limits.register('k', '4.4.4.4');
    clock.set(500);
    limits.noteActivity('k', { bytes: 3 }); // starts a partial-line clock

    clock.set(2000); // past partialLineTimeoutMs, well under handshakeTimeoutMs
    ok(limits.sweep().length === 0,
      'an ungreeted connection is not swept as slowloris no matter its partial clock');

    clock.set(5001);
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'handshake_timeout',
      'once ungreeted for too long, it is reported as handshake_timeout, not slowloris');
  }

  // ---- precedence: when a stalled partial line and idleness are both true
  // at once, slowloris is reported, not idle_timeout
  {
    const clock = makeClock(0);
    const limits = freshLimits(
      { handshakeTimeoutMs: 1000, partialLineTimeoutMs: 1000, idleTimeoutMs: 5000 },
      clock);
    limits.register('k', '5.5.5.5');
    limits.markGreeted('k');
    limits.noteActivity('k', { bytes: 1 }); // partialSince = 0, lastActivity = 0

    clock.set(5001); // both partialLineTimeoutMs and idleTimeoutMs have elapsed
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'slowloris',
      'with both conditions true, slowloris is reported, not idle_timeout');
  }

  // ---- completedLine clears the partial clock, so a completed line
  // followed by silence is judged as idle, not slowloris
  {
    const clock = makeClock(0);
    // idleTimeoutMs has a documented floor of 5000ms (BOUNDS.idleTimeoutMs),
    // so this stays at the floor rather than an arbitrary smaller number.
    const limits = freshLimits(
      { partialLineTimeoutMs: 1000, idleTimeoutMs: 5000 }, clock);
    limits.register('k', '6.6.6.6');
    limits.markGreeted('k');
    limits.noteActivity('k', { bytes: 1 }); // partialSince = 0
    clock.set(500);
    limits.noteActivity('k', { completedLine: true }); // clears partialSince, lastActivity = 500

    clock.set(5600); // past partialLineTimeoutMs from t=0, past idleTimeoutMs from t=500
    const doomed = limits.sweep();
    ok(doomed.length === 1 && doomed[0].reason === 'idle_timeout',
      'a completed line clears the partial clock, so this is judged as idle_timeout');
  }
}

// --------------------------------------------------------------- slowloris

function testSlowloris() {
  const clock = makeClock(0);
  const limits = freshLimits({ partialLineTimeoutMs: 1000 }, clock);
  limits.register('k', '7.7.7.7');
  limits.markGreeted('k');

  // bytes with no completed line start the clock
  limits.noteActivity('k', { bytes: 1 }); // partialSince = 0
  clock.set(400);
  ok(limits.sweep().length === 0, 'not yet stalled long enough');

  // dribbling more bytes does not reset the partial-line clock -- only a
  // completed line does. A connection dribbling forever is still eventually
  // swept.
  clock.set(700);
  limits.noteActivity('k', { bytes: 1 }); // still no completed line
  ok(limits.sweep().length === 0, 'still under the budget, measured from the first byte');

  clock.set(1001); // > 1000ms since partialSince (t=0), despite dribbling in between
  const doomed = limits.sweep();
  ok(doomed.length === 1 && doomed[0].reason === 'slowloris',
    'a connection dribbling bytes forever without a completed line is eventually swept');

  // a completed line clears it
  const clock2 = makeClock(0);
  const limits2 = freshLimits({ partialLineTimeoutMs: 1000 }, clock2);
  limits2.register('k2', '7.7.7.8');
  limits2.markGreeted('k2');
  limits2.noteActivity('k2', { bytes: 1 });
  clock2.set(500);
  limits2.noteActivity('k2', { completedLine: true });
  clock2.set(1600); // past the original partial budget
  ok(limits2.sweep().length === 0,
    'a completed line clears the partial clock, so slowloris no longer fires from it');
}

// ------------------------------------------------------------ writeAllowed

function testWriteAllowed() {
  const clock = makeClock();
  const limits = freshLimits({ maxWriteBufferBytes: 4096 }, clock);

  ok(limits.writeAllowed('unknown-key', 4096) === true,
    'writeAllowed does not require a registered key: true at the cap');
  ok(limits.writeAllowed('unknown-key', 4097) === false,
    'one byte over the cap is disallowed');
  ok(limits.writeAllowed('unknown-key', 0) === true, 'zero buffered is allowed');
  ok(limits.writeAllowed('unknown-key', Number.NaN) === true,
    'a non-finite writableLength (NaN) does not kill the connection');
  ok(limits.writeAllowed('unknown-key', Infinity) === true,
    'a non-finite writableLength (Infinity) does not kill the connection');
  ok(limits.writeAllowed('unknown-key', -Infinity) === true,
    'a non-finite writableLength (-Infinity) does not kill the connection');
}

// ---------------------------------------------------------------- release

function testReleaseIdempotent() {
  const clock = makeClock();
  const limits = freshLimits({ perIpConnections: 1, connectBurst: 100 }, clock);

  limits.register('k', '10.0.0.1');
  ok(limits.connectionsFrom('10.0.0.1') === 1, 'registered once, counted once');

  ok(limits.release('k') === true, 'first release reports success');
  ok(limits.connectionsFrom('10.0.0.1') === 0, 'count drops to zero');

  ok(limits.release('k') === false,
    'a second release of the same key reports failure (nothing to release)');
  ok(limits.connectionsFrom('10.0.0.1') === 0,
    'and does not drive the count negative');

  // prove it by exhausting the cap afterward: if the double release had
  // decremented twice, the count would sit at -1 and never trip per_ip.
  ok(limits.admit('10.0.0.1').ok, 'a fresh admission succeeds');
  limits.register('k2', '10.0.0.1'); // count = 1, at the cap (perIpConnections: 1)
  const second = limits.admit('10.0.0.1');
  ok(second.ok === false && second.reason === 'per_ip',
    'the per-ip cap still trips correctly -- the earlier double release left no residue');
}

// ------------------------------------------------------------- clamping

function testClamping() {
  // defaults with no options at all
  {
    const limits = new Limits();
    for (const name of Object.keys(DEFAULTS)) {
      ok(limits[name] === DEFAULTS[name],
        `${name} falls back to its documented default with no options object`);
    }
  }

  // every bound: below min clamps to min, above max clamps to max, and a
  // non-finite value falls back to the default -- per the bounds table
  // documented at the top of limits.js
  for (const name of Object.keys(BOUNDS)) {
    const [min, max] = BOUNDS[name];

    const low = new Limits({ [name]: min - 1000000 });
    ok(low[name] === min, `${name} below its floor clamps up to ${min}`);

    const high = new Limits({ [name]: max + 1000000 });
    ok(high[name] === max, `${name} above its ceiling clamps down to ${max}`);

    const nan = new Limits({ [name]: Number.NaN });
    ok(nan[name] === DEFAULTS[name], `${name} set to NaN falls back to the default`);

    const notNumber = new Limits({ [name]: 'not-a-number' });
    ok(notNumber[name] === DEFAULTS[name],
      `${name} set to a non-numeric string falls back to the default`);

    const atMin = new Limits({ [name]: min });
    ok(atMin[name] === min, `${name} exactly at its floor is accepted unchanged`);

    const atMax = new Limits({ [name]: max });
    ok(atMax[name] === max, `${name} exactly at its ceiling is accepted unchanged`);
  }

  // pins the documented table itself against silent drift
  ok(BOUNDS.perIpConnections[0] === 1 && BOUNDS.perIpConnections[1] === 256,
    'perIpConnections bounds match the documented table');
  ok(BOUNDS.connectBurst[0] === 1 && BOUNDS.connectBurst[1] === 1000,
    'connectBurst bounds match the documented table');
  ok(BOUNDS.connectPerMinute[0] === 1 && BOUNDS.connectPerMinute[1] === 60000,
    'connectPerMinute bounds match the documented table');
  ok(BOUNDS.maxPending[0] === 1 && BOUNDS.maxPending[1] === 1024,
    'maxPending bounds match the documented table');
  ok(BOUNDS.handshakeTimeoutMs[0] === 1000 && BOUNDS.handshakeTimeoutMs[1] === 300000,
    'handshakeTimeoutMs bounds match the documented table');
  ok(BOUNDS.idleTimeoutMs[0] === 5000 && BOUNDS.idleTimeoutMs[1] === 3600000,
    'idleTimeoutMs bounds match the documented table');
  ok(BOUNDS.partialLineTimeoutMs[0] === 1000 && BOUNDS.partialLineTimeoutMs[1] === 300000,
    'partialLineTimeoutMs bounds match the documented table');
  ok(BOUNDS.maxWriteBufferBytes[0] === 4096 && BOUNDS.maxWriteBufferBytes[1] === 67108864,
    'maxWriteBufferBytes bounds match the documented table');
  ok(BOUNDS.authFailureGrace[0] === 0 && BOUNDS.authFailureGrace[1] === 100,
    'authFailureGrace bounds match the documented table');
  ok(BOUNDS.authFailureWindowMs[0] === 1000 && BOUNDS.authFailureWindowMs[1] === 86400000,
    'authFailureWindowMs bounds match the documented table');
  ok(BOUNDS.authBackoffBaseMs[0] === 100 && BOUNDS.authBackoffBaseMs[1] === 3600000,
    'authBackoffBaseMs bounds match the documented table');
  ok(BOUNDS.authBackoffMaxMs[0] === 1000 && BOUNDS.authBackoffMaxMs[1] === 86400000,
    'authBackoffMaxMs bounds match the documented table');
  ok(BOUNDS.authGlobalFailures[0] === 1 && BOUNDS.authGlobalFailures[1] === 1000000,
    'authGlobalFailures bounds match the documented table');
  ok(BOUNDS.authGlobalWindowMs[0] === 1000 && BOUNDS.authGlobalWindowMs[1] === 3600000,
    'authGlobalWindowMs bounds match the documented table');
  ok(BOUNDS.authLockoutMs[0] === 1000 && BOUNDS.authLockoutMs[1] === 3600000,
    'authLockoutMs bounds match the documented table');

  // The defaults are a security posture, not an implementation detail: a
  // silent change to any of them changes how fast a 30-bit join code can be
  // guessed, so each one is pinned with the reason it holds.
  ok(DEFAULTS.authFailureGrace === 3,
    'three wrong codes are free -- a typo, a stale invite, and one more');
  ok(DEFAULTS.authFailureWindowMs === 600000,
    'one address\'s failures are remembered for ten minutes');
  ok(DEFAULTS.authBackoffBaseMs === 2000 && DEFAULTS.authBackoffMaxMs === 300000,
    'backoff runs 2s, doubling, to a five-minute ceiling');
  ok(DEFAULTS.authGlobalFailures === 100 && DEFAULTS.authGlobalWindowMs === 60000,
    'the hub-wide ceiling is 100 failures a minute -- far above honest traffic');
  ok(DEFAULTS.authLockoutMs === 60000,
    'and a trip closes authentication for one minute');
}

// --------------------------------------------------------- verdict objects

function testVerdictSingletons() {
  const clock = makeClock();
  const limits = freshLimits({ connectBurst: 1, perIpConnections: 100 }, clock);

  const okVerdict1 = limits.admit('11.0.0.1'); // spends 11.0.0.1's one-token burst
  const okVerdict2 = limits.admit('11.0.0.2'); // a different, unrelated address
  ok(okVerdict1 === okVerdict2,
    'two independent OK verdicts are the exact same frozen object by reference');
  ok(Object.isFrozen(okVerdict1), 'the OK verdict is frozen');

  // 11.0.0.1's burst (1) is already spent, so both of these read rate
  const rate1 = limits.admit('11.0.0.1');
  const rate2 = limits.admit('11.0.0.1');
  ok(rate1.reason === 'rate' && rate2.reason === 'rate',
    'repeated over-rate calls for the same exhausted bucket both read rate');
  ok(rate1 === rate2, 'and are the same frozen singleton by reference');
  ok(Object.isFrozen(rate1), 'the rate verdict is frozen');

  // sanity: a fresh, unrelated address is unaffected by 11.0.0.1's bucket
  ok(limits.admit('11.0.0.3').ok, 'an unrelated fresh address still admits cleanly');

  // frozen means an assignment attempt throws under this file's strict mode
  let threw = false;
  try {
    rate1.reason = 'tampered';
  } catch (err) {
    threw = true;
  }
  ok(threw, 'mutating a frozen verdict throws in strict mode');
}

// ------------------------------------------------------ misc documented behavior

function testRegisterTwiceAbsorbed() {
  const clock = makeClock();
  const limits = freshLimits({ perIpConnections: 1 }, clock);

  limits.register('k', '12.0.0.1');
  limits.register('k', '12.0.0.1'); // caller bug, not a security event
  ok(limits.connectionsFrom('12.0.0.1') === 1,
    'registering the same key twice charges the address only once');
  ok(limits.pendingCount === 1, 'and only counts as one pending slot');
}

function testNoteActivityUnknownKey() {
  const clock = makeClock();
  const limits = freshLimits({}, clock);
  ok(limits.noteActivity('never-registered', { bytes: 5 }) === false,
    'noteActivity on an unknown key reports failure rather than throwing');
}

function testBansAndAllowlistAcceptNonArray() {
  const clock = makeClock();
  const limits = freshLimits({}, clock);

  limits.setBans(null);
  ok(limits.admit('13.0.0.1').ok,
    'setBans(null) does not throw and leaves nobody banned');

  limits.setAllowlist(undefined);
  ok(limits.admit('13.0.0.2').ok,
    'setAllowlist(undefined) does not throw and leaves the allowlist empty (everyone)');
}

// ---------------------------------------------------- bucket pruning (white-box)
//
// This pins a specific documented internal decision -- "bucket pruning is
// interval-gated" -- by reading the internal `_buckets`/`_prunedAt` state.
// That is a deliberate exception to the black-box discipline used
// everywhere else in this file: pruning a full bucket is *designed* to be
// externally invisible (a pruned bucket behaves identically to a bucket that
// never existed, per the comment in limits.js), so there is no admit()/
// sweep()-observable consequence to assert against. The memory-bounds test
// below keeps to the black-box rule and explains why.

function testBucketPruningIntervalGated() {
  const clock = makeClock(0);
  const limits = freshLimits({ connectBurst: 10, connectPerMinute: 60 }, clock);

  limits.admit('20.0.0.1');
  const prunedAtAfterFirst = limits._prunedAt;
  ok(prunedAtAfterFirst === 0, 'the very first admit call runs an (empty) prune');

  clock.set(1000); // well within the 30s prune interval
  limits.admit('20.0.0.2');
  ok(limits._prunedAt === prunedAtAfterFirst,
    'a second admit inside the prune interval does not re-run the prune');

  clock.set(30001); // past the interval
  limits.admit('20.0.0.3');
  ok(limits._prunedAt === 30001,
    'once the interval has elapsed, the next admit runs the prune again');
}

// -------------------------------------------------------------- memory bounds
//
// The public surface of Limits -- `admit`, `register`, `release`,
// `pendingCount`, `connectionsFrom`, `stats()` -- exposes connection and
// per-IP bookkeeping, but nothing about the rate-limiter's bucket map. And
// unlike a leaked connection count, an unpruned bucket has no correctness
// consequence a caller can observe: a bucket that refilled to capacity and
// was never removed behaves *identically* to one that was removed and
// recreated fresh (a full bucket "carries no information", per the comment
// in limits.js), so admit()'s return values cannot distinguish "pruned
// correctly" from "leaking silently". There is, honestly, no black-box way
// to assert the bucket map's cardinality without reading the private
// `_buckets` field, which this test deliberately does not do (see the
// pruning test above for the one place this file makes that exception, for
// a decision that genuinely has no other observable).
//
// The closest available external proxy is operational: admitting a large,
// strictly-growing set of distinct addresses must keep working correctly
// (fresh addresses still get a full burst) and must not degrade, which is
// what a correctly bounded structure guarantees and an unbounded one (O(n)
// work per admit as the map grows without limit) would eventually fail at.
// The timing assertion below is intentionally very generous to avoid
// flakiness on a loaded machine -- it is a sanity check against
// catastrophic unbounded growth, not a precise bound on the internal map.

function testMemoryBoundsProxy() {
  const clock = makeClock(0); // frozen: no time-based refill muddies the count
  const limits = freshLimits(
    // maxPending is irrelevant here: this test never calls register(), so
    // `_pending` never moves off zero regardless of the configured cap.
    { connectBurst: 2, connectPerMinute: 60, perIpConnections: 1000 },
    clock);

  const ADDRESSES = 20000; // comfortably past the internal MAX_BUCKETS (4096)

  const ipFor = (i) =>
    `${10 + (i >>> 24 & 255)}.${i >>> 16 & 255}.${i >>> 8 & 255}.${i & 255}`;

  // Every address here is brand new, so every one of these must succeed --
  // that is true whether or not old buckets were ever pruned, which is
  // exactly why this cannot prove boundedness on its own; it proves
  // correctness survives at scale, which is the property we can observe.
  let allFresh = true;
  const start = process.hrtime.bigint();
  for (let i = 0; i < ADDRESSES; i++) {
    const verdict = limits.admit(ipFor(i));
    if (!verdict.ok) allFresh = false;
  }
  const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;

  ok(allFresh,
    `cycling ${ADDRESSES} distinct addresses through admit() never misfires ` +
    'on a fresh address, however many have come before it');

  // Generous: this would need to be off by orders of magnitude to trip on
  // any real machine. It exists only to catch a genuinely unbounded
  // structure making each successive call slower without limit.
  ok(elapsedMs < 5000,
    `admitting ${ADDRESSES} distinct addresses completes in bounded time ` +
    `(${elapsedMs.toFixed(1)}ms) rather than degrading; this is the closest ` +
    'externally observable proxy for the internal map staying bounded -- ' +
    'see the comment above this test for why a direct assertion is not possible');
}

// ------------------------------------------------- authentication failures
//
// The join code is 6 characters from a 32-symbol alphabet -- 2^30 exactly
// (lib/auth.js). Per-IP limiting alone does not bound the guess rate: it
// only prices it in rented addresses. Everything below drives the two
// throttles that do bound it, on the injected clock, with no timer anywhere.

function testAuthPerIpBackoff() {
  const clock = makeClock();
  const limits = freshLimits({
    authFailureGrace: 3,
    authBackoffBaseMs: 2000,
    authBackoffMaxMs: 300000,
    authFailureWindowMs: 600000,
    // out of the way: this test is about one address, not the ceiling
    authGlobalFailures: 1000000,
  }, clock);

  const ip = '203.0.113.10';

  ok(limits.authAllowed(ip).ok,
    'an address with no history may authenticate');

  // The grace. A friend reading the code off a phone photo gets three
  // attempts with no delay at all -- this is the "not collateral" half.
  for (let i = 1; i <= 3; i += 1) {
    ok(limits.noteAuthFailure(ip) === false,
      `wrong code ${i} of the grace does not trip the hub-wide ceiling`);
    ok(limits.authAllowed(ip).ok,
      `after ${i} wrong codes (grace 3) the address may still try immediately`);
    ok(limits.authRetryAfterMs(ip) === 0,
      `and owes no wait after ${i}`);
  }

  // The fourth is the first that costs anything.
  limits.noteAuthFailure(ip);
  const backoff = limits.authAllowed(ip);
  ok(backoff.ok === false && backoff.reason === 'auth_backoff',
    'the first failure past the grace puts the address into backoff');
  ok(limits.authRetryAfterMs(ip) === 2000,
    'and the first backoff step is authBackoffBaseMs (2s)');

  // Retrying into a closed door must not extend it. An honest player who
  // hammers retry during their own two-second wait would otherwise be
  // locked out for the evening.
  limits.authAllowed(ip);
  limits.authAllowed(ip);
  limits.authAllowed(ip);
  ok(limits.authRetryAfterMs(ip) === 2000,
    'refused attempts are not failures: retrying during backoff does not extend it');

  clock.advance(1999);
  ok(limits.authAllowed(ip).reason === 'auth_backoff',
    'one millisecond short of the backoff, the address is still refused');
  ok(limits.authRetryAfterMs(ip) === 1,
    'and is told exactly how much longer it owes');
  clock.advance(1);
  ok(limits.authAllowed(ip).ok,
    'once the backoff elapses the address may try again');

  // Escalation: each further failure doubles the wait.
  limits.noteAuthFailure(ip); // 5th
  ok(limits.authRetryAfterMs(ip) === 4000,
    'the second failure past the grace doubles the wait to 4s');
  clock.advance(4000);
  limits.noteAuthFailure(ip); // 6th
  ok(limits.authRetryAfterMs(ip) === 8000,
    'the third doubles again to 8s');

  // The ceiling. Doubling from 2s reaches 300000 on the ninth excess
  // failure (2^8 * 2000 = 512000, capped), i.e. the twelfth wrong code.
  clock.advance(8000);
  for (let i = 0; i < 6; i += 1) {
    limits.noteAuthFailure(ip);
    clock.advance(limits.authRetryAfterMs(ip));
  }
  limits.noteAuthFailure(ip);
  ok(limits.authRetryAfterMs(ip) === 300000,
    'the backoff caps at authBackoffMaxMs rather than doubling forever');

  // Recovery. This is what keeps the fat-fingering friend from being locked
  // out permanently: silence for authFailureWindowMs forgets the history
  // entirely, and the next wrong code starts again from the grace.
  clock.advance(300000);            // serve out the last backoff
  clock.advance(600000);            // then a full window of silence
  ok(limits.authAllowed(ip).ok, 'after the window the address is allowed again');
  limits.noteAuthFailure(ip);
  ok(limits.authAllowed(ip).ok,
    'and its next wrong code is free again: the failure count reset, not just the delay');
  ok(limits.authRetryAfterMs(ip) === 0,
    'so an honest player is never locked out permanently');

  // Success wipes the slate.
  limits.noteAuthFailure(ip);
  limits.noteAuthFailure(ip);
  limits.noteAuthFailure(ip);
  ok(limits.authAllowed(ip).reason === 'auth_backoff',
    'four failures inside the window put it back into backoff');
  ok(limits.noteAuthSuccess(ip) === true,
    'noteAuthSuccess reports that it cleared a record');
  ok(limits.authAllowed(ip).ok,
    'a correct code clears the address\'s failure history outright');
  ok(limits.noteAuthSuccess(ip) === false,
    'and clearing an address with no record reports so rather than throwing');

  // Grace 0 is a legal setting and means what it says.
  const strict = freshLimits(
    { authFailureGrace: 0, authBackoffBaseMs: 1000, authGlobalFailures: 1000000 },
    makeClock());
  strict.noteAuthFailure('203.0.113.11');
  ok(strict.authAllowed('203.0.113.11').reason === 'auth_backoff',
    'authFailureGrace: 0 backs an address off from its very first wrong code');
}

function testAuthPerIpIsPerPrefix() {
  const clock = makeClock();
  const limits = freshLimits(
    { authFailureGrace: 1, authBackoffBaseMs: 5000, authGlobalFailures: 1000000 },
    clock);

  // Same /64, different /128. A per-address backoff would be no backoff at
  // all here: the peer has 2^64 spellings of itself to spend one failure
  // from. See "/64 keying" in limits.js.
  limits.noteAuthFailure('2001:db8::1');
  limits.noteAuthFailure('2001:db8::2');
  ok(limits.authAllowed('2001:db8::dead').reason === 'auth_backoff',
    'failures from one /64 accumulate against the whole block, not one address');

  ok(limits.authAllowed('2001:db8:1::1').ok,
    'a genuinely different /64 is unaffected by its neighbour\'s failures');

  // IPv4 keeps counting per exact address -- an IPv4 host is one address.
  limits.noteAuthFailure('198.51.100.1');
  limits.noteAuthFailure('198.51.100.1');
  ok(limits.authAllowed('198.51.100.1').reason === 'auth_backoff',
    'an IPv4 address accumulates against itself');
  ok(limits.authAllowed('198.51.100.2').ok,
    'and its neighbour is untouched');

  // Spellings fold, exactly as they do for bans and the connection cap.
  limits.noteAuthFailure('::ffff:198.51.100.9');
  limits.noteAuthFailure('198.51.100.9');
  ok(limits.authAllowed('[::ffff:198.51.100.9]').reason === 'auth_backoff',
    'the mapped and bare spellings of one address share one failure record');

  // Garbage in must not throw on the authentication path.
  ok(limits.authAllowed(undefined).ok,
    'authAllowed on a non-string address answers rather than throwing');
  ok(limits.noteAuthFailure(undefined) === false,
    'and noteAuthFailure absorbs one too');
}

function testAuthGlobalCeiling() {
  const clock = makeClock();
  const limits = freshLimits({
    authGlobalFailures: 5,
    authGlobalWindowMs: 60000,
    authLockoutMs: 30000,
    // grace above the failure count, so nothing below is per-IP backoff
    authFailureGrace: 100,
  }, clock);

  const ipFor = (i) => `192.0.2.${i}`;

  for (let i = 1; i <= 4; i += 1) {
    ok(limits.noteAuthFailure(ipFor(i)) === false,
      `failure ${i} of 5 does not trip the ceiling`);
    ok(limits.authLockdown === false, `and the hub is not in lockdown after ${i}`);
    ok(limits.authAllowed(ipFor(99)).ok,
      `an unrelated address may still authenticate after ${i} hub-wide failures`);
  }

  ok(limits.noteAuthFailure(ipFor(5)) === true,
    'the failure that reaches the threshold reports the trip, once');
  ok(limits.authLockdown === true, 'and the hub-wide ceiling is now tripped');

  const refused = limits.authAllowed(ipFor(99));
  ok(refused.ok === false && refused.reason === 'auth_lockdown',
    'while tripped, a brand-new address is refused authentication');
  ok(limits.authRetryAfterMs(ipFor(99)) === 30000,
    'and is told the whole cooling period is left to run');

  ok(limits.noteAuthFailure(ipFor(6)) === false,
    'a further failure while tripped does not re-report the trip (edge, not level)');

  clock.advance(29999);
  ok(limits.authAllowed(ipFor(99)).reason === 'auth_lockdown',
    'one millisecond short of the cooling period, authentication is still refused');
  clock.advance(1);
  ok(limits.authAllowed(ipFor(99)).ok,
    'once the cooling period elapses, authentication reopens on its own');
  ok(limits.authLockdown === false, 'and the lockdown flag clears with it');
  ok(limits.stats().auth.recentFailures === 0,
    'the counter is zeroed on release, so one stray failure cannot re-trip instantly');

  // A second, independent trip: the mechanism rearms.
  for (let i = 1; i <= 4; i += 1) limits.noteAuthFailure(ipFor(i));
  ok(limits.authLockdown === false, 'four fresh failures are under the ceiling again');
  ok(limits.noteAuthFailure(ipFor(5)) === true, 'and the fifth trips it a second time');

  // Failures age out of the window rather than accumulating forever, so a
  // hub that sees a few wrong codes an hour never trips.
  const slowClock = makeClock();
  const drip = freshLimits(
    { authGlobalFailures: 5, authGlobalWindowMs: 60000, authFailureGrace: 100 },
    slowClock);
  for (let i = 0; i < 20; i += 1) {
    drip.noteAuthFailure('192.0.2.200');
    slowClock.advance(60000); // one whole window between each
  }
  ok(drip.authLockdown === false,
    'four-times-the-threshold failures spread one per window never trip the ceiling');
  ok(drip.stats().auth.recentFailures <= 1,
    'because the window forgets them as fast as they arrive');
}

function testAuthDistributedAttack() {
  // The scenario the global ceiling exists for, and the one per-IP limiting
  // cannot see: a thousand addresses, each politely under the per-IP
  // threshold, adding up to a grind that would otherwise run unimpeded.
  const clock = makeClock();
  const limits = freshLimits({
    authFailureGrace: 3,        // the honest default
    authGlobalFailures: 100,
    authGlobalWindowMs: 60000,
    authLockoutMs: 60000,
  }, clock);

  const ipFor = (i) => `10.${(i >> 8) & 255}.${i & 255}.1`;

  let tripped = false;
  let attempts = 0;
  // 50 addresses x 2 failures each = 100. Two apiece is *under* the grace of
  // three, so not one of them is ever individually backed off.
  for (let round = 0; round < 2 && !tripped; round += 1) {
    for (let i = 0; i < 50 && !tripped; i += 1) {
      attempts += 1;
      tripped = limits.noteAuthFailure(ipFor(i));
    }
  }

  ok(tripped, 'fifty addresses at two failures each trip the hub-wide ceiling');
  ok(attempts === 100,
    'and they trip it at exactly the configured threshold, not before or after');

  const stats = limits.stats();
  ok(stats.auth.throttledAddresses === 0,
    'not one of those addresses is in per-IP backoff -- each stayed under the ' +
    'grace, which is precisely why the per-IP throttle alone would have seen ' +
    'nothing wrong');
  ok(stats.auth.lockdown === true, 'yet the hub as a whole is closed to new attempts');

  // Rotating to a completely fresh address buys the attacker nothing. This
  // is the property that makes renting more hosts stop working.
  ok(limits.authAllowed('10.9.9.9').reason === 'auth_lockdown',
    'a never-before-seen address gains nothing from being fresh while tripped');
}

function testAuthCollateralBoundary() {
  // The assertion that matters most: a tripped ceiling closes the *door*,
  // not the hub. Everyone already inside keeps playing.
  const clock = makeClock();
  const limits = freshLimits({
    authGlobalFailures: 3,
    authGlobalWindowMs: 60000,
    authLockoutMs: 60000,
    authFailureGrace: 100,
    perIpConnections: 10,
    maxPending: 10,
    connectBurst: 100,
    idleTimeoutMs: 45000,
    // Longer than the lockout on purpose: this test needs a newcomer who is
    // still mid-handshake when the ceiling lifts, so the handshake budget
    // does not become the thing that closed her connection.
    handshakeTimeoutMs: 120000,
  }, clock);

  // Two players who authenticated before the attack started.
  limits.register('alice', '198.51.100.20');
  limits.markGreeted('alice');
  limits.noteAuthSuccess('198.51.100.20');
  limits.register('bob', '198.51.100.21');
  limits.markGreeted('bob');
  limits.noteAuthSuccess('198.51.100.21');
  ok(limits.stats().connections === 2, 'two players are in the world');

  // The attack.
  limits.noteAuthFailure('192.0.2.1');
  limits.noteAuthFailure('192.0.2.2');
  ok(limits.noteAuthFailure('192.0.2.3') === true, 'the ceiling trips');
  ok(limits.authLockdown === true, 'and the hub is refusing new authentication');

  // Nothing about the two players changed.
  ok(limits.sweep().length === 0,
    'a tripped ceiling dooms nobody: sweep() reports no connection to close');
  ok(limits.stats().connections === 2,
    'both authenticated players are still counted as connected');
  ok(limits.noteActivity('alice', { bytes: 40, completedLine: true }) === true,
    'an authenticated player\'s traffic is still accepted and tracked');
  ok(limits.writeAllowed('alice', 1024) === true,
    'and the hub will still write to them');
  ok(limits.connectionsFrom('198.51.100.20') === 1,
    'their connection is still charged to them, unchanged');

  // Time passes inside the lockout; the ordinary clocks still govern, and
  // only the ordinary clocks. Alice and Bob are playing, so they keep
  // producing traffic exactly as they would with no attack in progress.
  clock.advance(30000);
  limits.noteActivity('alice', { bytes: 40, completedLine: true });
  limits.noteActivity('bob', { bytes: 40, completedLine: true });
  ok(limits.sweep().length === 0,
    'half a minute into the lockout the players are still not swept');
  ok(limits.authLockdown === true, 'even though the ceiling is still tripped');

  // New *connections* are still accepted. The ceiling refuses authentication,
  // not TCP: a player who is mid-reconnect, or a hub with auth switched off,
  // must not be shut out of the front door by an attack on the passcode.
  ok(limits.admit('198.51.100.30').ok,
    'admit() is untouched by a tripped ceiling: connections are still admitted');
  limits.register('carol', '198.51.100.30');
  ok(limits.stats().connections === 3,
    'and a new connection can still be registered while the ceiling is tripped');

  // What it *does* cost, stated honestly: carol cannot prove her code yet.
  ok(limits.authAllowed('198.51.100.30').reason === 'auth_lockdown',
    'the one thing a newcomer cannot do while tripped is authenticate -- ' +
    'including a newcomer holding the correct code');

  // And when it lifts, she can, with no residue anywhere.
  clock.advance(30000);
  limits.noteActivity('alice', { bytes: 40, completedLine: true });
  limits.noteActivity('bob', { bytes: 40, completedLine: true });
  ok(limits.authAllowed('198.51.100.30').ok,
    'once the cooling period ends the newcomer authenticates normally');
  limits.markGreeted('carol');
  ok(limits.sweep().length === 0,
    'and nobody was ever swept on account of the attack');

  // The ordinary sweep still works afterwards, so the lockout did not
  // quietly disarm the connection clocks it must not touch.
  clock.advance(46000);
  const doomed = limits.sweep();
  ok(doomed.length === 3,
    'idle connections are still reaped normally after the lockout -- the ' +
    'ceiling suspended nothing');
  ok(doomed.every((d) => d.reason === 'idle_timeout' || d.reason === 'handshake_timeout'),
    'and for the ordinary reasons, never an auth one');
}

function testAuthDoesNotSpendConnectTokens() {
  // The judgement call, pinned. A refused authentication does NOT charge the
  // connect bucket: the connection it arrived on already spent a token in
  // admit(), and double-charging would drain a shared household's whole
  // connection budget over one roommate's typo while making
  // `connectPerMinute` mean something other than what it says. The auth
  // throttle is what stops the grinder; the bucket stays a connection
  // budget.
  const clock = makeClock();
  const limits = freshLimits({
    connectBurst: 3,
    connectPerMinute: 60,
    perIpConnections: 1000,
    maxPending: 1000,
    authFailureGrace: 100,
    authGlobalFailures: 1000000,
  }, clock);

  const ip = '203.0.113.50';
  ok(limits.admit(ip).ok, 'connect token 1 of 3 is spent by admit()');

  for (let i = 0; i < 25; i += 1) limits.noteAuthFailure(ip);

  ok(limits.admit(ip).ok, 'token 2 of 3 is still available after 25 auth failures');
  ok(limits.admit(ip).ok, 'and token 3 of 3');
  ok(limits.admit(ip).reason === 'rate',
    'the fourth is refused as rate -- exactly three tokens were spent, all by ' +
    'admit(): auth failures never charged the connect bucket');

  // The converse, and the reason the above is safe: an address deep in auth
  // backoff can still open sockets, and gets nowhere.
  const clock2 = makeClock();
  const back = freshLimits({
    authFailureGrace: 1,
    authBackoffBaseMs: 60000,
    authGlobalFailures: 1000000,
    connectBurst: 100,
    perIpConnections: 1000,
    maxPending: 1000,
  }, clock2);

  back.noteAuthFailure('203.0.113.51');
  back.noteAuthFailure('203.0.113.51');
  ok(back.authAllowed('203.0.113.51').reason === 'auth_backoff',
    'the address is in backoff');
  ok(back.admit('203.0.113.51').ok,
    'and may still connect -- the two limiters keep separate budgets');
  ok(back.authAllowed('203.0.113.51').reason === 'auth_backoff',
    'but reconnecting buys it nothing: the backoff is on the address, not the socket');

  // And a lockdown does not reach the connect bucket either.
  const clock3 = makeClock();
  const down = freshLimits(
    { authGlobalFailures: 1, authLockoutMs: 60000, authFailureGrace: 100 }, clock3);
  down.noteAuthFailure('192.0.2.77');
  ok(down.authLockdown === true, 'the ceiling is tripped');
  ok(down.admit('192.0.2.88').ok,
    'and an unrelated address is still admitted at its normal connect rate');
}

function testAuthStats() {
  const clock = makeClock();
  const limits = freshLimits({
    authGlobalFailures: 10,
    authGlobalWindowMs: 60000,
    authLockoutMs: 45000,
    authFailureGrace: 1,
    authBackoffBaseMs: 1000,
  }, clock);

  const quiet = limits.stats();
  ok(quiet.connections === 0 && quiet.pending === 0 && quiet.perIp &&
     typeof quiet.auth === 'object',
    'stats() keeps its existing shape and grows an auth section');
  ok(quiet.auth.recentFailures === 0 && quiet.auth.lockdown === false &&
     quiet.auth.lockdownMs === 0 && quiet.auth.throttledAddresses === 0 &&
     quiet.auth.trackedAddresses === 0,
    'a hub nobody is attacking reports nothing to worry about');
  ok(quiet.auth.failureThreshold === 10 && quiet.auth.windowMs === 60000,
    'and reports the threshold and window, so the count has a scale to read against');

  // Two addresses, two failures each: enough to back both off (grace 1).
  limits.noteAuthFailure('192.0.2.10');
  limits.noteAuthFailure('192.0.2.10');
  limits.noteAuthFailure('192.0.2.11');
  limits.noteAuthFailure('192.0.2.11');

  const hammered = limits.stats();
  ok(hammered.auth.recentFailures === 4,
    'stats() reports how many wrong passcodes arrived recently');
  ok(hammered.auth.throttledAddresses === 2,
    'and how many addresses are currently backed off -- one grinder or a fleet');
  ok(hammered.auth.trackedAddresses === 2,
    'and how many it is remembering at all');
  ok(hammered.auth.lockdown === false,
    'four of ten is under the ceiling, so no lockdown is reported');

  for (let i = 0; i < 6; i += 1) limits.noteAuthFailure(`192.0.2.${20 + i}`);
  const tripped = limits.stats();
  ok(tripped.auth.lockdown === true, 'stats() says plainly when the ceiling is tripped');
  ok(tripped.auth.lockdownMs === 45000,
    'and how long the hub will stay closed to new authentication');

  clock.advance(20000);
  ok(limits.stats().auth.lockdownMs === 25000,
    'the remaining lockout counts down on the injected clock');
  clock.advance(25000);
  const released = limits.stats();
  ok(released.auth.lockdown === false && released.auth.lockdownMs === 0,
    'and reads clear once it lifts');

  // The failure count decays with the window rather than accumulating for
  // the life of the process.
  clock.advance(120000);
  ok(limits.stats().auth.recentFailures === 0,
    'two windows of quiet leaves nothing in the recent-failure count');
  ok(limits.stats().auth.throttledAddresses === 0,
    'and no address is still serving a backoff');
}

function testAuthClockRunsBackwards() {
  // The injected clock can go backwards, and so can the real one across an
  // NTP step. Neither may leave the hub permanently closed.
  const clock = makeClock(1000000);
  const limits = freshLimits(
    { authGlobalFailures: 1, authLockoutMs: 30000, authFailureGrace: 100 }, clock);

  limits.noteAuthFailure('192.0.2.90');
  ok(limits.authLockdown === true, 'the ceiling trips');

  clock.set(0); // a step backwards past the whole lockout
  ok(limits.authRetryAfterMs('192.0.2.90') <= 30000,
    'a backwards clock cannot strand the lockout arbitrarily far in the future');
  clock.advance(30001);
  ok(limits.authLockdown === false,
    'and the hub reopens one configured lockout later, not never');
}

function testAuthVerdictSingletons() {
  const clock = makeClock();
  const limits = freshLimits(
    { authFailureGrace: 0, authBackoffBaseMs: 10000, authGlobalFailures: 1000000 },
    clock);

  limits.noteAuthFailure('192.0.2.100');
  limits.noteAuthFailure('192.0.2.101');
  const a = limits.authAllowed('192.0.2.100');
  const b = limits.authAllowed('192.0.2.101');
  ok(a === b, 'two backoff refusals are the same frozen singleton by reference');
  ok(Object.isFrozen(a), 'the auth_backoff verdict is frozen');

  const down = freshLimits(
    { authGlobalFailures: 1, authLockoutMs: 60000, authFailureGrace: 100 },
    makeClock());
  down.noteAuthFailure('192.0.2.110');
  const c = down.authAllowed('192.0.2.111');
  const d = down.authAllowed('192.0.2.112');
  ok(c === d && Object.isFrozen(c),
    'so are lockdown refusals -- a hub under attack allocates nothing per refusal');
  ok(c !== a, 'and the two refusals are distinguishable objects');
}

// ------------------------------------------- auth memory bounds
//
// Same problem as the bucket map, same shape of answer: an attacker cycling
// addresses must not grow the failure map without limit. Unlike the bucket
// map there *is* a defensible direct assertion here -- the map is pruned to
// a hard internal cap (MAX_AUTH_RECORDS, 4096) rather than only on the
// "carries no information" rule -- so this test reads the private
// `_authFails` field the way the pruning test above reads `_prunedAt`, and
// for the same reason: the decision has no other observable.

function testAuthMemoryBounds() {
  const clock = makeClock(0); // frozen: nothing ages out, so only the cap can save us
  const limits = freshLimits({
    authFailureGrace: 100,       // nobody is backed off; every record is "fresh"
    authGlobalFailures: 1000000, // and the ceiling never trips to end the loop early
    authFailureWindowMs: 600000,
  }, clock);

  const ADDRESSES = 20000; // comfortably past the internal cap (4096)
  const ipFor = (i) => `${10 + (i >> 16)}.${(i >> 8) & 255}.${i & 255}.7`;

  for (let i = 0; i < ADDRESSES; i += 1) limits.noteAuthFailure(ipFor(i));

  ok(limits._authFails.size <= 4097,
    `${ADDRESSES} distinct addresses leave at most the internal cap (4096, ` +
    `plus the record being written) in the failure map, not ${ADDRESSES}`);

  // Bounded is only useful if it is still correct. A fresh address gets a
  // clean judgement however many came before it.
  ok(limits.authAllowed('172.16.0.1').ok,
    'a fresh address is still judged correctly after the map has been evicted from');

  // And the address the attacker is *currently* on keeps its history: the
  // eviction drops the least-throttled records, not the most.
  const victim = '172.16.0.2';
  const throttled = freshLimits({
    authFailureGrace: 3,
    authBackoffBaseMs: 300000,
    authBackoffMaxMs: 300000,
    authGlobalFailures: 1000000,
  }, clock);
  // One grinder, past the grace and deep in backoff, then a flood of
  // single-failure addresses trying to push it out of the map.
  for (let i = 0; i < 4; i += 1) throttled.noteAuthFailure(victim);
  for (let i = 0; i < 6000; i += 1) throttled.noteAuthFailure(ipFor(i));
  ok(throttled.authAllowed(victim).reason === 'auth_backoff',
    'a deeply backed-off address survives an eviction storm: the least-throttled ' +
    'records go first, so cycling addresses cannot flush a grinder\'s own penalty');
}

// ------------------------------------------------------------------- main

function main() {
  testNormalizeIp();
  testNormalizeIpv6Canonical();
  testNormalizeIpMalformed();
  testIpv4Unchanged();
  testBanAcrossSpellings();
  testBansStayExact();
  testIpv6PrefixCap();
  testPerIpCap();
  testTokenBucket();
  testAdmitOrdering();
  testAllowlist();
  testMaxPending();
  testSweep();
  testSlowloris();
  testWriteAllowed();
  testReleaseIdempotent();
  testClamping();
  testVerdictSingletons();
  testRegisterTwiceAbsorbed();
  testNoteActivityUnknownKey();
  testBansAndAllowlistAcceptNonArray();
  testBucketPruningIntervalGated();
  testMemoryBoundsProxy();
  testAuthPerIpBackoff();
  testAuthPerIpIsPerPrefix();
  testAuthGlobalCeiling();
  testAuthDistributedAttack();
  testAuthCollateralBoundary();
  testAuthDoesNotSpendConnectTokens();
  testAuthStats();
  testAuthClockRunsBackwards();
  testAuthVerdictSingletons();
  testAuthMemoryBounds();

  console.log(`\n  ${passed}/${passed} checks passed  (limits)\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + (err && err.stack || err) + '\n');
  process.exit(1);
}
