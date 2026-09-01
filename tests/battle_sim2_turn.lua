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
  ok(Events.SHAPES.send.status ~= nil,
     "...and the condition a newcomer walked in with")
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
-- 6. whom the referee swings at when nobody chose (`_autoTarget`)
-- ------------------------------------------------------------------
--
-- The Gen 1 twin's tests/battle_sim_turn.lua carries the long version of this
-- story.  Short version: every aim the referee filed for itself used to be
-- "the lowest-numbered living foe", so on a side holding two players the NPCs
-- swung at seat 0 every turn and the second player was never attacked at all.
-- Gold inherited the rule and therefore the bug, so it inherits the pin.

local function aimSides(foes)
  local sideB = {}
  for i = 1, foes do
    sideB[i] = { playerId = "n" .. i, name = "Npc" .. i, mons = {
      mon({ species = "Beta", maxHp = 400, spe = 90 }) } }
  end
  return {
    a = {
      { playerId = "p1", name = "One", mons = { mon({ species = "Alpha", maxHp = 400, spe = 10 }) } },
      { playerId = "p2", name = "Two", mons = { mon({ species = "Gamma", maxHp = 400, spe = 10 }) } },
    },
    b = sideB,
  }
end

for _, case in ipairs({
  { mode = "coop_wild", foes = 1 },
  { mode = "coop_npc",  foes = 2 },
}) do
  local battle = battleOf({ id = "aim", mode = case.mode, seed = 4242, sides = aimSides(case.foes) })
  drain(battle)
  local onSlot0, onSlot1 = 0, 0
  for _ = 1, 10 do
    battle:submitChoice("p1", { action = "fight", move = 0, target = 2 })
    battle:submitChoice("p2", { action = "fight", move = 0, target = 2 })
    for i = 1, case.foes do battle:autoPick("n" .. i) end
    for _, event in ipairs(drain(battle)) do
      if event.t == "damage" and event.side == "a" then
        if event.slot == 0 then onSlot0 = onSlot0 + 1 else onSlot1 = onSlot1 + 1 end
      end
    end
    if battle.result then break end
  end
  ok(onSlot0 > 0, case.mode .. ": the npc side still attacks the first player")
  ok(onSlot1 > 0, case.mode .. ": and it attacks the second one too (the reported bug)")
end

-- An aim is drawn from a second generator, so asking for one must not spend a
-- byte of the battle's own -- otherwise every vector in the Gold pack moves.
do
  local battle = battleOf({ id = "aim", mode = "coop_npc", seed = 4242, sides = aimSides(2) })
  drain(battle)
  local before = battle.rng:state()
  local npc = battle.byId["n1"]
  local seen = {}
  for _ = 1, 32 do seen[battle:_autoTarget(npc).slot] = true end
  eq(battle.rng:state(), before, "aim: 32 draws later the battle RNG has not moved")
  ok(seen[0] and seen[1], "aim: and those draws reached both player seats")
end

-- One living foe is answered without a draw at all, which is why every 1v1 and
-- wild fixture replays byte for byte after aims began to spread.
do
  local battle = battleOf({ id = "solo", seed = 4242, sides = {
    a = { { playerId = "p1", name = "One", mons = { mon({ species = "Alpha" }) } } },
    b = { { playerId = "p2", name = "Two", mons = { mon({ species = "Beta" }) } } },
  } })
  drain(battle)
  local before = battle.aim:state()
  local fighter = battle.byId["p2"]
  for _ = 1, 8 do eq(battle:_autoTarget(fighter).slot, 0, "aim: 1v1 has one answer") end
  eq(battle.aim:state(), before, "aim: and a fight with one foe never touches the aim stream")
end


-- ------------------------------------------------------------------
-- trapping moves: the counter is a total attack count, and the answer the
-- referee files for a locked seat is not the player's to take back
-- ------------------------------------------------------------------

-- Gen1's 2..5 roll counts the hit that applied the trap, so the turn it lands
-- on deals the move's damage and no residual on top of it.  Counting it the
-- other way made a 2-turn Wrap hit three times.
do
  local battle = battleOf({ seed = 9999, sides = {
    a = { { playerId = "p1", name = "One", mons = {
      mon({ species = "Alpha", maxHp = 999, spe = 120,
            moves = { move({ id = "wrap", power = 5, effect = 42 }) } }) } } },
    b = { { playerId = "p2", name = "Two", mons = {
      mon({ species = "Beta", maxHp = 999, def = 200, spe = 1,
            moves = { move({ id = "tap", power = 0 }) } }) } } },
  } })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })

  local landingResidual = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "msg" and event.text:find("hurt by the trap", 1, true) then
      landingResidual = true
    end
  end
  ok(not landingResidual, "the turn the trap lands on deals no residual on top of the hit")

  local beta = battle.byId["p2"]
  local afterHit = beta.mons[beta.active].hp
  ok(afterHit < 999, "the trapping move itself damages the victim")

  -- The turn after is forced on both seats, so it waits for a tick.
  battle:tick(battle.now + 1)
  local residual = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "msg" and event.text:find("hurt by the trap", 1, true) then
      residual = true
    end
  end
  ok(residual, "the turns that follow each deal one residual")
  ok(beta.mons[beta.active].hp < afterHit, "trap residual reduces trapped mon HP")
end

-- A trap forces *both* seats, so `_openTurn` leaves that turn without a
-- deadline: a cancel that cleared one of those answers would hang the fight
-- with nothing left to time it out.
do
  local battle = battleOf({ seed = 9999, sides = {
    a = { { playerId = "p1", name = "One", mons = {
      mon({ species = "Alpha", maxHp = 999, spe = 120,
            moves = { move({ id = "wrap", power = 5, effect = 42 }) } }) } } },
    b = { { playerId = "p2", name = "Two", mons = {
      mon({ species = "Beta", maxHp = 999, def = 200, spe = 1,
            moves = { move({ id = "tap", power = 0 }) } }),
      mon({ species = "Delta", maxHp = 999, spe = 1,
            moves = { move({ id = "tap", power = 0 }) } }) } } },
  } })
  drain(battle)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drain(battle)

  eq(battle.deadline, nil, "a turn forced on every seat opens without a deadline")
  ok(battle.byId["p2"].forced, "the trapped seat is marked as answered by the referee")
  ok(battle:submitChoice("p2", { action = "cancel" }) == false,
     "cancel cannot clear a forced trap answer")
  ok(battle:submitChoice("p2", { action = "switch", slot = 1 }) == false,
     "and the victim still cannot switch out of the trap")
  ok(battle.byId["p2"].choice ~= nil, "the forced answer survived the cancel")

  -- The refusal is what keeps the clock alive: the chain still runs to its end.
  local freed = false
  for _ = 1, 40 do
    if battle:outcome() then break end
    if battle:submitChoice("p2", { action = "fight", move = 0 }) then freed = true; break end
    if not battle:tick(battle.now + 1) then break end
    drain(battle)
  end
  ok(freed, "the trap chain still ends after a refused cancel")
end

-- An ordinary answer stays cancellable -- the guard is about forced fills only.
do
  local battle = battleOf({ sides = {
    a = { { playerId = "p1", name = "One", mons = { mon({ species = "Alpha" }) } } },
    b = { { playerId = "p2", name = "Two", mons = { mon({ species = "Beta" }) } } },
  } })
  drain(battle)
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "an ordinary answer files")
  ok(battle:submitChoice("p1", { action = "cancel" }), "and can still be taken back")
  ok(battle.byId["p1"].choice == nil, "cancel cleared it")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "and the seat can answer again")
end

-- ------------------------------------------------------------------
-- what a move is *called* in a sentence (PROTOCOL 26)
-- ------------------------------------------------------------------
--
-- Gen 2's own copies of the five call sites that name a move.  The Gen 1 twin
-- (tests/battle_sim_turn.lua, section 12l) carries the same block, and
-- separately on purpose: BattleSim2 is a twin of BattleSim rather than an
-- import of it, so a fix landed on one half of one generation is exactly the
-- drift this catches.

do
  local swipe = move({ id = "slow_swipe", power = 10 })
  swipe.name = "SLOW SWIPE"
  local lockdown = move({ id = "lock_down", power = 0, effect = 86 })
  lockdown.name = "LOCK DOWN"
  local copycat = move({ id = "copy_cat", power = 0, effect = 82 })
  copycat.name = "COPY CAT"
  local thump = move({ id = "thump", power = 10 })
  thump.name = "THUMP HIT"
  -- No name at all: what a protocol-25 client uploads.
  local nudge = move({ id = "nudge", power = 10 })

  local battle = battleOf({ id = "names", seed = 4242, sides = {
    a = { { playerId = "p1", name = "Ann", mons = {
      mon({ species = "Alpha", maxHp = 400, spe = 90,
            moves = { swipe, lockdown, copycat } }) } } },
    b = { { playerId = "p2", name = "Bob", mons = {
      mon({ species = "Beta", maxHp = 400, spe = 10,
            moves = { thump, nudge } }) } } },
  } })
  local said, animated = {}, {}
  local function step(aMove, bMove)
    battle:submitChoice("p1", { action = "fight", move = aMove })
    battle:submitChoice("p2", { action = "fight", move = bMove })
    for _, event in ipairs(drain(battle)) do
      if event.t == "msg" then said[#said + 1] = event.text end
      if event.t == "anim" then animated[#animated + 1] = event.text end
    end
  end
  drain(battle)
  step(0, 0)
  step(1, 0)
  step(2, 1)
  for _ = 1, 5 do step(2, 1) end

  local function spoke(line)
    for _, text in ipairs(said) do if text == line then return true end end
    return false
  end

  ok(spoke("Alpha used SLOW SWIPE"), "gen2: an attack prints the display name")
  ok(spoke("THUMP HIT was disabled"), "gen2: Disable landing names the move")
  ok(spoke("THUMP HIT is disabled"), "gen2: and so does the refusal it causes")
  ok(spoke("THUMP HIT is no longer disabled"), "gen2: and so does it wearing off")
  ok(spoke("Alpha learned THUMP HIT"), "gen2: Mimic names what it copied")
  ok(spoke("Alpha used THUMP HIT"), "gen2: and the copy keeps the name")
  ok(spoke("Beta used nudge"), "gen2: a move with no name is narrated under its id")

  local sawId, sawName = false, false
  for _, text in ipairs(animated) do
    if text == "slow_swipe" then sawId = true end
    if text == "SLOW SWIPE" then sawName = true end
  end
  ok(sawId, "gen2: the anim row still carries the registry id")
  ok(not sawName, "gen2: and never the display name")
end

-- autoPick never leaves a living choice-phase seat owing: an empty moveset
-- used to return nil, and with choiceTimeout 0 the fight sat forever. An empty
-- sheet with a living foe is now Struggle; skip is only no-target.
do
  local battle = battleOf({
    choiceTimeout = 0,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 200, spe = 10, moves = {} }) } } },
    },
  })
  drain(battle)
  eq(battle.turn, 1, "the opening window is turn 1")
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }), "the player files")
  ok(battle:autoPick("p2"), "an empty-moves NPC still files")
  local struggle = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "anim" and event.text == "STRUGGLE" then struggle = true end
  end
  ok(struggle, "gen2: the empty sheet Struggles rather than skipping")
  ok(battle.turn >= 2 or battle:outcome() ~= nil,
     "the turn closed rather than sitting on an owed NPC")
end

-- The timeout sweep must file Struggle too, not push the clock on a nil pick.
do
  local battle = battleOf({
    choiceTimeout = 10,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 200, spe = 10, moves = {} }) } } },
    },
  })
  drain(battle)
  eq(battle.turn, 1, "the opening window is turn 1")
  ok(battle:tick(9) == false, "inside the deadline the sweep does nothing")
  ok(battle:tick(11) == true, "past the deadline the sweep files")
  local struggle = false
  for _, event in ipairs(drain(battle)) do
    if event.t == "anim" and event.text == "STRUGGLE" then struggle = true end
  end
  ok(struggle, "gen2: an unanswered empty sheet Struggles rather than pushing the clock")
  ok(battle.turn >= 2 or battle:outcome() ~= nil,
     "the timeout closed the turn instead of waiting another window")
end

-- A dead side left in `choice` must end the fight. Same hang the Gen 1
-- twin pins: FIGHT used to return nil (no living foe) and a zero timeout
-- sat on "Waiting for WILD...".
do
  local battle = battleOf({
    choiceTimeout = 0,
    mode = "wild",
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 40, spe = 10 }) } } },
    },
  })
  drain(battle)
  local foe = battle.byId.p2
  foe.mons[1].hp = 0
  foe.active = nil
  ok(battle:tick(0) == true, "gen2: one tick notices the empty side")
  local out = battle:outcome()
  ok(out ~= nil, "gen2: and the fight ends rather than waiting for the wild")
  eq(out and out.reason, "ko", "gen2: as a knockout")
end

do
  local battle = battleOf({
    choiceTimeout = 0,
    mode = "wild",
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mon({ species = "Alpha", maxHp = 200, atk = 90, spe = 80 }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mon({ species = "Beta", maxHp = 40, spe = 10 }) } } },
    },
  })
  drain(battle)
  local foe = battle.byId.p2
  foe.mons[1].hp = 0
  foe.active = nil
  ok(battle:submitChoice("p1", { action = "fight", move = 0 }),
     "gen2: FIGHT with nobody to aim at is accepted as a skip")
  ok(battle:outcome() ~= nil, "gen2: and the skip closes the fight")
end

-- ------------------------------------------------------------------

io.write(string.format("battle_sim2_turn: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
