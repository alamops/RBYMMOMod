-- The event vocabulary a mediated Gen 2 battle speaks, frozen.
--
-- Kind-compatible with Gen 1 BattleSim/events.lua and Wire.BATTLE_EVENTS so
-- T2c can extend Wire without renaming the stream.  Sheet dialect (spa/spd)
-- rides on existing fields (amount/text/hp); new Wire keys for spa/spd are
-- T2c's job — this mirror does not invent them yet.
--
-- Every visible thing that happens in a brokered fight leaves this file as one
-- small table, and a client draws the stream rather than the state: the
-- intermediator did the rolls, so the only thing left to send is what to show.
-- Getting the *shapes* wrong is therefore not a cosmetic bug -- an event whose
-- fields the screen cannot read is a turn the two players saw differently.
--
-- **The vocabulary is mirrored from src/Wire.lua, not imported from it, and
-- that is deliberate.**  Wire owns the sanitiser (`M.BATTLE_EVENTS`,
-- `M.battleEvent`) and pulls in Config to do it; everything under
-- src/BattleSim2/ has to run with no mod facade, no Config and no engine at all,
-- because the same rules will exist a second time in JavaScript under
-- server/lib/battle2/.  A copy that can drift is the price of that.
--
-- The field whitelist is the sharp edge here.  `Wire.battleEvent` rebuilds an
-- event from a fixed set of keys, so a field invented in this directory does
-- not arrive somewhere else looking optional -- it does not arrive at all.
-- `M.build` enforces the same whitelist at the point of construction, which
-- turns "the client never showed the crit" into a failure in the sim's own
-- suite instead of a silent drop three modules downstream.
--
-- Nothing here raises, and nothing here reads a clock: an event is a value.
--
-- No love, no engine modules, no mod facade.

local need = ...            -- entry-chunk shape; this module resolves nothing

local M = {}

local floor = math.floor

-- ------------------------------------------------------------------
-- the closed set
-- ------------------------------------------------------------------
--
-- A subset of Wire.BATTLE_EVENTS, not a mirror of it exactly: adding a kind to
-- Wire does NOT automatically belong here. Adding a kind that *does* belong
-- here is still a wire change: the Node twin, Wire's whitelist and the screen
-- all have to learn it in the same version, so the set is written out longhand
-- rather than derived.
--
-- `exp` was Gen1-only for one release (docs/plans/better-battle-ui.md R5-A2);
-- docs/plans/gen2-new-battle-system.md closes that gap. It needs no PROTOCOL
-- bump because the kind already rides Wire's whitelist and carries no
-- generation tag -- the facts a faint pays out on (who fell, what level, how
-- many shares) are the same sentence in both games, and each client prices
-- them with its own generation's formula.
--
--   msg        -- a line of text for the box
--   anim       -- play a move's animation
--   damage     -- HP came off a slot
--   drain      -- ...and some of it went onto another one
--   faint      -- a slot is out
--   send       -- a slot's next monster is on the field
--   status     -- a condition was inflicted or cleared
--   stat       -- a stat stage moved
--   switch     -- a voluntary swap resolved
--   item       -- a bag item was used
--   run        -- somebody fled, or tried
--   turn       -- a new turn is open; choices are wanted
--   over       -- the field is done; an OUTCOME is coming
--   wait       -- the fight is paused on somebody, and who
--   reconnect  -- a side that had dropped is back
--   chose      -- a seat filed this turn's answer (wait-line peer accuracy)
--   unchose    -- cancel cleared a filed answer
--   moves      -- mid-fight move-list sync after Transform/Mimic
--   exp        -- a faint paid out; facts only, the client prices it
M.KINDS = {
  msg = true, anim = true, damage = true, drain = true, faint = true,
  send = true, status = true, stat = true, switch = true, item = true,
  run = true, turn = true, over = true, wait = true, reconnect = true,
  chose = true, unchose = true, moves = true, exp = true,
}

-- Every key an event may carry, and the type it carries.  `battle` and `seq`
-- are stamped by the turn machine rather than passed to `M.build`, because a
-- caller that could choose its own sequence number could put a hole in the
-- stream, and a hole is what a client reads as lost messages.
M.FIELDS = {
  battle       = "string",
  seq          = "number",
  t            = "string",
  text         = "string",
  amount       = "number",
  slot         = "number",
  hp           = "number",
  side         = "string",
  status       = "string",
  species      = "string",
  speciesId    = "string",
  level        = "number",
  participants = "number",
  mon          = "number",
}

-- ------------------------------------------------------------------
-- what each kind actually means
-- ------------------------------------------------------------------
--
-- The whitelist says what *may* be present; this table says what the turn
-- machine promises to send, so the JS twin and the screen have one place to
-- read the contract off instead of inferring it from a sim run.  Optional
-- fields are marked, and the two readings that are easy to get backwards are
-- spelled out:
--
--   * `slot` on an event is a **field slot** (0..3: side a takes 0 and 1, side
--     b takes 2 and 3) -- it is *not* the party index a `switch` choice names.
--     Same word, two numbers, and the one the event carries is always about
--     somebody who is out on the field.
--   * a `status` event with a `status` field means the condition was
--     *inflicted*; the same event with no `status` field means it **cleared**.
--     There is no "none" token in Wire's status vocabulary to say it with, and
--     `text` carries the sentence either way.
--
-- `turn` puts the 1-based turn number in `amount`, which is the only numeric
-- field it has and is compared rather than sized, so a long fight is fine.
M.SHAPES = {
  msg       = { text = true },
  anim      = { slot = true, side = true, text = "move or ball-anim id",
                amount = "shake count on SHAKE_ANIM (0-3)" },
  damage    = { slot = true, side = true, amount = true, hp = "hp left",
                status = "set when a residual dealt it" },
  drain     = { slot = true, side = true, amount = true, hp = true },
  faint     = { slot = true, side = true, text = true,
                amount = "1 when the seat still has a living bench (mustReplace)" },
  send      = { slot = true, side = true, hp = true, text = "the species",
                speciesId = "registry id for the art, when the sheet named one",
                level = "the monster's level, for the seat opposite's pill",
                mon = "party index (0-5) of the mon the referee fielded" },
  status    = { slot = true, side = true, status = "absent means cleared",
                text = true },
  stat      = { slot = true, side = true, amount = true, text = true },
  switch    = { slot = true, side = true, text = "the species coming in",
                speciesId = "registry id for the art, when the sheet named one",
                level = "the monster's level, for the seat opposite's pill",
                mon = "party index (0-5) of the mon coming in" },
  item      = { slot = true, side = true, text = "the item id",
                amount = "1 when a vitamin applied (client save writeback)" },
  run       = { slot = true, side = true, text = true },
  turn      = { amount = "the 1-based turn number",
                slot = "present only on a replacement solicitation: the field slot being asked" },
  over      = { text = "the reason token" },
  wait      = { side = true, text = "who is being waited on" },
  reconnect = { side = true, text = true },
  chose     = { slot = true, side = true, text = "who answered" },
  unchose   = { slot = true, side = true, text = "who answered" },
  moves     = { slot = true, side = true, moves = "sanitised move list" },
  exp       = { slot = "the winner being paid", species = "the monster that fell",
                speciesId = "its registry id, when the sheet named one",
                level = "its level", participants = "how many shares split it",
                mon = "party index (0-5) of the mon banking this share; absent means the active one" },
}

-- ------------------------------------------------------------------
-- field slots
-- ------------------------------------------------------------------
--
-- Mirrors Config.COOP_SIDE (PARTY_MAX, which is 2) rather than requiring it,
-- for the reason in the header.  A 1v1 uses slots 0 and 2 and leaves the odd
-- ones empty, which keeps one numbering across all three modes -- the
-- alternative, packing a 1v1 into 0 and 1, would mean a client's "which box is
-- this" changes meaning with the mode.
M.SIDE_SLOTS = 2

function M.fieldSlot(side, index)
  local base = (side == "b") and M.SIDE_SLOTS or 0
  local n = tonumber(index)
  if not n or n ~= n then n = 1 end
  return base + math.max(0, floor(n) - 1)
end

local MOVE_FIELDS = { id = "string", pp = "number", power = "number",
                      accuracy = "number", type = "number", effect = "number",
                      chance = "number" }

local function checkMove(move)
  if type(move) ~= "table" then return false end
  for key, want in pairs(MOVE_FIELDS) do
    if type(move[key]) ~= want then return false end
  end
  return true
end

local function checkMoves(value)
  if type(value) ~= "table" then return false end
  for _, move in ipairs(value) do
    if not checkMove(move) then return false end
  end
  return #value > 0
end

-- ------------------------------------------------------------------
-- construction
-- ------------------------------------------------------------------

local function coerce(key, value)
  if key == "moves" then return nil end
  local want = M.FIELDS[key]
  if want == nil then return nil end                  -- not in the whitelist
  if want == "number" then
    local n = tonumber(value)
    if not n or n ~= n then return nil end
    return floor(n)
  end
  if type(value) ~= "string" or value == "" then return nil end
  return value
end

-- Builds one event, keeping only whitelisted keys that carry a usable value.
--
-- Returns nil for an unknown kind rather than raising: this runs downstream of
-- a mod callback, and a battle that stops mid-turn over an event nobody could
-- have drawn is a worse outcome than a battle missing one line of narration.
-- The caller that cares -- the turn machine -- treats nil as "do not emit" and
-- carries on, and the suite asserts nil never happens for the kinds it sends.
function M.build(kind, fields)
  if not M.KINDS[kind] then return nil end
  local out = { t = kind }
  if type(fields) == "table" then
    for key, value in pairs(fields) do
      if key == "moves" and type(value) == "table" then
        out.moves = value
      elseif key ~= "t" and key ~= "battle" and key ~= "seq" then
        local clean = coerce(key, value)
        if clean ~= nil then out[key] = clean end
      end
    end
  end
  return out
end

-- True when an event is something Wire would accept: a known kind, a stamped
-- battle and seq, and not one stray key.  Used by the suite, and cheap enough
-- for a hub to assert on in a debug build.
function M.check(event)
  if type(event) ~= "table" then return false, "not a table" end
  if not M.KINDS[event.t] then return false, "unknown kind" end
  if type(event.battle) ~= "string" or event.battle == "" then
    return false, "no battle id"
  end
  if type(event.seq) ~= "number" or event.seq < 0 then return false, "no seq" end
  for key, value in pairs(event) do
    if key == "moves" then
      if not checkMoves(value) then return false, "bad moves list" end
    else
      local want = M.FIELDS[key]
      if want == nil then return false, "field not in the whitelist: " .. tostring(key) end
      if type(value) ~= want then return false, "wrong type for " .. tostring(key) end
    end
  end
  return true
end

return M
