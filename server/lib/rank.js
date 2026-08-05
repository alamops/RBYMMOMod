'use strict';

/*
 * Ranked PVP: what a win is worth, and who is on top.
 *
 * This is the Node half of src/Rank.lua and the two must agree number for
 * number. The same player joins a game hosted from inside somebody's copy of
 * the game and a dedicated hub on a box somewhere, and a win worth 27 points
 * on one and 16 on the other is not a ranking, it is two. Both suites drive
 * the same table of cases for exactly that reason.
 *
 * The reasoning behind the numbers lives in src/Rank.lua's header rather
 * than being restated here; the short version:
 *
 *   * Elo, so the opponent's rating decides the size of the swing and there
 *     is nothing to gain from hunting the weakest player in the room.
 *   * A rematch inside RANK_REPEAT_WINDOW pays half, then a quarter, then
 *     nothing -- counted in both directions, so two friends trading wins
 *     cannot farm each other either.
 *   * A loss is never discounted, points floor at zero, and a draw scores
 *     nothing (a dead link ends a link battle as a draw, and paying for one
 *     would pay for pulling the cable out).
 *
 * Times are milliseconds here and seconds on the Lua side, because each
 * matches the clock its own hub already runs on.
 */

const crypto = require('node:crypto');

const RANK_K = 32;
const RANK_SCALE = 400;
const RANK_START = 0;
const RANK_MAX = 9999;
const RANK_TOP = 10;
const RANK_REPEAT_WINDOW_MS = 3600 * 1000;
const RANK_REPEAT_FADE = 6;
const RANK_PAIRS_MAX = 512;
const RANK_REPORT_GRACE_MS = 60 * 1000;
const RANK_QUERY_GATE_MS = 1000;
// A claim token, lowercase hex: 16 bytes, the same shape src/Config.lua's
// RANK_TOKEN_HEX describes. From crypto.randomBytes here and from the game's
// entropy pool on the Lua side -- the pool's own header is honest about the
// difference, and this is the side that has a real CSPRNG.
const RANK_TOKEN_BYTES = 16;

function mintToken() {
  return crypto.randomBytes(RANK_TOKEN_BYTES).toString('hex');
}

function digest(token) {
  return crypto.createHash('sha256').update(String(token)).digest('hex');
}

/*
 * The board is keyed by trainer name, upper-cased -- and a name is *claimed*
 * by whoever first played under it (see claim() below).
 *
 * Keying on the connection id would reset every rating on every reconnect,
 * so the name has to be the key. But a name is typed, not proved, so the
 * first time a hub sees one it mints a secret, hands it over once, and keeps
 * only the digest; later hellos carry the secret back and that is what says
 * "same player". A claim ticket, not an account: the token crosses an
 * unencrypted link and lives in a save file, which is the same exposure the
 * join code already has and is documented as such.
 */
function keyOf(name) {
  if (typeof name !== 'string') return null;
  const clean = name.toUpperCase().trim();
  return clean || null;
}

function clampPoints(value) {
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n)) return 0;
  if (n < 0) return 0;
  if (n > RANK_MAX) return RANK_MAX;
  return n;
}

/** The chance the first rating beats the second, on Elo's own curve. */
function expected(a, b) {
  return 1 / (1 + 10 ** ((b - a) / RANK_SCALE));
}

/*
 * What one match moves before the rematch discount: what the winner would
 * gain, and what the loser would lose. Two roundings rather than one number
 * used twice, because the pair stops being symmetric the moment either side
 * is against the floor.
 */
function swing(winnerPoints, loserPoints) {
  const e = expected(winnerPoints, loserPoints);
  return {
    gain: Math.round(RANK_K * (1 - e)),
    loss: Math.round(RANK_K * e),
  };
}

/*
 * Halve per prior meeting inside the window, and stop at zero. The exponent
 * is capped before it is used: 2 ** (a few thousand) is Infinity, and a
 * division by that is a value nobody wants inside a score.
 */
function discount(gain, repeats) {
  const n = Number(repeats) || 0;
  if (n <= 0) return gain;
  if (n >= RANK_REPEAT_FADE) return 0;
  return Math.floor(gain / 2 ** n);
}

function pairKey(a, b) {
  return a < b ? `${a}${b}` : `${b}${a}`;
}

class Board {
  constructor(options) {
    const opts = options || {};
    /** key -> { key, name, sprite, points, played, won } */
    this.entries = new Map();
    /** pair key -> [timestamps] */
    this.meetings = new Map();
    this.window = Number.isFinite(Number(opts.window))
      ? Number(opts.window) : RANK_REPEAT_WINDOW_MS;
  }

  entry(name) {
    const key = keyOf(name);
    if (!key) return null;
    let found = this.entries.get(key);
    if (!found) {
      found = {
        key, name, sprite: null, points: RANK_START, played: 0, won: 0,
        // the digest of whatever claimed this name, or null for a name
        // nobody has claimed yet
        tokenHash: null,
        // whether that claim was ever *proved* -- see claim(). A minted
        // claim is provisional: nobody has yet shown they hold the ticket.
        confirmed: false,
      };
      this.entries.set(key, found);
    }
    return found;
  }

  /*
   * A player is here, and this is what they look like today. Called when
   * somebody joins, so the leaderboard can draw a character for a player who
   * is offline -- the alternative is a row with a blank where everybody else
   * has a portrait. It never touches points: being seen is not a result.
   */
  seen(name, sprite) {
    const entry = this.entry(name);
    if (!entry) return null;
    entry.name = name;
    if (typeof sprite === 'string' && sprite) entry.sprite = sprite;
    return entry;
  }

  /*
   * Who is behind this name, as far as a hub can tell. Mirrors
   * Board:claim in src/Rank.lua, verdict for verdict:
   *
   *   'claimed'  -- the name was free, or its claim was still provisional;
   *                 `fresh` now owns it and must be handed to the player,
   *                 once. They score.
   *   'owner'    -- the presented token matches the one on file. They score,
   *                 and the claim is confirmed from here on.
   *   'impostor' -- the name is claimed and this is not the holder. They
   *                 play as normal and their battles score nothing.
   *   'open'     -- free, and no token to claim it with. They score, and the
   *                 name stays claimable.
   *
   * **A claim is provisional until it is proved.** Minting one only says a
   * ticket was posted, not that it arrived: a welcome that never reached the
   * client, a hub restarted before the file was written, or a save that never
   * carried the token to disk all leave a name claimed by nobody who can
   * present it -- and under the old rule that locked the rightful owner out
   * of their own name forever. So an unconfirmed claim on a name that has
   * never scored is transferred to whoever is connecting now. Nothing is
   * stolen by that: an unscored name holds no rating, and the owner who lost
   * the race takes it back the same way. The moment a name is proved (a
   * returning token) or worth something (a settled battle) it is confirmed,
   * and from then on the wrong ticket is refused exactly as before.
   *
   * `inUse` is the caller's answer to "is somebody *ranked* on this hub
   * connected under this name right now" -- board state alone cannot see it,
   * and without it the leniency above becomes theft: a player sitting on an
   * unproved, unscored claim would have it taken from under them by the next
   * hello for the same name, and their next settled win would land on the
   * taker's claim. Two friends who never changed the default trainer name are
   * enough to reach that by accident. So a live holder is an impostor gate
   * like `confirmed` and `played`, and the reclaim this rule exists for --
   * where the owner is not connected at all -- is untouched.
   *
   * Only the digest is kept, so a leaked ranking.json gives away nobody's
   * name -- it lists who is on the board, which is public anyway.
   */
  claim(name, presented, fresh, inUse) {
    const entry = this.entry(name);
    if (!entry) return 'impostor';

    if (entry.tokenHash) {
      if (typeof presented === 'string' && presented) {
        const seen = Buffer.from(digest(presented), 'utf8');
        const held = Buffer.from(entry.tokenHash, 'utf8');
        // timingSafeEqual, like the credential check next door: it throws on
        // a length mismatch, which a stored hash of the wrong shape causes.
        if (seen.length === held.length && crypto.timingSafeEqual(seen, held)) {
          entry.confirmed = true;
          return 'owner';
        }
      }
      // Unproved, unscored, worth nothing and nobody's right now: the claim
      // moves rather than shutting the name. `played` is the usual test --
      // record() is the only thing that raises it, and a draw is not recorded
      // -- and `points` is the belt on top of it, so a hand-edited file with a
      // rating but no games behind it is not a name anybody can walk into.
      if (entry.confirmed || entry.played > 0 || entry.points > RANK_START) {
        return 'impostor';
      }
      if (inUse) return 'impostor';
      if (typeof fresh !== 'string' || !fresh) return 'impostor';
      entry.tokenHash = digest(fresh);
      return 'claimed';
    }

    if (typeof fresh !== 'string' || !fresh) return 'open';
    entry.tokenHash = digest(fresh);
    entry.confirmed = false;
    return 'claimed';
  }

  /* Has anybody claimed this name? Never creates an entry: asking about a
   * name must not be what puts it on the board. */
  claimed(name) {
    const key = keyOf(name);
    const entry = key && this.entries.get(key);
    return Boolean(entry && entry.tokenHash);
  }

  points(name) {
    const key = keyOf(name);
    const entry = key && this.entries.get(key);
    return entry ? entry.points : RANK_START;
  }

  get(name) {
    const key = keyOf(name);
    return (key && this.entries.get(key)) || null;
  }

  /*
   * How many times these two have already played inside the window. One
   * bucket per pair and not per direction: A beating B and B beating A are
   * the same two people arranging results between themselves, which is the
   * thing the discount exists to make worthless.
   */
  meetingsBetween(aKey, bKey, now) {
    const stamps = this.meetings.get(pairKey(aKey, bKey));
    if (!stamps) return 0;
    let live = 0;
    for (const at of stamps) if (now - at < this.window) live += 1;
    return live;
  }

  noteMeeting(aKey, bKey, now) {
    const key = pairKey(aKey, bKey);
    let stamps = this.meetings.get(key);
    if (!stamps) {
      stamps = [];
      this.meetings.set(key, stamps);
    }
    // bounded even inside one window: the discount is zero long before
    // RANK_REPEAT_FADE meetings, so an older stamp changes no answer
    if (stamps.length >= RANK_REPEAT_FADE) stamps.shift();
    stamps.push(now);
  }

  /*
   * Drop pairings nobody can be discounted for any more. A hub that runs for
   * a month would otherwise hold one list per pair of players who ever met,
   * forever. Rare and cheap: it runs only once the table is larger than a
   * session plausibly needs.
   */
  sweep(now) {
    if (this.meetings.size <= RANK_PAIRS_MAX) return;
    for (const [key, stamps] of this.meetings) {
      const kept = stamps.filter((at) => now - at < this.window);
      if (kept.length) this.meetings.set(key, kept);
      else this.meetings.delete(key);
    }
  }

  /*
   * Settle one match. Returns what changed, or null when it was not a match
   * between two different, nameable players.
   *
   * Everything about the *result* is decided here and nothing about whether
   * to believe it: agreeing an outcome is the relay's job, and that is the
   * part a lying client attacks (see the mmo.result handler).
   */
  record(winnerName, loserName, now) {
    const at = Number(now) || 0;
    const winner = this.entry(winnerName);
    const loser = this.entry(loserName);
    if (!winner || !loser || winner.key === loser.key) return null;

    const repeats = this.meetingsBetween(winner.key, loser.key, at);
    const moved = swing(winner.points, loser.points);
    const gain = discount(moved.gain, repeats);

    const before = { winner: winner.points, loser: loser.points };
    winner.points = clampPoints(winner.points + gain);
    loser.points = clampPoints(loser.points - moved.loss);
    winner.played += 1;
    loser.played += 1;
    winner.won += 1;
    // Both names now hold a result, so neither claim is provisional any
    // more: from here the ticket is the only way back in (see claim()).
    winner.confirmed = true;
    loser.confirmed = true;

    this.noteMeeting(winner.key, loser.key, at);
    this.sweep(at);

    return {
      repeats,
      winner: {
        name: winner.name, key: winner.key, points: winner.points,
        gained: winner.points - before.winner,
      },
      loser: {
        name: loser.name, key: loser.key, points: loser.points,
        lost: before.loser - loser.points,
      },
    };
  }

  /*
   * The leaderboard: everybody with something to show, best first.
   *
   * Zero is filtered here rather than at the screen, because only this side
   * can tell "never won" from "lost it all back" -- both sit at zero, and
   * neither belongs on a top ten. Ties break by name so two hubs with the
   * same results answer identically and the list does not reshuffle under a
   * player reading it.
   */
  top(limit) {
    const out = [];
    for (const entry of this.entries.values()) {
      if (entry.points > 0) {
        // deliberately no tokenHash: this list goes out over the wire, and
        // the digest is nobody's business but the hub's
        out.push({
          name: entry.name, sprite: entry.sprite, points: entry.points,
          played: entry.played, won: entry.won,
        });
      }
    }
    out.sort((a, b) => (b.points - a.points) || (a.name < b.name ? -1 : 1));
    const cap = Number.isFinite(Number(limit)) ? Number(limit) : RANK_TOP;
    return out.slice(0, cap);
  }

  /*
   * Persistence, for a hub that outlives its process. A flat list, so the
   * file a host can read is the same shape src/Rank.lua exports and neither
   * side has to know the other's tables. Meetings are deliberately not
   * saved: they are a one-hour anti-farm window, and a hub that restarted
   * has already lost the sessions they belonged to.
   *
   * A row that is unproved, unplayed and still at the starting rating is not
   * written at all. Nothing is lost by that -- claim() hands such a name to
   * whoever connects next by design, so persisting it buys exactly nothing --
   * and what it stops is the file growing a row (and being rewritten) for
   * every passing hello, which on a hub anyone can dial is a connect loop with
   * a random name each time. Confirmed and scored claims are what restarting
   * has to survive, and those still travel.
   */
  export() {
    const out = [];
    for (const entry of this.entries.values()) {
      if (!entry.confirmed && entry.played <= 0 && entry.points <= RANK_START) {
        continue;
      }
      out.push({
        name: entry.name, sprite: entry.sprite, points: entry.points,
        played: entry.played, won: entry.won,
        // the digest, never the token: a hub that loses this file loses the
        // season, not everybody's identity
        tokenHash: entry.tokenHash,
        // Additive, and read back below. A hub built before this field
        // ignores it on the way in -- import() copies the fields it knows
        // and nothing else -- so a new hub's file still loads on an old one.
        confirmed: entry.confirmed,
      });
    }
    out.sort((a, b) => (b.points - a.points) || (a.name < b.name ? -1 : 1));
    return out;
  }

  /*
   * Rebuilt from whatever was on disk, which is a file a human can edit and
   * therefore a file that can be wrong. A row that is not a row is skipped
   * rather than taken down with the board: a corrupt line should cost one
   * player's rating, never everybody's.
   */
  import(rows) {
    if (!Array.isArray(rows)) return this;
    for (const row of rows) {
      if (!row || typeof row !== 'object') continue;
      const entry = this.entry(row.name);
      if (!entry) continue;
      entry.points = clampPoints(row.points);
      if (typeof row.sprite === 'string' && row.sprite) entry.sprite = row.sprite;
      entry.played = Math.max(Math.floor(Number(row.played) || 0), 0);
      entry.won = Math.max(Math.floor(Number(row.won) || 0), 0);
      // A hash that is not a hash is dropped rather than kept: rubbish in
      // this field would refuse the rightful owner forever, whereas an
      // unclaimed name can simply be claimed again.
      if (typeof row.tokenHash === 'string' && /^[0-9a-f]{64}$/.test(row.tokenHash)) {
        entry.tokenHash = row.tokenHash;
      }
      // A file written before `confirmed` existed says nothing about proof,
      // so the results decide: a name that has settled a battle is worth
      // protecting and is taken as confirmed, and one that has not stays
      // provisional -- which is the same leniency a fresh claim gets.
      entry.confirmed = typeof row.confirmed === 'boolean'
        ? row.confirmed : entry.played > 0;
    }
    return this;
  }
}

module.exports = {
  Board,
  mintToken,
  keyOf,
  clampPoints,
  expected,
  swing,
  discount,
  RANK_K,
  RANK_SCALE,
  RANK_START,
  RANK_MAX,
  RANK_TOP,
  RANK_REPEAT_WINDOW_MS,
  RANK_REPEAT_FADE,
  RANK_PAIRS_MAX,
  RANK_REPORT_GRACE_MS,
  RANK_QUERY_GATE_MS,
  RANK_TOKEN_BYTES,
};
