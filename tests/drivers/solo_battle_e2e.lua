-- Committed e2e driver for **solo battles** (src/SoloBattle.lua): the mod's
-- own battle system substituted for the engine's on ordinary wild encounters
-- and trainers, with no hub, no partner and no socket anywhere.
--
-- One LOVE instance, no network. That is the whole point of the feature and
-- so it is the whole shape of this driver: everything the two-instance MMO
-- drivers need a peer for -- a referee, a partner, a wire -- solo does in
-- process, and the only thing worth proving out here is what the headless
-- suite structurally cannot see: a real overworld, a real engine BattleState
-- pushed onto a real stack, this mod's screen taking it over, and **the real
-- save afterwards**.
--
--   SHOT_DIR=/path/to/inspect \
--   POKEPORT_IDENTITY=soloe2e POKEPORT_TOUCH=0 \
--   POKEPORT_DRIVER=mods/rby_mmo/tests/drivers/solo_battle_e2e.lua \
--   love .
--
-- From the Gen1Recomp checkout root, with mods/rby_mmo -> RBYMMOMod. See
-- tests/drivers/run-solo-battle-e2e.sh for the wrapped, gated invocation on
-- both carts (it also writes the options.lua that enables the mod).
--
-- ------- what the legs prove, in order
--
--   1. **the row is real** -- the F10 mod manager's own row model carries
--      SOLO BATTLES and it reads OFF, so a player can find it and flip it.
--   2. **default OFF is honoured** -- with the row off, a staged wild
--      encounter is fought by the *engine's* battle. The mod is invisible.
--   3. **flipping it takes effect with no relaunch** -- the flip goes through
--      the manager row's own step(), which is what a keypress on that row
--      calls, and the next encounter diverts.
--   4. **a solo wild fight** diverts to this mod's screen, plays to a win, and
--      the save is right afterwards: exp gained, PP spent, the engine's own
--      battle told how it went and off the stack, overworld restored.
--   5. **a refused kind stays vanilla** -- Config.SOLO_REFUSED, spelled the
--      way each generation spells it (Gen 1 `ghost`, Gold's roaming
--      battleType byte), is fought by the engine with no word to the player.
--   6. **a solo trainer fight** diverts, plays to a win, and pays out: prize
--      money on the save, the engine's onFinish called with "win" (which is
--      the script's resume), and the player back in the overworld and walking.
--      The computer carries no bag on the referee (contract K16: the carts'
--      own AI spends the class's items -- Red's TrainerAI record, Gold's
--      TrainerClassAttributes -- which sit on its seat instead), and picking
--      a 0-PP move stays on the list instead of spending the turn.  Every
--      computer choice (move, item, switch, replacement) is the referee's
--      cart AI's now, so these legs assert the player's side and the outcome,
--      never which move the trainer picked.
--   7. **a real sighted trainer** (Gen 1; Gold's map objects carry no Gen 1
--      sight cone, so the leg skips there) walked into for real, so the
--      *defeated flag* is asserted against a live npcId rather than a staged
--      battle that never had one.
--   8. **a catch** in a solo wild fight adds the monster exactly once.
--   9. **the carts' rules against the computer** (docs/plans/gen12-referee-
--      fidelity.md): a traded monster's disobedience in the cart's lines and
--      the badge that lifts it, QUICK ATTACK's priority, and on Gold the held
--      items -- LEFTOVERS, a BERRY eaten, QUICK CLAW, the foe's THIEF, SMOKE
--      BALL -- each read off the referee's own events and the save after.
--      With them, the referee-gap legs (group "gaps", docs/plans/gen12-
--      referee-gaps-fix.md TT-E): PAY DAY's pot on the save (Red's TELEPORT
--      escape too, Gold's AMULET COIN), a Gold trainer's held item stolen,
--      SLEEP TALK, a level-up reaching the referee mid-fight, Gold's rain and
--      BATON PASS to a picked successor.  Every wild foe there knows exactly
--      one move, so the cart's own pick (pokered's random slot, pokecrystal
--      ParseEnemyAction's) can only be that move; the lines are matched as
--      the screen reads them (H.readBattleLine: the referee's `^a` / `^b`
--      marks rendered for side a, its rows joined -- contracts K17 / K18),
--      and a move's use is its clip *or* its "used" line, since a missed
--      move plays no clip on either cart (K22).
--
-- ------- what is local here, and why
--
-- `mmo_util.lua` is shared by every driver in this folder and several agents
-- are in it at once, so nothing below was added there. Each of these is either
-- solo-shaped or a thing the shared file gets wrong for a mediated screen:
--
--   * `bootToPlay` / `stackNames` -- thin wrappers now, nothing more. They
--     were real copies while the shared boot still went through the engine's
--     `U.newGame` and its 400-tap Gen 1 budget, short of the intro's ~441;
--     `H.newGame` fixed that upstream and `H.bootToPlay` routes through it, so
--     these just spare the call sites a `game` argument.
--   * `medOnStack` / `awaitCommandMenu` / `throwItem` -- a solo fight is a
--     `MediatedBattle`, which carries no `.sim`; every fight helper in
--     mmo_util keys on that field and would report a fight over before its
--     first turn opened.
--   * Trainer-kit and 0-PP probes *do* live in mmo_util (`assertTrainerKit`,
--     `assertZeroPpRefused`): the same two bugs show up on hub-refereed
--     2v2s, and a solo-only copy would not catch a doubled NPC bag.
--   * `stageRefusedWild` -- mmo_util's `stageWild` pushes the state itself and
--     the divert fires *inside* that push (StateStack:push emits screen.pushed
--     after enter()), so a refusal field stamped on the returned state would
--     always be one frame too late. This marks it before the push.
--   * `dropStaged` -- take a staged battle back off the stack by identity. The
--     legs that assert "the engine kept it" must not then fight it.
--   * `moneyOf` / `expOf` -- the two save fields spelled differently per
--     generation (`save.money` vs `save.player.money`, `mon.exp` vs
--     `mon.experience`). Mirrors src/Gen.lua's `money` accessor rather than
--     reaching into the mod, which is sandboxed away from a driver.

if os.getenv("MMO_SOUND") ~= "1" and love and love.audio then
  love.audio.setVolume(0)
end

-- Which legs a run drives, from SOLO_LEGS (a comma / space list; unset,
-- empty or "all" is every leg, which is what a default run does).  The names
-- are "singles" (the wild / trainer legs above the doubles on Gen 3, legs 1-8
-- on Red / Gold) and the lone-double legs, together as "double" or one by one:
-- double-arena, double-classic, double-ko, double-lastmon, double-refusal,
-- double-handback, double-real.  The badge-rule legs (docs/plans/gen3-badge-
-- rules.md) are the group "badge" (badge-boost, badge-guard, badge-trainer),
-- the group "obey" (obey-arena, obey-classic, obey-badge8, obey-outcomes,
-- obey-asleep) and the group "theft" (theft-wild), likewise whole or one by
-- one.  Red / Gold's rules legs (leg 9, `rulesLegs12`) are "obey"
-- (obey-traded, obey-capless, obey-asleep), "priority" (priority-quick) and
-- "held" (held-leftovers, held-berry, held-quickclaw, held-thief,
-- held-smokeball) and "gaps" (payday, trainer-item, sleep-talk, level-up,
-- weather, baton-pass); one list serves every cart, and a name a cart has no
-- leg for is not driven there.
-- A cart's run is minutes long, so iterating on one leg is worth a knob; it
-- never changes what an unset run does.
local SOLO_LEGS = (function()
  local raw = os.getenv("SOLO_LEGS")
  if raw == nil or raw == "" or raw:lower() == "all" then return nil end
  local on = {}
  for part in raw:gmatch("[^,%s]+") do on[part:lower()] = true end
  return on
end)()

local function legOn(name, group)
  if SOLO_LEGS == nil then return true end
  if SOLO_LEGS[name] then return true end
  return group ~= nil and SOLO_LEGS[group] == true
end

-- ==================================================================
-- Gen 3 (FireRed / LeafGreen / Emerald)
-- ==================================================================
--
-- A Game3 has no battle state on a stack to stage: its battles are modules
-- (battle_bridge -> battle/init.lua) and the mod takes a fight *before* the
-- cart starts one.  So this arm drives the two ways a Gen 3 solo fight
-- begins:
--
--   * the mod's own entries, `SoloBattle:fromGen3Encounter` /
--     `fromGen3Trainer`, reached on the live instance (the ctx behind the
--     exports) -- a wild fight won on the arena, the same on CLASSIC BATTLE
--     UI, a catch, RUN refused by the roll, a trainer beaten, a trainer lost
--     to (the whiteout);
--   * the real thing: walking in tall grass until the step encounter fires,
--     which src/Client.lua's `encounter.roll` divert hands to solo through
--     `fromGen3Encounter` -- first with SOLO BATTLES off (the cart's own
--     battle must run), then on;
--   * the endings the cart words its own way: PAY DAY's coins, a trainer
--     drawn (both last monsters down at once, and a draw the player is still
--     standing after), FireRed's rival under the name the player gave them,
--     and a trainer met on a rainy field;
--   * the lone trainer doubles (the legs under "Lone doubles" below): two
--     seats, two commands a turn, aiming, switching, the refill after a
--     knockout, both UIs, the hand-back, and the real flow through the
--     twins' script;
--   * the cart's badge rules against the computer (the legs under "Badge
--     rules" below): the x110/100 stat boosts a save's badges give -- with a
--     with / without pair of fights on one seed -- and a traded monster over
--     its badge level cap disobeying, in the cart's own words, on both UIs.
--
-- SOLO_LEGS (a comma list; default every leg) picks which run: "singles",
-- "double", "badge", "obey", or one leg by name -- see `legOn`.
--
-- Screenshots land in SHOT_DIR as g3-<game>-solo-NN-<leg>.png.
--
-- Legal: nothing below names a ROM value it asserts on.  Species and trainers
-- are looked up by pret name in the player's own cart, and every number read
-- back is the save's own.

local function runGen3(game, H, U, env)
  local log, check, skip = env.log, env.check, env.skip
  local VERSION = os.getenv("POKEPORT_VERSION") or "firered"
  local emerald = VERSION == "emerald"
  local tagGame = emerald and "em" or (VERSION == "leafgreen" and "lg" or "fr")
  local n = 0
  local function shot(leg)
    n = n + 1
    return U.shot(game, ("%s/g3-%s-solo-%02d-%s.png"):format(env.SHOT_DIR, tagGame, n, leg))
  end

  local Runtime = require("src.core.game3.runtime")
  local Trainers = require("src.core.game3.scripting.trainers")
  local BattleBridge = require("src.core.game3.battle_bridge")
  local Battle = require("src.core.game3.battle")
  local Encounters = require("src.core.game3.encounters")
  local Map = require("src.core.game3.map")
  local Player = require("src.core.game3.player")
  local Bag = require("src.core.game3.bag")

  local STARTER = emerald and "TORCHIC" or "CHARMANDER"
  local WILD = emerald and "ZIGZAGOON" or "PIDGEY"
  local GRASS_MAP = emerald and "EM_ROUTE101" or "FR_ROUTE_1"
  local Collision = require("src.core.game3.collision")
  local Objects = require("src.core.game3.objects")

  local booted = H.g3BootToPlay(game, { name = "SOLO" })
  if not check(booted, "booted a " .. VERSION .. " new game into the field") then return end
  local exports = H.requireMod(game, env.TAG)
  if not check(exports ~= nil, "rby_mmo is loaded on " .. VERSION) then return end
  local ctx = H.modCtx(game)
  local solo = ctx and ctx.solo
  if not check(type(solo) == "table" and type(solo.fromGen3Encounter) == "function",
               "the live SoloBattle instance, with its Gen 3 entries") then
    return
  end
  local function session() return Runtime.getSession() end

  local store = game.mods and game.mods.modOptions
  local function setOption(key, value)
    if not store then return end
    store[env.MOD_ID] = store[env.MOD_ID] or {}
    store[env.MOD_ID][key] = value
  end

  -- ------- reading the live fight

  local function fight() return solo.fight end
  local function layerId() return H.g3LayerId() end
  local function shown()
    local f = fight()
    return f and type(f.shown) == "string" and f.shown or ""
  end
  local function said(needle)
    local f = fight()
    for _, line in ipairs((f and f.lines) or {}) do
      if type(line) == "string" and line:find(needle, 1, true) then return true end
    end
    return shown():find(needle, 1, true) ~= nil
  end

  local function awaitChoose(seconds, what)
    return H.waitSeconds(game, function()
      local f = fight()
      return f ~= nil and f.phase == "choose"
    end, seconds or 60, what or "the Gen 3 command grid")
  end

  -- Answer whatever the cart or the mod has up between turns and after the
  -- fight, the way a player mashing through would: A on text, START then A on
  -- the naming grid (keep the species name), B out of a summary picker.
  local function nudge()
    local id = layerId()
    if id == "naming" then
      U.tap(game, "start"); U.wait(8); U.tap(game, "a"); U.wait(8)
      return
    end
    if id == "summary" or id == "summary_menu" then U.tap(game, "b"); U.wait(6) return end
    U.tap(game, "a")
    U.wait(4)
  end

  -- The strongest damaging move on our side, as a cursor index.
  local function bestMove(f)
    local mine = f.mine and f.mine[f.active or 1]
    local best, power = 1, -1
    for i, mv in ipairs((mine and mine.moves) or {}) do
      if (tonumber(mv.power) or 0) > power and (tonumber(mv.pp) or 0) > 0 then
        best, power = i, tonumber(mv.power) or 0
      end
    end
    return best
  end

  -- FIGHT, then the move at `index`.
  local function fightWith(index, onMoveMenu)
    local f = fight()
    if not (f and f.phase == "choose") then return false end
    f.commandIndex = 1
    U.tap(game, "a"); U.wait(8)
    f = fight()
    if not (f and f.phase == "move") then return false end
    if onMoveMenu then onMoveMenu() end
    local moves = (f.mine and f.mine[f.active or 1] and f.mine[f.active or 1].moves) or {}
    local steps = ((index or 1) - (f.cursor or 1)) % math.max(1, #moves)
    for _ = 1, steps do U.tap(game, "down"); U.wait(4) end
    U.tap(game, "a"); U.wait(6)
    return true
  end

  -- The command at `name` (FIGHT / ITEM / SWITCH / RUN), in whichever grid
  -- this screen lays out, by setting the cursor the way the arrows would.
  local function command(name)
    local f = fight()
    if not (f and f.phase == "choose") then return false end
    local list = f:commandList()
    for i, c in ipairs(list) do
      if c == name then f.commandIndex = i end
    end
    U.tap(game, "a"); U.wait(8)
    return true
  end

  -- Mash the fight to its end: `onChoose(f)` answers each command menu.
  local function driveToEnd(onChoose, seconds)
    return H.waitSeconds(game, function()
      local f = fight()
      if not f then return true end
      if f.phase == "choose" then
        onChoose(f)
      else
        nudge()
      end
      return fight() == nil
    end, seconds or 240, "the Gen 3 solo fight to end")
  end

  -- Back to a field nobody is standing in front of.
  -- Idle, and no script still running: FireRed's whiteout carries on in a
  -- script at the heal location (its own fade to black and back), and a
  -- teleport out of the middle of that leaves the screen faded to black.
  local function settle()
    return H.waitSeconds(game, function()
      if H.g3Idle(game) and not Battle.isActive() and not H.g3ScriptRunning() then return true end
      nudge()
      return false
    end, 60, "the field after the fight")
  end

  local function party() return session().party end
  local function lead() return party()[1] end
  local function ppSum(mon)
    local total = 0
    for _, v in ipairs((mon and mon.pp) or {}) do total = total + (tonumber(v) or 0) end
    return total
  end
  local function seed(species, level)
    local mon = H.g3SeedParty(game, species, level)
    if mon then mon.hp = mon.maxHp; mon.status = nil end
    return mon
  end

  local function wildOf(name, level)
    return { species = H.g3Species(game, name), level = level }
  end

  -- ------------------------------------------------------------------
  -- Lone doubles (docs/plans/gen3-solo-doubles.md)
  -- ------------------------------------------------------------------
  --
  -- SOLO BATTLES fights a *lone* trainer double -- one trainer, one party, one
  -- AI, one defeat flag, two monsters a side -- on the mod's referee, with
  -- CoopBattle's solo-double screen (`newSoloDouble`: `ownSlots`, a chooser,
  -- buffered commands) in both UIs.  What this proves is what the headless
  -- suites cannot see: the screen's real menus under real key presses, the
  -- arena and the GBA double page actually drawn, and -- on the real flow --
  -- the trainer's script resuming off the fight's result.
  --
  --   double-arena     the picked double, on the arena: both seats out, the
  --                    intro lines; mon 1's command, mon 2's, B back to mon
  --                    1, a re-pick; aiming at each foe (the picker lists the
  --                    partner too); a switch to a bench monster; to the win:
  --                    prize x2, every participant's EXP, a clean referee
  --   double-classic   the same on CLASSIC BATTLE UI: the GBA double page's
  --                    model, the command and move menus, the target blink,
  --                    START's HP figures
  --   double-ko        one of ours faints; the replacement picker comes up for
  --                    that seat, and its bench leaves out the monster the
  --                    other seat has out
  --   double-lastmon   the last bench monster is gone: one seat is refilled,
  --                    not two, and the fight is fought on by one
  --   double-refusal   a command the referee turns down (a Disabled move): the
--                    cart's line, the seat's menu kept, nothing filed, the
--                    other seat not asked until another move goes through
--   double-handback  fewer than two usable monsters: SOLO does not take it
  --   double-real      Route 8 / Route 104's twins, met the cart's way: the
  --                    sight approach, the script, the fight, the script's
  --                    resume (flag, prize); and with one monster, the cart's
  --                    own refusal in its own words
  --
  -- Which double is picked by scanning the cart's own book (a named, non-
  -- LEADER double with a party of two, the lowest last level); the stage the
  -- real flow walks into is the one the picked trainer is staged on, and the
  -- leg skips when it is not.
  local DOUBLE_STAGE = {
    firered = { map = "FR_ROUTE_8", lid = 12 },
    leafgreen = { map = "FR_ROUTE_8", lid = 12 },
    emerald = { map = "EM_ROUTE104", lid = 23 },
  }

  local function doubleLegs()
    local legs = { "double-arena", "double-classic", "double-ko", "double-lastmon",
                   "double-refusal", "double-handback", "double-real" }
    local any = false
    for _, name in ipairs(legs) do
      if legOn(name, "double") then any = true end
    end
    if not any then return end

    local Moves = require("src.core.game3.battle.moves")
    local Prize = require("src.core.game3.battle.prize")
    local Natives = require("src.core.game3.scripting.natives")
    local OUTCOME = Natives.B_OUTCOME or {}

    -- ------- the double: the lowest-level named, non-LEADER lone double
    local doubleId, doubleLast
    do
      local pack = Trainers.pack() or {}
      for id, row in pairs(pack.trainers or {}) do
        local tid = tonumber(id)
        local p = type(row) == "table" and row.party or nil
        local named = type(row) == "table" and type(row.name) == "string" and row.name ~= ""
        local class = type(row) == "table" and tonumber(row.class) or 0
        local className = tostring((type(row) == "table" and row.className)
          or (pack.classNames and pack.classNames[class]) or ""):upper()
        if tid and tid > 0 and named and row.doubleBattle and type(p) == "table" and #p == 2
            and not className:find("LEADER", 1, true) then
          local last = tonumber(p[#p].level) or 999
          if doubleLast == nil or last < doubleLast or (last == doubleLast and tid < doubleId) then
            doubleId, doubleLast = tid, last
          end
        end
      end
      log(("double: picked trainer %s (last level %s)"):format(tostring(doubleId), tostring(doubleLast)))
    end
    if not doubleId then
      skip("the lone-double legs", "no named lone double with a party of two in this cart's book")
      return
    end

    -- What the cart pays for this trainer, once and as a double: FireRed /
    -- LeafGreen 4 x last level x class value, Emerald's money table -- the
    -- engine's own Prize formulas, which is where the mod reads them from.
    local function prizeOf(double)
      local fn = emerald and Prize.calcRse or Prize.calc
      local ok, amount = pcall(fn, doubleId, { double = double })
      return ok and tonumber(amount) or nil
    end

    local function moveId(name) return H.g3Const(game, "moves", name) end
    local pound, growl = moveId("MOVE_POUND"), moveId("MOVE_GROWL")

    local STRONG = "PIKACHU"
    local WEAK = emerald and "WURMPLE" or "CATERPIE"

    -- One lead that knows only `move`, full PP.
    local function pinMove(mon, move)
      local okP, row = pcall(Moves.get, move)
      local pp = (okP and type(row) == "table" and tonumber(row.pp)) or 10
      mon.moves, mon.pp, mon.maxPp = { move }, { pp }, { pp }
    end

    -- `move` in front of a monster's own moves (the strongest of them behind
    -- it, which the seeding put first).
    local function putFirst(mon, move)
      local okP, row = pcall(Moves.get, move)
      local pp = (okP and type(row) == "table" and tonumber(row.pp)) or 10
      table.insert(mon.moves, 1, move)
      table.insert(mon.pp, 1, pp)
      table.insert(mon.maxPp, 1, pp)
      while #mon.moves > 4 do
        table.remove(mon.moves)
        table.remove(mon.pp)
        table.remove(mon.maxPp)
      end
    end

    -- The party the fight is fought with: `{ species = , level = , move = ,
    -- first = , hp = }` rows, in order -- seat 1 takes the first, seat 2 the
    -- second, the rest are the bench.  Healthy (or at `hp`), a damaging move
    -- first unless `move` pins the only one, or `first` puts one in front.
    local function seedTeam(specs)
      local team = {}
      for i, spec in ipairs(specs) do
        local mon
        if i == 1 then
          mon = H.g3SeedParty(game, spec.species, spec.level)
        else
          mon = H.g3GiveMon(game, spec.species, spec.level)
        end
        if mon then
          if spec.move then pinMove(mon, spec.move) else H.g3FrontloadDamage(mon) end
          if spec.first then putFirst(mon, spec.first) end
          mon.hp = spec.hp or mon.maxHp
          mon.status = nil
        end
        team[i] = mon
      end
      return team
    end

    -- Each party monster's EXP, by party slot (read live: a fight writes the
    -- save's monsters, not the tables the seeding handed back).
    local function expsOf()
      local out = {}
      for i, mon in ipairs(party()) do out[i] = tonumber(mon and mon.exp) or 0 end
      return out
    end

    -- Put the cart's own battle (a refused double it ran itself) away without
    -- fighting it; this driver is not here to test the engine's battle.
    local function endCartBattle()
      pcall(BattleBridge.finishPending, "run")
      H.waitSeconds(game, function() return not Battle.isActive() end, 20, "the cart's battle to end")
      settle()
    end

    -- ------- reading the screen

    -- The line on the box, on one line.
    local function lineNow()
      local f = fight()
      local s = f and f.shown
      if type(s) == "table" then s = table.concat(s, " ") end
      if type(s) ~= "string" then return "" end
      return (s:gsub("%s*\n%s*", " "))
    end

    local function foeSlotsOf(f)
      local out = {}
      for _, s in ipairs((f.sim and f.sim.slots) or {}) do
        if f:foeSide(s.index) then out[#out + 1] = s.index end
      end
      return out
    end

    local function copyList(list)
      local out = {}
      for i, v in ipairs(list or {}) do out[i] = v end
      return out
    end

    local function indexSet(bench)
      local out = {}
      for _, entry in ipairs(bench or {}) do out[#out + 1] = entry.index end
      table.sort(out)
      return table.concat(out, ",")
    end

    -- The strongest damaging move, one aimed at a chosen battler first (a
    -- spread move asks nobody); a status move last.
    local function bestMove(moves, skip)
      local best, bestScore = 1, -1
      for i, mv in ipairs(moves or {}) do
        if (tonumber(mv.pp) or 0) > 0 and not (skip and skip[i]) then
          local power = tonumber(mv.power) or 0
          local score = (power > 0) and (power + ((tonumber(mv.target) or 0) == 0 and 1000 or 0)) or 0
          if score > bestScore then best, bestScore = i, score end
        end
      end
      return best
    end

    -- ------- the pilot
    --
    -- Plays a solo double with the real keys, a seat at a time: every command
    -- is FIGHT / SWITCH / B on the screen's own menus, the cursors walked with
    -- the d-pad.  `opts.plan(c)` answers each command menu (`c` = { f, turn,
    -- pos (the chooser, 1 or 2), visit (the n-th time this seat's menu has
    -- opened this turn) }) with { kind = "fight", move = i | fn, target =
    -- slot | fn } / { kind = "switch", pick = fn } / { kind = "back" }; the
    -- default is the strongest move at the first foe standing.  Hooks:
    -- onMenu(c), onMove(c, f, moves, want), onTarget(c, f, targets),
    -- onAimed(c, f, entry), onBack(c, before, after), onSwitchList(c, f,
    -- bench), onReplace(rec, f, bench), replacePick(bench) -> row.
    local function fightDouble(opts)
      opts = opts or {}
      local tag = opts.tag or "double"
      local rep = {
        said = {}, filed = {}, aimed = {}, replaces = {}, switches = {}, backs = {},
        turns = 0, medGaps = 0, ended = false, stuck = 0,
      }
      local visits, shotDone = {}, {}
      local lastTurnNumber = nil
      -- A command the referee will not take (a move the foe Disabled, a
      -- Taunt, Torment, no PP) reopens that seat's menu with the turn
      -- unspent; the pilot then tries another move, as a player would.
      local lastMove, skipMoves, backed = {}, {}, {}
      rep.refusals = 0
      rep.commits = {}
      local inMenu = false

      -- The referee's held choice for one of our seats (a command is filed
      -- with it the moment it is chosen; B takes it back through its `cancel`).
      local function refereeChoiceOf(pos)
        local sim = solo.sim
        local ft = sim and sim.byId and sim.byId[(pos == 1) and "solo_player" or "solo_player#2"]
        return ft and ft.choice or nil
      end

      -- What a command did on the screen once it was chosen: filed with the
      -- referee (the menu moves on), or turned down (the cart's line, and the
      -- seat's menu kept open).
      local function noteCommit(c)
        local g = fight()
        if not g then return end
        local rec = { turn = c.turn, pos = c.pos, visit = c.visit, phase = g.phase,
                      chooser = g.chooser, referee = refereeChoiceOf(c.pos) ~= nil }
        if g.phase == "messages" then
          for _ = 1, 24 do
            if lineNow() ~= "" then break end
            U.wait(1)
          end
          rec.line = lineNow()
        end
        rep.commits[#rep.commits + 1] = rec
        if opts.onCommit then opts.onCommit(c, rec) end
      end
      local deadline = os.time() + (opts.seconds or 240)

      local function shotOnce(key, frames)
        if shotDone[key] or opts.noAutoShots then return end
        shotDone[key] = true
        U.wait(frames or 4)
        shot(tag .. "-" .. key)
      end

      local function pressA(frames)
        U.tap(game, "a")
        U.wait(frames or 8)
      end

      local function noteFiled(c, kind, extra)
        local t = rep.filed[c.turn] or {}
        rep.filed[c.turn] = t
        local row = extra or {}
        row.kind = kind
        t[c.pos] = row
        if os.getenv("SOLO_DEBUG") == "1" then
          log(("%s: turn %d mon %d %s move=%s target=%s index=%s"):format(
            tag, c.turn, c.pos, kind, tostring(row.move), tostring(row.target), tostring(row.index)))
        end
      end

      local function pickCommand(f, name)
        for i, cmd in ipairs(f:commandList()) do
          if cmd == name then f.commandIndex = i end
        end
        pressA(8)
      end

      -- The target picker: walk the cursor onto the foe asked for with the
      -- d-pad (the arena walks its field, the GBA page its ring).
      local function aim(c, act)
        local f = fight()
        local targets = f:targetChoices()
        c.targets = targets
        if opts.onTarget then opts.onTarget(c, f, targets) end
        local want = act.target
        if type(want) == "function" then want = want(targets, f) end
        local at
        for i, e in ipairs(targets) do
          if e.index == want then at = i end
        end
        if not at then
          for i, e in ipairs(targets) do
            if f:foeSide(e.index) then at = i break end
          end
        end
        at = at or 1
        local reached = f.targetIndex == at
        for _, key in ipairs({ "right", "left", "down", "up" }) do
          if reached then break end
          for _ = 1, #targets do
            if f.targetIndex == at then reached = true break end
            U.tap(game, key)
            U.wait(4)
          end
          reached = reached or f.targetIndex == at
        end
        if not reached then
          check(false, tag .. ": the d-pad walks the aim onto the foe asked for",
                ("want entry %d of %d, cursor on %s"):format(at, #targets, tostring(f.targetIndex)))
          f.targetIndex = at
        end
        if opts.onAimed then opts.onAimed(c, f, targets[at]) end
        local slotIdx = targets[at] and targets[at].index
        pressA(8)
        f = fight()
        if f and f.phase == "target" then pressA(8) end
        rep.aimed[slotIdx or 0] = (rep.aimed[slotIdx or 0] or 0) + 1
        noteFiled(c, "fight", { move = c.move, target = slotIdx })
        noteCommit(c)
      end

      local function doBack(c)
        local f = c.f
        local own = f.ownSlots
        local filed = f.filed and f.filed[own[1]]
        local before = {
          chooser = f.chooser, filed = filed ~= nil,
          target = filed and filed.action and filed.action.target,
          command = filed and filed.command,
          referee = refereeChoiceOf(1) ~= nil,
        }
        U.tap(game, "b")
        U.wait(8)
        local g = fight()
        local after = {}
        if g then
          after = {
            chooser = g.chooser, mine = g.mine, phase = g.phase,
            filed = (g.filed and g.filed[own[1]]) ~= nil,
            referee = refereeChoiceOf(1) ~= nil,
            commandIndex = g.commandIndex,
          }
        end
        rep.backs[#rep.backs + 1] = { before = before, after = after, turn = c.turn }
        backed[c.turn] = true
        local t = rep.filed[c.turn]
        if t then t[1] = nil end
        if opts.onBack then opts.onBack(c, before, after) end
      end

      local function doSwitch(c, act)
        local f = c.f
        pickCommand(f, "SWITCH")
        f = fight()
        if not (f and f.phase == "switch") then
          rep.stuck = rep.stuck + 1
          log(tag .. ": SWITCH did not open the party list", f and f.phase)
          return
        end
        local bench = f:benchOf(f:mySlot())
        if opts.onSwitchList then opts.onSwitchList(c, f, bench) end
        local at = (act.pick and act.pick(bench)) or 1
        for _ = 1, at - 1 do
          U.tap(game, "down")
          U.wait(4)
        end
        local pick = bench[fight().switchIndex or 1]
        pressA(8)
        f = fight()
        if f and f.phase == "switch" then pressA(8) end
        rep.switches[#rep.switches + 1] = { turn = c.turn, pos = c.pos, index = pick and pick.index, bench = #bench }
        noteFiled(c, "switch", { index = pick and pick.index })
      end

      local function doFight(c, act)
        local f = c.f
        pickCommand(f, "FIGHT")
        f = fight()
        if not (f and f.phase == "move") then
          rep.stuck = rep.stuck + 1
          log(tag .. ": FIGHT did not open the move menu", f and f.phase)
          return
        end
        local moves = f:liveMoves()
        local want = act.move
        if type(want) == "function" then want = want(moves, f) end
        local seatKey = c.turn .. ":" .. c.pos
        local skip = skipMoves[seatKey]
        -- a move the referee already turned down this turn is not asked again
        if want == nil or (skip and skip[want]) then want = bestMove(moves, skip) end
        lastMove[seatKey] = want
        for _ = 1, #moves + 1 do
          if f.moveIndex == want then break end
          U.tap(game, "down")
          U.wait(4)
        end
        c.move = want
        if opts.onMove then opts.onMove(c, f, moves, want) end
        pressA(8)
        f = fight()
        if f and f.phase == "target" then
          aim(c, act)
        else
          noteFiled(c, "fight", { move = want })
          noteCommit(c)
        end
      end

      -- Why would the referee refuse this seat's last move?  Its own limits.
      local function limitsOf(pos)
        local sim = solo.sim
        local ft = sim and sim.byId and sim.byId[(pos == 1) and "solo_player" or "solo_player#2"]
        local b = ft and ft.b
        if not b then return "no battler" end
        local nums = {}
        for i, mv in ipairs(b.moves or {}) do nums[i] = tostring(mv.num) .. ":pp" .. tostring(mv.pp) end
        return ("disabled=%s tormented=%s taunt=%s encore=%s choiced=%s moves=%s"):format(
          tostring(b.disabledNum), tostring(b.tormented), tostring(b.tauntTurns),
          tostring(b.encoreTurns), tostring(b.choicedMove), table.concat(nums, " "))
      end

      local function handleCommand(c)
        local seatKey = c.turn .. ":" .. c.pos
        if c.visit >= 2 and not backed[c.turn] and lastMove[seatKey] then
          rep.refusals = rep.refusals + 1
          skipMoves[seatKey] = skipMoves[seatKey] or {}
          skipMoves[seatKey][lastMove[seatKey]] = true
          local n = 0
          for _ in pairs(skipMoves[seatKey]) do n = n + 1 end
          if n >= #c.f:liveMoves() then skipMoves[seatKey] = nil end
          if rep.refusals <= 3 then
            log(("%s: the referee did not take seat %d's move %d on turn %d (%s); trying another"):format(
              tag, c.pos, lastMove[seatKey], c.turn, limitsOf(c.pos)))
          end
        end
        if opts.onMenu then opts.onMenu(c) end
        local act = (opts.plan and opts.plan(c)) or { kind = "fight" }
        if act.kind == "back" then return doBack(c) end
        if act.kind == "switch" then return doSwitch(c, act) end
        return doFight(c, act)
      end

      local function handleReplace(f)
        local bench = f:benchOf(f:mySlot())
        local rec = { seat = f.mine, bench = bench, queue = copyList(f.replaceQueue), turn = rep.turns }
        rep.replaces[#rep.replaces + 1] = rec
        rec.n = #rep.replaces
        if opts.onReplace then opts.onReplace(rec, f, bench) end
        local at = (opts.replacePick and opts.replacePick(bench, rec)) or 1
        for _ = 1, at - 1 do
          U.tap(game, "down")
          U.wait(4)
        end
        local row = bench[fight().switchIndex or 1]
        rec.picked = row and row.index
        pressA(8)
      end

      -- where the screen was left, for whoever reads the log
      local function dumpStuck(why)
        local f = fight()
        if not f then return end
        log(("%s: %s at phase=%s chooser=%s mine=%s replacing=%s result=%s turn=%d queued=%d line=[%s]"):format(
          tag, why, tostring(f.phase), tostring(f.chooser), tostring(f.mine), tostring(f.replacing),
          tostring(f.result), rep.turns, #(f.messages or {}), lineNow()))
        for _, slot in ipairs((f.sim and f.sim.slots) or {}) do
          local mon = slot.party and slot.party[slot.active or 0]
          log(("%s:   slot %s side %s active %s hp %s/%s status %s"):format(tag, tostring(slot.index),
            tostring(slot.side), tostring(slot.active), tostring(mon and mon.hp), tostring(mon and mon.maxHp),
            tostring(mon and mon.status)))
        end
        -- ...and the referee's own view of the seats
        local sim = solo.sim
        if sim and sim.fighters then
          log(("%s:   referee phase=%s turn=%s"):format(tag, tostring(sim.phase), tostring(sim.turn)))
          for _, ft in ipairs(sim.fighters) do
            local owes
            if type(sim._owes) == "function" then
              local okO, v = pcall(sim._owes, sim, ft)
              owes = okO and v or "?"
            end
            log(("%s:   seat %s slot=%s side=%s connected=%s choice=%s mustReplace=%s active=%s owes=%s"):format(
              tag, tostring(ft.playerId), tostring(ft.slot), tostring(ft.side), tostring(ft.connected),
              tostring(ft.choice and ft.choice.action), tostring(ft.mustReplace), tostring(ft.active),
              tostring(owes)))
            local b = ft.b
            if b then
              local pps = {}
              for i, mv in ipairs(b.moves or {}) do pps[i] = tostring(mv.num) .. ":" .. tostring(mv.pp) end
              log(("%s:     disabledNum=%s tormented=%s taunt=%s encore=%s choiced=%s moves=%s"):format(
                tag, tostring(b.disabledNum), tostring(b.tormented), tostring(b.tauntTurns),
                tostring(b.encoreTurns), tostring(b.choicedMove), table.concat(pps, " ")))
            end
          end
        end
      end

      -- A turn never takes minutes: a screen that has said and asked nothing
      -- new for this long is wedged, and says so rather than waiting out the
      -- whole budget.
      local STALL_SECONDS = 100
      local lastKey, lastChange = nil, os.time()
      -- ...and one that never gets through a turn, whatever the screen is
      -- doing meanwhile (a menu that keeps coming back, say)
      local TURN_SECONDS = 150
      local seenTurn, turnSince = nil, os.time()

      while os.time() < deadline do
        local f = fight()
        if not f then
          rep.ended = true
          return rep
        end
        local text = lineNow()
        local key = table.concat({ tostring(f.phase), tostring(f.chooser), tostring(f.replacing),
          tostring(f.result), text, tostring(#(f.messages or {})) }, "|")
        if key ~= lastKey then
          lastKey, lastChange = key, os.time()
        elseif os.time() - lastChange > STALL_SECONDS then
          U.log(("TIMEOUT: the %s stood still for %ds"):format(tag, STALL_SECONDS))
          dumpStuck("stalled")
          return rep
        end
        local turnNow = solo.sim and tonumber(solo.sim.turn)
        if turnNow ~= seenTurn or f.replacing then
          seenTurn, turnSince = turnNow, os.time()
        elseif os.time() - turnSince > TURN_SECONDS then
          U.log(("TIMEOUT: the %s never got past turn %s in %ds"):format(tag, tostring(turnNow), TURN_SECONDS))
          dumpStuck("stuck in one turn")
          return rep
        end
        if text ~= "" and rep.said[#rep.said] ~= text then rep.said[#rep.said + 1] = text end
        rep.medGaps = math.max(rep.medGaps, tonumber(f.medGaps) or 0)
        local low = text:lower()
        if low:find("would like to battle", 1, true) then shotOnce("intro", 6) end
        if low:find("go!", 1, true) and low:find(" and ", 1, true) then shotOnce("sendout", 6) end
        if low:find("fainted", 1, true) then shotOnce("ko", 4) end
        if low:find("defeated", 1, true) and f.result == "win" then shotOnce("win", 4) end
        if low:find("for winning", 1, true) or low:find("\194\165", 1, true) then shotOnce("prize", 4) end

        if f.phase ~= "choose" then inMenu = false end
        if f.replacing and f.phase ~= "messages" then
          handleReplace(f)
        elseif f.phase == "choose" and not f.result and not f.replacing then
          -- A turn is the referee's: a refused command leaves the menu for a
          -- line and comes back to it, which is the same turn.
          local number = solo.sim and tonumber(solo.sim.turn)
          if number ~= nil then
            if number ~= lastTurnNumber then
              lastTurnNumber = number
              rep.turns = rep.turns + 1
            end
          elseif not inMenu then
            rep.turns = rep.turns + 1
          end
          inMenu = true
          local pos = f.chooser or 1
          local key = rep.turns .. ":" .. pos
          visits[key] = (visits[key] or 0) + 1
          handleCommand({ f = f, turn = rep.turns, pos = pos, visit = visits[key], rep = rep })
        elseif f.phase == "move" or f.phase == "target" or f.phase == "switch" then
          -- a menu left open by a refusal: back out of it
          U.tap(game, "b")
          U.wait(6)
        else
          nudge()
        end
        U.wait(2)
      end
      U.log(("TIMEOUT waiting %ds for the %s to end"):format(opts.seconds or 240, tag))
      dumpStuck("out of time")
      return rep
    end

    local function sawLine(rep, ...)
      for _, line in ipairs(rep.said) do
        local low = line:lower()
        local all = true
        for i = 1, select("#", ...) do
          if not low:find((select(i, ...)):lower(), 1, true) then all = false end
        end
        if all then return line end
      end
      return nil
    end

    local function money() return tonumber(session().money) or 0 end

    -- A shot, and the file it landed in (`shot` numbers them as it goes).
    local function shotFile(leg)
      shot(leg)
      return ("%s/g3-%s-solo-%02d-%s.png"):format(env.SHOT_DIR, tagGame, n, leg)
    end

    local function readFile(path)
      local handle = io.open(path, "rb")
      if not handle then return nil end
      local bytes = handle:read("*a")
      handle:close()
      return bytes
    end

    -- SoloBattle's stuck-seat backstop (`_backstop3`, three seconds) answers
    -- for a seat the screen stopped asking about, and says so once through
    -- `warned`.  A real fight must never come near it.
    local backstopReported = false
    local function backstopQuiet(leg)
      local warned = solo.warned or {}
      if warned.reopen3 or warned.autopick3 then
        if not backstopReported then
          backstopReported = true
          check(false, leg .. ": the stuck-seat backstop never fires in a real fight",
                warned.reopen3 and "it asked a seat again" or "it picked for a seat")
        end
      else
        check(true, leg .. ": the stuck-seat backstop never fired")
      end
    end

    -- ------------------------------------------------------------------
    -- the arena: two commands a turn, B back, aiming, a switch, the win
    -- ------------------------------------------------------------------
    if legOn("double-arena", "double") then
      settle()
      setOption(env.OPTION_KEY, true)
      setOption("classicui", false)
      local team = seedTeam({
        { species = STARTER, level = 40 }, { species = STRONG, level = 40 },
        { species = WILD, level = 30 },
      })
      check(#party() == 3 and team[1] and team[2] and team[3], "double: a team of three was seeded")
      session().money = 3000
      local moneyBefore, expBefore = money(), expsOf()
      local result
      local took = solo:fromGen3Trainer(game, doubleId,
        { trainerId = doubleId, done = function(r) result = r end })
      check(took, "double: SOLO takes the lone double " .. tostring(doubleId))
      local f0 = fight()
      check(took and f0 ~= nil and f0.soloDouble == true, "double: it is the solo-double screen")
      if took and f0 then
        check(f0.classicUi ~= true and f0:usesBattlefield(), "double: on the arena, not the GBA page")
        check(type(f0.ownSlots) == "table" and #f0.ownSlots == 2, "double: both side-a seats are ours")
        local foes = foeSlotsOf(f0)
        local foeA, foeB = foes[1], foes[2]
        check(foeA ~= nil and foeB ~= nil, "double: two foe seats")
        local sawTargets, switchOk = false, nil
        local rep = fightDouble({
          tag = "double",
          plan = function(c)
            if c.turn == 1 and c.pos == 1 then
              -- the first pick is aimed at the second foe and taken back; the
              -- re-pick at the first is what goes out
              return { kind = "fight", target = (c.visit == 1) and foeB or foeA }
            elseif c.turn == 1 and c.pos == 2 then
              if c.visit == 1 then return { kind = "back" } end
              return { kind = "switch" }
            elseif c.pos == 1 then
              return { kind = "fight", target = foeB }
            end
            return { kind = "fight", target = foeA }
          end,
          onMenu = function(c)
            local f = c.f
            if c.turn == 1 and c.pos == 1 and c.visit == 1 then
              local own = f.ownSlots
              local s1, s2 = f.sim:slot(own[1]), f.sim:slot(own[2])
              check(s1 and s1.battler and s2 and s2.battler, "double: both our seats have a monster out")
              local a, b = f.sim:slot(foeA), f.sim:slot(foeB)
              check(a and a.battler and b and b.battler, "double: both foe seats have a monster out")
              check(f.chooser == 1 and f.mine == own[1], "double: mon 1's command menu opens first")
              shot("double-cmd1")
            elseif c.turn == 1 and c.pos == 2 and c.visit == 1 then
              check(f.chooser == 2 and f.mine == f.ownSlots[2], "double: mon 2's command menu follows")
              check(f.filed and f.filed[f.ownSlots[1]] ~= nil and solo.sim.byId["solo_player"].choice ~= nil,
                    "double: mon 1's command is already filed with the referee")
              check(solo.sim.byId["solo_player#2"].choice == nil, "double: ...and mon 2's is still to come")
              shot("double-cmd2")
            end
          end,
          onBack = function(c, before, after)
            check(before.filed and before.referee and before.chooser == 2 and before.target == foeB,
                  "double: mon 1's pick (the second foe) was filed, and there to take back",
                  ("filed=%s referee=%s chooser=%s target=%s"):format(tostring(before.filed),
                    tostring(before.referee), tostring(before.chooser), tostring(before.target)))
            check(after.chooser == 1 and after.phase == "choose" and not after.filed and not after.referee,
                  "double: B on mon 2's menu hands back mon 1's menu, and the referee no longer holds mon 1's choice",
                  ("chooser=%s phase=%s filed=%s referee=%s"):format(tostring(after.chooser),
                    tostring(after.phase), tostring(after.filed), tostring(after.referee)))
            check(after.commandIndex == before.command,
                  "double: mon 1's menu reopens on the command it had chosen",
                  ("%s vs %s"):format(tostring(after.commandIndex), tostring(before.command)))
            shot("double-back")
          end,
          onTarget = function(c, f, targets)
            if sawTargets then return end
            sawTargets = true
            local foesListed, allies = 0, 0
            for _, e in ipairs(targets) do
              if f:foeSide(e.index) then foesListed = foesListed + 1
              elseif e.index ~= f.mine then allies = allies + 1 end
            end
            check(foesListed == 2 and allies == 1 and #targets == 3,
                  "double: the target picker lists both foes and the partner",
                  ("%d foes, %d partner, %d entries"):format(foesListed, allies, #targets))
            U.wait(10)
            shot("double-target")
          end,
          onSwitchList = function(c, f, bench)
            local own = f.ownSlots
            local mine, other = f.sim:slot(own[2]), f.sim:slot(own[1])
            local clean = #bench == 1
            for _, entry in ipairs(bench) do
              if entry.index == mine.active or entry.index == other.active then clean = false end
            end
            switchOk = clean
            check(clean, "double: the bench leaves out both monsters on the field",
                  ("bench %s; out %s and %s"):format(indexSet(bench), tostring(mine.active), tostring(other.active)))
            shot("double-switch")
          end,
          seconds = 300,
        })
        check(rep.ended, "double: the fight ended")
        check(#rep.backs == 1, "double: one B-back was played", tostring(#rep.backs))
        check(switchOk ~= nil and #rep.switches == 1, "double: the switch to the bench monster was played")
        -- what was filed, not what was tried: the first pick (taken back) does
        -- not count
        local filedAt = {}
        for _, turn in pairs(rep.filed) do
          for _, row in pairs(turn) do
            if row.target then filedAt[row.target] = (filedAt[row.target] or 0) + 1 end
          end
        end
        check(filedAt[foeA] ~= nil and filedAt[foeB] ~= nil,
              "double: both foes were aimed at, and the aim was sent",
              ("%s/%s"):format(tostring(filedAt[foeA]), tostring(filedAt[foeB])))
        local t1 = rep.filed[1] or {}
        check(t1[1] and t1[1].target == foeA and t1[2] and t1[2].kind == "switch",
              "double: turn 1 filed the re-pick at the first foe, and the switch",
              ("%s / %s"):format(tostring(t1[1] and t1[1].target), tostring(t1[2] and t1[2].kind)))
        check(rep.stuck == 0, "double: no menu refused a command it was given", tostring(rep.stuck))
        check(sawLine(rep, "would like to battle") ~= nil, "double: the trainer's intro line was said")
        check(sawLine(rep, "sent out", " and ") ~= nil, "double: 'the trainer sent out X and Y!' was said")
        check(sawLine(rep, "go!", " and ") ~= nil, "double: 'Go! X and Y!' was said")
        check(sawLine(rep, "fainted") ~= nil, "double: a knockout was said")
        check(result == "win", "double: done('win')", tostring(result))
        local once, twice = prizeOf(false), prizeOf(true)
        local gained = money() - moneyBefore
        check(once ~= nil and twice ~= nil and twice == 2 * once and gained == twice,
              "double: the prize is the cart's double prize (x2 the single's)",
              ("paid %d; single %s, double %s"):format(gained, tostring(once), tostring(twice)))
        local now = party()
        for i = 1, 3 do
          check(now[i] and (tonumber(now[i].exp) or 0) > expBefore[i],
                ("double: monster %d took part and gained EXP"):format(i),
                ("%d -> %d"):format(expBefore[i], tonumber(now[i] and now[i].exp) or -1))
        end
        check(rep.medGaps == 0, "double: the referee's events arrived in order", tostring(rep.medGaps))
        backstopQuiet("double")
        check(OUTCOME.WON ~= nil and session().battleOutcome == OUTCOME.WON,
              "double: the save's outcome is a win", tostring(session().battleOutcome))
        settle()
        check(H.g3Idle(game) and not Battle.isActive(), "double: the field is the player's again")
        shot("double-after")
      end
    end

    -- ------------------------------------------------------------------
    -- CLASSIC BATTLE UI: the GBA double page
    -- ------------------------------------------------------------------
    if legOn("double-classic", "double") then
      settle()
      setOption(env.OPTION_KEY, true)
      setOption("classicui", true)
      local team = seedTeam({
        { species = STARTER, level = 40 }, { species = STRONG, level = 40 },
        { species = WILD, level = 30 },
      })
      session().money = 3000
      local moneyBefore = money()
      local result
      local took = solo:fromGen3Trainer(game, doubleId,
        { trainerId = doubleId, done = function(r) result = r end })
      check(took, "classic double: SOLO takes the lone double")
      local f0 = fight()
      if took and f0 then
        check(f0.classicUi == true and not f0:usesBattlefield(),
              "classic double: the screen latched CLASSIC BATTLE UI")
        local foes = foeSlotsOf(f0)
        local foeB = foes[2]
        local didMenu, didMove, didTarget = false, false, false
        local rep = fightDouble({
          tag = "double-classic",
          plan = function(c)
            if c.turn == 1 and c.pos == 1 then return { kind = "fight", target = foeB } end
            return { kind = "fight" }
          end,
          onMenu = function(c)
            if didMenu or c.turn ~= 1 or c.pos ~= 1 then return end
            didMenu = true
            local f = c.f
            local model = f:gen3ClassicModel()
            local d = model.double
            check(type(d) == "table", "classic double: the page model carries `double`")
            if type(d) == "table" then
              check(d.foes and d.foes[1] and d.foes[2] and d.allies and d.allies[1] and d.allies[2],
                    "classic double: two foes and two allies are modelled")
              check(model.foe == nil and model.ally == nil and model.foeStrip == nil and model.allyStrip == nil,
                    "classic double: no centre pair or focus strips beside it")
              check(d.choosing == 1, "classic double: mon 1 is the one choosing", tostring(d.choosing))
              check(d.hpText ~= true, "classic double: the bars are up, not the HP figures")
            end
            check(type(model.commands) == "table" and #model.commands >= 4,
                  "classic double: the command menu is the page's")
            U.wait(24)
            shot("double-classic-command")
            -- START swaps the bars for HP numbers, and again swaps them back
            U.tap(game, "start")
            U.wait(8)
            local on = fight()
            local m2 = on and on:gen3ClassicModel()
            check(on and on.hpText3 == true and m2 and m2.double and m2.double.hpText == true,
                  "classic double: START puts the HP figures up",
                  tostring(on and on.hpText3))
            U.wait(8)
            shot("double-classic-hp")
            U.tap(game, "start")
            U.wait(8)
            local off = fight()
            local m3 = off and off:gen3ClassicModel()
            check(off and off.hpText3 ~= true and m3 and m3.double and m3.double.hpText ~= true,
                  "classic double: START again puts the bars back")
          end,
          onMove = function(c, f, moves)
            if didMove or c.turn ~= 1 or c.pos ~= 1 then return end
            didMove = true
            local model = f:gen3ClassicModel()
            check(type(model.moves) == "table" and #model.moves == #moves and model.double ~= nil,
                  "classic double: the move menu is the page's, on the double")
            local withTarget = 0
            for _, row in ipairs(model.moves or {}) do
              if row.target ~= nil then withTarget = withTarget + 1 end
            end
            check(withTarget == #moves, "classic double: every move carries its target byte (the preview's input)",
                  tostring(withTarget))
            U.wait(16)
            shot("double-classic-move")
          end,
          onAimed = function(c, f, entry)
            if didTarget or c.turn ~= 1 or c.pos ~= 1 then return end
            didTarget = true
            local model = f:gen3ClassicModel()
            local d = model.double
            check(model.phase == "target" and type(model.moves) == "table",
                  "classic double: aiming keeps the move menu up", tostring(model.phase))
            check(d and d.blink and d.blink.side == "b" and d.blink.index == 2,
                  "classic double: the second foe is the battler blinking",
                  d and d.blink and (tostring(d.blink.side) .. tostring(d.blink.index)) or "no blink")
            -- The cart's blink is 8 frames lit, 8 hidden, restarted by each
            -- cursor move: one frame of each, and the two must differ.
            local function blinkPhase()
              local g = fight()
              local m = g and g:gen3ClassicModel()
              local b = m and m.double and m.double.blink
              return b and ((g.frame or 0) - (b.since or 0)) % 16 or nil
            end
            for _ = 1, 40 do
              local at = blinkPhase()
              if at and at <= 3 then break end
              U.wait(1)
            end
            local litPath = shotFile("double-classic-target")
            for _ = 1, 40 do
              local at = blinkPhase()
              if at and at >= 10 and at <= 13 then break end
              U.wait(1)
            end
            local offPath = shotFile("double-classic-target-off")
            local lit, off = readFile(litPath), readFile(offPath)
            check(lit ~= nil and off ~= nil and lit ~= off,
                  "classic double: the aimed-at battler blinks -- its lit and hidden frames differ")
          end,
          seconds = 300,
        })
        check(rep.ended, "classic double: the fight ended")
        check(didMenu and didMove and didTarget, "classic double: the command, move and target pages were all up")
        check(result == "win", "classic double: done('win')", tostring(result))
        local gained = money() - moneyBefore
        check(gained == prizeOf(true), "classic double: the double prize was paid",
              ("%d vs %s"):format(gained, tostring(prizeOf(true))))
        check(rep.medGaps == 0, "classic double: the referee's events arrived in order", tostring(rep.medGaps))
        backstopQuiet("classic double")
        settle()
        shot("double-classic-after")
      end
      setOption("classicui", false)
    end

    -- ------------------------------------------------------------------
    -- a knockout and the refill from the bench
    -- ------------------------------------------------------------------
    --
    -- Mon 1 is a weak lead on 1 HP that only growls; mon 2 hits it with a
    -- plain POUND, aimed at the partner (the picker offers it), until it falls
    -- -- a knockout of ours that depends on nothing the foes choose, and one
    -- more thing the picker must do.  Until then nothing is aimed at a foe, so
    -- the fight cannot end before it has been seen.
    local function friendlyFire(c, fallen)
      local own = c.f.ownSlots
      if not fallen then
        if c.pos == 1 then return { kind = "fight", move = 1 } end
        return { kind = "fight", move = 1, target = own[1] }
      end
      return { kind = "fight" }
    end

    if legOn("double-ko", "double") then
      settle()
      setOption(env.OPTION_KEY, true)
      setOption("classicui", false)
      if not (pound and growl) then
        skip("the KO + refill leg", "this cart's table has no MOVE_POUND / MOVE_GROWL to stage it with")
      else
        local team = seedTeam({
          { species = WEAK, level = 10, move = growl, hp = 1 },
          { species = STRONG, level = 55, first = pound },
          { species = STARTER, level = 30 }, { species = WILD, level = 30 },
        })
        check(#party() == 4 and team[1] and team[4], "ko double: a team of four was seeded")
        session().money = 3000
        local result
        local took = solo:fromGen3Trainer(game, doubleId,
          { trainerId = doubleId, done = function(r) result = r end })
        check(took, "ko double: SOLO takes the lone double")
        local f0 = fight()
        if took and f0 then
          local refilled, pickedIndex, partnerOffered = nil, nil, false
          local rep = fightDouble({
            tag = "double-ko",
            plan = function(c) return friendlyFire(c, #c.rep.replaces >= 1) end,
            onTarget = function(c, f, targets)
              if c.pos ~= 2 or partnerOffered then return end
              for _, e in ipairs(targets) do
                if e.index == f.ownSlots[1] then partnerOffered = true end
              end
            end,
            onMenu = function(c)
              if pickedIndex and refilled == nil then
                local seat = c.f.sim:slot(c.f.ownSlots[1])
                refilled = seat and seat.active == pickedIndex
                check(refilled, "ko double: the emptied seat holds the monster that was picked",
                      ("active %s, picked %s"):format(tostring(seat and seat.active), tostring(pickedIndex)))
              end
            end,
            onReplace = function(rec, f, bench)
              -- the first knockout is the staged one; a monster that falls
              -- later in the fight (a foe's doing) is asked for as well, from
              -- whatever is left
              if rec.n ~= 1 then return end
              local own = f.ownSlots
              local other = f.sim:slot(own[2])
              check(rec.seat == own[1], "ko double: the replacement is asked for the seat that fell (seat 1)",
                    ("seat %s, ours %s/%s"):format(tostring(rec.seat), tostring(own[1]), tostring(own[2])))
              check(#rec.queue == 1 and rec.queue[1] == own[1],
                    "ko double: only that seat owes a monster", tostring(#rec.queue))
              local out = false
              for _, entry in ipairs(bench) do
                if entry.index == other.active or (entry.mon and (tonumber(entry.mon.hp) or 0) <= 0) then out = true end
              end
              check(#bench == 2 and not out and indexSet(bench) == "3,4",
                    "ko double: the bench is the two reserves -- not the other seat's monster, not the fallen one",
                    ("bench %s, the other seat holds %s"):format(indexSet(bench), tostring(other.active)))
              shot("double-refill")
            end,
            replacePick = function(bench, rec)
              if rec.n ~= 1 then return 1 end
              pickedIndex = bench[#bench] and bench[#bench].index
              return #bench
            end,
            seconds = 300,
          })
          check(rep.ended, "ko double: the fight ended")
          check(partnerOffered, "ko double: the target picker offered the partner")
          check(#rep.replaces >= 1 and rep.replaces[1].seat == f0.ownSlots[1],
                "ko double: the replacement picker came up for seat 1", tostring(#rep.replaces))
          check(refilled == true, "ko double: the refill landed on the seat")
          check(result == "win", "ko double: done('win')", tostring(result))
          check(party()[1] and (tonumber(party()[1].hp) or 1) == 0, "ko double: the fallen lead is still down on the save")
          check(rep.medGaps == 0, "ko double: the referee's events arrived in order", tostring(rep.medGaps))
        backstopQuiet("ko double")
          settle()
        end
      end
    end

    -- ------------------------------------------------------------------
    -- the last monster: one seat refilled, not two
    -- ------------------------------------------------------------------
    if legOn("double-lastmon", "double") then
      settle()
      setOption(env.OPTION_KEY, true)
      setOption("classicui", false)
      if not (pound and growl) then
        skip("the last-monster leg", "this cart's table has no MOVE_POUND / MOVE_GROWL to stage it with")
      else
        -- one monster against two, after turns spent knocking out the other:
        -- strong enough not to lose to chance
        seedTeam({
          { species = WEAK, level = 10, move = growl, hp = 1 },
          { species = STRONG, level = 70, first = pound },
        })
        check(#party() == 2, "last-mon double: a team of two was seeded")
        session().money = 3000
        local result
        local took = solo:fromGen3Trainer(game, doubleId,
          { trainerId = doubleId, done = function(r) result = r end })
        check(took, "last-mon double: SOLO takes it with two usable monsters")
        local f0 = fight()
        if took and f0 then
          local fellAt, seatOneAgain, laterMenus = nil, 0, 0
          local rep = fightDouble({
            tag = "double-lastmon",
            plan = function(c)
              local s1 = c.f.sim:slot(c.f.ownSlots[1])
              return friendlyFire(c, c.f.sim:isDown(s1))
            end,
            onMenu = function(c)
              local s1 = c.f.sim:slot(c.f.ownSlots[1])
              if c.f.sim:isDown(s1) then
                fellAt = fellAt or c.turn
                laterMenus = laterMenus + 1
                if c.pos ~= 2 then seatOneAgain = seatOneAgain + 1 end
              end
            end,
            seconds = 300,
          })
          check(rep.ended, "last-mon double: the fight ended")
          check(fellAt ~= nil, "last-mon double: the first monster fell", tostring(fellAt))
          check(#rep.replaces == 0, "last-mon double: nobody was asked for a replacement (no bench)",
                tostring(#rep.replaces))
          check(laterMenus >= 1 and seatOneAgain == 0,
                "last-mon double: after the knockout only the other seat is ever asked",
                ("%d later menus, seat 1 asked %d times"):format(laterMenus, seatOneAgain))
          check(result == "win", "last-mon double: the last monster won it alone", tostring(result))
          check(party()[1] and (tonumber(party()[1].hp) or 1) == 0, "last-mon double: the fallen lead is down on the save")
          check(rep.medGaps == 0, "last-mon double: the referee's events arrived in order", tostring(rep.medGaps))
        backstopQuiet("last-mon double")
          settle()
        end
      end
    end

    -- ------------------------------------------------------------------
    -- a command the referee turns down: the cart's line, the menu kept
    -- ------------------------------------------------------------------
    --
    -- A foe's DISABLE has taken mon 1's first move (the referee's own state,
    -- as the move leaves it).  Choosing it is turned down in the cart's words
    -- and mon 1's menu stays open; nothing is filed, so mon 2 is not asked;
    -- another move goes through, and then mon 2 is.
    if legOn("double-refusal", "double") then
      settle()
      setOption(env.OPTION_KEY, true)
      setOption("classicui", false)
      seedTeam({
        { species = STARTER, level = 40 }, { species = STRONG, level = 40 },
        { species = WILD, level = 30 },
      })
      session().money = 3000
      local result
      local took = solo:fromGen3Trainer(game, doubleId,
        { trainerId = doubleId, done = function(r) result = r end })
      check(took, "refusal double: SOLO takes the lone double")
      local f0 = fight()
      if took and f0 then
        local shotRefusal = false
        local rep = fightDouble({
          tag = "double-refusal",
          onMenu = function(c)
            if c.turn == 1 and c.pos == 1 and c.visit == 1 then
              local b = solo.sim.byId["solo_player"].b
              b.disabledNum = b.moves[1].num
            end
          end,
          plan = function(c)
            if c.turn == 1 and c.pos == 1 then
              return { kind = "fight", move = (c.visit == 1) and 1 or 2 }
            end
            return { kind = "fight" }
          end,
          onCommit = function(c, rec)
            if rec.line and not shotRefusal then
              shotRefusal = true
              U.wait(10)
              shot("double-refused")
            end
          end,
          seconds = 300,
        })
        check(rep.ended, "refusal double: the fight ended")
        local first, second, third = rep.commits[1], rep.commits[2], rep.commits[3]
        check(first and first.turn == 1 and first.pos == 1 and first.phase == "messages"
                and first.chooser == 1 and first.referee == false,
              "refusal double: the disabled move is turned down -- a line, mon 1's seat kept, nothing filed",
              first and ("%s chooser=%s referee=%s"):format(tostring(first.phase), tostring(first.chooser), tostring(first.referee)) or "no commit")
        check(first and type(first.line) == "string" and first.line:lower():find("disabled", 1, true) ~= nil,
              "refusal double: ...in the cart's words (the move is disabled)", first and first.line or "no line")
        check(second and second.turn == 1 and second.pos == 1 and second.visit >= 2 and second.referee == true,
              "refusal double: mon 1 chose again, and the referee took it",
              second and ("turn %s pos %s visit %s referee=%s"):format(tostring(second.turn), tostring(second.pos),
                tostring(second.visit), tostring(second.referee)) or "no commit")
        check(third and third.turn == 1 and third.pos == 2,
              "refusal double: mon 2 was asked only after mon 1's command was in",
              third and ("turn %s pos %s"):format(tostring(third.turn), tostring(third.pos)) or "no commit")
        -- (a foe's own DISABLE can turn another down later in the fight; this
        -- one is the staged first)
        check(rep.refusals >= 1, "refusal double: the turned-down command was noticed and another tried",
              tostring(rep.refusals))
        check(result == "win", "refusal double: done('win')", tostring(result))
        check(rep.medGaps == 0, "refusal double: the referee's events arrived in order", tostring(rep.medGaps))
        backstopQuiet("refusal double")
        settle()
      end
    end

    -- ------------------------------------------------------------------
    -- fewer than two usable monsters: handed back
    -- ------------------------------------------------------------------
    if legOn("double-handback", "double") then
      settle()
      setOption(env.OPTION_KEY, true)
      setOption("classicui", false)
      -- one monster
      local team = seedTeam({ { species = STARTER, level = 40 } })
      check(#party() == 1 and team[1], "hand-back: a one-monster party was seeded")
      local hpBefore = tonumber(team[1] and team[1].hp) or 0
      local result
      local took = solo:fromGen3Trainer(game, doubleId,
        { trainerId = doubleId, done = function(r) result = r end })
      check(took == false, "hand-back: one usable monster -- SOLO does not take the double", tostring(took))
      check(fight() == nil and not solo.handingBack3 and not Battle.isActive(),
            "hand-back: no mod fight, none of the cart's yet, nothing left half-started")
      check(result == nil, "hand-back: the script is not answered", tostring(result))
      check(#party() == 1 and (tonumber(party()[1].hp) or -1) == hpBefore,
            "hand-back: the party is as it was")
      -- two monsters, one fainted
      local two = seedTeam({ { species = STARTER, level = 40 }, { species = STRONG, level = 40 } })
      if two[2] then two[2].hp = 0 end
      took = solo:fromGen3Trainer(game, doubleId, { trainerId = doubleId, done = function(r) result = r end })
      check(took == false, "hand-back: two monsters, one fainted -- SOLO does not take it", tostring(took))
      check(fight() == nil and not Battle.isActive() and result == nil,
            "hand-back: ...and nothing started")
      check(#party() == 2 and (tonumber(party()[2].hp) or -1) == 0 and (tonumber(party()[1].hp) or 0) > 0,
            "hand-back: ...and the party is as it was")
      -- the control: the same trainer with two usable monsters is taken
      seedTeam({ { species = STARTER, level = 40 }, { species = STRONG, level = 40 } })
      took = solo:fromGen3Trainer(game, doubleId, { trainerId = doubleId, done = function(r) result = r end })
      check(took == true and fight() ~= nil and fight().soloDouble == true,
            "hand-back: the same trainer with two usable monsters is taken")
      if took then
        local rep = fightDouble({ tag = "hand-back", noAutoShots = true, seconds = 240 })
        check(rep.ended and result == "win", "hand-back: ...and fought to a win", tostring(result))
      end
      settle()
    end

    -- ------------------------------------------------------------------
    -- the real flow: the twins' sight, the script, the fight, the script's
    -- resume; and the cart's own refusal with one monster
    -- ------------------------------------------------------------------
    if legOn("double-real", "double") then
      local stage = DOUBLE_STAGE[VERSION] or DOUBLE_STAGE.firered
      setOption(env.OPTION_KEY, true)
      setOption("classicui", false)

      -- The cell, and the way to walk, that steps the player into the
      -- trainer's line of sight: one past the end of the cone along the line
      -- when that is ground, else beside the cone's far cell.
      local function approachFor(eo)
        local sx, sy, dir = H.g3SightApproach(eo)
        local function open(x, y)
          local okW, walkable = pcall(Collision.isWalkable, x, y)
          return okW and walkable and not Objects.at(x, y)
        end
        if sx and open(sx, sy) then return sx, sy, dir end
        local vec = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
        local d = vec[eo.facing]
        if not d then return nil end
        local reach = tonumber(eo.sight) or 1
        local cx, cy = eo.cellX + d[1] * reach, eo.cellY + d[2] * reach
        local nx, ny = H.g3FreeCellNear(cx, cy)
        if not nx or (nx ~= cx and ny ~= cy) then return nil end
        local way = (cx > nx and "right") or (cx < nx and "left") or (cy > ny and "down") or "up"
        return nx, ny, way
      end

      -- The trainer's objects (both twins), unbeaten, and where to stand.
      local function stageTwins()
        settle()
        H.g3Teleport(game, stage.map, 1, 1, "down")
        local eo = H.g3ObjectById(stage.lid)
        if not eo then return nil, ("no object %d on %s"):format(stage.lid, stage.map) end
        local tid = H.g3TrainerId(eo)
        if tid ~= doubleId then
          return nil, ("object %d on %s is trainer %s, not the picked %s"):format(
            stage.lid, stage.map, tostring(tid), tostring(doubleId))
        end
        local sx, sy, dir = approachFor(eo)
        if not sx then return nil, "no free cell to walk into its sight from" end
        local twin = H.g3ObjectById(stage.lid + 1)
        H.g3ClearTrainer(eo)
        if twin then H.g3ClearTrainer(twin) end
        return { eo = eo, twin = twin, x = sx, y = sy, dir = dir }
      end

      -- Walk into sight and answer the cart's boxes, until `done()`.
      local function walkIn(st, done, seconds, what)
        return H.waitSeconds(game, function()
          if done() then return true end
          local top = H.g3Top(game)
          if type(top) == "table" and top.g3Engine == "message" and H.g3Layer() == nil then
            U.tap(game, "a")
            U.wait(6)
            return false
          end
          if not H.g3Free(game) then
            U.wait(4)
            return false
          end
          U.hold(game, st.dir, 16)
          U.wait(1)
          return false
        end, seconds or 180, what)
      end

      -- ---- two usable monsters: the solo double from the script, to the end
      do
        local st, why = stageTwins()
        if not st then
          skip("the real-flow double leg", why)
        else
          local team = seedTeam({
            { species = STARTER, level = 40 }, { species = STRONG, level = 40 },
            { species = WILD, level = 30 },
          })
          session().money = 3000
          local moneyBefore, expBefore = money(), expsOf()
          local placed = H.g3Teleport(game, stage.map, st.x, st.y, st.dir)
          check(placed, "real double: standing just outside the twins' line of sight")
          local met = placed and walkIn(st, function() return solo.fight ~= nil end, 180,
            "the twins to see us and solo to take the fight")
          check(met and fight() ~= nil and fight().soloDouble == true,
                "real double: walking into sight raised the fight and solo took it as a double")
          if met and fight() then
            check(not Battle.isActive(), "real double: the cart's own battle did not start")
            check(H.g3ScriptRunning(), "real double: the trainer's script waits on the fight")
            check(H.g3TrainerDefeated(st.eo) == false, "real double: the twins are unbeaten until it is won")
            local rep = fightDouble({ tag = "double-real", seconds = 300 })
            check(rep.ended, "real double: the fight ended")
            check(rep.medGaps == 0, "real double: the referee's events arrived in order", tostring(rep.medGaps))
        backstopQuiet("real double")
            H.g3TalkUntilFree(game, 90)
            check(H.g3TrainerDefeated(st.eo) == true,
                  "real double: the script resumed -- the trainer's defeat flag is set")
            if st.twin then
              check(H.g3TrainerDefeated(st.twin) == true, "real double: ...for the other twin too (one trainer)")
            end
            local gained = money() - moneyBefore
            check(gained == prizeOf(true), "real double: the double prize was paid by the script's resume",
                  ("%d vs %s"):format(gained, tostring(prizeOf(true))))
            local now = party()
            for i = 1, 2 do
              check(now[i] and (tonumber(now[i].exp) or 0) > expBefore[i],
                    ("real double: monster %d (out on the field) gained EXP"):format(i))
            end
            if #rep.replaces == 0 and #rep.switches == 0 then
              check(now[3] and (tonumber(now[3].exp) or 0) == expBefore[3],
                    "real double: the bench monster that never came out gained nothing")
            end
            check(OUTCOME.WON ~= nil and session().battleOutcome == OUTCOME.WON,
                  "real double: the save's outcome is a win", tostring(session().battleOutcome))
            check(H.g3Free(game) and not H.g3ScriptRunning(), "real double: control is the field's again")
            shot("double-real-after")
          end
          -- nothing of this fight may outlive the leg
          if solo.fight then fightDouble({ tag = "double-real-cleanup", noAutoShots = true, seconds = 240 }) end
          if Battle.isActive() then endCartBattle() end
          settle()
        end
      end

      -- ---- one monster: the cart's own rules, SOLO stays out of it
      --
      -- The cart's trainer does not come for a player who cannot double
      -- (pokefirered trainer_see.c:114), and talking to one is refused in the
      -- trainer's own "not enough POKéMON" words, the script halted.
      do
        local st, why = stageTwins()
        if not st then
          skip("the real-flow refusal leg", why)
        else
          seedTeam({ { species = STARTER, level = 40 } })
          session().money = 3000
          local moneyBefore = money()
          local vec = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
          local back = { up = "down", down = "up", left = "right", right = "left" }
          local d = vec[st.eo.facing]
          local ax, ay = st.eo.cellX + d[1], st.eo.cellY + d[2]
          -- in the line of sight, right in front of the trainer, looking at it
          local placed = H.g3Teleport(game, stage.map, ax, ay, back[st.eo.facing])
          check(placed, "real refusal: standing in the twins' line of sight, facing one of them")
          -- four seconds of nothing (a quiet wait: not finding it is the point)
          local early = false
          do
            local until_ = os.time() + 4
            while os.time() < until_ and not early do
              early = solo.fight ~= nil or Battle.isActive() or H.g3ScriptRunning()
              U.wait(2)
            end
          end
          check(not early and fight() == nil and not Battle.isActive(),
                "real refusal: in sight with one monster, the trainer does not come, and neither battle starts")
          -- talk to it
          local sawMessage, taken, shotRefused = false, false, false
          local spoken = {}
          U.tap(game, "a")
          local done = H.waitSeconds(game, function()
            if solo.fight or Battle.isActive() then taken = true return true end
            local top = H.g3Top(game)
            if type(top) == "table" and top.g3Engine == "message" and H.g3Layer() == nil then
              sawMessage = true
              local page = top.pages and top.pages[1] and top.pages[1][1]
              if page and spoken[#spoken] ~= page then spoken[#spoken + 1] = page end
              if not shotRefused then
                shotRefused = true
                U.wait(40)
                shot("double-real-refused")
              end
              U.wait(24)
              U.tap(game, "a")
              U.wait(6)
              return false
            end
            if sawMessage then return H.g3Free(game) end
            U.wait(4)
            return false
          end, 60, "the cart to refuse a double with one monster")
          for i, page in ipairs(spoken) do log("real refusal: the cart said [" .. i .. "]", (page:gsub("\n", " / "))) end
          check(done and not taken, "real refusal: the cart finished talking, with no battle of any kind")
          check(sawMessage, "real refusal: the cart refused in its own words (a message box)")
          check(fight() == nil and not Battle.isActive(), "real refusal: SOLO did not take it, and neither did the cart")
          check(H.g3TrainerDefeated(st.eo) == false, "real refusal: the trainer stays unbeaten")
          check(money() == moneyBefore, "real refusal: no prize, nobody taxed", tostring(money()))
          check(H.g3Free(game) and not H.g3ScriptRunning(), "real refusal: the script is over and the field is the player's")
          if solo.fight then fightDouble({ tag = "double-real-cleanup", noAutoShots = true, seconds = 240 }) end
          if Battle.isActive() then endCartBattle() end
          -- out of the line of sight, and the flag as the cart left it
          H.g3Teleport(game, stage.map, 1, 1, "down")
          H.g3ClearTrainer(st.eo)
          settle()
        end
      end
    end
  end

  -- ------------------------------------------------------------------
  -- Badge rules (docs/plans/gen3-badge-rules.md)
  -- ------------------------------------------------------------------
  --
  -- Against the computer the cart's badges count: x110/100 (floored) on
  -- Attack for badge 1, Speed for 3, Defense for 5, Sp. Atk and Sp. Def for 7,
  -- and a TRADED monster above its badge level cap (10 with no badge; 30 / 50 /
  -- 70 with badge 2 / 4 / 6; none with badge 8) may disobey.  The referee
  -- (BattleSim3) owns both, off the badges the player's save holds and the
  -- `traded` fact on the monster's sheet; what these legs prove is the part a
  -- headless suite cannot see -- that a real save's badge flags and a real
  -- traded party monster reach the live referee through SOLO BATTLES, and that
  -- the screens then say what the cart says.
  --
  --   badge-boost    the same wild fight twice with the same seed and the same
  --                  first command: no badges, then badges 1 + 3.  Pinned stats
  --                  put the foe's Speed between the player's raw Speed and its
  --                  x110/100, so badge 3 flips who moves first; the referee's
  --                  own Damage.calc, replayed on the very RNG state of each
  --                  real hit, says what the hit does with and without the
  --                  badges, and the foe's HP afterwards is exactly that.  A
  --                  second pair, the player faster either way, makes the same
  --                  point across two real fights (same draws, so the foe's HP
  --                  differs by exactly the badge's share of the hit).
  --   badge-guard    badges 5 + 7: the foe's physical hit lands softer (Defense),
  --                  the player's special hit harder (Sp. Atk), Speed untouched
  --   badge-trainer  a trainer fight (the coop_npc mode) carries the same
  --                  badges on the player's battler and none on the trainer's
  --   obey-arena     a traded L50 monster, no badges: the referee emits `obey`
  --                  events for the player's seat, the screen says the cart's
  --                  line for each (once), the fight still ends in a win
  --   obey-classic   the same on CLASSIC BATTLE UI (the GBA page)
  --   obey-badge8    the same traded monster with badge 8: it never disobeys
  --   obey-outcomes  a seed run of two-move fights until the self-hit, the nap,
  --                  a called move and a loafing line have all been through
  --                  the screen, each said once in the cart's words
  --   obey-asleep    a MEW met outside an event (`unfateful`), asleep, told to
  --                  SNORE: the referee's `obey` is `ignores_asleep` on the
  --                  first turn on every seed, said once in the cart's words
  --                  (docs/plans/gen12-referee-fidelity.md §1 item 11)
  --   theft-wild     a wild monster whose only move is THIEF, faster than the
  --                  player's item holder: it hits and steals nothing -- no
  --                  `held` event, no "stole" line, the item still on the party
  --                  monster after the fight (§1 item 10; `wild` is a BADGE_MODES
  --                  fight, so side b is the computer)
  --
  -- Numbers pinned on the monsters are synthetic fixture values; every number
  -- asserted is read off the live referee or computed by its own Damage.
  local function badgeLegs()
    local legs = { "badge-boost", "badge-guard", "badge-trainer",
                   "obey-arena", "obey-classic", "obey-badge8", "obey-outcomes",
                   "obey-asleep", "theft-wild" }
    local function wants(name) return legOn(name, name:match("^(%a+)%-")) end
    local any = false
    for _, name in ipairs(legs) do
      if wants(name) then any = true end
    end
    if not any then return end

    local Moves = require("src.core.game3.battle.moves")
    local function moveId(name) return H.g3Const(game, "moves", name) end
    local SWIFT, WATER_GUN, TACKLE = moveId("MOVE_SWIFT"), moveId("MOVE_WATER_GUN"), moveId("MOVE_TACKLE")
    if not (SWIFT and WATER_GUN and TACKLE) then
      skip("the badge legs", "this cart's move table has no SWIFT / WATER GUN / TACKLE")
      return
    end
    if not solo.gen3FoeMon then
      skip("the badge legs", "SoloBattle.gen3FoeMon is not exported on this build")
      return
    end

    setOption(env.OPTION_KEY, true)
    setOption("classicui", false)

    local function setBadges(list)
      local ok = H.g3SetBadges(game, list)
      local held = table.concat(H.g3BadgesHeld(game), ",")
      local asked = {}
      for _, n in ipairs(list or {}) do asked[#asked + 1] = tostring(n) end
      check(ok and held == table.concat(asked, ","),
            "badges: the save's flags hold exactly [" .. table.concat(asked, ",") .. "]", held)
      return ok
    end

    -- One lead that knows only these moves (one, or a list), at full PP.
    local function pinMove(mon, moves)
      if type(moves) ~= "table" then moves = { moves } end
      local list, pps = {}, {}
      for i, move in ipairs(moves) do
        local okP, row = pcall(Moves.get, move)
        list[i] = move
        pps[i] = (okP and type(row) == "table" and tonumber(row.pp)) or 10
      end
      local maxPp = {}
      for i, v in ipairs(pps) do maxPp[i] = v end
      mon.moves, mon.pp, mon.maxPp = list, pps, maxPp
    end

    -- Synthetic stats, set the way the cart's own party monster holds them
    -- (the aliases too: Sheet3 reads `attack` before `atk`).
    local function pinStats(mon, st)
      mon.attack, mon.atk = st.atk, st.atk
      mon.defense, mon.def = st.def, st.def
      mon.speed, mon.spe = st.spe, st.spe
      mon.spAtk, mon.spa = st.spa, st.spa
      mon.spDef, mon.spd = st.spd, st.spd
      mon.maxHp, mon.hp = st.hp, st.hp
      if type(mon.stats) == "table" then
        mon.stats.attack, mon.stats.atk = st.atk, st.atk
        mon.stats.defense, mon.stats.def = st.def, st.def
        mon.stats.speed, mon.stats.spe = st.spe, st.spe
        mon.stats.spAtk, mon.stats.spa = st.spa, st.spa
        mon.stats.spDef, mon.stats.spd = st.spd, st.spd
      end
    end

    -- The wild foe, built once by SoloBattle's own builder and handed in
    -- prebuilt, so every run of a pair fights the same monster: no held item,
    -- fixed personality and IVs, one known move.
    local function foeMon(level, st, move)
      local mon = solo.gen3FoeMon({
        species = H.g3Species(game, WILD), level = level, item = 0, moves = { move },
        personality = 1234567,
        ivs = { hp = 15, atk = 15, def = 15, spe = 15, spa = 15, spd = 15 },
      }, { wild = true })
      if mon and st then pinStats(mon, st) end
      if mon then mon.status = nil end
      return mon
    end

    -- ------- watching the live referee

    local function view(b, over) return setmetatable(over, { __index = b }) end
    local function copyOpts(o)
      local c = {}
      for k, v in pairs(o) do c[k] = v end
      if type(o.rng) == "table" then
        c.rng = setmetatable({ s = o.rng.s, draws = o.rng.draws }, getmetatable(o.rng))
      end
      return c
    end
    -- The hit by hand: each stat a badge raises, raised x110/100 floored on
    -- the raw stat, and the badges themselves taken off.
    local function raised(Damage, b, pairs_)
      local stats = {}
      for k, v in pairs(b.stats or {}) do stats[k] = v end
      for _, pair in ipairs(pairs_) do
        if Damage.hasBadge(b, pair[1]) then
          stats[pair[2]] = math.floor(110 * stats[pair[2]] / 100)
        end
      end
      return view(b, { badges = false, stats = stats })
    end
    local function replay(Damage, C, o)
      local user, tgt, move = C.user, C.target, C.move
      local with, info = Damage.calc(user, tgt, move, copyOpts(o))
      local bare = Damage.calc(view(user, { badges = false }), view(tgt, { badges = false }),
        move, copyOpts(o))
      local byHand = Damage.calc(
        raised(Damage, user, { { 1, "atk" }, { 7, "spa" } }),
        raised(Damage, tgt, { { 5, "def" }, { 7, "spd" } }),
        move, copyOpts(o))
      return {
        from = user.side, to = tgt.side, with = with, bare = bare, byHand = byHand,
        crit = type(info) == "table" and info.critical == true,
        atk = user.stats and user.stats.atk, spa = user.stats and user.stats.spa,
        def = tgt.stats and tgt.stats.def, spd = tgt.stats and tgt.stats.spd,
        userBadges = H.badgeString(user.badges), targetBadges = H.badgeString(tgt.badges),
      }
    end

    -- Everything the referee emits and everything the screen says, in order,
    -- from here on; and, for every real hit, that hit replayed on the same
    -- RNG state with the badges on and off (the hit itself is untouched: the
    -- replay draws from a copy of the generator).
    local function watch(sim, f)
      local rec = { events = {}, obey = {}, said = {}, hits = {}, errors = {} }
      local emit = sim._emit
      sim._emit = function(self, kind, fields)
        local ev = emit(self, kind, fields)
        if ev then
          rec.events[#rec.events + 1] = {
            t = ev.t, side = ev.side, slot = ev.slot, text = ev.text, amount = ev.amount, hp = ev.hp,
          }
          if ev.t == "obey" then
            rec.obey[#rec.obey + 1] = { token = ev.text, side = ev.side, slot = ev.slot }
          end
        end
        return ev
      end
      local say, depth = f.say, 0
      f.say = function(self, text, ...)
        if depth == 0 and type(text) == "string" then rec.said[#rec.said + 1] = text end
        depth = depth + 1
        local ok, err = pcall(say, self, text, ...)
        depth = depth - 1
        if not ok then error(err, 0) end
      end
      local Damage = H.fnUpvalue(sim._disobey, "Damage")
      rec.haveDamage = Damage ~= nil
      local calcOpts = sim._calcOpts
      sim._calcOpts = function(self, C, target, extra)
        local o = calcOpts(self, C, target, extra)
        if Damage and type(C) == "table" and C.user and C.target and C.move and target == C.target then
          local ok, row = pcall(replay, Damage, C, o)
          if ok and row then rec.hits[#rec.hits + 1] = row else rec.errors[#rec.errors + 1] = tostring(row) end
        end
        return o
      end
      return rec
    end

    local function firstOf(list, pred)
      for _, item in ipairs(list) do
        if pred(item) then return item end
      end
      return nil
    end
    local function firstHit(rec, from)
      return firstOf(rec.hits, function(h) return h.from == from end)
    end
    local function firstDamage(rec, side)
      return firstOf(rec.events, function(e) return e.t == "damage" and e.side == side end)
    end
    local function firstAnimSide(rec)
      local ev = firstOf(rec.events, function(e) return e.t == "anim" end)
      return ev and ev.side or nil
    end
    local function turnOpened(rec, n)
      return firstOf(rec.events, function(e)
        return e.t == "turn" and (e.amount or 0) >= n and e.slot == nil
      end) ~= nil
    end

    -- Play the fight out to its end: FIGHT / move 1 on every command menu, A
    -- on every line.  `onFrame(f)` sees the screen each poll.
    local function play(onFrame, seconds, what)
      return H.waitSeconds(game, function()
        local f = fight()
        if not f then return true end
        if onFrame then onFrame(f) end
        if f.phase == "choose" then fightWith(1) else nudge() end
        return fight() == nil
      end, seconds or 240, what or "the fight to end")
    end

    -- ------- the badge fights

    -- One wild fight on the pinned fixture.  spec: label, badges (list),
    -- playerMove, foeMove, playerSpe, foeSpe, seed, shotTag (a screenshot of
    -- the command menu and of the first hit, named for this fight).
    local function badgeFight(spec)
      settle()
      setBadges(spec.badges)
      local mon = seed(STARTER, 30)
      if not mon then check(false, spec.label .. ": a lead was seeded") return nil end
      pinMove(mon, spec.playerMove)
      pinStats(mon, { atk = 80, def = 60, spe = spec.playerSpe, spa = 80, spd = 60, hp = 300 })
      local foe = foeMon(30, { atk = 70, def = 60, spe = spec.foeSpe, spa = 70, spd = 60, hp = 60 },
        spec.foeMove)
      if not foe then check(false, spec.label .. ": the wild foe was built") setBadges({}) return nil end
      local before = solo.seedFn
      solo.seedFn = function() return spec.seed end
      local result
      local took = solo:fromGen3Encounter(game, wildOf(WILD, 30),
        { party = { foe }, done = function(r) result = r end })
      solo.seedFn = before
      if not (check(took and solo.sim ~= nil and fight() ~= nil, spec.label .. ": the fight was taken")) then
        setBadges({})
        return nil
      end
      local sim = solo.sim
      local rec = watch(sim, fight())
      rec.label = spec.label
      check(rec.haveDamage, spec.label .. ": the referee's own Damage is reachable for the replay")
      check(awaitChoose(60, "the badge fight's command grid"), spec.label .. ": the command grid opens")

      local pf, ff = sim.byId.solo_player, sim.byId.solo_foe
      local pb, fb = pf and pf.b, ff and ff.b
      if not (pb and fb) then
        check(false, spec.label .. ": both battlers are on the field")
        driveToEnd(function(f) fightWith(1) end, 240)
        setBadges({})
        return nil
      end
      rec.facts = {
        playerBadges = H.badgeString(pb.badges), foeBadges = H.badgeString(fb.badges),
        foeHasBadges = fb.badges ~= nil,
        playerRules = pf.badgeRules == true, foeRules = ff.badgeRules == true,
        rawP = pb.stats.spe, rawF = fb.stats.spe,
        speedP = sim:_speedOf(pb), speedF = sim:_speedOf(fb),
        mode = sim.mode,
      }
      if spec.shotTag then shot(spec.shotTag .. "-command") end

      -- the same first command in every fight: FIGHT, move 1
      fightWith(1)
      local landed = false
      play(function(f)
        if not landed and spec.shotTag and (f.draining or f.hitHold) then
          landed = true
          U.wait(36)
          shot(spec.shotTag .. "-hit")
        end
      end, 240, "the badge fight to end")
      rec.result = result
      rec.turn1 = turnOpened(rec, 2)
      setBadges({})
      settle()
      return rec
    end

    -- What every fight of the fixture must have, whatever the badges.
    local function fixtureChecks(rec, spec)
      local L = rec.label
      check(rec.facts.rawP == spec.playerSpe and rec.facts.rawF == spec.foeSpe,
            L .. ": the referee's battlers carry the fixture's pinned Speed (player / foe)",
            tostring(rec.facts.rawP) .. " / " .. tostring(rec.facts.rawF))
      check(rec.facts.playerRules and not rec.facts.foeRules,
            L .. ": badge rules are on for the player's side only",
            tostring(rec.facts.playerRules) .. " / " .. tostring(rec.facts.foeRules))
      check(rec.facts.foeBadges == "" and not rec.facts.foeHasBadges,
            L .. ": the foe's battler carries no badges")
      check(rec.facts.speedF == rec.facts.rawF, L .. ": the foe's Speed is raw",
            tostring(rec.facts.speedF))
      check(#rec.errors == 0, L .. ": every hit could be replayed", rec.errors[1])
      check(rec.turn1, L .. ": turn 1 resolved")
      check(rec.result == "win", L .. ": the fight still ends in a win", tostring(rec.result))
    end

    -- The first hit each way: the referee's own damage, with the badges, by
    -- hand, and without them, against what the screen's referee really dealt.
    local function hitChecks(rec, from, expectBadges)
      local L = rec.label
      local hit = firstHit(rec, from)
      local to = (from == "a") and "b" or "a"
      local ev = firstDamage(rec, to)
      if not check(hit ~= nil and ev ~= nil, L .. ": side " .. from .. " landed a hit that was replayed",
                   hit and "" or "no replayed hit") then
        return nil
      end
      check(ev.amount == hit.with, L .. ": the damage the referee dealt is its own Damage.calc's",
            ("dealt %s, calc %s"):format(tostring(ev.amount), tostring(hit.with)))
      check(hit.with == hit.byHand,
            L .. ": and that is the hit with the raised stat worked by hand (floor(110 x stat / 100))",
            ("calc %s, by hand %s"):format(tostring(hit.with), tostring(hit.byHand)))
      if expectBadges == "boost" then
        check(hit.with > hit.bare, L .. ": the badge makes the hit stronger than the same hit without it",
              ("%s with, %s without"):format(tostring(hit.with), tostring(hit.bare)))
      elseif expectBadges == "guard" then
        check(hit.with < hit.bare, L .. ": the badge makes the hit softer than the same hit without it",
              ("%s with, %s without"):format(tostring(hit.with), tostring(hit.bare)))
      else
        check(hit.with == hit.bare, L .. ": no badge, no difference: the hit is the unboosted one",
              ("%s with, %s without"):format(tostring(hit.with), tostring(hit.bare)))
      end
      return hit, ev
    end

    -- ---- the pair that flips the order: badge 3 crosses the foe's Speed
    local FLIP = { playerSpe = 100, foeSpe = 105, playerMove = SWIFT, foeMove = SWIFT, seed = 4242 }
    local SAME = { playerSpe = 100, foeSpe = 60, playerMove = SWIFT, foeMove = SWIFT, seed = 4242 }
    local function with(base, extra)
      local out = {}
      for k, v in pairs(base) do out[k] = v end
      for k, v in pairs(extra) do out[k] = v end
      return out
    end

    if wants("badge-boost") then
      local spec0 = with(FLIP, { label = "badge flip, no badges", badges = {} })
      local spec1 = with(FLIP, { label = "badge flip, badges 1+3", badges = { 1, 3 }, shotTag = "badge-boost" })
      local none = badgeFight(spec0)
      local boosted = badgeFight(spec1)
      if none and boosted then
        fixtureChecks(none, spec0)
        fixtureChecks(boosted, spec1)
        local P = FLIP.playerSpe
        check(none.facts.playerBadges == "" and boosted.facts.playerBadges == "1,3",
              "badge boost: the player's battler holds the save's badges (none / 1,3)",
              ("[%s] / [%s]"):format(none.facts.playerBadges, boosted.facts.playerBadges))
        check(none.facts.speedP == P,
              "badge boost: no badges, the player's Speed is raw", tostring(none.facts.speedP))
        check(boosted.facts.speedP == math.floor(P * 110 / 100),
              "badge boost: badge 3, the player's Speed is floor(raw x 110 / 100)",
              ("%s from %s"):format(tostring(boosted.facts.speedP), tostring(boosted.facts.rawP)))
        check(none.facts.speedP < none.facts.speedF and boosted.facts.speedP > boosted.facts.speedF,
              "badge boost: badge 3 takes the player's Speed from under the foe's to over it",
              ("%s v %s -> %s v %s"):format(none.facts.speedP, none.facts.speedF,
                boosted.facts.speedP, boosted.facts.speedF))
        check(firstAnimSide(none) == "b",
              "badge boost: with no badges the foe moves first", tostring(firstAnimSide(none)))
        check(firstAnimSide(boosted) == "a",
              "badge boost: with badges 1+3 the player moves first -- the order flipped",
              tostring(firstAnimSide(boosted)))
        local hitNone, evNone = hitChecks(none, "a", "none")
        local hitBoost, evBoost = hitChecks(boosted, "a", "boost")
        hitChecks(none, "b", "none")
        hitChecks(boosted, "b", "none")   -- badge 5 is not held: the foe's hit is unboosted
        if hitBoost then
          check(hitBoost.atk == 80 and math.floor(110 * hitBoost.atk / 100) == 88,
                "badge boost: the Attack the hit read is the fixture's pinned stat, raw (the boost is applied in the formula)",
                tostring(hitBoost.atk))
          check(evBoost and evBoost.hp == 60 - hitBoost.with,
                "badge boost: the foe's HP after the hit is its max less the boosted damage",
                ("%s left, expected %s"):format(tostring(evBoost and evBoost.hp), tostring(60 - hitBoost.with)))
        end
        if hitNone then
          check(evNone and evNone.hp == 60 - hitNone.with,
                "badge boost: with no badges the foe's HP is its max less the plain damage",
                ("%s left, expected %s"):format(tostring(evNone and evNone.hp), tostring(60 - hitNone.with)))
        end
      end

      -- ---- the pair the order does not change: same draws, so the same hit
      local same0 = with(SAME, { label = "badge same-order, no badges", badges = {} })
      local same1 = with(SAME, { label = "badge same-order, badges 1+3", badges = { 1, 3 } })
      local a2 = badgeFight(same0)
      local b2 = badgeFight(same1)
      if a2 and b2 then
        fixtureChecks(a2, same0)
        fixtureChecks(b2, same1)
        check(firstAnimSide(a2) == "a" and firstAnimSide(b2) == "a",
              "badge boost: the player is faster either way -- the same order in both fights")
        local hitA = hitChecks(a2, "a", "none")
        local hitB, evB = hitChecks(b2, "a", "boost")
        local evA = firstDamage(a2, "b")
        if hitA and hitB and evA and evB then
          check(hitA.bare == hitB.bare and hitA.with == hitB.bare,
                "badge boost: the identical first hit: the unboosted damage is the same in both fights",
                ("%s / %s"):format(tostring(hitA.with), tostring(hitB.bare)))
          check(evA.hp - evB.hp == hitB.with - hitB.bare and evA.hp > evB.hp,
                "badge boost: the foe's HP after it is lower with badge 1 by exactly the formula's difference",
                ("%s -> %s, difference %s, formula %s"):format(tostring(evA.hp), tostring(evB.hp),
                  tostring(evA.hp - evB.hp), tostring(hitB.with - hitB.bare)))
        end
        local foeA, foeB = firstDamage(a2, "a"), firstDamage(b2, "a")
        check(foeA ~= nil and foeB ~= nil and foeA.amount == foeB.amount,
              "badge boost: the foe's hit on the player is the same in both (badges 1+3 do not touch it)",
              ("%s / %s"):format(tostring(foeA and foeA.amount), tostring(foeB and foeB.amount)))
      end
    end

    -- ---- badges 5 + 7: the other side of the formula
    if wants("badge-guard") then
      local spec = { label = "badge guard, badges 5+7", badges = { 5, 7 }, playerSpe = 100, foeSpe = 105,
                     playerMove = WATER_GUN, foeMove = SWIFT, seed = 4242, shotTag = "badge-guard" }
      local rec = badgeFight(spec)
      if rec then
        fixtureChecks(rec, spec)
        check(rec.facts.playerBadges == "5,7", "badge guard: the player's battler holds badges 5 and 7",
              rec.facts.playerBadges)
        check(rec.facts.speedP == rec.facts.rawP,
              "badge guard: no badge 3, the player's Speed stays raw", tostring(rec.facts.speedP))
        check(firstAnimSide(rec) == "b", "badge guard: the foe is faster and moves first", tostring(firstAnimSide(rec)))
        hitChecks(rec, "a", "boost")    -- Sp. Atk, badge 7
        hitChecks(rec, "b", "guard")    -- Defense, badge 5
      end
    end

    -- ---- a trainer: the coop_npc mode
    if wants("badge-trainer") then
      local pack = Trainers.pack() or {}
      local trainerId, trainerLevel
      for id, row in pairs(pack.trainers or {}) do
        local tid = tonumber(id)
        local p = type(row) == "table" and row.party or nil
        local named = type(row) == "table" and type(row.name) == "string" and row.name ~= ""
        local class = type(row) == "table" and tonumber(row.class) or 0
        local plain = (emerald or (class >= 57 and class ~= 98)) and class ~= 81
          and class ~= 89 and class ~= 90
        if tid and tid > 0 and named and plain and type(p) == "table" and #p == 1
            and not row.doubleBattle then
          local last = tonumber(p[#p].level) or 999
          if last >= 3 and (trainerLevel == nil or last < trainerLevel) then trainerId, trainerLevel = tid, last end
        end
      end
      if not trainerId then
        skip("badge-trainer", "no single trainer with a party of one in this cart's book")
      else
        settle()
        setBadges({ 1, 3 })
        seed(STARTER, 40)
        local result
        local took = solo:fromGen3Trainer(game, trainerId, { trainerId = trainerId, done = function(r) result = r end })
        if check(took and solo.sim ~= nil, "badge trainer: trainer " .. tostring(trainerId) .. " was taken") then
          local sim = solo.sim
          awaitChoose(60, "the trainer grid with badges")
          local pf, ff = sim.byId.solo_player, sim.byId.solo_foe
          local pb, fb = pf and pf.b, ff and ff.b
          if check(pb ~= nil and fb ~= nil, "badge trainer: both battlers are on the field") then
            check(sim.mode == "coop_npc", "badge trainer: the referee runs it as coop_npc", tostring(sim.mode))
            check(H.badgeString(pb.badges) == "1,3" and pf.badgeRules == true,
                  "badge trainer: the player's battler holds badges 1 and 3",
                  H.badgeString(pb.badges))
            check(fb.badges == nil and ff.badgeRules ~= true and (fb.mon and fb.mon.traded) == nil,
                  "badge trainer: the trainer's battler holds none, and is not 'traded'")
            local plain = (tonumber(pb.stages and pb.stages.spe) or 0) == 0 and pb.mon.status == nil
              and (tonumber(pb.mon.heldItem) or 0) == 0
            if plain then
              check(sim:_speedOf(pb) == math.floor(pb.stats.spe * 110 / 100),
                    "badge trainer: badge 3, the player's Speed is floor(raw x 110 / 100)",
                    ("%s from %s"):format(tostring(sim:_speedOf(pb)), tostring(pb.stats.spe)))
            else
              log("badge trainer: the lead is not plain (stage / status / item); the Speed check is skipped")
            end
            shot("badge-trainer-command")
          end
          driveToEnd(function(f) fightWith(bestMove(f)) end, 240)
          check(result == "win", "badge trainer: the trainer fight ends in a win", tostring(result))
        end
        setBadges({})
        settle()
      end
    end

    -- ------- obedience

    -- The cart's line for each outcome, as it is said on the screen, and the
    -- referee tokens that map to it: the first row a line fits is its row.
    local OBEY_LINES = {
      { key = "asleep", phrase = "ignored orders while asleep", tokens = { ignores_asleep = true } },
      { key = "ignored", phrase = "ignored orders", tokens = { uses_random_move = true } },
      { key = "nap", phrase = "began to nap", tokens = { falls_asleep = true } },
      { key = "loafing", phrase = "loafing around", tokens = { loafing = true } },
      { key = "turned", phrase = "turned away", tokens = { turned_away = true } },
      { key = "pretend", phrase = "pretended not to notice", tokens = { pretend_not_notice = true } },
      { key = "wont", phrase = "won't obey", tokens = { wont_obey = true, hits_itself = true } },
    }
    local function flat(text)
      return (tostring(text):gsub("\226\128\153", "'"):gsub("%s+", " "):lower())
    end
    local function lineKey(text)
      local t = flat(text)
      for _, row in ipairs(OBEY_LINES) do
        if t:find(row.phrase, 1, true) then return row.key end
      end
      return nil
    end
    local function tokenKey(token)
      for _, row in ipairs(OBEY_LINES) do
        if row.tokens[token] then return row.key end
      end
      return nil
    end
    local function countsOf(list, keyOf)
      local out = {}
      for _, item in ipairs(list) do
        local key = keyOf(item)
        if key then out[key] = (out[key] or 0) + 1 end
      end
      return out
    end
    local function describe(counts)
      local parts = {}
      for _, row in ipairs(OBEY_LINES) do
        if counts[row.key] then parts[#parts + 1] = row.key .. "=" .. counts[row.key] end
      end
      return #parts > 0 and table.concat(parts, " ") or "none"
    end

    -- A traded lead at `level` that knows only SWIFT: its OT is not this
    -- player's, by id and by name (what Sheet3's `tradedOf` compares).  False
    -- when this save has no trainer id to differ from.
    local function tradedLead(level, moves)
      local mon = seed(STARTER, level)
      if not mon then return nil end
      pinMove(mon, moves or SWIFT)
      local s = session()
      local pid = tonumber(s.trainerId or s.id or s.playerId)
      if not pid then return nil, "the session has no trainer id" end
      mon.otId = pid + 1
      mon.otName, mon.ot = "TRADER", "TRADER"
      mon.maxHp, mon.hp = math.max(300, tonumber(mon.maxHp) or 0), math.max(300, tonumber(mon.maxHp) or 0)
      return mon
    end

    -- One fight of the traded lead.  spec: label, seed, badges, classic,
    -- shotTag.  The foe is a weak wild monster a single landed hit knocks
    -- out, so the fight ends the moment the lead finally obeys.
    local function obeyFight(spec)
      settle()
      setBadges(spec.badges or {})
      setOption("classicui", spec.classic == true)
      local mon, why = tradedLead(50, spec.moves)
      if not mon then
        check(false, spec.label .. ": a traded lead was seeded", why)
        setOption("classicui", false)
        return nil
      end
      local foe = foeMon(5, { atk = 30, def = 30, spe = 20, spa = 30, spd = 30, hp = 30 }, TACKLE)
      if not foe then
        check(false, spec.label .. ": the wild foe was built")
        setOption("classicui", false)
        setBadges({})
        return nil
      end
      local before = solo.seedFn
      solo.seedFn = function() return spec.seed end
      local result
      local took = solo:fromGen3Encounter(game, wildOf(WILD, 5),
        { party = { foe }, done = function(r) result = r end })
      solo.seedFn = before
      if not check(took and solo.sim ~= nil and fight() ~= nil, spec.label .. ": the fight was taken") then
        setOption("classicui", false)
        setBadges({})
        return nil
      end
      local sim, f = solo.sim, fight()
      local rec = watch(sim, f)
      rec.label, rec.seed = spec.label, spec.seed
      rec.classic = f.classicUi == true
      check(awaitChoose(60, "the obedience fight's command grid"), spec.label .. ": the command grid opens")
      local pf, ff = sim.byId.solo_player, sim.byId.solo_foe
      local pb, fb = pf and pf.b, ff and ff.b
      rec.facts = pb and fb and {
        level = pb.mon.level, traded = pb.mon.traded == true, unfateful = pb.mon.unfateful,
        foeTraded = fb.mon.traded, playerBadges = H.badgeString(pb.badges),
        rules = pf.badgeRules == true,
      } or nil

      local shotDone = false
      rec.lineKeys = {}
      play(function(g)
        -- the moment the screen is showing a disobedience line: let the page
        -- finish typing, photograph it, then carry on
        if #rec.obey == 0 then return end
        local key = lineKey(g.shown or "")
        if not key then return end
        rec.lineKeys[key] = true
        if spec.shotTag and not shotDone then
          shotDone = true
          rec.shownLine = flat(g.shown or "")
          U.wait(30)
          shot(spec.shotTag)
          rec.shot = true
        elseif spec.shotEach and not spec.shotEach[key] then
          spec.shotEach[key] = true
          U.wait(30)
          shot("obey-" .. key)
        end
      end, 240, "the obedience fight to end")
      rec.result = result
      setOption("classicui", false)
      setBadges({})
      settle()
      return rec
    end

    -- Seeds tried in order; the first fight that has a disobedience in it is
    -- the leg's fight.  (A traded L50 monster over a cap of 10 obeys on a
    -- bit under one roll in five, so most seeds disobey at once; the list is
    -- only the net under the rest.)
    local OBEY_SEEDS = { 7, 23, 51, 77, 91, 131, 177, 211 }
    local function obeyUntilDisobeyed(spec)
      local rec
      for i, seedValue in ipairs(OBEY_SEEDS) do
        rec = obeyFight(with(spec, { seed = seedValue,
          label = ("%s (seed %d)"):format(spec.label, seedValue) }))
        if not rec then return nil end
        if #rec.obey > 0 then return rec end
        log(("%s: seed %d obeyed throughout; trying the next"):format(spec.label, seedValue))
        if i == #OBEY_SEEDS then return rec end
      end
      return rec
    end

    -- Do the lines the screen said match the referee's `obey` events, once
    -- for each, outcome by outcome?  (The referee's own sentence for an
    -- outcome sits right behind its event; the screen says the cart's line in
    -- its place and not both.)
    local function linesMatch(rec)
      local want = countsOf(rec.obey, function(ob) return tokenKey(ob.token) end)
      local got = countsOf(rec.said, lineKey)
      local same = true
      for _, row in ipairs(OBEY_LINES) do
        if (want[row.key] or 0) ~= (got[row.key] or 0) then same = false end
      end
      return same, ("events: %s; said: %s"):format(describe(want), describe(got)), want
    end

    local function obeyChecks(rec, classic)
      local L = rec.label
      check(rec.facts ~= nil and rec.facts.level == 50 and rec.facts.traded == true,
            L .. ": the referee's lead is the L50 monster, marked traded",
            rec.facts and ("L%s traded=%s"):format(tostring(rec.facts.level), tostring(rec.facts.traded)))
      check(rec.facts ~= nil and rec.facts.foeTraded == nil, L .. ": the wild foe is not marked traded")
      check(rec.facts ~= nil and rec.facts.unfateful == nil,
            L .. ": and the lead is an ordinary species -- no `unfateful` mark, so the ordinary level caps apply")
      check(rec.facts ~= nil and rec.facts.playerBadges == "" and rec.facts.rules,
            L .. ": and the lead holds no badges, with the badge rules on", rec.facts and rec.facts.playerBadges)
      check(rec.classic == classic, L .. ": the screen is on " .. (classic and "CLASSIC BATTLE UI" or "the arena"),
            tostring(rec.classic))
      check(#rec.obey >= 1, L .. ": the referee emitted an `obey` event for a disobedient lead",
            ("%d event(s)"):format(#rec.obey))
      local onlyPlayer = true
      for _, ob in ipairs(rec.obey) do
        if ob.side ~= "a" then onlyPlayer = false end
      end
      check(onlyPlayer, L .. ": every `obey` is the player's own seat -- the foe never disobeys")
      local same, said = linesMatch(rec)
      check(same, L .. ": the screen said the cart's line once for each outcome, and no other", said)
      check(rec.shot == true, L .. ": a disobedience line was on the screen and photographed",
            rec.shownLine)
      check(rec.result == "win", L .. ": the fight still ends normally (a win)", tostring(rec.result))
      check(#rec.errors == 0, L .. ": no referee call failed under the watch", rec.errors[1])
    end

    if wants("obey-arena") then
      local rec = obeyUntilDisobeyed({ label = "obey arena", classic = false, shotTag = "obey-arena" })
      if rec then
        obeyChecks(rec, false)
        log("obey arena: lines said", (table.concat(rec.said, " | "):gsub("%s+", " ")))
      end
    end

    if wants("obey-classic") then
      local rec = obeyUntilDisobeyed({ label = "obey classic", classic = true, shotTag = "obey-classic" })
      if rec then
        obeyChecks(rec, true)
        log("obey classic: lines said", (table.concat(rec.said, " | "):gsub("%s+", " ")))
      end
    end

    if wants("obey-badge8") then
      local spec = { label = "obey badge 8", badges = { 8 }, classic = false, seed = OBEY_SEEDS[1] }
      local rec = obeyFight(spec)
      if rec then
        local L = rec.label
        check(rec.facts ~= nil and rec.facts.traded == true and rec.facts.level == 50,
              L .. ": the lead is still the traded L50 monster",
              rec.facts and ("L%s traded=%s"):format(tostring(rec.facts.level), tostring(rec.facts.traded)))
        check(rec.facts ~= nil and rec.facts.playerBadges == "8",
              L .. ": and holds badge 8", rec.facts and rec.facts.playerBadges)
        check(#rec.obey == 0, L .. ": with badge 8 it never disobeys: no `obey` event in the fight",
              ("%d event(s)"):format(#rec.obey))
        check(countsOf(rec.said, lineKey) ~= nil and next(countsOf(rec.said, lineKey)) == nil,
              L .. ": and the screen said none of the disobedience lines",
              describe(countsOf(rec.said, lineKey)))
        check(firstAnimSide(rec) == "a", L .. ": the lead moved first and attacked", tostring(firstAnimSide(rec)))
        check(rec.result == "win", L .. ": the fight ends in a win", tostring(rec.result))
      end
    end

    -- Every way a traded monster can refuse, as far as one fight list reaches:
    -- a lead that knows two moves, so a called move is reachable, fought on a
    -- run of seeds until the self-hit, the nap, the called move and a loafing
    -- line have each been through the screen.  (Ignoring orders while asleep
    -- needs SNORE or SLEEP TALK picked while asleep; this pilot picks move 1
    -- and never builds that.)  Every disobedient fight must say the cart's line
    -- once for each outcome and still end in a win.
    if wants("obey-outcomes") then
      local shotKeys, seen, fights = {}, {}, 0
      local function covered()
        return seen.wont and seen.nap and seen.ignored
          and (seen.loafing or seen.turned or seen.pretend)
      end
      for i = 1, 40 do
        local seedValue = 1000 + i * 37
        local rec = obeyFight({ label = ("obey outcomes (seed %d)"):format(seedValue), seed = seedValue,
          classic = false, moves = { SWIFT, TACKLE }, shotEach = shotKeys })
        if not rec then break end
        fights = fights + 1
        local same, said, want = linesMatch(rec)
        check(same and rec.result == "win" and #rec.errors == 0,
              rec.label .. ": every outcome said once in the cart's words, and the fight ends in a win",
              ("%s; result %s"):format(said, tostring(rec.result)))
        for key, n in pairs(want) do seen[key] = (seen[key] or 0) + n end
        if covered() then break end
      end
      log("obey outcomes: reached", describe(seen), "in", fights, "fight(s)")
      check(seen.wont ~= nil, "obey outcomes: \"won't obey!\" (the self-hit's line) was reached and said")
      check(seen.nap ~= nil, "obey outcomes: \"began to nap!\" was reached and said")
      check(seen.ignored ~= nil, "obey outcomes: \"ignored orders!\" (a called move) was reached and said")
      check(seen.loafing ~= nil or seen.turned ~= nil or seen.pretend ~= nil,
            "obey outcomes: a loafing line (loafing / turned away / pretended) was reached and said")
    end

    -- ---- the asleep case, deterministically
    --
    -- pret IsMonDisobedient: a MEW (or DEOXYS) that is not event-legal skips the
    -- traded / badge ladder and keeps an obedience level of 0, so the first roll,
    -- `(level + 0) * rnd >> 8 < 0`, can never let it obey -- and with it asleep
    -- and SNORE chosen, the next test is BattleScript_IgnoresWhileAsleep.  The
    -- sleep check runs first (AtkCanceller_UnableToUseMove: the counter ticks,
    -- 5 -> 4, and SNORE goes through asleep), so turn 1 reaches the token on any
    -- seed: two seeds, the same token.  The OT is the player's own -- the
    -- `unfateful` mark (the engine mon's `fatefulEncounter` explicitly false,
    -- Sheet3 `unfatefulOf`) is the only fact that puts it under the rule.  Then
    -- RUN: a monster that never obeys never ends a fight, and the MEW is the
    -- faster, so the escape is certain.
    if wants("obey-asleep") then
      local SNORE, POUND = moveId("MOVE_SNORE"), moveId("MOVE_POUND")
      local MEW = H.g3Species(game, "MEW")
      if not (SNORE and POUND and MEW) then
        skip("obey-asleep", "this cart's tables have no MEW / SNORE / POUND")
      else
        for i, seedValue in ipairs({ 7, 23 }) do
          local L = ("obey asleep (seed %d)"):format(seedValue)
          settle()
          setBadges({})
          setOption("classicui", false)
          local mon = seed("MEW", 30)
          if not check(mon ~= nil, L .. ": a MEW was seeded") then break end
          pinMove(mon, { SNORE, POUND })
          pinStats(mon, { atk = 80, def = 60, spe = 200, spa = 80, spd = 60, hp = 300 })
          mon.fatefulEncounter = false
          mon.status, mon.sleep = "SLP", 5
          local foe = foeMon(5, { atk = 30, def = 30, spe = 20, spa = 30, spd = 30, hp = 30 }, TACKLE)
          if not check(foe ~= nil, L .. ": the wild foe was built") then break end
          local before = solo.seedFn
          solo.seedFn = function() return seedValue end
          local result
          local took = solo:fromGen3Encounter(game, wildOf(WILD, 5),
            { party = { foe }, done = function(r) result = r end })
          solo.seedFn = before
          if not check(took and solo.sim ~= nil and fight() ~= nil, L .. ": the fight was taken") then break end
          local sim, f = solo.sim, fight()
          local rec = watch(sim, f)
          check(awaitChoose(60, "the asleep MEW's command grid"), L .. ": the command grid opens")
          local pf, ff = sim.byId.solo_player, sim.byId.solo_foe
          local pb, fb = pf and pf.b, ff and ff.b
          local facts = (pb and fb) and {
            species = pb.mon.speciesNum, unfateful = pb.mon.unfateful, traded = pb.mon.traded,
            status = pb.mon.status, sleepTurns = pb.mon.sleepTurns, rules = pf.badgeRules == true,
            speedP = sim:_speedOf(pb), speedF = sim:_speedOf(fb), mode = sim.mode,
          } or nil
          check(facts ~= nil and facts.species == MEW and facts.unfateful == true,
                L .. ": the referee's lead is the MEW, marked `unfateful`",
                facts and ("species %s unfateful=%s"):format(tostring(facts.species), tostring(facts.unfateful)))
          check(facts ~= nil and facts.traded == nil,
                L .. ": and not traded -- its OT is the player's, so the Mew rule alone applies")
          check(facts ~= nil and facts.status == "SLP" and (tonumber(facts.sleepTurns) or 0) > 1,
                L .. ": and asleep with turns to go, as the save's party monster is",
                facts and ("%s / %s"):format(tostring(facts.status), tostring(facts.sleepTurns)))
          check(facts ~= nil and facts.rules and facts.mode == "wild",
                L .. ": a wild fight, the badge rules on for the player's side",
                facts and tostring(facts.mode))
          check(facts ~= nil and facts.speedP > facts.speedF,
                L .. ": the MEW is the faster (the RUN after is certain)",
                facts and ("%s v %s"):format(tostring(facts.speedP), tostring(facts.speedF)))

          -- turn 1: FIGHT, SNORE (slot 1); every menu after that: RUN
          local commanded, shotDone = 0, false
          H.waitSeconds(game, function()
            local g = fight()
            if not g then return true end
            if not shotDone and #rec.obey > 0 and lineKey(g.shown or "") == "asleep" then
              shotDone = true
              rec.shownLine = flat(g.shown or "")
              U.wait(30)
              if i == 1 then shot("obey-asleep") end
            end
            if g.phase == "choose" then
              commanded = commanded + 1
              if commanded == 1 then fightWith(1) else command("RUN") end
            else
              nudge()
            end
            return fight() == nil
          end, 240, "the asleep MEW's fight to end")
          rec.result = result
          settle()

          local tokens = {}
          for _, ob in ipairs(rec.obey) do tokens[#tokens + 1] = tostring(ob.side) .. ":" .. tostring(ob.token) end
          check(#rec.obey == 1 and rec.obey[1].token == "ignores_asleep" and rec.obey[1].side == "a",
                L .. ": the one `obey` of the fight is the player's `ignores_asleep`, on the SNORE turn",
                table.concat(tokens, ","))
          local same, said = linesMatch(rec)
          check(same, L .. ": the screen said the cart's \"ignored orders while asleep\" once, and no other line", said)
          check(shotDone, L .. ": the line was on the screen", rec.shownLine)
          check(firstOf(rec.events, function(e)
                  return e.t == "anim" and e.side == "a"
                    and (e.text == "SNORE" or e.text == ("MOVE_" .. tostring(SNORE)) or tonumber(e.text) == SNORE)
                end) == nil,
                L .. ": and SNORE never ran -- the player's move did not play")
          check(#rec.errors == 0, L .. ": no referee call failed under the watch", rec.errors[1])
          check(rec.result == "run", L .. ": the fight then ends on the RUN", tostring(rec.result))
        end
      end
    end

    -- ---- the computer's THIEF takes nothing
    --
    -- pokeemerald Cmd_tryswapitems / MOVE_EFFECT_STEAL_ITEM and pokefirered's:
    -- outside a link battle the opponent's side never steals (the item would
    -- be gone from the player's party for good, so the cart forbids it).  The
    -- foe here knows only THIEF and is the faster, so it hits before the
    -- player's knockout can stop it: the hit lands, nothing changes hands.
    if wants("theft-wild") then
      local THIEF = moveId("MOVE_THIEF")
      local NUGGET = H.g3ItemId(game, "NUGGET")
      if not (THIEF and NUGGET) then
        skip("theft-wild", "this cart's tables have no THIEF / NUGGET")
      else
        local L = "theft wild"
        settle()
        setBadges({})
        setOption("classicui", false)
        local mon = seed(STARTER, 30)
        local foe = foeMon(5, { atk = 30, def = 30, spe = 150, spa = 30, spd = 30, hp = 60 }, THIEF)
        if check(mon ~= nil and foe ~= nil, L .. ": the lead and the wild THIEF user were built") then
          pinMove(mon, TACKLE)
          pinStats(mon, { atk = 80, def = 60, spe = 50, spa = 80, spd = 60, hp = 300 })
          -- both of the engine mon's spellings (Party.applyBattleFields keeps
          -- `item` and `heldItem`; Sheet3 reads `heldItem` first)
          mon.item, mon.heldItem = NUGGET, NUGGET
          local before = solo.seedFn
          solo.seedFn = function() return 4242 end
          local result
          local took = solo:fromGen3Encounter(game, wildOf(WILD, 5),
            { party = { foe }, done = function(r) result = r end })
          solo.seedFn = before
          if check(took and solo.sim ~= nil and fight() ~= nil, L .. ": the fight was taken") then
            local sim, f = solo.sim, fight()
            local rec = watch(sim, f)
            check(awaitChoose(60, "the THIEF fight's command grid"), L .. ": the command grid opens")
            local pf, ff = sim.byId.solo_player, sim.byId.solo_foe
            local pb, fb = pf and pf.b, ff and ff.b
            check(sim.mode == "wild" and pf and pf.badgeRules == true and ff and ff.badgeRules ~= true,
                  L .. ": a wild fight -- side b is the computer", tostring(sim.mode))
            check(pb ~= nil and tonumber(pb.mon.heldItem) == NUGGET and fb ~= nil
                    and (tonumber(fb.mon.heldItem) or 0) == 0,
                  L .. ": the player's battler holds the NUGGET, the foe holds nothing",
                  pb and fb and ("%s / %s"):format(tostring(pb.mon.heldItem), tostring(fb.mon.heldItem)))
            check(pb ~= nil and fb ~= nil and sim:_speedOf(fb) > sim:_speedOf(pb),
                  L .. ": the foe is the faster, so its THIEF lands first")
            local shotDone = false
            play(function(g)
              if not shotDone and flat(g.shown or ""):find("thief", 1, true) then
                shotDone = true
                U.wait(30)
                shot("theft-wild")
              end
            end, 240, "the THIEF fight to end")
            rec.result = result
            settle()
            -- An `anim` names the move by its sheet token (Sheet3.tokenFor:
            -- the cart's MOVE_ constant without the prefix, else MOVE_<n>).
            local function isThief(text)
              return text == "THIEF" or text == ("MOVE_" .. tostring(THIEF)) or tonumber(text) == THIEF
            end
            local thiefs, hitAfter = 0, false
            for idx, e in ipairs(rec.events) do
              if e.t == "anim" and e.side == "b" and isThief(e.text) then
                thiefs = thiefs + 1
                for j = idx + 1, #rec.events do
                  local n = rec.events[j]
                  if n.t == "anim" then break end
                  if n.t == "damage" and n.side == "a" then hitAfter = true end
                end
              end
            end
            check(thiefs >= 1, L .. ": the foe used THIEF", ("%d time(s)"):format(thiefs))
            check(hitAfter, L .. ": and it hit the player's monster")
            local helds = 0
            for _, e in ipairs(rec.events) do
              if e.t == "held" then helds = helds + 1 end
            end
            check(helds == 0, L .. ": the referee emitted no `held` event -- nothing was stolen",
                  ("%d event(s)"):format(helds))
            local stole = false
            for _, line in ipairs(rec.said) do
              if flat(line):find("stole", 1, true) then stole = true end
            end
            check(not stole, L .. ": and the screen said no \"stole\" line")
            local after = lead()
            check(after ~= nil and tonumber(after.heldItem) == NUGGET and tonumber(after.item) == NUGGET,
                  L .. ": the party monster still holds the NUGGET after the fight",
                  after and ("heldItem %s item %s"):format(tostring(after.heldItem), tostring(after.item)))
            check(#rec.errors == 0, L .. ": no referee call failed under the watch", rec.errors[1])
            check(rec.result == "win", L .. ": the fight ends in a win", tostring(rec.result))
          end
        end
      end
    end

    setBadges({})
    setOption("classicui", false)
  end

  if not legOn("singles") then
    doubleLegs()
    badgeLegs()
    return
  end

  -- Two real trainers from this cart's own book: an easy single (a party of
  -- one, low level) and a hard one (the highest last level of a single
  -- battle).  Ids only -- nothing here is asserted about what they hold.
  local easyId, hardId
  do
    local pack = Trainers.pack() or {}
    local easyLevel, hardLevel = 999, -1
    for id, row in pairs(pack.trainers or {}) do
      local tid = tonumber(id)
      local p = type(row) == "table" and row.party or nil
      local named = type(row) == "table" and type(row.name) == "string" and row.name ~= ""
      if tid and tid > 0 and named and type(p) == "table" and #p >= 1 and not row.doubleBattle then
        local last = tonumber(p[#p].level) or 0
        local class = tonumber(row.class) or 0
        -- FireRed / LeafGreen keep Ruby's trainer table under their own
        -- (classes below YOUNGSTER's 57 are its unused leftovers); Emerald's
        -- whole table is its own.  The rival classes, and FireRed's PLAYER
        -- class (the link / Union Room stand-ins), are left alone.
        local plain = (emerald or (class >= 57 and class ~= 98)) and class ~= 81
          and class ~= 89 and class ~= 90
        -- a YOUNGSTER when the book has one (both carts do), the lowest
        -- party-of-one otherwise
        local youngster = type(row.className) == "string" and row.className:upper() == "YOUNGSTER"
          or (pack.classNames and tostring(pack.classNames[class]):upper() == "YOUNGSTER")
        local score = last - (youngster and 1000 or 0)
        if plain and #p == 1 and last >= 3 and score < easyLevel then easyId, easyLevel = tid, score end
        if plain and last > hardLevel then hardId, hardLevel = tid, last end
      end
    end
    log(("trainers: easy=%s (score %s) hard=%s (L%s)"):format(tostring(easyId), tostring(easyLevel),
      tostring(hardId), tostring(hardLevel)))
  end

  -- ------------------------------------------------------------------
  -- G1. SOLO BATTLES off: a real grass encounter is the cart's own battle
  -- ------------------------------------------------------------------

  -- A cell of tall grass on the grass map with grass above and below it, so
  -- walking up and down keeps rolling the step encounter (the engine's own
  -- game3_cut_grass driver finds its patch the same way).
  local function grassCell()
    local def = game.data and game.data.maps and game.data.maps[GRASS_MAP]
    local L = type(def) == "table" and def.midLayout or nil
    if not L then return nil end
    if Map.current ~= GRASS_MAP then H.g3Teleport(game, GRASS_MAP, 1, 1, "down") end
    local function grass(x, y)
      local ok, g = pcall(Collision.isGrass, x, y)
      return ok and g and not Objects.at(x, y)
    end
    for y = 2, (tonumber(L.height) or 0) - 3 do
      for x = 1, (tonumber(L.width) or 0) - 2 do
        if grass(x, y) and grass(x, y - 1) and grass(x, y + 1) then return x, y end
      end
    end
    return nil
  end

  -- Stand in the grass map (a whiteout earlier in the run may have sent the
  -- player home; the loss leg measures its own warp from here).
  local function toGrass()
    local x, y = grassCell()
    if x then H.g3Teleport(game, GRASS_MAP, x, y, "down") end
    return x ~= nil
  end

  -- Walk up and down in the grass until something takes the step: the mod's
  -- screen (solo.fight) or the cart's own battle.
  local function walkForEncounter(seconds)
    local x, y = grassCell()
    if not x then return nil, "no tall grass on " .. GRASS_MAP end
    H.g3Teleport(game, GRASS_MAP, x, y, "down")
    local dirs = { "down", "up" }
    local i = 0
    local found = nil
    H.waitSeconds(game, function()
      if solo.fight then found = "solo" return true end
      if Battle.isActive() then found = "engine" return true end
      if not H.g3Idle(game) then nudge() return false end
      i = i + 1
      U.hold(game, dirs[(i % 2) + 1], 16)
      U.wait(2)
      return false
    end, seconds or 90, "a step encounter in the grass")
    return found
  end

  -- End the cart's own battle without fighting it (the driver is not here to
  -- test the engine's battle).
  local function endEngineBattle()
    pcall(BattleBridge.finishPending, "run")
    H.waitSeconds(game, function() return not Battle.isActive() end, 20, "the cart's battle to end")
    settle()
  end

  setOption(env.OPTION_KEY, false)
  seed(STARTER, 40)
  check(not solo:isOn(), "SOLO BATTLES reads off, as the runner seeded it")
  do
    local found, why = walkForEncounter(90)
    if found == nil then
      skip("the SOLO-off grass leg", tostring(why or "no encounter in time"))
    else
      check(found == "engine", "with SOLO BATTLES off the cart runs its own battle", tostring(found))
      -- past the transition, onto the cart's own command menu
      H.waitSeconds(game, function()
        local ok, st = pcall(Battle.getState)
        return ok and type(st) == "table" and Battle.isActive() and st.enemy ~= nil
      end, 10, "the cart's battle to come up")
      U.wait(150)
      shot("off-cart-battle")
      if found == "engine" then endEngineBattle() end
    end
  end

  setOption(env.OPTION_KEY, true)
  check(solo:isOn(), "SOLO BATTLES reads on once the row is flipped")

  -- ------------------------------------------------------------------
  -- G2. a wild fight won on the arena: commands, move select, damage, EXP
  -- ------------------------------------------------------------------
  do
    settle()
    local mon = seed(STARTER, 40)
    local expBefore, ppBefore = tonumber(mon and mon.exp) or 0, ppSum(mon)
    local result
    local took = solo:fromGen3Encounter(game, wildOf(WILD, 4), { done = function(r) result = r end })
    check(took, "the entry takes a wild encounter")
    check(took and fight() ~= nil and fight().mmoBattle and H.g3Top(game) == fight(),
          "the mod's battle screen is the game3 layer on top")
    if took then
      check(awaitChoose(60, "the wild command grid"), "the command grid opens")
      shot("wild-command")
      local seenDamage = false
      fightWith(bestMove(fight()), function() shot("wild-move-select") end)
      H.waitSeconds(game, function()
        local f = fight()
        if not f then return true end
        if f.draining or f.hitHold then
          if not seenDamage then seenDamage = true; U.wait(6); shot("wild-damage") end
          return true
        end
        return false
      end, 20, "the hit to land")
      check(seenDamage, "a damaging turn plays on the arena")
      local sawExpLine = false
      H.waitSeconds(game, function()
        local f = fight()
        if not f then return true end
        if f.phase == "choose" then fightWith(bestMove(f)) return false end
        if not sawExpLine and shown():find("EXP", 1, true) then
          sawExpLine = true
          shot("wild-exp")
        end
        nudge()
        return false
      end, 120, "the wild fight to end")
      check(sawExpLine, "the cart's 'gained EXP. Points' line was on screen")
      local sawExp = (tonumber(lead().exp) or 0) > expBefore
      check(result == "win", "done('win') for a knockout", tostring(result))
      check(sawExp, "the knockout paid EXP onto the session mon",
            ("%d -> %d"):format(expBefore, tonumber(lead().exp) or 0))
      check(ppSum(lead()) < ppBefore, "the PP the fight spent came home (mon.pp[])",
            ("%d -> %d"):format(ppBefore, ppSum(lead())))
      settle()
      shot("wild-after")
    end
  end

  -- ------------------------------------------------------------------
  -- G3. CLASSIC BATTLE UI: the GBA page, and RUN from a slower wild mon
  -- ------------------------------------------------------------------
  do
    setOption("classicui", true)
    seed(STARTER, 40)
    local result
    local took = solo:fromGen3Encounter(game, wildOf(WILD, 3), { done = function(r) result = r end })
    check(took, "classic: taken")
    if took then
      check(fight().classicUi == true, "classic: the screen latched CLASSIC BATTLE UI")
      check(awaitChoose(60, "the classic command grid"), "classic: the command grid opens")
      shot("classic-command")
      local f = fight()
      f.commandIndex = 1
      U.tap(game, "a"); U.wait(8)
      if fight() and fight().phase == "move" then shot("classic-move-select") end
      U.tap(game, "b"); U.wait(6)
      command("RUN")
      H.waitSeconds(game, function() return said("Got away") or fight() == nil end, 10, "the escape line")
      shot("classic-run-away")
      driveToEnd(function() command("RUN") end, 60)
      check(result == "run", "classic: a faster runner gets away -- done('run')", tostring(result))
      settle()
    end
    setOption("classicui", false)
  end

  -- ------------------------------------------------------------------
  -- G4. a catch: the BAG, a MASTER BALL, "Gotcha!", the party and the dex
  -- ------------------------------------------------------------------
  do
    seed(STARTER, 40)
    local ball = H.g3ItemId(game, "MASTER_BALL")
    H.g3GiveItem(game, "MASTER_BALL", 1)
    local ballsBefore = Bag.get(session().bag, ball) or 0
    local species = H.g3Species(game, WILD)
    local partyBefore = #party()
    local result
    local took = solo:fromGen3Encounter(game, wildOf(WILD, 4), { done = function(r) result = r end })
    check(took, "catch: taken")
    if took then
      check(awaitChoose(60, "the grid before the ball"), "catch: the command grid opens")
      command("ITEM")
      local f = fight()
      if f and f.phase == "item" then
        local rows = f:usableItems()
        for i, row in ipairs(rows) do if tonumber(row.id) == ball then f.itemIndex = i end end
        shot("catch-bag")
        U.tap(game, "a"); U.wait(10)
      end
      local gotcha = H.waitSeconds(game, function()
        if shown():find("Gotcha", 1, true) or shown():find("caught", 1, true) then return true end
        local g = fight()
        if g and g.phase ~= "choose" then U.tap(game, "a"); U.wait(4) end
        return false
      end, 30, "Gotcha!")
      check(gotcha, "catch: 'Gotcha!'")
      shot("catch-gotcha")
      local sawNaming = false
      H.waitSeconds(game, function()
        if layerId() == "naming" then
          if not sawNaming then sawNaming = true; U.wait(20); shot("catch-nickname") end
        end
        if fight() == nil and layerId() ~= "naming" then return true end
        nudge()
        return false
      end, 60, "the catch to finish")
      check(sawNaming, "catch: the nickname grid was offered")
      check(result == "caught", "catch: done('caught')", tostring(result))
      check(#party() == partyBefore + 1, "catch: the party grew by one",
            ("%d -> %d"):format(partyBefore, #party()))
      local caught = party()[#party()]
      check(caught and tonumber(caught.species) == species, "catch: it is the wild mon")
      check(caught and tonumber(caught.pokeball) == ball, "catch: in a MASTER BALL")
      check(caught and caught.otName == session().name, "catch: the catcher is its OT")
      local Dex = require("src.core.game3.dex")
      local okDex, isCaught = pcall(Dex.isCaught, session().dex, species)
      check(okDex and isCaught, "catch: the dex has it caught")
      check((Bag.get(session().bag, ball) or 0) < ballsBefore, "catch: the ball was spent")
      settle()
    end
  end

  -- ------------------------------------------------------------------
  -- G5. RUN refused by the roll: a slow runner and a fast wild mon
  -- ------------------------------------------------------------------
  do
    seed(STARTER, 40)
    local sawCant = false
    for attempt = 1, 6 do
      local result
      local took = solo:fromGen3Encounter(game, wildOf(emerald and "NINJASK" or "ELECTRODE",
        emerald and 30 or 60),
        { done = function(r) result = r end })
      if not took then break end
      awaitChoose(60, "the grid before RUN")
      command("RUN")
      H.waitSeconds(game, function()
        if said("Can't escape") then return true end
        return fight() == nil or said("Got away")
      end, 15, "the escape roll")
      if said("Can't escape") then
        sawCant = true
        shot("run-cant-escape")
      end
      -- leave either way: RUN until it works (the odds climb each try), else
      -- fight on; a loss here is a wild whiteout, which is fine too.
      driveToEnd(function() command("RUN") end, 120)
      settle()
      seed(STARTER, 40)
      log(("run attempt %d: result=%s"):format(attempt, tostring(result)))
      if sawCant then break end
    end
    check(sawCant, "a slower runner is refused by the roll: \"Can't escape!\"")
  end

  -- ------------------------------------------------------------------
  -- G6. a trainer beaten: the intro, the trainer on the arena, the prize
  -- ------------------------------------------------------------------
  if not easyId then
    skip("the trainer-win leg", "no single easy trainer in this cart's book")
  else
    settle()
    toGrass()
    seed(STARTER, 40)
    local moneyBefore = tonumber(session().money) or 0
    local expBefore = tonumber(lead().exp) or 0
    local result
    local took = solo:fromGen3Trainer(game, easyId, { trainerId = easyId, done = function(r) result = r end })
    check(took, "trainer: the entry takes trainer " .. tostring(easyId))
    if took then
      -- The trainer's own AI, in this cart's own bit layout: FireRed numbers
      -- TRY_TO_FAINT 2, Emerald 1 (the engine battle profile's aiFlagBits).
      local brain = solo.brain
      check(brain ~= nil and brain.generation == 3, "trainer: the Gen 3 brain answers for them")
      local bits = brain and brain.aiBits or {}
      check(bits.TRY_TO_FAINT == (emerald and 1 or 2),
            "trainer: the brain reads the cart's own AI flag layout",
            "TRY_TO_FAINT=" .. tostring(bits.TRY_TO_FAINT))
      H.waitSeconds(game, function() return said("would like") end, 10, "the trainer's intro")
      shot("trainer-intro")
      check(awaitChoose(60, "the trainer command grid"), "trainer: the command grid opens")
      shot("trainer-command")
      local sawMoney = false
      H.waitSeconds(game, function()
        local f = fight()
        if not f then return true end
        if f.phase == "choose" then fightWith(bestMove(f)) return false end
        if not sawMoney and (shown():find("got", 1, true) and shown():find("winning", 1, true)
            or shown():find("\194\165", 1, true)) then
          sawMoney = true
          shot("trainer-prize")
        end
        nudge()
        return false
      end, 240, "the trainer fight to end")
      check(result == "win", "trainer: done('win') -- what sets the trainer flag", tostring(result))
      check((tonumber(session().money) or 0) > moneyBefore, "trainer: the prize was paid",
            ("%d -> %d"):format(moneyBefore, tonumber(session().money) or 0))
      check((tonumber(lead().exp) or 0) > expBefore, "trainer: its mons paid EXP")
      check(sawMoney, "trainer: the money line was on screen")
      settle()
      shot("trainer-after")
    end
  end

  -- ------------------------------------------------------------------
  -- G7. a trainer lost to: the lost lines, the whiteout, the heal location
  -- ------------------------------------------------------------------
  if not (hardId or easyId) then
    skip("the loss leg", "no trainer to lose to")
  else
    settle()
    toGrass()
    local mon = seed(emerald and "WURMPLE" or "CATERPIE", 3)
    if mon then mon.hp = 1 end
    session().money = 3000
    local mapBefore = Map.current
    local result
    local took = solo:fromGen3Trainer(game, hardId or easyId,
      { trainerId = hardId or easyId, done = function(r) result = r end })
    check(took, "loss: taken")
    if took then
      awaitChoose(60, "the grid before the loss")
      local sawLost = false
      H.waitSeconds(game, function()
        local f = fight()
        if not f then return true end
        if f.phase == "choose" then fightWith(1) return false end
        local text = shown()
        if not sawLost and (text:find("out of", 1, true) or text:find("against", 1, true)
            or text:find("paid", 1, true) or text:find("whited", 1, true)
            or text:find("panicked", 1, true)) then
          sawLost = true
          shot("loss-lines")
        end
        nudge()
        return false
      end, 180, "the loss to end")
      check(sawLost, "loss: the cart's lost lines were on screen")
      check(result == "lose", "loss: done('lose')", tostring(result))
      settle()
      U.wait(30)
      shot("loss-respawn")
      check(Map.current ~= mapBefore, "loss: the whiteout warped to the heal location",
            tostring(mapBefore) .. " -> " .. tostring(Map.current))
      check((tonumber(lead().hp) or 0) == (tonumber(lead().maxHp) or -1), "loss: the party was healed")
      check((tonumber(session().money) or 0) < 3000, "loss: the whiteout took money",
            tostring(session().money))
    end
  end

  -- The id of a move in this cart's own table, by pret name.
  local function moveId(name) return H.g3Const(game, "moves", name) end

  -- One lead that knows only `move` (full PP), at `level`.
  local function seedWith(species, level, move)
    local mon = seed(species, level)
    if not (mon and move) then return mon end
    local Moves = require("src.core.game3.battle.moves")
    local okP, row = pcall(Moves.get, move)
    local pp = (okP and type(row) == "table" and tonumber(row.pp)) or 10
    mon.moves, mon.pp, mon.maxPp = { move }, { pp }, { pp }
    return mon
  end

  local Natives = require("src.core.game3.scripting.natives")
  local OUTCOME = Natives.B_OUTCOME or {}

  -- ------------------------------------------------------------------
  -- G9. PAY DAY: the coins land once, with the cart's line
  -- ------------------------------------------------------------------
  do
    settle()
    toGrass()
    local payDay = moveId("MOVE_PAY_DAY")
    local mon = seedWith(STARTER, 40, payDay)
    session().money = 3000
    local result
    local took = payDay and mon and solo:fromGen3Encounter(game, wildOf(WILD, 3),
      { done = function(r) result = r end })
    check(took, "payday: a wild fight with only PAY DAY known")
    if took then
      awaitChoose(60, "the PAY DAY grid")
      local sawCoins, sawLine = false, false
      H.waitSeconds(game, function()
        local f = fight()
        if not f then return true end
        if f.phase == "choose" then fightWith(1) return false end
        if not sawCoins and shown():find("Coins scattered", 1, true) then
          sawCoins = true
          shot("payday-scatter")
        end
        if not sawLine and shown():find("picked up", 1, true) then
          sawLine = true
          shot("payday-picked-up")
        end
        nudge()
        return false
      end, 120, "the PAY DAY fight to end")
      check(result == "win", "payday: won", tostring(result))
      check(sawCoins, "payday: 'Coins scattered everywhere!'")
      check(sawLine, "payday: 'picked up' the coins, on screen")
      check((tonumber(session().money) or 0) == 3000 + 40 * 5,
            "payday: level x 5 coins paid, once", tostring(session().money))
      settle()
    end
  end

  -- ------------------------------------------------------------------
  -- G10. a trainer draw: both last monsters down at once (SELFDESTRUCT)
  -- ------------------------------------------------------------------
  --
  -- The cart counts a draw as a defeat (IsPlayerDefeated), so the trainer
  -- script is answered "lose" -- the trainerbattle opcode sets the trainer
  -- flag (and runs the beaten script, the badge, the TM) for anything else --
  -- and a player with nothing standing whites out.  No prize.
  if not easyId then
    skip("the trainer draw leg", "no single easy trainer in this cart's book")
  else
    settle()
    toGrass()
    local boom = moveId("MOVE_SELF_DESTRUCT")
    local mon = seedWith(STARTER, 60, boom)
    session().money = 3000
    local mapBefore = Map.current
    local result
    local took = boom and mon and solo:fromGen3Trainer(game, easyId,
      { trainerId = easyId, done = function(r) result = r end })
    check(took, "draw: taken")
    if took then
      awaitChoose(60, "the SELFDESTRUCT grid")
      shot("draw-command")
      local sawBoom = false
      H.waitSeconds(game, function()
        local f = fight()
        if not f then return true end
        if f.phase == "choose" then fightWith(1) return false end
        if not sawBoom and shown():find("SELFDESTRUCT", 1, true) then
          sawBoom = true
          shot("draw-selfdestruct")
        end
        nudge()
        return false
      end, 120, "the drawn trainer fight to end")
      check(result == "lose", "draw: the trainer script hears 'lose' -- no trainer flag, "
        .. "no beaten script", tostring(result))
      check(session().battleOutcome ~= OUTCOME.WON, "draw: the save's outcome is not a win",
            tostring(session().battleOutcome))
      check((tonumber(session().money) or 0) <= 3000, "draw: no prize",
            tostring(session().money))
      settle()
      U.wait(30)
      shot("draw-after")
      check(Map.current ~= mapBefore, "draw: with nothing standing, the player whites out",
            tostring(mapBefore) .. " -> " .. tostring(Map.current))
    end
  end

  -- A draw the player is still standing after -- the one the cart has no
  -- word for (here: the referee's own clock, forced) -- is never handed to
  -- the trainer script at all ("lose" would run the bytes after the
  -- trainerbattle command); a waiting script is halted instead.  The save
  -- says B_OUTCOME_DREW, and nobody is whited out.
  if easyId then
    settle()
    toGrass()
    seed(STARTER, 40)
    session().money = 3000
    local mapBefore = Map.current
    local result
    local took = solo:fromGen3Trainer(game, easyId, { trainerId = easyId, done = function(r) result = r end })
    check(took, "standing draw: taken")
    if took then
      awaitChoose(60, "the grid before the called draw")
      solo.sim:_finish("draw", nil, nil, "timeout")
      H.waitSeconds(game, function()
        local f = fight()
        return f == nil or (f.phase == "over" and shown() ~= "")
      end, 20, "the draw's ending")
      shot("standing-draw")
      driveToEnd(function() fightWith(1) end, 60)
      check(result == nil, "standing draw: the trainer script is never answered", tostring(result))
      local Space = require("src.core.game3.scripting.space")
      local vm = Space and Space.vm
      check(not (vm and vm.isRunning and vm:isRunning()), "standing draw: no script is left running")
      check(session().battleOutcome == OUTCOME.DREW, "standing draw: B_OUTCOME_DREW on the save",
            tostring(session().battleOutcome))
      check((tonumber(session().money) or 0) == 3000, "standing draw: no prize, no loss",
            tostring(session().money))
      settle()
      check(Map.current == mapBefore, "standing draw: nobody standing is whited out",
            tostring(mapBefore) .. " -> " .. tostring(Map.current))
    end
  end

  -- The same standing draw against a real trainer, met the cart's way (seen,
  -- walked up to, its intro said, its trainerbattle command waiting in the
  -- script VM): the script is halted where it waits -- no flag, and none of
  -- the bytes after the command (the trainer's post-battle words) run.
  do
    local stage = (H.G3_STAGE[VERSION] or H.G3_STAGE.firered).battle
    settle()
    seed(STARTER, 40)
    session().money = 3000
    H.g3Teleport(game, stage.trainerMap, 1, 1, "down")
    local eo = H.g3ObjectById(stage.trainerLid)
    local sx, sy, dir
    if eo then sx, sy, dir = H.g3SightApproach(eo) end
    if not sx then
      skip("the real trainer draw leg", "no trainer with a line of sight on " .. tostring(stage.trainerMap))
    else
      H.g3ClearTrainer(eo)
      local placed = H.g3Teleport(game, stage.trainerMap, sx, sy, dir)
      check(placed, "real draw: standing just outside the trainer's line of sight")
      local met = placed and H.waitSeconds(game, function()
        if solo.fight then return true end
        local top = H.g3Top(game)
        if type(top) == "table" and top.g3Engine == "message" and H.g3Layer() == nil then
          U.tap(game, "a"); U.wait(6)
          return false
        end
        if not H.g3Free(game) then U.wait(4) return false end
        U.hold(game, dir, 16)
        U.wait(1)
        return false
      end, 180, "the trainer to see us and solo to take the fight")
      check(met, "real draw: walking into sight raised the fight, and solo took it")
      if met then
        awaitChoose(60, "the real trainer's grid")
        check(H.g3ScriptRunning(), "real draw: the trainer's script waits on the fight")
        local result
        local done = solo.gen3 and solo.gen3.done
        if solo.gen3 and type(done) == "function" then
          solo.gen3.done = function(r) result = r; return done(r) end
        end
        -- One cell out of the trainer's line while the fight is up: the
        -- engine looks for a trainer's sight on every idle frame, and an
        -- unbeaten trainer still facing us would come straight back for
        -- another go -- its intro is not the post-battle words asked about.
        local P = require("src.core.game3.player")
        local side = (dir == "up" or dir == "down") and { 1, 0 } or { 0, 1 }
        P.cellX, P.cellY = P.cellX + side[1], P.cellY + side[2]
        P.px, P.py, P.targetX, P.targetY = P.cellX * 16, P.cellY * 16, P.cellX, P.cellY
        session().x, session().y = P.cellX, P.cellY
        -- What is halted, and in what state: the trainerbattle command waits
        -- in the VM ("waiting", native) until it is answered.
        local Space = require("src.core.game3.scripting.space")
        local vm = Space.vm
        local halts, ownHalt = {}, vm and rawget(vm, "halt")
        if vm then
          local realHalt = vm.halt
          vm.halt = function(self, aborted)
            local c = self.ctx or {}
            halts[#halts + 1] = { aborted = aborted, status = c.status, mode = c.mode }
            return realHalt(self, aborted)
          end
        end
        solo.sim:_finish("draw", nil, nil, "timeout")
        H.waitSeconds(game, function()
          local f = fight()
          return f == nil or (f.phase == "over" and shown() ~= "")
        end, 20, "the draw's ending")
        shot("real-draw")
        driveToEnd(function() fightWith(1) end, 60)
        -- Four seconds of whatever the script might still say (none, now).
        local sawWords = false
        local clock = love and love.timer
        local deadline = clock and (clock.getTime() + 4) or nil
        for _ = 1, 2400 do
          if deadline and clock.getTime() >= deadline then break end
          local top = H.g3Top(game)
          if type(top) == "table" and top.g3Engine == "message" then
            sawWords = true
            U.tap(game, "a")
          end
          U.wait(1)
        end
        shot("real-draw-after")
        if vm then vm.halt = ownHalt end
        check(result == nil, "real draw: the trainerbattle command is never answered", tostring(result))
        check(#halts == 1 and halts[1].aborted == true and halts[1].status == "waiting",
              "real draw: the script was halted while its trainerbattle command waited",
              #halts .. " halt(s), " .. tostring(halts[1] and halts[1].status))
        check(not sawWords, "real draw: no post-battle words -- the bytes after the command did not run")
        check(not H.g3ScriptRunning(), "real draw: the trainer's script was halted where it waited")
        check(H.g3TrainerDefeated(H.g3ObjectById(stage.trainerLid)) == false,
              "real draw: the trainer stays unbeaten")
        check(session().battleOutcome == OUTCOME.DREW, "real draw: B_OUTCOME_DREW on the save",
              tostring(session().battleOutcome))
        check((tonumber(session().money) or 0) == 3000, "real draw: no prize, nobody taxed",
              tostring(session().money))
        check(Map.current == stage.trainerMap, "real draw: nobody whited out", tostring(Map.current))
        check(H.g3Free(game), "real draw: the field is the player's again")
      end
      -- Nothing of this trainer may outlive the leg: a fight still up (it came
      -- back for another go) is won, the cart's own battle ended, the flag
      -- cleared, and the player sent back to the grass.
      if solo.fight then driveToEnd(function(f) fightWith(bestMove(f)) end, 240) end
      if Battle.isActive() then endEngineBattle() end
      settle()
      H.g3ClearTrainer(H.g3ObjectById(stage.trainerLid))
      toGrass()
    end
  end

  -- ------------------------------------------------------------------
  -- G11. FireRed / LeafGreen's rival is the name the player gave them
  -- ------------------------------------------------------------------
  local rivalId
  if not emerald then
    local pack = Trainers.pack() or {}
    local best = 999
    for id, row in pairs(pack.trainers or {}) do
      local tid = tonumber(id)
      local class = type(row) == "table" and tonumber(row.class) or nil
      local p = type(row) == "table" and row.party or nil
      if tid and (class == 81 or class == 89 or class == 90) and type(p) == "table" and #p >= 1
          and not row.doubleBattle then
        local last = tonumber(p[#p].level) or 999
        if last < best then rivalId, best = tid, last end
      end
    end
  end
  if emerald then
    skip("the rival name leg", "Emerald's rival is not named by the player")
  elseif not rivalId then
    skip("the rival name leg", "no single rival battle in this cart's book")
  else
    settle()
    toGrass()
    seed(STARTER, 70)
    session().rivalName = "ZAKK"
    local result
    local took = solo:fromGen3Trainer(game, rivalId, { trainerId = rivalId, done = function(r) result = r end })
    check(took, "rival: trainer " .. tostring(rivalId) .. " taken")
    if took then
      local label = fight() and fight().peerName or ""
      check(label:find("ZAKK", 1, true) ~= nil, "rival: named by the player's rival name", label)
      check(not label:find("TERRY", 1, true), "rival: not the cart's placeholder", label)
      H.waitSeconds(game, function() return said("ZAKK") end, 10, "the rival's intro")
      shot("rival-intro")
      driveToEnd(function(f) fightWith(bestMove(f)) end, 240)
      check(result == "win", "rival: beaten", tostring(result))
      settle()
    end
  end

  -- ------------------------------------------------------------------
  -- G12. a trainer on a rainy field fights in the rain
  -- ------------------------------------------------------------------
  --
  -- The engine opens every battle off the link under the overworld's weather.
  -- The rain is set the way a map script sets it (setweather / doweather,
  -- here applied at once), then the trainer is met.
  if not easyId then
    skip("the rain leg", "no single easy trainer in this cart's book")
  else
    settle()
    toGrass()
    seed(STARTER, 40)
    local Weather = require("src.core.game3.weather")
    pcall(Weather.apply, 3, { seamless = false }) -- WEATHER_RAIN
    local raining = H.waitSeconds(game, function()
      local ok, id = pcall(Weather.get)
      return ok and tonumber(id) == 3
    end, 15, "the rain to set in")
    check(raining, "rain: the overworld is raining")
    U.wait(30)
    shot("rain-field")
    local result
    local took = solo:fromGen3Trainer(game, easyId, { trainerId = easyId, done = function(r) result = r end })
    check(took, "rain: the trainer is taken")
    if took then
      check(solo.sim and solo.sim.field and solo.sim.field.weather == "RAIN",
            "rain: the fight opens in the rain",
            tostring(solo.sim and solo.sim.field and solo.sim.field.weather))
      local sawRainLine = false
      H.waitSeconds(game, function()
        if said("rain") or said("RAIN") then sawRainLine = true return true end
        local f = fight()
        if f and f.phase == "choose" then return true end
        nudge()
        return false
      end, 30, "the rain line")
      awaitChoose(60, "the grid in the rain")
      shot("rain-arena")
      check(sawRainLine or (fight() and fight().weatherShown == "RAIN"),
            "rain: the arena shows it")
      driveToEnd(function(f) fightWith(bestMove(f)) end, 240)
      check(result == "win", "rain: beaten", tostring(result))
      settle()
    end
    toGrass()
  end

  -- ------------------------------------------------------------------
  -- G8. the real thing: a step encounter, taken by src/Client.lua's divert
  -- ------------------------------------------------------------------
  do
    settle()
    seed(STARTER, 40)
    local found, why = walkForEncounter(120)
    if found == nil then
      skip("the grass divert leg", tostring(why or "no encounter in time"))
    elseif found == "engine" then
      skip("the grass divert leg", "the cart ran its own battle -- the Gen 3 divert "
        .. "(src/Client.lua encounter.roll) is not installed in this build")
      endEngineBattle()
    else
      check(true, "a real grass encounter was taken by the mod's divert")
      awaitChoose(60, "the diverted wild's grid")
      shot("grass-divert")
      driveToEnd(function() command("RUN") end, 60)
      settle()
      check(H.g3Idle(game), "grass: the field is the player's again")
      shot("grass-after")
    end
  end

  doubleLegs()
  badgeLegs()
end

return function(game)
  local H = dofile("mods/rby_mmo/tests/drivers/mmo_util.lua")
  local U = H.U
  local TAG = "SOLO_E2E:"
  local SHOT_DIR = os.getenv("SHOT_DIR") or "/tmp/rby_mmo_solo_shots"
  os.execute('mkdir -p "' .. SHOT_DIR .. '" 2>/dev/null')

  local MOD_ID = "rby_mmo"
  local OPTION_KEY = "solo"           -- src/SoloBattle.lua M.OPTION
  local OPTION_LABEL = "SOLO BATTLES" -- src/SoloBattle.lua M.OPTION_LABEL

  local pass, fail = 0, 0
  -- Tag-first, like battlefield_shot.lua: the wrapper greps `^SOLO_E2E:`, and
  -- U.log's own "[driver]" prefix would push the tag off the line start.
  -- mmo_util's own waits still log through U.log, and their TIMEOUT lines are
  -- grepped separately by the wrapper.
  local function log(...)
    local parts = { TAG }
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    print(table.concat(parts, "\t"))
  end
  local function check(ok, what, note)
    if ok then
      pass = pass + 1
      log("ok " .. what .. (note and ("  [" .. tostring(note) .. "]") or ""))
    else
      fail = fail + 1
      log("FAIL " .. what .. (note and ("  [" .. tostring(note) .. "]") or ""))
    end
    return ok and true or false
  end
  local function skip(what, why)
    log("skip " .. what .. " -- " .. tostring(why))
  end
  local function shot(name)
    U.shot(game, SHOT_DIR .. "/" .. name .. ".png")
  end

  -- FireRed / LeafGreen / Emerald boot a Game3, whose battles are modules
  -- rather than stack states: everything below this line is written against a
  -- Gen 1 / Gen 2 stack, so a Gen 3 run is its own arm (runGen3, at the end
  -- of this file), sharing only the log / check / shot vocabulary.
  if tonumber(game.generation) == 3 then
    local env = { log = log, check = check, skip = skip, shot = shot, TAG = TAG,
                  SHOT_DIR = SHOT_DIR, OPTION_KEY = OPTION_KEY, MOD_ID = MOD_ID }
    local ok, err = pcall(runGen3, game, H, U, env)
    if not ok then check(false, "the Gen 3 arm ran to its end", tostring(err)) end
    log("shots in", SHOT_DIR)
    log("GAPS:" .. tostring(fail))
    log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
    log("DONE")
    love.event.quit(fail > 0 and 1 or 0)
    return
  end

  -- ------------------------------------------------------------------
  -- save readers, per generation
  -- ------------------------------------------------------------------

  -- src/Gen.lua's money accessor, mirrored: Gen 2 always writes
  -- save.player.money, Gen 1 keeps save.money unless a player table already
  -- carries one.
  local function moneyOf()
    local save = game and game.save
    if type(save) ~= "table" then return 0 end
    local player = save.player
    if save.generation == 2 or H.generation(game) == 2 then
      return math.floor(tonumber(player and player.money) or 0)
    end
    if type(player) == "table" and player.money ~= nil then
      return math.floor(tonumber(player.money) or 0)
    end
    return math.floor(tonumber(save.money) or 0)
  end

  -- MediatedBattle:gainExp writes through the engine's own Experience.apply
  -- (Gen 1, `mon.exp`) or src/Exp2.lua (Gen 2, `mon.experience`).
  local function expOf(mon)
    if type(mon) ~= "table" then return 0 end
    return math.floor(tonumber(mon.exp or mon.experience) or 0)
  end

  local function ppOf(mon)
    local total = 0
    for _, mv in ipairs((type(mon) == "table" and mon.moves) or {}) do
      total = total + (tonumber(mv.pp) or 0)
    end
    return total
  end

  local function lead()
    return game.save and game.save.party and game.save.party[1] or nil
  end

  -- A pristine, deterministic fighter before every leg that measures a delta.
  -- frontloadDamage puts the highest-power move in slot 1, which is what makes
  -- "mash A" resolve a fight instead of trading GROWLs until PP runs out.
  --
  -- Resolved per call rather than once at load: this file's helpers are
  -- defined before the boot below has run, and the generation is a property of
  -- the game that is running.
  local function partySpecies()
    return H.generation(game) == 2 and "CYNDAQUIL" or "CHARIZARD"
  end
  local function freshParty()
    local mon = H.seedParty(game, partySpecies(), 50)
    if mon then H.frontloadDamage(game.data, mon) end
    return mon
  end

  -- ------------------------------------------------------------------
  -- staging helpers this file owns
  -- ------------------------------------------------------------------

  -- Take a staged engine battle back off the stack, by identity.
  --
  -- Two legs assert the engine *kept* an encounter, and neither wants to then
  -- fight it: a vanilla battle driven to a decision here would prove nothing
  -- the engine's own suites do not already prove, and would cost a minute.
  local function dropStaged(state)
    if state == nil then return true end
    for _ = 1, 20 do
      if not H.onStack(game, state) then break end
      if not pcall(function() game.stack:pop() end) then break end
      U.wait(2)
    end
    U.wait(8)
    return not H.onStack(game, state)
  end

  -- Make a staged Gold battle end the way a real Gold battle ends.
  --
  -- On Gen 2 the pop that takes a finished battle off the stack does not live
  -- in `Gen2BattleState` at all: it lives inside the `onDone` closure
  -- `World:startBattle` builds around it (engine `src/world/gen2/World.lua`),
  -- and `src/Client.lua` aliases the state's absent `onFinish` onto it -- so
  -- every Gold battle a player can walk into carries *one* function, on both
  -- fields, and that function pops.
  --
  -- `mmo_util`'s Gen 2 staging pushes `Gen2BattleState` itself with a callback
  -- of its own, which recorded the outcome and popped nothing. That is a shape
  -- no Gold player can produce, and it is exactly the question
  -- `src/SoloBattle.lua`'s ending has to answer -- who takes the buried battle
  -- down -- so a leg staged that way was exercising a path the product does not
  -- ship while leaving the one it does ship untested. (It found a real
  -- fragility doing so, which is now fixed and covered headlessly: the
  -- non-popping shape is `goldNoPop` in `mods/rby_mmo/tests/solo_battle.lua`
  -- section 10.)
  --
  -- So the callbacks are restamped to Gold's real shape. Gen 1 is left alone:
  -- there the pop is `BattleState:finish`'s own, `onFinish` never pops, and
  -- `mmo_util`'s staging is already faithful.
  local function likeWorldStartBattle(state, onFinish)
    if state == nil or H.generation(game) ~= 2 then return state end
    local done = function(outcome)
      -- `World:startBattle` pops unconditionally. By identity here, because
      -- the engine's unconditional pop is safe on the invariants an overworld
      -- maintains and a driver has none of them: a wrong guess would take the
      -- world down and every assertion after it would blame the mod.
      if H.top(game) == state then pcall(function() game.stack:pop() end) end
      if onFinish then onFinish(outcome) end
    end
    state.onDone = done
    state.onFinish = done
    return state
  end

  -- A wild encounter this mod is required to hand straight back.
  --
  -- Gen 1 gets a real Pokemon Tower ghost through BattleState's own
  -- `makeGhost` (falling back to the bare field if the ghost art is not in
  -- this build's cache); Gold gets the roaming battle *byte*, which is the
  -- half of Config.SOLO_REFUSED that is keyed by value rather than by name --
  -- and is inert on the Gen 2 screen, which only ever branches on FORCESHINY
  -- and TRAP. Both are marked before the push, because the divert runs inside
  -- it.
  local function stageRefusedWild(species, level)
    species, level = species or "GASTLY", level or 5
    if H.generation(game) == 2 then
      local okB, Battle = pcall(require, "src.battle.gen2.Battle")
      local okM, Mon = pcall(require, "src.battle.gen2.Mon")
      local okS, Screens = pcall(require, "src.ui.Screens")
      if not (okB and Battle and okM and Mon and okS and Screens) then
        return nil, "gen2 battle modules unavailable"
      end
      local wild = Mon.new(game.data, species, level)
      if not wild then return nil, "no such species: " .. tostring(species) end
      local okNew, battle = pcall(Battle.new, {
        data = game.data,
        party = (game.save and game.save.party) or {},
        wild = wild,
        save = game.save,
        battleType = 5, -- BATTLETYPE_ROAMING, Config.SOLO_REFUSED_BATTLE_TYPES
      })
      if not (okNew and battle) then return nil, tostring(battle) end
      battle.battleType = 5
      local okPush, state = pcall(Screens.push, game, "Gen2BattleState",
        { battle = battle, save = game.save })
      state = (okPush and state) or H.top(game)
      if not state then return nil, "Gen2BattleState never came up" end
      return state, "battleType=5 (roaming)"
    end
    local BattleState = require("src.battle.BattleState")
    local function build()
      local ok, battle = pcall(BattleState.newWild, game, species, level)
      if ok and battle and not battle.dead then return battle end
      return nil
    end
    local battle = build()
    if not battle then return nil, "newWild refused " .. tostring(species) end
    local how = "makeGhost()"
    if not pcall(function() battle:makeGhost() end) then
      -- The ghost disguise loads art generated from the player's own cache and
      -- a build without it would leave the state half-mutated -- worse than
      -- not disguised at all. Start over and set the one field
      -- Config.SOLO_REFUSED actually reads.
      battle = build()
      if not battle then return nil, "newWild refused on the retry" end
      battle.ghost = true
      how = "ghost field (makeGhost unavailable)"
    end
    game.stack:push(battle)
    return battle, how
  end

  -- The species a wild leg fights. SENTRET is Gold's Route 29 opener and does
  -- not exist on Red; PIDGEY is the Gen 1 one and is in Johto too, so the
  -- fallback is real rather than decorative.
  local function stageWildOf(candidates, level, onFinish)
    for _, species in ipairs(candidates) do
      local staged = H.stageWild(game, species, level or 5, onFinish)
      if staged then return likeWorldStartBattle(staged, onFinish), species end
    end
    return nil, nil
  end

  -- ------------------------------------------------------------------
  -- driving the mod's screen
  -- ------------------------------------------------------------------
  --
  -- **A solo fight is a `MediatedBattle`, and a MediatedBattle has no `.sim`.**
  -- That field belongs to `CoopBattle`, the 2-on-2 screen, and every helper in
  -- mmo_util that touches a fight keys on it -- `awaitCommandMenu`,
  -- `throwBattleItem`, and the `top.sim == nil` done-predicate the co-op legs
  -- pass to `drivePrompts`. Reused here they would be worse than useless: the
  -- done-predicate is true on the very first poll, so a fight would report
  -- itself finished before its first turn opened and every save assertion
  -- after it would read an untouched party as a passing one.
  --
  -- So the three below read the mediated screen's own machine instead: its
  -- `mmoBattle` marker, its `phase` (setup/play/choose/move/item/... --
  -- src/MediatedBattle.lua), and `M.COMMANDS` = FIGHT / SWITCH / ITEM / RUN.
  -- They stay local rather than joining mmo_util for the same reason
  -- everything else here does; if the shared file ever grows a mediated-screen
  -- vocabulary, these are what it should be.

  -- The mod's screen anywhere on the stack, not merely on top: a box pushed
  -- over the fight for a frame must not read as the fight being over.
  local function medOnStack()
    for _, state in ipairs((game.stack and game.stack.states) or {}) do
      if state and state.mmoBattle == true then return state end
    end
    return nil
  end

  local function medTop()
    local top = H.top(game)
    if H.isMediatedBattle(top) then return top end
    return nil
  end

  -- Wait for this mod's screen to be the thing on the stack. The divert is
  -- synchronous inside StateStack:push, so this is a formality -- but a
  -- formality that names the failure when the row is off, the kind was
  -- refused, or _begin bailed.
  local function awaitDivert(what)
    return H.waitFor(game, function()
      return H.isMediatedBattle(H.top(game))
    end, 240, what or "the mod's battle screen to take the encounter")
  end

  -- The command grid really being what the player is looking at. "phase ==
  -- choose" and nothing weaker: the opening line holds the message box for its
  -- whole dwell, and a driver that taps an arrow into that lands every press
  -- behind it one step out of order.
  local function awaitCommandMenu(what)
    return H.waitSeconds(game, function()
      local top = medTop()
      return top ~= nil and top.phase == "choose"
    end, 60, what or "the solo command grid")
  end

  -- ------- what the arena is actually holding
  --
  -- The two halves of the picture a solo fight draws, read off the live screen
  -- rather than off a fixture, because both were wrong in a way only a real
  -- boot could show:
  --
  --   * **the player's own front pic.** `MediatedBattle:seatFront` hands the
  --     arena a *front* for both sides -- that is the whole difference between
  --     this theatre and the classic 160x144 stage, where the player's side is
  --     a back pic. When it fails it falls back to `slot.sprite`, which on our
  --     own seat *is* that back pic, so the failure draws a monster seen from
  --     behind and mirrored rather than an empty seat. Nothing but comparing
  --     the two images catches that: a nil check passes on the wrong pic.
  --   * **the figure on the foe edge.** `Battlefield.drawHuman` falls back to a
  --     dark placeholder rectangle when a human names no walk sheet, which is
  --     what a solo trainer fight drew for the whole battle.
  --
  -- Soft throughout: a probe that throws must not take the leg with it.
  local function arenaProbe(mine)
    local top = medTop()
    if not top then return nil end
    local out = {}
    pcall(function()
      if not (top.usesBattlefield and top:usesBattlefield()) then
        out.classic = true
        return
      end
      local index = mine and top:mySlot() or top:foeSlot()
      local slot = top.slots and top.slots[index]
      local seat = top.battlefieldSeat and top:battlefieldSeat(index, mine)
      out.front = seat and seat.front or nil
      out.slotSprite = slot and slot.sprite or nil
      local ctx = top.battlefieldCtx and top:battlefieldCtx() or nil
      out.foeHumans = ctx and ctx.foeHumans or nil
      out.allyHumans = ctx and ctx.allyHumans or nil
      -- What the referee has said about each seat's party (`team`, PROTOCOL
      -- 24). Resolved here, where the screen is in scope, and taken off
      -- `top.teams` rather than off the ctx -- so a nil at the call site means
      -- "no event ever arrived" rather than "the ctx dropped it".
      local mineSlot = top.mySlot and top:mySlot() or nil
      local foeSlot = top.foeSlot and top:foeSlot() or nil
      out.mineTeam = top.teams and mineSlot and top.teams[mineSlot] or nil
      out.foeTeam = top.teams and foeSlot and top.teams[foeSlot] or nil
    end)
    return out
  end

  -- FIGHT / SWITCH / ITEM / RUN, then the bag row for `itemId`.
  --
  -- The grid's shape is asked for rather than assumed -- the battlefield band
  -- lays all four in one row, classic GB chrome and Gold keep the 2x2 -- which
  -- is the same rule mmo_util's own version follows and the same one that
  -- silently broke the co-op catch flow when it was assumed instead.
  local function throwItem(itemId)
    local top = medTop()
    if not (top and top.phase == "choose") then return false end
    local cols = 2
    if type(top.commandCols) == "function" then
      local ok, got = pcall(top.commandCols, top)
      if ok and tonumber(got) then cols = tonumber(got) end
    end
    if cols >= 4 then
      U.tap(game, "right"); U.wait(6)
      U.tap(game, "right"); U.wait(6)
    else
      U.tap(game, "down"); U.wait(6)
    end
    U.tap(game, "a"); U.wait(10)
    top = medTop()
    if not (top and top.phase == "item") then return false end
    local items = (type(top.usableItems) == "function") and top:usableItems() or {}
    local want = 1
    for i, row in ipairs(items) do
      if row.id == itemId then want = i break end
    end
    top.itemIndex = want
    U.tap(game, "a"); U.wait(20)
    return true
  end

  -- Mash the fight to its end, the way the co-op legs do: drivePrompts answers
  -- whatever box is up, and the extra tap walks the command grid (FIGHT ->
  -- move 1, which frontloadDamage made the strongest one).
  local function fightToEnd(seconds)
    return H.drivePrompts(game, function()
      return medOnStack() == nil
    end, seconds or 240, function()
      U.tap(game, "a")
    end)
  end

  local function backToOverworld(seconds)
    H.closeToOverworld(game)
    return H.waitSeconds(game, function() return H.inPlay(game) end,
                         seconds or 30, "the overworld to come back")
  end

  -- ------------------------------------------------------------------
  -- boot
  -- ------------------------------------------------------------------
  --
  -- `H.bootToPlay` again, now that it is safe to use.  This driver carried its
  -- own copy of the boot because `mmo_util`'s went through the engine's
  -- `U.newGame`, whose Gen 1 arm mashed A 400 times against an intro that
  -- reaches the overworld at tap 441 -- and then returned nothing, so a driver
  -- walked on and asserted against OakSpeech while reading a save it had
  -- seeded itself.  That is fixed upstream of here now: `H.newGame` waits for
  -- the overworld to actually be on top, on a budget with real headroom, and
  -- names the stack it is stuck on when it gives up.  `H.bootToPlay` routes
  -- through it, so the local copy has done its job and is gone -- one boot for
  -- every driver in the repo, which is the point of keeping it in `mmo_util`.
  local function bootToPlay()
    return H.bootToPlay(game) and H.inPlay(game)
  end

  local function stackNames()
    return H.stackNames(game)
  end

  local events = H.captureEvents({ "battle.started", "battle.ended" })

  local booted = bootToPlay()
  if not check(booted, "booted to a playable overworld") then
    log("shots in", SHOT_DIR)
    log("GAPS:" .. tostring(fail))
    log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
    log("DONE")
    love.event.quit(1)
    return
  end
  if game.save and game.save.player then
    game.save.player.name = "SOLO"
  end
  local GEN = H.generation(game)
  log("generation =", tostring(GEN))
  log("stack after boot:", stackNames())

  local exports = H.requireMod(game, TAG)
  if not exports then
    log("stack:", stackNames())
    log("GAPS:1")
    log("SUMMARY", "pass=" .. pass, "fail=" .. (fail + 1))
    log("DONE")
    love.event.quit(1)
    return
  end
  local connected = type(exports.isConnected) == "function"
    and exports.isConnected() or false
  check(connected == false,
        "and nothing is connected -- this is the offline copy the row is for")

  freshParty()
  log("party:", table.concat(H.partySpecies(game), ","))

  -- ------------------------------------------------------------------
  -- 1. the row, through the mod manager's own row model
  -- ------------------------------------------------------------------
  --
  -- Not simulated keypresses. The manager's cursor walks a flat row list with
  -- category headers in it, and a driver that counted DOWNs to reach a row
  -- would report "SOLO BATTLES is missing" the first time a mod was installed
  -- beside this one -- a failure about the driver's arithmetic wearing the
  -- clothes of a failure about the feature. What is asserted instead is the
  -- model the options screen draws from and the callback its keypress runs:
  -- `ManagerState:buildOptionRows` (src/mods/ManagerState.lua) and, for the
  -- flip, the row's own `step()`. A row that is in there is a row the player
  -- can see; a `step()` that flips it is the flip a player performs.
  -- The manager, opened the way F10 opens it, and its own row model.
  local function openManager()
    local okScreens, Screens = pcall(require, "src.ui.Screens")
    if not (okScreens and Screens) then return nil end
    local okPush, pushed = pcall(Screens.push, game, "ManagerState")
    local mgr = (okPush and pushed) or nil
    if mgr == nil then
      local top = H.top(game)
      if top and top.screenId == "ManagerState" then mgr = top end
    end
    return mgr
  end

  local function closeManager(mgr)
    if mgr and H.top(game) == mgr then
      pcall(function() game.stack:pop() end)
      U.wait(6)
    end
    H.closeToOverworld(game)
  end

  local function schemaRows()
    return game.mods and game.mods.optionSchemas
      and game.mods.optionSchemas[MOD_ID]
  end

  -- The SOLO BATTLES row as the OPTIONS.. screen builds it.
  local function soloRowOf(mgr)
    local schema = schemaRows()
    local entry = mgr and mgr.byId and mgr.byId[MOD_ID] or nil
    if not (mgr and entry and type(schema) == "table"
            and type(mgr.buildOptionRows) == "function") then
      return nil, entry
    end
    local okRows, rows = pcall(mgr.buildOptionRows, mgr, entry, schema)
    if not (okRows and type(rows) == "table") then
      log("warn buildOptionRows failed:", tostring(rows))
      return nil, entry
    end
    local labels, soloRow = {}, nil
    for _, row in ipairs(rows) do
      labels[#labels + 1] = tostring(row.label)
      if row.id == OPTION_KEY then soloRow = row end
    end
    log("manager option rows:", table.concat(labels, ","))
    return soloRow, entry
  end

  -- What mod.options:get actually reads (Loader's per-mod option store).
  local function optionValue()
    local stored = game.mods and game.mods.modOptions
      and game.mods.modOptions[MOD_ID]
    return stored and stored[OPTION_KEY]
  end

  -- Legs 1-8 below are the group "singles" of SOLO_LEGS (`legOn`), as on
  -- Gen 3; the carts' rules against the computer (leg 9, `rulesLegs12`) are
  -- the groups "obey", "priority", "gaps" and "held".  A run that leaves "singles"
  -- out turns the row on the way leg 3 leaves it, through the store
  -- mod.options:get reads, since leg 3 is what normally flips it.
  local SINGLES = legOn("singles")

  if SINGLES then
    local mgr = openManager()
    check(mgr ~= nil, "F10's mod manager opens (Screens.push ManagerState)")

    local schema = schemaRows()
    check(type(schema) == "table",
          "the mod published an options schema to the loader")

    -- The schema's own answer to "what does this default to", which is the
    -- answer a player with no options.lua at all would get.
    local declared = nil
    for _, row in ipairs(schema or {}) do
      if row.key == OPTION_KEY then declared = row end
    end
    check(declared ~= nil,
          ("the schema carries a %q row"):format(OPTION_KEY))
    check(declared ~= nil and declared.type == "toggle",
          "and it is a toggle, not a choice or a number",
          declared and tostring(declared.type))
    check(declared ~= nil and declared.default == false,
          "and it defaults to OFF (Config.SOLO_BATTLES_DEFAULT)",
          declared and tostring(declared.default))
    check(declared ~= nil and declared.label == OPTION_LABEL,
          ("and its label is %q"):format(OPTION_LABEL),
          declared and tostring(declared.label))

    local soloRow, entry = soloRowOf(mgr)
    check(entry ~= nil, "the manager lists rby_mmo among the installed mods")
    check(soloRow ~= nil,
          "the OPTIONS.. screen really draws a SOLO BATTLES row")
    if soloRow then
      check(soloRow.label == OPTION_LABEL,
            "the row reads " .. OPTION_LABEL, tostring(soloRow.label))
      local shown = soloRow.value and soloRow.value() or nil
      check(shown == "OFF",
            "and it reads OFF before anybody touches it", tostring(shown))
      shot("solo-manager-row")
    end
    closeManager(mgr)
    check(optionValue() ~= true,
          "and nothing has turned it on behind the player's back")
  end

  -- ------------------------------------------------------------------
  -- 2. default OFF is honoured
  -- ------------------------------------------------------------------
  --
  -- Run before anything is flipped, so what it proves is what it says: an
  -- untouched copy of this mod does not take the game's battles. The wrapper
  -- seeds the row OFF in options.lua rather than leaving the key absent, so
  -- this leg is the same leg on an identity a previous run left dirty.
  if SINGLES then
    check(optionValue() ~= true, "the row is off for the default-OFF leg")

    freshParty()
    local finished = nil
    local staged, species = stageWildOf({ "PIDGEY", "SENTRET", "RATTATA" }, 5,
      function(result) finished = result end)
    check(staged ~= nil, "staged a wild encounter with the row off",
          tostring(species))
    if staged then
      U.wait(20)
      local top = H.top(game)
      check(not H.isMediatedBattle(top),
            "with SOLO BATTLES off the mod's screen never appears")
      check(top == staged,
            "the engine's own battle is what the player is looking at")
      shot("solo-off-engine-battle")
      check(dropStaged(staged), "and it comes back off the stack cleanly")
      check(finished == nil,
            "nothing finished the engine's battle behind the player's back")
    end
    check(backToOverworld(), "back in the overworld after the OFF leg")
  end

  -- ------------------------------------------------------------------
  -- 3. flipping it on, through the row a player would press
  -- ------------------------------------------------------------------
  --
  -- Not a write into loader.modOptions. `ManagerState:buildOptionRows` gives
  -- each toggle a `step()` closure, and that closure is exactly what the
  -- options screen calls when the row is pressed -- it writes both
  -- save.options.modOptions and loader.modOptions and emits
  -- mod.options_changed, none of which a driver poking one table would do.
  --
  -- Mid-session and with no relaunch, which is the half of success criterion 1
  -- that a pre-seeded options.lua can never show: the very next encounter
  -- (leg 4) is the assertion that it took.
  if SINGLES then
    local mgr = openManager()
    local soloRow = soloRowOf(mgr)
    check(soloRow ~= nil, "reopened the manager on the SOLO BATTLES row")
    local flipped, shown = false, nil
    if soloRow then
      local okStep = pcall(soloRow.step, soloRow, 1)
      shown = soloRow.value and soloRow.value() or nil
      flipped = okStep and shown == "ON"
    end
    check(flipped, "the row's own step() turns it ON", tostring(shown))
    closeManager(mgr)
    check(optionValue() == true,
          "and it landed in the table mod.options:get reads",
          tostring(optionValue()))
  end

  -- ------------------------------------------------------------------
  -- 4. a solo wild fight, and the save afterwards
  -- ------------------------------------------------------------------
  if SINGLES then
    freshParty()
    local before = lead()
    local expBefore, ppBefore = expOf(before), ppOf(before)
    local hpBefore = tonumber(before and before.hp) or 0
    local partyBefore = H.partySpeciesCount(game)
    local startedBefore = events["battle.started"]

    local finished = nil
    local staged, species = stageWildOf({ "PIDGEY", "SENTRET", "RATTATA" }, 5,
      function(result) finished = result end)
    check(staged ~= nil, "staged a wild encounter with the row on",
          tostring(species))

    if staged then
      check(awaitDivert("the solo wild divert"),
            "the encounter diverts onto this mod's battle screen")
      check(H.onStack(game, staged),
            "and the engine's own battle is frozen underneath, not destroyed")
      do
        local top = H.top(game)
        log(("solo wild: id=%s mode=%s phase=%s"):format(
          tostring(top and top.battleId), tostring(top and top.mode),
          tostring(top and top.phase)))
        check(top and top.mode == "wild",
              "seated as a wild fight, so catching and running are legal",
              tostring(top and top.mode))
      end
      check(awaitCommandMenu("the solo wild command grid"),
            "the command grid opens on the mod's screen")
      shot("solo-wild-battle")

      do
        local arena = arenaProbe(true)
        if arena and arena.classic then
          skip("the wild arena probe", "this generation draws the classic stage")
        else
          log(("solo wild arena: front=%s back=%s same=%s foeHumans=%d"):format(
            tostring(arena and arena.front ~= nil),
            tostring(arena and arena.slotSprite ~= nil),
            tostring(arena and arena.front == arena.slotSprite),
            arena and arena.foeHumans and #arena.foeHumans or -1))
          check(arena ~= nil and arena.front ~= nil,
                "our own seat hands the arena a pic to draw")
          check(arena ~= nil and arena.slotSprite ~= nil
                  and arena.front ~= arena.slotSprite,
                "...and it is the FRONT pic co-op draws, not the classic "
                .. "stage's back pic")
          check(arena ~= nil and arena.foeHumans ~= nil
                  and #arena.foeHumans == 0,
                "a wild fight stands nobody on the foe edge")
        end
      end

      local over, seen = fightToEnd(240)
      check(over, "the solo wild fight runs to an end", tostring(seen))
      check(backToOverworld(), "and the overworld is restored")
      shot("solo-wild-after")

      -- The save, which is the whole reason this leg is out here.
      local after = lead()
      check(finished == "win",
            "the engine's own battle was told it was a win", tostring(finished))
      check(not H.onStack(game, staged),
            "and it is off the stack -- no rematch waiting underneath")
      check(expOf(after) > expBefore,
            "exp landed on the real save monster",
            ("%d -> %d"):format(expBefore, expOf(after)))
      check(ppOf(after) < ppBefore,
            "and the PP it spent is on the save too",
            ("%d -> %d"):format(ppBefore, ppOf(after)))
      check((tonumber(after and after.hp) or 0) <= hpBefore
            and (tonumber(after and after.hp) or 0) > 0,
            "HP reflects the fight and the winner is standing",
            ("%d -> %s"):format(hpBefore, tostring(after and after.hp)))
      check(H.partySpeciesCount(game) == partyBefore,
            "a won wild fight adds nobody to the party")
      log("engine battle.started since the leg opened:",
          tostring(events["battle.started"] - startedBefore))
    end
  end

  -- ------------------------------------------------------------------
  -- 4b. the fight after that one: a hurt monster's bar is out of its own
  --     maximum, not out of the HP it walked in on
  -- ------------------------------------------------------------------
  --
  -- **Deliberately no `freshParty()`.** The leg above just wrote HP back to
  -- the save, so this is the second encounter of the day with the monster that
  -- fought the first -- which is exactly where the bug lived. An event on this
  -- wire carries current HP, and the screen used to take the largest HP it had
  -- ever seen on a seat for that seat's maximum: a monster walking out on 42
  -- of 200 drew a **full** bar with "42/200" collapsed to "42/42" over it, and
  -- stayed that way for the whole fight. From PROTOCOL 24 the referee states
  -- the maximum on the `send`.
  --
  -- Out here rather than only in the suites because the numbers a player reads
  -- come off the *save's* stat block through the real snapshot, the real
  -- referee and the real screen -- and each of those three could have been the
  -- one that lost them.
  if SINGLES then
    local before = lead()
    local maxIn = tonumber(before and before.stats and before.stats.hp) or 0
    check(maxIn > 0, "the save monster states a maximum to check against")
    check((tonumber(before and before.hp) or 0) > 0,
          "and it came out of the last fight standing")
    -- **The wound is written here rather than fought for**, and that is the
    -- one liberty this leg takes. The lead is a level-50 starter and the
    -- staged encounters are level 5, so the fight above lands no damage on it
    -- at all -- the leg would pass on a monster that walked in whole, which is
    -- precisely the case the old guess already got right. So the save is put
    -- where a real fight leaves it: hurt, on a monster whose maximum only its
    -- own stat block knows. Everything after this point is the real path --
    -- the real snapshot, the real referee, the real send, the real screen.
    if before then before.hp = math.max(1, math.floor(maxIn / 4)) end
    local hpIn = tonumber(before and before.hp) or 0
    log(("solo second fight opens on %d/%d"):format(hpIn, maxIn))
    check(hpIn < maxIn, "the monster walks into this one hurt",
          ("%d/%d"):format(hpIn, maxIn))

    local finished = nil
    local staged, species = stageWildOf({ "PIDGEY", "SENTRET", "RATTATA" }, 5,
      function(result) finished = result end)
    check(staged ~= nil, "staged a second wild encounter", tostring(species))

    if staged then
      check(awaitDivert("the second solo wild divert"),
            "the second encounter diverts too")
      check(awaitCommandMenu("the second solo wild command grid"),
            "the command grid opens on it")

      local top = medTop()
      local slot = top and top.slots and top.slots[top:mySlot()]
      local shown = slot and (slot.shownHp or slot.hp) or nil
      log(("solo second seat: hp=%s shownHp=%s maxHp=%s"):format(
        tostring(slot and slot.hp), tostring(shown),
        tostring(slot and slot.maxHp)))
      check(slot ~= nil, "our own seat is on the field")
      check(slot ~= nil and tonumber(slot.maxHp) == maxIn,
            "the seat is drawn against the save's own maximum",
            ("%s vs %d"):format(tostring(slot and slot.maxHp), maxIn))
      check(slot ~= nil and tonumber(slot.hp) == hpIn,
            "...over the HP it really walked in on",
            ("%s vs %d"):format(tostring(slot and slot.hp), hpIn))
      -- The bar itself, through the same model the plate draws from: a hurt
      -- monster must not produce a full one.
      if slot and maxIn > 0 then
        local frac = math.min(1, math.max(0, (tonumber(shown) or 0) / maxIn))
        log(("solo second bar: frac=%.3f"):format(frac))
        check(frac < 1,
              "a monster that walked in hurt draws a part-filled bar",
              ("%.3f"):format(frac))
        check(math.abs(frac - hpIn / maxIn) < 0.001,
              "...filled to exactly the fraction the numbers state",
              ("%.3f vs %.3f"):format(frac, hpIn / maxIn))
      end
      shot("solo-wild-second-hp")

      local over, seen = fightToEnd(240)
      check(over, "the second solo wild fight runs to an end", tostring(seen))
      check(backToOverworld(), "and the overworld is restored after it")
    end
  end

  -- ------------------------------------------------------------------
  -- 5. a refused kind stays vanilla
  -- ------------------------------------------------------------------
  if SINGLES then
    freshParty()
    local staged, how = stageRefusedWild(GEN == 2 and "SENTRET" or "GASTLY", 5)
    if staged == nil then
      skip("the refused-kind leg", tostring(how))
    else
      log("refused kind staged as:", tostring(how))
      U.wait(20)
      local top = H.top(game)
      check(not H.isMediatedBattle(top),
            "a Config.SOLO_REFUSED battle is handed straight back to the engine")
      check(top == staged,
            "the engine's own battle is what the player is looking at")
      shot("solo-refused-engine-battle")
      check(dropStaged(staged), "and it comes back off the stack cleanly")
      check(backToOverworld(), "back in the overworld after the refused leg")
    end
  end

  -- ------------------------------------------------------------------
  -- 6. a solo trainer fight, and the payout
  -- ------------------------------------------------------------------
  if SINGLES then
    freshParty()
    local class, total = H.coopTrainer(game.data)
    check(class ~= nil, "the dataset has a trainer with two POKeMON",
          tostring(class) .. " total level " .. tostring(total))
    if class then
      local moneyBefore = moneyOf()
      local expBefore = expOf(lead())
      local finished = nil
      local record = function(result) finished = result end
      local staged = likeWorldStartBattle(H.stageTrainer(game, class, record),
                                          record)
      check(staged ~= nil, "staged a trainer battle", tostring(class))

      if staged then
        check(awaitDivert("the solo trainer divert"),
              "the trainer diverts onto this mod's battle screen")
        check(H.onStack(game, staged),
              "and the engine's trainer battle is frozen underneath")
        do
          local top = H.top(game)
          log(("solo trainer: id=%s mode=%s phase=%s"):format(
            tostring(top and top.battleId), tostring(top and top.mode),
            tostring(top and top.phase)))
          check(top and top.mode == "coop_npc",
                "seated as coop_npc, so a ball cannot catch a trainer's mon",
                tostring(top and top.mode))
        end
        check(awaitCommandMenu("the solo trainer command grid"),
              "the command grid opens on the mod's screen")
        H.assertTrainerKit(game, check, log, { solo = true, class = class })
        H.assertZeroPpRefused(game, check, log)
        shot("solo-trainer-battle")

        do
          local arena = arenaProbe(true)
          if arena and arena.classic then
            skip("the trainer arena probe",
                 "this generation draws the classic stage")
          else
            local who = arena and arena.foeHumans and arena.foeHumans[1] or nil
            log(("solo trainer arena: front=%s same=%s foe=%s sheet=%s"):format(
              tostring(arena and arena.front ~= nil),
              tostring(arena and arena.front == arena.slotSprite),
              tostring(who and who.name), tostring(who and who.spriteId)))
            check(arena ~= nil and arena.front ~= nil
                    and arena.front ~= arena.slotSprite,
                  "our own seat draws its front pic here too")
            check(who ~= nil,
                  "the trainer is standing on the foe edge")
            check(who ~= nil and type(who.spriteId) == "string"
                    and who.spriteId ~= "",
                  "...with a real walk sheet, not the placeholder silhouette",
                  tostring(who and who.spriteId))
            check(who ~= nil and type(who.name) == "string"
                    and who.name ~= "" and who.name ~= "FRIEND",
                  "...named as the trainer and not as an absent peer",
                  tostring(who and who.name))

            -- The roster chips, end to end through the real referee.
            --
            -- A solo fight runs the same `BattleSim` `Turn` an MMO fight does,
            -- over a table transport instead of a socket, so this is the leg
            -- that proves the `team` events are actually emitted, sanitised
            -- and stored -- on the one path where the trainer's party is not
            -- otherwise knowable to the screen. Nothing on this client holds
            -- the NPC's sheets: if the chip has a roster, the referee sent it.
            local mineTeam = arena and arena.mineTeam or nil
            local foeTeam = arena and arena.foeTeam or nil
            log(("solo trainer rosters: mine=%s foe=%s"):format(
              tostring(mineTeam), tostring(foeTeam)))
            check(type(mineTeam) == "string" and #mineTeam > 0,
                  "the referee published our own party roster",
                  tostring(mineTeam))
            check(type(foeTeam) == "string" and #foeTeam > 0,
                  "...and the trainer's, which is the only source there is "
                  .. "for a party this client never held",
                  tostring(foeTeam))
            check(who ~= nil and who.party == foeTeam,
                  "...and it is what the trainer's roster chip draws from",
                  tostring(who and who.party))
            local us = arena and arena.allyHumans and arena.allyHumans[1] or nil
            check(us ~= nil and us.party == mineTeam,
                  "our own chip reads the referee too, not the uploaded sheets",
                  tostring(us and us.party))
          end
        end

        local over, seen = fightToEnd(360)
        check(over, "the solo trainer fight runs to an end", tostring(seen))
        check(backToOverworld(), "and the overworld is restored")
        shot("solo-trainer-after")

        check(finished == "win",
              "the engine's trainer battle got its result back -- which is the "
              .. "script that was waiting, resumed", tostring(finished))
        check(not H.onStack(game, staged),
              "and it is off the stack, so the trainer is not refought")
        check(moneyOf() > moneyBefore,
              "prize money was paid onto the save",
              ("%d -> %d"):format(moneyBefore, moneyOf()))
        check(expOf(lead()) > expBefore,
              "and the trainer's mons paid exp",
              ("%d -> %d"):format(expBefore, expOf(lead())))

        -- Walking is the honest test of "the world is the player's again":
        -- StateStack only updates its top, so a leaked screen freezes the
        -- overworld and no direction moves anybody. Four directions, because
        -- wherever the last warp left us at least one of them is open.
        local from = H.playerCell(game)
        local moved = false
        for _, dir in ipairs({ "down", "up", "left", "right" }) do
          if moved then break end
          U.hold(game, dir, 18)
          U.wait(10)
          local now = H.playerCell(game)
          moved = from ~= nil and now ~= nil
            and (now.x ~= from.x or now.y ~= from.y or now.mapId ~= from.mapId)
        end
        check(moved, "and the player can walk again",
              from and (tostring(from.mapId) .. " " .. tostring(from.x)
                        .. "," .. tostring(from.y)) or "?")
      end
    end
  end

  -- ------------------------------------------------------------------
  -- 7. a real sighted trainer, for the defeated flag
  -- ------------------------------------------------------------------
  --
  -- stageTrainer above pushes a battle nobody walked into, so it has no npcId
  -- and there is no flag for the world to set -- what it can prove is the
  -- payout and the handoff, and it does. The defeated flag needs a trainer
  -- who exists in the world, which means walking into a real sight line.
  --
  -- mmo_util's sight helpers read Gen 1's map objects (`movement == "STAY"`
  -- plus a `range` cone); Gold spells NPC movement as numeric SPRITEMOVEDATA
  -- and has no such record, so `sightTrainerOn` answers nil there and this leg
  -- skips rather than failing for a shape it was never written against.
  if SINGLES then
    local SIGHT_MAP = "ROUTE_3"
    local sightObj = H.sightTrainerOn(game.data, SIGHT_MAP)
    if sightObj == nil then
      skip("the sighted-trainer leg",
           ("no Gen 1-shaped sight trainer on %s (generation %d)")
             :format(SIGHT_MAP, GEN))
    else
      freshParty()
      local npcId = H.sightNpcId(SIGHT_MAP, sightObj)
      log("sight trainer:", tostring(sightObj.name), "npcId", tostring(npcId),
          "class", tostring(sightObj.trainerClass))
      local defeatedBefore = game.save and game.save.defeatedTrainers
        and game.save.defeatedTrainers[npcId] or nil
      check(defeatedBefore ~= true, "and it has not been beaten yet")

      check(H.warpToSightLine(game, SIGHT_MAP, sightObj,
              { dist = 2, behind = 0, side = 1 }) ~= nil,
            "warped beside the trainer's sight line")
      check(H.awaitOnMap(game, SIGHT_MAP, 90), "arrived on " .. SIGHT_MAP)

      -- Latched from inside the walk: the divert takes the engine's battle
      -- over the frame it is pushed, and after the fight the ritual unwinds it
      -- -- so the window in which the stack names it is the fight itself.
      local staged, finished = nil, nil
      local function catchStaged()
        if staged then return staged end
        staged = H.captureStagedTrainer(game)
        if staged then
          H.wrapBattleFinish(staged, function(result) finished = result end)
          H.softenTopTrainer(game)
        end
        return staged
      end

      check(H.walkIntoTrainerSight(game, sightObj, { dist = 2 }),
            "walked into the trainer's sight")
      local diverted = H.waitFor(game, function()
        catchStaged()
        H.softenTopTrainer(game)
        if H.isMediatedBattle(H.top(game)) then return true end
        local top = H.top(game)
        -- The pre-battle text is a plain box; advance it, never a menu row.
        if top ~= nil and top.items == nil and not H.isMediatedBattle(top) then
          U.tap(game, "a")
        end
        return false
      end, 60 * 10, "the sighted trainer to divert onto the mod's screen")
      check(diverted,
            "a trainer walked into for real diverts onto this mod's screen")
      catchStaged()
      check(staged ~= nil,
            "and the engine's own trainer battle was caught underneath it")
      shot("solo-sight-trainer")

      if diverted then
        check(awaitCommandMenu("the sighted-trainer command grid"),
              "the command grid opens")
        local over, seen = fightToEnd(360)
        check(over, "the sighted trainer fight runs to an end", tostring(seen))
        check(backToOverworld(), "and the overworld is restored")
        shot("solo-sight-after")
        check(finished == "win",
              "the world's own onFinish ran -- the script resumed",
              tostring(finished))
        local defeated = game.save and game.save.defeatedTrainers
          and npcId and game.save.defeatedTrainers[npcId] == true
        check(defeated == true,
              "and defeatedTrainers marks the sighted trainer beaten",
              tostring(npcId))
        -- No rematch: the buried battle must be gone, not merely off the top.
        local buried = false
        for _, state in ipairs((game.stack and game.stack.states) or {}) do
          if state and state.kind == "trainer" then buried = true end
        end
        check(not buried,
              "no trainer BattleState left buried under the overworld")
      end
    end
  end

  -- ------------------------------------------------------------------
  -- 8. a catch, exactly once
  -- ------------------------------------------------------------------
  --
  -- Last, so the party growth it asserts is unambiguous: every earlier leg
  -- reseeds a one-member party, and this one deliberately does not run before
  -- anything that would.
  if SINGLES then
    freshParty()
    check(H.giveItem(game, "MASTER_BALL", 1), "seeded a MASTER_BALL")
    local ballsBefore = (game.save.inventory
      and game.save.inventory.MASTER_BALL) or 0
    local partyBefore = H.partySpeciesCount(game)

    local finished = nil
    local staged, species = stageWildOf({ "RATTATA", "SENTRET", "PIDGEY" }, 5,
      function(result) finished = result end)
    check(staged ~= nil, "staged a wild encounter to catch", tostring(species))
    local speciesBefore = species and H.partySpeciesCount(game, species) or 0

    if staged then
      check(awaitDivert("the solo catch divert"),
            "the encounter diverts onto this mod's battle screen")
      check(awaitCommandMenu("the command grid before MASTER_BALL"),
            "the command grid opens")
      check(throwItem("MASTER_BALL"),
            "filed MASTER_BALL from the ITEM menu")
      local over, seen = fightToEnd(240)
      check(over, "the catch runs the fight to an end", tostring(seen))
      check(backToOverworld(), "and the overworld is restored")
      shot("solo-catch-after")

      local ballsAfter = (game.save.inventory
        and game.save.inventory.MASTER_BALL) or 0
      check(ballsAfter < ballsBefore, "the ball was spent",
            ("%d -> %d"):format(ballsBefore, ballsAfter))
      check(H.partySpeciesCount(game) == partyBefore + 1,
            "the party grew by exactly one",
            ("%d -> %d"):format(partyBefore, H.partySpeciesCount(game)))
      check(species ~= nil
            and H.partySpeciesCount(game, species) == speciesBefore + 1,
            ("the caught %s is in the party exactly once"):format(
              tostring(species)),
            ("%d -> %s"):format(speciesBefore,
              tostring(species and H.partySpeciesCount(game, species))))
      check(finished == "caught",
            "and the engine's battle was told 'caught', not 'win' -- a catch "
            .. "must not read back as a trainer beaten", tostring(finished))
    end
  end

  -- ------------------------------------------------------------------
  -- 9. the carts' own rules against the computer
  -- ------------------------------------------------------------------
  --
  -- docs/plans/gen12-referee-fidelity.md (§1 items 7-9, test row TT-E): what
  -- the referee does on Red and Gold now that it follows pokered / pokecrystal,
  -- proved on the live solo path -- a real save monster, a real engine battle
  -- staged and diverted, the real referee, the real screen, and the save after.
  -- Every assertion reads the referee's own event stream (its `_emit`,
  -- watched, less any clip it took back before sending -- K22) or the save;
  -- the screen's lines (its `say`, watched) are checked to carry the
  -- referee's words -- word for word where the leg is about the line, its
  -- marks said for side a ("Enemy " before the foe's monster, nothing before
  -- the player's: K17) and its breaks kept (K18).  One screenshot per leg.
  --
  --   obey-traded     Red and Gold: a traded L50 lead (its OT id is not the
  --                   save's player id -- `mon.otId` against `save.player.id`,
  --                   MediatedBattle.tradedOf) with no badges, against a wild
  --                   monster, disobeys in the cart's lines: "is loafing
  --                   around." / "won't obey!" / "turned away!" / "ignored
  --                   orders!", "began to nap!", "won't obey!" with the
  --                   self-hit, "used instead, <move>" -- seeds are fought until
  --                   each kind has been said; every one is the referee's msg,
  --                   said on the screen, and every fight is still won
  --   obey-capless    the same traded lead with EARTHBADGE (Red) / RISINGBADGE
  --                   (Gold): no level cap, so it obeys -- not one line, and its
  --                   move is the turn's first
  --   obey-asleep     Gold: the traded lead put to sleep (the foe's SPORE) and
  --                   told to SNORE: "ignored orders...sleeping!", said while the
  --                   referee holds it asleep.  Red has neither SNORE nor SLEEP
  --                   TALK; skipped there
  --   priority-quick  Red and Gold: QUICK ATTACK moves before a foe the referee
  --                   rates faster; the same fight with SCRATCH (same seed, same
  --                   Speeds) moves second
  --   held-leftovers  Gold: LEFTOVERS heals a sixteenth of the maximum at the
  --                   end of the turn, and is still held on the save after
  --   held-berry      Gold: a BERRY under half HP is eaten for its parameter's
  --                   worth, and is gone from the save after the fight
  --   held-quickclaw  Gold: QUICK CLAW moves its slower holder first (seeds are
  --                   fought until it fires), and that seed without it does not
  --   held-thief      Gold: a wild foe whose only move is THIEF takes the lead's
  --                   item, and the save has lost it after the fight
  --   held-smokeball  Gold: SMOKE BALL gets away on the first RUN, on a seed
  --                   whose same RUN without it is refused ("Can't escape!")
  --
  -- The referee-gap legs (group "gaps"; docs/plans/gen12-referee-gaps-fix.md
  -- §1 and TT-E -- what CHANGELOG 1.5.0 "Every Red and Gold move now works the
  -- cart's way" shipped):
  --
  --   payday          Red and Gold: the lead's PAY DAY scatters coins (the
  --                   referee's "Coins scattered everywhere!", 2 x its level
  --                   each), the fight is won, and the outcome's pot
  --                   (contract K11) lands on the save's money with the cart's
  --                   "<PLAYER> picked up / ¥N!" said exactly once.  Red: a
  --                   TELEPORT escape after PAY DAY pays too, a plain RUN does
  --                   not.  Gold: AMULET COIN on the lead (a monster that was
  --                   sent out) doubles what is paid; a control without it
  --                   pays the pot as is
  --   trainer-item    Gold: a real trainer whose party monster holds an item
  --                   (TRAINERTYPE_ITEM, looked up in the player's own data):
  --                   the foe's sheet on the referee's field carries it, the
  --                   lead's THIEF takes it (`held` pair and the cart's line),
  --                   and the save's lead holds it after the won fight
  --   sleep-talk      Gold: SLEEP TALK told while awake fails ("But it
  --                   failed!"); once the foe's SPORE has the lead asleep it
  --                   calls the lead's other move (the referee's "used" line),
  --                   which spends no PP of its own
  --   level-up        Red and Gold: a lead one EXP point short of its next
  --                   level against a two-monster trainer: the first knockout's
  --                   EXP levels it, the client's K9 `battle_moveset` reaches
  --                   the referee mid-fight (`sim:levelUp`, accepted), the
  --                   referee's level, stats and maximum HP for it rise to the
  --                   K9 numbers, it fights on, and the save's level and stats
  --                   after the fight are those numbers
  --   weather         Gold: RAIN DANCE then WATER GUN against the same seed's
  --                   SPLASH then WATER GUN (the same draws, no rain): the
  --                   rain's hit is the boosted one (~x1.5); "A downpour
  --                   started!", four "Rain continues to fall." and "The rain
  --                   stopped." -- five turns -- each said on the screen
  --   baton-pass      Gold: SWORDS DANCE (the `stat` event's signed K10 stage
  --                   +2), then BATON PASS with the client's picker naming the
  --                   third party member (the FIGHT choice's `pass`): that one
  --                   comes in, not the referee's default, and keeps the stage
  --
  -- Stats, levels and HP pinned on the monsters are synthetic fixture values;
  -- move and item ids are pret names looked up in the player's own data, and
  -- every number asserted is the referee's, the save's, or the player's own
  -- item row's.
  local function rulesLegs12()
    local legs = { "obey-traded", "obey-capless", "obey-asleep", "priority-quick",
                   "held-leftovers", "held-berry", "held-quickclaw", "held-thief",
                   "held-smokeball" }
    local gapLegs = { "payday", "trainer-item", "sleep-talk", "level-up", "weather",
                      "baton-pass" }
    local function wants(name) return legOn(name, name:match("^(%a+)%-")) end
    local function wantsGap(name) return legOn(name, "gaps") end
    local any = false
    for _, name in ipairs(legs) do
      if wants(name) then any = true end
    end
    for _, name in ipairs(gapLegs) do
      if wantsGap(name) then any = true end
    end
    if not any then return end

    local ctx = H.modCtx(game)
    local solo = ctx and ctx.solo
    if not check(type(solo) == "table" and type(solo.isOn) == "function",
                 "the live SoloBattle instance is reachable for the rules legs") then
      return
    end
    -- The row is on for these: leg 3 flips it, and a run without "singles"
    -- sets it in the store mod.options:get reads.
    if game.mods and game.mods.modOptions then
      game.mods.modOptions[MOD_ID] = game.mods.modOptions[MOD_ID] or {}
      game.mods.modOptions[MOD_ID][OPTION_KEY] = true
    end
    check(solo:isOn(), "SOLO BATTLES is on for the rules legs")

    local data = game.data or {}
    local GOLD = GEN == 2
    local WILDS = GOLD and { "SENTRET", "RATTATA", "PIDGEY" } or { "PIDGEY", "RATTATA" }
    local function haveMove(id) return type(data.moves) == "table" and data.moves[id] ~= nil end
    local function itemRow(id) return type(data.items) == "table" and data.items[id] or nil end
    -- The cart's glyphs flattened for the screen matchers: ’ as ', and the one
    -- "…" tile (pokecrystal IgnoredSleepingText) as three dots -- read as one
    -- sentence first (H.plainBattleLine: a row the cart broke after a hyphen
    -- joined whole, every other break a space).
    local function flat12(text)
      return (H.plainBattleLine(tostring(text or "")):gsub("\226\128\153", "'")
        :gsub("\226\128\166", "..."):gsub("%s+", " "):lower())
    end

    -- ------- the referee's lines, as the player's screen reads them
    --
    -- The Red / Gold referee writes `^a` / `^b` before a battler's name the
    -- cart prefixes and breaks its rows where the cart's text does (contracts
    -- K17 / K18 of docs/plans/gen12-referee-remaining-gaps.md); a solo screen
    -- is side a's (the player's side in every fight against the computer), so
    -- it says the foe's mark as "Enemy " and its own as nothing.  `rec.events`
    -- keep the referee's text as it was sent; `rec.said` keeps what the
    -- screen was handed.
    --   plain12  one sentence, marks out -- the referee's words
    --   view12   exactly the text the screen's `say` gets for that line
    --   read12   view12 as one sentence -- what the player reads
    local SOLO_SIDE = "a"
    local function plain12(text) return H.plainBattleLine(text) end
    local function view12(text) return H.viewBattleLine(text, SOLO_SIDE) end
    local function read12(text) return H.readBattleLine(text, SOLO_SIDE) end
    -- Whose monster a referee line opens with (its leading mark), or nil.
    local function markOf(text)
      return type(text) == "string" and text:match("^%^([ab])") or nil
    end

    -- ------- the monsters

    -- `ids`, at full PP off the player's own move rows, in the shape each
    -- engine keeps a party move ({ id, pp } -- Gold's carries maxPp too).
    local function setMoves(mon, ids)
      local list = {}
      for i, id in ipairs(ids) do
        local row = type(data.moves) == "table" and data.moves[id] or nil
        local pp = tonumber(row and row.pp) or 10
        list[i] = { id = id, pp = pp, maxPp = pp }
      end
      mon.moves = list
    end

    -- Speed, maximum HP, current HP, status and (Gold) the held item -- the
    -- fields the battle sheet is cut from (MediatedBattle.snapshotMons:
    -- `stats`, `hp`, `status`, `item`).  `dvs` (Gold) fixes the four DVs and
    -- recomputes every stat from them first (Mon.refreshStats, as Battle.new
    -- does), so two fights compared on one seed field the same monsters --
    -- a fresh Mon.new rolls its DVs.
    local function pin(mon, p)
      if p.dvs and GOLD then
        local okM, Mon = pcall(require, "src.battle.gen2.Mon")
        if okM and Mon then
          local dvs = { attack = p.dvs.attack, defense = p.dvs.defense,
                        speed = p.dvs.speed, special = p.dvs.special }
          dvs.hp = Mon.hpDV(dvs)
          mon.dvs = dvs
          Mon.refreshStats(mon, data)
        end
      end
      mon.stats = mon.stats or {}
      if p.speed then mon.stats.speed = p.speed end
      if p.maxHp then
        mon.stats.hp = p.maxHp
        if mon.maxHp ~= nil or GOLD then mon.maxHp = p.maxHp end
      end
      local max = tonumber(mon.stats.hp) or tonumber(mon.maxHp) or 1
      local hp = max
      if p.hpAt then hp = p.hpAt(max) end
      if p.hp then hp = p.hp end
      mon.hp = math.max(1, math.min(max, math.floor(hp)))
      mon.status = p.status
      if GOLD then mon.item = p.item end
    end

    -- The save's player id, which the engines stamp on a new monster as its OT
    -- id (BattleState.stampOT, Gold's Mon.stampOT) -- given a synthetic one on
    -- a save that has not stamped one yet, exactly as those two would.
    local function playerId()
      local player = game.save and game.save.player
      if type(player) ~= "table" then return nil end
      if tonumber(player.id) == nil then player.id = 4321 end
      return math.floor(tonumber(player.id)) % 65536
    end

    -- The EXP the monster's next level starts at, off its own growth curve in
    -- the player's data (Red src/pokemon/Growth.lua, Gold Mon.experienceForLevel).
    local function expForNext(mon)
      local def = type(data.pokemon) == "table" and data.pokemon[mon.species] or nil
      if not def then return nil end
      local nextLevel = (tonumber(mon.level) or 1) + 1
      if GOLD then
        local okM, Mon = pcall(require, "src.battle.gen2.Mon")
        if not (okM and Mon) then return nil end
        return Mon.experienceForLevel(Mon.growthFor(data, def.growthRate), nextLevel)
      end
      local okG, Growth = pcall(require, "src.pokemon.Growth")
      if not (okG and Growth) then return nil end
      return Growth.expForLevel(def.growthRate, nextLevel, data.growth_rates)
    end

    -- A party: the generation's L50 lead with exactly `spec.moves` (none: the
    -- species' own, strongest first -- H.frontloadDamage).  `traded` gives it
    -- an OT id one off the player's (and an OT name that is not theirs);
    -- otherwise its OT id is the player's own.  `bench` (Gold) puts more of
    -- the player's own monsters behind it ({ species, level?, moves }).
    -- `toNextLevel` leaves the lead one EXP point short of its next level.
    local function seedLead(spec)
      local mon = H.seedParty(game, spec.species or partySpecies(), spec.level or 50)
      if not mon then return nil end
      if spec.moves then setMoves(mon, spec.moves) else H.frontloadDamage(data, mon) end
      pin(mon, spec)
      local pid = playerId()
      if pid and spec.traded then
        mon.otId = (pid + 1) % 65536
        mon.ot, mon.otName = "TRADER", "TRADER"
      elseif pid then
        mon.otId = pid
      end
      if spec.toNextLevel then
        local need = expForNext(mon)
        if need and need > 0 then
          if GOLD then mon.experience = need - 1 else mon.exp = need - 1 end
        end
      end
      if spec.bench and GOLD then
        local okM, Mon = pcall(require, "src.battle.gen2.Mon")
        for _, b in ipairs(spec.bench) do
          local extra = okM and Mon and Mon.new(data, b.species, b.level or 50) or nil
          if extra then
            if b.moves then setMoves(extra, b.moves) end
            if pid then extra.otId = pid end
            game.save.party[#game.save.party + 1] = extra
          end
        end
      end
      return mon
    end

    local function tweakFoe(mon, foe)
      if foe.moves then setMoves(mon, foe.moves) end
      pin(mon, { speed = foe.speed, maxHp = foe.maxHp, hp = foe.hp, item = foe.item, dvs = foe.dvs })
    end

    -- ------- badges

    -- Gold keeps its badges in `save.player.badges` by name (Battle:hasBadge);
    -- Red under each badge's inventory key (Badges.itemFor: the
    -- `constants.badges` record's `item`, else its id).  Undone after the fight.
    local undoBadges = nil
    local function badgeKey1(id)
      for _, entry in ipairs((data.constants and data.constants.badges) or {}) do
        if type(entry) == "table" and entry.id == id then
          return (type(entry.item) == "string" and entry.item ~= "") and entry.item or id
        end
      end
      return id
    end
    local function setBadges12(list)
      local save = game.save
      if GOLD then
        local player = save.player
        local was = player.badges
        player.badges = {}
        for _, name in ipairs(list or {}) do player.badges[name] = true end
        undoBadges = function() player.badges = was end
      else
        save.inventory = save.inventory or {}
        local kept = {}
        for _, id in ipairs(list or {}) do
          local key = badgeKey1(id)
          kept[#kept + 1] = { key = key, was = save.inventory[key] }
          save.inventory[key] = 1
        end
        undoBadges = function()
          for _, k in ipairs(kept) do save.inventory[k.key] = k.was end
        end
      end
    end
    local function clearBadges12()
      if undoBadges then undoBadges() end
      undoBadges = nil
    end

    -- ------- staging

    -- A wild encounter built the way mmo_util's `stageWild` builds one, with
    -- `tweak(mon)` run on the engine's own wild monster and `repin()` on the
    -- player's lead *before* the push: the divert fires inside the push
    -- (stageRefusedWild's reason), so a field set afterwards would never reach
    -- the sheet.  On Gold both run after Battle.new as well, which recomputes
    -- every monster's stats from its DVs and level (Mon.refreshStats, as the
    -- cart's party struct does) and would otherwise undo a pinned Speed or HP.
    -- Gold's callbacks are restamped to World:startBattle's popping shape
    -- (likeWorldStartBattle).
    local function stageTweakedWild(species, level, tweak, onFinish, repin)
      if GOLD then
        local okB, Battle = pcall(require, "src.battle.gen2.Battle")
        local okM, Mon = pcall(require, "src.battle.gen2.Mon")
        local okS, Screens = pcall(require, "src.ui.Screens")
        if not (okB and Battle and okM and Mon and okS and Screens) then
          return nil, "gen2 battle modules unavailable"
        end
        local wild = Mon.new(data, species, level)
        if not wild then return nil, "no such species: " .. tostring(species) end
        tweak(wild)
        local okNew, battle = pcall(Battle.new, {
          data = data, party = (game.save and game.save.party) or {}, wild = wild, save = game.save,
        })
        if not (okNew and battle) then return nil, tostring(battle) end
        tweak(wild)
        if repin then repin() end
        local okPush, state = pcall(Screens.push, game, "Gen2BattleState",
          { battle = battle, save = game.save })
        if not (okPush and type(state) == "table") then
          return nil, "Gen2BattleState never came up: " .. tostring(state)
        end
        state.kind = "wild"
        state.enemyParty = battle.enemyParty or { wild }
        return likeWorldStartBattle(state, onFinish)
      end
      local BattleState = require("src.battle.BattleState")
      local ok, battle = pcall(BattleState.newWild, game, species, level)
      if not (ok and battle and not battle.dead) then return nil, "newWild refused " .. tostring(species) end
      local mon = battle.enemy and battle.enemy.mon
      if not mon then return nil, "the wild battle has no enemy monster" end
      tweak(mon)
      if repin then repin() end
      battle.onFinish = onFinish
      game.stack:push(battle)
      return battle
    end

    -- ------- watching

    -- Everything the referee emits from here on, each with the turn it was
    -- emitted in and what the player's monster then was (status, HP, party
    -- index, stat stages); and every line the screen is handed to say.  Also
    -- the referee's side of three seams the gap legs read: every choice filed
    -- into it (`choices`: a BATON PASS's `pass`), every mid-fight level-up
    -- handed to it (`levelUps`, contract K9: what it was told, whether it
    -- took it, the monster before and after) and the outcome the screen was
    -- given (`outcome`: K11's `payDay`).
    local function copy12(t)
      if type(t) ~= "table" then return nil end
      local out = {}
      for k, v in pairs(t) do out[k] = v end
      return out
    end
    local function monState12(m)
      if type(m) ~= "table" then return nil end
      return { level = m.level, maxHp = m.maxHp, hp = m.hp,
               stats = copy12(m.partyStats or m.stats) }
    end
    local function watch12(sim, med)
      local rec = { events = {}, said = {}, choices = {}, levelUps = {} }
      local emit = sim._emit
      sim._emit = function(self, kind, fields)
        local ev = emit(self, kind, fields)
        if ev then
          local pf = self.byId and self.byId.solo_player
          local pm = pf and pf.active and pf.mons and pf.mons[pf.active]
          local row = copy12(ev)
          row.turn = self.turn
          row.pStatus, row.pHp = pm and pm.status, pm and pm.hp
          row.pActive, row.pStages = pf and pf.active, pm and copy12(pm.stages)
          row.src = ev
          rec.events[#rec.events + 1] = row
        end
        return ev
      end
      -- A move's clip the referee takes back before it is sent (K22: the
      -- carts play none for a move that missed or failed -- Red's
      -- `_dropMoveAnim`, Gold's `_noAnim` pull it out of the outgoing buffer)
      -- is taken out of this record too, so `rec.events` stays what the
      -- screen was actually sent.
      for _, name in ipairs({ "_dropMoveAnim", "_noAnim" }) do
        local takeBack = sim[name]
        if type(takeBack) == "function" then
          sim[name] = function(self, ...)
            local before = {}
            for _, b in ipairs(self.buffer or {}) do before[b] = true end
            local r1, r2 = takeBack(self, ...)
            local still = {}
            for _, b in ipairs(self.buffer or {}) do still[b] = true end
            for k = #rec.events, 1, -1 do
              local src = rec.events[k].src
              if src ~= nil and before[src] and not still[src] then table.remove(rec.events, k) end
            end
            return r1, r2
          end
        end
      end
      local submit = sim.submitChoice
      if type(submit) == "function" then
        sim.submitChoice = function(self, seat, payload, ...)
          if type(payload) == "table" then
            rec.choices[#rec.choices + 1] = {
              seat = seat, action = payload.action, move = payload.move,
              pass = payload.pass, slot = payload.slot, turn = self.turn,
            }
          end
          return submit(self, seat, payload, ...)
        end
      end
      local levelUp = sim.levelUp
      if type(levelUp) == "function" then
        sim.levelUp = function(self, playerId, index, level, stats, maxHp, ...)
          local f = self.byId and self.byId[playerId]
          local m = f and f.mons and f.mons[index]
          local before = monState12(m)
          local ok = levelUp(self, playerId, index, level, stats, maxHp, ...)
          rec.levelUps[#rec.levelUps + 1] = {
            playerId = playerId, index = index, level = level, stats = copy12(stats),
            maxHp = maxHp, ok = ok, before = before, after = monState12(m),
            active = f and f.active, at = #rec.events, result = self.result ~= nil,
          }
          return ok
        end
      end
      local onOutcome = med.onOutcome
      if type(onOutcome) == "function" then
        med.onOutcome = function(self, msg, ...)
          if type(msg) == "table" and rec.outcome == nil then
            rec.outcome = { reason = msg.reason, payDay = msg.payDay, outcome = msg.outcome }
          end
          return onOutcome(self, msg, ...)
        end
      end
      local say, depth = med.say, 0
      med.say = function(self, text, ...)
        if depth == 0 and type(text) == "string" then rec.said[#rec.said + 1] = text end
        depth = depth + 1
        local ok, err = pcall(say, self, text, ...)
        depth = depth - 1
        if not ok then error(err, 0) end
      end
      return rec
    end

    -- Every `msg` of the fight: `raw` the referee's text, `text` as the
    -- player reads it (`read12`).
    local function msgsOf(rec)
      local out = {}
      for i, e in ipairs(rec.events) do
        if e.t == "msg" then
          out[#out + 1] = { i = i, raw = e.text, text = read12(e.text), turn = e.turn, pStatus = e.pStatus }
        end
      end
      return out
    end
    -- The screen said `text` -- a referee line (marks and breaks) or a
    -- literal -- in the player's words: both read as one sentence, so a leg
    -- about what a line says does not hang on where the cart breaks it.
    local function screenSaid(rec, text)
      local want = read12(text)
      for _, line in ipairs(rec.said) do
        if plain12(line) == want then return true end
      end
      return false
    end
    -- ...and word for word: the line the screen was handed is the referee's
    -- `raw`, its marks said for side a and its breaks kept (K17 / K18).
    local function screenSaidExact(rec, raw)
      local want = view12(raw)
      for _, line in ipairs(rec.said) do
        if line == want then return true end
      end
      return false
    end
    local function screenSaidLike(rec, needle)
      for _, line in ipairs(rec.said) do
        if flat12(line):find(needle, 1, true) then return true end
      end
      return false
    end
    -- The names a move's "used" line may call `id` by: the sheet's (the
    -- player's move row's `name`, which the referee prints -- moveLabel) and
    -- the id's own words.
    local function moveNames12(id)
      local names = { (tostring(id):gsub("_", " ")) }
      local row = type(data.moves) == "table" and data.moves[id] or nil
      if row and type(row.name) == "string" and row.name ~= "" then names[#names + 1] = row.name end
      return names
    end
    -- A "<USER>\nused <MOVE>!" line (pokered _UsedMove1Text, pokecrystal
    -- UsedMoveText) naming one of `ids`: whose (its mark) and which.
    local function usedLineOf(text, ids)
      local side = markOf(text)
      if not side then return nil end
      local plain = plain12(text)
      for _, id in ipairs(ids) do
        for _, name in ipairs(moveNames12(id)) do
          local tail = " used " .. name .. "!"
          if #plain > #tail and plain:sub(-#tail) == tail then return side, id end
        end
      end
      return nil
    end
    -- The first use of one of `ids` this fight: its side and move.  A use is
    -- the move's own clip (an `anim` naming it, not `quiet` -- K22's residual
    -- and charge beats are nobody's use) or its "used" line, whichever came
    -- first: a move that misses plays no clip on either cart (pokered
    -- handleIfPlayerMoveMissed, pokecrystal BattleCommand_MoveAnim's
    -- wAttackMissed test) and still printed its line.
    local function firstMove(rec, ids)
      local want = {}
      for _, id in ipairs(ids) do want[id] = true end
      for _, e in ipairs(rec.events) do
        if e.t == "anim" and want[e.text] and not e.quiet then return e.side, e.text end
        if e.t == "msg" then
          local side, id = usedLineOf(e.text, ids)
          if side then return side, id end
        end
      end
      return nil
    end
    local function eventAfter(rec, from, pred)
      for j = from + 1, #rec.events do
        if pred(rec.events[j]) then return rec.events[j], j end
      end
      return nil
    end

    -- ------- driving

    -- `pick.passTo` (a sheet index, Gold): the party picker BATON PASS opens
    -- (MediatedBattle `asksPass` -> phase "switch") is answered with that
    -- monster, through the picker's own cursor and A.  Answers "picker" when
    -- the picker was up and answered.
    local function choose12(m, pick)
      local want = pick.run and "RUN" or "FIGHT"
      local list = (type(m.commandList) == "function" and m:commandList()) or {}
      for i, c in ipairs(list) do
        if c == want then m.commandIndex = i end
      end
      U.tap(game, "a"); U.wait(8)
      if not pick.run and m.phase == "move" then
        m.cursor = pick.move or 1
        U.tap(game, "a"); U.wait(8)
        if pick.passTo and m.phase == "switch" and type(m.partyRows) == "function" then
          local n, at = 0, nil
          for _, row in ipairs(m:partyRows()) do
            if not row.fainted and not row.active then
              n = n + 1
              if row.index == pick.passTo then at = n end
            end
          end
          if at then m.switchIndex = at end
          U.tap(game, "a"); U.wait(8)
          return at and "picker" or "picker-missing"
        end
      end
      return nil
    end

    -- One staged wild fight, driven to its end.  spec: label, seed, lead (for
    -- seedLead), foe ({ species?, level?, moves, speed?, maxHp?, hp?, item?,
    -- dvs? }), badges, pick(turn, rec) -> { move = n, passTo? } | { run = true }
    -- (default: move 1 every turn), shotWhen(flatLine) -> bool and shotName
    -- (the one screenshot, the first time the screen shows such a line).
    -- `stage(onFinish, repin)` -> state, why, label stages something else (a
    -- trainer) in place of the wild encounter; `foe` is then unused.
    local function rulesFight(spec)
      local L = spec.label
      backToOverworld(10)
      local mon = seedLead(spec.lead)
      if not check(mon ~= nil, L .. ": the lead was seeded") then return nil end
      setBadges12(spec.badges)
      local seedBefore, randomBefore = solo.seedFn, solo.randomFn
      solo.seedFn = function() return spec.seed end
      -- Gold's wild held-item roll (MediatedBattle.rollWildItem2) reads this
      -- byte source: 0 is under its 192, "no item", so the foe holds exactly
      -- what the leg gives it.
      solo.randomFn = function() return 0 end
      local finished
      local staged, why, species
      if spec.stage then
        staged, why, species = spec.stage(function(result) finished = result end,
          function() pin(mon, spec.lead) end)
      else
        local foe = spec.foe or {}
        for _, name in ipairs(foe.species or WILDS) do
          staged, why = stageTweakedWild(name, foe.level or 5,
            function(m) tweakFoe(m, foe) end,
            function(result) finished = result end,
            function() pin(mon, spec.lead) end)
          if staged then species = name break end
        end
      end
      solo.seedFn, solo.randomFn = seedBefore, randomBefore
      local med, sim = medOnStack(), solo.sim
      if not check(staged ~= nil and med ~= nil and sim ~= nil,
                   L .. (spec.stage and ": the staged fight" or ": the staged wild fight")
                     .. " was taken onto the mod's screen",
                   staged and tostring(species) or tostring(why)) then
        if staged and not med then dropStaged(staged) end
        clearBadges12()
        backToOverworld()
        return nil
      end
      local rec = watch12(sim, med)
      rec.label, rec.seed, rec.species, rec.med, rec.staged = L, spec.seed, species, med, staged
      local pf, ff = sim.byId.solo_player, sim.byId.solo_foe
      local pm = pf and pf.mons and pf.active and pf.mons[pf.active]
      local fm = ff and ff.mons and ff.active and ff.mons[ff.active]
      local function speed(f, m)
        local ok, v = pcall(sim._speedOf, sim, f, m)
        return ok and tonumber(v) or nil
      end
      local function ids(m)
        local out, labels = {}, {}
        for i, mv in ipairs((m and m.moves) or {}) do
          out[i] = mv.id
          labels[i] = mv.name or mv.id
        end
        return out, labels
      end
      if pm and fm then
        local moves, labels = ids(pm)
        rec.facts = {
          species = pm.species, level = pm.level, traded = pm.traded, rules = pf.badgeRules == true,
          badges = pf.badges, foeTraded = fm.traded, foeSpecies = fm.species,
          speedP = speed(pf, pm), speedF = speed(ff, fm), hp = pm.hp, maxHp = pm.maxHp,
          heldItem = pm.heldItem, holdEffect = pm.holdEffect, holdParam = pm.holdParam,
          itemName = pm.itemName, foeHeld = fm.heldItem, foeMoves = (ids(fm)),
          moves = moves, moveLabels = labels, mode = sim.mode,
        }
      end
      check(rec.facts ~= nil, L .. ": both monsters are on the referee's field")
      check(awaitCommandMenu(L .. "'s command grid"), L .. ": the command grid opens")
      local turn = 0
      rec.over = H.waitSeconds(game, function()
        local m = medOnStack()
        if not m then return true end
        if H.top(game) ~= m then
          U.tap(game, "a"); U.wait(6)
          return medOnStack() == nil
        end
        if spec.shotWhen and not rec.shot and type(m.shown) == "string"
            and spec.shotWhen(flat12(m.shown)) then
          rec.shot = true
          rec.shownLine = flat12(m.shown)
          U.wait(24)
          shot(spec.shotName)
        end
        if m.phase == "choose" then
          turn = turn + 1
          local how = choose12(m, (spec.pick and spec.pick(turn, rec)) or { move = 1 })
          if how then rec[how] = (rec[how] or 0) + 1 end
        else
          U.tap(game, "a"); U.wait(4)
        end
        return medOnStack() == nil
      end, spec.seconds or 300, L .. " to end")
      rec.turns = turn
      check(rec.over, L .. ": the fight ran to its end", ("%d command(s)"):format(turn))
      check(backToOverworld(), L .. ": and the overworld is back")
      clearBadges12()
      rec.result = finished
      rec.after = lead()
      return rec
    end

    -- ------- obedience

    -- The cart's disobedience lines as the referee spells them after the
    -- monster's name (pokered engine/battle/core.asm CheckForDisobedience and
    -- text_2.asm; pokecrystal BattleCommand_CheckObedience and
    -- data/text/battle.asm -- src/BattleSim/Turn.lua LOAF_TEXT / `_obey`,
    -- src/BattleSim2/Turn.lua LOAF_LINES / `_obey`), read as one sentence
    -- (`msgsOf`'s `text`: the referee breaks them where the cart does, "<MON>
    -- is" / "loafing around.", K18).  The monster is the player's own, which
    -- the carts print bare (wBattleMonNick through `text_ram`, no prefixing
    -- macro), so a line with "Enemy " in front is never ours.  Gold's asleep
    -- line is the cart's one "…" tile (IgnoredSleepingText); the three-dot
    -- spelling is kept beside it for the flattened screen lines (`flat12`).
    local OBEY_TAILS = {
      { key = "loafing", tail = " is loafing around." },
      { key = "wont", tail = " won't obey!" },
      { key = "turned", tail = " turned away!" },
      { key = "ignored", tail = " ignored orders!" },
      { key = "nap", tail = " began to nap!" },
      { key = "asleep", tail = " ignored orders\226\128\166sleeping!" },
      { key = "asleep", tail = " ignored orders...sleeping!" },
    }
    -- "<MON> used instead, <MOVE>!" (pokered _UsedInsteadText, pokecrystal
    -- UsedInsteadText, the move name and the cart's "!")
    local INSTEAD = " used instead, "
    -- HandleSelfConfusionDamage's line, both carts: "It hurt itself in its
    -- confusion!" (pokered _HurtItselfText, pokecrystal HurtItselfText).
    local SELF_HIT = "It hurt itself in its confusion!"
    local LOAF = { loafing = true, wont = true, turned = true, ignored = true }

    -- Every disobedience line of the fight, keyed ("selfhit" is "won't obey!"
    -- with the self-hit line right behind it), and any line that reads like
    -- one but does not name the player's monster (a foe disobeying, a name
    -- spelled otherwise) as strays.
    local function obeyLines(rec)
      local species = rec.facts and rec.facts.species or "?"
      local found, strays = {}, {}
      local msgs = msgsOf(rec)
      for k, m in ipairs(msgs) do
        local text, key = m.text, nil
        if type(text) == "string" then
          for _, row in ipairs(OBEY_TAILS) do
            if text == species .. row.tail then key = row.key end
          end
          if not key and text:sub(1, #species + #INSTEAD) == species .. INSTEAD then key = "instead" end
          if key == "wont" and msgs[k + 1] and msgs[k + 1].text == SELF_HIT then
            key = "selfhit"
          end
          if key then
            found[#found + 1] = { key = key, text = text, raw = m.raw, i = m.i, turn = m.turn,
                                  pStatus = m.pStatus }
          else
            for _, row in ipairs(OBEY_TAILS) do
              if text:sub(-#row.tail) == row.tail then strays[#strays + 1] = text end
            end
            if text:find(INSTEAD, 1, true) then strays[#strays + 1] = text end
          end
        end
      end
      return found, strays
    end
    -- A page on screen (`flat12`) showing a disobedience line.  A page is two
    -- rows, and "<MON>" / "used instead," / "<MOVE>!" is three (K18's
    -- scroll), so the "used instead," row is looked for on its own.
    local function anyObeyLine(line)
      for _, row in ipairs(OBEY_TAILS) do
        if line:find(row.tail:lower(), 1, true) then return true end
      end
      return line:find("used instead,", 1, true) ~= nil
    end

    local OBEY_MOVES = { "SCRATCH", "GROWL" }
    local CAP_BADGE = GOLD and "RISING" or "EARTHBADGE"
    local disobeyedSeed = nil

    if wants("obey-traded") then
      local seen, fights, lines = {}, 0, 0
      local strays, unsaid, unwon, badNap, badInstead = {}, {}, {}, 0, 0
      local first, photographed
      for i = 1, 12 do
        local seedValue = 300 + i * 41
        local rec = rulesFight({
          label = ("obey traded (seed %d)"):format(seedValue), seed = seedValue,
          lead = { traded = true, moves = OBEY_MOVES, maxHp = 400, speed = 200 },
          foe = { moves = { "SPLASH" }, speed = 10 },
          badges = {},
          shotWhen = (not photographed) and anyObeyLine or nil, shotName = "solo-rules-obey-traded",
        })
        if not rec then break end
        fights = fights + 1
        first = first or rec
        if rec.shot then photographed = rec.shownLine end
        local found, stray = obeyLines(rec)
        for _, s in ipairs(stray) do strays[#strays + 1] = s end
        if #found > 0 and not disobeyedSeed then disobeyedSeed = seedValue end
        for _, ob in ipairs(found) do
          lines = lines + 1
          seen[ob.key] = (seen[ob.key] or 0) + 1
          -- Word for word, breaks and all: the screen was handed the
          -- referee's line with nothing in front of the player's own monster.
          if not screenSaidExact(rec, ob.raw) then unsaid[#unsaid + 1] = ob.text end
          if ob.key == "nap" then
            -- `.monNaps` / `.Nap`: the line is the status event's own text --
            -- in its words (a `status` carries Red's line plain, Gold's as said).
            if not eventAfter(rec, ob.i - 1, function(e)
                  return e.t == "status" and e.side == "a" and plain12(e.text) == plain12(ob.raw) end) then
              badNap = badNap + 1
            end
          elseif ob.key == "instead" then
            -- the called move is the lead's other one, named as the referee names it
            local labels = rec.facts.moveLabels or {}
            if ob.text ~= rec.facts.species .. INSTEAD .. tostring(labels[2]) .. "!" then
              badInstead = badInstead + 1
              log("obey traded: unexpected \"used instead,\" line: " .. tostring(ob.text))
            end
          end
        end
        if rec.result ~= "win" then unwon[#unwon + 1] = tostring(rec.seed) .. "=" .. tostring(rec.result) end
        local loafed = seen.loafing or seen.wont or seen.turned or seen.ignored
        if seen.nap and seen.selfhit and seen.instead and loafed then break end
      end
      local L = "obey traded"
      local f = first and first.facts
      check(f ~= nil and f.level == 50 and f.traded == true,
            L .. ": the referee's lead is the L50 monster, marked traded (its OT id is not the player's)",
            f and ("L%s traded=%s"):format(tostring(f.level), tostring(f.traded)))
      check(f ~= nil and f.rules and next(f.badges or {}) == nil,
            L .. ": with the badge rules on and no badge held", f and tostring(f.mode))
      check(f ~= nil and f.foeTraded == nil, L .. ": the wild foe is not marked traded")
      local parts = {}
      for _, k in ipairs({ "loafing", "wont", "turned", "ignored", "nap", "selfhit", "instead" }) do
        parts[#parts + 1] = k .. "=" .. tostring(seen[k] or 0)
      end
      log("obey traded:", lines, "line(s) in", fights, "fight(s):", table.concat(parts, " "))
      check(lines > 0, L .. ": the traded lead disobeyed, in the cart's lines", table.concat(parts, " "))
      check(seen.loafing or seen.wont or seen.turned or seen.ignored,
            L .. ": a loafing line (\"is loafing around.\" / \"won't obey!\" / \"turned away!\" / \"ignored orders!\") was said")
      check(seen.nap ~= nil, L .. ": \"began to nap!\" was said")
      check(seen.selfhit ~= nil, L .. ": \"won't obey!\" with the self-hit was said")
      check(seen.instead ~= nil, L .. ": \"used instead, <move>\" was said")
      check(badNap == 0, L .. ": every nap's line is its sleep status event's own", tostring(badNap))
      check(badInstead == 0, L .. ": every \"used instead,\" names the lead's other move", tostring(badInstead))
      check(#strays == 0, L .. ": no disobedience line names anybody but the player's monster", strays[1])
      check(#unsaid == 0, L .. ": the screen said every one of the referee's lines, word for word", unsaid[1])
      check(#unwon == 0, L .. ": every fight still ends in a win", table.concat(unwon, ","))
      check(photographed ~= nil, L .. ": a disobedience line was on the screen and photographed",
            photographed)
    end

    if wants("obey-capless") then
      local seeds = { disobeyedSeed or 341, 382, 423 }
      local L = "obey capless (" .. CAP_BADGE .. ")"
      for n, seedValue in ipairs(seeds) do
        local rec = rulesFight({
          label = ("%s (seed %d)"):format(L, seedValue), seed = seedValue,
          lead = { traded = true, moves = OBEY_MOVES, maxHp = 400, speed = 200 },
          foe = { moves = { "SPLASH" }, speed = 10 },
          badges = { CAP_BADGE },
          shotWhen = n == 1 and function(line) return line:find("used scratch", 1, true) ~= nil end or nil,
          shotName = "solo-rules-obey-capless",
        })
        if not rec then break end
        local f = rec.facts or {}
        local found, stray = obeyLines(rec)
        check(f.traded == true and f.level == 50,
              rec.label .. ": the lead is still the traded L50 monster", tostring(f.traded))
        check(type(f.badges) == "table" and f.badges[CAP_BADGE] ~= nil and f.rules,
              rec.label .. ": and the referee's seat holds " .. CAP_BADGE)
        check(#found == 0 and #stray == 0,
              rec.label .. ": no level cap, so not one disobedience line",
              found[1] and found[1].text or stray[1])
        local side, move = firstMove(rec, { "SCRATCH", "GROWL", "SPLASH" })
        check(side == "a" and move == "SCRATCH",
              rec.label .. ": its SCRATCH is the turn's first move", tostring(side) .. " " .. tostring(move))
        check(rec.result == "win", rec.label .. ": a win", tostring(rec.result))
        if n == 1 and disobeyedSeed then
          log(L .. ": seed " .. disobeyedSeed .. " disobeyed without the badge and obeyed with it")
        end
      end
    end

    if wants("obey-asleep") then
      if not GOLD then
        skip("obey-asleep", "Red has no SNORE or SLEEP TALK -- the asleep case is Gold's (and Gen 3's)")
      elseif not (haveMove("SNORE") and haveMove("SPORE")) then
        skip("obey-asleep", "this cart's move table has no SNORE / SPORE")
      else
        local L = "obey asleep"
        local hit, fights, awake, unsaid = nil, 0, 0, {}
        for i = 1, 10 do
          local seedValue = 500 + i * 29
          -- SPORE from a far faster foe puts the lead to sleep before it moves;
          -- told SNORE, it passes the sleep gate (CheckTurn's Snore / Sleep Talk
          -- exception) and meets IgnoreSleepOnly.  The foe on 1 HP: the first
          -- move that lands (a SNORE that obeys, a SCRATCH used instead) ends it.
          local rec = rulesFight({
            label = ("%s (seed %d)"):format(L, seedValue), seed = seedValue,
            lead = { traded = true, moves = { "SNORE", "SCRATCH" }, maxHp = 400, speed = 20 },
            foe = { moves = { "SPORE" }, speed = 300, hp = 1 },
            badges = {},
            shotWhen = function(line) return line:find("ignored orders...sleeping", 1, true) ~= nil end,
            shotName = "solo-rules-obey-asleep",
          })
          if not rec then break end
          fights = fights + 1
          local found = obeyLines(rec)
          for _, ob in ipairs(found) do
            if ob.key == "asleep" then
              hit = hit or rec
              if ob.pStatus ~= "sleep" then awake = awake + 1 end
              if not screenSaidExact(rec, ob.raw) then unsaid[#unsaid + 1] = ob.text end
            end
          end
          if rec.result ~= "win" then unsaid[#unsaid + 1] = "result " .. tostring(rec.result) end
          if hit then break end
        end
        log(L .. ": reached in", fights, "fight(s)")
        check(hit ~= nil, L .. ": \"" .. "<lead> ignored orders...sleeping!\" was said by the referee",
              hit and hit.label or "not in " .. fights .. " fight(s)")
        check(hit ~= nil and hit.facts.traded == true, L .. ": by the traded lead")
        check(awake == 0, L .. ": only ever while the referee holds the lead asleep", tostring(awake))
        check(#unsaid == 0, L .. ": the screen said it word for word, and the fight was won", unsaid[1])
        check(hit ~= nil and hit.shot == true, L .. ": the line was on the screen and photographed",
              hit and hit.shownLine)
      end
    end

    -- ------- move priority

    if wants("priority-quick") then
      if not (haveMove("QUICK_ATTACK") and haveMove("SCRATCH") and haveMove("TACKLE")) then
        skip("priority-quick", "this cart's move table has no QUICK ATTACK / SCRATCH / TACKLE")
      else
        local function prioFight(label, move, shotName)
          return rulesFight({
            label = label, seed = 777,
            lead = { moves = { move }, speed = 20 },
            foe = { moves = { "TACKLE" }, speed = 300 },
            badges = {},
            shotWhen = shotName and function(line) return line:find("used quick attack", 1, true) ~= nil end or nil,
            shotName = shotName,
          })
        end
        local plain = prioFight("priority control (SCRATCH)", "SCRATCH")
        local quick = prioFight("priority QUICK ATTACK", "QUICK_ATTACK", "solo-rules-priority-quick")
        for _, rec in ipairs({ plain, quick }) do
          local f = rec and rec.facts or {}
          check(f.speedP ~= nil and f.speedF ~= nil and f.speedF > f.speedP,
                (rec and rec.label or "priority") .. ": the referee rates the foe the faster",
                ("%s v %s"):format(tostring(f.speedP), tostring(f.speedF)))
          check(rec ~= nil and rec.result == "win", (rec and rec.label or "priority") .. ": a win",
                tostring(rec and rec.result))
        end
        local ps, pm = firstMove(plain or { events = {} }, { "SCRATCH", "TACKLE" })
        local qs, qm = firstMove(quick or { events = {} }, { "QUICK_ATTACK", "TACKLE" })
        check(ps == "b" and pm == "TACKLE",
              "priority: with SCRATCH (bracket 0 each) the faster foe moves first",
              tostring(ps) .. " " .. tostring(pm))
        check(qs == "a" and qm == "QUICK_ATTACK",
              "priority: QUICK ATTACK's bracket moves the slower lead first, same seed and Speeds",
              tostring(qs) .. " " .. tostring(qm))
        check(quick ~= nil and quick.shot == true, "priority: the QUICK ATTACK line was photographed")
      end
    end

    -- The lead's held-item facts on the referee's sheet are the player's own
    -- item row's (contract K2: MediatedBattle.heldFields2).
    local function itemFacts(L, rec, id)
      local row = itemRow(id) or {}
      local f = rec and rec.facts or {}
      check(f.heldItem == id and f.holdEffect == row.heldEffect and f.itemName == row.name,
            L .. ": the referee's lead holds " .. id .. ", with its item row's hold effect and name",
            ("%s %s %s"):format(tostring(f.heldItem), tostring(f.holdEffect), tostring(f.itemName)))
    end
    -- the `held` event for side `side` holding (amount 1) or losing (0) `id`
    local function heldEvent(rec, side, id, amount)
      for i, e in ipairs(rec.events) do
        if e.t == "held" and e.side == side and e.text == id and e.amount == amount then return e, i end
      end
      return nil
    end
    local function nextMsg(rec, i)
      return eventAfter(rec, i, function(e) return e.t == "msg" end)
    end
    local function prevOf(rec, i, pred)
      for j = i - 1, 1, -1 do
        if pred(rec.events[j]) then return rec.events[j] end
      end
      return nil
    end

    -- ------- the referee gaps (docs/plans/gen12-referee-gaps-fix.md TT-E)

    -- The referee's `msg`s that say `text` (a literal or a referee line), as
    -- the player reads both (`read12`): "Coins scattered everywhere!" is sent
    -- as the cart's two rows (K18).
    local function countMsgs(rec, text)
      local n, want = 0, read12(text)
      for _, e in ipairs(rec.events) do
        if e.t == "msg" and read12(e.text) == want then n = n + 1 end
      end
      return n
    end
    local function saidCount(rec, needle)
      local n, last = 0, nil
      for _, line in ipairs(rec.said) do
        if flat12(line):find(needle, 1, true) then n, last = n + 1, line end
      end
      return n, last
    end
    -- The side-`side` anim of `moveId` at or after event `from` -- the move's
    -- own clip, not a `quiet` beat (K22) -- and the first `pred` event after
    -- it before the next anim of anybody's.
    local function afterAnim(rec, from, side, moveId, pred)
      for i = from or 1, #rec.events do
        local e = rec.events[i]
        if e.t == "anim" and e.side == side and e.text == moveId and not e.quiet then
          for j = i + 1, #rec.events do
            local x = rec.events[j]
            if x.t == "anim" then return e, i, nil, j end
            if pred(x) then return e, i, x, j end
          end
          return e, i, nil, #rec.events
        end
      end
      return nil
    end
    local function sameTable(a, b)
      if type(a) ~= "table" or type(b) ~= "table" then return false end
      for k, v in pairs(a) do if b[k] ~= v then return false end end
      for k, v in pairs(b) do if a[k] ~= v then return false end end
      return true
    end
    local function fmtTable(t)
      if type(t) ~= "table" then return tostring(t) end
      local keys, parts = {}, {}
      for k in pairs(t) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(t[k]) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    -- A save monster's stats in the referee sheet's own dialect
    -- (MediatedBattle statsOf: Red atk/def/spd/spc, Gold atk/def/spe/spa/spd).
    local function sheetStats(mon)
      local s = type(mon) == "table" and mon.stats or nil
      if type(s) ~= "table" then return nil end
      if GOLD then
        return { atk = s.attack, def = s.defense, spe = s.speed,
                 spa = s.specialAttack or s.spa or s.special,
                 spd = s.specialDefense or s.spd or s.special }
      end
      return { atk = s.attack, def = s.defense, spd = s.speed, spc = s.special }
    end
    -- Every key of `want` holds the same number in `got`.
    local function statsMatch(want, got)
      if type(want) ~= "table" or type(got) ~= "table" then return false end
      local any = false
      for k, v in pairs(want) do
        any = true
        if tonumber(got[k]) ~= tonumber(v) then return false end
      end
      return any
    end
    -- A level `from` or above at whose next level the species learns no move,
    -- so a level-up mid-fight asks nothing of the player.
    local function quietLevel(species, from)
      local def = type(data.pokemon) == "table" and data.pokemon[species] or nil
      local rows = def and (def.levelMoves or def.learnset) or {}
      for level = from, from + 10 do
        local learns = false
        for _, e in ipairs(rows) do
          if tonumber(e.level) == level + 1 then learns = true end
        end
        if not learns then return level end
      end
      return from
    end
    local function playerName12()
      local p = game.save and game.save.player
      local name = p and p.name
      return (type(name) == "string" and name ~= "") and name or "YOU"
    end

    -- Gold: the real trainer (a TRAINERTYPE_ITEM row in the player's own
    -- trainer data) whose lead monster holds an item -- the fewest monsters,
    -- then the lowest total level, then the class id and member, so a run
    -- always meets the same one.
    local function goldItemTrainer()
      local classes = data.trainers and data.trainers.classes
      local best = nil
      for classId, class in pairs(type(classes) == "table" and classes or {}) do
        for member, row in ipairs((type(class) == "table" and class.trainers) or {}) do
          local party = (type(row) == "table" and row.party) or {}
          local first = party[1]
          if type(first) == "table" and type(first.item) == "string" and itemRow(first.item) then
            local total = 0
            for _, p in ipairs(party) do total = total + (tonumber(p.level) or 0) end
            local key = { classId = tostring(classId), member = member, n = #party, total = total,
                          item = first.item, species = first.species, level = first.level,
                          name = row.name }
            local better = best == nil or key.n < best.n
              or (key.n == best.n and key.total < best.total)
              or (key.n == best.n and key.total == best.total and key.classId < best.classId)
              or (key.n == best.n and key.total == best.total and key.classId == best.classId
                  and key.member < best.member)
            if better then best = key end
          end
        end
      end
      return best
    end

    -- That trainer on the stack the way H.stageTrainer's Gold arm stages one
    -- (Battle.new over Trainers.party, Gen2BattleState pushed, the Gen 1-shaped
    -- fields stamped), but that exact member, its party unsoftened, and the
    -- lead re-pinned after Battle.new's stat refresh.  `pickT.engineItem` is
    -- what the engine's own party monster held as it was built.
    local function stageGoldTrainer(pickT, onFinish, repin)
      local okB, Battle = pcall(require, "src.battle.gen2.Battle")
      local okT, Trainers = pcall(require, "src.world.gen2.Trainers")
      local okS, Screens = pcall(require, "src.ui.Screens")
      if not (okB and Battle and okT and Trainers and okS and Screens) then
        return nil, "gen2 trainer modules unavailable"
      end
      local classRec = data.trainers.classes[pickT.classId]
      if not classRec then return nil, "no trainer class " .. tostring(pickT.classId) end
      local entry = Trainers.lookup(data.trainers, classRec.index, pickT.member)
      if not entry then return nil, "Trainers.lookup refused " .. pickT.classId end
      local party = Trainers.party(data, entry)
      if not (party and #party > 0) then return nil, "the trainer's party built empty" end
      pickT.engineItem = party[1].item
      local trainer = {
        class = entry.class, classId = entry.classId, memberId = entry.id, name = entry.name,
        className = entry.className, party = party, baseMoney = entry.baseMoney,
        attributes = entry.attributes, items = entry.items,
      }
      local okNew, battle = pcall(Battle.new, {
        data = data, party = (game.save and game.save.party) or {}, trainer = trainer, save = game.save,
      })
      if not (okNew and battle) then return nil, tostring(battle) end
      if repin then repin() end
      local okPush, state = pcall(Screens.push, game, "Gen2BattleState", { battle = battle, save = game.save })
      if not (okPush and type(state) == "table") then
        return nil, "Gen2BattleState never came up: " .. tostring(state)
      end
      state.kind = "trainer"
      state.oppClass = trainer.classId or trainer.class
      state.enemyParty = battle.enemyParty or party
      state.trainer = trainer
      return likeWorldStartBattle(state, onFinish), nil, party[1].species
    end

    if wantsGap("payday") then
      local strong = haveMove("FLAMETHROWER") and "FLAMETHROWER" or "SLASH"
      if not (haveMove("PAY_DAY") and haveMove(strong) and haveMove("SPLASH")) then
        skip("payday", "this cart has no PAY DAY / " .. strong .. " / SPLASH")
      else
        -- The foe takes a PAY DAY (a critical one too) and stays up; the next
        -- turn's move ends it.  `moves`, `pick` and `item` vary per fight.
        local function payFight(label, opts)
          local moneyBefore = moneyOf()
          local rec = rulesFight({
            label = label, seed = opts.seed,
            lead = { moves = opts.moves, item = opts.item, speed = 200, maxHp = 400 },
            foe = { moves = { "SPLASH" }, speed = 10, maxHp = 500 },
            badges = {},
            pick = opts.pick,
            shotWhen = opts.shotName and function(line) return line:find("picked up", 1, true) ~= nil end or nil,
            shotName = opts.shotName,
          })
          if rec then
            rec.moneyBefore, rec.moneyAfter = moneyBefore, moneyOf()
            rec.scattered = countMsgs(rec, "Coins scattered everywhere!")
            local level = tonumber(rec.facts and rec.facts.level) or 50
            -- PayDayEffect_ / BattleCommand_PayDay: the user's level doubled
            -- (an 8-bit `add a`) per PAY DAY that landed.
            rec.pot = rec.scattered * ((2 * level) % 256)
            rec.pickedUp, rec.pickedLine = saidCount(rec, "picked up")
            log(("%s: scattered=%d pot=%d outcome.payDay=%s reason=%s money %d -> %d (+%d) line=[%s]"):format(
              label, rec.scattered, rec.pot, tostring(rec.outcome and rec.outcome.payDay),
              tostring(rec.outcome and rec.outcome.reason), moneyBefore, rec.moneyAfter,
              rec.moneyAfter - moneyBefore, (tostring(rec.pickedLine):gsub("\n", "|"))))
          end
          return rec
        end
        local function paid(rec, label, factor, wantReason)
          if not rec then return end
          local paidOut = rec.pot * factor
          check(rec.scattered >= 1 and screenSaid(rec, "Coins scattered everywhere!"),
                label .. ": the lead's PAY DAY scattered coins (the referee's line, on the screen)",
                tostring(rec.scattered))
          if wantReason then
            check(rec.outcome ~= nil and rec.outcome.reason == wantReason,
                  label .. ": the fight ended by " .. wantReason, tostring(rec.outcome and rec.outcome.reason))
          end
          check(rec.outcome ~= nil and tonumber(rec.outcome.payDay) == rec.pot,
                label .. ": the referee's outcome carries the pot (K11), 2 x the level per PAY DAY",
                ("%s vs %d"):format(tostring(rec.outcome and rec.outcome.payDay), rec.pot))
          check(rec.moneyAfter - rec.moneyBefore == paidOut,
                label .. (factor == 2 and ": the save's money rose by twice the pot (AMULET COIN)"
                  or ": the save's money rose by the pot"),
                ("%d -> %d, want +%d"):format(rec.moneyBefore, rec.moneyAfter, paidOut))
          local want = ("%s picked up\n¥%d!"):format(playerName12(), paidOut)
          check(rec.pickedUp == 1, label .. ": \"picked up\" was said exactly once", tostring(rec.pickedUp))
          check(rec.pickedLine == want, label .. ": in the cart's words, naming what was paid",
                (tostring(rec.pickedLine):gsub("\n", "|")))
        end

        if GOLD then
          local coin = itemRow("AMULET_COIN")
          if not coin then
            skip("payday (AMULET COIN)", "this cart has no AMULET COIN")
          else
            local rec = payFight("payday AMULET COIN", {
              seed = 1011, moves = { "PAY_DAY", strong }, item = "AMULET_COIN",
              pick = function(turn) return { move = (turn == 1) and 1 or 2 } end,
              shotName = "solo-gaps-payday",
            })
            if rec then
              itemFacts("payday AMULET COIN", rec, "AMULET_COIN")
              check(rec.result == "win", "payday AMULET COIN: a win", tostring(rec.result))
              paid(rec, "payday AMULET COIN", 2, "ko")
              check(rec.after ~= nil and rec.after.item == "AMULET_COIN",
                    "payday AMULET COIN: the coin is never used up -- still on the save's lead",
                    tostring(rec.after and rec.after.item))
              check(rec.shot == true, "payday AMULET COIN: the line was photographed")
            end
          end
          local control = payFight("payday (no AMULET COIN)", {
            seed = 1011, moves = { "PAY_DAY", strong },
            pick = function(turn) return { move = (turn == 1) and 1 or 2 } end,
          })
          if control then
            check(control.facts and control.facts.heldItem == nil,
                  "payday (no AMULET COIN): the lead holds nothing", tostring(control.facts and control.facts.heldItem))
            check(control.result == "win", "payday (no AMULET COIN): a win", tostring(control.result))
            paid(control, "payday (no AMULET COIN)", 1, "ko")
          end
        else
          local rec = payFight("payday win", {
            seed = 1011, moves = { "PAY_DAY", strong },
            pick = function(turn) return { move = (turn == 1) and 1 or 2 } end,
            shotName = "solo-gaps-payday",
          })
          if rec then
            check(rec.result == "win", "payday win: a win", tostring(rec.result))
            paid(rec, "payday win", 1, "ko")
            check(rec.shot == true, "payday win: the line was photographed")
          end
          if not haveMove("TELEPORT") then
            skip("payday TELEPORT", "this cart has no TELEPORT")
          else
            -- SwitchAndTeleportEffect leaves wBattleResult 0: EndOfBattle pays.
            local tele = payFight("payday TELEPORT", {
              seed = 1013, moves = { "PAY_DAY", "TELEPORT" },
              pick = function(turn) return { move = (turn == 1) and 1 or 2 } end,
            })
            if tele then
              check(firstMove(tele, { "TELEPORT" }) == "a", "payday TELEPORT: the lead used TELEPORT")
              paid(tele, "payday TELEPORT", 1, "run")
            end
          end
          -- TryRunningFromBattle `.canEscape` writes wBattleResult 2: no pay.
          local ran = payFight("payday RUN", {
            seed = 1017, moves = { "PAY_DAY" },
            pick = function(turn) return (turn == 1) and { move = 1 } or { run = true } end,
          })
          if ran then
            check(ran.scattered >= 1, "payday RUN: the lead's PAY DAY scattered coins first",
                  tostring(ran.scattered))
            check(ran.result == "run" or (ran.outcome and ran.outcome.reason == "run"),
                  "payday RUN: the player ran", tostring(ran.result))
            check(ran.outcome ~= nil and ran.outcome.payDay == nil,
                  "payday RUN: the referee states no pot for the player's own RUN",
                  tostring(ran.outcome and ran.outcome.payDay))
            check(ran.moneyAfter == ran.moneyBefore, "payday RUN: the save's money did not move",
                  ("%d -> %d"):format(ran.moneyBefore, ran.moneyAfter))
            check(ran.pickedUp == 0, "payday RUN: nothing was picked up", (tostring(ran.pickedLine):gsub("\n", "|")))
          end
        end
      end
    end

    if wantsGap("trainer-item") then
      local L = "trainer item"
      local pickT = GOLD and goldItemTrainer() or nil
      if not GOLD then
        skip("trainer-item", "Red's trainers' monsters hold no items -- the item byte is Gold's")
      elseif not (haveMove("THIEF") and haveMove("FLAMETHROWER")) then
        skip("trainer-item", "this cart has no THIEF / FLAMETHROWER")
      elseif not pickT then
        skip("trainer-item", "no trainer in this cart's data has a lead monster holding an item")
      else
        log(("%s: %s #%d %s (%s L%s holding %s)"):format(L, pickT.classId, pickT.member,
          tostring(pickT.name), tostring(pickT.species), tostring(pickT.level), pickT.item))
        local row = itemRow(pickT.item) or {}
        local rec = rulesFight({
          label = L, seed = 1021,
          lead = { moves = { "THIEF", "FLAMETHROWER" }, maxHp = 400 },
          stage = function(onFinish, repin) return stageGoldTrainer(pickT, onFinish, repin) end,
          badges = {},
          pick = function(turn) return { move = (turn == 1) and 1 or 2 } end,
          shotWhen = function(line) return line:find(" stole ", 1, true) ~= nil end,
          shotName = "solo-gaps-trainer-item",
        })
        if rec then
          local f = rec.facts or {}
          check(pickT.engineItem == pickT.item,
                L .. ": the engine built the trainer's monster holding its party row's item",
                tostring(pickT.engineItem))
          check(rec.med and rec.med.mode == "coop_npc", L .. ": seated as a trainer fight (coop_npc)",
                tostring(rec.med and rec.med.mode))
          check(f.foeHeld == pickT.item,
                L .. ": the foe's sheet on the referee's field carries the item",
                tostring(f.foeHeld))
          check(f.heldItem == nil, L .. ": the lead walks in empty-handed (THIEF needs that)",
                tostring(f.heldItem))
          local lost = heldEvent(rec, "b", pickT.item, 0)
          local took, i = heldEvent(rec, "a", pickT.item, 1)
          check(lost ~= nil and took ~= nil,
                L .. ": the referee's `held` pair: the foe's item gone, the lead holding it",
                ("%s / %s"):format(tostring(lost ~= nil), tostring(took ~= nil)))
          -- The referee's THIEF line (pokecrystal BattleCommand_Thief's
          -- StoleText, "<USER>" / "stole <ITEM>" / "from its foe!"), read
          -- as one sentence: the thief is the player's lead, side a's mark,
          -- which its own screen says bare (K17).
          local stoleLine = nil
          for _, e in ipairs(rec.events) do
            if e.t == "msg" and type(e.text) == "string" and plain12(e.text):find(" stole ", 1, true) then
              stoleLine = e.text
              break
            end
          end
          local want = tostring(f.species) .. " stole " .. tostring(row.name) .. " from its foe!"
          check(stoleLine ~= nil and plain12(stoleLine) == want, L .. ": the cart's line",
                tostring(stoleLine and plain12(stoleLine)))
          check(markOf(stoleLine) == "a", L .. ": naming the lead by side a's mark", tostring(stoleLine))
          check(stoleLine ~= nil and screenSaidExact(rec, stoleLine) and screenSaid(rec, want),
                L .. ": and the screen said it -- the lead's name bare, nothing in front of it")
          check(rec.result == "win", L .. ": a win", tostring(rec.result))
          check(rec.after ~= nil and rec.after.item == pickT.item,
                L .. ": the save's lead holds the stolen " .. pickT.item .. " after the fight",
                tostring(rec.after and rec.after.item))
          check(rec.shot == true, L .. ": the theft was photographed")
        end
      end
    end

    if wantsGap("sleep-talk") then
      local L = "sleep talk"
      if not GOLD then
        skip("sleep-talk", "Red has no SLEEP TALK")
      elseif not (haveMove("SLEEP_TALK") and haveMove("SPORE") and haveMove("SCRATCH")) then
        skip("sleep-talk", "this cart has no SLEEP TALK / SPORE / SCRATCH")
      else
        -- The faster lead's SLEEP TALK opens awake; the foe's SPORE puts it to
        -- sleep; asleep, SLEEP TALK calls SCRATCH, the only other move, onto a
        -- foe on 1 HP -- the fight ends on the first call.
        local rec = rulesFight({
          label = L, seed = 1031,
          lead = { moves = { "SLEEP_TALK", "SCRATCH" }, maxHp = 400, speed = 200 },
          foe = { moves = { "SPORE" }, speed = 10, hp = 1 },
          badges = {},
          pick = function() return { move = 1 } end,
          shotWhen = function(line) return line:find("used scratch", 1, true) ~= nil end,
          shotName = "solo-gaps-sleep-talk",
          seconds = 420,
        })
        if rec then
          local species = rec.facts and rec.facts.species or "?"
          -- Each SLEEP TALK the lead used, found by its "used" line rather
          -- than its clip: told while awake, the cart's BattleCommand_SleepTalk
          -- fails through AnimateFailedMove, which plays no clip (K22), and
          -- its "used" line is still printed.  Awake, the next line is the
          -- failure; asleep, the next "used" line of the lead's in that turn
          -- is the move it called (ResetTurn re-enters the move script, so
          -- the called move prints its own).
          local leadMoves = (rec.facts and rec.facts.moves) or { "SLEEP_TALK", "SCRATCH" }
          local awake, asleep, calledLine = nil, nil, nil
          for k, e in ipairs(rec.events) do
            if e.t == "msg" and usedLineOf(e.text, { "SLEEP_TALK" }) == "a" then
              if e.pStatus ~= "sleep" and not awake then
                local failed = eventAfter(rec, k, function(x) return x.t == "msg" end)
                awake = { line = failed and read12(failed.text), turn = e.turn }
              elseif e.pStatus == "sleep" and not asleep then
                asleep = { turn = e.turn }
                for j = k + 1, #rec.events do
                  local x = rec.events[j]
                  if x.turn ~= e.turn then break end
                  local side, id = nil, nil
                  if x.t == "msg" then side, id = usedLineOf(x.text, leadMoves) end
                  if side == "a" then
                    asleep.called, calledLine = id, x.text
                    break
                  end
                end
              end
            end
          end
          log(("%s: awake=%s asleep=%s line=[%s] turns=%d"):format(L,
            awake and tostring(awake.line) or "-", asleep and tostring(asleep.called) or "-",
            tostring(calledLine and plain12(calledLine)), rec.turns or 0))
          check(awake ~= nil and awake.line == "But it failed!",
                L .. ": told while awake, SLEEP TALK fails -- \"But it failed!\"", awake and awake.line)
          check(screenSaid(rec, "But it failed!"), L .. ": and the screen said it")
          check(asleep ~= nil and asleep.called == "SCRATCH",
                L .. ": asleep, it calls the lead's other move (SCRATCH)", asleep and asleep.called)
          local want = species .. " used " .. tostring(rec.facts and rec.facts.moveLabels
            and rec.facts.moveLabels[2]) .. "!"
          check(calledLine ~= nil and read12(calledLine) == want, L .. ": in the referee's own line",
                tostring(calledLine and read12(calledLine)))
          check(calledLine ~= nil and screenSaidExact(rec, calledLine), L .. ": and the screen said it")
          check(rec.result == "win", L .. ": the called SCRATCH won the fight", tostring(rec.result))
          local after = rec.after and rec.after.moves or {}
          local scratchRow = data.moves and data.moves.SCRATCH
          local talkRow = data.moves and data.moves.SLEEP_TALK
          check(after[2] ~= nil and tonumber(after[2].pp) == tonumber(scratchRow and scratchRow.pp),
                L .. ": the called SCRATCH spent no PP of its own (the save's PP is full)",
                after[2] and tostring(after[2].pp))
          check(after[1] ~= nil and tonumber(after[1].pp) < tonumber(talkRow and talkRow.pp or 0),
                L .. ": SLEEP TALK's own PP was spent", after[1] and tostring(after[1].pp))
          check(rec.shot == true, L .. ": the called move's line was photographed")
        end
      end
    end

    if wantsGap("level-up") then
      local L = "level-up"
      local class = H.coopTrainer(data)
      local species = GOLD and "TYPHLOSION" or "CHARIZARD"
      if not (type(data.pokemon) == "table" and data.pokemon[species]) then species = partySpecies() end
      local move = haveMove("FLAMETHROWER") and "FLAMETHROWER" or nil
      if not class then
        skip("level-up", "this cart's data has no trainer with two monsters")
      elseif not move then
        skip("level-up", "this cart has no FLAMETHROWER")
      else
        local level = quietLevel(species, 50)
        local rec = rulesFight({
          label = L, seed = 1041,
          lead = { species = species, level = level, moves = { move }, toNextLevel = true },
          stage = function(onFinish)
            local st = H.stageTrainer(game, class, onFinish)
            if not st then return nil, "stageTrainer refused " .. tostring(class) end
            return likeWorldStartBattle(st, onFinish), nil, tostring(class)
          end,
          badges = {},
          shotWhen = function(line) return line:find("grew to level", 1, true) ~= nil end,
          shotName = "solo-gaps-level-up",
          seconds = 360,
        })
        if rec then
          local ups = rec.levelUps or {}
          local up = ups[1]
          log(("%s: %s L%d vs %s; %d level-up(s) handed to the referee; first: ok=%s L%s stats=%s maxHp=%s; "
            .. "before L%s %s maxHp=%s; after L%s %s maxHp=%s"):format(L, species, level, tostring(class), #ups,
            tostring(up and up.ok), tostring(up and up.level), fmtTable(up and up.stats), tostring(up and up.maxHp),
            tostring(up and up.before and up.before.level), fmtTable(up and up.before and up.before.stats),
            tostring(up and up.before and up.before.maxHp),
            tostring(up and up.after and up.after.level), fmtTable(up and up.after and up.after.stats),
            tostring(up and up.after and up.after.maxHp)))
          check(rec.med and rec.med.mode == "coop_npc", L .. ": against a trainer (coop_npc)",
                tostring(rec.med and rec.med.mode))
          check(up ~= nil and up.index == 1 and up.result == false,
                L .. ": the client handed the referee a level-up for the lead mid-fight (K9)",
                up and ("mon %s, over=%s"):format(tostring(up.index), tostring(up.result)) or "none")
          check(up ~= nil and up.ok == true, L .. ": and the referee took it", tostring(up and up.ok))
          check(up ~= nil and tonumber(up.level) == level + 1,
                L .. ": to the next level", tostring(up and up.level))
          local b, a = up and up.before or {}, up and up.after or {}
          check(tonumber(a.level) == tonumber(up and up.level),
                L .. ": the referee's monster is at that level now", tostring(a.level))
          check(statsMatch(up and up.stats, a.stats),
                L .. ": its stats are the K9 stats", fmtTable(a.stats))
          local rose, fell = false, false
          for k, v in pairs((up and up.stats) or {}) do
            local was = tonumber(b.stats and b.stats[k])
            if was and tonumber(v) > was then rose = true end
            if was and tonumber(v) < was then fell = true end
          end
          check(rose and not fell, L .. ": which rose from what it walked in with",
                fmtTable(b.stats) .. " -> " .. fmtTable(a.stats))
          check(tonumber(a.maxHp) == tonumber(up and up.maxHp) and tonumber(a.maxHp) > (tonumber(b.maxHp) or 0),
                L .. ": its maximum HP rose to the K9 maximum",
                ("%s -> %s (K9 %s)"):format(tostring(b.maxHp), tostring(a.maxHp), tostring(up and up.maxHp)))
          -- A use of the lead's after the level-up: its move's clip (not a
          -- `quiet` beat or a cart `_ANIM` -- K20 / K22 put those on a seat
          -- nobody chose for) or its "used" line, which a miss still prints.
          local fought = false
          for j = (up and up.at or #rec.events) + 1, #rec.events do
            local e = rec.events[j]
            if e.t == "anim" and e.side == "a" and not e.quiet
                and not tostring(e.text):find("_ANIM$") then
              fought = true break
            end
            if e.t == "msg" and usedLineOf(e.text, { move }) == "a" then fought = true break end
          end
          check(fought, L .. ": and it fought on after the level-up (the trainer's next monster)")
          check(screenSaidLike(rec, "grew to level " .. tostring(level + 1) .. "!"),
                L .. ": the screen said \"grew to level " .. (level + 1) .. "!\"")
          check(rec.result == "win", L .. ": a win", tostring(rec.result))
          local saved = rec.after
          check(saved ~= nil and tonumber(saved.level) == tonumber(up and up.level),
                L .. ": the save's lead is at the referee's level after the fight",
                tostring(saved and saved.level))
          check(statsMatch(up and up.stats, sheetStats(saved)),
                L .. ": with the stats the referee was told", fmtTable(sheetStats(saved)))
          check(saved ~= nil and saved.stats and tonumber(saved.stats.hp) == tonumber(up and up.maxHp),
                L .. ": and that maximum HP", tostring(saved and saved.stats and saved.stats.hp))
          check(rec.shot == true, L .. ": the level-up line was photographed")
        end
      end
    end

    if wantsGap("weather") then
      local L = "weather"
      if not GOLD then
        skip("weather", "Red has no weather")
      elseif not (haveMove("RAIN_DANCE") and haveMove("WATER_GUN") and haveMove("SPLASH")) then
        skip("weather", "this cart has no RAIN DANCE / WATER GUN / SPLASH")
      else
        -- One move list for both fights, fixed DVs on both monsters, one seed:
        -- turn 1 is RAIN DANCE or SPLASH (neither script draws a number:
        -- pokecrystal RainDance is checkobedience / usedmovetext / doturn /
        -- startrain, Splash the same with `splash`), every later turn WATER
        -- GUN, into a foe that outlasts the whole rain.
        local DVS = { attack = 8, defense = 8, speed = 8, special = 8 }
        local function rainFight(label, first, shotName)
          return rulesFight({
            label = label, seed = 1051,
            lead = { moves = { "RAIN_DANCE", "WATER_GUN", "SPLASH" }, maxHp = 400, speed = 200, dvs = DVS },
            foe = { moves = { "SPLASH" }, speed = 10, maxHp = 999, level = 8, dvs = DVS },
            badges = {},
            pick = function(turn) return { move = (turn == 1) and first or 2 } end,
            shotWhen = shotName and function(line) return line:find("downpour", 1, true) ~= nil end or nil,
            shotName = shotName,
            seconds = 420,
          })
        end
        local wet = rainFight("weather RAIN DANCE", 1, "solo-gaps-weather")
        local dry = rainFight("weather control (SPLASH)", 3)
        local function firstGun(rec)
          if not rec then return nil end
          local _, _, hit = afterAnim(rec, 1, "a", "WATER_GUN",
            function(x) return x.t == "damage" and x.side == "b" end)
          return hit and tonumber(hit.amount) or nil
        end
        local wetHit, dryHit = firstGun(wet), firstGun(dry)
        log(("%s: first WATER GUN %s in the rain, %s without"):format(L, tostring(wetHit), tostring(dryHit)))
        if wet then
          local start, stop, continues, startAt, stopAt = 0, 0, 0, nil, nil
          -- The weather lines as the player reads them (pokecrystal
          -- DownpourText "A downpour" / line "started!",
          -- BattleText_RainContinuesToFall "Rain continues to" / line "fall.",
          -- BattleText_TheRainStopped: the referee keeps the rows, K18).
          for i, e in ipairs(wet.events) do
            if e.t == "msg" then
              local line = read12(e.text)
              if line == "A downpour started!" then start = start + 1; startAt = startAt or i end
              if line == "The rain stopped." then stop = stop + 1; stopAt = stopAt or i end
              if line == "Rain continues to fall." and startAt and not stopAt then continues = continues + 1 end
            end
          end
          log(("%s: start=%d continues=%d stop=%d turns=%d"):format(L, start, continues, stop, wet.turns or 0))
          check(start == 1 and screenSaid(wet, "A downpour started!"),
                L .. ": RAIN DANCE: \"A downpour started!\", on the screen", tostring(start))
          check(continues == 4 and screenSaid(wet, "Rain continues to fall."),
                L .. ": \"Rain continues to fall.\" at the end of each of the next four turns", tostring(continues))
          check(stop == 1 and stopAt ~= nil and screenSaid(wet, "The rain stopped."),
                L .. ": and \"The rain stopped.\" at the end of the fifth", tostring(stop))
          check(wet.result == "win", L .. ": a win", tostring(wet.result))
          check(wet.shot == true, L .. ": the downpour was photographed")
        end
        if dry then
          check(countMsgs(dry, "A downpour started!") == 0, L .. " control: no rain in the control fight")
        end
        check(wetHit ~= nil and dryHit ~= nil and wetHit > dryHit,
              L .. ": the same seed's first WATER GUN hits harder in the rain",
              ("%s vs %s"):format(tostring(wetHit), tostring(dryHit)))
        check(wetHit ~= nil and dryHit ~= nil and wetHit * 10 >= dryHit * 14 and wetHit * 10 <= dryHit * 16 + 10,
              L .. ": by the rain's x1.5 (within the damage roll's rounding)",
              ("%s / %s"):format(tostring(wetHit), tostring(dryHit)))
      end
    end

    if wantsGap("baton-pass") then
      local L = "baton pass"
      if not GOLD then
        skip("baton-pass", "Red has no BATON PASS")
      elseif not (haveMove("BATON_PASS") and haveMove("SWORDS_DANCE") and haveMove("TACKLE")
                  and haveMove("SCRATCH") and haveMove("SPLASH")) then
        skip("baton-pass", "this cart has no BATON PASS / SWORDS DANCE / TACKLE / SCRATCH / SPLASH")
      else
        -- Three of the player's own: the lead, a second the referee's default
        -- (the first living one; neither bench monster has a super-effective
        -- move on a NORMAL foe) would send, and the third, which the picker names.
        local SECOND, THIRD = "TOTODILE", "CHIKORITA"
        if not (data.pokemon and data.pokemon[SECOND] and data.pokemon[THIRD]) then
          SECOND, THIRD = "RATTATA", "PIDGEY"
        end
        local rec = rulesFight({
          label = L, seed = 1061,
          lead = { moves = { "SWORDS_DANCE", "BATON_PASS" }, maxHp = 400, speed = 200,
                   bench = { { species = SECOND, moves = { "SCRATCH" } },
                             { species = THIRD, moves = { "TACKLE" } } } },
          foe = { moves = { "SPLASH" }, speed = 10 },
          badges = {},
          pick = function(turn)
            if turn == 1 then return { move = 1 } end
            if turn == 2 then return { move = 2, passTo = 3 } end
            return { move = 1 }
          end,
          shotWhen = function(line) return line:find(THIRD:lower(), 1, true) ~= nil end,
          shotName = "solo-gaps-baton-pass",
        })
        if rec then
          local sd, sdAt = nil, nil
          for i, e in ipairs(rec.events) do
            if e.t == "stat" and e.side == "a" and not sd then sd, sdAt = e, i end
          end
          local sdAnim = nil
          for _, e in ipairs(rec.events) do
            if e.t == "anim" and e.side == "a" and e.text == "SWORDS_DANCE" then sdAnim = e break end
          end
          check(sd ~= nil and tonumber(sd.stage) == 2,
                L .. ": SWORDS DANCE's `stat` event carries the signed stage +2 (K10)",
                sd and tostring(sd.stage))
          check(sd ~= nil and sdAnim ~= nil and not sameTable(sd.pStages, sdAnim.pStages),
                L .. ": the referee's lead holds a raised stage",
                fmtTable(sdAnim and sdAnim.pStages) .. " -> " .. fmtTable(sd and sd.pStages))
          local passChoice = nil
          for _, c in ipairs(rec.choices) do
            if c.seat == "solo_player" and c.action == "fight" and c.pass ~= nil then passChoice = c end
          end
          check((rec.picker or 0) >= 1, L .. ": choosing BATON PASS opened the client's party picker",
                tostring(rec.picker or rec["picker-missing"]))
          check(passChoice ~= nil and tonumber(passChoice.pass) == 2,
                L .. ": the FIGHT choice filed the picked successor (`pass` = the third, slot 2)",
                passChoice and tostring(passChoice.pass))
          local sent = nil
          for i = (sdAt or 1), #rec.events do
            local e = rec.events[i]
            if e.t == "send" and e.side == "a" then sent = e break end
          end
          check(sent ~= nil and sent.text == THIRD and tonumber(sent.mon) == 2 and sent.pActive == 3,
                L .. ": " .. THIRD .. " -- the picked one, not the default " .. SECOND .. " -- came in",
                sent and ("%s mon=%s active=%s"):format(tostring(sent.text), tostring(sent.mon),
                  tostring(sent.pActive)))
          check(sent ~= nil and sd ~= nil and sameTable(sent.pStages, sd.pStages),
                L .. ": and keeps the stage the lead passed", fmtTable(sent and sent.pStages))
          check(rec.result == "win", L .. ": a win", tostring(rec.result))
          check(rec.shot == true, L .. ": the successor's entrance was photographed")
        end
      end
    end

    -- ------- Gold's held items

    local heldLegs = { "held-leftovers", "held-berry", "held-quickclaw", "held-thief", "held-smokeball" }
    if not GOLD then
      for _, name in ipairs(heldLegs) do
        if wants(name) then skip(name, "held items are Gold's; Red's monsters hold none") end
      end
      return
    end

    if wants("held-leftovers") then
      local L = "held LEFTOVERS"
      if not (itemRow("LEFTOVERS") and haveMove("GROWL") and haveMove("SPLASH")) then
        skip("held-leftovers", "this cart has no LEFTOVERS / GROWL / SPLASH")
      else
        -- Turn 1 does nothing to anybody (GROWL against SPLASH), so the end of
        -- the turn is the only HP change; turn 2 is the knockout.
        local rec = rulesFight({
          label = L, seed = 611,
          lead = { moves = { "GROWL", "SCRATCH" }, item = "LEFTOVERS", hpAt = function(max) return max / 2 end },
          foe = { moves = { "SPLASH" }, speed = 10 },
          badges = {},
          pick = function(turn) return { move = (turn == 1) and 1 or 2 } end,
          shotWhen = function(line) return line:find("recovered with", 1, true) ~= nil end,
          shotName = "solo-rules-held-leftovers",
        })
        if rec then
          local f = rec.facts or {}
          itemFacts(L, rec, "LEFTOVERS")
          local ev, i = heldEvent(rec, "a", "LEFTOVERS", 1)
          check(ev ~= nil and ev.turn == 1,
                L .. ": the referee's `held` (side a, still held) at the end of turn 1",
                ev and ("turn %s"):format(tostring(ev.turn)))
          -- HandleLeftovers' sixteenth: max(1, floor(maxHp / 16)) under 1024 HP
          local sixteenth = math.max(1, math.floor((tonumber(f.maxHp) or 0) / 16))
          local drain = ev and prevOf(rec, i, function(e) return e.t == "drain" and e.side == "a" end)
          check(drain ~= nil and drain.amount == sixteenth and drain.hp == (f.hp or 0) + sixteenth,
                L .. ": it healed exactly a sixteenth of the maximum, onto the HP the lead walked in on",
                drain and ("+%s -> %s (max %s, from %s)"):format(tostring(drain.amount), tostring(drain.hp),
                  tostring(f.maxHp), tostring(f.hp)) or "no drain")
          local line = ev and nextMsg(rec, i)
          -- BattleText_TargetRecoveredWithItem (pokecrystal HandleLeftovers:
          -- "<TARGET>" / "recovered with" / "<ITEM>."), the lead's own: read
          -- as the player reads it, and handed to the screen as the referee
          -- said it.
          local want = tostring(f.species) .. " recovered with " .. tostring(f.itemName) .. "."
          check(line ~= nil and read12(line.text) == want, L .. ": the cart's line right behind it",
                line and read12(line.text))
          check(line ~= nil and screenSaidExact(rec, line.text) and screenSaid(rec, want),
                L .. ": and the screen said it")
          check(rec.result == "win", L .. ": a win", tostring(rec.result))
          check(rec.after ~= nil and rec.after.item == "LEFTOVERS",
                L .. ": LEFTOVERS is never used up -- still on the save's lead",
                tostring(rec.after and rec.after.item))
          check(rec.shot == true, L .. ": the line was photographed")
        end
      end
    end

    if wants("held-berry") then
      local L = "held BERRY"
      local row = itemRow("BERRY")
      if not (row and haveMove("GROWL") and haveMove("SPLASH")) then
        skip("held-berry", "this cart has no BERRY / GROWL / SPLASH")
      else
        local rec = rulesFight({
          label = L, seed = 622,
          lead = { moves = { "GROWL", "SCRATCH" }, item = "BERRY", hpAt = function(max) return max / 4 end },
          foe = { moves = { "SPLASH" }, speed = 10 },
          badges = {},
          pick = function(turn) return { move = (turn == 1) and 1 or 2 } end,
          shotWhen = function(line) return line:find("recovered using a", 1, true) ~= nil end,
          shotName = "solo-rules-held-berry",
        })
        if rec then
          local f = rec.facts or {}
          itemFacts(L, rec, "BERRY")
          check(f.holdParam == tonumber(row.heldParameter),
                L .. ": its parameter is the item row's", tostring(f.holdParam))
          local ev, i = heldEvent(rec, "a", "BERRY", 0)
          check(ev ~= nil, L .. ": the referee's `held` (side a, gone): the BERRY was eaten",
                ev and ("turn %s"):format(tostring(ev.turn)))
          local drain = ev and prevOf(rec, i, function(e) return e.t == "drain" and e.side == "a" end)
          local heal = math.min(tonumber(f.holdParam) or 0, (tonumber(f.maxHp) or 0) - (tonumber(f.hp) or 0))
          check(drain ~= nil and drain.amount == heal and drain.hp == (f.hp or 0) + heal,
                L .. ": it restored its parameter's worth, from under half HP",
                drain and ("+%s -> %s (from %s of %s)"):format(tostring(drain.amount), tostring(drain.hp),
                  tostring(f.hp), tostring(f.maxHp)) or "no drain")
          local line = ev and nextMsg(rec, i)
          -- RecoveredUsingText (pokecrystal HandleHPHealingItem's
          -- UseOpponentItem: "<TARGET>" / "recovered using a" / "<ITEM>!"),
          -- the lead's own, read as the player reads it.
          local want = tostring(f.species) .. " recovered using a " .. tostring(f.itemName) .. "!"
          check(line ~= nil and read12(line.text) == want, L .. ": the cart's line right behind it",
                line and read12(line.text))
          check(line ~= nil and screenSaidExact(rec, line.text) and screenSaid(rec, want),
                L .. ": and the screen said it")
          check(rec.result == "win", L .. ": a win", tostring(rec.result))
          check(rec.after ~= nil and (rec.after.item == nil or rec.after.item == ""),
                L .. ": the save's lead holds nothing after the fight -- the eaten BERRY is gone",
                tostring(rec.after and rec.after.item))
          check(rec.shot == true, L .. ": the line was photographed")
        end
      end
    end

    if wants("held-quickclaw") then
      local L = "held QUICK CLAW"
      if not (itemRow("QUICK_CLAW") and haveMove("SCRATCH") and haveMove("TACKLE")) then
        skip("held-quickclaw", "this cart has no QUICK CLAW / SCRATCH / TACKLE")
      else
        local function clawFight(seedValue, item, shotName)
          return rulesFight({
            label = ("%s %s (seed %d)"):format(L, item and "held" or "control", seedValue), seed = seedValue,
            lead = { moves = { "SCRATCH" }, item = item, speed = 20 },
            foe = { moves = { "TACKLE" }, speed = 300 },
            badges = {},
            shotWhen = shotName and function(line) return line:find("used scratch", 1, true) ~= nil end or nil,
            shotName = shotName,
          })
        end
        -- DetermineMoveOrder's `.equal_priority`: one BattleRandom against the
        -- claw's parameter, so the seeds are fought until one fires.
        local fired, tried, slower = nil, 0, true
        for i = 1, 20 do
          local rec = clawFight(900 + i * 13, "QUICK_CLAW", "solo-rules-held-quickclaw")
          if not rec then break end
          tried = tried + 1
          local f = rec.facts or {}
          if not (f.speedP and f.speedF and f.speedF > f.speedP) then slower = false end
          if i == 1 then itemFacts(L, rec, "QUICK_CLAW") end
          if firstMove(rec, { "SCRATCH", "TACKLE" }) == "a" then fired = rec break end
        end
        log(L .. ": fired on try", tostring(tried))
        check(slower, L .. ": the referee rated the holder the slower in every fight")
        check(fired ~= nil, L .. ": the slower holder's SCRATCH went first on a seed (the claw fired)",
              fired and fired.label or ("not in %d fight(s)"):format(tried))
        if fired then
          check(fired.result == "win", L .. ": that fight is a win", tostring(fired.result))
          local control = clawFight(fired.seed, nil)
          check(control ~= nil and firstMove(control, { "SCRATCH", "TACKLE" }) == "b",
                L .. ": the same seed with no claw: the faster foe goes first",
                control and tostring((firstMove(control, { "SCRATCH", "TACKLE" }))))
          check(control ~= nil and control.facts and control.facts.heldItem == nil,
                L .. ": (and that lead held nothing)")
          check(fired.shot == true, L .. ": the claw's turn was photographed")
        end
      end
    end

    if wants("held-thief") then
      local L = "held THIEF"
      if not (itemRow("NUGGET") and haveMove("THIEF") and haveMove("SCRATCH")) then
        skip("held-thief", "this cart has no NUGGET / THIEF / SCRATCH")
      else
        -- The faster foe's THIEF lands before the lead's knockout; the lead's
        -- NUGGET is an item no rule of the fight consumes.
        local rec = rulesFight({
          label = L, seed = 633,
          lead = { moves = { "SCRATCH" }, item = "NUGGET", speed = 20, maxHp = 400 },
          foe = { moves = { "THIEF" }, speed = 300 },
          badges = {},
          shotWhen = function(line) return line:find("stole", 1, true) ~= nil end,
          shotName = "solo-rules-held-thief",
        })
        if rec then
          local f = rec.facts or {}
          itemFacts(L, rec, "NUGGET")
          check(f.foeHeld == nil, L .. ": the wild foe holds nothing (THIEF needs an empty hand)",
                tostring(f.foeHeld))
          local lost, i = heldEvent(rec, "a", "NUGGET", 0)
          local took = heldEvent(rec, "b", "NUGGET", 1)
          check(lost ~= nil and took ~= nil,
                L .. ": the referee's `held` pair: the lead's NUGGET gone, the foe holding it",
                ("%s / %s"):format(tostring(lost ~= nil), tostring(took ~= nil)))
          local line = lost and nextMsg(rec, i)
          -- StoleText (pokecrystal BattleCommand_Thief) over the thief, the
          -- foe's monster: `<USER>` is PlaceBattlersName, so its name carries
          -- side b's mark and the player's screen says it behind "Enemy "
          -- (K17) -- "Enemy <MON>" / "stole <ITEM>" / "from its foe!".
          local words = tostring(f.foeSpecies) .. " stole " .. tostring(f.itemName) .. " from its foe!"
          check(line ~= nil and plain12(line.text) == words, L .. ": the cart's line behind them",
                line and plain12(line.text))
          check(line ~= nil and markOf(line.text) == "b", L .. ": naming the thief by the foe's mark",
                line and line.text)
          check(line ~= nil and screenSaidExact(rec, line.text) and screenSaid(rec, "Enemy " .. words),
                L .. ": and the screen said it as \"Enemy " .. tostring(f.foeSpecies) .. " stole ...\"")
          check(rec.result == "win", L .. ": a win", tostring(rec.result))
          check(rec.after ~= nil and (rec.after.item == nil or rec.after.item == ""),
                L .. ": the save's lead has lost the NUGGET after the fight",
                tostring(rec.after and rec.after.item))
          check(rec.shot == true, L .. ": the theft was photographed")
        end
      end
    end

    if wants("held-smokeball") then
      local L = "held SMOKE BALL"
      local row = itemRow("SMOKE_BALL")
      if not (row and haveMove("SCRATCH") and haveMove("SPLASH")) then
        skip("held-smokeball", "this cart has no SMOKE BALL / SCRATCH / SPLASH")
      else
        -- RUN first, then fight: the far faster foe makes the ordinary escape
        -- a roll (SoloBattle's escapeOdds), which the control has to lose.
        local function runFight(seedValue, item, shotName)
          return rulesFight({
            label = ("%s %s (seed %d)"):format(L, item and "held" or "control", seedValue), seed = seedValue,
            lead = { moves = { "SCRATCH" }, item = item, speed = 10 },
            foe = { moves = { "SPLASH" }, speed = 400 },
            badges = {},
            pick = function(turn) return (turn == 1) and { run = true } or { move = 1 } end,
            shotWhen = shotName and function(line) return line:find("fled using a", 1, true) ~= nil end or nil,
            shotName = shotName,
          })
        end
        local refused = nil
        for i = 1, 8 do
          local rec = runFight(700 + i * 17, nil)
          if not rec then break end
          if screenSaid(rec, "Can't escape!") and rec.turns >= 2 then refused = rec break end
        end
        check(refused ~= nil, L .. ": a control seed whose first RUN is refused (\"Can't escape!\")",
              refused and refused.label)
        if refused then
          local f = refused.facts or {}
          check(f.speedP and f.speedF and f.speedP < f.speedF,
                L .. ": the lead is the slower, so its escape is a roll",
                ("%s v %s"):format(tostring(f.speedP), tostring(f.speedF)))
          local rec = runFight(refused.seed, "SMOKE_BALL", "solo-rules-held-smokeball")
          if rec then
            local g = rec.facts or {}
            itemFacts(L, rec, "SMOKE_BALL")
            check(screenSaidLike(rec, "fled using a " .. flat12(row.name) .. "!"),
                  L .. ": the screen said the cart's \"fled using a SMOKE BALL!\"")
            check(not screenSaid(rec, "Can't escape!"), L .. ": and never \"Can't escape!\"")
            check(rec.turns == 1, L .. ": the fight ended on that first RUN", ("%d command(s)"):format(rec.turns))
            check(rec.result == "run", L .. ": as an escape", tostring(rec.result))
            check(firstMove(rec, { "SCRATCH", "SPLASH" }) == nil, L .. ": before anybody moved")
            check(rec.after ~= nil and rec.after.item == "SMOKE_BALL",
                  L .. ": SMOKE BALL is never used up -- still on the save's lead",
                  tostring(rec.after and rec.after.item))
            check(rec.shot == true, L .. ": the line was photographed")
            log(L .. ": " .. tostring(g.species) .. " fled on seed " .. tostring(refused.seed))
          end
        end
      end
    end
  end

  rulesLegs12()

  -- ------------------------------------------------------------------

  log("shots in", SHOT_DIR)
  log("GAPS:" .. tostring(fail))
  log("SUMMARY", "pass=" .. pass, "fail=" .. fail)
  log("DONE")
  love.event.quit(fail > 0 and 1 or 0)
end
