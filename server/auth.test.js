#!/usr/bin/env node
'use strict';

/*
 * Pin the authentication primitives in server/lib/auth.js.
 *
 * This is the most load-bearing suite in the self-hosting feature: auth.js
 * decides whether a stranger gets into someone's game. The HMAC wire
 * contract in particular is cross-checked against an independently computed
 * digest -- never by calling back into auth.js's own sign() -- and a fixed
 * known-answer vector is hard-coded so a refactor that silently changes the
 * key or message derivation gets caught before it reaches a player.
 *
 * Same bespoke idiom as server/hub.test.js: a throwing ok(cond, label)
 * helper, plain scenario functions, a final console.log of the pass count.
 * No test framework, no dependencies beyond node:crypto.
 *
 * Run: node server/auth.test.js
 * Also runs under `npm test` (node --test), which auto-discovers *.test.js
 * siblings and runs each as its own process. This file has no node:test
 * imports, so --test treats the whole script as one implicit test and calls
 * it a pass as long as it exits 0 -- exactly how hub.test.js already behaves
 * under both invocations.
 */

const crypto = require('crypto');
const auth = require('./lib/auth.js');

let passed = 0;
const ok = (cond, label) => {
  if (!cond) throw new Error('FAIL: ' + label);
  passed++;
};

// ---------------------------------------------------------------- join codes

const CODE_RE = new RegExp(`^[${auth.ALPHABET}]{${auth.CODE_LEN}}$`);

function testJoinCodes() {
  const SAMPLE = 5000;
  const codes = [];
  for (let i = 0; i < SAMPLE; i++) codes.push(auth.generateJoinCode());

  ok(auth.CODE_LEN === 6, 'a passcode is 6 characters long');
  ok(auth.ALPHABET.length === 32, 'the alphabet is 32 symbols, so 32^6 = 2^30 exactly');

  ok(codes.every((c) => CODE_RE.test(c)),
    `all ${SAMPLE} generated codes match the ungrouped 6-character A7K3P9 shape`);
  ok(codes.every((c) => !c.includes('-')),
    'no generated code carries a dash: the grouped form is gone');

  const allChars = codes.join('');
  ok(allChars.length === SAMPLE * auth.CODE_LEN,
    'the sample produced the expected total character count');
  ok([...allChars].every((ch) => auth.ALPHABET.includes(ch)),
    'every character across the whole sample is in ALPHABET');
  ok(!/[ILOU]/.test(allChars),
    'the excluded characters I, L, O and U never appear across the sample');

  // Every symbol should turn up somewhere in 30,000 draws. A missing one
  // would mean an off-by-one in the rejection-sampling index range -- the
  // classic way to silently lose the first or last character of an alphabet.
  const seen = new Set(allChars);
  ok(seen.size === auth.ALPHABET.length,
    `all ${auth.ALPHABET.length} alphabet symbols appear across the sample`);

  /*
   * Distinctness -- a real question at 6 characters, where it simply was not
   * at 16. With 2^30 codes the birthday bound gives a 50% chance of *some*
   * collision once about sqrt(pi/2 * 2^30) ~= 41,000 codes have been drawn,
   * and for a sample of n the chance is about n(n-1)/2 / 2^30.
   *
   * At this 5,000-code sample that is ~1.2%, so asserting perfect
   * distinctness would be a genuinely flaky test -- roughly 1 run in 85 would
   * fail with nothing wrong. Tolerating a single duplicate pair drops the
   * false-failure rate to P(>=2 collisions) ~= 7e-5, about 1 run in 15,000,
   * while still catching every way a generator can actually be broken: a
   * fixed seed, a truncated index range or a reused randomBytes buffer
   * produces duplicates by the hundred, not by the one.
   *
   * At the scale anyone actually runs, this is a non-issue and the CLI is
   * right not to check for it: a host with 10 invites outstanding has a
   * 10*9/2 / 2^30 chance of two matching -- about 1 in 24 million.
   */
  const unique = new Set(codes);
  ok(unique.size >= SAMPLE - 1,
    `at most one duplicate pair across ${SAMPLE} generated codes ` +
    '(~1.2% birthday chance of one at this sample size, ~7e-5 of two)');
}

// --------------------------------------------------------------- normalising

function testNormalization() {
  const canonical = 'A7K3P9';
  const lower = 'a7k3p9';
  const spaced = ' A7K 3P9 ';
  const messy = ' a7k-3p9, ?? ';
  const dashedHabit = 'A7K-3P9'; // someone who remembers the old grouped form

  ok(auth.normalizeCode(canonical) === canonical, 'the canonical form is unchanged');
  ok(auth.normalizeCode(lower) === canonical, 'lowercase normalises the same as uppercase');
  ok(auth.normalizeCode(spaced) === canonical, 'spaces are stripped');
  ok(auth.normalizeCode(messy) === canonical, 'stray punctuation and dashes are stripped');
  ok(auth.normalizeCode(dashedHabit) === canonical,
    'a dash typed out of old habit still normalises to the same passcode');

  ok(auth.normalizeCode('A7K3P') === null, 'a too-short input returns null');
  ok(auth.normalizeCode('A7K3P99') === null, 'a too-long input returns null');
  ok(auth.normalizeCode('') === null, 'an empty string returns null');
  ok(auth.normalizeCode('!!!!!!') === null,
    'an input with nothing in the alphabet returns null rather than an empty code');

  // The excluded letters are outside the alphabet, so they are dropped like
  // any other stray character rather than folded to a lookalike: O does not
  // become 0 and I does not become 1. Wire.lua must mirror this exactly --
  // a Lua half that aliased them would normalise the same input to a
  // different key and every such player would be told their passcode is
  // wrong.
  ok(auth.normalizeCode('IA7LK3OP9U') === canonical,
    'I, L, O and U are dropped as noise, leaving the code intact');
  ok(auth.normalizeCode('A7K3PO') === null,
    'typing O for 0 drops a character and fails the length check, rather than aliasing to 0');
  ok(auth.normalizeCode('A7K3P1') !== auth.normalizeCode('A7K3PI'),
    'and I is not an alias for 1');

  // The old 16-character format is not a valid passcode any more. It must
  // refuse, not truncate -- truncating would turn a stale invite into a
  // different, wrong-but-accepted key.
  ok(auth.normalizeCode('ABCD-EFGH-JKMN-PQRS') === null,
    'a legacy 16-character code is refused outright, not truncated to 6');

  for (const bad of [42, null, undefined, {}, [], true, Symbol('x')]) {
    ok(auth.normalizeCode(bad) === null, `a non-string input (${String(bad)}) returns null`);
  }

  // formatCode is a passthrough at 6 characters -- kept as the named seam for
  // "render this for a human" rather than deleted, since callers outside this
  // module (lib/cli.js, and Wire.formatCode on the Lua side) go through it.
  ok(auth.formatCode(auth.normalizeCode(canonical)) === canonical,
    'formatCode(normalizeCode(x)) round-trips the canonical form');
  ok(auth.formatCode(auth.normalizeCode(messy)) === canonical,
    'a messy input round-trips to the same canonical form');
  ok(!auth.formatCode(canonical).includes('-'),
    'formatCode adds no grouping at 6 characters');
  ok(auth.formatCode(canonical) === canonical, 'formatCode is a passthrough');
  ok(auth.formatCode(auth.formatCode(canonical)) === canonical, 'and idempotent');
  ok(auth.formatCode(null) === '' && auth.formatCode(undefined) === '',
    'formatCode answers the empty string for a non-string rather than throwing');
  ok(auth.formatCode(canonical).length === auth.CODE_LEN,
    'formatCode returns the whole code -- it is a formatter, never a mask');
}

// -------------------------------------------------------- the HMAC contract

function testHmacContract() {
  const code = 'a7k 3p9';
  const nonce = auth.newNonce();
  const normalized = auth.normalizeCode(code);

  ok(/^[0-9a-f]{32}$/.test(nonce),
    'newNonce is 16 random bytes as 32 lowercase hex characters');

  // Independently computed -- this does NOT call back into auth.js's own
  // HMAC path. A test that asserted sign() equalled sign() would prove
  // nothing about the wire contract; this proves auth.js agrees with the
  // literal recipe documented at the top of lib/auth.js.
  const expected = crypto
    .createHmac('sha256', Buffer.from(normalized, 'ascii'))
    .update(nonce, 'ascii')
    .digest('hex');

  const actual = auth.sign(code, nonce);
  ok(actual === expected,
    'sign() matches an independently computed HMAC-SHA256(normalizedCode, nonce)');
  ok(/^[0-9a-f]{64}$/.test(actual), 'the signature is 64 lowercase hex characters');

  const messySig = auth.sign(' a7k-3p9 ', nonce);
  const cleanSig = auth.sign('A7K3P9', nonce);
  ok(messySig === cleanSig, 'a messy and a canonical spelling of the same code sign identically');

  // The key is the *normalised* code as ASCII bytes -- never the raw input.
  // Signing with the raw string would make ' a7k-3p9 ' and 'A7K3P9' different
  // keys, and every player who pasted a code with a space would be told it
  // was wrong.
  const rawKeyed = crypto
    .createHmac('sha256', Buffer.from(' a7k-3p9 ', 'ascii'))
    .update(nonce, 'ascii')
    .digest('hex');
  ok(messySig !== rawKeyed, 'the HMAC key is the normalised code, not the raw input string');

  // The message is the nonce's hex *string*, not its decoded bytes. This is
  // the half of the contract the Lua side would most easily get wrong, since
  // hex-decoding first is the more obvious implementation.
  const byteKeyed = crypto
    .createHmac('sha256', Buffer.from(normalized, 'ascii'))
    .update(Buffer.from(nonce, 'hex'))
    .digest('hex');
  ok(actual !== byteKeyed,
    'the HMAC message is the nonce hex string, not the 16 decoded nonce bytes');

  for (const bad of [null, undefined, '', 42, {}]) {
    let threw = false;
    try { auth.sign('A7K3P9', bad); } catch (err) { threw = err instanceof TypeError; }
    ok(threw, `sign throws a TypeError on a non-string nonce (${String(bad)})`);
  }

  for (const bad of ['A7K3P', 'ABCD-EFGH-JKMN-PQRS', '!!!!!!', null, 42]) {
    let threw = false;
    try { auth.sign(bad, nonce); } catch (err) { threw = err instanceof TypeError; }
    ok(threw, `sign throws a TypeError on an unnormalisable code (${String(bad)})`);
  }
}

/*
 * Known-answer vector -- the cross-language contract with src/Sha256.lua.
 * Recomputed for the 6-character passcode format; the old 16-character
 * vector is dead and must not be resurrected from git history.
 *
 *   code:   A7K3P9   (already canonical: 6 chars, no dashes)
 *   nonce:  a1b2c3d4e5f6070819293a4b5c6d7e8f   (32 lowercase hex chars)
 *   digest: HMAC-SHA256(key = 'A7K3P9' as the 6 ASCII bytes
 *                             41 37 4b 33 50 39,
 *                       message = the 32-character nonce string above, taken
 *                             as ASCII -- NOT the 16 bytes it decodes to)
 *
 * Computed once, offline, with node:crypto -- independently written, never by
 * calling auth.sign():
 *
 *   crypto.createHmac('sha256', Buffer.from('A7K3P9', 'ascii'))
 *     .update('a1b2c3d4e5f6070819293a4b5c6d7e8f', 'ascii')
 *     .digest('hex')
 *   === '56a6349bae6c261ba588e3d29671234ba74ff295d8deb0fff22254e83acf9670'
 *
 * src/Sha256.lua's HMAC-SHA256 must reproduce this exact 64-hex-character
 * value for the same two inputs. If it does not, a correct passcode will
 * look like a wrong one to a client on the pure-Lua implementation -- silent
 * auth failure, not a crash, which is why this is pinned as a literal rather
 * than derived from any code path.
 */
const KAT_CODE = 'A7K3P9';
const KAT_NONCE = 'a1b2c3d4e5f6070819293a4b5c6d7e8f';
const KAT_DIGEST = '56a6349bae6c261ba588e3d29671234ba74ff295d8deb0fff22254e83acf9670';

function testKnownAnswerVector() {
  ok(KAT_DIGEST.length === 64, 'the fixed vector literal is 64 characters long');
  ok(/^[0-9a-f]{64}$/.test(KAT_DIGEST), 'the fixed vector literal is lowercase hex');
  ok(KAT_CODE.length === auth.CODE_LEN && auth.normalizeCode(KAT_CODE) === KAT_CODE,
    'the vector code is already canonical, so the literal pins sign() and not normalizeCode()');
  ok(KAT_NONCE.length === auth.NONCE_BYTES * 2 && /^[0-9a-f]+$/.test(KAT_NONCE),
    'the vector nonce is the wire shape: 16 bytes as 32 lowercase hex characters');
  ok(auth.sign(KAT_CODE, KAT_NONCE) === KAT_DIGEST,
    'sign() reproduces the fixed known-answer vector');
  ok(auth.sign(' a7k-3p9 ', KAT_NONCE) === KAT_DIGEST,
    'and reproduces it from a messy spelling of the same passcode');
}

// ------------------------------------------------------------------- verify

function testVerify() {
  const code = 'A7K3P9';
  const nonce = auth.newNonce();
  const goodResponse = auth.sign(code, nonce);
  const credential = auth.newCredential({ secret: code });

  {
    const result = auth.verify(nonce, goodResponse, [credential]);
    ok(result.ok === true, 'a correct response is accepted');
    ok(result.credentialId === credential.id, 'credentialId names the credential that matched');
    ok(result.reason === null, 'a successful verify carries no reason');
  }

  {
    const wrong = auth.sign('WXYZ23', nonce);
    const result = auth.verify(nonce, wrong, [credential]);
    ok(result.ok === false, 'a wrong response is rejected');
    ok(result.reason === 'rejected', 'and reported as a plain rejection');
    ok(result.credentialId === null, 'and names no credential');
  }

  // A response of the wrong length/case/charset must be refused as
  // 'malformed' before any credential is consulted -- proven by getting the
  // same verdict whether or not a matching credential, or any credential at
  // all, is present.
  const malformedCases = [
    ['too short', goodResponse.slice(0, 10)],
    ['too long', goodResponse + 'ab'],
    ['wrong case', 'A' + goodResponse.slice(1)],
    ['wrong charset', goodResponse.slice(0, 63) + 'z'],
  ];
  for (const [label, response] of malformedCases) {
    const withCreds = auth.verify(nonce, response, [credential]);
    ok(withCreds.reason === 'malformed',
      `${label} response is rejected as malformed even with a matching credential present`);
    const withoutCreds = auth.verify(nonce, response, []);
    ok(withoutCreds.reason === 'malformed',
      `${label} response is rejected as malformed ahead of the empty-credential-list check`);
  }

  {
    const result = auth.verify(nonce, goodResponse, []);
    ok(result.ok === false, 'an empty credential list never admits');
    ok(result.reason === 'no_credentials', 'and is reported distinctly from a wrong code');
  }

  // Revoked, expired and used-up credentials must be indistinguishable from
  // a plain wrong code in the reason returned -- a refusal must not be an
  // oracle for enumerating which invites a hub has issued. Each is tested
  // alongside one genuinely active credential so the hub is in the same
  // "has active credentials" state as the plain-wrong-code case above --
  // otherwise activeCredentials() would filter the pool down to nothing and
  // the comparison would be against 'no_credentials' instead, which is a
  // different question (whether *any* credential is active right now, not
  // whether *this* one is).
  const now = Date.now();
  const revoked = Object.assign(
    auth.newCredential({ secret: 'AAAAAA' }), { revoked: true });
  const expired = Object.assign(
    auth.newCredential({ secret: 'BBBBBB' }),
    { expiresAt: new Date(now - 1000).toISOString() });
  const usedUp = Object.assign(
    auth.newCredential({ secret: 'CCCCCC', maxUses: 1 }), { uses: 1 });
  const bystander = auth.newCredential({ secret: 'ZZZZZZ' });

  for (const [label, cred, signCode] of [
    ['a revoked credential', revoked, 'AAAAAA'],
    ['an expired credential', expired, 'BBBBBB'],
    ['a used-up credential', usedUp, 'CCCCCC'],
  ]) {
    const response = auth.sign(signCode, nonce);
    const result = auth.verify(nonce, response, [cred, bystander], now);
    ok(result.ok === false, `${label} is rejected even with the right underlying code`);
    ok(result.reason === 'rejected', `${label} looks identical to a plain wrong code`);
  }

  {
    const valid = auth.newCredential({ secret: 'DDDDDD' });
    const pool = [revoked, expired, usedUp, valid];
    const response = auth.sign('DDDDDD', nonce);
    const result = auth.verify(nonce, response, pool, now);
    ok(result.ok === true, 'a valid credential is still found among several invalid ones');
    ok(result.credentialId === valid.id, 'and identified by the right id');
  }

  // A stored secret in the retired 16-character format no longer normalises,
  // so verify() skips it rather than throwing on it. It cannot admit anyone,
  // and -- the point -- it cannot take the whole hub down with it either.
  {
    const legacy = { id: 'legacy', secret: 'ABCD-EFGH-JKMN-PQRS' };
    const valid = auth.newCredential({ secret: 'DDDDDD' });
    const response = auth.sign('DDDDDD', nonce);
    const result = auth.verify(nonce, response, [legacy, valid], now);
    ok(result.ok === true, 'an unnormalisable legacy secret is skipped, not thrown on');
    ok(result.credentialId === valid.id, 'and the usable credential beside it still matches');

    const legacyOnly = auth.verify(
      nonce, auth.sign('DDDDDD', nonce), [legacy], now);
    ok(legacyOnly.ok === false, 'a hub holding only legacy secrets admits nobody');
    ok(legacyOnly.reason === 'rejected',
      'and says so without naming the format, keeping the refusal uninformative');
  }

  // timingSafeEqual is what the comparison must go through: a plain ===
  // on 64 hex characters leaks, through response time, how long a prefix of
  // the expected digest an attacker has guessed. Proven by counting calls,
  // since the property is otherwise invisible from outside.
  {
    const real = crypto.timingSafeEqual;
    let calls = 0;
    crypto.timingSafeEqual = function (a, b) { calls++; return real(a, b); };
    try {
      auth.verify(nonce, auth.sign(code, nonce), [auth.newCredential({ secret: code })]);
    } finally {
      crypto.timingSafeEqual = real;
    }
    ok(calls === 1, 'verify compares the response with crypto.timingSafeEqual, not ===');
  }

  // And no early exit: every active credential is compared even once one has
  // matched, so the hub's answer does not time-leak which position matched or
  // how many credentials it is carrying.
  {
    const first = auth.newCredential({ secret: 'DDDDDD' });
    const pool = [first, auth.newCredential({}), auth.newCredential({}), auth.newCredential({})];
    const real = crypto.timingSafeEqual;
    let calls = 0;
    crypto.timingSafeEqual = function (a, b) { calls++; return real(a, b); };
    try {
      auth.verify(nonce, auth.sign('DDDDDD', nonce), pool);
    } finally {
      crypto.timingSafeEqual = real;
    }
    ok(calls === pool.length,
      'every active credential is compared even after a match -- no early exit to time');
  }
}

// --------------------------------------------------- isActive / activeCredentials

function testActiveCredentials() {
  const now = 1700000000000; // a fixed reference instant

  const justBefore = { secret: 'AAAAAA', expiresAt: new Date(now + 1).toISOString() };
  const exactlyAt = { secret: 'AAAAAA', expiresAt: new Date(now).toISOString() };
  const justAfter = { secret: 'AAAAAA', expiresAt: new Date(now - 1).toISOString() };
  ok(auth.isActive(justBefore, now) === true, 'a credential expiring 1ms in the future is still active');
  ok(auth.isActive(exactlyAt, now) === false, 'a credential expiring exactly now is already expired');
  ok(auth.isActive(justAfter, now) === false, 'a credential that expired 1ms ago is expired');

  const underMax = { secret: 'AAAAAA', maxUses: 3, uses: 2 };
  const atMax = { secret: 'AAAAAA', maxUses: 3, uses: 3 };
  const overMax = { secret: 'AAAAAA', maxUses: 3, uses: 4 };
  ok(auth.isActive(underMax, now) === true, 'one use below maxUses is still active');
  ok(auth.isActive(atMax, now) === false, 'uses equal to maxUses is exhausted');
  ok(auth.isActive(overMax, now) === false, 'uses above maxUses is exhausted');

  const revoked = { secret: 'AAAAAA', revoked: true };
  ok(auth.isActive(revoked, now) === false, 'a revoked credential is never active');

  const badExpiry = { secret: 'AAAAAA', expiresAt: 'not-a-date' };
  ok(auth.isActive(badExpiry, now) === false, 'an unparseable expiresAt is treated as expired');

  // The same rule, one field over: a use count the hub cannot read is a
  // budget it cannot enforce, so it counts as spent. This is the last gate
  // before admission and it must have no fail-open branch -- a credential
  // whose `uses` was hand-edited to a string, or corrupted to an object, used
  // to make the `uses >= maxUses` comparison unreachable and stay active for
  // ever regardless of maxUses.
  const unreadableUses = [
    ['a string', 'lots'],
    ['an object', {}],
    ['NaN', Number.NaN],
    ['Infinity', Number.POSITIVE_INFINITY],
  ];
  for (const [label, uses] of unreadableUses) {
    const credential = { secret: 'AAAAAA', maxUses: 3, uses };
    ok(auth.isActive(credential, now) === false,
      `${label} as the use count fails closed, not open`);
  }

  // ...but a *missing* count is genuinely zero uses, which is what every
  // freshly-minted credential has before anyone has spent it.
  ok(auth.isActive({ secret: 'AAAAAA', maxUses: 3 }, now) === true,
    'a credential with no uses recorded yet is still active');
  ok(auth.isActive({ secret: 'AAAAAA', maxUses: 3, uses: null }, now) === true,
    'and so is one whose count is null');

  // And the whole way through verify(), with the right underlying code: an
  // unreadable count must look exactly like a spent one from outside.
  {
    const nonce = auth.newNonce();
    const broken = { id: 'broken', secret: 'AAAAAA', maxUses: 1, uses: 'one' };
    const result = auth.verify(nonce, auth.sign('AAAAAA', nonce), [broken], now);
    ok(result.ok === false,
      'verify refuses a credential whose use count cannot be read, even with the right code');
    ok(result.reason === 'no_credentials',
      'and it is filtered out before the comparison rather than failing it');
  }

  const pool = [justBefore, exactlyAt, atMax, revoked, underMax];
  const active = auth.activeCredentials(pool, now);
  ok(active.length === 2, 'activeCredentials keeps only the active entries');
  ok(active.includes(justBefore) && active.includes(underMax), 'and keeps the right ones');
}

// ------------------------------------------------------------- newCredential

function testNewCredential() {
  const generated = auth.newCredential({});
  ok(typeof generated.secret === 'string' && auth.normalizeCode(generated.secret) !== null,
    'newCredential generates a usable secret when none is given');

  ok(generated.secret.length === auth.CODE_LEN && !generated.secret.includes('-'),
    'and stores it in the 6-character ungrouped form');

  const given = auth.newCredential({ secret: 'a7k-3p9' });
  ok(given.secret === 'A7K3P9',
    'a given secret is normalised on the way in, so config.json holds the canonical form');

  // A secret in the retired 16-character format is not silently accepted or
  // truncated: minting a credential nobody can ever use is a call-site bug
  // and throws, which is the one place in auth.js that may.
  for (const bad of ['ABCD-EFGH-JKMN-PQRS', 'A7K3P', '!!!!!!']) {
    let threw = false;
    try { auth.newCredential({ secret: bad }); } catch (err) { threw = err instanceof TypeError; }
    ok(threw, `newCredential refuses an unusable secret (${bad})`);
  }

  // ...but an absent secret is the ordinary `init` / `invite` path and mints
  // a fresh one rather than throwing.
  for (const blank of [undefined, null, '']) {
    const minted = auth.newCredential({ secret: blank });
    ok(auth.normalizeCode(minted.secret) === minted.secret,
      `an absent secret (${String(blank)}) mints a fresh canonical passcode`);
  }

  ok(typeof generated.createdAt === 'string' && !Number.isNaN(Date.parse(generated.createdAt)),
    'createdAt is stamped with a parseable date');

  ok(generated.uses === 0, 'uses starts at 0');
  ok(generated.revoked === false, 'and it is not born revoked');
  ok(generated.maxUses === null && generated.expiresAt === null,
    'an unqualified credential has no budget and no expiry');
  ok(generated.label === 'Join code', 'and carries the default label');

  // The id is an identifier, not a secret, and it is what `revoke <id>`
  // takes -- so it has to be distinct per credential even though passcodes
  // themselves are only 30 bits.
  const ids = new Set();
  for (let i = 0; i < 50; i++) ids.add(auth.newCredential({}).id);
  ok(ids.size === 50, 'newCredential gives distinct ids');

  // The id must not be derived from the secret: that would turn a public
  // column into a 30-bit oracle for the passcode it names.
  const twins = [
    auth.newCredential({ secret: 'A7K3P9' }),
    auth.newCredential({ secret: 'A7K3P9' }),
  ];
  ok(twins[0].id !== twins[1].id,
    'two credentials with the same secret still get different ids -- the id is not derived from it');
}

// --------------------------------------------------------------------- main

function main() {
  testJoinCodes();
  testNormalization();
  testHmacContract();
  testKnownAnswerVector();
  testVerify();
  testActiveCredentials();
  testNewCredential();
  console.log(`\n  ${passed}/${passed} checks passed  (auth)\n`);
  console.log(`  known-answer vector -- code: ${KAT_CODE}  nonce: ${KAT_NONCE}`);
  console.log(`  known-answer vector -- digest: ${KAT_DIGEST}\n`);
}

try {
  main();
} catch (err) {
  console.error('\n  ' + err.message + '\n');
  process.exit(1);
}
