-- src/BattleSim2/Turn.lua: the Gen 2 turn machine's referee-level rules.
--
-- Run: luajit tests/battle_sim2_turn.lua              (from this folder's root)
--   or luajit mods/rby_mmo/tests/battle_sim2_turn.lua (from the engine)
--
-- Standalone for the same reason `tests/battle_sim2_vectors.lua` is: the claim
-- src/BattleSim2/ makes is that it resolves a whole fight with no love, no
-- engine modules and no mod facade.
--
-- The sibling vector suite pins the *formulas*.  This one pins the three
-- referee rules `docs/plans/gen2-new-battle-system.md` brought across from the
-- Gen 1 twin, all of which a vector is the wrong shape to state:
--
--   1. **who a faint pays** -- the `exp` mode gate, the participation set, and
--      the divisor.  The referee holds no species table and can never price a
--      faint (the legal floor, restated in `_awardExp`'s own comment); what it
--      states is which mode a faint happened in, who was still standing on the
--      owner side, and how many of them there were to split across.
--   2. **the replace phase** -- a faint with a living bench opens a phase of
--      its own, the seat that owes is the only one asked, and the turn number
--      does not move until the successor is on the field.
--   3. **stolen-KO retargeting** -- an action aimed at a seat a faster ally
--      already emptied swings at whoever is left instead of fizzling.
--
-- Every one of these is byte-shared with `src/BattleSim/Turn.lua` and with the
-- Node twin under `server/lib/battle2/`; `server/battle2_turn.test.js` runs the
-- same scenarios, and a case that passes on one side and fails on the other is
-- exactly the drift these suites exist to catch.

-- ------------------------------------------------------------------
-- where we are
-- ------------------------------------------------------------------

local ROOT = "."
do
  local invoked = arg and arg[0]
  local dir = invoked and invoked:match("^(.*)[/\\]tests[/\\][^/\\]+$")
  if dir and dir ~= "" then ROOT = dir end
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
    io.stderr:write("battle_sim2_turn: missing " .. path .. "\n")
    os.exit(1)
  end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then
    io.stderr:write("battle_sim2_turn: " .. tostring(err) .. "\n")
    os.exit(1)
  end
  cache[name] = chunk(need)
  return cache[name]
end

local BattleSim2 = need("BattleSim2/init")
local Turn, Events = BattleSim2.Turn, BattleSim2.Events

-- ------------------------------------------------------------------
-- assertions
-- ------------------------------------------------------------------

local passed, failed = 0, 0

local function ok(condition, what)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write("FAIL " .. tostring(what) .. "\n")
  end
end

local function eq(actual, expected, what)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    io.stderr:write(string.format("FAIL %s: expected %s, got %s\n",
      tostring(what), tostring(expected), tostring(actual)))
  end
end

-- ------------------------------------------------------------------
-- fixtures
-- ------------------------------------------------------------------
--
-- Synthetic throughout, and that is the legal posture rather than laziness: no
-- species, move or item this repo may not name appears anywhere here.

local function move(o)
  o = o or {}
  return {
    id = o.id or "thump",
    pp = o.pp or 20,
    power = o.power ~= nil and o.power or 40,
    accuracy = o.accuracy or 255,
    type = o.type or 0,
    effect = o.effect or 0,
    chance = o.chance or 0,
  }
end

-- Gen 2 sheet dialect: spe (Speed), spa (Sp.Atk), spd (Sp.Def).  The Gen 1
-- spd=Speed / spc=Special shape is what `copyMon` shape-sniffs away from, and
-- naming all five here is what keeps this suite on the Gen 2 branch of it.
local function mon(o)
  o = o or {}
  return {
    species = o.species or "Alpha",
    level = o.level or 20,
    hp = o.hp,
    maxHp = o.maxHp or 60,
    status = o.status,
    types = o.types,
    stats = {
      atk = o.atk or 40, def = o.def or 40,
      spe = o.spe or 40, spa = o.spa or 40, spd = o.spd or 40,
    },
    moves = o.moves or { move() },
  }
end

local function battleOf(o)
  local battle, err = Turn.create({
    id = o.id or "b1",
    mode = o.mode or "1v1",
    seed = o.seed or 12345,
    choiceTimeout = o.choiceTimeout or 60,
    reconnectGrace = o.reconnectGrace or 60,
    sides = o.sides,
  })
  if not battle then error("fixture battle refused: " .. tostring(err), 0) end
  return battle
end

local function drain(battle)
  return battle:drainEvents()
end

-- Play a scripted fight and hand back everything it emitted, opening drain
-- included.  `script` files one round of choices; it is called until the fight
-- ends or the round cap is hit, which keeps a rule that accidentally wedges the
-- machine from hanging the suite.
local function play(battle, script, rounds)
  local events = {}
  for _, event in ipairs(drain(battle)) do events[#events + 1] = event end
  for round = 1, rounds or 12 do
    if battle:outcome() then break end
    script(battle, round)
    for _, event in ipairs(drain(battle)) do events[#events + 1] = event end
  end
  return events
end

local function ofKind(events, kind)
  local out = {}
  for _, event in ipairs(events) do
    if event.t == kind then out[#out + 1] = event end
  end
  return out
end

local function sawKind(events, kind)
  return #ofKind(events, kind) > 0
end

-- The two seats a co-op fight puts on side a, against one synthetic seat on b.
local function coopSides(aMons, bMons)
  return {
    a = {
      { playerId = "a1", name = "Ann", mons = aMons[1] },
      { playerId = "a2", name = "Abe", mons = aMons[2] },
    },
    b = { { playerId = "npc", name = "Foe", mons = bMons } },
  }
end

-- ------------------------------------------------------------------
-- 1. the exp mode gate
-- ------------------------------------------------------------------
--
-- `EXP_MODES` is the rule, not a shortcut for an owner check: a seated fighter
-- carries a playerId whether a connection is behind it or a synthetic wild /
-- trainer seat is, so "does this seat have an owner" is not a question the turn
-- machine can ask -- but the mode answers it.

-- 1v1: a farming loop the gate refuses outright.  Vanilla link battles do not
-- pay either, so this is deliberate rather than incidental.
do
  local battle = battleOf({
    mode = "1v1", seed = 90101,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 30, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end)
  eq(#ofKind(events, "exp"), 0, "1v1: no exp event, however the fight ends")
  ok(sawKind(events, "faint"),
     "...and a faint really did happen, so the gate is what refused it")
end

-- coop_pvp: the other PvP shape, same refusal.
do
  local battle = battleOf({
    mode = "coop_pvp", seed = 90102,
    sides = {
      a = { { playerId = "a1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "b1", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 30, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("a1", { action = "fight", move = 0 })
    b:submitChoice("b1", { action = "fight", move = 0 })
  end)
  eq(#ofKind(events, "exp"), 0, "coop_pvp: no exp event either")
  ok(sawKind(events, "faint"), "...and again a faint really happened")
end

-- wild: the one owner seat is paid, once, naming the monster that fell.
do
  local battle = battleOf({
    mode = "wild", seed = 90103,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 60, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end)
  local exps = ofKind(events, "exp")
  eq(#exps, 1, "wild: exactly one exp event")
  eq(exps[1] and exps[1].slot, 0, "...paid to the sole owner seat, slot 0")
  eq(exps[1] and exps[1].species, "Beta", "...naming the wild mon that fell")
  eq(exps[1] and exps[1].level, 20, "...and the level it was")
  eq(exps[1] and exps[1].participants, 1, "...split one way")
  eq(exps[1] and exps[1].mon, 0, "...banked by party index 0")
  ok(exps[1] and exps[1].amount == nil,
     "...and never an amount: the referee holds no species table")
end

-- coop_wild: both owner seats stood against the wild mon, so both are paid, in
-- field-slot order, and each names the same divisor.
do
  local battle = battleOf({
    mode = "coop_wild", seed = 90104,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 90, spe = 70 }) } },
      { mon({ species = "Beta", maxHp = 200, spe = 10 }) }),
  })
  -- coop_wild seats the wild mon on b under the id the roster gave it.
  local events = play(battle, function(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 2 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 2 })
    b:autoPick("npc")
  end)
  local exps = ofKind(events, "exp")
  eq(#exps, 2, "coop_wild: both standing owner seats are paid")
  eq(exps[1] and exps[1].slot, 0, "...slot 0 first")
  eq(exps[2] and exps[2].slot, 1, "...then slot 1 -- seat order, not speed order")
  eq(exps[1] and exps[1].participants, 2, "...split two ways")
  eq(exps[2] and exps[2].participants, 2, "...and both say so")
end

-- ------------------------------------------------------------------
-- 2. participation: the set is per FOE MONSTER, and a corpse leaves it
-- ------------------------------------------------------------------

-- A benched monster that was never in against the foe collects nothing, and is
-- not in the divisor either: the set is the flag list, not the party.
do
  local battle = battleOf({
    mode = "wild", seed = 90105,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
                mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }),
                mon({ species = "Bench", maxHp = 200, spe = 5 }),
              } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 60, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end)
  local exps = ofKind(events, "exp")
  eq(#exps, 1, "a bench that never fought is not paid")
  eq(exps[1] and exps[1].participants, 1, "...and is not in the divisor either")
  eq(exps[1] and exps[1].mon, 0, "...the share goes to the one that was out")
end

-- A monster that switches in joins the standing foe's set, so both halves of a
-- swap are paid when the foe finally drops.
do
  local battle = battleOf({
    mode = "wild", seed = 90106,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
                mon({ species = "Alpha", maxHp = 200, atk = 20, spe = 80 }),
                mon({ species = "Second", maxHp = 200, atk = 90, spe = 80 }),
              } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mon({ species = "Beta", maxHp = 90, spe = 10 }) } } },
    },
  })
  local events = play(battle, function(b, round)
    if round == 1 then
      b:submitChoice("p1", { action = "switch", slot = 1 })
    else
      b:submitChoice("p1", { action = "fight", move = 0 })
    end
    b:submitChoice("wild", { action = "fight", move = 0 })
  end)
  local exps = ofKind(events, "exp")
  ok(#exps >= 1, "the swap-in that landed the KO is paid")
  if #exps >= 1 then
    eq(exps[1].participants, 2,
       "...and the monster it came in for is still a participant, so the "
       .. "divisor is two")
  end
end

-- ------------------------------------------------------------------
-- 3. the replace phase
-- ------------------------------------------------------------------
--
-- A faint with a living bench must not be folded into the next choice window:
-- the successor walks out first, and only then does the turn advance.

do
  local battle = battleOf({
    mode = "coop_npc", seed = 90107,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 95, spe = 90 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 95, spe = 80 }) } },
      { mon({ species = "Beta", maxHp = 30, spe = 10 }),
        mon({ species = "Delta", maxHp = 200, spe = 10 }) }),
  })
  local events = play(battle, function(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 2 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 2 })
    b:autoPick("npc")
  end, 3)

  -- The solicitation is a `turn` carrying the asked seat's field slot, which is
  -- the whole of the wire contract: with `slot` it is a replacement ask, without
  -- it the ordinary window.
  local solicited = nil
  local firstOrdinaryAfter = nil
  local sawFaint = false
  for _, event in ipairs(events) do
    if event.t == "faint" then sawFaint = true end
    if event.t == "turn" and event.slot ~= nil and solicited == nil then
      solicited = event
    elseif event.t == "turn" and event.slot == nil and solicited ~= nil
           and firstOrdinaryAfter == nil then
      firstOrdinaryAfter = event
    end
  end
  ok(sawFaint, "the KO that opens the phase really happened")
  ok(solicited ~= nil, "a replacement solicitation was raised")
  eq(solicited and solicited.slot, 2, "...naming the seat that owes, slot 2")

  -- The turn number does not move across the phase: the fight is still on the
  -- turn whose faint opened it.
  local faintTurn = nil
  for _, event in ipairs(events) do
    if event.t == "turn" and event.slot == nil and faintTurn == nil then
      faintTurn = event.amount
    end
  end
  eq(solicited and solicited.amount, faintTurn,
     "...on the same turn number the faint happened on")
  ok(firstOrdinaryAfter == nil
     or firstOrdinaryAfter.amount == (faintTurn or 0) + 1,
     "...and the next ordinary window is exactly one turn later")

  -- Order within the batch: faint, then the spoils, then the ask, then the
  -- successor, then the turn.  A client reads this as one story.
  local order = {}
  for _, event in ipairs(events) do
    if event.t == "faint" or event.t == "exp" or event.t == "switch"
       or event.t == "send" or (event.t == "turn" and event.slot ~= nil) then
      order[#order + 1] = event.t == "turn" and "ask" or event.t
    end
  end
  local joined = table.concat(order, ",")
  ok(joined:find("faint,exp,exp,ask,switch,send", 1, true) ~= nil,
     "the batch reads faint -> spoils -> ask -> switch -> send (" .. joined .. ")")
end

-- A standing seat may not answer during the replace phase: its fight would be
-- an answer to a turn that has not opened yet.
do
  local battle = battleOf({
    mode = "coop_npc", seed = 90108,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 95, spe = 90 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 95, spe = 80 }) } },
      { mon({ species = "Beta", maxHp = 30, spe = 10 }),
        mon({ species = "Delta", maxHp = 200, spe = 10 }) }),
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 2 })
  battle:autoPick("npc")
  drain(battle)
  eq(battle:snapshot().phase, "replace",
     "the KO left the machine in the replace phase")
  eq(battle:submitChoice("a1", { action = "fight", move = 0, target = 2 }), false,
     "a standing seat's fight is refused during the phase")
  eq(battle:submitChoice("a1", { action = "cancel" }), false,
     "...and so is a cancel: a forced replacement cannot be taken back")
  eq(battle:autoPick("a1"), false,
     "an NPC that is still standing does not file either")
  ok(battle:autoPick("npc"), "only the seat that owes may answer")
  eq(battle:snapshot().phase, "choice",
     "...and answering it closes the phase")
end

-- The highest-consequence path in the phase, and the one neither generation
-- covered until now: if the timeout sweep does not reach a `replace` seat, an
-- idle or dropped player wedges the fight forever -- `_maybeResolve` never
-- fires, because the only thing anybody owes is the replacement nobody filed.
-- `server/battle2_turn.test.js` asserts the same scenario on the JS twin.
do
  local battle = battleOf({
    mode = "coop_npc", seed = 90111, choiceTimeout = 10, reconnectGrace = 600,
    sides = coopSides(
      { { mon({ species = "Alpha", maxHp = 200, atk = 95, spe = 90 }) },
        { mon({ species = "Gamma", maxHp = 200, atk = 95, spe = 80 }) } },
      { mon({ species = "Beta", maxHp = 30, spe = 10 }),
        mon({ species = "Delta", maxHp = 400, spe = 10 }) }),
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 2 })
  battle:autoPick("npc")
  drain(battle)
  eq(battle:snapshot().phase, "replace", "the KO opened the phase")

  -- Nobody answers. The clock is what has to carry it.
  ok(battle:tick(battle:snapshot().now + 60),
     "the deadline passing is a tick that did something")
  eq(battle:snapshot().phase, "choice",
     "the sweep filled the owed replacement and closed the phase")
  local sent = 0
  for _, event in ipairs(drain(battle)) do
    if event.t == "send" and event.slot == 2 then sent = sent + 1 end
  end
  ok(sent > 0, "...and the successor really was fielded")
end

-- ------------------------------------------------------------------
-- 4. stolen-KO retargeting
-- ------------------------------------------------------------------
--
-- In a 2v2 the faster ally KOs the seat the slower ally picked.  Without
-- `_retarget` the slower mon fizzles with "has no target"; with it the action
-- swings at whoever is left.

do
  -- Two foe seats.  a1 (fastest) empties slot 2; a2 aimed there too and must
  -- land on slot 3 -- rule (b), the nearest living opposing seat.
  local battle = battleOf({
    mode = "coop_pvp", seed = 90109,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spe = 99 }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 200, spe = 90 }) } },
      },
      b = {
        { playerId = "b1", name = "Bob",
          mons = { mon({ species = "Beta", maxHp = 1, spe = 5 }) } },
        { playerId = "b2", name = "Bea",
          mons = { mon({ species = "Delta", maxHp = 400, spe = 5 }) } },
      },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)

  local fizzled = false
  for _, event in ipairs(events) do
    if event.t == "msg" and type(event.text) == "string"
       and event.text:find("has no target", 1, true) then
      fizzled = true
    end
  end
  ok(not fizzled, "the slower ally does not fizzle on the seat its partner emptied")

  local hitSlot3 = false
  for _, event in ipairs(events) do
    if event.t == "damage" and event.slot == 3 then hitSlot3 = true end
  end
  ok(hitSlot3, "...it swings at the nearest living opposing seat instead")
end

-- Nothing standing opposite: the action is skipped rather than redirected onto
-- an ally -- rule (c), and the reason `_retarget` only ever searches the
-- opposing side.
do
  local battle = battleOf({
    mode = "coop_pvp", seed = 90110,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mon({ species = "Alpha", maxHp = 200, atk = 200, spe = 99 }) } },
        { playerId = "a2", name = "Abe",
          mons = { mon({ species = "Gamma", maxHp = 200, atk = 200, spe = 90 }) } },
      },
      b = { { playerId = "b1", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 1, spe = 5 }) } } },
    },
  })
  drain(battle)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 2 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  local events = drain(battle)
  local hitOwnSide = false
  for _, event in ipairs(events) do
    if event.t == "damage" and (event.slot == 0 or event.slot == 1)
       and event.status == nil then
      -- Side a taking damage here could only be the ally strike this rule
      -- exists to make impossible; a residual would carry `status`.
      hitOwnSide = true
    end
  end
  ok(not hitOwnSide, "an emptied opposing side never redirects a move onto an ally")
end

-- ------------------------------------------------------------------
-- 5. the vocabulary really carries all of this
-- ------------------------------------------------------------------
--
-- `Events.build` enforces the field whitelist at construction, so a field this
-- suite reads off an event is a field the Node twin and the screen will see
-- too.  A kind or key that only exists because a test made it up would be a
-- drop three modules downstream instead of a failure here.

do
  ok(Events.KINDS.exp == true, "`exp` is in the closed kind set")
  eq(Events.FIELDS.species, "string", "...with a species field")
  eq(Events.FIELDS.level, "number", "...a level")
  eq(Events.FIELDS.participants, "number", "...a participant count")
  eq(Events.FIELDS.mon, "number", "...and a party index")
  ok(Events.SHAPES.send and Events.SHAPES.send.mon ~= nil,
     "`send` promises the party index it fielded")
  ok(Events.SHAPES.switch and Events.SHAPES.switch.mon ~= nil,
     "...and so does `switch`")
  ok(Events.SHAPES.turn and Events.SHAPES.turn.slot ~= nil,
     "`turn` documents the replacement-solicitation slot")

  local built = Events.build("exp", {
    slot = 0, species = "Beta", level = 20, participants = 2, mon = 1,
  })
  ok(built ~= nil, "an exp event builds")
  eq(built and built.t, "exp", "...tagged exp")
  eq(built and built.participants, 2, "...carrying its divisor")
  eq(built and built.mon, 1, "...and the party index banking the share")
end

-- ------------------------------------------------------------------
-- 4. wildlife never uses an item, from either end
-- ------------------------------------------------------------------
--
-- Byte-shared with the Gen 1 twin's 12f3 and with server/lib/battle2/Turn.js.
-- A wild monster has no bag and no hands, and its seat is driven from two ends
-- -- the hub auto-picks for it, and a submitted choice can arrive addressed to
-- it -- so both are pinned.  The wild seat is handed a bag on purpose: the
-- point is that even a seat that HAS one never spends it, so a hub seeding the
-- wrong kit cannot put a Potion in a wild monster's mouth.

for _, mode in ipairs({ "wild", "coop_wild" }) do
  do
    local battle = battleOf({
      mode = mode,
      choiceTimeout = 10,
      seed = 88010,
      sides = {
        a = {
          { playerId = "p1", name = "Ann",
            mons = { mon({ species = "Alpha", maxHp = 200, spe = 90 }) } },
        },
        b = {
          { playerId = "wild", name = "Wild",
            -- Hurt below half and poisoned: a trainer seat heals or cures here.
            mons = { mon({ species = "Beta", maxHp = 200, hp = 40, spe = 10,
                           status = "PSN" }) },
            bag = { POTION = 2, FULL_HEAL = 1, X_ATTACK = 1 } },
        },
      },
    })
    drain(battle)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    ok(battle:tick(11) == true, mode .. ": the wild seat's turn resolves")
    local items = ofKind(drain(battle), "item")
    eq(#items, 0, mode .. ": auto-pick never reaches the wild seat's bag")
    eq(battle.byId.wild.bag.POTION, 2, mode .. ": and spends none of it")
    eq(battle.byId.wild.bag.FULL_HEAL, 1, mode .. ": cure untouched too")
    eq(battle.byId.wild.mons[1].status, "poison", mode .. ": still poisoned")
  end

  do
    local battle = battleOf({
      mode = mode,
      seed = 88011,
      sides = {
        a = {
          { playerId = "p1", name = "Ann",
            mons = { mon({ species = "Alpha", maxHp = 200, spe = 90 }) },
            bag = { POTION = 1 } },
        },
        b = {
          { playerId = "wild", name = "Wild",
            mons = { mon({ species = "Beta", maxHp = 200, hp = 40, spe = 10 }) },
            bag = { POTION = 1 } },
        },
      },
    })
    drain(battle)
    ok(battle:submitChoice("wild", { action = "item", item = "POTION", slot = 0 })
       == false, mode .. ": a submitted item from the wild seat is refused")
    eq(battle.byId.wild.choice, nil, mode .. ": and files nothing")
    ok(battle:submitChoice("p1", { action = "item", item = "POTION", slot = 0 })
       == true, mode .. ": the player on side a still may")
  end
end

-- ------------------------------------------------------------------

io.write(string.format("battle_sim2_turn: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
