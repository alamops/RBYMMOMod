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
/*
 * The board is keyed by persistent playerId (32 lowercase hex) — PROTOCOL 16.
 * Display name is cosmetic on the entry and can collide; the id cannot.
 *
 * Keying on the connection id would reset everybody's rating on every
 * reconnect. Keying on trainer name required claim tickets (not accounts).
 * A client-minted playerId that survives CONTINUE is closer to an account:
 * same id → same rating; duplicate live connections with the same id are
 * refused at admit.
 */
function keyOf(id) {
  if (typeof id !== 'string') return null;
  const clean = id.toLowerCase().replace(/\s+/g, '');
  if (clean.length !== 32) return null;
  return /^[0-9a-f]+$/.test(clean) ? clean : null;
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

/*
 * What a side of a team battle is worth, as one number.
 *
 * The mean, which is what "the strength of the pair you beat" means and the
 * standard answer wherever team ratings are kept. A strong player carrying a
 * weak one is worth about the average of the two, and beating them pays
 * accordingly -- which is the right answer, because that is who was on the
 * field. Mirrors src/Rank.lua's M.teamPoints.
 */
function teamPoints(entries) {
  let total = 0;
  let count = 0;
  for (const entry of entries) {
    total += entry.points || 0;
    count += 1;
  }
  if (!count) return 0;
  return Math.floor(total / count + 0.5);
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

  entry(id) {
    const key = keyOf(id);
    if (!key) return null;
    let found = this.entries.get(key);
    if (!found) {
      found = {
        key, name: null, sprite: null, points: RANK_START, played: 0, won: 0,
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
  seen(id, name, sprite) {
    const entry = this.entry(id);
    if (!entry) return null;
    if (typeof name === 'string' && name) entry.name = name;
    if (typeof sprite === 'string' && sprite) entry.sprite = sprite;
    return entry;
  }

  points(id) {
    const key = keyOf(id);
    const entry = key && this.entries.get(key);
    return entry ? entry.points : RANK_START;
  }

  get(id) {
    const key = keyOf(id);
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
  record(winnerId, loserId, now) {
    const at = Number(now) || 0;
    const winner = this.entry(winnerId);
    const loser = this.entry(loserId);
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
   * Settle a team battle: every winner against the losing side's strength,
   * and every loser against the winning side's.
   *
   * **This replaces pairing by slot index** -- first against first, second
   * against second -- which reused the 1v1 machinery unchanged and was
   * arbitrary in the way that matters: nothing about a four-way says who
   * fought whom. Both players on a side attack both players on the other, a
   * move redirects across the pair when a target falls, and the side loses
   * together. Slot one beating slot one is a fact about the order the hub
   * happened to list them in, and it produced answers nobody could defend:
   * put your strongest player in the other seat and the ratings move
   * differently for the same battle, with the same four people and the same
   * result.
   *
   * So the match each player actually played is *them against the other
   * pair*, and that is what is scored -- one rated result each, the same
   * curve and the same K as a 1v1.
   *
   * The rematch discount is per player and takes the fewest meetings they
   * have had with anyone they just beat. Four people running the same 2-on-2
   * all afternoon meet on every cross pair, so it bites exactly as it does in
   * a 1v1; bringing in somebody genuinely new means at least one opponent
   * with no history, and that fight is worth its full value.
   *
   * Mirrors src/Rank.lua's recordTeam. The two must not drift.
   */
  recordTeam(winnerIds, loserIds, now) {
    const at = Number(now) || 0;
    const seen = new Set();
    const gather = (ids) => {
      const out = [];
      for (const id of ids || []) {
        const entry = this.entry(id);
        // An id that will not resolve, or one that turns up twice across the
        // four, means this is not a battle between four different people --
        // and paying it out would move a rating twice for one result.
        if (!entry || seen.has(entry.key)) return null;
        seen.add(entry.key);
        out.push(entry);
      }
      return out.length ? out : null;
    };
    const winners = gather(winnerIds);
    if (!winners) return null;
    const losers = gather(loserIds);
    if (!losers) return null;

    const winnerSide = teamPoints(winners);
    const loserSide = teamPoints(losers);
    const moved = swing(winnerSide, loserSide);

    // Read before anything moves, so the discount is about the history each
    // player brought to this battle rather than one it has already written.
    const repeatsFor = new Map();
    for (const winner of winners) {
      let fewest = null;
      for (const loser of losers) {
        const met = this.meetingsBetween(winner.key, loser.key, at);
        if (fewest === null || met < fewest) fewest = met;
      }
      repeatsFor.set(winner.key, fewest || 0);
    }

    const outWinners = [];
    const outLosers = [];
    for (const winner of winners) {
      const before = winner.points;
      winner.points = clampPoints(
        winner.points + discount(moved.gain, repeatsFor.get(winner.key)));
      winner.played += 1;
      winner.won += 1;
      outWinners.push({
        name: winner.name, key: winner.key, points: winner.points,
        gained: winner.points - before, repeats: repeatsFor.get(winner.key),
      });
    }
    for (const loser of losers) {
      const before = loser.points;
      loser.points = clampPoints(loser.points - moved.loss);
      loser.played += 1;
      outLosers.push({
        name: loser.name, key: loser.key, points: loser.points,
        lost: before - loser.points,
      });
    }

    // Every cross pair, because every one of them was a real opponent: a
    // discount that only remembered one of the two would let four players
    // farm each other by swapping which of them is "first".
    for (const winner of winners) {
      for (const loser of losers) this.noteMeeting(winner.key, loser.key, at);
    }
    this.sweep(at);

    return { winners: outWinners, losers: outLosers, winnerSide, loserSide };
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
        // `id` is the persistent playerId (PROTOCOL 16) so duplicate display
        // names can be told apart on RANK / CLI. No tokenHash on the wire.
        out.push({
          id: entry.key,
          name: entry.name, sprite: entry.sprite, points: entry.points,
          played: entry.played, won: entry.won,
        });
      }
    }
    out.sort((a, b) => (b.points - a.points)
      || ((a.name || '').localeCompare(b.name || ''))
      || ((a.id || '').localeCompare(b.id || '')));
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
   * A row with nothing played and still at the starting rating is not written
   * at all. What restarting has to survive is scored history.
   */
  export() {
    const out = [];
    for (const entry of this.entries.values()) {
      if (entry.played <= 0 && entry.points <= RANK_START) continue;
      out.push({
        id: entry.key,
        name: entry.name,
        sprite: entry.sprite,
        points: entry.points,
        played: entry.played,
        won: entry.won,
      });
    }
    out.sort((a, b) => (b.points - a.points)
      || ((a.name || a.id || '').localeCompare(b.name || b.id || ''))
      || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    return out;
  }

  /*
   * Rebuilt from whatever was on disk. PROTOCOL 16 rows carry `id` (playerId).
   * Legacy name-keyed rows without a 32-hex id are skipped -- a season reset,
   * not a silent merge into the wrong identity.
   */
  import(rows) {
    if (!Array.isArray(rows)) return this;
    for (const row of rows) {
      if (!row || typeof row !== 'object') continue;
      if (!row.id) continue;
      const entry = this.entry(row.id);
      if (!entry) continue;
      entry.points = clampPoints(row.points);
      if (typeof row.name === 'string' && row.name) entry.name = row.name;
      if (typeof row.sprite === 'string' && row.sprite) entry.sprite = row.sprite;
      entry.played = Math.max(Math.floor(Number(row.played) || 0), 0);
      entry.won = Math.max(Math.floor(Number(row.won) || 0), 0);
    }
    return this;
  }
}

module.exports = {
  Board,
  teamPoints,
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
};
