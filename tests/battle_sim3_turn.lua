-- src/BattleSim3/Turn.lua against the Gen 3 whole-turn parity fixture.
--
-- Run: luajit tests/battle_sim3_turn.lua            (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim3_turn.lua  (from the engine)
-- Regenerate the expectations after a deliberate rule change:
--      luajit tests/battle_sim3_turn.lua --update
--
-- tests/fixtures/battle3_turn_parity.json holds SCRIPTS, not just answers: each
-- scenario is `create` (the Turn.create options, verbatim) plus `steps`, and
-- `expect` is what src/BattleSim3 produced for it.  That is what makes the
-- fixture runtime-agnostic -- the Node twin (server/lib/battle3, wave 3) replays
-- the same steps against Turn.js and compares, event for event, without a
-- mirrored copy of any scenario (the Gen 2 pair keeps its scenarios twice; this
-- one keeps them once).
--
-- The step vocabulary (all a replayer needs):
--
--   { op = "drain" }                           drainEvents(); append the events,
--                                              append the count to `batches`
--   { op = "submit", player, choice }          submitChoice -> `results`
--   { op = "auto", player }                    autoPick -> `results`
--   { op = "tick", now }                       tick(now) -> `results`
--   { op = "levelup", player, mon, level, stats, maxHp } -> `results`
--   { op = "disconnect" | "reconnect", player } -> `results`
--   { op = "repeat", times, untilOver, steps } run `steps` `times` times,
--                                              stopping first when untilOver and
--                                              outcome() is set
--   { op = "waiting" }                         snapshot().waiting -> `results`
--   { op = "seats", player }                   the seat ids of seatsOf(player)
--                                              -> `results`
--   { op = "palaceLow", slot }                 battle:palaceLow(slot) -> `results`
--   { op = "arena" }                           snapshot().arena (the Battle
--                                              Arena's tallies) -> `results`
--
-- `create.typeTable == "$chart"` / `create.movePool == "$pool"` are replaced by
-- the fixture's shared `typeTable` / `movePool` before Turn.create.
--
-- A scenario with `refuses` is a create that must be refused, for exactly that
-- reason; it has no steps and no `expect`.
--
-- `expect` = { events, batches, results, outcome, snapshot }, where outcome is
-- { battle, outcome, reason, winners?, losers?, catcher?, caughtSpecies?,
-- payDay?, how?, by?, given?, safari?, judged? } and snapshot is
-- the digest { phase, turn, seq, now, deadline, rngState, weather, field =
-- [{ slot, hp, party }] } -- rngState is the one number that proves both
-- runtimes drew the same count.  Events compare as canonical JSON (sorted keys),
-- so key order never matters and a missing or extra field always does.
--
-- Standalone (no engine, no love, no mod facade), like the vector suite.
-- Synthetic throughout: every species, move and number is invented.

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
end
local UPDATE = false
for i = 1, #(arg or {}) do
  if arg[i] == "--update" then UPDATE = true end
end

local function slurp(path)
  local handle = io.open(path, "rb")
  if not handle then return nil end
  local body = handle:read("*a")
  handle:close()
  return body
end

local loadstr = loadstring or load
local cache = {}
local function need(name)
  if cache[name] ~= nil then return cache[name] end
  local path = ROOT .. "/src/" .. name .. ".lua"
  local body = slurp(path)
  if not body then
    io.stderr:write("battle_sim3_turn: missing " .. path .. "\n")
    os.exit(1)
  end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim3_turn: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local Sim = need("BattleSim3/init")
local Turn, Events = Sim.Turn, Sim.Events

-- ------------------------------------------------------------------
-- JSON: a reader (null -> NULL) and a canonical writer (sorted keys)
-- ------------------------------------------------------------------

local NULL = setmetatable({}, { __tostring = function() return "null" end })
local OBJECT = {}   -- metatable marking an empty table that must encode as {}

local decodeValue

local function skipSpace(text, i)
  local _, stop = text:find("^[ \t\r\n]*", i)
  return stop + 1
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decodeString(text, i)
  local out, pos = {}, i + 1
  while true do
    local c = text:sub(pos, pos)
    if c == "" then error("unterminated string at " .. i, 0) end
    if c == '"' then return table.concat(out), pos + 1 end
    if c == "\\" then
      local esc = text:sub(pos + 1, pos + 1)
      if esc == "u" then error("\\u escapes are not supported by this reader", 0) end
      out[#out + 1] = ESCAPES[esc] or esc
      pos = pos + 2
    else
      out[#out + 1] = c
      pos = pos + 1
    end
  end
end

local function decodeNumber(text, i)
  local literal = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  return tonumber(literal), i + #literal
end

local function decodeArray(text, i)
  local out, pos = {}, skipSpace(text, i + 1)
  if text:sub(pos, pos) == "]" then return out, pos + 1 end
  while true do
    local value
    value, pos = decodeValue(text, pos)
    out[#out + 1] = value
    pos = skipSpace(text, pos)
    local c = text:sub(pos, pos)
    if c == "]" then return out, pos + 1 end
    if c ~= "," then error("expected , or ] at " .. pos, 0) end
    pos = skipSpace(text, pos + 1)
  end
end

local function decodeObject(text, i)
  local out, pos = setmetatable({}, OBJECT), skipSpace(text, i + 1)
  if text:sub(pos, pos) == "}" then return out, pos + 1 end
  while true do
    local key, value
    key, pos = decodeString(text, pos)
    pos = skipSpace(text, pos)
    if text:sub(pos, pos) ~= ":" then error("expected : at " .. pos, 0) end
    value, pos = decodeValue(text, skipSpace(text, pos + 1))
    out[key] = value
    pos = skipSpace(text, pos)
    local c = text:sub(pos, pos)
    if c == "}" then return out, pos + 1 end
    if c ~= "," then error("expected , or } at " .. pos, 0) end
    pos = skipSpace(text, pos + 1)
  end
end

function decodeValue(text, i)
  i = skipSpace(text, i)
  local c = text:sub(i, i)
  if c == "{" then return decodeObject(text, i) end
  if c == "[" then return decodeArray(text, i) end
  if c == '"' then return decodeString(text, i) end
  if text:sub(i, i + 3) == "true" then return true, i + 4 end
  if text:sub(i, i + 4) == "false" then return false, i + 5 end
  if text:sub(i, i + 3) == "null" then return NULL, i + 4 end
  return decodeNumber(text, i)
end

local function encString(s)
  return '"' .. s:gsub('[%c"\\]', function(ch)
    if ch == '"' then return '\\"' end
    if ch == '\\' then return '\\\\' end
    if ch == '\n' then return '\\n' end
    if ch == '\t' then return '\\t' end
    return string.format('\\u%04x', ch:byte())
  end) .. '"'
end

local function isArray(t)
  if getmetatable(t) == OBJECT then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local encode
function encode(v)
  if v == nil or v == NULL then return "null" end
  local t = type(v)
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if t == "string" then return encString(v) end
  if next(v) == nil then return (getmetatable(v) == OBJECT) and "{}" or "[]" end
  if isArray(v) then
    local parts = {}
    for i = 1, #v do parts[i] = encode(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = encString(k) .. ":" .. encode(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- A decoded value back into plain Lua (NULL -> nil), for Turn.create.
local function plain(v)
  if v == NULL then return nil end
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    if x ~= NULL then out[k] = plain(x) end
  end
  return out
end

-- ------------------------------------------------------------------
-- replay
-- ------------------------------------------------------------------

local FIXTURE = ROOT .. "/tests/fixtures/battle3_turn_parity.json"
local raw = slurp(FIXTURE)
if not raw then
  io.stderr:write("battle_sim3_turn: missing " .. FIXTURE .. "\n")
  os.exit(1)
end
local fixture = decodeValue(raw, 1)

local function digest(battle)
  local snap = battle:snapshot()
  local field = {}
  for _, entry in ipairs(snap.field) do
    field[#field + 1] = { slot = entry.slot, hp = entry.hp, party = entry.party }
  end
  return {
    phase = snap.phase, turn = snap.turn, seq = snap.seq, now = snap.now,
    deadline = snap.deadline or NULL, rngState = snap.rngState,
    weather = snap.weather or NULL, field = field,
  }
end

local function outcomeOf(out)
  if not out then return NULL end
  local o = { battle = out.battle, outcome = out.outcome, reason = out.reason }
  if out.winners then o.winners = out.winners end
  if out.losers then o.losers = out.losers end
  if out.catcher then o.catcher = out.catcher end
  if out.caught then o.caughtSpecies = out.caught.species end
  if out.payDay then o.payDay = out.payDay end
  -- contract C3 (docs/plans/gen3-solo-remaining-fights.md): how it ended, by whom
  if out.how then o.how = out.how end
  if out.by then o.by = out.by end
  -- wave 2 of contract C3: a forced catch's `given = false`, a Safari's spend
  if out.given ~= nil then o.given = out.given end
  if out.safari then o.safari = out.safari end
  -- wave 3: the Battle Arena's judged losers, by sheet slot
  if out.judged then o.judged = out.judged end
  return o
end

local function run(scn)
  local opts = plain(scn.create)
  if opts.typeTable == "$chart" then opts.typeTable = plain(fixture.typeTable) end
  if opts.movePool == "$pool" then opts.movePool = plain(fixture.movePool) end
  local battle, reason = Turn.create(opts)
  if not battle then return { refused = reason } end
  local got = { events = {}, batches = {}, results = {} }
  local bad = {}
  local function drain()
    local list = battle:drainEvents()
    for _, e in ipairs(list) do
      local ok, why = Events.check(e)
      if not ok then bad[#bad + 1] = tostring(e.seq) .. ": " .. tostring(why) end
      got.events[#got.events + 1] = e
    end
    got.batches[#got.batches + 1] = #list
  end
  local exec
  exec = function(steps)
    for _, st in ipairs(steps) do
      if st.op == "drain" then drain()
      elseif st.op == "submit" then got.results[#got.results + 1] = battle:submitChoice(st.player, plain(st.choice))
      elseif st.op == "auto" then got.results[#got.results + 1] = battle:autoPick(st.player)
      elseif st.op == "tick" then got.results[#got.results + 1] = battle:tick(st.now)
      elseif st.op == "levelup" then
        got.results[#got.results + 1] = battle:levelUp(st.player, st.mon, st.level, plain(st.stats), st.maxHp)
      elseif st.op == "disconnect" then got.results[#got.results + 1] = battle:disconnect(st.player)
      elseif st.op == "reconnect" then got.results[#got.results + 1] = battle:reconnect(st.player)
      elseif st.op == "waiting" then got.results[#got.results + 1] = battle:snapshot().waiting
      elseif st.op == "seats" then
        local ids = {}
        for i, seat in ipairs(battle:seatsOf(st.player)) do ids[i] = seat.playerId end
        got.results[#got.results + 1] = ids
      elseif st.op == "palaceLow" then
        got.results[#got.results + 1] = battle:palaceLow(st.slot)
      elseif st.op == "arena" then
        got.results[#got.results + 1] = battle:snapshot().arena or false
      elseif st.op == "repeat" then
        for _ = 1, st.times do
          if st.untilOver and battle:outcome() then break end
          exec(st.steps)
        end
      else
        error("unknown step op " .. tostring(st.op), 0)
      end
    end
  end
  exec(scn.steps or {})
  got.outcome = outcomeOf(battle:outcome())
  got.snapshot = digest(battle)
  got.badEvents = bad
  return got
end

-- ------------------------------------------------------------------
-- compare / update
-- ------------------------------------------------------------------

local passed, failed = 0, 0
local function fail(name, what)
  failed = failed + 1
  io.stderr:write("FAIL " .. name .. ": " .. what .. "\n")
end

local results = {}
for index, scn in ipairs(fixture.scenarios) do
  local ok, got = pcall(run, scn)
  if not ok then
    fail(scn.name, "threw: " .. tostring(got))
    results[index] = nil
  elseif scn.refuses ~= nil then
    if got.refused ~= scn.refuses then
      fail(scn.name, "create\n  expected refusal " .. encode(scn.refuses) .. "\n  got      " ..
        encode(got.refused or "a battle"))
    else
      passed = passed + 1
    end
  elseif got.refused then
    fail(scn.name, "create refused: " .. tostring(got.refused))
  else
    results[index] = got
    for _, why in ipairs(got.badEvents) do fail(scn.name, "event outside the C5 whitelist: " .. why) end
    if not UPDATE then
      local exp = scn.expect
      if type(exp) ~= "table" then
        fail(scn.name, "no expect block (run with --update)")
      else
        local n = math.max(#exp.events, #got.events)
        local shown = 0
        for i = 1, n do
          local a, b = encode(exp.events[i]), encode(got.events[i])
          if a ~= b then
            if shown < 3 then fail(scn.name, "event " .. i .. "\n  expected " .. a .. "\n  got      " .. b) end
            shown = shown + 1
          else
            passed = passed + 1
          end
        end
        for _, key in ipairs({ "batches", "results", "outcome", "snapshot" }) do
          local a, b = encode(exp[key]), encode(got[key])
          if a ~= b then fail(scn.name, key .. "\n  expected " .. a .. "\n  got      " .. b)
          else passed = passed + 1 end
        end
      end
    end
  end
end

-- ------------------------------------------------------------------
-- contract C-W: WALLY's throw (docs/plans/gen3-solo-remaining-fights.md,
-- wave 4b), asserted on the replay itself -- what each w4b_wally_cw_* script
-- must show whatever `--update` wrote, so a regenerated `expect` can never
-- bless a turn order pret does not have.  pokeemerald battle_main.c:4819
-- sorts B_ACTION_WALLY_THROW with the moves at priority 0 (MOVE_NONE, :4706);
-- battle_util.c:625 HandleAction_WallyBallThrow sets gActionsByTurnOrder[1] =
-- B_ACTION_FINISHED.
-- ------------------------------------------------------------------

do
  local byName = {}
  for index, scn in ipairs(fixture.scenarios) do byName[scn.name] = results[index] end
  local function check(cond, name, what)
    if cond then passed = passed + 1 else fail(name, what) end
  end
  -- The 1-based position of the first event `pred` takes, after `from`.
  local function at(got, pred, from)
    for i = (from or 0) + 1, #got.events do
      if pred(got.events[i]) then return i end
    end
    return nil
  end
  local function isThrow(e) return e.t == "wallyThrow" end
  local function used(who) return function(e) return e.t == "msg" and e.text:find("^" .. who .. " used ") ~= nil end end
  local function turnOf(n) return function(e) return e.t == "turn" and e.amount == n and e.slot == nil end end
  local function count(got, pred)
    local n = 0
    for _, e in ipairs(got.events) do if pred(e) then n = n + 1 end end
    return n
  end
  local function scenario(name)
    local got = byName[name]
    if not got then fail(name, "C-W: scenario missing from the fixture or refused") end
    return got
  end

  -- Thrown first: the event names WALLY's field slot (no seat id rides), and
  -- the foe never acts that turn.
  local got = scenario("w4b_wally_cw_throw_first")
  if got then
    local t3, t4 = at(got, turnOf(3)), at(got, turnOf(4))
    local thr = at(got, isThrow)
    check(t3 and thr and t4 and t3 < thr and thr < t4, "w4b_wally_cw_throw_first",
      "C-W: the throw runs in turn 3, and turn 4 opens after it")
    local ev = thr and got.events[thr] or {}
    check(ev.seat == nil and ev.slot == 0 and ev.side == "a", "w4b_wally_cw_throw_first",
      "C-W: wallyThrow { slot = 0, side = a }, no seat")
    check(t3 and t4 and (at(got, used("RALTS"), t3) or math.huge) > t4, "w4b_wally_cw_throw_first",
      "C-W: thrown first, the foe's slot is cancelled -- no RALTS move in turn 3")
    check(count(got, isThrow) == 1, "w4b_wally_cw_throw_first", "C-W: one throw, one event")
    check(got.outcome.how == "catch" and got.outcome.given == false, "w4b_wally_cw_throw_first",
      "C-W: turn 4's ball is the forced catch")
  end
  -- The foe first (faster, a tie it wins, a +1 move, a QUICK CLAW): it acts,
  -- then the throw; the turn then ends.
  for _, name in ipairs({ "w4b_wally_cw_foe_first", "w4b_wally_cw_tie_foe_first",
                          "w4b_wally_cw_priority_foe", "w4b_wally_cw_quick_claw_foe" }) do
    got = scenario(name)
    if got then
      local foe, thr, t2 = at(got, used("RALTS")), at(got, isThrow), at(got, turnOf(2))
      check(foe and thr and t2 and foe < thr and thr < t2, name,
        "C-W: the foe acts first, then the throw, then turn 2")
    end
  end
  -- The throw first (a tie it wins, a foe's -6 move): the foe is silent.
  for _, name in ipairs({ "w4b_wally_cw_tie_throw_first", "w4b_wally_cw_negative_priority_foe" }) do
    got = scenario(name)
    if got then
      local thr, t2 = at(got, isThrow), at(got, turnOf(2))
      check(thr and t2 and thr < t2 and at(got, used("RALTS")) == nil, name,
        "C-W: thrown first, the foe never acts that turn")
    end
  end
  -- A thrower knocked out before its turn throws nothing.
  got = scenario("w4b_wally_cw_thrower_down")
  if got then
    check(count(got, isThrow) == 0 and got.outcome.how == "ko", "w4b_wally_cw_thrower_down",
      "C-W: no throw from a fainted thrower; the fight is lost")
  end
  -- The SECOND slot, whoever holds it: the faster partner is cancelled, the
  -- wild seat after it still acts.
  got = scenario("w4b_wally_cw_second_slot_partner")
  if got then
    local thr = at(got, isThrow)
    check(thr and at(got, used("PARTNER")) == nil and (at(got, used("RALTS"), thr) or 0) > thr,
      "w4b_wally_cw_second_slot_partner", "C-W: gActionsByTurnOrder[1] is the partner's; the third slot acts")
  end
  -- Refused everywhere else (the result `false`), and no event.
  for name, slot in pairs({
    w4b_wally_cw_refused_plain_wild = 1, w4b_wally_cw_refused_old_man = 1,
    w4b_wally_cw_refused_pokedude = 1, w4b_wally_cw_refused_1v1 = 1,
    w4b_wally_cw_refused_no_battler = 1, w4b_wally_cw_refused_replacing = 3,
  }) do
    got = scenario(name)
    if got then
      check(got.results[slot] == false and count(got, isThrow) == 0, name,
        "C-W: wallyThrow refused (result " .. slot .. " false) and never emitted")
    end
  end
  got = scenario("w4b_wally_cw_refused_side_b")
  if got then
    check(got.results[1] == false and got.results[3] == true and count(got, isThrow) == 1
      and got.events[at(got, isThrow)].side == "a", "w4b_wally_cw_refused_side_b",
      "C-W: side b's throw refused, side a's taken")
  end
  -- WALLY's seat alone: side a's SECOND seat (a coop partner) is refused like
  -- side b -- pokeemerald's WALLY controller drives B_POSITION_PLAYER_LEFT
  -- only -- so a turn where both side-a seats file one holds one throw, and
  -- one recall (WALLY's, slot 0).
  got = scenario("w4b_wally_cw_refused_partner")
  if got then
    local thr = at(got, isThrow)
    check(got.results[1] == false and got.results[2] == true and count(got, isThrow) == 1
      and thr and got.events[thr].slot == 0 and got.events[thr].side == "a", "w4b_wally_cw_refused_partner",
      "C-W: the partner's throw refused, WALLY's taken; one throw, from slot 0")
  end

  -- The throw draws nothing: with no tie and no QUICK CLAW, a turn whose foe
  -- is cancelled leaves the generator where it was.
  local scn
  for _, s in ipairs(fixture.scenarios) do
    if s.name == "w4b_wally_cw_throw_first" then scn = s end
  end
  if scn then
    local opts = plain(scn.create)
    opts.typeTable, opts.movePool = plain(fixture.typeTable), plain(fixture.movePool)
    opts.wildPick = nil
    local battle = Turn.create(opts)
    battle:drainEvents()
    local before = battle:snapshot().rngState
    battle:submitChoice("p1", { action = "wallyThrow" })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    check(battle:snapshot().rngState == before and battle:snapshot().turn == 2, "C-W draws",
      "C-W: the throw turn drew nothing and closed")
    -- A choice the throw ignores: nothing but the action is read.
    local b2 = Turn.create(opts)
    check(b2:submitChoice("p1", { action = "wallyThrow", move = 1, item = 4, slot = 1, target = 3 }) == true,
      "C-W stray", "C-W: stray fields on a wallyThrow are ignored, not refused")
  end
end

if UPDATE then
  -- Rewrite the fixture: inputs as they were, expectations from this run,
  -- one event per line so a diff reads as a turn-by-turn change.
  local lines = { "{" }
  lines[#lines + 1] = '  "version": ' .. encode(fixture.version) .. ","
  lines[#lines + 1] = '  "generation": ' .. encode(fixture.generation) .. ","
  lines[#lines + 1] = '  "notes": ' .. encode(fixture.notes) .. ","
  lines[#lines + 1] = '  "typeTable": ' .. encode(fixture.typeTable) .. ","
  lines[#lines + 1] = '  "movePool": ' .. encode(fixture.movePool) .. ","
  lines[#lines + 1] = '  "scenarios": ['
  for index, scn in ipairs(fixture.scenarios) do
    local got = results[index]
    lines[#lines + 1] = "    {"
    lines[#lines + 1] = '      "name": ' .. encode(scn.name) .. ","
    lines[#lines + 1] = '      "create": ' .. encode(scn.create) .. ","
    if scn.refuses ~= nil then
      lines[#lines + 1] = '      "refuses": ' .. encode(scn.refuses)
    else
      lines[#lines + 1] = '      "steps": ' .. encode(scn.steps) .. ","
      lines[#lines + 1] = '      "expect": {'
      lines[#lines + 1] = '        "batches": ' .. encode(got and got.batches or {}) .. ","
      lines[#lines + 1] = '        "results": ' .. encode(got and got.results or {}) .. ","
      lines[#lines + 1] = '        "outcome": ' .. encode(got and got.outcome or NULL) .. ","
      lines[#lines + 1] = '        "snapshot": ' .. encode(got and got.snapshot or NULL) .. ","
      lines[#lines + 1] = '        "events": ['
      local evs = got and got.events or {}
      for i, e in ipairs(evs) do
        lines[#lines + 1] = "          " .. encode(e) .. ((i < #evs) and "," or "")
      end
      lines[#lines + 1] = "        ]"
      lines[#lines + 1] = "      }"
    end
    lines[#lines + 1] = "    }" .. ((index < #fixture.scenarios) and "," or "")
  end
  lines[#lines + 1] = "  ]"
  lines[#lines + 1] = "}"
  local handle = io.open(FIXTURE, "wb")
  if not handle then
    io.stderr:write("battle_sim3_turn: cannot write " .. FIXTURE .. "\n")
    os.exit(1)
  end
  handle:write(table.concat(lines, "\n") .. "\n")
  handle:close()
  io.write(string.format("battle_sim3_turn: rewrote %s (%d scenarios)\n", FIXTURE, #fixture.scenarios))
  os.exit(failed == 0 and 0 or 1)
end

io.write(string.format("battle_sim3_turn: %d passed, %d failed (%d scenarios)\n",
  passed, failed, #fixture.scenarios))
os.exit(failed == 0 and 0 or 1)
