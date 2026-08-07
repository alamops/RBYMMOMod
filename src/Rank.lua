-- Ranked PVP: what a win is worth, and who is on top.
--
-- Pure arithmetic over plain tables.  No engine, no network, and no clock of
-- its own -- every entry point that cares about time is handed one -- so a
-- hub can own a board, the suite can play a whole season in a loop, and
-- neither has to stand a socket up to do it.
--
-- **server/lib/rank.js is the other half of this file and must stay in
-- step, number for number.**  The same player joins a game hosted from
-- inside somebody's copy and a dedicated hub on a box somewhere, and a win
-- that is worth 27 points on one and 16 on the other is not a ranking, it is
-- two.  The suite pins the arithmetic on both sides against the same table
-- of cases for exactly that reason.
--
-- ------- what the numbers mean
--
-- Elo, with the two decisions the brief asked for on top of it.
--
-- 1. **The opponent's rating decides the size of the swing.**  Expected
--    score is the standard logistic curve, so beating somebody 400 points
--    above you pays nearly the whole of RANK_K and beating somebody 400
--    below pays almost nothing.  That is the anti-farm rule stated the way
--    Elo already states it: there is nothing to be gained from finding the
--    weakest player in the room.
--
-- 2. **Beating the same person again pays half, then a quarter, then
--    nothing.**  Elo alone does not close the loop, because two friends can
--    trade wins and stay near each other forever, each collecting the fair
--    price of an even match. So a pairing that has already been played
--    inside RANK_REPEAT_WINDOW is discounted by half per prior meeting --
--    counted in *both* directions, so alternating wins does not reset it --
--    until it reaches zero and the pair has to go and find somebody else.
--    Nobody is stopped from playing their friend; the tenth rematch in an
--    hour simply is not worth points.
--
-- A loss is the mirror of the win it came from, and is never discounted: a
-- rematch you keep losing costs full price, so a farm cannot be run from the
-- losing side either.  Points floor at zero -- the brief's rule -- which is
-- also what makes RANK_START = 0 honest: everybody begins unranked, and the
-- board only lists players who have actually won something.
--
-- A draw scores nothing.  A link battle draws when the connection dies, when
-- both sides run, or when the two simulations disagree (src/link/LinkBattle
-- endAsDraw), so paying for one would pay for pulling the cable out.

local need = ...
local Config = need("Config")
-- Only to digest a claim token.  A board stores the hash and never the token
-- itself, so a leaked ranking.json hands over nobody's name.
local Sha256 = need("Sha256")

local M = {}

local Board = {}
Board.__index = Board

-- The board is keyed by trainer name, upper-cased -- and a name is *claimed*
-- by whoever first won under it.
--
-- Keying on the connection id would reset everybody's rating on every
-- reconnect, so the name has to be the key. But a name is typed, not proved,
-- and on its own it means anybody who knows yours can put on your rating and
-- spend it. So the first time a hub sees a name it mints a secret, hands it
-- to that player once, and remembers only its digest; every later hello
-- carries the secret back and that is what says "same player".
--
-- **This is a claim ticket, not an account.** The token crosses a link with
-- no encryption on it and lives in a save file, so anyone who can read
-- either can take the name -- exactly the exposure the join code already
-- has, and the README says so in the same breath. What it does buy is that
-- typing somebody's nickname is no longer enough, which was the whole of the
-- old story.
--
-- A player who arrives without the token for a claimed name is not turned
-- away: they play, chat, trade and battle as normal, and their results
-- simply do not score. Refusing the connection would mean a lost save file
-- costs somebody the hub; scoring them into a stranger's rating would mean
-- the ticket bought nothing. And while the claim is still only *minted* --
-- never proved by a returning token, never scored under -- the name follows
-- whoever is here now rather than locking; Board:claim states why.
local function keyOf(name)
  if type(name) ~= "string" then return nil end
  local clean = name:upper():gsub("^%s+", ""):gsub("%s+$", "")
  if clean == "" then return nil end
  return clean
end

M.keyOf = keyOf

local function clampPoints(value)
  local n = tonumber(value)
  if not n or n ~= n then return 0 end
  n = math.floor(n)
  if n < 0 then return 0 end
  if n > Config.RANK_MAX then return Config.RANK_MAX end
  return n
end

M.clampPoints = clampPoints

local function round(value)
  return math.floor(value + 0.5)
end

-- The chance the first rating beats the second, on Elo's own curve.
function M.expected(a, b)
  return 1 / (1 + 10 ^ ((b - a) / Config.RANK_SCALE))
end

-- What one match moves before the rematch discount: what the winner would
-- gain, and what the loser would lose.  Two separate roundings rather than
-- one number used twice, because the pair is not symmetric once either side
-- is against the floor.
function M.swing(winnerPoints, loserPoints)
  local expected = M.expected(winnerPoints, loserPoints)
  return round(Config.RANK_K * (1 - expected)), round(Config.RANK_K * expected)
end

-- Halve per prior meeting inside the window, and stop at zero.
--
-- The exponent is capped before it is used: 2^(a few thousand) is inf, and
-- inf underneath a division is a nan that would land in somebody's score.
function M.discount(gain, repeats)
  local n = tonumber(repeats) or 0
  if n <= 0 then return gain end
  if n >= Config.RANK_REPEAT_FADE then return 0 end
  return math.floor(gain / 2 ^ n)
end

-- ------- the board

function M.newBoard(opts)
  opts = opts or {}
  return setmetatable({
    entries = {},        -- key -> { name, key, sprite, points, played, won }
    meetings = {},       -- pair key -> { timestamps }
    meetingsCount = 0,   -- how many pairs are in that table
    window = tonumber(opts.window) or Config.RANK_REPEAT_WINDOW,
    count = 0,           -- how many players it has ever seen
  }, Board)
end

function Board:entry(name)
  local key = keyOf(name)
  if not key then return nil end
  local entry = self.entries[key]
  if not entry then
    entry = { key = key, name = name, sprite = Config.DEFAULT_SPRITE,
              points = Config.RANK_START, played = 0, won = 0,
              -- the digest of whatever claimed this name, or nil for a name
              -- nobody has claimed yet
              tokenHash = nil,
              -- whether that claim was ever *proved* -- see Board:claim. A
              -- minted claim is provisional: nobody has yet shown they hold
              -- the ticket.
              confirmed = false }
    self.entries[key] = entry
    self.count = self.count + 1
  end
  return entry
end

-- ------- claiming a name

-- Who is behind this name, as far as a hub can tell.
--
-- Answers one of four words, and the caller acts on it:
--
--   "claimed"  -- the name was free, or its claim was still provisional;
--                 `fresh` now owns it and must be handed to the player,
--                 once. They score.
--   "owner"    -- the token presented matches the one on file. They score,
--                 and the claim is confirmed from here on.
--   "impostor" -- the name is claimed and this is not the holder. They play
--                 exactly as before and their battles score nothing.
--   "open"     -- the name is free and there was no token to claim it with
--                 (the hub could not mint one). They score, and the name
--                 stays claimable by whoever turns up with one next.
--
-- **A claim is provisional until it is proved.** Minting one only says a
-- ticket was posted, not that it arrived: a welcome that never reached the
-- client, a hub restarted before its file was written, or a save that never
-- carried the token to disk all leave a name claimed by nobody who can
-- present it -- and under the old rule that locked the rightful owner out of
-- their own name forever. So an unconfirmed claim on a name that has never
-- scored is transferred to whoever is connecting now. Nothing is stolen by
-- that: an unscored name holds no rating, and the owner who lost the race
-- takes it back the same way. The moment a name is proved (a returning
-- token) or worth something (a settled battle) it is confirmed, and from
-- then on the wrong ticket is refused exactly as before.
--
-- `inUse` is the caller's answer to "is somebody *ranked* connected under
-- this name right now" -- board state alone cannot see it, and without it the
-- leniency above becomes theft: a player sitting on an unproved, unscored
-- claim would have it taken from under them by the next hello for the same
-- name, and their next settled win would land on the taker's claim. Two
-- friends who never changed the default trainer name are enough to reach
-- that by accident. So a live holder is an impostor gate like `confirmed`
-- and `played`, and the reclaim this rule exists for -- where the owner is
-- not connected at all -- is untouched.
--
-- **One caller-shaped divergence from server/lib/rank.js, stated rather than
-- hidden:** the board rules below are identical, but the `fresh` these two
-- are handed is not. Hub:newToken() can answer nil (the entropy pool has no
-- state to draw from), where the node hub's crypto.randomBytes cannot fail
-- that way -- so on a reclaim with a dead pool this side answers "impostor"
-- where the node hub answers "claimed". That is the two hubs being handed
-- different arguments, not the two boards disagreeing about the same ones.
--
-- Only the digest is kept. A ranking file that leaks tells an attacker who
-- is on the board, which is public anyway, and gives them no way to be any
-- of them.
function Board:claim(name, presented, fresh, inUse)
  local entry = self:entry(name)
  if not entry then return "impostor" end

  if entry.tokenHash then
    if type(presented) == "string" and presented ~= "" then
      local hash = Sha256.hex(presented)
      -- Sha256.equals, never ==: a plain compare returns as soon as two bytes
      -- differ, which is the same leak the join-code check avoids. The value
      -- here is a digest rather than the secret, so the leak is small -- but
      -- the constant-time compare is already in the building.
      if type(hash) == "string" and Sha256.equals(entry.tokenHash, hash) then
        entry.confirmed = true
        return "owner"
      end
    end
    -- Unproved, unscored, worth nothing and nobody's right now: the claim
    -- moves rather than shutting the name. `played` is the usual test --
    -- Board:record is the only thing that raises it, and a draw is never
    -- recorded -- and `points` is the belt on top of it, so a hand-edited
    -- file with a rating but no games behind it is not a name anybody can
    -- walk into.
    if entry.confirmed or entry.played > 0
       or entry.points > Config.RANK_START then
      return "impostor"
    end
    if inUse then return "impostor" end
    if type(fresh) ~= "string" or fresh == "" then return "impostor" end
    local minted = Sha256.hex(fresh)
    if type(minted) ~= "string" then return "impostor" end
    entry.tokenHash = minted
    return "claimed"
  end

  if type(fresh) ~= "string" or fresh == "" then return "open" end
  local hash = Sha256.hex(fresh)
  if type(hash) ~= "string" then return "open" end
  entry.tokenHash = hash
  entry.confirmed = false
  return "claimed"
end

-- Has anybody claimed this name?  Read-only, and it never creates an entry:
-- asking about a name must not be what puts it on the board.
function Board:claimed(name)
  local key = keyOf(name)
  local entry = key and self.entries[key]
  return (entry and entry.tokenHash) ~= nil
end

-- A player is here, and this is what they look like today.
--
-- Called when somebody joins, so the leaderboard can show the character of a
-- player who is not online -- the alternative is a row with a blank where
-- everybody else has a portrait. It never touches points: being seen is not
-- a result.
function Board:seen(name, sprite)
  local entry = self:entry(name)
  if not entry then return nil end
  entry.name = name
  if type(sprite) == "string" and sprite ~= "" then entry.sprite = sprite end
  return entry
end

function Board:points(name)
  local key = keyOf(name)
  local entry = key and self.entries[key]
  return entry and entry.points or Config.RANK_START
end

function Board:get(name)
  local key = keyOf(name)
  return key and self.entries[key] or nil
end

-- How many times these two have already played inside the window.
--
-- One bucket per pair, not per direction: A beating B and B beating A are
-- the same two people arranging results between themselves, which is the
-- thing the discount exists to make worthless.
local function pairKey(a, b)
  if a < b then return a .. "\1" .. b end
  return b .. "\1" .. a
end

function Board:meetingsBetween(aKey, bKey, now)
  local stamps = self.meetings[pairKey(aKey, bKey)]
  if not stamps then return 0 end
  local live = 0
  for _, at in ipairs(stamps) do
    if now - at < self.window then live = live + 1 end
  end
  return live
end

-- Drop pairings nobody can be discounted for any more.
--
-- A hub that runs for a month would otherwise keep one list per pair of
-- players who ever met, forever. Cheap and rare: it only runs once the table
-- is larger than a session plausibly needs.
function Board:sweep(now)
  if self.meetingsCount <= Config.RANK_PAIRS_MAX then return end
  for key, stamps in pairs(self.meetings) do
    local kept = nil
    for _, at in ipairs(stamps) do
      if now - at < self.window then
        kept = kept or {}
        kept[#kept + 1] = at
      end
    end
    if kept then
      self.meetings[key] = kept
    else
      self.meetings[key] = nil
      self.meetingsCount = self.meetingsCount - 1
    end
  end
end

function Board:noteMeeting(aKey, bKey, now)
  local key = pairKey(aKey, bKey)
  local stamps = self.meetings[key]
  if not stamps then
    stamps = {}
    self.meetings[key] = stamps
    self.meetingsCount = self.meetingsCount + 1
  end
  -- keep the list bounded even inside one window: the discount is zero long
  -- before RANK_REPEAT_FADE meetings, so older stamps change no answer
  if #stamps >= Config.RANK_REPEAT_FADE then table.remove(stamps, 1) end
  stamps[#stamps + 1] = now
end

-- Settle one match.  Returns what changed, or nil if it was not a match
-- between two different, nameable players.
--
-- Everything about the result is decided here and nothing about *whether to
-- believe it* is: agreeing the outcome is the hub's job, and it is the part
-- a lying client attacks (see Hub.lua's mmo.result handler).
function Board:record(winnerName, loserName, now)
  now = tonumber(now) or 0
  local winner, loser = self:entry(winnerName), self:entry(loserName)
  if not (winner and loser) or winner.key == loser.key then return nil end

  local repeats = self:meetingsBetween(winner.key, loser.key, now)
  local gain, loss = M.swing(winner.points, loser.points)
  gain = M.discount(gain, repeats)

  local before = { winner = winner.points, loser = loser.points }
  winner.points = clampPoints(winner.points + gain)
  loser.points = clampPoints(loser.points - loss)
  winner.played, loser.played = winner.played + 1, loser.played + 1
  winner.won = winner.won + 1
  -- Both names now hold a result, so neither claim is provisional any more:
  -- from here the ticket is the only way back in (see Board:claim).
  winner.confirmed, loser.confirmed = true, true

  self:noteMeeting(winner.key, loser.key, now)
  self:sweep(now)

  return {
    repeats = repeats,
    winner = { name = winner.name, key = winner.key, points = winner.points,
               gained = winner.points - before.winner },
    loser = { name = loser.name, key = loser.key, points = loser.points,
              lost = before.loser - loser.points },
  }
end

-- What a side of a team battle is worth, as one number.
--
-- The mean, which is what "the strength of the pair you beat" means and the
-- standard answer wherever team ratings are kept. A strong player carrying a
-- weak one is worth about the average of the two, and beating them pays
-- accordingly -- which is the right answer, because that is who was on the
-- field.
function M.teamPoints(entries)
  local total, count = 0, 0
  for _, entry in ipairs(entries) do
    total = total + (entry.points or 0)
    count = count + 1
  end
  if count == 0 then return 0 end
  return round(total / count)
end

-- Settle a team battle: every winner against the losing side's strength, and
-- every loser against the winning side's.
--
-- **The alternative this replaces was pairing by slot index** -- first against
-- first, second against second -- which reused the 1v1 machinery unchanged and
-- was arbitrary in the way that matters: nothing about a four-way says who
-- fought whom. Both players on a side attack both players on the other, a move
-- redirects across the pair when a target falls, and the side loses together.
-- Slot one beating slot one is a fact about the order the hub happened to list
-- them in, and it produced answers nobody could defend: put your strongest
-- player in slot two and the ratings move differently for the same battle,
-- with the same four people, and the same result.
--
-- So the match each player actually played is *them against the other pair*,
-- and that is what is scored. One rated result each, the same curve and the
-- same K as a 1v1, so a co-op win is worth about what a win is worth.
--
-- The rematch discount is per player and takes the **fewest** meetings they
-- have had with anyone they just beat. Four people running the same 2-on-2 all
-- afternoon meet on every cross pair, so the discount bites exactly as it does
-- in a 1v1; bringing in somebody genuinely new means at least one opponent
-- with no history, and that fight is worth its full value to everyone in it.
--
-- Returns nil unless both sides resolve to real, distinct, non-overlapping
-- players -- the same bar `record` sets, one side wider.
function Board:recordTeam(winnerNames, loserNames, now)
  now = tonumber(now) or 0
  local winners, losers = {}, {}
  local seen = {}
  local function gather(names, into)
    for _, name in ipairs(names or {}) do
      local entry = self:entry(name)
      -- A name that will not resolve, or one that turns up twice across the
      -- four, means this is not a battle between four different people --
      -- and paying it out would move a rating twice for one result.
      if not entry or seen[entry.key] then return false end
      seen[entry.key] = true
      into[#into + 1] = entry
    end
    return #into > 0
  end
  if not gather(winnerNames, winners) then return nil end
  if not gather(loserNames, losers) then return nil end

  local winnerSide, loserSide = M.teamPoints(winners), M.teamPoints(losers)
  local gain, loss = M.swing(winnerSide, loserSide)

  -- Read before anything moves, so the discount every player gets is about
  -- the history they brought to this battle rather than one this battle has
  -- already started writing.
  local repeatsFor = {}
  for _, winner in ipairs(winners) do
    local fewest
    for _, loser in ipairs(losers) do
      local met = self:meetingsBetween(winner.key, loser.key, now)
      if fewest == nil or met < fewest then fewest = met end
    end
    repeatsFor[winner.key] = fewest or 0
  end

  local outWinners, outLosers = {}, {}
  for _, winner in ipairs(winners) do
    local before = winner.points
    winner.points = clampPoints(winner.points
      + M.discount(gain, repeatsFor[winner.key]))
    winner.played, winner.won = winner.played + 1, winner.won + 1
    outWinners[#outWinners + 1] = {
      name = winner.name, key = winner.key, points = winner.points,
      gained = winner.points - before, repeats = repeatsFor[winner.key],
    }
  end
  for _, loser in ipairs(losers) do
    local before = loser.points
    loser.points = clampPoints(loser.points - loss)
    loser.played = loser.played + 1
    outLosers[#outLosers + 1] = {
      name = loser.name, key = loser.key, points = loser.points,
      lost = before - loser.points,
    }
  end

  -- Every cross pair, because every one of them was a real opponent: a
  -- discount that only remembered one of the two would let four players farm
  -- each other by swapping which of them is "first".
  for _, winner in ipairs(winners) do
    for _, loser in ipairs(losers) do
      self:noteMeeting(winner.key, loser.key, now)
    end
  end
  self:sweep(now)

  return {
    winners = outWinners, losers = outLosers,
    winnerSide = winnerSide, loserSide = loserSide,
  }
end

-- The leaderboard: everybody with something to show, best first.
--
-- Zero is filtered out here rather than at the screen, because "unranked"
-- and "ranked bottom" are not the same fact and only this side can tell them
-- apart -- a player who has never won and one who lost everything back both
-- sit at zero, and neither belongs on a top ten.
--
-- Ties break by name so two hubs with the same results answer identically,
-- and so the list does not reshuffle under a player reading it.
function Board:top(limit)
  local out = {}
  for _, entry in pairs(self.entries) do
    if entry.points > 0 then
      -- deliberately no tokenHash: this list goes out over the wire, and
      -- the digest is nobody's business but the hub's
      out[#out + 1] = { name = entry.name, sprite = entry.sprite,
                        points = entry.points, played = entry.played,
                        won = entry.won }
    end
  end
  table.sort(out, function(a, b)
    if a.points ~= b.points then return a.points > b.points end
    return a.name < b.name
  end)
  local cap = tonumber(limit) or Config.RANK_TOP
  for i = #out, cap + 1, -1 do out[i] = nil end
  return out
end

-- ------- persistence, for a hub that outlives its process
--
-- A flat list, so the Node hub can hold the same thing in a JSON file and
-- neither side has to know the other's table layout.  Meetings are
-- deliberately *not* saved: they are a one-hour anti-farm window, and a hub
-- that restarts has already lost the sessions they belonged to.
--
-- A row that is unproved, unplayed and still at the starting rating is not
-- written at all.  Nothing is lost by that -- Board:claim hands such a name
-- to whoever connects next by design, so persisting it buys exactly nothing
-- -- and what it stops is the file growing a row (and being rewritten) for
-- every passing hello, which on a hub anyone can dial is a connect loop with
-- a random name each time.  Confirmed and scored claims are what restarting
-- has to survive, and those still travel.

function Board:export()
  local out = {}
  for _, entry in pairs(self.entries) do
    local throwaway = not entry.confirmed and entry.played <= 0
                      and entry.points <= Config.RANK_START
    if not throwaway then
      out[#out + 1] = { name = entry.name, sprite = entry.sprite,
                        points = entry.points, played = entry.played,
                        won = entry.won,
                        -- the digest, never the token: a hub that loses this
                        -- file loses the season, not everybody's identity
                        tokenHash = entry.tokenHash,
                        -- Additive, and read back below. A hub built before
                        -- this field ignores it on the way in -- import copies
                        -- the fields it knows and nothing else -- so a new
                        -- hub's file still loads on an old one.
                        confirmed = entry.confirmed }
    end
  end
  table.sort(out, function(a, b)
    if a.points ~= b.points then return a.points > b.points end
    return a.name < b.name
  end)
  return out
end

-- Rebuilt from whatever was on disk, which is a file a human can edit and
-- therefore a file that can be wrong.  A row that is not a row is skipped
-- rather than taken down with the board: a corrupt line should cost one
-- player's rating, never everybody's.
function Board:import(rows)
  if type(rows) ~= "table" then return self end
  for _, row in ipairs(rows) do
    if type(row) == "table" then
      local entry = self:entry(row.name)
      if entry then
        entry.points = clampPoints(row.points)
        if type(row.sprite) == "string" and row.sprite ~= "" then
          entry.sprite = row.sprite
        end
        entry.played = math.max(math.floor(tonumber(row.played) or 0), 0)
        entry.won = math.max(math.floor(tonumber(row.won) or 0), 0)
        -- A hash that is not a hash is dropped rather than kept: a row with
        -- rubbish in this field would refuse its rightful owner forever,
        -- whereas an unclaimed name can simply be claimed again. The length
        -- is part of the shape, and server/lib/rank.js checks the same 64:
        -- a file the two hubs read differently is two boards.
        if type(row.tokenHash) == "string" and #row.tokenHash == 64
           and row.tokenHash:match("^[0-9a-f]+$") then
          entry.tokenHash = row.tokenHash
        end
        -- A file written before `confirmed` existed says nothing about
        -- proof, so the results decide: a name that has settled a battle is
        -- worth protecting and is taken as confirmed, and one that has not
        -- stays provisional -- the same leniency a fresh claim gets.
        if type(row.confirmed) == "boolean" then
          entry.confirmed = row.confirmed
        else
          entry.confirmed = entry.played > 0
        end
      end
    end
  end
  return self
end

M.Board = Board

return M
