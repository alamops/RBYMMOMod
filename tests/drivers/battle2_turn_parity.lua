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
--   * the referee-gaps run's wave 2 (R2b): `r2b_transform`, `r2b_haze_2v2`,
--     `r2b_switch_in_stats` / `r2b_switch_in_computer` (InitBattleMon /
--     LoadEnemyMon), `r2b_sleep_talk`, `r2b_snore_asleep`,
--     `r2b_mysteryberry_party`, `r2b_replace_items`, `r2b_quick_claw_forced`,
--     `r2b_bright_powder` (with the one-hit KO's own accuracy),
--     `r2b_held_prevent`, `r2b_lock_on`, `r2b_safeguard`,
--     `r2b_stat_down_lines` / `_sub` / `_floor`, `r2b_priority_sheet` (K8),
--     `r2b_level_up` (K9), `r2b_defrost`, `r2b_drain`, `r2b_toxic`,
--     `r2b_leech_grass`, `r2b_stat_up_999`, `r2b_bide_gates`, `r2b_hit_ko` and
--     `r2b_metronome_known`.
--   * the referee-gaps run's wave 3 (R2c): `r2c_happiness`, `r2c_hidden_power`,
--     `r2c_reversal_false_swipe`, `r2c_magnitude`, `r2c_present_gold` /
--     `_crystal`, `r2c_triple_kick`, `r2c_fury_cutter`, `r2c_rollout`,
--     `r2c_beat_up` / `_wild`, `r2c_pursuit_link` / `_computer`,
--     `r2c_future_sight`, `r2c_protect` / `_slow`, `r2c_counter`, `r2c_rain`,
--     `r2c_sun`, `r2c_sandstorm`, `r2c_time_heal`, `r2c_fixed_damage`, and
--     R2b's findings: `r2c_checkhit` (a, b), `r2c_checkturn` (c-f), `r2c_bide`
--     (h), `r2c_flinch` (i).
--   * the referee-gaps run's wave 4 (R2d), Gold's status and field moves:
--     `r2d_attract` (K15's gender), `r2d_baton_pass`, `r2d_belly_drum`,
--     `r2d_curse`, `r2d_destiny_bond`, `r2d_encore`, `r2d_foresight`,
--     `r2d_heal_bell`, `r2d_mean_look`, `r2d_teleport`, `r2d_nightmare`,
--     `r2d_pain_split`, `r2d_perish_song` / `r2d_perish_2v2`, `r2d_psych_up`,
--     `r2d_rapid_spin`, `r2d_sketch` / `_link` / `_transformed_end`,
--     `r2d_spite`, `r2d_amnesia`, `r2d_swagger`, `r2d_conversion2`; and the
--     rest of Gold's cart differences: `r2d_status_lines` (the AI's random
--     fail, the miss and failure lines), `r2d_full_heal_ai`,
--     `r2d_mysteryberry_mimic`, `r2d_disable`, `r2d_skull_bash_rest`,
--     `r2d_metronome_bytes`, `r2d_residual_order` (each seat's ResidualDamage
--     after its own move) and `r2d_faint_moves` (the party moves after the
--     faint).
--   * the referee-gaps run's wave 5 (R2e): the `r2e_*` rows below (CONVERSION,
--     HEAL BELL / BATON PASS and the toxic bit, SKETCH's base PP, ROAR /
--     WHIRLWIND, the standing 0-HP successor, the computer's switch slot,
--     PURSUIT's slot, the coop_wild RUN, METRONOME's numbered pool, the
--     confusion and volatile lines).
--   * the review polish (RP2): `rp2_item_lines` (ItemUsedText, the
--     computer's _EnemyUsedOnText, the bits that say nothing more, a ball and
--     a POKé DOLL in a trainer fight), `rp2_ball_lines` / `rp2_ball_broke_free`
--     / `rp2_ball_so_close` (the wobble lines by count, Text_BallCaught),
--     `rp2_doll_wild` (the use line and a DRAW), `rp2_flute`,
--     `rp2_status_anims_npc` / `_wild` (CheckTurn's ANIM_SLP / ANIM_CONFUSED,
--     each side's variant and place) and `rp2_pp_ups` (K8 on `moves`).
--   * the review fixes (FX-R2): `fx2_struggle_disabled`
--     (`.CheckPlayerHasUsableMoves`), `fx2_out_of_pp` (DoTurn's `.out_of_pp`),
--     `fx2_pursuit_ai_ko` (AI_Switch's PursuitSwitch, no EXP),
--     `fx2_protect_ai_item` (wEnemyGoesFirst), `fx2_ai_item_counter_crystal`
--     / `_gold` (Crystal's AI_TryItem forgets the counter move),
--     `fx2_spikes_ai_switch`, `fx2_baton_pass_mirror`, `fx2_mutual_ko_npc` /
--     `_link` (LostBattle / TiedAgainstText), `fx2_residual_ko` (the HP bar
--     before the line), `fx2_bag_no_effect` ("It won't have any effect."),
--     `fx2_ball_table` (PokeBallEffect) and `fx2_level_up_guards` (K9).
--   * the remaining-gaps run's wave 2, Gold (H2, docs/plans/gen12-referee-
--     remaining-gaps.md): the `h2_*` rows -- AIChooseMove, ParseEnemyAction's
--     overrides and wild pick, AI_SwitchOrTryItem, FindMonInOTPartyToSwitch-
--     IntoBattle (K16, driven through `autoPick` -- a round's "auto"), LOVE
--     BALL on a transformed wild monster, K22's quiet clips and missed moves,
--     K17's side-word marks and T2's follow-ups.
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
    -- What the R2b scenarios add: the K7 blocks a level-up's CalcMonStats
    -- reads (synthetic numbers).
    base = o.base, dvs = o.dvs,
    -- What the R2c scenarios add: the K14 happiness byte.
    happiness = o.happiness,
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
    id = "sh", mode = "coop_pvp", seed = 9, choiceTimeout = 60, reconnectGrace = 60,
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

-- Focus Band rolls on every hit: turns 1-3 are not lethal (the bytes are
-- drawn, nothing is said), turn 4's would be and the band holds Bob at 1 HP,
-- turn 5's roll misses and he faints.
scenario("focus_band", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("p2", { action = "fight", move = 0 })
  end
  return play(events, { id = "fb", mode = "1v1", seed = 2, choiceTimeout = 60, reconnectGrace = 60,
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
  return play(events, { id = "bg2", mode = "wild", seed = 14, choiceTimeout = 60, reconnectGrace = 60,
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
  return play(events, { id = "bp", mode = "1v1", seed = 4, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "p1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 900, spe = 90, types = { 2 },
              moves = { hm("thump", 10), hm("star_dart", 10, 0, 17) } }) } } },
      b = { { playerId = "p2", name = "Bob", mons = { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 },
              item = { "BRIGHTPOWDER", "HELD_BRIGHTPOWDER", 120, "BRIGHTPOWDER" }, moves = { hm("tap", 1) } }) } } },
    } }, rounds)
end)

-- Obedience: a traded level-80 monster with no badge (cap 10) against a wild
-- one.  On this seed it won't obey and hits itself (turn 1), obeys (2 and
-- 3), uses another move instead (4), turns away (5), ignores orders (6),
-- loafs around (7) and naps (8).
scenario("obey_traded", function(events)
  local function round(b)
    b:submitChoice("p1", { action = "fight", move = 0 })
    b:submitChoice("wild", { action = "fight", move = 0 })
  end
  return play(events, { id = "ob", mode = "wild", seed = 511, choiceTimeout = 60, reconnectGrace = 60,
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
  return play(events, { id = "obb", mode = "coop_wild", seed = 16, choiceTimeout = 60, reconnectGrace = 60,
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
  return play(events, { id = "tcm", mode = "1v1", seed = 218, choiceTimeout = 60, reconnectGrace = 60,
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
-- only Bide's next first use, turn 2, is asked.  Ann's turn-1 FIGHT is the
-- Bide's continuation (the player's menu opens during a Bide on Gold).
scenario("obey_bide", function(events)
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
    } }, { round, round, round })
end)

-- A Bide aimed at seat 0 releases on seat 0: on this seed the aim stream would
-- pick seat 1, which is where `targetSlot || foe.slot` used to send it.
scenario("bide_slot0", function(events)
  local function round(b)
    b:submitChoice("b1", { action = "fight", move = 0, target = 1 })
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
  return play(events, { id = "gpc", mode = "1v1", seed = 1, choiceTimeout = 60, reconnectGrace = 60,
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
-- PP, which the copied moves never spend.  Ditto copies Wild's tap -- 5 PP,
-- BattleCommand_Transform's own count (R2b) -- and the party's TRANSFORM
-- never empties.
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
  return play(events, { id = "rgs", mode = "1v1", seed = 2, choiceTimeout = 60, reconnectGrace = 60,
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
    -- R2b's: a chart (type immunities) and side a's badges.
    o.chart = extra.chart
    o.sides.a[1].badges = extra.badges
  end
  return o
end
-- A round is a list of { playerId, choice } pairs, "tick", or a function of
-- the battle (R2b: a level-up between turns).
local function seq(events, opts, rounds)
  local fns = {}
  for i, list in ipairs(rounds) do
    if type(list) == "function" then
      fns[i] = function(b) list(b, events) end
    elseif list == "tick" then
      fns[i] = function(b) b:tick(b.now + 1) end
    else
      fns[i] = function(b)
        -- "auto" files the seat's answer the way a hub's NPC seat and a solo
        -- foe do (`autoPick`: the computer's own AI, H2).
        for _, pair in ipairs(list) do
          if pair[2] == "auto" then b:autoPick(pair[1]) else b:submitChoice(pair[1], pair[2]) end
        end
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
-- Alpha is awake, so its SNORE fails (BattleCommand_Snore, R2b); the
-- sleeping one is `r2b_snore_asleep`.
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
  return seq(events, duo("tri", "1v1", 12,
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
  return seq(events, duo("rzp", "1v1", 8,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("THRASH", 20, 0, 27, 1) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90, status = "PAR", moves = { hm("THRASH", 20, 0, 27, 5) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, moves = { hm("tap", 1) } }) }),
    { both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)),
      both(S(1), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)) })
end)

-- MIRROR MOVE reads the foe's LAST_COUNTER_MOVE.  After its METRONOME there
-- is none: METRONOME's ClearLastMove writes 0 and the move it called writes
-- nothing (UsedMoveText's CheckUserIsCharging, H2's follow-up), so it fails;
-- the foe's own jab is copied; it fails on a move the user knows, and after a
-- send-out.
scenario("mirror_move_last_used", function(events)
  return seq(events, duo("mml", "1v1", 514,
    { mn({ species = "Alpha", maxHp = 600, spe = 10, moves = { hm("MIRROR_MOVE", 0, 0, 9), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 600, spe = 90,
           moves = { hm("METRONOME", 0, 0, 83), hm("tap", 1), hm("jab", 20) } }),
      mn({ species = "Delta", maxHp = 600, spe = 90, moves = { hm("tap", 1) } }) },
    { metronomePool = { hm("pool_hit", 30, 0, 0) } }),
    { both(F(0), F(0)), both(F(0), F(2)), both(F(0), F(1)), both(F(0), S(1)) })
end)

-- A charge move METRONOME called keeps the called move: FLY lands the next
-- turn instead of a second call.  Neither turn writes the user's
-- LAST_COUNTER_MOVE -- BattleCommand_Charge and the release's UsedMoveText
-- both ask CheckUserIsCharging, and ResetTurn's 1 holds through the lock-in
-- (`.locked_in`) -- so the foe's MIRROR MOVE fails both turns.
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
    { both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)), both(F(0), F(0)) })
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
-- the referee-gaps run's wave 2 (docs/plans/gen12-referee-gaps-fix.md, R2b):
-- Transform undone, Haze in a 2v2, the switch-in stat order, SLEEP TALK and
-- SNORE, MYSTERYBERRY under Transform, a replacement's between-turn items,
-- Quick Claw on a forced turn, Bright Powder's bytes and the one-hit KO,
-- HELD_PREVENT_*, LOCK-ON, SAFEGUARD, the stat-down lines, the sheet's
-- priority (K8), the level-up (K9), the freeze thaw point, the drain misses,
-- TOXIC, LEECH SEED on a Grass type, RaiseStat at 999, a storing BIDE's gates
-- and "Hit N times!".  Every number synthetic.
-- ------------------------------------------------------------------

-- R2b's chart: NORMAL 0, FIRE 1, ICE 2, ELECTRIC 3, POISON 4, GRASS 5,
-- STEEL 6, GROUND 7; POISON can't touch STEEL, ELECTRIC can't touch GROUND.
local R2B_TYPES = { "NORMAL", "FIRE", "ICE", "ELECTRIC", "POISON", "GRASS", "STEEL", "GROUND" }
local R2B_CHART = {}
for i = 1, 8 do
  R2B_CHART[i] = {}
  for j = 1, 8 do R2B_CHART[i][j] = 100 end
end
R2B_CHART[5][7] = 0
R2B_CHART[4][8] = 0
local R2B = { typeIds = R2B_TYPES, chart = R2B_CHART }

-- A move with its own accuracy (and, optionally, a stated priority).
local function am(id, power, ty, effect, acc, chance, priority)
  return { id = id, pp = 60, power = power, accuracy = acc, type = ty or 0,
           effect = effect or 0, chance = chance or 0, priority = priority }
end
local function both2(a, b) return { { "p1", a }, { "p2", b } } end

-- Transform (BattleCommand_Transform): through a substitute, 5 PP a copied
-- move and SKETCH 1, the copied stats; Beta confuses it; a switch-out gives
-- back the moves and clears the confusion; a TRANSFORM at a transformed
-- target fails.
scenario("r2b_transform", function(events)
  return seq(events, duo("r2t", "1v1", 601,
    { mn({ species = "Alpha", maxHp = 400, atk = 50, spe = 90, types = { 0 },
           moves = { hm("TRANSFORM", 0, 0, 57, 10), hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 20, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 600, atk = 120, def = 70, spe = 60, types = { 1 },
           substitute = 40, stages = { atk = 2 },
           moves = { hm("SKETCH", 0, 0, 0), hm("slam", 40, 1, 0), hm("TRANSFORM", 0, 0, 57),
                     hm("CONFUSE_RAY", 0, 0, 49) } }) },
    R2B),
    { both2(F(0), F(3)), both2(F(1), F(1)), both2(S(1), F(1)), both2(S(0), F(1)),
      both2(F(0), F(2)) })
end)

-- Haze resets all four battlers of a 2v2 (BattleCommand_ResetStats): each one
-- raised from +2 says +1 after it.
scenario("r2b_haze_2v2", function(events)
  local function staged(name, spe, first)
    return mn({ species = name, maxHp = 400, spe = spe, stages = { atk = 2, def = -1 },
                moves = { first, hm("GROWTH", 0, 0, 10) } })
  end
  local round1 = function(b)
    b:submitChoice("a1", F(0)); b:submitChoice("a2", F(0))
    b:submitChoice("b1", F(0)); b:submitChoice("b2", F(0))
  end
  local round2 = function(b)
    b:submitChoice("a1", F(1)); b:submitChoice("a2", F(1))
    b:submitChoice("b1", F(1)); b:submitChoice("b2", F(1))
  end
  return play(events, { id = "r2h", mode = "coop_pvp", seed = 602, choiceTimeout = 60, reconnectGrace = 60,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { staged("Alpha", 90, hm("HAZE", 0, 0, 25)) } },
            { playerId = "a2", name = "Abe", mons = { staged("Gamma", 70, hm("wait", 0, 0, 85)) } } },
      b = { { playerId = "b1", name = "Bob", mons = { staged("Beta", 60, hm("wait", 0, 0, 85)) } },
            { playerId = "b2", name = "Bea", mons = { staged("Delta", 50, hm("wait", 0, 0, 85)) } } },
    } }, { round1, round2 })
end)

-- The switch-in order (InitBattleMon): a paralysed switch-in with PLAIN is
-- boost(quarter(15)) = 3 and Beta's 4 moves first; a stat change rebuilds it
-- as CalcPlayerStats does, quarter(boost(15)) = 4, and the two tie.
scenario("r2b_switch_in_stats", function(events)
  return seq(events, duo("r2s", "wild", 21,
    { mn({ species = "Alpha", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 15, status = "PAR",
           moves = { hm("tap", 1), hm("GROWTH", 0, 0, 10) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 4, moves = { hm("tap", 1) } }) },
    { badges = { PLAIN = true } }),
    { both2(S(1), F(0)), both2(F(0), F(0)), both2(F(1), F(0)), both2(F(0), F(0)),
      both2(F(0), F(0)) })
end)

-- ...and the computer's switch-in outside a link fight (LoadEnemyMon): a
-- paralysed Delta comes in at its full 80 and outruns Alpha's 30.
scenario("r2b_switch_in_computer", function(events)
  return seq(events, duo("r2c", "coop_npc", 2,
    { mn({ species = "Alpha", maxHp = 400, atk = 120, spe = 30, moves = { hm("slam", 40) } }) },
    { mn({ species = "Beta", maxHp = 400, hp = 1, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 80, status = "PAR", moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), { { "p2", S(1) } }, both2(F(0), F(0)), both2(F(0), F(0)) })
end)

-- SLEEP TALK (BattleCommand_SleepTalk): asleep it calls a move other than
-- itself, the disabled one and the two-turn ones (here only kick); awake it
-- fails, and so does a user with one move.
scenario("r2b_sleep_talk", function(events)
  return seq(events, duo("r2l", "1v1", 605,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, status = "SLP", statusTurns = 6,
           disable = { moveIndex = 3, turns = 8 },
           moves = { hm("SLEEP_TALK", 0, 0, 102), hm("FLY", 30, 0, 43), hm("thump", 40),
                     hm("kick", 20) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 90, moves = { hm("SLEEP_TALK", 0, 0, 102), hm("tap", 1) } }),
      mn({ species = "Eps", maxHp = 400, spe = 90, status = "SLP", statusTurns = 6,
           moves = { hm("SLEEP_TALK", 0, 0, 102) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), both2(F(0), F(0)), both2(S(1), F(0)), both2(F(0), F(0)),
      both2(S(2), F(0)), both2(F(0), F(0)) })
end)

-- SNORE asleep: the hit, its flinch byte and King's Rock (BattleCommand_Snore
-- passes a sleeping user; `snore_sky_attack` above is the awake one failing).
scenario("r2b_snore_asleep", function(events)
  return seq(events, duo("r2n", "1v1", 606,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, status = "SLP", statusTurns = 7,
           item = { "KINGS_ROCK", "HELD_FLINCH", 128, "KING'S ROCK" },
           moves = { hm("SNORE", 20, 0, 96, 60, 30) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), both2(F(0), F(0)), both2(F(0), F(0)), both2(F(0), F(0)) })
end)

-- MYSTERYBERRY under Transform (HandleMysteryberry): the party's empty tap is
-- found behind the copies and gets 5, the copies untouched; the owner hears
-- of it when Transform is undone at the switch-out.
scenario("r2b_mysteryberry_party", function(events)
  return seq(events, duo("r2m", "1v1", 607,
    { mn({ species = "Alpha", maxHp = 400, spe = 90,
           item = { "MYSTERYBERRY", "HELD_RESTORE_PP", 5, "MYSTERYBERRY" },
           moves = { hm("TRANSFORM", 0, 0, 57, 10), hm("tap", 1, 0, 0, 0) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 20, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 600, spe = 60, moves = { hm("slam", 40, 0, 0, 30) } }) }),
    { both2(F(0), F(0)), both2(S(1), F(0)), both2(S(0), F(0)) })
end)

-- A replacement's between-turn items (HandleBetweenTurnEffects after the
-- cart's mid-turn send-out): Delta's Leftovers and its defrost roll, at the
-- close of the replace phase.
scenario("r2b_replace_items", function(events)
  return seq(events, duo("r2r", "1v1", 608,
    { mn({ species = "Alpha", maxHp = 400, atk = 200, spe = 90, moves = { hm("slam", 80) } }) },
    { mn({ species = "Beta", maxHp = 400, hp = 5, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, hp = 40, spe = 10, status = "FRZ",
           item = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), { { "p2", S(1) } }, both2(F(0), F(0)), both2(F(0), F(0)) })
end)

-- Quick Claw on a forced turn (DetermineMoveOrder compares wCurPlayerMove):
-- the recharging Alpha's claw rolls, and so does a storing Bide's.
scenario("r2b_quick_claw_forced", function(events)
  return seq(events, duo("r2q", "1v1", 609,
    { mn({ species = "Alpha", maxHp = 600, atk = 60, spe = 10,
           item = { "QUICK_CLAW", "HELD_QUICK_CLAW", 200, "QUICK CLAW" },
           moves = { hm("HYPER_BEAM", 150, 0, 80), hm("BIDE", 0, 0, 26) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 50, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), { { "p2", F(0) } }, both2(F(1), F(0)), both2(F(1), F(0)),
      both2(F(1), F(0)), both2(F(1), F(0)) })
end)

-- Bright Powder in the byte domain (BattleCommand_CheckHit .BrightPowder) and
-- the one-hit KO's own accuracy (BattleCommand_OHKO): Alpha's taps roll a byte
-- against 235, its GUILLOTINE against 30%'s 76 + 2 x 10 levels - 20; Beta's
-- GUILLOTINE meets a higher level ("unaffected!") and draws nothing.
scenario("r2b_bright_powder", function(events)
  return seq(events, duo("r2p", "1v1", 2,
    { mn({ species = "Alpha", level = 50, maxHp = 400, spe = 90,
           moves = { am("tap", 10, 0, 0, 255), am("GUILLOTINE", 0, 0, 38, 76) } }) },
    { mn({ species = "Beta", level = 40, maxHp = 900, spe = 10,
           item = { "BRIGHTPOWDER", "HELD_BRIGHTPOWDER", 20, "BRIGHTPOWDER" },
           moves = { am("tap", 1, 0, 0, 255), am("GUILLOTINE", 0, 0, 38, 76) } }) }),
    { both2(F(0), F(0)), both2(F(0), F(0)), both2(F(0), F(0)), both2(F(1), F(1)),
      both2(F(1), F(1)), both2(F(1), F(1)), both2(F(1), F(1)) })
end)

-- HELD_PREVENT_*: the primary commands' "protected by" line (SleepTarget,
-- Confuse), a side effect's silent stop (BurnTarget).
scenario("r2b_held_prevent", function(events)
  return seq(events, duo("r2v", "1v1", 611,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 0 },
           moves = { hm("HYPNOSIS", 0, 0, 32), hm("EMBER", 10, 1, 4, 60, 100),
                     hm("CONFUSE_RAY", 0, 0, 49) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, item = { "GUARD_A", "HELD_PREVENT_SLEEP", 0, "GUARD A" },
           moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, item = { "GUARD_B", "HELD_PREVENT_BURN", 0, "GUARD B" },
           moves = { hm("tap", 1) } }),
      mn({ species = "Eps", maxHp = 400, spe = 10, item = { "GUARD_C", "HELD_PREVENT_CONFUSE", 0, "GUARD C" },
           moves = { hm("tap", 1) } }) },
    R2B),
    { both2(F(0), F(0)), both2(F(1), S(1)), both2(F(2), S(2)) })
end)

-- LOCK-ON (BattleCommand_LockOn, CheckHit .LockOn): the next move against the
-- target cannot miss (a 1% hit lands), the lock is spent by it; EARTHQUAKE
-- still misses a flier; a substitute "didn't affect".
scenario("r2b_lock_on", function(events)
  return seq(events, duo("r2o", "1v1", 612,
    { mn({ species = "Alpha", maxHp = 600, spe = 10,
           moves = { am("LOCK_ON", 0, 0, 103, 255), am("wild_hit", 20, 0, 0, 1),
                     am("EARTHQUAKE", 30, 0, 100, 255), am("tap", 1, 0, 0, 255) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 90,
           moves = { hm("tap", 1), hm("FLY", 30, 0, 43), hm("SUBSTITUTE", 0, 0, 79) } }) }),
    { both2(F(0), F(0)), both2(F(1), F(0)), both2(F(1), F(0)), both2(F(0), F(0)),
      both2(F(2), F(1)), { { "p1", F(3) } }, both2(F(0), F(2)) })
end)

-- SAFEGUARD (BattleCommand_Safeguard): a sleep move into it is "protected by
-- SAFEGUARD!", a burn hit's side effect stops, a second cast fails, the
-- rampage's own confusion is spared, and it fades after five ticks.
scenario("r2b_safeguard", function(events)
  return seq(events, duo("r2g", "1v1", 613,
    { mn({ species = "Alpha", maxHp = 600, spe = 90, types = { 0 },
           moves = { hm("SAFEGUARD", 0, 0, 104), hm("THRASH", 20, 0, 27), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("HYPNOSIS", 0, 0, 32), hm("EMBER", 10, 1, 4, 60, 100), hm("tap", 1) } }) },
    R2B),
    { both2(F(0), F(0)), both2(F(0), F(1)), both2(F(1), F(2)), { { "p2", F(2) } },
      { { "p2", F(2) } }, both2(F(2), F(2)), both2(F(2), F(0)) })
end)

-- The primary stat-down lines (StatDownFailText): Mist's, before and on a
-- miss; TryLowerStat's at a battle stat of 1; a missed GROWL's "But it
-- failed".  A send-out clears a sheet's Mist, substitute and stages, so each
-- of those is a lead of its own below.
scenario("r2b_stat_down_lines", function(events)
  return seq(events, duo("r2d", "1v1", 614,
    { mn({ species = "Alpha", maxHp = 400, spe = 90,
           moves = { am("GROWL", 0, 0, 18, 255), am("faint_growl", 0, 0, 18, 1) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, mist = true, moves = { hm("tap", 1) } }),
      mn({ species = "Zeta", maxHp = 400, atk = 1, spe = 10, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), both2(F(1), F(0)), both2(F(0), S(1)), both2(F(1), F(0)) })
end)

-- ...a substitute's "But it failed" (`.DidntMiss`), and the -6 floor's
-- "won't drop anymore!", which comes first.
scenario("r2b_stat_down_sub", function(events)
  return seq(events, duo("r2d2", "1v1", 624,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { am("GROWL", 0, 0, 18, 255) } }) },
    { mn({ species = "Delta", maxHp = 400, spe = 10, substitute = 50, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)) })
end)
scenario("r2b_stat_down_floor", function(events)
  return seq(events, duo("r2d3", "1v1", 625,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { am("GROWL", 0, 0, 18, 255) } }) },
    { mn({ species = "Eps", maxHp = 400, spe = 10, substitute = 50, stages = { atk = -6 },
           moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)) })
end)

-- The sheet's priority (K8) wins over the move-id table.
scenario("r2b_priority_sheet", function(events)
  return seq(events, duo("r2y", "1v1", 615,
    { mn({ species = "Alpha", maxHp = 400, spe = 10,
           moves = { am("jab", 10, 0, 0, 255, 0, 2), am("QUICK_ATTACK", 10, 0, 0, 255, 0, 1) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 90, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), both2(F(1), F(0)) })
end)

-- The level-up (K9): Alpha's new stats come in boosted by PLAIN and outrun
-- Beta, its HP rises by the max-HP step; a bench level-up from the K7 blocks
-- (CalcMonStats) is what Gamma brings in; a level below the current one is
-- refused.
scenario("r2b_level_up", function(events)
  local function up(...)
    local args = { ... }
    return function(b, list)
      local ok = b:levelUp(args[1], args[2], args[3], args[4], args[5])
      list[#list + 1] = { t = "levelUp", text = tostring(ok) }
    end
  end
  return seq(events, duo("r2u", "wild", 616,
    { mn({ species = "Alpha", level = 20, maxHp = 100, hp = 60, spe = 40, moves = { hm("tap", 1) } }),
      mn({ species = "Gamma", level = 10, maxHp = 50, spe = 5, moves = { hm("tap", 1) },
           base = { hp = 60, atk = 60, def = 60, spe = 90, spa = 60, spd = 60 },
           dvs = { atk = 15, def = 14, spe = 13, spc = 12 } }) },
    { mn({ species = "Beta", level = 20, maxHp = 900, spe = 50, moves = { hm("tap", 1) } }) },
    { badges = { PLAIN = true } }),
    { both2(F(0), F(0)), up("p1", 1, 21, { atk = 45, def = 45, spe = 60, spa = 45, spd = 45 }, 110),
      both2(F(0), F(0)), up("p1", 2, 30), up("p1", 1, 5), both2(S(1), F(0)), both2(F(0), F(0)) })
end)

-- The freeze thaw point: CheckTurn never thaws ("frozen solid", no byte);
-- HandleDefrost rolls 10% between turns, never on the turn the freeze landed.
scenario("r2b_defrost", function(events)
  local rounds = {}
  for i = 1, 10 do rounds[i] = both2(F(0), F(0)) end
  return seq(events, duo("r2f", "1v1", 617,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, status = "FRZ", types = { 0 },
           moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("ice_hit", 5, 2, 5, 60, 100) } }) },
    R2B), rounds)
end)

-- `.DrainSub` / `.DreamEater`: LEECH LIFE at a substitute and DREAM EATER at
-- an awake target miss before the accuracy byte; SapHealth heals at least 1.
scenario("r2b_drain", function(events)
  return seq(events, duo("r2e", "1v1", 618,
    { mn({ species = "Alpha", maxHp = 400, hp = 100, spe = 90,
           moves = { hm("LEECH_LIFE", 20, 0, 3), hm("DREAM_EATER", 100, 0, 8) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, substitute = 100, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, hp = 1, spe = 10, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), both2(F(1), F(0)), both2(F(0), S(1)) })
end)

-- TOXIC (BattleCommand_Poison's `.check_toxic`): badly poisoned, 1/16 x n;
-- a Poison type and a Steel one (the matchup's 0) are not affected; the
-- switch-out leaves plain poison (1/8).
scenario("r2b_toxic", function(events)
  return seq(events, duo("r2x", "1v1", 619,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { am("TOXIC", 0, 4, 105, 255) } }) },
    { mn({ species = "Beta", maxHp = 160, spe = 10, types = { 0 }, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, types = { 4 }, moves = { hm("tap", 1) } }),
      mn({ species = "Eps", maxHp = 400, spe = 10, types = { 6 }, moves = { hm("tap", 1) } }) },
    R2B),
    { both2(F(0), F(0)), both2(F(0), F(0)), both2(F(0), S(1)), both2(F(0), S(0)),
      both2(F(0), S(2)) })
end)

-- LEECH SEED doesn't affect a Grass type (BattleCommand_LeechSeed).
scenario("r2b_leech_grass", function(events)
  return seq(events, duo("r2s2", "1v1", 620,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { hm("LEECH_SEED", 0, 5, 84) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, types = { 5 }, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, types = { 0 }, moves = { hm("tap", 1) } }) },
    R2B),
    { both2(F(0), F(0)), both2(F(0), S(1)) })
end)

-- RaiseStat at 999 for a primary move (`.stats_already_max`): SWORDS DANCE
-- keeps one stage of its two and says "won't rise anymore!"; MEDITATE then
-- changes nothing.
scenario("r2b_stat_up_999", function(events)
  return seq(events, duo("r2z", "1v1", 621,
    { mn({ species = "Alpha", maxHp = 400, atk = 999, spe = 90,
           moves = { hm("SWORDS_DANCE", 0, 0, 50), hm("MEDITATE", 0, 0, 10) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), both2(F(1), F(0)) })
end)

-- A storing BIDE runs CheckTurn's gates: confused after it began, a storing
-- turn that hits itself ends the Bide (CantMove), and the next turn asks for
-- a move again.
scenario("r2b_bide_gates", function(events)
  return seq(events, duo("r2b", "1v1", 622,
    { mn({ species = "Alpha", maxHp = 600, spe = 90, moves = { hm("BIDE", 0, 0, 26) } }) },
    { mn({ species = "Beta", maxHp = 600, atk = 90, spe = 10,
           moves = { hm("thump", 40), hm("CONFUSE_RAY", 0, 0, 49) } }) }),
    { both2(F(0), F(1)), both2(F(0), F(0)), both2(F(0), F(0)), both2(F(0), F(0)),
      both2(F(0), F(0)), both2(F(0), F(0)) })
end)

-- "Hit N times!" only when the loop ran out with the target standing: a
-- DOUBLE KICK whose second hit knocks Beta out says nothing.
scenario("r2b_hit_ko", function(events)
  return seq(events, duo("r2k", "1v1", 623,
    { mn({ species = "Alpha", maxHp = 400, atk = 90, spe = 90, moves = { hm("DOUBLE_KICK", 30, 0, 44) } }) },
    { mn({ species = "Beta", maxHp = 400, hp = 30, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }) }),
    { both2(F(0), F(0)), { { "p2", S(1) } }, both2(F(0), F(0)) })
end)

-- METRONOME's `.GetMove` redraws a move the user knows (CheckUserMove):
-- Alpha, knowing tap, only ever calls kick; Gamma knows the whole pool.
scenario("r2b_metronome_known", function(events)
  return seq(events, duo("r2w", "1v1", 626,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { hm("METRONOME", 0, 0, 83), hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 90,
           moves = { hm("METRONOME", 0, 0, 83), hm("tap", 1), hm("kick", 20) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) },
    { metronomePool = { hm("tap", 1), hm("kick", 20) } }),
    { both2(F(0), F(0)), both2(F(0), F(0)), both2(F(0), F(0)), both2(S(1), F(0)),
      both2(F(0), F(0)) })
end)

-- ------------------------------------------------------------------
-- the referee-gaps run's wave 3 (R2c): the Gold move effects, weather, and
-- R2b's found cart differences (a)-(i).  Synthetic numbers throughout.
-- ------------------------------------------------------------------

-- A ruleset with names for the types the new rules ask about: NORMAL 0,
-- FIGHTING 1, GHOST 2, WATER 3, FIRE 4, ROCK 5, STEEL 6, DARK 7, PSYCHIC_TYPE
-- 8, GRASS 9, ELECTRIC 10, GROUND 11; the immunities NORMAL / FIGHTING ->
-- GHOST, GHOST -> NORMAL, PSYCHIC -> DARK, ELECTRIC -> GROUND; WATER -> FIRE
-- and FIRE -> GRASS doubled; the special types WATER, FIRE, DARK, PSYCHIC,
-- GRASS, ELECTRIC.
local R2C_TYPES = { "NORMAL", "FIGHTING", "GHOST", "WATER", "FIRE", "ROCK", "STEEL",
                    "DARK", "PSYCHIC_TYPE", "GRASS", "ELECTRIC", "GROUND" }
local R2C_CHART = {}
for i = 1, 12 do
  R2C_CHART[i] = {}
  for j = 1, 12 do R2C_CHART[i][j] = 100 end
end
R2C_CHART[1][3] = 0
R2C_CHART[2][3] = 0
R2C_CHART[3][1] = 0
R2C_CHART[9][8] = 0
R2C_CHART[11][12] = 0
R2C_CHART[4][5] = 200
R2C_CHART[5][10] = 200
local R2C_SPECIAL = { 3, 4, 7, 8, 9, 10 }

-- One seat a side on the R2c ruleset; `extra` adds a time of day, a cart
-- family on both sides, a Metronome pool.
local function duo3(id, mode, seed, aMons, bMons, extra)
  extra = extra or {}
  local o = duo(id, mode, seed, aMons, bMons, { typeIds = R2C_TYPES, chart = R2C_CHART,
    metronomePool = extra.metronomePool })
  o.specialTypes = R2C_SPECIAL
  o.timeOfDay = extra.timeOfDay
  if extra.family then
    o.sides.a[1].family = extra.family
    o.sides.b[1].family = extra.family
  end
  if extra.foe then o.sides.b[1].playerId = extra.foe end
  return o
end
local function both3(a, b, foe) return { { "p1", a }, { foe or "p2", b } } end
local ITEM = function(id) return { action = "item", item = id } end

-- The computer's seat (contract K16): its items and switches are
-- AI_SwitchOrTryItem's alone -- `_normaliseChoice` refuses one filed for it --
-- so the scenarios that show one give side b's seat the trainer's bytes
-- (`npc`) and let the AI reach it: TrainerClassAttributes' SWITCH_OFTEN /
-- ALWAYS_USE (constants/trainer_data_constants.asm), and `after`'s state
-- for the turns a scenario does not spend getting there -- a PERISH count of
-- 1 (CheckAbleToSwitch's `$30 + slot`, a 96% switch under SWITCH_OFTEN) or
-- an HP at a quarter (`.HealItem`'s certain heal).
local SWITCH_OFTEN, ALWAYS_USE = 0x01, 0x10
local function npc(o, fields)
  for key, value in pairs(fields) do o.sides.b[1][key] = value end
  return o
end
local function after(set, list)
  return function(b)
    set(b)
    for _, pair in ipairs(list) do
      if pair[2] == "auto" then b:autoPick(pair[1]) else b:submitChoice(pair[1], pair[2]) end
    end
  end
end
local function perishOne(b)
  local foe = b.byId.p2
  foe.mons[foe.active].perish = 1
end
local function hpTo(hp)
  return function(b)
    local foe = b.byId.p2
    foe.mons[foe.active].hp = hp
  end
end

-- RETURN / FRUSTRATION (BattleCommand_HappinessPower / FrustrationPower, K14):
-- happiness 255 is RETURN's 102 and FRUSTRATION's 0 -- a 0-power hit that
-- takes nothing and shows nothing -- and a sheet with no happiness reads
-- BASE_HAPPINESS 70 (28).
scenario("r2c_happiness", function(events)
  return seq(events, duo3("r3h", "1v1", 701,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, happiness = 255,
           moves = { hm("RETURN", 1, 0, 106), hm("FRUSTRATION", 1, 0, 107) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 90, moves = { hm("RETURN", 1, 0, 106) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(S(1), F(0)), both3(F(0), F(0)) })
end)

-- HIDDEN POWER (HiddenPowerDamage): the K7 DVs' FIGHTING at 61 -- the matchup
-- against a GHOST is 0 -- and WATER at 52, super effective on a FIRE type;
-- the special / physical split and STAB follow the new type.
scenario("r2c_hidden_power", function(events)
  return seq(events, duo3("r3p", "1v1", 702,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 1 },
           dvs = { atk = 8, def = 12, spe = 0, spc = 0 }, moves = { hm("HIDDEN_POWER", 1, 0, 108) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 90, dvs = { atk = 10, def = 5, spe = 1, spc = 2 },
           moves = { hm("HIDDEN_POWER", 1, 0, 108) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 }, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, types = { 4 }, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), S(1)), both3(S(1), F(0)), both3(F(0), F(0)) })
end)

-- FLAIL (ConstantDamage's .reversal: no crit byte, no roll) at 12 / 300 and
-- 1 HP; FALSE SWIPE leaves its target 1 HP, then deals nothing to 1 HP.
scenario("r2c_reversal_false_swipe", function(events)
  return seq(events, duo3("r3r", "1v1", 703,
    { mn({ species = "Alpha", maxHp = 300, hp = 12, spe = 90, moves = { hm("FLAIL", 1, 0, 109) } }) },
    { mn({ species = "Beta", maxHp = 900, atk = 200, spe = 10, moves = { hm("FALSE_SWIPE", 40, 0, 118) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- MAGNITUDE (BattleCommand_GetMagnitude): its byte after the crit's, the
-- line, and `doubleundergrounddamage` on a target that dug.
scenario("r2c_magnitude", function(events)
  return seq(events, duo3("r3m", "1v1", 704,
    { mn({ species = "Alpha", maxHp = 400, spe = 10, moves = { hm("MAGNITUDE", 1, 11, 110) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 90, moves = { hm("DIG", 30, 11, 43), hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(1)) })
end)

-- PRESENT on Gold (no `family`: Gold / Silver): DamageCalc on the registers
-- its own Stab call left -- the target's second type constant as the level,
-- the matchup as the attack -- and the heal branch on a hurt target.
scenario("r2c_present_gold", function(events)
  return seq(events, duo3("r3g", "1v1", 705,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 0 },
           moves = { am("PRESENT", 1, 0, 111, 229) } }) },
    { mn({ species = "Beta", maxHp = 900, hp = 700, spe = 10, types = { 5, 7 }, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)),
      both3(F(0), F(0)) })
end)

-- ...and on Crystal outside a link battle (`family` crystal, against the
-- computer): damagestats' own registers, and the heal on a full target is
-- "refused the gift!".
scenario("r2c_present_crystal", function(events)
  return seq(events, duo3("r3c", "wild", 706,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 0 },
           moves = { am("PRESENT", 1, 0, 111, 229) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 5, 7 }, moves = { hm("tap", 1) } }) },
    { family = "crystal", foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"),
      both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild") })
end)

-- TRIPLE KICK: `checkhit` once, then a crit and a roll per kick at x1, x2,
-- x3, the count (BattleRandom & 3, not 0) drawn after the first kick.
scenario("r2c_triple_kick", function(events)
  return seq(events, duo3("r3k", "1v1", 707,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { am("TRIPLE_KICK", 10, 1, 112, 229) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- FURY CUTTER: the count doubles each hit in a row up to 16x; a miss resets
-- it (and the next hit is x1 again); choosing another move resets it too.
scenario("r2c_fury_cutter", function(events)
  return seq(events, duo3("r3f", "1v1", 708,
    { mn({ species = "Alpha", maxHp = 400, spe = 90,
           moves = { am("FURY_CUTTER", 10, 0, 113, 242), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)),
      both3(F(0), F(0)), both3(F(1), F(0)), both3(F(0), F(0)) })
end)

-- DEFENSE CURL then ROLLOUT: the roll locks the seat in (no PP, no menu)
-- for up to five rolls, doubling each, once more for the curl; a miss ends it.
scenario("r2c_rollout", function(events)
  return seq(events, duo3("r3o", "1v1", 709,
    { mn({ species = "Alpha", maxHp = 400, spe = 90,
           moves = { hm("DEFENSE_CURL", 0, 0, 115), am("ROLLOUT", 30, 5, 114, 229), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 999, def = 200, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), { { "p2", F(0) } }, { { "p2", F(0) } }, { { "p2", F(0) } },
      { { "p2", F(0) } }, both3(F(1), F(0)), { { "p2", F(0) } } })
end)

-- BEAT UP: one pass per party member -- a fainted one and a statused one
-- skipped -- each at its own level and base Attack against the target's base
-- Defense, no matchup, no "Hit N times!", then `kingsrock`.
scenario("r2c_beat_up", function(events)
  return seq(events, duo3("r3b", "1v1", 710,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 0 }, base = { atk = 100 },
           item = { "KINGS_ROCK", "HELD_FLINCH", 30, "KING'S ROCK" },
           moves = { hm("BEAT_UP", 10, 7, 116) } }),
      mn({ species = "Gamma", level = 30, maxHp = 100, base = { atk = 60 }, moves = { hm("tap", 1) } }),
      mn({ species = "Eta", maxHp = 100, hp = 0, base = { atk = 120 }, moves = { hm("tap", 1) } }),
      mn({ species = "Theta", maxHp = 100, status = "PSN", base = { atk = 120 }, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 }, base = { def = 50 },
           moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- ...a wild monster's BEAT UP is one ordinary hit and "But it failed!", and a
-- party of one is EndLoop's `.only_one_beatup`: no `kingsrock`.
scenario("r2c_beat_up_wild", function(events)
  return seq(events, duo3("r3w", "wild", 711,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, base = { atk = 100 },
           moves = { hm("BEAT_UP", 10, 7, 116) } }) },
    { mn({ species = "Wild", maxHp = 900, spe = 10, base = { def = 50 }, moves = { hm("BEAT_UP", 10, 7, 116) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild") })
end)

-- PURSUIT (PursuitSwitch): in a link fight each player's withdrawal is
-- chased -- the foe's whole turn taken before the switch, doubled -- and its
-- later turn is spent.
scenario("r2c_pursuit_link", function(events)
  return seq(events, duo3("r3u", "1v1", 712,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { hm("PURSUIT", 40, 7, 117) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 90, moves = { hm("PURSUIT", 40, 7, 117) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, moves = { hm("PURSUIT", 40, 7, 117) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(S(1), F(0)), both3(F(0), S(1)), both3(F(0), F(0)) })
end)

-- ...and against the computer its switch is AI_Switch's, which calls
-- PursuitSwitch too (FX-R2): the player's PURSUIT hits the withdrawing
-- monster, doubled, before the send-out, and its own turn is spent.  The
-- switch is AI_SwitchOrTryItem's (K16: SWITCH_OFTEN, a PERISH count of 1).
scenario("r2c_pursuit_computer", function(events)
  return seq(events, npc(duo3("r3v", "coop_npc", 713,
    { mn({ species = "Alpha", maxHp = 400, spe = 10, moves = { hm("PURSUIT", 40, 7, 117) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 90, moves = { hm("tap", 1) } }) }),
    { itemSwitch = SWITCH_OFTEN }),
    { after(perishOne, both3(F(0), F(0))), both3(F(0), F(0)) })
end)

-- FUTURE SIGHT: stored typeless (a DARK target is still hit), a second use
-- while it runs fails, the hit lands at the second turn's end with its roll
-- and accuracy byte -- on whoever stands in the aimed seat.
scenario("r2c_future_sight", function(events)
  return seq(events, duo3("r3s", "1v1", 714,
    { mn({ species = "Alpha", maxHp = 400, spe = 90,
           moves = { am("FUTURE_SIGHT", 80, 8, 119, 229), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 7 }, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), S(1)), both3(F(1), F(0)), both3(F(0), F(0)),
      both3(F(1), F(0)), both3(F(1), F(0)) })
end)

-- PROTECT / DETECT / ENDURE (ProtectChance): blocked hits ("PROTECTING
-- itself!"), the consecutive-use odds, ENDURE's 1 HP with no Focus Band byte.
scenario("r2c_protect", function(events)
  return seq(events, duo3("r3t", "1v1", 715,
    { mn({ species = "Alpha", maxHp = 400, hp = 150, spe = 90,
           item = { "FOCUS_BAND", "HELD_FOCUS_BAND", 30, "FOCUS BAND" },
           moves = { hm("PROTECT", 0, 0, 120), hm("DETECT", 0, 1, 120), hm("ENDURE", 0, 0, 121),
                     hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, atk = 250, spe = 10,
           moves = { hm("slam", 120), hm("HYPNOSIS", 0, 8, 32), hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(1)), both3(F(3), F(2)), both3(F(2), F(0)), both3(F(2), F(0)),
      both3(F(2), F(0)) })
end)

-- ...and a PROTECT after the foe went first -- here its switch, which goes
-- before every move -- fails with no byte drawn.
scenario("r2c_protect_slow", function(events)
  return seq(events, duo3("r3l", "1v1", 716,
    { mn({ species = "Alpha", maxHp = 400, spe = 10, moves = { hm("PROTECT", 0, 0, 120) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }) }),
    { both3(F(0), S(1)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- COUNTER / MIRROR COAT: twice wCurDamage after a foe that went first with a
-- physical / special hit; the wrong category, going first and a GHOST all
-- miss (the last "It doesn't affect").
scenario("r2c_counter", function(events)
  return seq(events, duo3("r3n", "1v1", 717,
    { mn({ species = "Alpha", maxHp = 600, spe = 10,
           moves = { hm("COUNTER", 1, 1, 122), hm("MIRROR_COAT", 1, 8, 123) } }),
      mn({ species = "Gamma", maxHp = 600, spe = 200, moves = { hm("COUNTER", 1, 1, 122) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 90, moves = { hm("slam", 40), hm("SURF", 40, 3) } }),
      mn({ species = "Delta", maxHp = 900, spe = 90, types = { 2 }, moves = { hm("slam", 40) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), both3(F(1), F(1)), both3(F(1), F(0)),
      both3(S(1), F(0)), both3(F(0), F(0)), both3(F(0), S(1)), both3(F(0), F(0)) })
end)

-- RAIN DANCE: WATER x1.5, FIRE x0.5, THUNDER never misses (`.ThunderRain`),
-- SOLARBEAM charges and is halved, five turns and the end line.
scenario("r2c_rain", function(events)
  return seq(events, duo3("r3a", "1v1", 718,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { am("RAIN_DANCE", 0, 3, 124, 229), am("THUNDER", 60, 10, 97, 1, 30) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90,
           moves = { hm("SOLARBEAM", 60, 9, 127), hm("SURF", 40, 3), hm("EMBER", 40, 4),
                     am("RAIN_DANCE", 0, 3, 124, 229) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(S(1), F(0)), both3(F(0), F(0)), both3(F(0), F(0)),
      both3(F(3), F(0)), both3(F(1), F(0)), both3(F(2), F(0)), both3(F(1), F(0)) })
end)

-- SUNNY DAY: FIRE x1.5, WATER x0.5, SOLARBEAM fires at once, THUNDER at its
-- `50 percent + 1` byte, nothing freezes, MORNING SUN restores it all.
scenario("r2c_sun", function(events)
  return seq(events, duo3("r3y", "wild", 719,
    { mn({ species = "Alpha", maxHp = 900, hp = 300, spe = 90,
           moves = { hm("SUNNY_DAY", 0, 4, 125), hm("SOLARBEAM", 60, 9, 127),
                     am("THUNDER", 60, 10, 97, 178, 0), hm("ICE_BEAM", 40, 3, 5, 60, 100) } }),
      mn({ species = "Gamma", maxHp = 900, hp = 300, spe = 90,
           moves = { hm("SUNNY_DAY", 0, 4, 125), hm("MORNING_SUN", 0, 0, 128), hm("EMBER", 40, 4),
                     hm("SURF", 40, 3) } }) },
    { mn({ species = "Wild", maxHp = 999, spe = 10, types = { 9 }, moves = { hm("tap", 1) } }) },
    { foe = "wild", timeOfDay = "nite" }),
    { both3(F(0), F(0), "wild"), both3(F(1), F(0), "wild"), both3(F(2), F(0), "wild"),
      both3(F(3), F(0), "wild"), both3(S(1), F(0), "wild"), both3(F(0), F(0), "wild"),
      both3(F(1), F(0), "wild"), both3(F(2), F(0), "wild"), both3(F(3), F(0), "wild") })
end)

-- SANDSTORM: an eighth off every monster but a ROCK / GROUND / STEEL and one
-- that dug, a second SANDSTORM fails, and it subsides.
scenario("r2c_sandstorm", function(events)
  return seq(events, duo3("r3d", "1v1", 720,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 0 },
           moves = { hm("SANDSTORM", 0, 5, 126), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, types = { 6, 0 },
           moves = { hm("tap", 1), hm("DIG", 30, 11, 43) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, types = { 0 }, moves = { hm("DIG", 30, 11, 43) } }) }),
    { both3(F(0), F(0)), both3(F(0), S(1)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(1), F(0)),
      both3(F(1), F(0)) })
end)

-- The time-of-day heals outside a link fight (`timeOfDay` "nite"): MORNING
-- SUN off its time a quarter, MOONLIGHT on it a half, SYNTHESIS in the rain
-- an eighth, and "HP is full!".
scenario("r2c_time_heal", function(events)
  return seq(events, duo3("r3e", "wild", 721,
    { mn({ species = "Alpha", maxHp = 400, hp = 50, spe = 90,
           moves = { hm("MORNING_SUN", 0, 0, 128), hm("MOONLIGHT", 0, 0, 130),
                     hm("SYNTHESIS", 0, 9, 129), hm("RAIN_DANCE", 0, 3, 124) } }) },
    { mn({ species = "Wild", maxHp = 400, spe = 10, moves = { hm("splash", 0, 0, 85) } }) },
    { foe = "wild", timeOfDay = "nite" }),
    { both3(F(0), F(0), "wild"), both3(F(1), F(0), "wild"), both3(F(3), F(0), "wild"),
      both3(F(2), F(0), "wild"), both3(F(1), F(0), "wild"), both3(F(1), F(0), "wild"),
      both3(F(1), F(0), "wild") })
end)

-- The ConstantDamage rows (R2b's finding (g)): SEISMIC TOSS is the level,
-- PSYWAVE its own loop, SONICBOOM its power, NIGHT SHADE against a NORMAL
-- type "doesn't affect" (`resettypematchup`) -- no crit byte, no roll.
scenario("r2c_fixed_damage", function(events)
  return seq(events, duo3("r3x", "1v1", 722,
    { mn({ species = "Alpha", level = 37, maxHp = 400, spe = 90,
           moves = { hm("SEISMIC_TOSS", 1, 1, 131), am("PSYWAVE", 1, 8, 132, 204),
                     am("SONICBOOM", 20, 0, 41, 229), hm("NIGHT_SHADE", 1, 2, 131) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, types = { 0 }, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(2), F(0)), both3(F(3), F(0)) })
end)

-- R2b's findings (a) and (b): CheckHit's byte (255 draws nothing; the
-- accuracy levels' own table), the crit and roll drawn ahead of a miss, a
-- matchup of 0 "doesn't affect" whatever the accuracy did, and JUMP KICK's
-- crash -- an eighth of the damage it rolled, none against a GHOST.
scenario("r2c_checkhit", function(events)
  -- Seed 724 since R2d's crit byte and DamageVariation loop (723 no longer
  -- missed a JUMP KICK).
  return seq(events, duo3("r3i", "1v1", 724,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, stages = { acc = 1 },
           moves = { am("wide_hit", 40, 0, 0, 178), am("JUMP_KICK", 70, 1, 45, 76),
                     hm("tap", 1), am("HI_JUMP_KICK", 85, 1, 45, 229) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, stages = { eva = 2 }, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, types = { 2 }, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(2), S(1)),
      both3(F(3), F(0)), both3(F(0), F(0)) })
end)

-- R2b's findings (c)-(f): no CheckTurn byte for sleep, SleepTarget's count
-- of 2..7, full paralysis under 63, the Disable count ticking in CheckTurn
-- ("disabled no more!").
scenario("r2c_checkturn", function(events)
  -- Seed 725 since R2d (Gold's DISABLE needs Beta's thump to have landed
  -- first: LAST_COUNTER_MOVE).
  return seq(events, duo3("r3j", "1v1", 725,
    { mn({ species = "Alpha", maxHp = 600, spe = 90,
           moves = { hm("tap", 1), hm("DISABLE", 0, 0, 86), am("HYPNOSIS", 0, 8, 32, 255) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, status = "PAR",
           moves = { hm("thump", 10), hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("thump", 10), hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(1)), both3(F(0), F(1)), both3(F(0), F(1)), both3(F(0), F(1)),
      both3(F(0), F(1)), both3(F(0), F(1)), both3(F(0), F(0)), both3(F(0), S(1)), both3(F(2), F(0)),
      both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- R2b's finding (h): a player's BIDE is asked, its FIGHT goes on with it, its
-- release runs `checkhit` and `bidefailtext` ("It doesn't affect" a GHOST),
-- and an item ends a Bide.
scenario("r2c_bide", function(events)
  return seq(events, duo3("r3q", "1v1", 725,
    { mn({ species = "Alpha", maxHp = 600, spe = 90, moves = { hm("BIDE", 0, 0, 26), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("slam", 40) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, types = { 2 }, moves = { hm("slam", 40) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(0), S(1)),
      both3(F(1), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(0), F(0)),
      both3(ITEM("POTION"), F(0)), both3(F(1), F(0)) })
end)

-- R2b's finding (i): FlinchTarget asks CheckOpponentWentFirst -- a slower
-- BITE flinches nothing -- and its EndRechargeOpp makes a recharging target
-- "flinched", not "must recharge".
scenario("r2c_flinch", function(events)
  return seq(events, duo3("r3z", "1v1", 726,
    { mn({ species = "Alpha", maxHp = 900, spe = 10, moves = { hm("BITE", 20, 7, 31, 60, 100) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 200, moves = { hm("BITE", 20, 7, 31, 60, 100) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 90, moves = { hm("tap", 1), hm("HYPER_BEAM", 50, 0, 80) } }) }),
    { both3(F(0), F(0)), both3(S(1), F(1)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- ------------------------------------------------------------------
-- the referee-gaps run's wave 4 (R2d): the Gold status and field scripts,
-- each command's own failure lines, SKULL BASH / REST / DISABLE / MIMIC as
-- the cart runs them, the computer's status cures, ResidualDamage after each
-- seat's own turn, and a faint's party `moves`.  The ruleset adds FLYING and
-- POISON to R2c's (SPIKES spare a FLYING type); every number is synthetic, and
-- `base.gender` is the proposed K15 byte.
-- ------------------------------------------------------------------

local R2D_TYPES = { "NORMAL", "FIGHTING", "GHOST", "WATER", "FIRE", "ROCK", "STEEL",
                    "DARK", "PSYCHIC_TYPE", "GRASS", "ELECTRIC", "GROUND", "FLYING", "POISON" }
local R2D_CHART = {}
for i = 1, 14 do
  R2D_CHART[i] = {}
  for j = 1, 14 do R2D_CHART[i][j] = 100 end
end
R2D_CHART[1][3] = 0
R2D_CHART[2][3] = 0
R2D_CHART[3][1] = 0
R2D_CHART[11][12] = 0
R2D_CHART[4][5] = 200
R2D_CHART[5][4] = 50
R2D_CHART[5][5] = 50
R2D_CHART[5][6] = 50
local R2D_SPECIAL = { 3, 4, 7, 8, 9, 10 }
local function duo4(id, mode, seed, aMons, bMons, extra)
  extra = extra or {}
  local o = duo(id, mode, seed, aMons, bMons, { typeIds = R2D_TYPES, chart = R2D_CHART,
    metronomePool = extra.metronomePool })
  o.specialTypes = R2D_SPECIAL
  if extra.foe then o.sides.b[1].playerId = extra.foe end
  return o
end
local function FP(i, pass) return { action = "fight", move = i, pass = pass } end
local MALE = { base = { hp = 50, atk = 50, def = 50, spe = 50, spa = 50, spd = 50, gender = 127 },
               dvs = { atk = 15, def = 8, spe = 15, spc = 8 } }
local FEMALE = { base = { hp = 50, atk = 50, def = 50, spe = 50, spa = 50, spd = 50, gender = 127 },
                 dvs = { atk = 2, def = 8, spe = 2, spc = 8 } }
local function sexed(o, sex)
  o.base, o.dvs = sex.base, sex.dvs
  return mn(o)
end

-- ATTRACT (BattleCommand_Attract, CheckOppositeGender over K15's
-- BASE_GENDER): Beta falls in love, CheckTurn's infatuation byte stops it
-- some turns, a second ATTRACT fails, a send-out breaks the love
-- (BreakAttraction), and Gamma -- whose sheet states no gender ratio --
-- cannot attract at all.
scenario("r2d_attract", function(events)
  return seq(events, duo4("r4a", "1v1", 801,
    { sexed({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("ATTRACT", 0, 0, 133), hm("tap", 1) } }, MALE),
      mn({ species = "Gamma", maxHp = 900, spe = 90, moves = { hm("ATTRACT", 0, 0, 133), hm("tap", 1) } }) },
    { sexed({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }, FEMALE) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(0), F(0)),
      both3(S(1), F(0)), both3(F(1), F(0)), both3(F(0), F(0)) })
end)

-- BATON PASS: Beta's +2 Attack and SUBSTITUTE go to the successor the FIGHT's
-- `pass` named, past Alpha's MEAN LOOK (the hold stays on the seat), and the
-- SPIKES on its side hurt it; the passed SUBSTITUTE takes Alpha's taps.
scenario("r2d_baton_pass", function(events)
  return seq(events, duo4("r4b", "1v1", 802,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("SPIKES", 0, 0, 149), hm("MEAN_LOOK", 0, 0, 142), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10,
           moves = { hm("SWORDS_DANCE", 0, 0, 50), hm("SUBSTITUTE", 0, 0, 79), hm("BATON_PASS", 0, 0, 134) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Eps", maxHp = 400, spe = 10, moves = { hm("thump", 20) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(1)), both3(F(2), FP(2, 2)), both3(F(2), F(0)), both3(F(0), F(0)),
      both3(F(2), F(0)) })
end)

-- BELLY DRUM: at 50 of 400 HP the AttackUp2 lands and the HP check fails it
-- -- the cart's bug, +2 kept -- twice; Gamma at full HP pays half and climbs
-- to +6; a third use at +6 fails at its first AttackUp2.
scenario("r2d_belly_drum", function(events)
  return seq(events, duo4("r4c", "1v1", 803,
    { mn({ species = "Alpha", maxHp = 400, hp = 50, spe = 90, moves = { hm("BELLY_DRUM", 0, 0, 135) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 90, moves = { hm("BELLY_DRUM", 0, 0, 135), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(S(1), F(0)), both3(F(0), F(0)), both3(F(0), F(0)),
      both3(F(1), F(0)) })
end)

-- CURSE: a NORMAL user trades a Speed stage for Attack and Defense (each
-- silent when it cannot rise), and at +6 / +6 says ABILITY; a GHOST user cuts
-- half its HP and curses the foe (a quarter after the foe's own turn,
-- ResidualDamage); a second curse fails.
scenario("r2d_curse", function(events)
  return seq(events, duo4("r4d", "1v1", 804,
    { mn({ species = "Gamma", maxHp = 400, spe = 90, types = { 0 }, stages = { atk = 5, def = 6 },
           moves = { hm("CURSE", 0, 2, 137) } }),
      mn({ species = "Alpha", maxHp = 400, spe = 90, types = { 2 }, moves = { hm("CURSE", 0, 2, 137), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(S(1), F(0)), both3(F(0), F(0)), both3(F(0), F(0)),
      both3(F(1), F(0)) })
end)

-- DESTINY BOND: Beta's bond, made last in a turn, holds through Alpha's next
-- move -- its KO takes Alpha down with it; Delta's, made first in a turn, is
-- gone once Gamma has moved (EndOpponentProtectEndureDestinyBond), so
-- Gamma's priority KO the turn after takes nobody.
scenario("r2d_destiny_bond", function(events)
  return seq(events, duo4("r4e", "1v1", 805,
    { mn({ species = "Alpha", maxHp = 400, atk = 300, spe = 90, moves = { hm("slam", 120), hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 400, atk = 300, spe = 10,
           moves = { hm("slam", 120), hm("tap", 1), am("QUICK_SLAM", 120, 0, 0, 255, 0, 2) } }) },
    { mn({ species = "Beta", maxHp = 200, spe = 10, moves = { hm("DESTINY_BOND", 0, 2, 138) } }),
      mn({ species = "Delta", maxHp = 200, spe = 50, moves = { hm("DESTINY_BOND", 0, 2, 138), hm("tap", 1) } }) }),
    { both3(F(1), F(0)), both3(F(0), F(0)), { { "p1", S(1) }, { "p2", S(1) } },
      both3(F(1), F(0)), both3(F(2), F(1)) })
end)

-- ENCORE: Beta has used GROWL; Alpha (faster) encores it, so Beta's TAP this
-- turn becomes GROWL; every FIGHT after is GROWL until the count runs out or
-- its 3 PP do ("ENCORE ended!").  A miss, or a target that has used nothing,
-- "didn't affect".
scenario("r2d_encore", function(events)
  return seq(events, duo4("r4f", "1v1", 806,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("ENCORE", 0, 0, 139), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("GROWL", 0, 0, 18, 3), hm("tap", 1) } }) }),
    { both3(F(0), F(1)), both3(F(1), F(0)), both3(F(0), F(1)), both3(F(1), F(1)), both3(F(1), F(1)),
      both3(F(1), F(1)), both3(F(1), F(1)), both3(F(1), F(1)) })
end)

-- FORESIGHT: a NORMAL hit "doesn't affect" the GHOST until it is identified,
-- then lands (the Foresight rows); a second FORESIGHT fails.
scenario("r2d_foresight", function(events)
  return seq(events, duo4("r4g", "1v1", 807,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("tap", 10), hm("FORESIGHT", 0, 0, 140) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 2 }, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(0), F(0)), both3(F(1), F(0)) })
end)

-- HEAL BELL: every status on Ann's side is cleared -- the field's and the
-- bench's, each a `status` event naming its party index -- "A bell chimed!".
scenario("r2d_heal_bell", function(events)
  return seq(events, duo4("r4h", "1v1", 808,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, status = "PAR", moves = { hm("HEAL_BELL", 0, 0, 141) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 90, status = "PSN", moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 400, spe = 90, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- MEAN LOOK and TELEPORT in a wild fight: the held wild monster's TELEPORT
-- fails; Ann's own TELEPORT at a lower level draws its byte loop.
scenario("r2d_mean_look", function(events)
  return seq(events, duo4("r4i", "wild", 809,
    { mn({ species = "Alpha", level = 10, maxHp = 900, spe = 90,
           moves = { hm("MEAN_LOOK", 0, 0, 142), hm("TELEPORT", 0, 0, 153), hm("tap", 1) } }) },
    { mn({ species = "Wild", level = 40, maxHp = 900, spe = 10, moves = { hm("TELEPORT", 0, 0, 153) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"), both3(F(1), F(0), "wild"),
      both3(F(1), F(0), "wild"), both3(F(1), F(0), "wild"), both3(F(1), F(0), "wild") })
end)

-- TELEPORT against a trainer fails; the wild monster's always escapes.
scenario("r2d_teleport", function(events)
  local t = seq(events, duo4("r4j", "coop_npc", 810,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("TELEPORT", 0, 0, 153) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("TELEPORT", 0, 0, 153) } }) }),
    { both3(F(0), F(0)) })
  t = seq(events, duo4("r4k", "wild", 811,
    { mn({ species = "Alpha", level = 60, maxHp = 900, spe = 90, moves = { hm("tap", 1) } }) },
    { mn({ species = "Wild", level = 5, maxHp = 900, spe = 10, moves = { hm("TELEPORT", 0, 0, 153) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild") })
  return t
end)

-- NIGHTMARE: only on a sleeper; a quarter after its turn (ResidualDamage)
-- until it wakes, which clears it (CheckTurn's `.woke_up`).
scenario("r2d_nightmare", function(events)
  return seq(events, duo4("r4l", "1v1", 812,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("NIGHTMARE", 0, 2, 143), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, status = "SLP", statusTurns = 3, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(0), F(0)) })
end)

-- PAIN SPLIT: both bars to the halved sum (side a's first), a substitute
-- "didn't affect".
scenario("r2d_pain_split", function(events)
  return seq(events, duo4("r4m", "1v1", 813,
    { mn({ species = "Alpha", maxHp = 400, hp = 20, spe = 90, moves = { am("PAIN_SPLIT", 0, 0, 144, 255) } }) },
    { mn({ species = "Beta", maxHp = 400, hp = 380, spe = 10,
           moves = { hm("wait", 0, 0, 85), hm("SUBSTITUTE", 0, 0, 79) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), both3(F(0), F(0)) })
end)

-- PERISH SONG: both counts, "3", "2", "1", "0" and both faint; a second song
-- while both run fails; the successors start clean.
scenario("r2d_perish_song", function(events)
  return seq(events, duo4("r4n", "1v1", 814,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("PERISH_SONG", 0, 0, 145), hm("wait", 0, 0, 85) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)),
      { { "p1", S(1) }, { "p2", S(1) } }, both3(F(0), F(0)) })
end)

-- PSYCH UP: a foe at every base level fails it; after SWORDS DANCE it copies.
scenario("r2d_psych_up", function(events)
  return seq(events, duo4("r4o", "1v1", 815,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("PSYCH_UP", 0, 0, 146), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("SWORDS_DANCE", 0, 0, 50) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)) })
end)

-- RAPID SPIN: SPIKES on Ann's side, LEECH SEED and a WRAP on Alpha -- the hit
-- sheds all three; the SPIKES then spare nobody on Gamma's way in... because
-- they are gone.
scenario("r2d_rapid_spin", function(events)
  return seq(events, duo4("r4p", "1v1", 816,
    { mn({ species = "Alpha", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85), hm("RAPID_SPIN", 20, 0, 147) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 90,
           moves = { hm("SPIKES", 0, 0, 149), hm("LEECH_SEED", 0, 9, 84), hm("WRAP", 15, 0, 42), hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), both3(F(0), F(2)), both3(F(1), F(3)), both3(S(1), F(3)),
      both3(F(0), F(0)), both3(S(0), F(3)) })
end)

-- SKETCH: with nothing to copy it "didn't affect"; then the wild monster's
-- last move goes into the LAST slot holding SKETCH (`.find_sketch` scans
-- from the end) with its base PP, battle and party alike -- a `moves` event
-- naming the party index; a SKETCH of a move it knows now "didn't affect".
scenario("r2d_sketch", function(events)
  return seq(events, duo4("r4q", "wild", 817,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("SKETCH", 0, 0, 148, 5), hm("tap", 1), hm("SKETCH", 0, 0, 148) } }) },
    { mn({ species = "Wild", maxHp = 900, spe = 10, moves = { hm("EMBER", 20, 4, 4, 25) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"),
      both3(F(2), F(0), "wild") })
end)

-- SKETCH in a link battle: "But nothing happened".
scenario("r2d_sketch_link", function(events)
  return seq(events, duo4("r4r", "1v1", 818,
    { mn({ species = "Alpha", maxHp = 900, spe = 10, moves = { hm("SKETCH", 0, 0, 148) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)) })
end)

-- SPITE: 2..5 PP off the foe's last move (a `moves` event for Bob's party
-- slot); against nothing used, or a move with no PP left, "didn't affect".
scenario("r2d_spite", function(events)
  return seq(events, duo4("r4s", "1v1", 819,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { am("SPITE", 0, 2, 150, 255), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("thump", 10, 0, 0, 4), hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(1)), both3(F(0), F(1)) })
end)

-- AMNESIA and the SP. DEF rows: +2 a use to +6, then "won't rise"; SP. DEF
-- DOWN lowers the foe (the computer's StatDown byte on its own).
scenario("r2d_amnesia", function(events)
  return seq(events, duo4("r4t", "coop_npc", 820,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("AMNESIA", 0, 9, 151), hm("SP_DEF_UP", 0, 9, 154) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { am("SPDEF_DROP", 0, 9, 155, 255), am("SPDEF_DROP2", 0, 9, 156, 255) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), both3(F(0), F(0)), both3(F(1), F(1)), both3(F(1), F(0)) })
end)

-- SWAGGER: the foe's Attack +2 and its confusion; again while confused (no
-- second confusion byte); at +6 the RaiseStat fails and `failuretext` ends
-- the move -- no confusion.
scenario("r2d_swagger", function(events)
  return seq(events, duo4("r4u", "1v1", 821,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { am("SWAGGER", 0, 0, 152, 255) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, stages = { atk = 6 }, moves = { hm("wait", 0, 0, 85) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(0), S(1)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- The status commands' own lines and the computer's `.CheckAIRandomFail`
-- (coop_npc: Bob is the computer): HYPNOSIS, POISONPOWDER and THUNDER WAVE
-- each draw the AI byte -- "It didn't affect" when it lands under 64 --
-- then "already asleep / poisoned / paralyzed"; Ann's LEECH SEED into a
-- substitute "evaded the attack!".
scenario("r2d_status_lines", function(events)
  -- Seed 825 (822 before K16): the trainer's AIChooseMove byte at each
  -- turn's head moved the `.CheckAIRandomFail` rolls this scenario shows.
  return seq(events, duo4("r4v", "coop_npc", 825,
    { mn({ species = "Alpha", maxHp = 999, spe = 90, moves = { hm("LEECH_SEED", 0, 9, 84), hm("wait", 0, 0, 85) } }),
      mn({ species = "Gamma", maxHp = 999, spe = 10, moves = { hm("wait", 0, 0, 85) } }),
      mn({ species = "Delta", maxHp = 999, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 50, substitute = 50,
           moves = { am("HYPNOSIS", 0, 8, 32, 255), am("POISONPOWDER", 0, 13, 66, 255),
                     am("THUNDER_WAVE", 0, 10, 67, 255) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(S(1), F(1)), both3(F(0), F(1)),
      both3(F(0), F(1)), both3(S(2), F(2)), both3(F(0), F(2)), both3(F(0), F(2)) })
end)

-- The computer's FULL HEAL / FULL RESTORE (AI_HealStatus): Bob's burned Beta
-- is cured but its Attack stays halved (no CalcEnemyStats) -- its taps hit as
-- hard as a burned monster's -- and FULL HEAL leaves its confusion; Ann's
-- FULL HEAL clears hers (HealStatus's %11111111).  The computer's are
-- AI_TryItem's (K16): with ALWAYS_USE the FULL HEAL goes on the first turn
-- (`.Status`; the FULL RESTORE row ahead of it reads a full HP bar and passes),
-- the FULL RESTORE once the HP is at a quarter (`.HealItem`).
scenario("r2d_full_heal_ai", function(events)
  local o = npc(duo4("r4w", "coop_npc", 823,
    { mn({ species = "Alpha", maxHp = 999, spe = 90, confusion = 5, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 999, atk = 200, spe = 10, status = "BRN", confusion = 6,
           moves = { hm("slam", 40) } }) }),
    { trainerItems = { "FULL_RESTORE", "FULL_HEAL" }, itemSwitch = ALWAYS_USE })
  return seq(events, o,
    { both3(F(0), F(0)), both3(ITEM("FULL_HEAL"), F(0)), both3(F(0), F(0)),
      after(hpTo(200), both3(F(0), F(0))), both3(F(0), F(0)) })
end)

-- MYSTERYBERRY against a MIMIC'd slot: MIMIC spends its last PP and copies
-- Beta's move; the berry finds the party's MIMIC at 0 and restores it there
-- alone (`.restore`'s id compare), and the party list is told once the copy
-- is undone at the switch-out.
scenario("r2d_mysteryberry_mimic", function(events)
  return seq(events, duo4("r4x", "1v1", 824,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, item = { "MYSTERYBERRY", "HELD_RESTORE_PP", 5, "MYSTERYBERRY" },
           moves = { hm("MIMIC", 0, 0, 82, 1), hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("thump", 10) } }) }),
    { both3(F(1), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(S(1), F(0)) })
end)

-- Gold's DISABLE: the foe's last move (LAST_COUNTER_MOVE) for `.loop2`'s
-- 2..8 count -- a slot at 0 PP with PP Ups is not empty to it -- counted down
-- in CheckTurn ("disabled no more!"); a count still running "But it failed!".
scenario("r2d_disable", function(events)
  local slam = hm("slam", 10, 0, 0, 1)
  slam.ppUps = 1
  return seq(events, duo4("r4y", "1v1", 825,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { am("DISABLE", 0, 0, 86, 255), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { slam, hm("tap", 1) } }) }),
    { both3(F(1), F(0)), both3(F(0), F(1)), both3(F(0), F(1)), both3(F(1), F(1)), both3(F(1), F(1)),
      both3(F(1), F(1)), both3(F(1), F(1)), both3(F(1), F(1)), both3(F(1), F(1)), both3(F(1), F(1)) })
end)

-- SKULL BASH raises Defense on its charge turn only; REST at full HP is "HP
-- is full!", hurt it sleeps two turns and restores it all; RECOVER halves.
scenario("r2d_skull_bash_rest", function(events)
  return seq(events, duo4("r4z", "1v1", 826,
    { mn({ species = "Alpha", maxHp = 400, spe = 90,
           moves = { hm("SKULL_BASH", 50, 0, 157), hm("REST", 0, 9, 56), hm("RECOVER", 0, 0, 56) } }) },
    { mn({ species = "Beta", maxHp = 900, atk = 200, spe = 10, moves = { hm("slam", 40) } }) }),
    { both3(F(1), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)),
      both3(F(1), F(0)), both3(F(1), F(0)), both3(F(2), F(0)) })
end)

-- METRONOME's `.GetMove`: a byte is a move number -- the pool's `num` where
-- it states one, its place where it does not -- redrawn on 0, past 251, on a
-- number the pool lacks and on a move the user knows.
scenario("r2d_metronome_bytes", function(events)
  local pool = { hm("pound", 10), hm("tap", 1), hm("scratch", 15) }
  pool[1].num = 200
  pool[3].num = 3
  return seq(events, duo4("r4m2", "1v1", 827,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("METRONOME", 0, 0, 83), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { metronomePool = pool }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- ResidualDamage after each seat's own turn: Alpha's poison right after its
-- move, before Beta's; in a fight of one seat a side a KO ends the turn -- the
-- KO'ing Alpha takes no poison then (Battle_PlayerFirst's `jp z`).
scenario("r2d_residual_order", function(events)
  return seq(events, duo4("r4o2", "1v1", 828,
    { mn({ species = "Alpha", maxHp = 400, atk = 120, spe = 90, status = "PSN", moves = { hm("tap", 5), hm("slam", 80) } }) },
    { mn({ species = "Beta", maxHp = 150, spe = 10, status = "BRN", moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 200, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), { { "p2", S(1) } }, both3(F(0), F(0)) })
end)

-- A faint's party `moves` (C2a): a transformed MYSTERYBERRY holder with a
-- 0-PP party slot eats the berry (the party PP the overlay hides), then
-- faints -- the party list follows the `faint`.
scenario("r2d_faint_moves", function(events)
  return seq(events, duo4("r4fm", "1v1", 829,
    { mn({ species = "Alpha", maxHp = 130, spe = 90, item = { "MYSTERYBERRY", "HELD_RESTORE_PP", 5, "MYSTERYBERRY" },
           moves = { hm("TRANSFORM", 0, 0, 57), hm("spent", 10, 0, 0, 0) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, atk = 120, spe = 10, moves = { hm("slam", 90) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), { { "p1", S(1) } },
      both3(F(0), F(0)) })
end)

-- SKETCH under TRANSFORM, the fight ending before it is undone: the copies
-- hold the transformed-into monster's moves, so the move sketched is one the
-- computer's successor used after its AI switched (a METRONOME-called move
-- writes no LAST_COUNTER_MOVE -- CheckUserIsCharging -- and a link fight's
-- SKETCH does nothing); the cart's bug writes it into the PARTY struct at
-- the copied SKETCH slot's index (TRANSFORM's own slot here), and that party
-- list is emitted before `over`.
scenario("r2d_sketch_transformed_end", function(events)
  return seq(events, npc(duo4("r4st", "coop_npc", 830,
    { mn({ species = "Alpha", maxHp = 900, hp = 60, spe = 90, moves = { hm("TRANSFORM", 0, 0, 57), hm("tap", 1) } }) },
    { mn({ species = "Wild", maxHp = 900, spe = 10, moves = { hm("SKETCH", 0, 0, 148), hm("wait", 0, 0, 85) } }),
      mn({ species = "Delta", maxHp = 900, atk = 150, spe = 10, moves = { hm("pound", 20) } }) }),
    { itemSwitch = SWITCH_OFTEN }),
    { both3(F(0), F(1)), after(perishOne, both3(F(1), F(1))), both3(F(1), F(0)), both3(F(0), F(0)),
      both3(F(1), F(0)), both3(F(1), F(0)), both3(F(1), F(0)) })
end)

-- CONVERSION2: a type that resists the foe's last move -- FIRE's, here,
-- which WATER, FIRE and ROCK resist -- off the byte loop; with nothing to
-- read, "But it failed!".
scenario("r2d_conversion2", function(events)
  return seq(events, duo4("r4cv", "1v1", 831,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { am("CONVERSION2", 0, 0, 136, 255), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("EMBER", 20, 4) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)) })
end)

-- PERISH SONG, MEAN LOOK and BATON PASS in a 2v2 (coop_pvp): the song reaches
-- all four; a passed count goes on in the successor.
scenario("r2d_perish_2v2", function(events)
  local function round(a1, a2, b1, b2)
    return { { "a1", a1 }, { "a2", a2 }, { "b1", b1 }, { "b2", b2 } }
  end
  local T = function(i, slot) return { action = "fight", move = i, target = slot } end
  return seq(events, { id = "r4pp", mode = "coop_pvp", seed = 832, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = R2D_TYPES, chart = R2D_CHART, specialTypes = R2D_SPECIAL,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 900, spe = 90,
              moves = { hm("PERISH_SONG", 0, 0, 145), hm("BATON_PASS", 0, 0, 134), hm("wait", 0, 0, 85) } }),
              mn({ species = "Iota", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 900, spe = 80,
              moves = { hm("wait", 0, 0, 85) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 900, spe = 10,
              moves = { hm("wait", 0, 0, 85) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 900, spe = 20,
              moves = { hm("PERISH_SONG", 0, 0, 145), hm("wait", 0, 0, 85) } }) } } },
    } },
    { round(T(0, 3), T(0, 3), T(0, 0), T(0, 0)), round({ action = "fight", move = 1, target = 3, pass = 1 }, T(0, 3), T(0, 0), T(1, 0)),
      round(T(0, 3), T(0, 3), T(0, 0), T(1, 0)), round(T(0, 3), T(0, 3), T(0, 0), T(1, 0)),
      round(T(0, 3), T(0, 3), T(0, 0), T(1, 0)) })
end)

-- ------------------------------------------------------------------
-- The referee-gaps run's wave 5 (R2e): the last Gold rows.
-- ------------------------------------------------------------------

local LEFTOVERS = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" }
local SMOKE_BALL = { "SMOKE_BALL", "HELD_ESCAPE", 0, "SMOKE BALL" }

-- CONVERSION (move_effects/conversion.asm): a type of one of the user's own
-- moves it does not have -- WATER or FIRE, then the other or NORMAL -- off
-- the `and 3` loop; a send-out gives the species' types back (InitBattleMon:
-- Alpha's WATER hit is no STAB on its return); Gamma, whose moves are all
-- its own NORMAL, fails ("But it failed!").
scenario("r2e_conversion", function(events)
  return seq(events, duo4("r5cv", "1v1", 901,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, types = { 0 },
           moves = { hm("CONVERSION", 0, 0, 24), hm("water_hit", 30, 3), hm("fire_hit", 30, 4) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90, types = { 0 },
           moves = { hm("CONVERSION", 0, 0, 24), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)), both3(S(1), F(0)), both3(F(0), F(0)),
      both3(S(0), F(0)), both3(F(1), F(0)) })
end)

-- HEAL BELL leaves SUBSTATUS_TOXIC (heal_bell.asm): Alpha's badly poisoned
-- count (60, 120 off 960) goes on under the PSN POISONPOWDER gives it
-- after the bell -- 180, not the eighth (120) a plain poison would take.
scenario("r2e_heal_bell_toxic", function(events)
  return seq(events, duo4("r5hb", "1v1", 902,
    { mn({ species = "Alpha", maxHp = 960, spe = 90, moves = { hm("HEAL_BELL", 0, 0, 141), hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("TOXIC", 0, 13, 105), hm("POISONPOWDER", 0, 13, 66), hm("wait", 0, 0, 85) } }) }),
    { both3(F(1), F(0)), both3(F(1), F(2)), both3(F(1), F(2)), both3(F(0), F(1)), both3(F(1), F(2)),
      both3(F(1), F(2)) })
end)

-- BATON PASS hands SUBSTATUS_TOXIC and the count on to a successor that is
-- not poisoned (baton_pass.asm keeps SubStatus5): Gamma, burned after it, is
-- hurt by its burn on the passed count (2/16, then 3/16), not the eighth.
scenario("r2e_baton_toxic", function(events)
  return seq(events, duo4("r5bt", "1v1", 903,
    { mn({ species = "Alpha", maxHp = 960, spe = 90, moves = { hm("BATON_PASS", 0, 0, 134), hm("wait", 0, 0, 85) } }),
      mn({ species = "Gamma", maxHp = 960, spe = 90, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("TOXIC", 0, 13, 105), hm("ember", 1, 4, 4, 60, 255), hm("wait", 0, 0, 85) } }) }),
    { both3(F(1), F(0)), both3(F(1), F(2)), both3(FP(0, 1), F(1)), both3(F(0), F(2)), both3(F(0), F(2)) })
end)

-- SKETCH copies the move's base PP (`Moves + MOVE_PP` by id): the wild
-- monster's MIMIC'd SLAM (a 5-PP copy) is sketched by Gamma with SLAM's own
-- 35.
scenario("r2e_sketch_mimic", function(events)
  return seq(events, duo4("r5sm", "wild", 904,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("SLAM", 40, 0, 0, 35), hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 90, moves = { hm("SKETCH", 0, 0, 148, 1), hm("tap", 1) } }) },
    { mn({ species = "Wild", maxHp = 900, spe = 10, moves = { hm("MIMIC", 0, 0, 82), hm("wait", 0, 0, 85) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(S(1), F(0), "wild"), both3(F(0), F(1), "wild"),
      both3(F(1), F(1), "wild") })
end)

-- DESTINY BOND against a recoil knockout: the target's faint and the user's
-- (its recoil left it at 0) both wait for `checkfaint`'s line, the target's
-- first.
scenario("r2e_bond_recoil", function(events)
  return seq(events, duo4("r5br", "1v1", 905,
    { mn({ species = "Alpha", maxHp = 400, hp = 10, atk = 200, spe = 10, moves = { hm("TAKE_DOWN", 200, 0, 48) } }),
      mn({ species = "Gamma", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 100, spe = 90, moves = { hm("DESTINY_BOND", 0, 0, 138) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), { { "p1", S(1) }, { "p2", S(1) } }, both3(F(0), F(0)) })
end)

-- ROAR / WHIRLWIND in a trainer (link) fight (BattleCommand_ForceSwitch):
-- Bob's ROAR, last, drags a random living member of Ann's party out into the
-- SPIKES; used first (Ann's, both ROARing) it fails.
scenario("r2e_roar_link", function(events)
  local ann = function(name)
    return mn({ species = name, maxHp = 800, spe = 90, moves = { hm("tap", 1), hm("ROAR", 0, 0, 28) } })
  end
  return seq(events, duo4("r5rl", "1v1", 906,
    { ann("Alpha"), ann("Gamma"), ann("Delta") },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("SPIKES", 0, 0, 149), hm("ROAR", 0, 0, 28) } }),
      mn({ species = "Iota", maxHp = 900, spe = 10, moves = { hm("SPIKES", 0, 0, 149), hm("ROAR", 0, 0, 28) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), both3(F(1), F(1)), both3(F(1), F(1)) })
end)

-- WHIRLWIND against a lower-level wild monster: no byte, "was blown away!",
-- and the fight ends as an escape.
scenario("r2e_whirlwind_wild", function(events)
  return seq(events, duo4("r5ww", "wild", 907,
    { mn({ species = "Alpha", level = 30, maxHp = 900, spe = 90, moves = { hm("WHIRLWIND", 0, 0, 28) } }) },
    { mn({ species = "Wild", level = 20, maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild") })
end)

-- ROAR from below the wild monster's level: the level loop's byte, against
-- its level / 4 -- "But it failed!" or "fled in fear!".
scenario("r2e_roar_wild_low", function(events)
  return seq(events, duo4("r5rw", "wild", 908,
    { mn({ species = "Alpha", level = 10, maxHp = 900, spe = 90, moves = { hm("ROAR", 0, 0, 28) } }) },
    { mn({ species = "Wild", level = 90, maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"),
      both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild") })
end)

-- PERISH SONG and SPIKES leave a monster at 0 HP and not fainted (the cart's
-- bug): Alpha perishes at the turn's last check, so Gamma -- whose SPIKES
-- take it to 0 at the send-out -- stands into the next turn, moves first,
-- and faints at the check after its move.
scenario("r2e_spikes_standing", function(events)
  return seq(events, duo4("r5ss", "1v1", 909,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 100, hp = 5, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Iota", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("SPIKES", 0, 0, 149), hm("PERISH_SONG", 0, 0, 145), hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), both3(F(0), S(1)), both3(F(0), F(0)), both3(F(0), F(0)),
      { { "p1", S(1) } }, both3(F(0), F(0)), { { "p1", S(2) } }, both3(F(0), F(0)) })
end)

-- ...and with LEFTOVERS the standing successor is lifted off 0 by the held
-- items of the turn's end (HandleLeftovers checks no faint): it fights on.
scenario("r2e_spikes_leftovers", function(events)
  return seq(events, duo4("r5sl", "1v1", 910,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 160, hp = 5, spe = 90, item = LEFTOVERS, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("SPIKES", 0, 0, 149), hm("PERISH_SONG", 0, 0, 145), hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), both3(F(0), S(1)), both3(F(0), F(0)), both3(F(0), F(0)),
      { { "p1", S(1) } }, both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- ...and a successor that comes in after a move's knockout (the turn's own
-- check) is found by the next check at once: it faints before anything.
scenario("r2e_spikes_early", function(events)
  return seq(events, duo4("r5se", "1v1", 911,
    { mn({ species = "Alpha", maxHp = 50, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Gamma", maxHp = 100, hp = 5, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Iota", maxHp = 900, spe = 90, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, atk = 250, spe = 90,
           moves = { hm("SPIKES", 0, 0, 149), hm("slam", 250) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(1)), { { "p1", S(1) } }, { { "p1", S(2) } }, both3(F(0), F(0)) })
end)

-- The computer's switch keeps its move-order slot (DetermineMoveOrder runs
-- before AI_SwitchOrTryItem): slower than Ann, its poisoned successor's
-- ResidualDamage follows Ann's move and residual; faster, it comes first.
-- The switch is AI_SwitchOrTryItem's (K16: SWITCH_OFTEN, a PERISH count of 1).
scenario("r2e_ai_switch_slow", function(events)
  return seq(events, npc(duo4("r5as", "coop_npc", 912,
    { mn({ species = "Alpha", maxHp = 800, spe = 50, status = "PSN", moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 800, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 800, spe = 10, status = "PSN", moves = { hm("tap", 1) } }) }),
    { itemSwitch = SWITCH_OFTEN }),
    { after(perishOne, both3(F(0), F(0))), both3(F(0), F(0)) })
end)
scenario("r2e_ai_switch_fast", function(events)
  return seq(events, npc(duo4("r5af", "coop_npc", 913,
    { mn({ species = "Alpha", maxHp = 800, spe = 50, status = "PSN", moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 800, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 800, spe = 10, status = "PSN", moves = { hm("tap", 1) } }) }),
    { itemSwitch = SWITCH_OFTEN }),
    { after(perishOne, both3(F(0), F(0))), both3(F(0), F(0)) })
end)

-- A PURSUIT spent chasing a switch keeps its slot in a 2v2 (coop_pvp): Bob's
-- poisoned Beta takes its residual after the faster Delta's and Alpha's
-- moves, not ahead of them.
scenario("r2e_pursuit_slot", function(events)
  local function round(a1, a2, b1, b2)
    return { { "a1", a1 }, { "a2", a2 }, { "b1", b1 }, { "b2", b2 } }
  end
  local T = function(i, slot) return { action = "fight", move = i, target = slot } end
  return seq(events, { id = "r5ps", mode = "coop_pvp", seed = 914, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = R2D_TYPES, chart = R2D_CHART, specialTypes = R2D_SPECIAL,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 900, spe = 50,
              moves = { hm("tap", 1) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 900, spe = 40,
              moves = { hm("tap", 1) } }), mn({ species = "Iota", maxHp = 900, spe = 40,
              moves = { hm("tap", 1) } }) } } },
      b = { { playerId = "b1", name = "Bob", mons = { mn({ species = "Beta", maxHp = 900, spe = 30, status = "PSN",
              moves = { hm("PURSUIT", 40, 7, 117) } }) } },
            { playerId = "b2", name = "Bea", mons = { mn({ species = "Delta", maxHp = 900, spe = 70,
              moves = { hm("tap", 1) } }) } } },
    } },
    { round(T(0, 3), { action = "switch", slot = 1 }, T(0, 1), T(0, 0)), round(T(0, 3), T(0, 3), T(0, 0), T(0, 0)) })
end)

-- A coop_wild RUN rolls TryToRunAwayFromBattle's odds: slow Ann can't
-- escape (her try counted, the turn spent); Abe's SMOKE BALL gets away.
scenario("r2e_run_coop_wild", function(events)
  return seq(events, { id = "r5rc", mode = "coop_wild", seed = 915, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = R2D_TYPES, chart = R2D_CHART, specialTypes = R2D_SPECIAL,
    sides = {
      a = { { playerId = "a1", name = "Ann", mons = { mn({ species = "Alpha", maxHp = 900, spe = 10,
              moves = { hm("tap", 1) } }) } },
            { playerId = "a2", name = "Abe", mons = { mn({ species = "Gamma", maxHp = 900, spe = 10,
              item = SMOKE_BALL, moves = { hm("tap", 1) } }) } } },
      b = { { playerId = "wild", name = "Wild", mons = { mn({ species = "Beta", maxHp = 900, spe = 200,
              moves = { hm("tap", 1) } }) } } },
    } },
    { { { "a1", { action = "run" } }, { "a2", { action = "fight", move = 0, target = 3 } }, { "wild", F(0) } },
      { { "a1", { action = "fight", move = 0, target = 3 } }, { "a2", { action = "run" } }, { "wild", F(0) } } })
end)

-- METRONOME's pool, numbered: a row with no `num` (a modded move) never
-- takes a place a vanilla number owns -- it is unreachable.
scenario("r2e_pool_num", function(events)
  local pool = {}
  for n = 1, 40 do
    pool[#pool + 1] = hm("move" .. n, 10)
    pool[#pool].num = n
  end
  table.insert(pool, 2, hm("MODDED", 250))
  return seq(events, duo4("r5pn", "1v1", 916,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("METRONOME", 0, 0, 83) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { metronomePool = pool }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- CheckTurn's confusion (wave 5): a count running out snaps out with no
-- byte; one going on says "is confused!" and draws its byte.
scenario("r2e_confusion_lines", function(events)
  return seq(events, duo4("r5cf", "1v1", 917,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, confusion = 1, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, confusion = 3, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- MIST and FOCUS ENERGY fail while already up; SUBSTITUTE's own lines.
scenario("r2e_volatile_lines", function(events)
  return seq(events, duo4("r5vl", "1v1", 918,
    { mn({ species = "Alpha", maxHp = 400, spe = 90,
           moves = { hm("MIST", 0, 0, 46), hm("FOCUS_ENERGY", 0, 0, 47), hm("SUBSTITUTE", 0, 0, 79) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("slam", 30) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(2), F(0)),
      both3(F(2), F(0)) })
end)

-- ------------------------------------------------------------------
-- The review polish (RP2, docs/plans/gen12-referee-gaps-fix.md): the bag's
-- lines and CheckTurn's status animations, each in the cart's words.
-- ------------------------------------------------------------------

-- Against the computer: the player's ItemUsedText ("<PLAYER> used the
-- <ITEM>.") and the computer's _EnemyUsedOnText ("<ENEMY> used <ITEM> on
-- <MON>!"); X ACCURACY / DIRE HIT / GUARD SPEC. say nothing more; the
-- player's X item says how it went (a raise, then a +6), the computer's
-- nothing (a raise, then a +6); a ball in a trainer fight is blocked, a POKé
-- DOLL there is refused (FX-R2: `.not_wild` uses nothing -- the turn goes on
-- the next choice); a medicine is named by the use line.  The computer's two
-- X ATTACKs are AI_TryItem's (K16, ALWAYS_USE): the first on Beta's first
-- turn out (`.XItem`), the second on a later turn's byte under 20 percent - 1.
scenario("rp2_item_lines", function(events)
  local o = duo4("rp2i", "coop_npc", 931,
    { mn({ species = "Alpha", maxHp = 999, hp = 500, spe = 90, stages = { spe = 5 },
           moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 999, hp = 500, spe = 10, stages = { atk = 5 },
           moves = { hm("wait", 0, 0, 85) } }) })
  o.sides.b[1].name = "COOLTRAINER♀ EMMA"
  npc(o, { trainerItems = { "X_ATTACK", "X_ATTACK" }, itemSwitch = ALWAYS_USE })
  return seq(events, o,
    { both3(ITEM("X_ACCURACY"), F(0)), both3(ITEM("GUARD_SPEC"), F(0)),
      both3(ITEM("X_SPEED"), F(0)), both3(ITEM("X_SPEED"), F(0)),
      both3(ITEM("POKE_BALL"), F(0)), both3(ITEM("POKE_DOLL"), F(0)),
      both3(ITEM("DIRE_HIT"), F(0)), both3(ITEM("POTION"), F(0)) })
end)

-- A wild fight's balls: ItemUsedText ahead of every throw, one wobble line
-- per miss by its count (BallBrokeFreeText .. BallSoCloseText) and no "The
-- ball shook", then Text_BallCaught.  From FX-R2 the throws are pokegold's
-- PokeBallEffect: one catch byte, then the wobble draws.
scenario("rp2_ball_lines", function(events)
  local wild = mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } })
  wild.catchRate = 200
  local o = duo4("rp2b", "wild", 932,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("slam", 90) } }) }, { wild },
    { foe = "wild" })
  local rounds = {}
  for _, ball in ipairs({ "POKE_BALL", "POKE_BALL", "GREAT_BALL", "ULTRA_BALL" }) do
    rounds[#rounds + 1] = both3(ITEM(ball), F(0), "wild")
  end
  for _ = 1, 3 do rounds[#rounds + 1] = both3(F(0), F(0), "wild") end
  for _, ball in ipairs({ "POKE_BALL", "GREAT_BALL", "ULTRA_BALL", "ULTRA_BALL" }) do
    rounds[#rounds + 1] = both3(ITEM(ball), F(0), "wild")
  end
  rounds[#rounds + 1] = both3(ITEM("MASTER_BALL"), F(0), "wild")
  return seq(events, o, rounds)
end)

-- The wobble lines at either end: no wobble at all (BallBrokeFreeText) off a
-- hard catch...
scenario("rp2_ball_broke_free", function(events)
  local hard = mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } })
  hard.catchRate = 3
  return seq(events, duo4("rp2e", "wild", 938,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) }, { hard },
    { foe = "wild" }),
    { both3(ITEM("POKE_BALL"), F(0), "wild"), both3(ITEM("POKE_BALL"), F(0), "wild") })
end)

-- ...and three wobbles that still fail (BallSoCloseText) off an easy one.
scenario("rp2_ball_so_close", function(events)
  local easy = mn({ species = "Beta", maxHp = 900, hp = 700, spe = 10, moves = { hm("wait", 0, 0, 85) } })
  easy.catchRate = 255
  local rounds = {}
  for _ = 1, 4 do rounds[#rounds + 1] = both3(ITEM("ULTRA_BALL"), F(0), "wild") end
  return seq(events, duo4("rp2c", "wild", 942,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) }, { easy },
    { foe = "wild" }), rounds)
end)

-- A wild fight's POKé DOLL: the use line and nothing after it, and the
-- fight ends a DRAW (PokeDollEffect) -- no win, no PAY DAY pot.
scenario("rp2_doll_wild", function(events)
  return seq(events, duo4("rp2d", "wild", 933,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("PAY_DAY", 40, 0, 16) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(ITEM("POKE_DOLL"), F(0), "wild") })
end)

-- The POKé FLUTE in a link fight (each side a player): Text_PlayedPokeFlute
-- then _FluteWakeUpText while anyone sleeps, _PlayedFluteText after.  And
-- the sleeping monster's ANIM_SLP ahead of its line on both sides.
scenario("rp2_flute", function(events)
  return seq(events, duo4("rp2f", "1v1", 934,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, status = "SLP", statusTurns = 4,
           moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, status = "SLP", statusTurns = 5,
           moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(ITEM("POKE_FLUTE"), F(0)), both3(ITEM("POKE_FLUTE"), F(0)) })
end)

-- CheckTurn's status animations against the computer: the player's ANIM_SLP
-- ahead of FastAsleepText (SLP_PLAYER_ANIM), the computer's behind it
-- (SLP_ANIM), and ANIM_CONFUSED behind IsConfusedText on each side
-- (CONF_PLAYER_ANIM / CONF_ANIM); none on the turn a sleeper wakes or a
-- confusion runs out.
scenario("rp2_status_anims_npc", function(events)
  return seq(events, duo4("rp2s", "coop_npc", 935,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, status = "SLP", statusTurns = 2, confusion = 3,
           moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, status = "SLP", statusTurns = 3, confusion = 4,
           moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- The same against a wild monster: the wild seat is the cart's enemy too.
scenario("rp2_status_anims_wild", function(events)
  return seq(events, duo4("rp2w", "wild", 936,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, status = "SLP", statusTurns = 3, confusion = 3,
           moves = { hm("wait", 0, 0, 85) } }) },
    { foe = "wild" }),
    { both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"), both3(F(0), F(0), "wild"),
      both3(F(0), F(0), "wild") })
end)

-- K8's PP Ups on the `moves` events: a row that states them carries them, a
-- row that states none carries none.
scenario("rp2_pp_ups", function(events)
  local upped = hm("slam", 10)
  upped.ppUps = 2
  return seq(events, duo4("rp2p", "1v1", 937,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { upped, hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)) })
end)

-- ------------------------------------------------------------------
-- The review fixes (FX-R2, docs/plans/gen12-referee-gaps-fix.md): the Gold
-- reviewer's findings, each the cart's way.  Synthetic numbers throughout.
-- ------------------------------------------------------------------

-- A function round's verdict as an event of its own (`submit` / `levelUp`).
local function verdict(kind, fn)
  return function(b, list)
    list[#list + 1] = { t = kind, text = tostring(fn(b)) }
  end
end

-- `.CheckPlayerHasUsableMoves`: with every slot that has PP DISABLEd, any
-- FIGHT index is Struggle, decided as it is chosen (the reviewer's
-- disable_struggle probe).
scenario("fx2_struggle_disabled", function(events)
  return seq(events, duo4("fx2a", "1v1", 951,
    { mn({ species = "Alpha", maxHp = 300, spe = 10, moves = { hm("growl", 0, 0, 0, 0), hm("tackle", 35, 0, 0, 5) } }) },
    { mn({ species = "Beta", maxHp = 300, spe = 90, moves = { hm("DISABLE", 0, 0, 86), hm("wait", 0, 0, 85) } }) }),
    { both3(F(1), F(1)), both3(F(1), F(0)), both3(F(0), F(1)), both3(F(1), F(1)) })
end)

-- BattleCommand_DoTurn's `.out_of_pp`: SPITE empties the slot between the
-- choice and the move -- "used", then NoPPLeftText; a charge move's
-- HasNoPPLeftText alone.
scenario("fx2_out_of_pp", function(events)
  return seq(events, duo4("fx2b", "1v1", 952,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("SPITE", 0, 0, 150), hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("thump", 10, 0, 0, 2), hm("razor", 10, 0, 39, 2), hm("tap", 1) } }) }),
    { both3(F(1), F(0)), both3(F(0), F(0)), both3(F(1), F(1)), both3(F(1), F(1)), both3(F(0), F(1)),
      both3(F(1), F(2)) })
end)

-- AI_Switch's PursuitSwitch: the player's PURSUIT knocks the computer's
-- withdrawing monster out before the send-out, and pays no EXP.  The switch
-- is AI_SwitchOrTryItem's (K16: SWITCH_OFTEN, a PERISH count of 1).
scenario("fx2_pursuit_ai_ko", function(events)
  return seq(events, npc(duo4("fx2c", "coop_npc", 953,
    { mn({ species = "Alpha", maxHp = 300, atk = 200, spe = 10, moves = { hm("PURSUIT", 40, 7, 117) } }) },
    { mn({ species = "Beta", maxHp = 300, hp = 5, spe = 90, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 300, spe = 90, moves = { hm("tap", 1) } }) }),
    { itemSwitch = SWITCH_OFTEN }),
    { after(perishOne, both3(F(0), F(0))), both3(F(0), F(0)) })
end)

-- wEnemyGoesFirst: after the computer's item or switch the player's
-- PROTECT / ENDURE fail (the reviewer's protect_ai_item probe).  Both are
-- AI_SwitchOrTryItem's (K16): the X ATTACK on Beta's first turn out
-- (ALWAYS_USE's `.XItem`), the switch at a PERISH count of 1 (SWITCH_OFTEN).
scenario("fx2_protect_ai_item", function(events)
  return seq(events, npc(duo4("fx2d", "coop_npc", 954,
    { mn({ species = "Alpha", maxHp = 300, spe = 90, moves = { hm("PROTECT", 0, 0, 120), hm("ENDURE", 0, 0, 121) } }) },
    { mn({ species = "Beta", maxHp = 300, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 300, spe = 10, moves = { hm("tap", 1) } }) }),
    { trainerItems = { "X_ATTACK" }, itemSwitch = SWITCH_OFTEN + ALWAYS_USE }),
    { both3(F(0), F(0)), after(perishOne, both3(F(1), F(0))), both3(F(0), F(0)) })
end)

-- Crystal's AI_TryItem zeroes wLastEnemyCounterMove (DISABLE and MIRROR MOVE
-- find nothing); Gold / Silver's does not (the reviewer's ai_item_counter).
-- The items are AI_TryItem's (K16): a MAX POTION, then a POTION, each at an
-- HP of a quarter (`.HealItem`; the POTION row reads item 2 through `de`).
local function itemCounter(id, seed, family)
  return function(events)
    local o = npc(duo4(id, "coop_npc", seed,
      { mn({ species = "Alpha", maxHp = 300, spe = 10,
             moves = { hm("DISABLE", 0, 0, 86), hm("MIRROR_MOVE", 0, 0, 9), hm("wait", 0, 0, 85) } }) },
      { mn({ species = "Beta", maxHp = 300, spe = 90, moves = { hm("tap", 1) } }) }),
      { trainerItems = { "MAX_POTION", "POTION" } })
    o.sides.a[1].family = family
    return seq(events, o, { both3(F(2), F(0)), after(hpTo(50), both3(F(1), F(0))), both3(F(2), F(0)),
      after(hpTo(50), both3(F(0), F(0))) })
  end
end
scenario("fx2_ai_item_counter_crystal", itemCounter("fx2e", 955, "crystal"))
scenario("fx2_ai_item_counter_gold", itemCounter("fx2f", 955, "gs"))

-- SPIKES: the computer's own switch (AI_Switch) takes none; the successor
-- of its faint does (EnemyPartyMonEntrance).  The switch is
-- AI_SwitchOrTryItem's (K16: SWITCH_OFTEN, a PERISH count of 1).
scenario("fx2_spikes_ai_switch", function(events)
  return seq(events, npc(duo4("fx2g", "coop_npc", 956,
    { mn({ species = "Alpha", maxHp = 300, atk = 250, spe = 90,
           moves = { hm("SPIKES", 0, 0, 149), hm("wait", 0, 0, 85), hm("slam", 200) } }) },
    { mn({ species = "Beta", maxHp = 300, spe = 10, moves = { hm("wait", 0, 0, 85) } }),
      mn({ species = "Delta", maxHp = 60, def = 5, spe = 10, moves = { hm("wait", 0, 0, 85) } }),
      mn({ species = "Eps", maxHp = 300, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { itemSwitch = SWITCH_OFTEN }),
    { both3(F(0), F(0)), after(perishOne, both3(F(1), F(0))), both3(F(2), F(0)), { { "p2", S(2) } },
      both3(F(1), F(0)) })
end)

-- BATON PASS's send-out zeroes both sides' counter moves: a foe's MIRROR
-- MOVE right after it fails (the reviewer's bp_mirror probe).
scenario("fx2_baton_pass_mirror", function(events)
  return seq(events, duo4("fx2h", "1v1", 957,
    { mn({ species = "Passer", maxHp = 300, spe = 90, moves = { hm("BATON_PASS", 0, 0, 134) } }),
      mn({ species = "Heir", maxHp = 300, spe = 10, moves = { hm("tap", 1) } }) },
    { mn({ species = "Mirror", maxHp = 300, spe = 10, moves = { hm("MIRROR_MOVE", 0, 0, 9), hm("tap", 1) } }),
      mn({ species = "Bench", maxHp = 300, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(FP(0, 1), F(0)), both3(F(0), F(0)), both3(F(0), F(0)) })
end)

-- Both last monsters down at once: against the computer LostBattle (side b
-- wins), in a link fight TiedAgainstText (a draw).
local function mutualKo(id, mode)
  return function(events)
    return seq(events, duo4(id, mode, 958,
      { mn({ species = "Alpha", maxHp = 100, atk = 250, spe = 90, moves = { hm("EXPLOSION", 250, 0, 7) } }) },
      { mn({ species = "Beta", maxHp = 20, def = 5, spe = 10, moves = { hm("tap", 1) } }) }),
      { both3(F(0), F(0)) })
  end
end
scenario("fx2_mutual_ko_npc", mutualKo("fx2i", "coop_npc"))
scenario("fx2_mutual_ko_link", mutualKo("fx2j", "1v1"))

-- SANDSTORM and a wrap: the HP bar, then the line, and a knockout waits for
-- the faint check after the routine.
scenario("fx2_residual_ko", function(events)
  return seq(events, duo4("fx2k", "1v1", 959,
    { mn({ species = "Alpha", maxHp = 400, spe = 90, moves = { hm("SANDSTORM", 0, 5, 126), hm("wrap", 15, 0, 42) } }) },
    { mn({ species = "Beta", maxHp = 400, hp = 60, spe = 10, moves = { hm("wait", 0, 0, 85) } }),
      mn({ species = "Delta", maxHp = 400, hp = 80, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), { { "p2", S(1) } }, both3(F(1), F(0)), both3(F(1), F(0)) })
end)

-- The bag's "It won't have any effect.": refused items (not spent, the seat
-- asked again) and an X item on a stat of 999 (used, "won't rise anymore!").
scenario("fx2_bag_no_effect", function(events)
  local function try(choice)
    return verdict("submit", function(b) return b:submitChoice("p1", choice) end)
  end
  local o = duo4("fx2l", "coop_npc", 960,
    { mn({ species = "Alpha", maxHp = 300, atk = 999, spe = 90, focusEnergy = true,
           moves = { hm("tap", 1), hm("kick", 10, 0, 0, 5) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) })
  o.sides.a[1].bag = { { id = "X_ATTACK", count = 1 }, { id = "X_ACCURACY", count = 2 },
    { id = "DIRE_HIT", count = 1 }, { id = "POTION", count = 2 }, { id = "ANTIDOTE", count = 1 },
    { id = "ETHER", count = 1 } }
  return seq(events, o, {
    try(ITEM("DIRE_HIT")), try({ action = "item", item = "POTION", slot = 0 }),
    try({ action = "item", item = "ANTIDOTE", slot = 0 }),
    try({ action = "item", item = "ETHER", slot = 0, move = 0 }),
    both3(ITEM("X_ATTACK"), F(0)), both3(ITEM("X_ACCURACY"), F(0)), try(ITEM("X_ACCURACY")),
    both3({ action = "item", item = "POTION", slot = 0 }, F(0)) })
end)

-- PokeBallEffect: BallMultiplierFunctionTable's balls, the HP step, the
-- SLP / FRZ bonus, one catch byte and the wobble draws (a LURE BALL in a
-- BATTLETYPE_FISH fight, a FAST BALL on MAGNEMITE, a LOVE BALL on the same
-- species and gender, a HEAVY BALL by the sheet's weight).
scenario("fx2_ball_table", function(events)
  local wild = mn({ species = "Beta", level = 20, maxHp = 300, spe = 10, status = "SLP", statusTurns = 7,
    moves = { hm("wait", 0, 0, 85) },
    base = { hp = 50, atk = 50, def = 50, spe = 50, spa = 50, spd = 50, gender = 127 },
    dvs = { atk = 15, def = 8, spe = 15, spc = 8 } })
  wild.catchRate = 3
  wild.speciesId = "MAGNEMITE"
  wild.weight = 2000
  local o = duo4("fx2m", "wild", 961,
    { mn({ species = "Alpha", level = 50, maxHp = 300, spe = 90, moves = { hm("wait", 0, 0, 85) },
           base = { hp = 50, atk = 50, def = 50, spe = 50, spa = 50, spd = 50, gender = 127 },
           dvs = { atk = 15, def = 8, spe = 15, spc = 8 } }) },
    { wild }, { foe = "wild" })
  o.sides.a[1].mons[1].speciesId = "MAGNEMITE"
  o.battleType = 4
  local rounds = {}
  for _, ball in ipairs({ "POKE_BALL", "GREAT_BALL", "PARK_BALL", "MOON_BALL", "FRIEND_BALL", "HEAVY_BALL",
                          "LURE_BALL", "FAST_BALL", "LEVEL_BALL", "LOVE_BALL", "ULTRA_BALL" }) do
    rounds[#rounds + 1] = both3(ITEM(ball), F(0), "wild")
  end
  return seq(events, o, rounds)
end)

-- K9 levelUp with Red's guards: no level-up between players, nor for the
-- computer's seat; a level that rises, stats that do not fall, the K7
-- ceiling at full stat exp.
scenario("fx2_level_up_guards", function(events)
  local function up(...)
    local args = { ... }
    return verdict("levelUp", function(b) return b:levelUp(args[1], args[2], args[3], args[4], args[5]) end)
  end
  local o = duo4("fx2n", "coop_npc", 962,
    { mn({ species = "Alpha", level = 29, maxHp = 60, spe = 40, moves = { hm("tap", 1) },
           base = { hp = 50, atk = 50, def = 50, spe = 50, spa = 50, spd = 50 },
           dvs = { atk = 15, def = 15, spe = 15, spc = 15 } }) },
    { mn({ species = "Beta", level = 20, maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) })
  local function s5(v) return { atk = v, def = v, spe = v, spa = v, spd = v } end
  return seq(events, o, {
    up("p2", 1, 21, s5(50), 950), up("p1", 1, 29, s5(50), 70), up("p1", 1, 30, s5(39), 70),
    up("p1", 1, 30, s5(63), 97), up("p1", 1, 30), both3(F(0), F(0)),
    up("p1", 1, 31, s5(64), 101), up("p1", 1, 31, s5(64), 100), both3(F(0), F(0)) })
end)

-- docs/plans/gen12-referee-remaining-gaps.md, the Gold half (W1-T2): the
-- name marks (K17), the cart's breaks (K18), a move's knockout fainting at
-- the check after the turn (K19) and the cart's status / residual / weather
-- clips (K20).  `t2_marks_ko_tails`: both sides marked, SuperEffectiveText's
-- break, a drain's KO fainting after SuckedHealthText and a recoil that KOs
-- both (the target first); `t2_thief_bond_boom`: THIEF robbing a foe it
-- knocks out, DESTINY BOND's line, clip and faints, and EXPLOSION's user
-- emptied at `selfdestruct`, the target's bond reset; `t2_status_anims`:
-- PSN / CONF / stat-down / SAP clips against the computer;
-- `t2_love_sand_bind`: IN_LOVE, IN_SANDSTORM, HandleWrap's move clip and
-- ItemRecoveryAnim; `t2_nightmare_curse_fs`: IN_NIGHTMARE for both, the
-- CURSE's paragraphs and FUTURE SIGHT's clip.
scenario("t2_marks_ko_tails", function(events)
  return seq(events, duo4("t2a", "1v1", 971,
    { mn({ species = "Alpha", types = { 3 }, maxHp = 100, hp = 1, atk = 250, spe = 90,
           moves = { hm("sap", 80, 3, 3), hm("ram", 80, 0, 48) } }) },
    { mn({ species = "Beta", types = { 4 }, maxHp = 100, hp = 5, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", types = { 0 }, maxHp = 100, hp = 60, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Eps", maxHp = 300, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), { { "p2", S(1) } }, both3(F(1), F(0)) })
end)

scenario("t2_thief_bond_boom", function(events)
  return seq(events, duo4("t2b", "1v1", 972,
    { mn({ species = "Alpha", maxHp = 100, atk = 250, spe = 10,
           moves = { hm("THIEF", 40, 0, 0, 60, 100) } }),
      mn({ species = "Gamma", maxHp = 100, atk = 250, spe = 10, substitute = 20,
           moves = { hm("EXPLOSION", 250, 0, 7) } }),
      mn({ species = "Zeta", maxHp = 100, spe = 10, moves = { hm("tap", 1) } }) },
    { mn({ species = "Beta", maxHp = 100, hp = 5, spe = 90, item = { "LEFTOVERS", "HELD_LEFTOVERS", 0, "LEFTOVERS" },
           moves = { hm("DESTINY_BOND", 0, 0, 138) } }),
      mn({ species = "Delta", maxHp = 50, def = 5, spe = 90, moves = { hm("DESTINY_BOND", 0, 0, 138) } }),
      mn({ species = "Eps", maxHp = 300, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), { { "p1", S(1) }, { "p2", S(1) } }, both3(F(0), F(0)) })
end)

scenario("t2_status_anims", function(events)
  return seq(events, duo4("t2c", "coop_npc", 973,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("sting", 10, 0, 2, 60, 100), hm("psybeam", 10, 0, 76, 60, 100),
                     hm("LEER", 0, 0, 19), hm("LEECH_SEED", 0, 9, 84) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("GROWL", 0, 0, 18), hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(1)), both3(F(2), F(0)), both3(F(3), F(1)), both3(F(2), F(1)) })
end)

scenario("t2_love_sand_bind", function(events)
  return seq(events, duo4("t2d", "1v1", 974,
    { sexed({ species = "Alpha", maxHp = 900, spe = 90,
              moves = { hm("ATTRACT", 0, 0, 133), hm("SANDSTORM", 0, 5, 126), hm("BIND", 10, 0, 42) } }, MALE) },
    { sexed({ species = "Beta", maxHp = 100, hp = 60, spe = 10, item = { "BERRY", "HELD_BERRY", 12, "BERRY" },
              moves = { hm("tap", 1) } }, FEMALE) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(2), F(0)), both3(F(2), F(0)) })
end)

scenario("t2_nightmare_curse_fs", function(events)
  return seq(events, duo4("t2e", "1v1", 975,
    { mn({ species = "Alpha", types = { 2 }, maxHp = 900, spe = 90,
           moves = { hm("NIGHTMARE", 0, 0, 143), hm("CURSE", 0, 2, 137), hm("FUTURE_SIGHT", 40, 8, 119),
                     hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, status = "SLP", statusTurns = 7, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(2), F(0)), both3(F(3), F(0)), both3(F(3), F(0)) })
end)

-- docs/plans/gen12-referee-remaining-gaps.md, wave 2's Gold half (H2): the
-- computer's choices at the cart's points (K16) -- `"auto"` is `autoPick`, the
-- path a hub's NPC seat and a solo foe take.  `h2_ai_flags0` / `_layers`:
-- AIChooseMove with no layers and with all ten; `h2_ai_disabled`: the AI's
-- slot DISABLE takes from it the same turn fails at CheckTurn, then
-- `.continue` finds nothing usable -- Struggle; `h2_ai_out_of_pp`: the slot
-- SPITE empties is `.out_of_pp`; `h2_ai_encore`: ENCORE's move whatever the
-- AI drew; `h2_wild_pick`: `.loop2`'s redraws (an empty slot, no PP, the
-- disabled one); `h2_ai_item_base_reward`: AI_TryItem reads the base reward
-- as an item; `h2_ai_potion`; `h2_ai_switch_pursuit`: PERISH SONG's count of
-- 1 makes AI_SwitchOrTryItem switch -- PURSUIT chases it, then the withdraw
-- line, no SPIKES; `h2_replace_single`: FindMonInOTPartyToSwitchIntoBattle
-- and the move-struct type a THRASH carries on into the successor;
-- `h2_replace_double`: the AI's successor scored against the player's own;
-- `h2_love_ball_transform`; `h2_quiet_anims` / `h2_miss_no_anim` (K22);
-- `h2_side_word_marks` (K17); `h2_selfdestruct_status`; `h2_team_hold`;
-- `h2_pursuit_bond`; `h2_solo_seat` (SoloBattle's `sides.b[1]`).
local function A(choice, foe)
  foe = foe or "p2"
  return { { "p1", choice }, { foe, "auto" }, { foe, "auto" } }
end
local function typed(o, types)
  o.types = types
  return mn(o)
end

scenario("h2_ai_flags0", function(events)
  return seq(events, duo4("h2a", "coop_npc", 1101,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("tap", 5), hm("thump", 10), hm("slam", 20) } }) }),
    { A(F(0)), A(F(0)), A(F(0)), A(F(0)), A(F(0)) })
end)

scenario("h2_ai_layers", function(events)
  local o = duo4("h2b", "coop_npc", 1102,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, status = "PSN", types = { 4 },
           moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, types = { 3 },
           moves = { am("HYPNOSIS", 0, 8, 32, 255), hm("splash_wave", 40, 3), hm("tap", 5),
                     hm("GROWL", 0, 0, 18) } }) })
  npc(o, { aiFlags = 1023 })
  return seq(events, o, { A(F(0)), A(F(0)), A(F(0)), A(F(0)) })
end)

scenario("h2_ai_disabled", function(events)
  return seq(events, duo4("h2c", "coop_npc", 1103,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("wait", 0, 0, 85), hm("DISABLE", 0, 0, 86) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 5) } }) }),
    { A(F(0)), A(F(1)), A(F(0)), A(F(0)) })
end)

scenario("h2_ai_out_of_pp", function(events)
  return seq(events, duo4("h2d", "coop_npc", 1104,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("wait", 0, 0, 85), hm("SPITE", 0, 0, 150) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 5, 0, 0, 2) } }) }),
    { A(F(0)), A(F(1)), A(F(0)) })
end)

scenario("h2_ai_encore", function(events)
  return seq(events, duo4("h2e", "coop_npc", 1105,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("wait", 0, 0, 85), hm("ENCORE", 0, 0, 139) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("tap", 5), hm("thump", 10), hm("slam", 20) } }) }),
    { A(F(0)), A(F(1)), A(F(0)), A(F(0)), A(F(0)) })
end)

scenario("h2_wild_pick", function(events)
  return seq(events, duo4("h2f", "wild", 1106,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("wait", 0, 0, 85), hm("DISABLE", 0, 0, 86) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("tap", 5, 0, 0, 0), hm("thump", 10), hm("slam", 20) } }) }, { foe = "wild" }),
    { A(F(0), "wild"), A(F(0), "wild"), A(F(1), "wild"), A(F(0), "wild"), A(F(0), "wild"),
      A(F(0), "wild") })
end)

scenario("h2_ai_item_base_reward", function(events)
  local o = duo4("h2g", "coop_npc", 1107,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("tap", 5) } }) })
  -- ANTIDOTE matches no row; FULL_RESTORE (item 2) matches the first and its
  -- routine declines at full HP, so `de` stays on item 2 and the rows after
  -- read the byte past it: the base reward, $31 -- X_ATTACK's number.
  npc(o, { itemSwitch = 0x10, trainerItems = { "ANTIDOTE", "FULL_RESTORE" }, baseReward = 0x31 })
  return seq(events, o, { A(F(0)), A(F(0)) })
end)

scenario("h2_ai_potion", function(events)
  local o = duo4("h2h", "coop_npc", 1108,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 100, hp = 20, spe = 10, moves = { hm("tap", 5) } }) })
  npc(o, { trainerItems = { "POTION" } })
  return seq(events, o, { A(F(0)), A(F(0)) })
end)

scenario("h2_ai_switch_pursuit", function(events)
  local o = duo4("h2i", "coop_npc", 1109,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("PERISH_SONG", 0, 0, 145), hm("wait", 0, 0, 85), hm("PURSUIT", 40, 7, 117) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 50, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 400, spe = 10, moves = { hm("tap", 5) } }),
      mn({ species = "Delta", maxHp = 400, spe = 10, moves = { hm("tap", 5) } }) })
  npc(o, { itemSwitch = 0x01 })
  return seq(events, o, { A(F(0)), A(F(1)), A(F(1)), A(F(2)), { { "p1", S(1) }, { "p2", "auto" } },
    A(F(0)) })
end)

scenario("h2_replace_single", function(events)
  return seq(events, duo4("h2j", "coop_npc", 1110,
    { typed({ species = "Alpha", maxHp = 900, atk = 200, spe = 90,
              moves = { hm("THRASH", 60, 0, 27) } }, { 10 }) },
    { typed({ species = "Beta", maxHp = 100, hp = 5, spe = 10, moves = { hm("tap", 5) } }, { 0 }),
      typed({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("tap", 5) } }, { 11 }) }),
    { A(F(0)), A(F(0)), A(F(0)) })
end)

scenario("h2_replace_double", function(events)
  return seq(events, duo4("h2k", "coop_npc", 1111,
    { typed({ species = "Alpha", maxHp = 100, atk = 250, spe = 90,
              moves = { hm("EXPLOSION", 250, 0, 7) } }, { 0 }),
      typed({ species = "Gamma", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }, { 4 }) },
    { typed({ species = "Beta", maxHp = 50, def = 5, spe = 10, moves = { hm("tap", 5) } }, { 0 }),
      typed({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("tap", 5) } }, { 0 }),
      typed({ species = "Eps", maxHp = 900, spe = 10, moves = { hm("splash_wave", 40, 3) } }, { 3 }) }),
    { A(F(0)), { { "p2", "auto" }, { "p1", S(1) } }, A(F(0)) })
end)

scenario("h2_love_ball_transform", function(events)
  local wild = sexed({ species = "Beta", maxHp = 300, spe = 10, moves = { hm("TRANSFORM", 0, 0, 57) } }, FEMALE)
  wild.speciesId, wild.catchRate = "MAGNEMITE", 3
  local alpha = sexed({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("wait", 0, 0, 85) } }, MALE)
  alpha.speciesId = "MAGNEMITE"
  return seq(events, duo4("h2l", "wild", 1112, { alpha }, { wild }, { foe = "wild" }),
    { A(ITEM("LOVE_BALL"), "wild"), A(F(0), "wild"), A(ITEM("LOVE_BALL"), "wild"),
      A(ITEM("LOVE_BALL"), "wild") })
end)

scenario("h2_quiet_anims", function(events)
  return seq(events, duo4("h2m", "1v1", 1113,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { hm("SOLARBEAM", 60, 9, 127), am("FLY", 60, 12, 43, 1), hm("BIND", 10, 0, 42),
                     am("HI_JUMP_KICK", 60, 1, 45, 1) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(0)), both3(F(2), F(0)),
      both3(F(3), F(0)), both3(F(3), F(0)) })
end)

scenario("h2_miss_no_anim", function(events)
  return seq(events, duo4("h2n", "1v1", 1114,
    { mn({ species = "Alpha", maxHp = 900, spe = 90,
           moves = { am("whiff", 40, 0, 0, 1), am("HYPNOSIS", 0, 8, 32, 1), hm("SANDSTORM", 0, 5, 126),
                     hm("MIRROR_MOVE", 0, 0, 9) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, status = "PSN",
           moves = { hm("tap", 5), am("POISONPOWDER", 0, 13, 66, 255) } }) }),
    { both3(F(0), F(0)), both3(F(1), F(1)), both3(F(2), F(0)), both3(F(2), F(0)), both3(F(3), F(1)) })
end)

scenario("h2_side_word_marks", function(events)
  local rounds = { both3(F(0), F(0)) }
  for _ = 1, 5 do rounds[#rounds + 1] = both3(F(1), F(1)) end
  return seq(events, duo4("h2o", "1v1", 1115,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("LIGHT_SCREEN", 0, 8, 64), hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("REFLECT", 0, 8, 65), hm("wait", 0, 0, 85) } }) }),
    rounds)
end)

scenario("h2_selfdestruct_status", function(events)
  return seq(events, duo4("h2p", "1v1", 1116,
    { mn({ species = "Alpha", maxHp = 100, atk = 250, spe = 90, status = "PSN", leechSeed = { fromSlot = 3 },
           moves = { hm("EXPLOSION", 250, 0, 7) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), { { "p1", S(1) } }, both3(F(0), F(0)) })
end)

scenario("h2_team_hold", function(events)
  return seq(events, duo4("h2q", "1v1", 1117,
    { mn({ species = "Alpha", maxHp = 100, hp = 1, atk = 250, spe = 90, moves = { hm("ram", 80, 0, 48) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 100, hp = 5, spe = 10, moves = { hm("tap", 1) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("tap", 1) } }) }),
    { both3(F(0), F(0)), { { "p1", S(1) }, { "p2", S(1) } }, both3(F(0), F(0)) })
end)

scenario("h2_pursuit_bond", function(events)
  return seq(events, duo4("h2r", "1v1", 1118,
    { mn({ species = "Alpha", maxHp = 20, spe = 10, moves = { hm("DESTINY_BOND", 0, 0, 138) } }),
      mn({ species = "Gamma", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { mn({ species = "Beta", maxHp = 300, atk = 250, spe = 90,
           moves = { hm("wait", 0, 0, 85), hm("PURSUIT", 80, 7, 117) } }),
      mn({ species = "Delta", maxHp = 900, spe = 10, moves = { hm("wait", 0, 0, 85) } }) }),
    { both3(F(0), F(0)), both3(S(1), F(1)), { { "p2", S(1) } }, both3(F(0), F(0)) })
end)

-- A solo trainer fight (src/SoloBattle.lua): `solo_foe` in coop_npc, the
-- side entry K16 builds (aiFlags, trainerItems, itemSwitch, baseReward,
-- countSpeciesTypes, no bag), `autoPick` every turn and every send-out.
scenario("h2_solo_seat", function(events)
  local o = duo4("h2s", "coop_npc", 1119,
    { typed({ species = "Alpha", maxHp = 300, atk = 150, spe = 90,
              moves = { hm("thump", 50), hm("splash_wave", 50, 3) } }, { 3 }),
      typed({ species = "Gamma", maxHp = 300, atk = 150, spe = 50, moves = { hm("thump", 50) } }, { 0 }) },
    { typed({ species = "Beta", level = 22, maxHp = 200, spe = 40,
              moves = { hm("tap", 20), hm("GROWL", 0, 0, 18) } }, { 4 }),
      typed({ species = "Delta", level = 20, maxHp = 200, spe = 40,
              moves = { hm("splash_wave", 30, 3), hm("tap", 20) } }, { 3 }),
      typed({ species = "Eps", level = 20, maxHp = 200, spe = 40, moves = { hm("tap", 20) } }, { 5 }) },
    { foe = "solo_foe" })
  o.sides.b[1].name = "YOUNGSTER JOEY"
  npc(o, { aiFlags = 0x07, trainerItems = { "POTION", "X_ATTACK" }, itemSwitch = 0x01,
           baseReward = 0x12, countSpeciesTypes = { 3 } })
  local rounds = {}
  for _ = 1, 16 do rounds[#rounds + 1] = A(F(0), "solo_foe") end
  return seq(events, o, rounds)
end)

-- H2's follow-up: UsedMoveText / BattleCommand_Charge write no LAST_MOVE or
-- LAST_COUNTER_MOVE while CheckUserIsCharging -- ResetTurn's 1, set when
-- METRONOME, MIRROR MOVE or SLEEP TALK calls a move and kept through
-- `.locked_in`.  `h2f_mirror_charge`: Bob's MIRROR MOVE copies Ann's FLY, and
-- the copy's charge and release write nothing -- Ann's MIRROR MOVE fails on
-- it -- until Bob's own tap, chosen, is recorded again (ParsePlayerAction's
-- `.encored` zeroes the flag); Ann's copy of it writes nothing either.
scenario("h2f_mirror_charge", function(events)
  return seq(events, duo4("h2fm", "1v1", 1131,
    { mn({ species = "Alpha", maxHp = 600, spe = 90,
           moves = { hm("FLY", 30, 0, 43), hm("MIRROR_MOVE", 0, 0, 9) } }) },
    { mn({ species = "Beta", maxHp = 600, spe = 10, moves = { hm("MIRROR_MOVE", 0, 0, 9), hm("tap", 1) } }) }),
    { both3(F(0), F(0)), "tick", both3(F(1), F(1)), both3(F(1), F(0)) })
end)

-- `h2f_multi_hit_anims`: BattleCommand_EndLoop loops back to `critical`, so
-- every hit plays its own `moveanimnosub` -- one `anim` a hit -- and `amount`
-- is that hit's wBattleAnimParam: `lowersub`'s 1 behind the user's own
-- SUBSTITUTE, flipped before every DOUBLE_HIT / POISON_MULTI_HIT / MULTI_HIT
-- clip (`.alternate_anim`), one up after every TRIPLE KICK kick.  A MULTI_HIT
-- METRONOME calls starts from 0 behind the same SUBSTITUTE: its `lowersub`
-- returns at CheckUserIsCharging.
scenario("h2f_multi_hit_anims", function(events)
  return seq(events, duo4("h2fh", "1v1", 1133,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, substitute = 100,
           moves = { hm("double_hit", 20, 0, 44), hm("twin", 20, 0, 77), hm("METRONOME", 0, 0, 83),
                     hm("TRIPLE_KICK", 10, 0, 112) } }) },
    { mn({ species = "Beta", maxHp = 999, spe = 10, moves = { hm("wait", 0, 0, 85) } }) },
    { metronomePool = { hm("multi", 15, 0, 29) } }),
    { both3(F(0), F(0)), both3(F(1), F(0)), both3(F(2), F(0)), both3(F(3), F(0)) })
end)

-- `h2f_coop_npc_double`: a co-op 2v2 against one computer trainer whose party
-- is dealt across two seats (`countSpeciesTypes` absent -- Turn.create keeps
-- it only for a seat dealt the whole party), each seat carrying K16's bytes:
-- every turn each seat's AIChooseMove pick, AI_SwitchOrTryItem (a POTION at a
-- quarter of the HP) and, after a knockout, its own
-- FindMonInOTPartyToSwitchIntoBattle -- all through `autoPick`, as
-- `Hub:fillNpcChoices` drives them -- and the fight runs to its end.
local function T(i, target) return { action = "fight", move = i, target = target } end
local function A2(a1, a2)
  return { { "a1", a1 }, { "a2", a2 }, { "b1", "auto" }, { "b2", "auto" }, { "b1", "auto" }, { "b2", "auto" } }
end
scenario("h2f_coop_npc_double", function(events)
  local k16 = function(name)
    return { aiFlags = 0x07, trainerItems = { "POTION", "NO_ITEM" }, itemSwitch = 0x01, baseReward = 0x12,
             name = name }
  end
  local o = { id = "h2fd", mode = "coop_npc", seed = 1134, choiceTimeout = 60, reconnectGrace = 60,
    typeIds = R2D_TYPES, chart = R2D_CHART, specialTypes = R2D_SPECIAL,
    sides = {
      a = {
        { playerId = "a1", name = "Ann", mons = {
          mn({ species = "Alpha", maxHp = 400, atk = 160, spe = 90, moves = { hm("thump", 60), hm("tap", 10) } }) } },
        { playerId = "a2", name = "Abe", mons = {
          mn({ species = "Gamma", maxHp = 400, atk = 160, spe = 70, moves = { hm("thump", 60), hm("tap", 10) } }) } },
      },
      b = {
        { playerId = "b1", mons = {
          mn({ species = "Beta", level = 22, maxHp = 160, spe = 50, moves = { hm("tap", 20), hm("GROWL", 0, 0, 18) } }),
          mn({ species = "Delta", level = 20, maxHp = 160, spe = 40, moves = { hm("tap", 20) } }) } },
        { playerId = "b2", mons = {
          mn({ species = "Eps", level = 21, maxHp = 160, spe = 45, moves = { hm("thump", 25), hm("tap", 15) } }),
          mn({ species = "Zeta", level = 20, maxHp = 160, spe = 35, moves = { hm("tap", 20) } }) } },
      },
    } }
  for key, value in pairs(k16("LASS AMY")) do o.sides.b[1][key] = value end
  for key, value in pairs(k16("LASS AMY")) do o.sides.b[2][key] = value end
  local rounds = {}
  for i = 1, 14 do
    local aim = (i % 2 == 0) and 3 or 4
    rounds[#rounds + 1] = A2(T(0, aim), T(0, 7 - aim))
  end
  return seq(events, o, rounds)
end)

-- `h2f_metronome_rampage`: a THRASH METRONOME called writes nothing on any of
-- its turns, so Bob's DISABLE, ENCORE and MIRROR MOVE find no move of Ann's
-- (LAST_COUNTER_MOVE, LAST_MOVE); once the rampage is over Ann's jab is hers
-- again -- MIRROR MOVE copies it and ENCORE holds it.
scenario("h2f_metronome_rampage", function(events)
  return seq(events, duo4("h2fr", "1v1", 1132,
    { mn({ species = "Alpha", maxHp = 900, spe = 90, moves = { hm("METRONOME", 0, 0, 83), hm("jab", 20) } }) },
    { mn({ species = "Beta", maxHp = 900, spe = 10,
           moves = { hm("MIRROR_MOVE", 0, 0, 9), hm("ENCORE", 0, 0, 139), hm("DISABLE", 0, 0, 86) } }) },
    { metronomePool = { hm("THRASH", 20, 0, 27) } }),
    { both3(F(0), F(2)), both3(F(0), F(1)), both3(F(0), F(0)), both3(F(1), F(0)), both3(F(1), F(1)),
      both3(F(1), F(0)) })
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
