-- The Lua half of the **Gen 2** turn machine's cross-runtime parity check.
--
-- Run: luajit tests/drivers/battle2_turn_parity.lua .       (from this root)
--
-- Drives src/BattleSim2/Turn.lua through a fixed set of scenarios and prints
-- the event stream, the outcome and a snapshot digest as JSON on stdout.
-- server/battle2_turn.test.js builds the same scenarios against
-- server/lib/battle2/Turn.js and asserts the two are equal, event for event.
-- It spawns this file when luajit is on PATH and falls back to
-- tests/fixtures/battle2_turn_parity.json -- this script's own committed output
-- -- when it is not.
--
-- Same contract and the same JSON shape as its Gen 1 sibling
-- (`battle_turn_parity.lua`), which pins the *formula* draw sites. This one
-- scopes to the three referee rules `docs/plans/gen2-new-battle-system.md`
-- brought across from the Gen 1 twin, because those are the rules that are new
-- in this directory and therefore the ones that can drift:
--
--   * `exp_wild` / `exp_coop` -- who a faint pays, and the divisor. A stream
--     that differs from the JS one by a permutation of the `exp` rows is a
--     parity failure with no symptom anyone could read, which is exactly why
--     the events are compared in order rather than as a set.
--   * `replace` -- the phase between two turns: the solicitation's `slot`, the
--     turn number holding still across it, and the successor's party index on
--     `switch` / `send`.
--   * `retarget` -- a stolen KO. The slower ally's action must land on the
--     seat that is left, and it must land on it having drawn the same bytes.
--   * `badges_link` / `badges_coop_pvp` / `badges_npc` / `badges_gold` --
--     where an uploaded badge set counts (Turn.BADGE_MODES: side a of a fight
--     against the computer, never a link battle and never side b), and what
--     it does there: Crystal's stat boosts, Glacier's Sp. Def tail, the 999
--     cap and DoBadgeTypeBoosts.
--   * the pokecrystal fidelity pass (docs/plans/gen12-referee-fidelity.md):
--     `stage_badge_order` (CalcPlayerStats: stage, then badge, rounding and
--     the turn order it moves), `crit_stages` (CheckDamageStatsCritical both
--     ways, screens included / ignored), `truncate_wild` / `truncate_link`
--     (TruncateHL_BC's loop against its single link pass and wrap),
--     `screens_side` (per side, five turns, a failed recast, surviving a
--     switch and Haze), `self_hit` (own Reflect, the Explosion-selected
--     halving), `struggle_typeless`, `metronome_last_pp` and `priority`.
--   * the cart family (contract K6): `truncate_wild` / `truncate_link` fight
--     with no `family` (Gold / Silver: one pass everywhere), and
--     `truncate_crystal_wild` / `truncate_crystal_link` say "crystal" (a loop
--     outside a link battle, one pass in one).
--   * Gold held items, obedience and the flinch reset (wave 2 of the same
--     plan): `quick_claw` (the roll inside a bracket, side b's first, a bracket
--     of one drawing nothing), `held_between_turns` (HandleBetweenTurnEffects'
--     order, a berry eaten and gone), `status_berries` (cured right after
--     infliction and between turns), `focus_band` (a roll on every hit),
--     `kings_rock` (eligible / ineligible scripts, the flinch reset at turn
--     open), `thief` / `thief_refused` (both ways; Mail, a full hand, a KO),
--     `berserk_gene` (256 and the inherited count), `metal_powder` (the party
--     species through Transform, the overflow), `species_items` (Light Ball /
--     Thick Club and the one-pass wrap), `type_boost` (Struggle's NORMAL, the
--     self-hit's selected type), `crit_items`, `bright_powder` (Swift exempt),
--     and obedience: `obey_traded` (use-instead, loafing, nap, self-hit),
--     `obey_asleep` (Snore and Sleep Talk), `obey_badges`, `obey_fallbacks`,
--     `obey_link` and `obey_side_b` (never).
--   * the wave-2 review fixes: `thief_substitute` / `thief_chance_miss`
--     (Thief's `effectchance`: a substitute, the 1/256), `obey_bide` (a Bide
--     release skips obedience), `bide_slot0` (a release aimed at seat 0),
--     `gate_para_confused` / `gate_para_disabled` (paralysis is CheckTurn's
--     last gate), `mysteryberry_transformed`, `leftovers_large`
--     (GetSixteenthMaxHP past 1024), `leech_seed_ko`, `rage` / `rage_cap` /
--     `rage_sources` (Gold's Rage counter) and `side_effect_ko` (no secondary
--     effect past `checkfaint`).
--   * the referee-gaps run (docs/plans/gen12-referee-gaps-fix.md, R2a):
--     `gold_stat_hits` (SP. DEF / ACCURACY down, ATTACK / DEFENSE / ALL up),
--     `flame_wheel_thaw`, `stomp_minimize`, `twister_fly` (GUST, EARTHQUAKE,
--     THUNDER), `snore_sky_attack`, `tri_attack`, `effectchance_miss`,
--     `multi_hit_draws` / `multi_hit_first_ko`, `leech_seed_eighth`,
--     `no_999_cap`, `recoil_substitute`, `rampage_zero_pp`,
--     `mirror_move_last_used`, `metronome_charge`, `metronome_bide`, `pay_day_wild` /
--     `pay_day_link` and `hyper_beam_recharge`; `trap_chain` is Gold's wrap.
--
-- The snapshot digest carries `rngState`, which is the single number that says
-- both runtimes drew the same count: a faint that paid out must not move it,
-- and the retarget scenario exists partly to prove redirecting an action does
-- not spend a byte the other runtime would not have spent.
--
-- Standalone on purpose, like the suites beside it: it loads the shipped files
-- through the same `need`-shaped resolver main.lua uses, with no love, no
-- engine modules and no mod facade -- which is the claim src/BattleSim2/ makes.
--
-- Synthetic throughout: no species, move or item this repo may not name appears
-- anywhere below.
--
-- Invoked as: luajit <this file> <repo root>

local ROOT = arg and arg[1] or "."

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
  if not body then error("missing " .. path, 0) end
  local chunk, err = loadstr(body, "@" .. name .. ".lua")
  if not chunk then error(tostring(err), 0) end
  cache[name] = chunk(need)
  return cache[name]
end

local Turn = need("BattleSim2/init").Turn

-- ------------------------------------------------------------------
-- canonical JSON out (byte-identical shape to battle_turn_parity.lua)
-- ------------------------------------------------------------------

local function encString(s)
  local body = s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    if c == '\r' then return '\\r' end
    if c == '\t' then return '\\t' end
    return string.format('\\u%04x', c:byte())
  end)
  return '"' .. body .. '"'
end

local function encNumber(n)
  if n == math.floor(n) then return string.format("%d", n) end
  return string.format("%.17g", n)
end

local function encScalar(v)
  local t = type(v)
  if t == "string" then return encString(v) end
  if t == "number" then return encNumber(v) end
  if t == "boolean" then return v and "true" or "false" end
  return "null"
end

-- Flat until `moves` arrived.  A `moves` event (Transform / Mimic republishing
-- a live move list) is the one event kind carrying a table value, and encoding
-- it as `null` -- which is what encScalar does with any table -- would have made
-- every such event compare equal on both runtimes no matter what was in it.
-- One level of nesting is all the vocabulary has, so one level is all this
-- takes; a deeper value would still land as null, loudly, in a diff.
local function encObject(tbl)
  local keys = {}
  for k in pairs(tbl) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = tbl[k]
    if type(v) == "table" then
      local rows = {}
      for i = 1, #v do
        local row = v[i]
        if type(row) == "table" then
          local inner = {}
          for ik in pairs(row) do inner[#inner + 1] = ik end
          table.sort(inner)
          local cells = {}
          for _, ik in ipairs(inner) do
            cells[#cells + 1] = encString(ik) .. ":" .. encScalar(row[ik])
          end
          rows[i] = "{" .. table.concat(cells, ",") .. "}"
        else
          rows[i] = encScalar(row)
        end
      end
      parts[#parts + 1] = encString(k) .. ":[" .. table.concat(rows, ",") .. "]"
    else
      parts[#parts + 1] = encString(k) .. ":" .. encScalar(v)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function encList(list, encoder)
  local parts = {}
  for i = 1, #list do parts[i] = encoder(list[i]) end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function encOutcome(out)
  if not out then return "null" end
  local parts = {
    '"battle":' .. encString(out.battle),
    '"outcome":' .. encString(out.outcome),
    '"reason":' .. encString(out.reason),
  }
  if out.winners then
    parts[#parts + 1] = '"winners":' .. encList(out.winners, encString)
  end
  if out.losers then
    parts[#parts + 1] = '"losers":' .. encList(out.losers, encString)
  end
  -- Contract K11: Pay Day's coins on side a's win against the computer.
  if out.payDay then
    parts[#parts + 1] = '"payDay":' .. encNumber(out.payDay)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- A digest rather than the whole snapshot: the RNG state is the part that
-- proves both runtimes drew the same number of bytes at the same points.
local function encSnapshot(battle)
  local snap = battle:snapshot()
  local rows = {}
  for _, entry in ipairs(snap.field) do
    rows[#rows + 1] = "{"
      .. '"slot":' .. encNumber(entry.slot) .. ","
      .. '"hp":' .. encNumber(entry.hp) .. ","
      .. '"party":' .. encList(entry.party, encNumber)
      .. "}"
  end
  return "{"
    .. '"phase":' .. encString(snap.phase) .. ","
    .. '"turn":' .. encNumber(snap.turn) .. ","
    .. '"seq":' .. encNumber(snap.seq) .. ","
    .. '"now":' .. encNumber(snap.now) .. ","
    .. '"deadline":' .. (snap.deadline and encNumber(snap.deadline) or "null") .. ","
    .. '"rngState":' .. encNumber(snap.rngState) .. ","
    .. '"field":[' .. table.concat(rows, ",") .. "]"
    .. "}"
end

-- ------------------------------------------------------------------
-- fixtures (synthetic: no species, move or item this repo may not name)
-- ------------------------------------------------------------------

local function mv(id, power, accuracy, ty, pp)
  return { id = id, pp = pp or 60, power = power, accuracy = accuracy,
           type = ty, effect = 0, chance = 0 }
end

-- Gen 2 sheet dialect throughout: spe / spa / spd, never the Gen 1
-- spd=Speed / spc=Special pair, so `copyMon` takes the Gen 2 branch.
local function mn(o)
  local m = {
    species = o.species, level = o.level or 20, hp = o.hp,
    maxHp = o.maxHp or 100, status = o.status, types = o.types,
    stats = { atk = o.atk or 40, def = o.def or 40,
              spe = o.spe or 40, spa = o.spa or 40, spd = o.spd or 40 },
    moves = o.moves,
    stages = o.stages, confusion = o.confusion, focusEnergy = o.focusEnergy,
    -- What the held-item and obedience scenarios add (contracts K1 / K2):
    -- the registry id the species-keyed items read, a sleep counter, the
    -- `traded` flag, a standing Disable, and the item -- { id, HELD_* effect,
    -- parameter, name, mail } -- with synthetic parameters throughout.
    speciesId = o.speciesId, statusTurns = o.statusTurns, traded = o.traded,
    disable = o.disable,
    -- What the review-fix scenarios add: a standing substitute, Bide, Leech
    -- Seed, rage and Transform carried on the sheet.
    substitute = o.substitute, bide = o.bide, leechSeed = o.leechSeed,
    raging = o.raging, rageCounter = o.rageCounter, transformed = o.transformed,
    -- What the side-effect scenarios add: a Mist the sheet carries.
    mist = o.mist,
  }
  if o.item then
    m.heldItem, m.holdEffect, m.holdParam = o.item[1], o.item[2], o.item[3]
    m.itemName, m.mail = o.item[4], o.item[5]
  end
  return m
end

-- A move with an effect id (src/BattleSim2/Effects.lua numbering), which `mv`
-- leaves at 0.
local function fx(id, power, ty, effect, pp)
  return { id = id, pp = pp or 60, power = power, accuracy = 255,
           type = ty, effect = effect, chance = 0 }
end

-- A full move for the held-item scenarios: an effect id and its chance.
local function hm(id, power, ty, effect, pp, chance)
  return { id = id, pp = pp or 60, power = power, accuracy = 255,
           type = ty or 0, effect = effect or 0, chance = chance or 0 }
end

local function build(opts)
  local battle, err = Turn.create(opts)
  if not battle then error("scenario refused: " .. tostring(err), 0) end
  return battle
end

-- ------------------------------------------------------------------
-- scenarios
-- ------------------------------------------------------------------

local scenarios = {}

local function scenario(name, fn)
  scenarios[#scenarios + 1] = { name = name, run = fn }
end

-- The events go into one flat list, and how many came out of each drain goes
-- into a second one beside it.  The counts are not decoration: they are the
-- only record of *when* an event was available, and a clock that fired a turn
-- early produces exactly the same events in exactly the same order, just one
-- drain sooner.
local batches = {}

local function drainInto(battle, events)
  local list = battle:drainEvents()
  for _, event in ipairs(list) do events[#events + 1] = event end
  batches[#batches + 1] = #list
end

-- 1. a wild fight that ends in a KO: one owner seat, one payout, and the
--    rngState afterwards proves the payout drew nothing.
scenario("exp_wild", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "expw", mode = "wild", seed = 4242,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mn({ species = "Alpha", maxHp = 200, atk = 90, spe = 80,
                            moves = { thump() } }) } } },
      b = { { playerId = "wild", name = "Wild",
              mons = { mn({ species = "Beta", maxHp = 60, spe = 10,
                            moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 8 do
    if battle:outcome() then break end
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("wild", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- 2. coop_wild: two owner seats standing at the KO, so two payouts in
--    field-slot order with a divisor of two.
scenario("exp_coop", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "expc", mode = "coop_wild", seed = 5150,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mn({ species = "Alpha", maxHp = 200, atk = 90, spe = 80,
                        moves = { thump() } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mn({ species = "Gamma", maxHp = 200, atk = 90, spe = 70,
                        moves = { thump() } }) } },
      },
      b = { { playerId = "wild", name = "Wild",
              mons = { mn({ species = "Beta", maxHp = 200, spe = 10,
                            moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 8 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:autoPick("wild")
    drainInto(battle, events)
  end
  return battle
end)

-- 3. the replace phase: a foe seat with a bench falls, is solicited by field
--    slot, answers, and only then does the turn advance.  The party index on
--    `switch` / `send` is what stops a client re-fielding the fallen copy of a
--    duplicated species.
scenario("replace", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "rep", mode = "coop_npc", seed = 6161,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann",
          mons = { mn({ species = "Alpha", maxHp = 200, atk = 95, spe = 90,
                        moves = { thump() } }) } },
        { playerId = "a2", name = "Abe",
          mons = { mn({ species = "Gamma", maxHp = 200, atk = 95, spe = 80,
                        moves = { thump() } }) } },
      },
      b = { { playerId = "npc", name = "Foe",
              mons = { mn({ species = "Beta", maxHp = 30, spe = 10,
                            moves = { thump() } }),
                       mn({ species = "Delta", maxHp = 400, spe = 10,
                            moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 4 do
    if battle:outcome() then break end
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    -- Called twice on purpose: the first files the ordinary turn's answer, the
    -- second the replacement the KO opened.  A loop that stopped after one
    -- would leave the phase open, which is what `Hub:fillNpcChoices` does not.
    battle:autoPick("npc")
    battle:autoPick("npc")
    drainInto(battle, events)
  end
  return battle
end)

-- 4. a stolen KO.  `fast` empties foe seat 2; `slow` aimed there too and must
--    swing at seat 3 instead of fizzling -- and must do it having drawn the
--    same bytes the JS twin drew.
scenario("retarget", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "ret", mode = "coop_pvp", seed = 7272,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "fast", name = "Fast",
          mons = { mn({ species = "Alpha", maxHp = 300, atk = 200, spe = 99,
                        moves = { thump() } }) } },
        { playerId = "slow", name = "Slow",
          mons = { mn({ species = "Gamma", maxHp = 300, atk = 200, spe = 90,
                        moves = { thump() } }) } },
      },
      b = {
        { playerId = "foeA", name = "FoeA",
          mons = { mn({ species = "Beta", maxHp = 1, spe = 5,
                        moves = { thump() } }) } },
        { playerId = "foeB", name = "FoeB",
          mons = { mn({ species = "Delta", maxHp = 400, spe = 5,
                        moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("fast", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("slow", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("foeA", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("foeB", { action = "fight", move = 0, target = 0 })
  drainInto(battle, events)
  return battle
end)

-- 5. a whole trapping chain, Gold's way.  TrapTarget sets a 3..6 count;
--    HandleWrap ticks it at the end of every turn -- the one Wrap landed on
--    included -- for a sixteenth of max HP, and releases at 0.  Nobody is
--    forced: the wrapped seat answers every turn, its switch is refused while
--    the count runs and taken once it is released, and the trapper picks its
--    own moves (a plain hit after the first turn).
scenario("trap_chain", function(events)
  local wrap = function()
    return { id = "wrap", pp = 60, power = 5, accuracy = 255, type = 0,
             effect = 42, chance = 0 }
  end
  local battle = build({
    id = "trp", mode = "1v1", seed = 9999,
    choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann",
              mons = { mn({ species = "Alpha", maxHp = 400, spe = 120,
                            moves = { wrap(), mv("tap", 10, 255, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob",
              mons = { mn({ species = "Beta", maxHp = 400, def = 200, spe = 1,
                            moves = { mv("tap", 10, 255, 0) } }),
                       mn({ species = "Gamma", maxHp = 400, spe = 1,
                            moves = { mv("tap", 10, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  for _ = 1, 6 do
    if not battle:submitChoice("p2", { action = "switch", slot = 1 }) then
      battle:submitChoice("p2", { action = "fight", move = 0 })
    end
    battle:submitChoice("p1", { action = "fight", move = 1 })
    drainInto(battle, events)
  end
  return battle
end)

-- the display name a sheet carries (PROTOCOL 26), and the id it falls back to
-- when it carries none.  The Gen 1 pair next door explains the shape; this is
-- the Gen 2 twin of it, because BattleSim2 / lib/battle2 narrate a move from
-- their own copies of the same five call sites.
scenario("move_names", function(events)
  -- `mv` writes effect=0, so the two effect moves are built by hand.  86 is
  -- DISABLE_EFFECT and 82 is MIMIC_EFFECT (src/BattleSim2/Effects.lua).
  local swipe = function()
    return { id = "slow_swipe", name = "SLOW SWIPE", pp = 60, power = 10,
             accuracy = 255, type = 0, effect = 0, chance = 0 }
  end
  local lockdown = function()
    return { id = "lock_down", name = "LOCK DOWN", pp = 60, power = 0,
             accuracy = 255, type = 0, effect = 86, chance = 0 }
  end
  local copycat = function()
    return { id = "copy_cat", name = "COPY CAT", pp = 60, power = 0,
             accuracy = 255, type = 0, effect = 82, chance = 0 }
  end
  local thump = function()
    return { id = "thump", name = "THUMP HIT", pp = 60, power = 10,
             accuracy = 255, type = 0, effect = 0, chance = 0 }
  end
  -- No `name` at all: the protocol-25 sheet, narrated under its id.
  local nudge = function() return mv("nudge", 10, 255, 0) end
  local battle = build({
    id = "mn", mode = "1v1", seed = 4242, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", maxHp = 400, spe = 90,
             moves = { swipe(), lockdown(), copycat() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 400, spe = 10,
             moves = { thump(), nudge() } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 0 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 0 })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 2 })
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drainInto(battle, events)
  for _ = 1, 5 do
    battle:submitChoice("p1", { action = "fight", move = 2 })
    battle:submitChoice("p2", { action = "fight", move = 1 })
    drainInto(battle, events)
  end
  return battle
end)

-- uploaded badge sets, and where the referee lets them count (Turn.BADGE_MODES
-- / Turn.BADGE_SIDE: side a of a fight against the computer, never a link
-- battle -- Crystal's BadgeStatBoosts returns early in one).  Every seat holds
-- all sixteen Gold badges and the ruleset names the types, so a leak would
-- show as a stat boost or a type boost.  Speeds sit a step apart so a PLAIN
-- that leaked would reorder the field rather than merely move a damage
-- number, and the npc fight carries a special move so GLACIER (Sp. Atk) and
-- VOLCANO's type boost are both read.  `badges_link` and `badges_coop_pvp`
-- fight as though nobody held a badge; `badges_npc` boosts side a and ignores
-- side b's upload; `badges_gold` drives the rules a plain fight never reaches
-- -- the 999 cap, Glacier's Sp. Def tail, a type boost on a move with no
-- stat badge behind it, and a confusion self-hit on boosted stats.
local function allBadges()
  return { ZEPHYR = true, HIVE = true, PLAIN = true, FOG = true,
           MINERAL = true, STORM = true, GLACIER = true, RISING = true,
           BOULDER = true, CASCADE = true, THUNDER = true, RAINBOW = true,
           SOUL = true, MARSH = true, VOLCANO = true, EARTH = true }
end

-- Chart index 0 is NORMAL (PLAIN's type), 1 FIRE (VOLCANO's, and Special),
-- 2 BUG (HIVE's).
local TYPE_IDS = { "NORMAL", "FIRE", "BUG" }

scenario("badges_link", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "bl", mode = "1v1", seed = 2718, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = TYPE_IDS,
    sides = {
      a = { { playerId = "p1", name = "Ann", badges = allBadges(), mons = {
        mn({ species = "Alpha", maxHp = 200, atk = 60, spe = 40, moves = { thump() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", maxHp = 200, atk = 60, spe = 42, moves = { thump() } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 3 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

scenario("badges_coop_pvp", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "bp", mode = "coop_pvp", seed = 3141, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = TYPE_IDS,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = allBadges(), mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, spe = 40, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", badges = allBadges(), mons = {
          mn({ species = "Gamma", maxHp = 300, atk = 55, spe = 30, moves = { thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, spe = 42, moves = { thump() } }) } },
        { playerId = "b2", name = "Bea", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 300, atk = 55, spe = 34, moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  return battle
end)

scenario("badges_npc", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local zap = function() return mv("zap", 40, 255, 1) end
  local battle = build({
    id = "bn", mode = "coop_npc", seed = 1618, choiceTimeout = 60, reconnectGrace = 60,
    specialTypes = { 1 },
    typeIds = TYPE_IDS,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = allBadges(), mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, spe = 40, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", badges = allBadges(), mons = {
          mn({ species = "Gamma", maxHp = 300, spa = 60, spd = 50, spe = 30,
               moves = { zap() } }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, spe = 42, moves = { thump() } }) } },
        { playerId = "n2", name = "NpcB", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 300, spa = 60, spd = 50, spe = 37,
               moves = { zap() } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("n1", { action = "fight", move = 0, target = 0 })
    battle:submitChoice("n2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  return battle
end)

scenario("badges_gold", function(events)
  local bite = function() return mv("bite", 40, 255, 2) end
  local thump = function() return mv("thump", 40, 255, 0) end
  local zap = function() return mv("zap", 40, 255, 1) end
  -- Abe is confused, so his turns spend the confusion byte and, on this seed,
  -- hit himself on MINERAL's boosted Defense.
  local abe = mn({ species = "Gamma", maxHp = 300, atk = 50, def = 40,
                   spa = 227, spd = 50, spe = 30, moves = { thump() } })
  abe.confusion = 4
  local battle = build({
    id = "bg", mode = "coop_npc", seed = 2027, choiceTimeout = 60, reconnectGrace = 60,
    specialTypes = { 1 },
    typeIds = TYPE_IDS,
    sides = {
      a = {
        -- 950 Attack under ZEPHYR is the 999 cap; HIVE type-boosts the BUG
        -- move, which no stat badge stands behind.
        { playerId = "a1", name = "Ann", badges = { ZEPHYR = true, PLAIN = true, HIVE = true },
          mons = { mn({ species = "Alpha", maxHp = 300, atk = 950, spe = 40,
                        moves = { bite() } }) } },
        -- Sp. Atk 227 boosts to 255 under GLACIER, which Glacier's tail reads
        -- as a Sp. Def boost too; MINERAL stands behind Defense.
        { playerId = "a2", name = "Abe", badges = { GLACIER = true, MINERAL = true },
          mons = { abe } },
      },
      b = {
        { playerId = "n1", name = "NpcA", badges = allBadges(), mons = {
          mn({ species = "Beta", maxHp = 400, spa = 70, spe = 42, moves = { zap() } }) } },
        { playerId = "n2", name = "NpcB", badges = allBadges(), mons = {
          mn({ species = "Delta", maxHp = 999, def = 600, atk = 70, spe = 37,
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  for _ = 1, 3 do
    battle:submitChoice("a1", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    battle:submitChoice("n1", { action = "fight", move = 0, target = 1 })
    battle:submitChoice("n2", { action = "fight", move = 0, target = 1 })
    drainInto(battle, events)
  end
  return battle
end)

-- CalcPlayerStats' order: the stage, then the badge.  Ann's Attack 100 at -1
-- is 66, which ZEPHYR lifts to 74 (badge first would be 112 -> 73), and her
-- Speed 100 at -1 is 66, which PLAIN lifts to 74 -- one point ahead of NpcA's
-- 73, so she moves first where badge-then-stage tied them.  Abe's Sp. Atk 152
-- at +1 is 228, which GLACIER lifts to 256: an odd tail, so his Sp. Def 100 is
-- boosted too (the unstaged 152 -> 171 would have left it alone).
scenario("stage_badge_order", function(events)
  local slam = function() return mv("slam", 100, 255, 0) end
  local zap = function() return mv("zap", 60, 255, 1) end
  local battle = build({
    id = "sb", mode = "coop_npc", seed = 4096, choiceTimeout = 60, reconnectGrace = 60,
    -- Index 0 names DARK, a type no held badge boosts, so PLAIN moves Speed
    -- and nothing else.
    specialTypes = { 1 }, typeIds = { "DARK", "FIRE" },
    sides = {
      a = {
        { playerId = "a1", name = "Ann", badges = { ZEPHYR = true, PLAIN = true },
          mons = { mn({ species = "Alpha", level = 50, maxHp = 400, atk = 100, spe = 100,
                        types = { 2 }, stages = { atk = -1, spe = -1 },
                        moves = { slam() } }) } },
        { playerId = "a2", name = "Abe", badges = { GLACIER = true },
          mons = { mn({ species = "Gamma", level = 50, maxHp = 400, spa = 152, spd = 100,
                        spe = 30, types = { 2 }, stages = { spa = 1 },
                        moves = { zap() } }) } },
      },
      b = {
        { playerId = "n1", name = "NpcA", mons = {
          mn({ species = "Beta", level = 50, maxHp = 400, def = 20, spe = 73,
               types = { 2 }, moves = { slam() } }) } },
        { playerId = "n2", name = "NpcB", mons = {
          mn({ species = "Delta", level = 50, maxHp = 400, spa = 120, spe = 20,
               types = { 2 }, moves = { zap() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("n1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("n2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  return battle
end)

-- CheckDamageStatsCritical, both ways, on a seed where each side crits once.
-- Both raise Reflect on turn 1.  Ann (Attack +1, Defense +2) crits Bob on
-- turn 3: Bob's Defense stage 0 is lower than her +1, so the boosted pair is
-- kept -- 120 against Bob's Reflect-doubled 160.  Bob (focus energy, for a
-- crit ladder that is not Ann's) crits Ann on turn 2: her +2 is not lower than
-- his 0, so the hit reads the unmodified 80 against 80, no stage and no
-- Reflect.
scenario("crit_stages", function(events)
  local slash = function()
    local m = mv("slash_hit", 70, 255, 0, 30); m.highCrit = true; return m
  end
  local wall = function() return fx("wall_up", 0, 1, 65, 20) end
  local battle = build({
    id = "cr", mode = "1v1", seed = 34, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 30, maxHp = 400, atk = 80, def = 80, spe = 60,
             types = { 2 }, stages = { atk = 1, def = 2 }, moves = { slash(), wall() } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 30, maxHp = 400, atk = 80, def = 80, spe = 50,
             types = { 2 }, focusEnergy = true, moves = { slash(), wall() } }) } } },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("p1", { action = "fight", move = 1 })
  battle:submitChoice("p2", { action = "fight", move = 1 })
  drainInto(battle, events)
  for _ = 1, 3 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- TruncateHL_BC, by cart (contract K6).  Bob's Defense 600 under his Reflect
-- is 1200; Ann's Attack is 200.  Crystal outside a link battle loops: 12
-- against 75.  A link battle on either cart -- and every battle on Gold /
-- Silver, whose routine has no loop -- folds once and keeps the low bytes: 50
-- against 300 -> 44, the wrap bug.  Same sheets, same seed; only the mode and
-- the `family` side a's seat carries (none is Gold / Silver's).
local function truncation(mode, id, foeId, family)
  return function(events)
    local thump = function() return mv("thump", 70, 255, 0) end
    local wall = function() return fx("wall_up", 0, 1, 65, 20) end
    local battle = build({
      id = id, mode = mode, seed = 31337, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", family = family, mons = {
          mn({ species = "Alpha", level = 30, maxHp = 400, atk = 200, spe = 50,
               types = { 2 }, moves = { thump() } }) } } },
        b = { { playerId = foeId, name = "Bob", mons = {
          mn({ species = "Beta", level = 30, maxHp = 400, def = 600, spe = 60,
               types = { 2 }, moves = { wall(), thump() } }) } } },
      },
    })
    drainInto(battle, events)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice(foeId, { action = "fight", move = 0 })
    drainInto(battle, events)
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice(foeId, { action = "fight", move = 1 })
    drainInto(battle, events)
    return battle
  end
end
scenario("truncate_wild", truncation("wild", "tw", "wild"))
scenario("truncate_link", truncation("1v1", "tl", "p2"))
scenario("truncate_crystal_wild", truncation("wild", "tcw", "wild", "crystal"))
scenario("truncate_crystal_link", truncation("1v1", "tcl", "p2", "crystal"))

-- Screens belong to the SIDE.  Ann raises Reflect on turn 1 and her partner
-- Abe is covered by it; her recast on turn 2 fails; she switches out on turn 3
-- and Bob's Haze lands on turn 4, and neither takes it down; it fades at the
-- end of turn 5 (cast turn included), so turn 6 is unscreened.
scenario("screens_side", function(events)
  local thump = function() return mv("thump", 50, 255, 0) end
  local wall = function() return fx("wall_up", 0, 1, 65, 20) end
  local haze = function() return fx("reset_fog", 0, 1, 25, 20) end
  local battle = build({
    id = "ss", mode = "coop_pvp", seed = 8080, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 999, spe = 90, types = { 2 },
               moves = { wall(), thump() } }),
          mn({ species = "Gamma", maxHp = 999, spe = 85, types = { 2 },
               moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Eta", maxHp = 999, spe = 80, types = { 2 },
               moves = { thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 999, atk = 60, spe = 50, types = { 2 },
               moves = { thump(), haze() } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 999, atk = 60, spe = 40, types = { 2 },
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  -- Ann: Reflect, Reflect again, switch to Gamma, then Gamma's one hit.  Bob:
  -- a hit on Abe every turn but the fourth, which is Haze.
  for turn = 1, 6 do
    if turn == 3 then
      battle:submitChoice("a1", { action = "switch", slot = 1 })
    else
      battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    end
    battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    battle:submitChoice("b1", { action = "fight", move = (turn == 4) and 1 or 0, target = 1 })
    battle:submitChoice("b2", { action = "fight", move = 0, target = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- HitConfusion on both sides, on a seed where both confused seats hit
-- themselves on turn 1.  Abe (faster) raises Reflect first, so Ann's self-hit
-- reads her OWN side's Reflect; Bob selected Explosion, so his self-hit reads
-- his Defense halved (DamageCalc's EFFECT_SELFDESTRUCT check sees the
-- selected move).
scenario("self_hit", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local wall = function() return fx("wall_up", 0, 1, 65, 20) end
  local boom = function() return fx("big_boom", 250, 0, 7, 5) end
  local battle = build({
    id = "sh", mode = "coop_pvp", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 300, atk = 60, def = 60, spe = 50,
               types = { 2 }, confusion = 4, moves = { thump() } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 300, spe = 90, types = { 2 },
               moves = { wall() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 300, atk = 60, def = 60, spe = 40,
               types = { 2 }, confusion = 4, moves = { boom() } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 300, spe = 30, types = { 2 },
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  return battle
end)

-- Struggle is typeless.  Index 0 is NORMAL and NORMAL cannot touch a GHOST on
-- this chart; Ann (NORMAL) is out of PP, so her Struggle hits Bob (GHOST) with
-- no STAB, and its recoil is a quarter of what it dealt.
scenario("struggle_typeless", function(events)
  local battle = build({
    id = "st", mode = "1v1", seed = 5555, choiceTimeout = 60, reconnectGrace = 60,
    chart = { { 100, 0 }, { 100, 100 } },
    typeIds = { "NORMAL", "GHOST" },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 30, maxHp = 300, atk = 80, spe = 60,
             types = { 0 }, moves = { mv("thump", 40, 255, 0, 0) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 30, maxHp = 300, def = 60, spe = 50,
             types = { 1 }, moves = { mv("haunt", 40, 255, 1) } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- Metronome with its last PP calls a plain hit: no recoil, because the called
-- move is not Struggle.  The turn after, every slot is empty, so it is.
scenario("metronome_last_pp", function(events)
  local battle = build({
    id = "mt", mode = "1v1", seed = 6060, choiceTimeout = 60, reconnectGrace = 60,
    metronomePool = { mv("pool_hit", 60, 255, 1, 10) },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
        mn({ species = "Alpha", level = 30, maxHp = 300, atk = 80, spe = 60,
             types = { 2 }, moves = { fx("wave_finger", 0, 0, 83, 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = {
        mn({ species = "Beta", level = 30, maxHp = 300, def = 60, spe = 50,
             types = { 2 }, moves = { mv("thump", 40, 255, 0) } }) } } },
    },
  })
  drainInto(battle, events)
  for _ = 1, 2 do
    battle:submitChoice("p1", { action = "fight", move = 0 })
    battle:submitChoice("p2", { action = "fight", move = 0 })
    drainInto(battle, events)
  end
  return battle
end)

-- GetMovePriority's brackets on a four-seat field.  Turn 1: Bob's PROTECT (3)
-- is slowest and moves first, Ann's QUICK_ATTACK (2) next though she is slow,
-- Bea's plain hit (1), then Abe's VITAL_THROW (0) last though he is fastest.
-- Turn 2: EXTREMESPEED and QUICK_ATTACK share a bracket, so Speed decides
-- between them, and both still move before the faster plain hits.
scenario("priority", function(events)
  local thump = function() return mv("thump", 40, 255, 0) end
  local battle = build({
    id = "pr", mode = "coop_pvp", seed = 9090, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 300, spe = 10, types = { 2 },
               moves = { mv("QUICK_ATTACK", 40, 255, 0) } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 300, spe = 99, types = { 2 },
               moves = { fx("VITAL_THROW", 70, 0, 17), thump() } }) } },
      },
      b = {
        { playerId = "b1", name = "Bob", mons = {
          mn({ species = "Beta", maxHp = 300, spe = 5, types = { 2 },
               moves = { mv("PROTECT", 0, 255, 0), mv("EXTREMESPEED", 80, 255, 0) } }) } },
        { playerId = "b2", name = "Bea", mons = {
          mn({ species = "Delta", maxHp = 300, spe = 50, types = { 2 },
               moves = { thump() } }) } },
      },
    },
  })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 0, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 0, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  battle:submitChoice("a1", { action = "fight", move = 0, target = 3 })
  battle:submitChoice("a2", { action = "fight", move = 1, target = 4 })
  battle:submitChoice("b1", { action = "fight", move = 1, target = 0 })
  battle:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  drainInto(battle, events)
  return battle
end)

-- ------------------------------------------------------------------
-- Gold held items, obedience and the flinch reset (docs/plans/
-- gen12-referee-fidelity.md, wave 2).  Every parameter is synthetic.
-- ------------------------------------------------------------------

-- Build, drain, then play each round and drain after it.
local function play(events, opts, rounds)
  local battle = build(opts)
  drainInto(battle, events)
  for _, round in ipairs(rounds) do
    if battle:outcome() then break end
    round(battle)
    drainInto(battle, events)
  end
  return battle
end

-- Quick Claw inside a bracket.  Bea's QUICK_ATTACK is alone in its bracket,
-- so her claw never rolls; in the base bracket Bob's claw rolls first and
-- Ann's only when his missed.  Turns 1-2: Bob missed and Ann's fired (Ann,
-- Speed 10, moves ahead of Abe's 90); turn 3: Bob's fired; turn 4: neither.
scenario("quick_claw", function(events)
  local claw = { "QUICK_CLAW", "HELD_QUICK_CLAW", 100, "QUICK CLAW" }
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    b:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    b:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  end
  return play(events, { id = "qc", mode = "coop_pvp", seed = 4, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 999, spe = 10,
              item = claw, moves = { hm("thump", 10) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 999, spe = 90,
              moves = { hm("thump", 10) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 999, spe = 20,
              item = claw, moves = { hm("thump", 10) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 999, spe = 50,
              item = claw, moves = { hm("QUICK_ATTACK", 10) } }) } } },
    } }, { round, round, round, round })
end)

-- HandleBetweenTurnEffects' held items, in the cart's order: Leftovers (Ann;
-- Bo's is full and stays quiet), Mysteryberry (Abe: SKETCH is his first empty
-- slot, so +1), the screens, the stat-up item (Bea), then the healing items --
-- side b's first, so Bob's Berry before Cal's Gold Berry.  Both berries are
-- eaten: turn 2, under half again, neither heals.
scenario("held_between_turns", function(events)
  local function round(b)
    for _, id in ipairs({ "a1", "a2", "a3" }) do b:submitChoice(id, { action = "fight", move = 0, target = 3 }) end
    for _, id in ipairs({ "b1", "b2", "b3" }) do b:submitChoice(id, { action = "fight", move = 0, target = 1 }) end
  end
  return play(events, { id = "bt", mode = "coop_pvp", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 320, hp = 200, spe = 90,
              item = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }, moves = { hm("tap", 1) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 400, spe = 80,
              item = { "MYSTERYBERRY", "HELD_RESTORE_PP", 0, "MYSTERYBERRY" },
              moves = { hm("tap", 1), hm("SKETCH", 0, 0, 0, 0), hm("spent", 40, 0, 0, 0) } }) } },
            { playerId = "a3", name = "Cal", mons = { mn({ species = "Eta", maxHp = 200, hp = 90, spe = 70,
              item = { "GOLD_BERRY", "HELD_BERRY", 25, "GOLD BERRY" }, moves = { hm("tap", 1) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 200, hp = 99, spe = 60,
              item = { "BERRY", "HELD_BERRY", 12, "BERRY" }, moves = { hm("tap", 1) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 400, spe = 50,
              item = { "X_GEM", "HELD_ATTACK_UP", 0, "X GEM" }, moves = { hm("tap", 1) } }) } },
            { playerId = "b3", name = "Bo", mons = { mn({ species = "Zeta", maxHp = 400, spe = 40,
              item = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round })
end)

-- The status berries, both ways.  Right after a status lands: Bob's Mint Berry
-- cures the sleep Ann's move put on him, Bea's PsnCureBerry the poison Abe's
-- hit did, Bo's Bitter Berry the confusion Cal's did -- each eaten, so turn 2's
-- sleep and confusion stay.  Between turns: Ann's MiracleBerry takes her PSN
-- and her confusion together, Abe's Bitter Berry his confusion, Cal's Ice Berry
-- his burn.
scenario("status_berries", function(events)
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    b:submitChoice("a3", { action = "fight", move = 0, target = 5 })
    for _, id in ipairs({ "b1", "b2", "b3" }) do b:submitChoice(id, { action = "fight", move = 0, target = 0 }) end
  end
  return play(events, { id = "sb", mode = "coop_pvp", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, status = "PSN",
              confusion = 3, item = { "MIRACLEBERRY", "HELD_HEAL_STATUS", 0, "MIRACLEBERRY" },
              moves = { hm("doze_dust", 0, 0, 32) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 300, spe = 80,
              confusion = 4, item = { "BITTER_BERRY", "HELD_HEAL_CONFUSION", 0, "BITTER BERRY" },
              moves = { hm("venom_jab", 20, 0, 2, 60, 100) } }) } },
            { playerId = "a3", name = "Cal", mons = { mn({ species = "Eta", maxHp = 300, spe = 70, status = "BRN",
              item = { "ICE_BERRY", "HELD_HEAL_BURN", 0, "ICE BERRY" }, moves = { hm("daze_ray", 0, 0, 49) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 60,
              item = { "MINT_BERRY", "HELD_HEAL_SLEEP", 0, "MINT BERRY" }, moves = { hm("tap", 1) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 300, spe = 50,
              item = { "PSNCUREBERRY", "HELD_HEAL_POISON", 0, "PSNCUREBERRY" }, moves = { hm("tap", 1) } }) } },
            { playerId = "b3", name = "Bo", mons = { mn({ species = "Zeta", maxHp = 300, spe = 40,
              item = { "BITTER_BERRY", "HELD_HEAL_CONFUSION", 0, "BITTER BERRY" }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round })
end)

-- Focus Band rolls on every hit: turns 1-2 are not lethal (the bytes are
-- drawn, nothing is said), turn 3's would be and the band holds Bob at 1 HP,
-- turn 4's roll misses and he faints.
scenario("focus_band", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "fb", mode = "1v1", seed = 11, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, atk = 60, spe = 90,
              types = { 2 }, moves = { hm("thump", 40) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 40, spe = 10, types = { 2 },
              item = { "FOCUS_BAND", "HELD_FOCUS_BAND", 160, "FOCUS BAND" }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round, round, round, round })
end)

-- King's Rock.  Turn 1: Ann's plain hit (a `kingsrock` script) flinches Bob,
-- who has not moved.  Turn 2: THUNDER, on its own Gold-native id (97), runs
-- no `kingsrock`, so Ann rolls nothing; Bob's hit lands his own roll on
-- Ann, who already moved.  Turn 3: that flag died at the turn's open, so Ann
-- acts -- with a burn hit, another script without the command.  Turn 4: a
-- plain hit again.
scenario("kings_rock", function(events)
  local rock = { "KINGS_ROCK", "HELD_FLINCH", 200, "KING'S ROCK" }
  local rounds = {}
  for i, picks in ipairs({ { 0, 0 }, { 1, 0 }, { 2, 0 }, { 0, 0 } }) do
    rounds[i] = function(b)
      b:submitChoice("p1", { action = "fight", move = picks[1] })
      b:submitChoice("p2", { action = "fight", move = picks[2] })
    end
  end
  return play(events, { id = "kr", mode = "1v1", seed = 1, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 999, spe = 90, types = { 2 },
              item = rock, moves = { hm("thump", 10), hm("THUNDER", 10, 0, 97), hm("ember_hit", 10, 0, 4) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 999, spe = 10, types = { 2 },
              item = rock, moves = { hm("thump", 10) } }) } } },
    } }, rounds)
end)

-- Thief's row: its 100% effect chance (`percent 100`), which the script's
-- `effectchance` rolls before the hit.
local function thief(power) return hm("THIEF", power, 0, 0, nil, 100) end

-- Thief, both ways, against the computer: Ann takes the wild monster's
-- Leftovers, the wild monster takes them straight back, and they heal it at the
-- end of the turn; turn 2 is the same trade.
scenario("thief", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end
  return play(events, { id = "th", mode = "wild", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 },
              moves = { thief(10) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", maxHp = 320, spe = 10, types = { 2 },
              item = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }, moves = { thief(10) } }) } } },
    } }, { round, round })
end)

-- Thief refused and allowed: Ann already holds a Berry, so she takes nothing;
-- Bea's FLOWER_MAIL is Mail; Cal's hit knocks Bo out and still takes his Quick
-- Claw (`thief` runs before checkfaint).
scenario("thief_refused", function(events)
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    b:submitChoice("a3", { action = "fight", move = 0, target = 5 })
    for _, id in ipairs({ "b1", "b2", "b3" }) do b:submitChoice(id, { action = "fight", move = 0, target = 0 }) end
  end
  return play(events, { id = "tr", mode = "coop_pvp", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 },
              item = { "BERRY", "HELD_BERRY", 12, "BERRY" }, moves = { thief(10) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 300, spe = 80, types = { 2 },
              moves = { thief(10) } }) } },
            { playerId = "a3", name = "Cal", mons = { mn({ species = "Eta", maxHp = 300, atk = 200, spe = 70,
              types = { 2 }, moves = { thief(60) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 60, types = { 2 },
              item = { "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" }, moves = { hm("tap", 1) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 300, spe = 50, types = { 2 },
              item = { "FLOWER_MAIL", nil, 0, "FLOWER MAIL", true }, moves = { hm("tap", 1) } }) } },
            { playerId = "b3", name = "Bo", mons = { mn({ species = "Zeta", maxHp = 5, spe = 40, types = { 2 },
              item = { "QUICK_CLAW", "HELD_QUICK_CLAW", 100, "QUICK CLAW" }, moves = { hm("tap", 1) } }) } } },
    } }, { round })
end)

-- Berserk Gene.  The wild one's goes off as the first turn opens: Attack +2 and
-- a confusion with nothing behind its seat's count, so 256.  Its daze ray
-- confuses Ann's Alpha (count 4), Ann switches, and her gene-holding Gamma goes
-- off at the next turn's open inheriting that 4.
scenario("berserk_gene", function(events)
  local gene = { "BERSERK_GENE", nil, 0, "BERSERKGENE" }
  local rounds = {
    function(b)
      b:submitChoice("p1", { action = "fight", move = 0 })
      b:submitChoice("wild", { action = "fight", move = 0 })
    end,
    function(b)
      b:submitChoice("p1", { action = "switch", slot = 1 })
      b:submitChoice("wild", { action = "fight", move = 1 })
    end,
    function(b)
      b:submitChoice("p1", { action = "fight", move = 0 })
      b:submitChoice("wild", { action = "fight", move = 1 })
    end,
  }
  return play(events, { id = "bg2", mode = "wild", seed = 2, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = {
              mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 }, moves = { hm("tap", 1) } }),
              mn({ species = "Gamma", maxHp = 300, spe = 80, types = { 2 }, item = gene,
                   moves = { hm("tap", 1) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", maxHp = 300, spe = 10,
              types = { 2 }, item = gene, moves = { hm("daze_ray", 0, 0, 49), hm("tap", 1) } }) } } },
    } }, rounds)
end)

-- Metal Powder reads the PARTY species, on Crystal's looping fold: Bob, a
-- Ditto, keeps it after he transforms into Ann -- whose Defense 200 overflows
-- the boost, so the hit's attack is halved too -- and Bea, a Mew, transforms
-- into a Ditto (Abe) and gets nothing.
scenario("metal_powder", function(events)
  local powder = { "METAL_POWDER", "HELD_METAL_POWDER", 0, "METAL POWDER" }
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    b:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    b:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  end
  return play(events, { id = "mp", mode = "coop_pvp", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", family = "crystal", mons = { mn({ species = "Alpha", maxHp = 400,
              atk = 120, def = 200, spe = 90, types = { 2 }, moves = { hm("thump", 40) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", speciesId = "DITTO", maxHp = 400,
              atk = 120, def = 60, spe = 80, types = { 2 }, moves = { hm("thump", 40) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", speciesId = "DITTO", maxHp = 400,
              def = 60, spe = 60, types = { 2 }, item = powder, moves = { hm("copycat", 0, 0, 57) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", speciesId = "MEW", maxHp = 400,
              def = 60, spe = 50, types = { 2 }, item = powder, moves = { hm("copycat", 0, 0, 57) } }) } } },
    } }, { round, round })
end)

-- Light Ball doubles Pikachu's special attack only and Thick Club Cubone's
-- physical attack only, before the fold -- which, on Gold's one pass, wraps
-- Bob's doubled 600: 1200 / 4 = 300, low byte 44.
scenario("species_items", function(events)
  local rounds = {}
  for i, picks in ipairs({ { 0, 0 }, { 1, 1 } }) do
    rounds[i] = function(b)
      b:submitChoice("p1", { action = "fight", move = picks[1] })
      b:submitChoice("p2", { action = "fight", move = picks[2] })
    end
  end
  return play(events, { id = "si", mode = "1v1", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    specialTypes = { 1 },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", speciesId = "PIKACHU", level = 30,
              maxHp = 600, atk = 100, spa = 100, def = 100, spd = 100, spe = 90, types = { 2 },
              item = { "LIGHT_BALL", nil, 0, "LIGHT BALL" }, moves = { hm("zap", 40, 1), hm("thump", 40) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", speciesId = "CUBONE", level = 30,
              maxHp = 600, atk = 600, spa = 100, def = 100, spd = 100, spe = 10, types = { 2 },
              item = { "THICK_CLUB", nil, 0, "THICK CLUB" }, moves = { hm("thump", 40), hm("zap", 40, 1) } }) } } },
    } }, rounds)
end)

-- Type-boost items: Ann's Charcoal on her FIRE move; Bob's Pink Bow on his
-- Struggle (its row says NORMAL); and Ann's Charcoal again on her confusion
-- self-hits, because the move she selected is FIRE -- the cart bug.
scenario("type_boost", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "tb", mode = "1v1", seed = 1, choiceTimeout = 60, reconnectGrace = 60,
    specialTypes = { 1 }, typeIds = { "NORMAL", "FIRE", "WATER" },
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", level = 30, maxHp = 600, atk = 100,
              spa = 100, def = 100, spd = 100, spe = 90, types = { 2 }, confusion = 5,
              item = { "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" }, moves = { hm("ember_hit", 40, 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", level = 30, maxHp = 600, atk = 100,
              def = 100, spe = 10, types = { 2 }, item = { "PINK_BOW", "HELD_NORMAL_BOOST", 20, "PINK BOW" },
              moves = { hm("thump", 40, 0, 0, 0) } }) } } },
    } }, { round, round, round })
end)

-- Crit items: Chansey's Lucky Punch sets the level to 2 whatever Focus Energy
-- and the high-crit move would add; Bob's Scope Lens adds one.
scenario("crit_items", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  local slash = hm("slash_hit", 20)
  slash.highCrit = true
  return play(events, { id = "ci", mode = "1v1", seed = 2, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", speciesId = "CHANSEY", maxHp = 900,
              spe = 90, types = { 2 }, focusEnergy = true, item = { "LUCKY_PUNCH", nil, 0, "LUCKY PUNCH" },
              moves = { slash } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 },
              item = { "SCOPE_LENS", "HELD_CRITICAL_UP", 0, "SCOPE LENS" }, moves = { hm("thump", 20) } }) } } },
    } }, { round, round, round, round, round, round })
end)

-- Bright Powder: Ann's sure hit misses Bob at the powder's rate, and her
-- Swift-effect move never does.
scenario("bright_powder", function(events)
  local rounds = {}
  for i = 1, 6 do
    rounds[i] = function(b)
      b:submitChoice("p1", { action = "fight", move = (i % 2 == 1) and 0 or 1 })
      b:submitChoice("p2", { action = "fight", move = 0 })
    end
  end
  return play(events, { id = "bp", mode = "1v1", seed = 1, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 900, spe = 90, types = { 2 },
              moves = { hm("thump", 10), hm("star_dart", 10, 0, 17) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 },
              item = { "BRIGHTPOWDER", "HELD_BRIGHTPOWDER", 120, "BRIGHTPOWDER" }, moves = { hm("tap", 1) } }) } } },
    } }, rounds)
end)

-- Obedience: a traded level-80 monster with no badge (cap 10) against a wild
-- one.  On this seed it uses another move instead (turns 1 and 7), loafs
-- around (2), turns away (3), won't obey and hits itself (4), obeys (5),
-- ignores orders (6) and naps (8).
scenario("obey_traded", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end
  return play(events, { id = "ob", mode = "wild", seed = 660, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", level = 80, maxHp = 900, atk = 60,
              def = 200, spe = 90, types = { 2 }, traded = true,
              moves = { hm("thump", 10), hm("pound_two", 10), hm("pound_three", 10), hm("pound_four", 10) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", level = 80, maxHp = 900, spe = 10,
              types = { 2 }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round, round, round, round, round, round })
end)

-- Obedience while asleep: Snore and Sleep Talk pass the sleep gate ("fast
-- asleep", then the move), and a disobedient sleeper "ignored orders...sleeping!".
scenario("obey_asleep", function(events)
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    b:submitChoice("wild", { action = "fight", move = 0, target = 0 })
  end
  return play(events, { id = "oa", mode = "coop_wild", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", level = 60, maxHp = 900, spe = 90,
              types = { 2 }, status = "SLP", statusTurns = 7, traded = true,
              moves = { hm("SNORE", 10), hm("thump", 10) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", level = 60, maxHp = 900, spe = 80,
              types = { 2 }, status = "SLP", statusTurns = 7, traded = true,
              moves = { hm("SLEEP_TALK", 0), hm("thump", 10) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", level = 60, maxHp = 900, spe = 10,
              types = { 2 }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round, round })
end)

-- Obedience caps by badge: RISING obeys at level 100, STORM's 70 lets a
-- level-70 monster obey -- neither draws a byte -- and a level-75 one under
-- STORM is asked every turn.
scenario("obey_badges", function(events)
  local function round(b)
    for _, id in ipairs({ "a1", "a2", "a3" }) do b:submitChoice(id, { action = "fight", move = 0, target = 3 }) end
    b:submitChoice("wild", { action = "fight", move = 0, target = 0 })
  end
  local function seat(id, name, species, level, spe, badges)
    return { playerId = id, name = name, badges = badges, mons = { mn({ species = species, level = level,
             maxHp = 900, spe = spe, types = { 2 }, traded = true,
             moves = { hm("thump", 10), hm("pound_two", 10) } }) } }
  end
  return play(events, { id = "obb", mode = "coop_wild", seed = 1, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { seat("a1", "Ann", "Alpha", 100, 88, { RISING = true }),
            seat("a2", "Abe", "Gamma", 70, 90, { STORM = true, FOG = true, HIVE = true }),
            seat("a3", "Cal", "Eta", 75, 85, { STORM = true }) },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", level = 50, maxHp = 900, spe = 10,
              types = { 2 }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round, round })
end)

-- `.UseInstead` with nowhere to go loafs instead: Ann knows one move, Abe's
-- other move is out of PP, Cal's is disabled -- on this seed each of them
-- reaches the branch at least once.
scenario("obey_fallbacks", function(events)
  local function round(b)
    for _, id in ipairs({ "a1", "a2", "a3" }) do b:submitChoice(id, { action = "fight", move = 0, target = 3 }) end
    b:submitChoice("wild", { action = "fight", move = 0, target = 0 })
  end
  return play(events, { id = "obf", mode = "coop_wild", seed = 7, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", level = 80, maxHp = 900, spe = 90,
              types = { 2 }, traded = true, moves = { hm("thump", 10) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", level = 80, maxHp = 900, spe = 80,
              types = { 2 }, traded = true, moves = { hm("thump", 10), hm("pound_two", 10, 0, 0, 0) } }) } },
            { playerId = "a3", name = "Cal", mons = { mn({ species = "Eta", level = 80, maxHp = 900, spe = 70,
              types = { 2 }, traded = true, disable = { moveIndex = 2, turns = 9 },
              moves = { hm("thump", 10), hm("pound_two", 10) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", level = 50, maxHp = 900, spe = 10,
              types = { 2 }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round, round, round, round })
end)

-- Never in a link battle and never on side b: a traded level-80 sheet on each
-- obeys without a draw (the rngState is the untraded fight's).
local function obeyNever(mode, id)
  return function(events)
    local foe = (mode == "wild") and "wild" or "p2"
    local function round(b)
      b:submitChoice("p1", { action = "fight", move = 0 })
      b:submitChoice(foe, { action = "fight", move = 0 })
    end
    return play(events, { id = id, mode = mode, seed = 99, choiceTimeout = 60, reconnectGrace = 60,
      sides = {
        a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha",
                level = (mode == "wild") and 5 or 80, maxHp = 900, spe = 90, types = { 2 },
                traded = (mode ~= "wild") or nil, moves = { hm("thump", 10), hm("pound_two", 10) } }) } } },
        b = { { playerId = foe, name = "Bob", mons = { mn({ species = "Beta", level = 80, maxHp = 900, spe = 10,
                types = { 2 }, traded = true, moves = { hm("tap", 1), hm("pound_two", 1) } }) } } },
      } }, { round, round, round, round })
  end
end
scenario("obey_link", obeyNever("1v1", "ol"))
scenario("obey_side_b", obeyNever("wild", "osb"))

-- The review fixes (docs/plans/gen12-referee-fidelity.md, wave-2 review).
--
-- Thief into a substitute: `effectchance` fails on CheckSubstituteOpp before
-- any byte is drawn, so the three hits that land on the doll (the third breaks
-- it) take nothing; the fourth reaches the HP and steals.
scenario("thief_substitute", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end
  return play(events, { id = "tsu", mode = "wild", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 },
              moves = { thief(10) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", maxHp = 320, spe = 10, types = { 2 },
              substitute = 8, item = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round, round })
end)

-- The 1/256: on this seed the effect-chance byte is 255, not under Thief's
-- $ff, so wEffectFailed stays set and Bob keeps his Charcoal.
scenario("thief_chance_miss", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "tcm", mode = "1v1", seed = 153, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 },
              moves = { thief(10) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 400, spe = 10, types = { 2 },
              item = { "CHARCOAL", "HELD_FIRE_BOOST", 20, "CHARCOAL" }, moves = { hm("tap", 1) } }) } } },
    } }, { round })
end)

-- A Bide's release skips `checkobedience` (StoreEnergy's SkipToBattleCommand):
-- Ann's traded level-80 monster unleashes on turn 1 drawing no obedience byte
-- (this seed's first draws are a "used instead" when they are drawn), and
-- only Bide's next first use, turn 2, is asked.
scenario("obey_bide", function(events)
  local function release(b) b:submitChoice("wild", { action = "fight", move = 0 }) end
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end
  return play(events, { id = "obb", mode = "wild", seed = 2, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", level = 80, maxHp = 900, spe = 90,
              types = { 2 }, traded = true, bide = { turns = 0, stored = 40, moveIndex = 1, targetSlot = 3 },
              moves = { hm("BIDE", 0, 0, 26, 10), hm("tap", 10) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 },
              moves = { hm("tap", 1) } }) } } },
    } }, { release, round, round })
end)

-- A Bide aimed at seat 0 releases on seat 0: on this seed the aim stream would
-- pick seat 1, which is where `targetSlot || foe.slot` used to send it.
scenario("bide_slot0", function(events)
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 3 })
    b:submitChoice("b2", { action = "fight", move = 0, target = 0 })
  end
  return play(events, { id = "bs0", mode = "coop_pvp", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 },
              moves = { hm("tap", 1) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 300, spe = 80, types = { 2 },
              moves = { hm("tap", 1) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 10, types = { 2 },
              bide = { turns = 0, stored = 30, moveIndex = 1, targetSlot = 0 },
              moves = { hm("BIDE", 0, 0, 26, 10), hm("tap", 1) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 300, spe = 20, types = { 2 },
              moves = { hm("tap", 1) } }) } } },
    } }, { round })
end)

-- CheckTurn's order: confusion before paralysis.  A paralysed, confused
-- monster rolls its confusion first; a self-hit ends the turn with no
-- paralysis byte, and "snapped out" still meets the paralysis gate after it.
scenario("gate_para_confused", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "gpc", mode = "1v1", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 },
              status = "PAR", confusion = 4, moves = { hm("thump", 10) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 10, types = { 2 },
              moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round, round })
end)

-- ...and the disabled move before paralysis: Bob (faster) disables the move
-- Ann's paralysed monster chose, which stops it with no paralysis byte.
scenario("gate_para_disabled", function(events)
  local function pick(a, b)
    return function(battle)
      battle:submitChoice("p1", { action = "fight", move = a })
      battle:submitChoice("p2", { action = "fight", move = b })
    end
  end
  return play(events, { id = "gpd", mode = "1v1", seed = 9, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 10, types = { 2 },
              status = "PAR", moves = { hm("thump", 10), hm("pound_two", 10) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 90, types = { 2 },
              moves = { hm("DISABLE", 0, 0, 86), hm("tap", 1) } }) } } },
    } }, { pick(0, 1), pick(0, 0), pick(1, 1) })
end)

-- A transformed Mysteryberry holder keeps the berry: the cart scans the party
-- PP, which the copied moves never spend.  Ditto copies Wild's one-PP tap and
-- empties it on turn 2.
scenario("mysteryberry_transformed", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end
  return play(events, { id = "mbt", mode = "wild", seed = 5, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Ditto", speciesId = "DITTO", maxHp = 300,
              spe = 90, types = { 2 }, item = { "MYSTERYBERRY", "HELD_RESTORE_PP", 0, "MYSTERYBERRY" },
              moves = { hm("TRANSFORM", 0, 0, 57, 10) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", maxHp = 300, spe = 10, types = { 2 },
              moves = { hm("tap", 1, 0, 0, 1) } }) } } },
    } }, { round, round, round })
end)

-- GetSixteenthMaxHP past 1024: the quarter's high byte rides through, so
-- Leftovers on an 1100-HP holder heals 260.
scenario("leftovers_large", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "lol", mode = "1v1", seed = 4, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 1100, hp = 500, spe = 90,
              types = { 2 }, item = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }, moves = { hm("tap", 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 10, types = { 2 },
              moves = { hm("tap", 1) } }) } } },
    } }, { round })
end)

-- A Leech Seed sap that knocks the seeded monster out: the seeder's seat is
-- read before the faint clears the seed, and the seeder is healed.
scenario("leech_seed_ko", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "lsk", mode = "1v1", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, hp = 100, spe = 90,
              types = { 2 }, moves = { hm("tap", 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 320, hp = 10, spe = 10,
              types = { 2 }, leechSeed = { fromSlot = 0 }, moves = { hm("tap", 1) } }) } } },
    } }, { round, round })
end)

-- Gold / Crystal Rage: no lock-in and no Attack stage.  Each hit that leaves
-- the raging monster standing builds its counter (a multi-hit move once per
-- hit, with the cart's line), Rage's damage is multiplied by the counter plus
-- one, and choosing another move ends the rage and zeroes the counter.
scenario("rage", function(events)
  local function pick(a, b)
    return function(battle)
      battle:submitChoice("p1", { action = "fight", move = a })
      battle:submitChoice("p2", { action = "fight", move = b })
    end
  end
  return play(events, { id = "rg", mode = "1v1", seed = 11, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 500, spe = 90, types = { 2 },
              moves = { hm("RAGE", 20, 0, 81), hm("tap", 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 },
              moves = { hm("pelt", 5, 0, 29), hm("tap", 1) } }) } } },
    } }, { pick(0, 0), pick(0, 1), pick(1, 0), pick(0, 0) })
end)

-- The counter's ceiling: a hit into the raging monster's substitute builds
-- (it did not miss), 254 -> 255 says so once, and the later hits of the same
-- move find it full and say nothing; Rage then multiplies by 256.
scenario("rage_cap", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "rgc", mode = "1v1", seed = 21, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 500, spe = 10, types = { 2 },
              raging = true, rageCounter = 254, substitute = 30,
              moves = { hm("RAGE", 20, 0, 81), hm("tap", 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 999, spe = 90, types = { 2 },
              moves = { hm("pelt", 5, 0, 29) } }) } } },
    } }, { round, round })
end)

-- Only a foe's move builds rage: a confusion self-hit (turn 2) and poison
-- between turns never do.
scenario("rage_sources", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "rgs", mode = "1v1", seed = 1, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 500, spe = 90, types = { 2 },
              status = "PSN", confusion = 3, moves = { hm("RAGE", 20, 0, 81), hm("tap", 1) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 },
              moves = { hm("thump", 10) } }) } } },
    } }, { round, round, round, round })
end)

-- A secondary effect never lands on a target the hit knocked out (`checkfaint`
-- ends the script first): Ann's burning hit KOs Bob's first monster, Abe's
-- confusing hit KOs the second, and neither says a word about it -- nor draws
-- the confusion's turn count.
scenario("side_effect_ko", function(events)
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    b:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    b:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  end
  return play(events, { id = "sko", mode = "coop_pvp", seed = 6, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 2 },
              moves = { hm("ember_hit", 40, 0, 4, nil, 100) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 300, spe = 80, types = { 2 },
              moves = { hm("daze_hit", 40, 0, 76, nil, 100) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, hp = 2, spe = 10,
              types = { 2 }, moves = { hm("tap", 1) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 300, hp = 2, spe = 20,
              types = { 2 }, moves = { hm("tap", 1) } }) } } },
    } }, { round })
end)

-- The carts' side-effect conditions (FX6), on a named chart: NORMAL 0,
-- FIRE 1, ICE 2, ELECTRIC 3, POISON 4, BUG 5, STEEL 6.
local SIDE_TYPES = { "NORMAL", "FIRE", "ICE", "ELECTRIC", "POISON", "BUG", "STEEL" }

-- Type immunities at 100%: Ann's Fire hit never burns Bob (Fire),
-- Abe's Ice hit never freezes Bea (Ice), Bob's Bug Twineedle poisons Ann
-- (Steel: CheckIfTargetIsPoisonType asks POISON alone), and Bea's Electric hit
-- paralyses Abe (Electric: ParalyzeTarget asks no type).
scenario("side_immunity", function(events)
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    b:submitChoice("b1", { action = "fight", move = 0, target = 0 })
    b:submitChoice("b2", { action = "fight", move = 0, target = 1 })
  end
  return play(events, { id = "sim", mode = "coop_pvp", seed = 12, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = SIDE_TYPES,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 6 },
              moves = { hm("ember_hit", 10, 1, 4, nil, 100) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 300, spe = 80, types = { 3 },
              moves = { hm("chill_hit", 10, 2, 5, nil, 100) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 20, types = { 1 },
              moves = { hm("needles", 10, 5, 77, nil, 100) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 300, spe = 10, types = { 2 },
              moves = { hm("spark_hit", 10, 3, 6, nil, 100) } }) } } },
    } }, { round, round })
end)

-- BurnTarget's Defrost: Ann's 10% Fire hit thaws Bob whatever its chance byte
-- says, and Bob then takes his turn.
scenario("side_defrost", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "sdf", mode = "1v1", seed = 4, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = SIDE_TYPES,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 0 },
              moves = { hm("ember_hit", 10, 1, 4, nil, 10) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 10, types = { 0 },
              status = "FRZ", moves = { hm("tap", 1) } }) } } },
    } }, { round, round })
end)

-- FlinchTarget's `and 1 << FRZ | SLP_MASK`: Ann's 100% flinch hit sets
-- nothing on sleeping Bob, so the turn he wakes he acts; once awake he
-- flinches.
scenario("side_flinch_sleep", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "sfs", mode = "1v1", seed = 6, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = SIDE_TYPES,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 90, types = { 0 },
              moves = { hm("bite_hit", 10, 0, 31, nil, 100) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 300, spe = 10, types = { 0 },
              status = "SLP", statusTurns = 2, moves = { hm("tap", 1) } }) } } },
    } }, { round, round, round })
end)

-- BattleCommand_StatDown's `.ComputerMiss`, wild: the computer's 30% Attack-
-- down hit draws its byte into Ann's substitute (silently), and after it
-- breaks, whether or not the chance byte landed; its GROWL draws it too, and
-- on this seed misses on it into the substitute (turn 2, "But it failed"
-- rather than the substitute's "nothing happened").  Ann starts at -5, so
-- once a drop lands (turn 5) she is at -6 and the routine stops before the
-- byte -- silently for the hit, "won't go any lower" for GROWL.
scenario("computer_drops", function(events)
  local function pick(move)
    return function(b)
      b:submitChoice("p1", { action = "fight", move = 0 })
      b:submitChoice("wild", { action = "fight", move = move })
    end
  end
  return play(events, { id = "cdr", mode = "wild", seed = 3, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = SIDE_TYPES,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 400, spe = 10, types = { 0 },
              substitute = 6, stages = { atk = -5 }, moves = { hm("wait", 0, 0, 85) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", maxHp = 400, spe = 90, types = { 0 },
              moves = { hm("aurora_hit", 10, 2, 68, nil, 30), hm("growl", 0, 0, 18) } }) } } },
    } }, { pick(0), pick(1), pick(0), pick(0), pick(0), pick(1), pick(0), pick(0), pick(0), pick(1) })
end)

-- ...and coop_npc, after a miss: both NPC seats throw a 1% GROWL.  Ann is
-- under Mist, so the routine stops before the byte; Abe is not, so the
-- computer draws it after the accuracy byte missed.
scenario("computer_growl_miss", function(events)
  local function round(b)
    b:submitChoice("a1", { action = "fight", move = 0, target = 3 })
    b:submitChoice("a2", { action = "fight", move = 0, target = 4 })
    b:submitChoice("n1", { action = "fight", move = 0, target = 0 })
    b:submitChoice("n2", { action = "fight", move = 0, target = 1 })
  end
  local function growl() return { id = "growl", pp = 30, power = 0, accuracy = 1, type = 0, effect = 18, chance = 0 } end
  return play(events, { id = "cgm", mode = "coop_npc", seed = 9, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = SIDE_TYPES,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 300, spe = 10, types = { 0 },
              mist = true, moves = { hm("wait", 0, 0, 85) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 300, spe = 20, types = { 0 },
              moves = { hm("wait", 0, 0, 85) } }) } } },
      b = { { playerId = "n1", name = "Foe", mons = { mn({ species = "Beta", maxHp = 300, spe = 90, types = { 0 },
              moves = { growl() } }) } },
            { playerId = "n2", name = "Fay", mons = { mn({ species = "Delta", maxHp = 300, spe = 80, types = { 0 },
              moves = { growl() } }) } } },
    } }, { round, round })
end)

-- ------------------------------------------------------------------
-- the referee-gaps run (docs/plans/gen12-referee-gaps-fix.md, R2a): the
-- Gold-native secondary effects (Effects.lua 87..101), `effectchance` on a
-- miss, per-hit multi-hit draws, LEECH SEED's eighth, no 999 cap after STAB,
-- Gold's wrap (`trap_chain` above), recoil into a substitute, a rampage at
-- 0 PP, MIRROR MOVE's last move used, a METRONOME-called charge, Pay Day and
-- HYPER BEAM's recharge.  Every number synthetic.
-- ------------------------------------------------------------------

-- One seat a side; `rounds` is a list of { playerId, choice } lists, each
-- submitted in order -- or "tick", one second on the clock, for a turn every
-- seat is forced through.
local function duo(id, mode, seed, aMons, bMons, extra)
  local o = { id = id, mode = mode, seed = seed, choiceTimeout = 60, reconnectGrace = 60,
    sides = { a = { { playerId = "p1", name = "Ann", mons = aMons } },
              b = { { playerId = "p2", name = "Bob", mons = bMons } } } }
  if extra then
    o.typeIds = extra.typeIds
    o.metronomePool = extra.metronomePool
  end
  return o
end
local function seq(events, opts, rounds)
  local fns = {}
  for i, list in ipairs(rounds) do
    if list == "tick" then
      fns[i] = function(b) b:tick(b.now + 1) end
    else
      fns[i] = function(b)
        for _, pair in ipairs(list) do b:submitChoice(pair[1], pair[2]) end
      end
    end
  end
  return play(events, opts, fns)
end
local function F(i) return { action = "fight", move = i } end
local function S(slot) return { action = "switch", slot = slot } end
local function both(a, b) return { { "p1", a }, { "p2", b } } end

-- The stat hits.  Ann (against the computer) lowers Bob's Sp. Def with CRUNCH
-- (87), raises her Attack with METAL CLAW (89) -- +5 -> +6 -- then
-- ANCIENTPOWER (91) raises all but the Attack already at +6, and STEEL WING
-- (90) fails silently on a Defense of 999.  Bob's MUD-SLAP (88) is the
-- computer's ACCURACY_DOWN_HIT: no `.ComputerMiss` byte.
scenario("gold_stat_hits", function(events)
  return seq(events, duo("gsh", "wild", 501,
    { mn({ species = "Alpha", maxHp = 400, def = 999, spe = 90, stages = { atk = 5 },
           moves = { hm("CRUNCH", 20, 0, 87, 60, 100), hm("METAL_CLAW", 20, 0, 89, 60, 100),
                     hm("ANCIENTPOWER", 20, 0, 91, 60, 100), hm("STEEL_WING", 20, 0, 90, 60, 100) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("MUD_SLAP", 5, 0, 88, 60, 100) } }) }),
    { both(F(0), F(0)), both(F(1), F(0)), both(F(2), F(0)), both(F(3), F(0)) })
end)

-- FLAME WHEEL (92) and SACRED FIRE (93): both monsters frozen; each passes
-- CheckTurn's freeze by move id, Ann's hit thaws Bob through BurnTarget's
-- Defrost, and her own `defrost` thaws her.
scenario("flame_wheel_thaw", function(events)
  return seq(events, duo("fwt", "1v1", 502,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, status = "FRZ", types = { 0 },
           moves = { hm("FLAME_WHEEL", 30, 1, 92, 60, 100) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, status = "FRZ", types = { 0 },
           moves = { hm("SACRED_FIRE", 30, 1, 93, 60, 100) } }) },
    { typeIds = SIDE_TYPES }),
    { both(F(0), F(0)), both(F(0), F(0)) })
end)

-- STOMP (94) against a MINIMIZE that went up (wEnemyMinimized): doubled after
-- the variation; a switch-in clears it.
scenario("stomp_minimize", function(events)
  return seq(events, duo("stm", "1v1", 503,
    { mn({ species = "Alpha", maxHp = 500, spe = 90, moves = { hm("MINIMIZE", 0, 0, 15) } }),
      mn({ species = "Gamma", maxHp = 500, spe = 90, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 500, spe = 10, moves = { hm("STOMP", 40, 0, 94, 60, 30) } }) }),
    { both(F(0), F(0)), both(F(0), F(0)), both(S(1), F(0)) })
end)

-- TWISTER (95) and GUST (99) reach a FLY user and double; EARTHQUAKE (100)
-- reaches a DIG user and doubles; THUNDER (97) reaches the sky too and
-- paralyses.
scenario("twister_fly", function(events)
  return seq(events, duo("twf", "1v1", 504,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("FLY", 30, 0, 43), hm("DIG", 30, 0, 43) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("TWISTER", 20, 0, 95, 60, 20), hm("GUST", 20, 0, 99),
                     hm("EARTHQUAKE", 20, 0, 100), hm("THUNDER", 20, 0, 97, 60, 100) } }) }),
    { both(F(0), F(0)), both(F(0), F(1)), both(F(1), F(2)), both(F(1), F(1)),
      both(F(0), F(3)) })
end)

-- SNORE (96) and SKY ATTACK (101) end in FlinchTarget and `kingsrock`.
scenario("snore_sky_attack", function(events)
  return seq(events, duo("ssa", "1v1", 505,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, item = { "KINGS_ROCK", "HELD_FLINCH", 30, "KING'S ROCK" },
           moves = { hm("SNORE", 20, 0, 96, 60, 30), hm("SKY_ATTACK", 40, 0, 101, 60, 30) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both(F(0), F(0)), both(F(1), F(0)), both(F(1), F(0)), both(F(0), F(0)) })
end)

-- TRI ATTACK (98): its own effectchance and the `.loop` bytes every hit,
-- landing on ParalyzeTarget / FreezeTarget / BurnTarget -- the frozen target
-- thawed when it lands on BurnTarget.
scenario("tri_attack", function(events)
  local quiet = hm("wait", 0, 0, 85)
  return seq(events, duo("tri", "1v1", 506,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 0 },
           moves = { hm("TRI_ATTACK", 10, 0, 98, 60, 100) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, status = "FRZ", types = { 2 }, moves = { quiet } }) },
    { typeIds = SIDE_TYPES }),
    { both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)),
      both(F(0), F(0)), both(F(0), F(0)) })
end)

-- `effectchance` right after `checkhit`: a 1%-accurate burn hit draws it on
-- its misses, and on its miss into the sky (`.FlyDigMoves`); a substitute
-- standing skips it.
scenario("effectchance_miss", function(events)
  local wild = { id = "wild_flame", pp = 60, power = 40, accuracy = 1, type = 1, effect = 4, chance = 10 }
  return seq(events, duo("ecm", "1v1", 507,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { wild } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10,
           moves = { hm("wait", 0, 0, 85), hm("SUBSTITUTE", 0, 0, 79), hm("FLY", 30, 0, 43) } }) }),
    { both(F(0), F(0)), both(F(0), F(2)), { { "p1", F(0) } }, both(F(0), F(1)), both(F(0), F(0)) })
end)

-- MultiHit / DoubleHit / PoisonMultiHit: per hit, a crit byte and a roll;
-- MULTI_HIT's count after the first hit; TWINEEDLE's one effectchance before
-- its loop.
scenario("multi_hit_draws", function(events)
  return seq(events, duo("mhd", "1v1", 508,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, focusEnergy = true,
           moves = { hm("fury_hits", 15, 0, 29), hm("twin_hits", 25, 0, 44), hm("TWINEEDLE", 25, 0, 77, 60, 20) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, types = { 0 }, moves = { hm("tap", 1) } }) },
    { typeIds = SIDE_TYPES }),
    { both(F(0), F(0)), both(F(0), F(0)), both(F(1), F(0)), both(F(2), F(0)), both(F(2), F(0)) })
end)

-- A first hit that knocks the target out ends MULTI_HIT before EndLoop draws
-- its count.
scenario("multi_hit_first_ko", function(events)
  return seq(events, duo("mfk", "1v1", 509,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { hm("fury_hits", 15, 0, 29) } }) },
    { mn({ species = "Beta", maxHp = 400, hp = 1, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }) }),
    { both(F(0), F(0)), { { "p2", S(1) } }, both(F(0), F(0)) })
end)

-- LEECH SEED's eighth (GetEighthMaxHP) through SubtractHPFromUser: past the
-- seeded monster's own substitute, and the seeder healed what was taken.
scenario("leech_seed_eighth", function(events)
  local seeded = mn({ species = "Beta", maxHp = 400, spe = 10, substitute = 50,
                      leechSeed = { fromSlot = 0 }, moves = { hm("wait", 0, 0, 85) } })
  return seq(events, duo("lse", "1v1", 510,
    { mn({ species = "Alpha", maxHp = 400, hp = 100, spe = 90, moves = { hm("wait", 0, 0, 85) } }) },
    { seeded }),
    { both(F(0), F(0)), both(F(0), F(0)) })
end)

-- No 999 cap after the DamageCalc tail: a STAB hit past 999 lands whole, and
-- BIDE stores it (16-bit, pinned at $ffff) and releases twice that.
scenario("no_999_cap", function(events)
  return seq(events, duo("n9c", "1v1", 511,
    { mn({ species = "Alpha", level = 100, maxHp = 9000, atk = 255, spe = 90, types = { 0 },
           moves = { hm("crush", 250, 0, 0) } }) },
    { mn({ species = "Beta", level = 100, maxHp = 9000, def = 1, spe = 10, types = { 0 },
           moves = { hm("BIDE", 0, 0, 26) } }) }),
    { both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)) })
end)

-- RECOIL into a substitute: wCurDamage is 0 after DoSubstituteDamage, so the
-- recoil is the minimum 1 -- off the user's HP, past its own substitute.
scenario("recoil_substitute", function(events)
  return seq(events, duo("rcs", "1v1", 512,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, substitute = 50,
           moves = { hm("TAKE_DOWN", 40, 0, 48) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, substitute = 200, moves = { hm("wait", 0, 0, 85) } }) }),
    { both(F(0), F(0)), both(F(0), F(0)) })
end)

-- THRASH with its last PP: the rampage's next turns re-use it (no PP, never
-- Struggle), its count drawn before `checkhit`, the confusion when it runs
-- out; a full paralysis (CantMove) ends one.
scenario("rampage_zero_pp", function(events)
  return seq(events, duo("rzp", "1v1", 513,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("THRASH", 20, 0, 27, 1) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90, status = "PAR", moves = { hm("THRASH", 20, 0, 27, 5) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, moves = { hm("tap", 1) } }) }),
    { both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)),
      both(S(1), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)) })
end)

-- MIRROR MOVE reads the foe's last move USED: the move its METRONOME called,
-- not METRONOME; it fails on a move the user knows, and after a send-out.
scenario("mirror_move_last_used", function(events)
  return seq(events, duo("mml", "1v1", 514,
    { mn({ species = "Alpha", maxHp = 600, spe = 10, moves = { hm("MIRROR_MOVE", 0, 0, 9), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 600, spe = 90, moves = { hm("METRONOME", 0, 0, 83), hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 600, spe = 90, moves = { hm("tap", 1) } }) },
    { metronomePool = { hm("pool_hit", 30, 0, 0) } }),
    { both(F(0), F(0)), both(F(0), F(1)), both(F(0), S(1)) })
end)

-- A charge move METRONOME called keeps the called move: FLY lands the next
-- turn instead of a second call; and a MIRROR MOVE that copied the FLY
-- charges and lands it too.
scenario("metronome_charge", function(events)
  return seq(events, duo("mtc", "1v1", 515,
    { mn({ species = "Alpha", maxHp = 600, spe = 90, moves = { hm("METRONOME", 0, 0, 83) } }) },
    { mn({ species = "Beta", maxHp = 600, spe = 10, moves = { hm("MIRROR_MOVE", 0, 0, 9) } }) },
    { metronomePool = { hm("FLY", 30, 0, 43) } }),
    { both(F(0), F(0)), "tick", both(F(0), F(0)) })
end)

-- ...and a BIDE METRONOME called is released as BIDE, not a second call.
scenario("metronome_bide", function(events)
  return seq(events, duo("mtb", "1v1", 518,
    { mn({ species = "Alpha", maxHp = 600, spe = 90, moves = { hm("METRONOME", 0, 0, 83) } }) },
    { mn({ species = "Beta", maxHp = 600, atk = 90, spe = 10, moves = { hm("thump", 40) } }) },
    { metronomePool = { hm("BIDE", 0, 0, 26) } }),
    { both(F(0), F(0)), { { "p2", F(0) } }, { { "p2", F(0) } }, { { "p2", F(0) } }, both(F(0), F(0)) })
end)

-- PAY DAY: level x 2 a hit into the fight's one pot, the computer's own
-- included, paid as `payDay` on side a's win against the computer; a link
-- fight reports none.
local function payDayFight(id, mode)
  return function(events)
    return seq(events, duo(id, mode, 516,
      { mn({ species = "Alpha", level = 30, maxHp = 400, atk = 90, spe = 90, moves = { hm("PAY_DAY", 40, 0, 16) } }) },
      { mn({ species = "Beta", level = 140, maxHp = 60, spe = 10, moves = { hm("PAY_DAY", 1, 0, 16) } }) }),
      { both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)) })
  end
end
scenario("pay_day_wild", payDayFight("pdw", "wild"))
scenario("pay_day_link", payDayFight("pdl", "1v1"))

-- HYPER BEAM recharges after a knockout and after a hit into a substitute on
-- Gold (`rechargenextturn` before `checkfaint`).
scenario("hyper_beam_recharge", function(events)
  return seq(events, duo("hbr", "1v1", 517,
    { mn({ species = "Alpha", maxHp = 600, atk = 90, spe = 90, moves = { hm("HYPER_BEAM", 150, 0, 80), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 20, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 600, spe = 10, moves = { hm("SUBSTITUTE", 0, 0, 79), hm("wait", 0, 0, 85) } }) }),
    { both(F(0), F(0)), { { "p2", S(1) } }, { { "p2", F(0) } }, both(F(0), F(1)), { { "p2", F(1) } } })
end)

-- ------------------------------------------------------------------

local out = {}
for _, entry in ipairs(scenarios) do
  local events = {}
  batches = {}
  local battle = entry.run(events)
  out[#out + 1] = "{"
    .. '"name":' .. encString(entry.name) .. ","
    .. '"events":' .. encList(events, encObject) .. ","
    .. '"batches":' .. encList(batches, encNumber) .. ","
    .. '"outcome":' .. encOutcome(battle:outcome()) .. ","
    .. '"snapshot":' .. encSnapshot(battle)
    .. "}"
end

io.write("[" .. table.concat(out, ",") .. "]\n")
