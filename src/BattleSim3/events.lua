-- The event vocabulary a mediated Gen 3 battle speaks, frozen.
--
-- Contract C5 (docs/plans/gen3-battle-sheet.md §7).  Every BattleSim2 kind is
-- kept verbatim -- same name, same fields, same meaning -- so a client that
-- draws a Gen 2 stream already draws most of a Gen 3 one.  Gen 3 adds seven kinds
-- (`ability weather held form sub ball obey`) and six fields (`target spread
-- stat stage delta holding`), each for a thing the cart shows that the older
-- vocabulary cannot say: an ability acting, the weather, a held item doing
-- something (and what the mon is left holding), a picture change, the
-- substitute doll, a ball's shakes, a mon disobeying its trainer.
--
-- Mirrored, not imported, for the reason BattleSim2/events.lua gives: this
-- directory runs with no Config, no Wire and no engine, because the same rules
-- exist a second time in JavaScript under server/lib/battle3/.  Wire's
-- whitelist (T7) has to learn the new kinds and fields in the same version.
--
-- `M.build` enforces the field whitelist at construction, so an invented field
-- fails the sim's own suite instead of vanishing at the Wire boundary.
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
-- BattleSim2's twenty, then Gen 3's seven:
--
--   ability  -- an ability visibly acted (amount = ability id, text = its name)
--   weather  -- weather started (amount 1), continues (2) or ended (0);
--               text = RAIN | SUN | SAND | HAIL
--   held     -- a held item acted; `holding` is what the mon holds afterwards
--               (0 = nothing) and is the client's save writeback
--   form     -- the battler's picture changed: Castform (amount = form 0..3)
--               or Transform (speciesId + text)
--   sub      -- the substitute doll went up (amount 1) or faded (amount 0)
--   ball     -- one throw: target = the wild slot, amount = shakes 0..3, or 4
--               when caught; text = the ball's item id
--   obey     -- a mon disobeyed (docs/plans/gen3-badge-rules.md K3): text = the
--               outcome token (Move.lua Bm:_disobey; the sheet doc §7.2 maps
--               each to its cart line), always followed by our `msg`
M.KINDS = {
  msg = true, anim = true, damage = true, drain = true, faint = true,
  send = true, status = true, stat = true, switch = true, item = true,
  run = true, turn = true, over = true, wait = true, reconnect = true,
  chose = true, unchose = true, moves = true, exp = true, team = true,
  ability = true, weather = true, held = true, form = true, sub = true, ball = true,
  obey = true,
}

-- Every key an event may carry, and its type.  `battle` / `seq` are stamped by
-- the turn machine, never passed in.  The last six are Gen 3's:
--
--   target   number  a field slot the event is aimed at (anim, ball)
--   spread   number  1 when one move animation covers several targets
--   stat     string  atk | def | spe | spa | spd | acc | eva
--   stage    number  the resulting stat stage, -6..6
--   delta    number  the stage change actually applied, -12..12
--   holding  number  the held item id after a `held` event (0 = none)
M.FIELDS = {
  battle       = "string",
  seq          = "number",
  t            = "string",
  text         = "string",
  amount       = "number",
  slot         = "number",
  hp           = "number",
  maxHp        = "number",
  side         = "string",
  status       = "string",
  species      = "string",
  speciesId    = "string",
  level        = "number",
  participants = "number",
  mon          = "number",
  team         = "string",
  confused     = "number",
  target       = "number",
  spread       = "number",
  stat         = "string",
  stage        = "number",
  delta        = "number",
  holding      = "number",
}

-- What each kind promises (docs/plans/gen3-battle-sheet.md §7 is the prose).
M.SHAPES = {
  msg       = { text = true },
  anim      = { slot = true, side = true, text = "move id", amount = "1 on a charge turn",
                target = "the move's first target (field slot), when it has one",
                spread = "1 when the animation covers several targets" },
  damage    = { slot = true, side = true, amount = true, hp = "hp left",
                status = "set when a residual dealt it" },
  drain     = { slot = true, side = true, amount = true, hp = true },
  faint     = { slot = true, side = true, text = true,
                amount = "1 when the seat still has a living bench (mustReplace)" },
  send      = { slot = true, side = true, hp = true, maxHp = true, text = "the species",
                speciesId = true, level = true, mon = "party index", status = true,
                confused = true },
  status    = { slot = true, side = true, status = "absent means cleared", text = true,
                confused = "1 inflicted, 0 snapped out" },
  stat      = { slot = true, side = true, text = true, stat = true, stage = true, delta = true },
  switch    = { slot = true, side = true, text = true, speciesId = true, level = true, mon = true },
  item      = { slot = true, side = true, text = "the numeric item id, as a string" },
  run       = { slot = true, side = true, text = true },
  turn      = { amount = "the 1-based turn number",
                slot = "present only on a replacement solicitation" },
  over      = { text = "the reason token" },
  wait      = { side = true, text = true },
  reconnect = { side = true, text = true },
  chose     = { slot = true, side = true, text = true },
  unchose   = { slot = true, side = true, text = true },
  moves     = { slot = true, side = true, moves = "Gen 3 move rows",
                mon = "party index on a PP change; absent on a Transform / Mimic overlay" },
  exp       = { slot = true, species = true, speciesId = true, level = true,
                participants = true, mon = true },
  team      = { slot = true, side = true, team = "o / s / x per party member" },
  ability   = { slot = true, side = true, amount = "ability id", text = "ability name" },
  weather   = { text = "RAIN | SUN | SAND | HAIL", amount = "1 start, 2 continue, 0 end",
                slot = "who started it", side = "who started it" },
  held      = { slot = true, side = true, mon = "party index", amount = "the item that acted",
                holding = "held item id afterwards (0 none)", text = "item name" },
  form      = { slot = true, side = true, amount = "Castform form 0..3",
                speciesId = "Transform: the copied species", text = "Transform: its name" },
  sub       = { slot = true, side = true, amount = "1 made, 0 faded" },
  ball      = { slot = "thrower", side = true, target = "wild slot",
                amount = "shakes 0..3, 4 = caught", text = "ball item id" },
  obey      = { slot = true, side = true, text = "the outcome token" },
}

-- ------------------------------------------------------------------
-- field slots (BattleSim2's numbering, unchanged)
-- ------------------------------------------------------------------

M.SIDE_SLOTS = 3

function M.fieldSlot(side, index)
  local base = (side == "b") and M.SIDE_SLOTS or 0
  local n = tonumber(index)
  if not n or n ~= n then n = 1 end
  return base + math.max(0, floor(n) - 1)
end

-- ------------------------------------------------------------------
-- team rosters (token-for-token with BattleSim2)
-- ------------------------------------------------------------------

M.TEAM_OK      = "o"
M.TEAM_STATUS  = "s"
M.TEAM_FAINTED = "x"
M.TEAM_TOKENS  = { o = true, s = true, x = true }

function M.teamToken(mon)
  if type(mon) ~= "table" then return nil end
  if (tonumber(mon.hp) or 0) <= 0 then return M.TEAM_FAINTED end
  local status = mon.status
  if type(status) == "string" and status ~= "" then return M.TEAM_STATUS end
  return M.TEAM_OK
end

function M.teamString(mons)
  if type(mons) ~= "table" then return "" end
  local out = {}
  for i = 1, #mons do
    out[i] = M.teamToken(mons[i]) or M.TEAM_FAINTED
  end
  return table.concat(out)
end

-- ------------------------------------------------------------------
-- move rows on a `moves` event
-- ------------------------------------------------------------------

local MOVE_FIELDS = {
  id = "string", num = "number", pp = "number", maxPp = "number", power = "number",
  accuracy = "number", type = "number", effect = "number", chance = "number",
  target = "number", priority = "number", flags = "number",
}
M.MOVE_FIELDS = MOVE_FIELDS

local function checkMove(move)
  if type(move) ~= "table" then return false end
  for key, want in pairs(MOVE_FIELDS) do
    if type(move[key]) ~= want then return false end
  end
  if move.name ~= nil and type(move.name) ~= "string" then return false end
  for key in pairs(move) do
    if key ~= "name" and MOVE_FIELDS[key] == nil then return false end
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
  if want == nil then return nil end
  if want == "number" then
    local n = tonumber(value)
    if not n or n ~= n then return nil end
    return floor(n)
  end
  if type(value) ~= "string" or value == "" then return nil end
  return value
end

-- Builds one event, keeping only whitelisted keys that carry a usable value;
-- nil for an unknown kind (the turn machine treats nil as "do not emit").
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

-- True when an event is one Wire (with the Gen 3 additions) would accept.
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
