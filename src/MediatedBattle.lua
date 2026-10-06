-- The client half of a mediated 1v1: a screen that sends choices and draws
-- what it is told.
--
-- **Nothing in this file decides anything about the fight.**  That is the whole
-- point of it.  Until PROTOCOL 10 an MMO battle was the engine's own
-- `LinkBattle` running in lockstep inside both players' processes over
-- `SessionNet`, which meant the arithmetic of a fight lived on the same side of
-- the wire as the person who benefits from getting it wrong -- and it meant the
-- two copies had to agree about their content before they were allowed to
-- start, which is what `Sessions.canBattle` and the fingerprint were for.  The
-- intermediator (the Node hub, or a LAN host running `src/BattleSim/`) now owns
-- hit, crit, damage, status and the outcome, so this side is reduced to three
-- jobs:
--
--   1. upload what we are bringing -- `mmo.battle_party` (mons + optional
--      battle `bag` for PROTOCOL 15 proofs), and on the host
--      `mmo.battle_ruleset` -- before the fight opens;
--   2. put a choice on the wire when a turn opens;
--   3. apply the ordered `mmo.battle_event` stream to a screen.
--
-- Everything the sim needs about a monster therefore rides on (1), because
-- there is no move table and no type chart on either intermediator and there
-- must never be one: those are the player's own decoded ROM, and this repo may
-- not carry them (see the legal posture in CLAUDE.md).  A move brings its own
-- power and accuracy; the chart is uploaded for one match and thrown away with
-- it.
--
-- Because the fingerprint gate is gone, two players whose copies disagree can
-- now fight -- a Red against a Yellow, a data pack against vanilla.  What they
-- are agreeing on instead is *this upload*: the host's chart decides the
-- matchups and each side's own records decide its own moves.  That is a real
-- change in what a battle means and it is deliberate; the residual is that a
-- modified client can lie on the sheet it sends, which is the accepted v1
-- surface written down in src/Wire.lua's mediated-battle section.
--
-- The screen draws a classic Gen1 1v1 field when CLASSIC BATTLE UI is on
-- (or Battlefield.enabled is false): foe front pic + top-left HUD, ally
-- back pic + bottom HUD, message box, optional AnimPlayer. Otherwise
-- presentation is the top-down arena theatre (640×360 fill) from
-- src/Battlefield.lua. Co-op still owns the multi-slot renderer.
--
-- ------- Gen 3 (FireRed / LeafGreen / Emerald)
--
-- The same screen, the same queue, the same rules -- a Gen 3 arm at every
-- place the generation shows, and nothing of Gen 1's engine reached on the
-- way (a Gen 1 module name on Emerald is a boot error, and the rest only
-- describe a Game Boy):
--
--   * the upload is src/Sheet3.lua's (contract C4): session-party sheets
--     with IVs / EVs / nature already in the stats, ability, held item and
--     its hold effect, Hidden Power, the ordered type chart and the compact
--     move pool, the §4 bag from the session's pockets (numeric ids);
--   * the badges ride only into a fight against the computer (wild, a
--     trainer): the badge numbers off the cart's flags (Gen3.badgeList), for
--     the referee's badge boosts and obedience caps, while a 1v1 is a link
--     battle and sends none (`badgesOf`, docs/plans/gen3-badge-rules.md);
--     there are no vitamins (§6);
--   * the referee is BattleSim3, so the stream carries Gen 3's seven extra
--     kinds (ability weather held form sub ball, C5 §7.2, and obey, K3 of
--     docs/plans/gen3-badge-rules.md) -- each has a place in the queue below,
--     and `held` is the writeback of a consumed / stolen item;
--   * a knockout is priced by src/Exp3.lua on the session party (Cmd_getexp:
--     Exp. Share, Lucky Egg, traded, trainer, EVs), a level's moves by the
--     cart's learnset, a full moveset by the cart's own LearnMove exchange
--     (src/LearnMove.lua), an evolution by the cart's evolution rules;
--   * a catch goes into the session party or the PC with the dex, the OT and
--     the ball written the way Catching.storeCaught writes them;
--   * music and sound are the game3 m4a player's (Gen.playBattleMusic /
--     Gen3.audio), pics are the cart's 64x64 battle pics (Gen3.frontPic /
--     backPic);
--   * the arena paints in window space from render.hud (drawsWidescreen, as
--     on Gold), while CLASSIC BATTLE UI draws a GBA-shaped 240x160 page into
--     the game3 canvas (ClassicBattle.drawGen3 when it has one, else the
--     plain page at the end of this file); the screen closes with Gen3Ui.pop,
--     there being no game.stack for it to pop itself from.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Effects1 = need("BattleSim/Effects")
local Gen = need("Gen")
-- The Gen 3 engine adapters and the modal-stack toolkit (lazy and guarded:
-- nothing of src.core.game3.* is reached off a Gen 3 boot).
local Gen3 = need("Gen3")
local Gen3Ui = need("Gen3Ui")
-- The Gen 3 upload (C4 sheets, ruleset, bag) and the Gen 3 award.
local Sheet3 = need("Sheet3")

local Exp3 = need("Exp3")
local SoloBrain = need("SoloBrain")
local Battlefield = need("Battlefield")
-- Which particle effect a move / item / condition / stat stage wears. A
-- catalogue, not a renderer: Battlefield draws what this resolves.
local Vfx = need("Vfx")

-- The look an item event plays.  Gen 1/2 name the item on the wire; Gen 3
-- sends the pret item number, which the Gen 3 catalogue reads by the name the
-- cart prints (balls answer nil in both, left to the throw chain).
local function itemVfx(id)
  if Gen3.active() then
    local n = tonumber(id)
    return Vfx.forItem3(n and Gen3.itemName(n) or id)
  end
  return Vfx.forItem(id)
end

-- The Gen 2 half of the award. Gen 1 prices a refereed faint with the engine's
-- `src/battle/Experience.lua`, which Gold does not have -- its award lives
-- inside a live `src/battle/gen2/Battle.lua` this screen never owns. `Exp2` is
-- the mod-side orchestration over Gen 2's own `Mon` primitives; see its header.
local Exp2 = need("Exp2")
-- Mid-battle evolution movie: timing + apply. Twin of CoopBattle's own
-- require -- the two screens must not drift on qualify / cancel / apply.
local EvolveFx = need("EvolveFx")
-- Free-slot apply + the generation's own forget prompt. Shared with
-- CoopBattle so a 1v1 and a 2-on-2 cannot disagree about "already knows".
local LearnMove = need("LearnMove")
-- Classic 160×144 chrome option. Owns the key the manager row uses; this
-- screen latches it at construct so a mid-fight flip cannot swap skins.
local ClassicBattle = need("ClassicBattle")

local M = {}
M.__index = M

local floor, max, min = math.floor, math.max, math.min

-- BattleSim vs BattleSim2 item tables — vitamins already gen-switched;
-- bag upload / ball hints must match the hub sim generation too.
local Effects2
-- Gen 3's reading of the same three questions, answered by the BattleSim3 bag
-- catalog through Sheet3 (numeric ids; no vitamins, no Metronome effect id --
-- the Gen 3 pool is the whole move table and the sim filters it).
local Effects3 = {
  itemEffect = function(id) return Sheet3.itemEffect(id) end,
  idOf = function() return nil end,
  itemFailsOnFainted = function(effect) return Sheet3.itemFailsOnFainted(effect) end,
}
M.Effects3 = Effects3
local function effectsFor(game)
  local generation = Gen.generation(game)
  if generation == 3 then return Effects3 end
  if generation == 2 then
    if not Effects2 then Effects2 = need("BattleSim2/Effects") end
    return Effects2
  end
  return Effects1
end
-- Gold's wPlayerSubStatus4 bits an item sets and refuses to set twice (X
-- ACCURACY, GUARD SPEC., DIRE HIT), by their item-effect field (`noteItemFlags2`).
local FLAG_OF_ITEM = { xAccuracy = true, focusEnergy = true, mist = true }

-- Back-compat alias for any leftover Effects.* call sites in this file.
local Effects = setmetatable({}, {
  __index = function(_, k)
    return Effects1[k]
  end,
})

-- ------- the engine, loaded once and never at file scope
--
-- Lazily and behind pcall, for the reason src/CoopBattle.lua loads its own
-- renderer that way: `modkit validate` loads this file headlessly with no love
-- and no data, and the mod's suite drives the whole exchange with no engine at
-- all.  A build that cannot draw still uploads, still sends choices and still
-- hears the outcome -- it simply has nothing to paint, which is a far better
-- failure than a battle that cannot start.
local engine, engineTried

local function loadEngine()
  if engineTried then return engine end
  engineTried = true
  -- Gen 3 has none of the modules below: src.battle.BattleState and
  -- src.ui.PartyMenu are a boot error on Emerald, and the rest describe a Game
  -- Boy screen.  Everything the Gen 3 arms need is reached through Gen3 /
  -- Gen3Ui instead, so the engine bag is empty but for the marker.
  if Gen3.active() then
    engine = { gen3 = true }
    return engine
  end
  local ok, Font = pcall(require, "src.render.Font")
  if not ok then
    mod.log:warn("the engine's font module is unavailable, so a mediated "
      .. "battle cannot be drawn; the fight still runs -- report this with "
      .. "the game version")
    engine = false
    return engine
  end
  local function grab(key, path)
    local good, value = pcall(require, path)
    if good then return value end
    return nil
  end
  engine = {
    Font = Font,
    HudTiles = grab("HudTiles", "src.render.HudTiles"),
    AnimPlayer = grab("AnimPlayer", "src.battle.AnimPlayer"),
    BattleState = grab("BattleState", "src.battle.BattleState"),
    Sprites = grab("Sprites", "src.pokemon.Sprites"),
    -- Display only, and soft for that reason: it names a move's type for the
    -- move list's own column (`moveTypeName`). `displayName` needs no `load`
    -- -- it falls back to the module's vanilla records -- so a build without
    -- the chart shows the raw type id rather than losing the column.
    TypeChart = grab("TypeChart", "src.battle.TypeChart"),
    -- Exp is the *client's* arithmetic and can only ever be. The referee holds
    -- no species table (the legal floor -- no ROM bytes on a hub), so it can
    -- never price a faint: it states what fell and how many shared it, and
    -- this runs the engine's own formula over the player's own save (see
    -- `gainExp`). Grabbed rather than required so a build that cannot load it
    -- fights on, exp-less, instead of failing to open a battle at all.
    Experience = grab("Experience", "src.battle.Experience"),
    -- The curve behind the exp strip, soft beside Experience because it is a
    -- *display* dependency: a build without it still awards exp and still
    -- levels, the plate simply draws no strip (see `expFraction`). Twin of
    -- CoopBattle's own grab, and for the same reason.
    Growth = grab("Growth", "src.pokemon.Growth"),
    -- Start-menu bag icons for the classic full-page party picker.
    PokemonIcon = grab("PokemonIcon", "src.ui.PokemonIcon"),
    PartyMenu = grab("PartyMenu", "src.ui.PartyMenu"),
  }
  -- Optional SFX / music. Missing Sound or Music must not fail the whole
  -- load — headless / no-audio builds still fight without them.
  do
    local good, value = pcall(require, "src.core.Sound")
    if good then engine.Sound = value end
  end
  do
    local good, value = pcall(require, "src.core.Music")
    if good then engine.Music = value end
  end
  return engine
end

M.loadEngine = loadEngine

-- ------- how far along its level a monster is
--
-- Verbatim twin of CoopBattle's helper of the same name (which is itself the
-- Gen 2 HUD's `HpBar.expFraction` ported to Gen 1 spellings): the exp a mon
-- carries is `mon.exp`, and the curve comes off the species def's
-- `growthRate` through `Growth.expForLevel` -- the same call `Experience.apply`
-- levels by, so the strip and the level can never disagree about where a level
-- ends. Kept a copy rather than shared because the two screens load their
-- engines separately and neither requires the other.
--
-- **nil is a real answer and means "draw no strip".** No species def, no
-- Growth module, no `mon.exp`: three states where any number this could return
-- would be invented, and an invented exp bar on somebody's plate is worse than
-- no bar at all -- Battlefield's `plateModel` treats a nil `expFrac` as exactly
-- that no-data state. Everything is pcall-guarded because it runs inside the
-- draw path.
--
-- The mon here is the **save** mon, never the wire sheet: a `Wire.battleMon`
-- carries level and HP and no exp at all, so a fraction worked off one would
-- be a fraction of nothing.
-- `game` rather than `data`, since round 7: the curve a Gen 2 monster levels on
-- is Gold's own (`Mon.growthFor` / `Mon.experienceForLevel` over
-- `mon.experience`), and reading Gen 1's `Growth.expForLevel` off `mon.exp`
-- would answer nil on every Gold boot -- a plate that silently never drew its
-- strip. Callers that only hold a dataset pass `{ data = data }`, which is the
-- shape both branches read.
local function expFraction(game, mon)
  -- Gen 3 reads the cart's own curve off the mon itself (growth rate + exp);
  -- see Exp3.fraction.
  if type(mon) == "table" and Gen3.active() then return Exp3.fraction(mon) end
  local data = game and game.data
  if type(data) ~= "table" or type(mon) ~= "table" then return nil end
  if Gen.generation(game) == 2 then
    local ok, frac = pcall(Exp2.fraction, game, mon)
    if ok then return frac end
    return nil
  end
  if mon.exp == nil then return nil end
  local eng = loadEngine()
  local Growth = eng and eng.Growth
  if not (Growth and Growth.expForLevel) then return nil end
  local def = mon.species and (data.pokemon or {})[mon.species]
  if not def then return nil end
  local level = tonumber(mon.level) or 1
  local ok, base = pcall(Growth.expForLevel, def.growthRate, level,
    data.growth_rates)
  if not ok then return nil end
  local okNext, after = pcall(Growth.expForLevel, def.growthRate, level + 1,
    data.growth_rates)
  if not okNext then return nil end
  base, after = tonumber(base), tonumber(after)
  if not (base and after) or after <= base then return nil end
  local into = (tonumber(mon.exp) or base) - base
  local frac = into / (after - base)
  -- NaN compares false against every bound there is, so it is refused rather
  -- than clamped -- the same rule `startDrain` applies to a wire `to`.
  if frac ~= frac then return nil end
  return math.max(0, math.min(1, frac))
end

-- Classic 1v1 anchors (AnimPlayer / BattleState pic windows).
-- Ally back pics draw at 2x on Gen 1 (32×32); Gen 2 backs are 48×48 at 1x.
local CLASSIC_PLAYER = { x = 8, y = 40 }
local CLASSIC_ENEMY = { x = 88, y = 0 }
local PLAYER_PIC_SCALE_GEN1 = 2
local PLAYER_PIC_SCALE_GEN2 = 1
M.PLAYER_PIC_SCALE = PLAYER_PIC_SCALE_GEN1
M.CLASSIC_PLAYER = CLASSIC_PLAYER
M.CLASSIC_ENEMY = CLASSIC_ENEMY

local function playerPicScale(game)
  local generation = Gen.generation(game)
  -- Gen 3 back pics are full 64x64 frames, drawn at their own size.
  if generation == 2 or generation == 3 then return PLAYER_PIC_SCALE_GEN2 end
  return PLAYER_PIC_SCALE_GEN1
end

-- ------- snapshots
--
-- What this client claims it is bringing, in the shapes src/Wire.lua sanitises.
-- Both halves are built from `game.data` -- the player's own decoded copy --
-- and neither is stored anywhere past the match.

-- The widest neutral chart to offer when there is no type table to read.
--
-- A fallback rather than a default: a build with no `type_chart` has no
-- matchups to state, and a chart of nothing but neutral cells says exactly
-- that.  Sixteen is comfortably above Gen 1's fifteen types and comfortably
-- inside Config.BATTLE_TYPE_MAX, so a move naming any type this client could
-- have produced still finds a row -- and every row reads 100, which is the
-- honest answer for a client that does not know the matchups.
M.NEUTRAL_TYPES = 16

-- The engine spells a type as an id ("NORMAL"); the wire spells it as a small
-- integer, because the chart that crosses it is a rectangle of numbers and a
-- move names its own type by index into that rectangle.
--
-- **The ordering has to be the same on both clients, and nothing on the wire
-- states it.**  The host uploads the chart and the guest uploads moves carrying
-- indices into it, so a guest that ordered its types differently would have
-- every matchup read off the wrong row -- silently, and only for its own moves.
-- A plain sort of the ids is what makes that agree: two copies with the same
-- type set produce the same list whatever order their tables happened to
-- iterate in, and Lua's `pairs` order is not something either side may rely on.
--
-- Two copies with *different* type sets still disagree, and that is the
-- residual the fingerprint gate used to cover.  It is accepted rather than
-- fixed here: refusing the fight would put the mods-incompatibility refusal
-- back, which is the thing PROTOCOL 10 exists to remove.
--
-- Memoised against the data table itself and weakly, so a hot reload that
-- rebuilds `game.data` does not keep the old ordering alive.  `false` is
-- cached for a build with no chart at all, so the walk is not repeated per
-- battle.
local typeOrderCache = setmetatable({}, { __mode = "k" })

local function typeOrder(data)
  if type(data) ~= "table" then return nil end
  local hit = typeOrderCache[data]
  if hit ~= nil then return hit or nil end

  local chart = type(data.type_chart) == "table" and data.type_chart or nil
  if not chart then
    typeOrderCache[data] = false
    return nil
  end

  local seen, ids = {}, {}
  local function note(id)
    if type(id) ~= "string" or id == "" or seen[id] then return end
    seen[id] = true
    ids[#ids + 1] = id
  end
  -- The registry's own type records first, then anything a matchup row names
  -- that they missed: a data pack may register a matchup against a type it
  -- did not also describe, and a type with no row is still a type a move can
  -- claim.
  if type(chart.types) == "table" then
    for id in pairs(chart.types) do note(id) end
  end
  if type(chart.matchups) == "table" then
    for _, row in ipairs(chart.matchups) do
      if type(row) == "table" then note(row.attacker); note(row.defender) end
    end
  end

  if #ids == 0 then
    typeOrderCache[data] = false
    return nil
  end
  table.sort(ids)
  -- Config.BATTLE_TYPE_MAX bounds both axes of the chart, and Wire refuses a
  -- wider one outright.  Cutting the tail is what keeps an over-wide pack
  -- fighting: the types that survive keep their matchups, and a move naming
  -- one that did not is read as neutral by the sim rather than refusing
  -- somebody's whole team.
  for i = #ids, Config.BATTLE_TYPE_MAX + 1, -1 do ids[i] = nil end

  local index = {}
  for i = 1, #ids do index[ids[i]] = i - 1 end

  local out = { ids = ids, index = index }
  typeOrderCache[data] = out
  return out
end

M.typeOrder = typeOrder

local moveOf

-- The moves each cart's METRONOME can never call, by registry id (the pool
-- `snapshotRuleset` uploads leaves them out; the referee picks from the pool).
--
--   Red   pokered MetronomePickMove (engine/battle/core.asm): a BattleRandom
--         byte is re-drawn while it is 0, at or past STRUGGLE (`ASSERT
--         NUM_ATTACKS == STRUGGLE`: nothing past it is a move), or METRONOME
--         -- so METRONOME and STRUGGLE.
--   Gold  pokecrystal BattleCommand_Metronome (engine/battle/move_effects/
--         metronome.asm, identical in pokegold) re-draws a byte past
--         NUM_ATTACKS or in MetronomeExcepts (data/moves/
--         metronome_exception_moves.asm, the same list in both repos):
--         NO_MOVE, METRONOME, STRUGGLE, SKETCH, MIMIC, COUNTER, MIRROR_COAT,
--         PROTECT, DETECT, ENDURE, DESTINY_BOND, SLEEP_TALK and THIEF.  (Its
--         third re-draw -- a move the user already knows, CheckUserMove -- is
--         the user's, so the referee's pick owns it, not this list.)
--
-- Before contract K13 Gold's pool was cut at 200 rows and took only Red's two
-- exclusions, so the last ~50 ids could never be called and the twelve the
-- cart bars could.
M.METRONOME_EXCEPT = {
  [1] = { METRONOME = true, STRUGGLE = true },
  [2] = {
    METRONOME = true, STRUGGLE = true, SKETCH = true, MIMIC = true,
    COUNTER = true, MIRROR_COAT = true, PROTECT = true, DETECT = true,
    ENDURE = true, DESTINY_BOND = true, SLEEP_TALK = true, THIEF = true,
  },
}

-- Gold's wTimeOfDay as the referee spells it ("morn" | "day" | "nite";
-- src/BattleSim2/Turn.lua `TIMES`), or nil.
--
-- The cart's battle reads wTimeOfDay -- GetTimeOfDay's MORN_F / DAY_F / NITE_F
-- off the RTC hour (engine/rtc/rtc.asm), never DARKNESS_F, which is a palette
-- -- and BattleCommand_TimeBasedHealContinue (engine/battle/effect_commands
-- .asm) doubles a MORNING SUN / SYNTHESIS / MOONLIGHT heal when it is the
-- move's own time.  The engine's Gold battle is handed the same reading as
-- it opens (src/world/gen2/World.lua startScriptedBattle's `timeOfDay =
-- self:timeOfDayId()`), off the overworld's clock word.  The reading itself
-- is src/EvolveFx.lua's `timeOfDay2` -- the one place the client asks the
-- overworld for wTimeOfDay, which EvolveAfterBattle's happiness evolutions
-- read too -- spelled here in the referee's lower case.
--
-- Nothing answers (no overworld: a headless run, the title screen) -> nil,
-- which the referee reads as the move's own time.  Read once, as the
-- ruleset is cut: the cart's wTimeOfDay is only rewritten by the overworld's
-- clock tick, which a battle does not run.
function M.timeOfDay2(game)
  local word = EvolveFx.timeOfDay2(game)
  return type(word) == "string" and word:lower() or nil
end

-- The ephemeral rules for one match: the type chart, as integer percent.
--
-- The engine's table holds x10 multipliers (5 is half, 20 is double, 0 is
-- immune) and states only the matchups that are not neutral; the wire wants a
-- full rectangle of percent, because a fraction that crossed a JSON boundary
-- into two languages would round differently on the two ends and the same
-- attack would hit for different amounts depending on who was hosting.  So the
-- rectangle is filled with EFF_NEUTRAL and the stated rows are written over it.
function M.snapshotRuleset(game, opts)
  -- Gen 3 uploads the cart's ordered chart and the compact move pool
  -- (docs/plans/gen3-battle-sheet.md §3) -- no percent rectangle, so
  -- NEUTRAL_TYPES never applies there: a missing `typeTable` is read by the
  -- sim as every matchup neutral.  `opts.wild` lets a wild fight open under
  -- the overworld's weather.
  if Gen.generation(game) == 3 then return Sheet3.ruleset(game, opts) end
  local data = game and game.data
  local order = typeOrder(data)
  local width = order and #order.ids or M.NEUTRAL_TYPES

  local chart = {}
  for i = 1, width do
    local row = {}
    for j = 1, width do row[j] = Wire.EFF_NEUTRAL end
    chart[i] = row
  end

  -- Red's TypeEffects order (`chartOrder`, wave 5 of docs/plans/
  -- gen12-referee-gaps-fix.md): the same rows, in the table's own order, as
  -- the flat chart-index pairs { atk1, def1, atk2, def2, ... } the Red referee
  -- walks (BattleSim Turn `chartRowsOf` / `_typeRows`).  pokered
  -- AdjustDamageForMoveType (engine/battle/core.asm) applies every
  -- TypeEffects row whose attacker is the move's type and whose defender is
  -- either of the target's, top to bottom, flooring after each, and leaves
  -- the LAST row's multiplier in wDamageMultipliers -- which
  -- DisplayEffectiveness and PrintMoveFailureText read -- so the order is a
  -- rule: a dual type whose immunity row comes before another row of the
  -- move's type is "<USER>'s attack missed!", not "It doesn't affect".  The
  -- engine keeps the rows ROM-ordered (src/battle/TypeChart.lua `matchups`),
  -- which is this walk's order.  A row naming a type the chart's axis does
  -- not carry (cut past BATTLE_TYPE_MAX) is left out: no move and no monster
  -- can name that index, so the row could never match -- and one with no
  -- multiplier writes no cell, so the referee would apply the neutral cell
  -- the cart never had.
  local chartOrder = (Gen.generation(game) == 1) and {} or nil

  if order and type(data.type_chart.matchups) == "table" then
    for _, entry in ipairs(data.type_chart.matchups) do
      if type(entry) == "table" then
        local attacker = order.index[entry.attacker]
        local defender = order.index[entry.defender]
        local mult = tonumber(entry.multiplier)
        if attacker and defender and mult then
          chart[attacker + 1][defender + 1] =
            min(Wire.CHART_MAX, max(0, floor(mult * 10)))
          if chartOrder then
            chartOrder[#chartOrder + 1] = attacker
            chartOrder[#chartOrder + 1] = defender
          end
        end
      end
    end
  end

  -- ------- which types are Special
  --
  -- Gen 1 and Gen 2 both split physical from special by TYPE, and the chart
  -- itself is the authority: every type record the `type_chart` registry
  -- serves carries a `category` of "physical" or "special"
  -- (src/battle/TypeChart.lua's TYPES, merged into `data.type_chart.types` by
  -- the registry's own write). Reading it means a mod that registers a
  -- nineteenth type is honoured, Gen 2's Dark is picked up without a second
  -- list here, and -- the reason this stopped being a name match -- **a type
  -- whose registry id is not its own name still resolves**.
  --
  -- That last one was a real, shipped bug. Psychic's id is `PSYCHIC_TYPE`,
  -- because `PSYCHIC` is already a move; the old table keyed on `PSYCHIC`, so
  -- Psychic dropped out of the uploaded list and every Psychic move in every
  -- refereed fight was resolved on atk/def instead of spc/spc, with Light
  -- Screen not halving it. Six of the seven types matched, so the guard below
  -- -- which only fired at *zero* -- never said a word.
  --
  -- The two name lists are the fallback for a type the chart ships without a
  -- category, and Gold needs them: `TypeChart.TYPES` carries records for the
  -- fifteen Gen 1 types only, so on a Gen 2 boot Dark and Steel reach the
  -- chart through their matchups with no record behind them.
  --
  -- **Physical is listed as well as Special, and not for symmetry.** The
  -- warning below fires for a type neither list nor record can place, and
  -- without the physical names every Gen 2 Steel move would raise a false
  -- alarm about a type that is Physical exactly as intended. A warning that
  -- cries wolf on stock data is a warning nobody reads.
  local SPECIAL = {
    FIRE = true, WATER = true, GRASS = true, ELECTRIC = true,
    ICE = true, DRAGON = true, DARK = true,
    PSYCHIC = true, PSYCHIC_TYPE = true,
  }
  local PHYSICAL = {
    NORMAL = true, FIGHTING = true, FLYING = true, POISON = true,
    GROUND = true, ROCK = true, BUG = true, GHOST = true, STEEL = true,
    BIRD = true, -- the unused beta type at chart index 13
  }
  local specialTypes = {}
  if order then
    local records = type(data) == "table" and type(data.type_chart) == "table"
      and data.type_chart.types or nil
    local unknown = {}
    for i, id in ipairs(order.ids) do
      local record = type(records) == "table" and records[id] or nil
      local category = type(record) == "table" and record.category or nil
      local isSpecial
      if category ~= nil then
        isSpecial = (category == "special")
      else
        isSpecial = SPECIAL[id] == true
        -- Neither the record nor either name list places this one, so it is
        -- about to be fought as Physical on a guess.
        if not isSpecial and not PHYSICAL[id] then
          unknown[#unknown + 1] = id
        end
      end
      if isSpecial then specialTypes[#specialTypes + 1] = i - 1 end
    end
    -- Named rather than counted, and that is the fix to the guard: a list
    -- that is *partly* wrong is the dangerous case, and counting only caught
    -- the totally-empty one.
    if #unknown > 0 then
      local one = #unknown == 1
      mod.log:warn("type chart has no category for %s; %s will be fought as "
        .. "Physical (atk/def) and Light Screen will not halve %s. Give the "
        .. "type record a category of \"special\" or \"physical\", or upload "
        .. "specialTypes yourself",
        table.concat(unknown, ", "),
        one and "it" or "they", one and "it" or "them")
    end
    -- ...and the original guard, still worth keeping: a chart that resolved
    -- cleanly and yielded nothing Special at all is a ruleset in which Light
    -- Screen and Special damage can never fire.
    if #order.ids > 0 and #specialTypes == 0 then
      mod.log:warn("type chart has %d types and none of them are Special; "
        .. "Light Screen and Special damage will treat every move as "
        .. "Physical. Check the type records' `category` (or upload "
        .. "specialTypes yourself)", #order.ids)
    end
  end

  -- Ephemeral Metronome pool from the host's own move table.  Sorted for a
  -- stable wire order; what the cart's METRONOME can never call is left out
  -- (M.METRONOME_EXCEPT -- Metronome itself among them, so a call cannot
  -- recurse), and Gold's whole table fits the cap since K13.
  local metronomePool = {}
  local moveCount = 0
  if type(data) == "table" and type(data.moves) == "table" then
    local ids = {}
    -- Records only.  Gold's imported moves.lua carries two scalars beside its
    -- 251 records -- `generation = 2` and `source` (src/import/
    -- RomExtractorGen2.lua extractMoves seeds `out` with them) -- and either,
    -- walked as a move, is a 40-power default the pool would offer Metronome
    -- (or, for the number, a throw in `moveOf`).  They sort after every
    -- capitalised id and the pool cap stops the walk first on a stock Gold
    -- table, which is the only reason that never fired.
    for id, record in pairs(data.moves) do
      if type(record) == "table" then
        moveCount = moveCount + 1
        ids[#ids + 1] = id
      end
    end
    table.sort(ids)
    -- What the cart's METRONOME never picks, per cart (M.METRONOME_EXCEPT).
    -- Metronome's own effect is excluded on top of the id lists, so a content
    -- mod's second Metronome cannot recurse either.  Use this boot's Effects
    -- pack: Gen 1 Effects.idOf("METRONOME_EFFECT") is 83, and Gen 2 maps
    -- EFFECT_METRONOME onto the same id.  A Gen 1-only lookup would still work
    -- after that alias, but comparing against the pack that `moveOf` just used
    -- is the one that cannot drift.
    local generation = Gen.generation(game)
    local except = M.METRONOME_EXCEPT[generation == 2 and 2 or 1]
    local metroEffect = effectsFor(game).idOf("METRONOME_EFFECT")
    for _, id in ipairs(ids) do
      if #metronomePool >= Config.BATTLE_METRONOME_POOL_MAX then break end
      local idKey = type(id) == "string" and id:upper() or ""
      if not except[idKey] then
        local sheet = moveOf(data, { id = id, pp = 5 }, order, generation)
        if sheet and sheet.effect ~= metroEffect then
          -- Gold's cart number (wave 5): pokecrystal BattleCommand_Metronome
          -- `.GetMove` draws a BattleRandom byte that IS a move number, and
          -- the referee finds the pick by it (BattleSim2 Turn
          -- `byNumber[entry.num or i]`).  The engine's Gold move record keeps
          -- it as `index` (src/import/RomExtractorGen2.lua extractMoves: its
          -- place in moveOrder, POUND 1).  1..NUM_ATTACKS only -- the wire
          -- refuses the whole ruleset past it, and `.GetMove` redraws a byte
          -- there anyway -- so a content mod's move numbered past the cart's
          -- table states none and is found by its pool place.
          if generation == 2 then
            local record = data.moves[id]
            local num = type(record) == "table" and tonumber(record.index) or nil
            local top = tonumber(Wire.NUM_ATTACKS2) or 251
            if num and num == floor(num) and num >= 1 and num <= top then
              sheet.num = num
            end
          end
          metronomePool[#metronomePool + 1] = sheet
        end
      end
    end
    if moveCount > 0 and #metronomePool == 0 then
      mod.log:warn("move table has %d entries but Metronome pool is empty; "
        .. "METRONOME will say \"But nothing happened\". Check move sheets "
        .. "decode (power/type/effect) from START > POKeMON",
        moveCount)
    end
  end

  -- No seed: the intermediator is the only party that rolls anything and can
  -- perfectly well pick its own.  Offering one would be claiming a say in the
  -- randomness that this side deliberately no longer has.
  local out = { chart = chart }
  if #specialTypes > 0 then out.specialTypes = specialTypes end
  if #metronomePool > 0 then out.metronomePool = metronomePool end
  -- Red's TypeEffects order (built with the chart, above).  Whole or not at
  -- all, on the wire's rule (Wire.battleRuleset refuses a list longer than
  -- CHART_ORDER_MAX, and with it the ruleset): a content pack whose chart
  -- outgrows it fights on the referee's product reading -- what every
  -- fight read before the order was uploaded -- rather than not at all.
  if chartOrder and #chartOrder > 0 then
    local cap = tonumber(Wire.CHART_ORDER_MAX) or 512
    if #chartOrder <= cap then
      out.chartOrder = chartOrder
    else
      mod.log:warn("type chart has %d matchup rows, more than the %d a Red "
        .. "ruleset can carry, so this fight reads a dual type's matchups as "
        .. "their product (its effectiveness line and \"doesn't affect\" may "
        .. "differ from the cart's). Trim the type_chart registry's matchups",
        #chartOrder / 2, cap / 2)
    end
  end
  -- Gold's wTimeOfDay, which MORNING SUN / SYNTHESIS / MOONLIGHT compare
  -- outside a link fight (`M.timeOfDay2`).  The referee ignores it in a link
  -- fight itself (BattleCommand_TimeBasedHealContinue's `wLinkMode` check), so
  -- it is stated whatever the mode; nil when this boot has no clock to read,
  -- which the referee takes as the move's own time.  Gen 2 only: Red has no
  -- clock, and the wire refuses the field on no other generation's ruleset.
  if Gen.generation(game) == 2 then out.timeOfDay = M.timeOfDay2(game) end
  -- The chart's axis by name: `typeIds[i + 1]` is the registry id of the type
  -- every row, column, move and monster on this upload calls `i`.  The referee
  -- holds no type table and a move row carries only the index, so this is how
  -- it learns which index is which type: Gold's badge type boost
  -- (DoBadgeTypeBoosts, keyed by type; BattleSim2 `_typeIdOf`), and Red's
  -- side effects, which ask whether the target is POISON (PoisonEffect turns a
  -- Poison type away) and whether a FIRE move thaws it (CheckDefrost) --
  -- BattleSim `typeIndexOf`.  So it rides Gen 1 and Gen 2, never Gen 3 (whose
  -- sheets name their types).  Read through Wire.typeIds, the hub's own
  -- question, which answers with a copy (nothing downstream can write into
  -- `typeOrder`'s cache) or nil when one id cannot ride the wire: a registry
  -- id is any non-empty string, and a content mod's type ("mymod.FAIRY") fails
  -- the wire's id alphabet.  Then the list is left off rather than sent for a
  -- hub to drop, and the fight -- solo too, which reads this same ruleset, so
  -- both fight alike -- goes on without the rules that read a type by name.
  if order and #order.ids > 0 and Gen.generation(game) <= 2 then
    local ids = Wire.typeIds(order.ids)
    if ids then
      out.typeIds = ids
    else
      local bad = {}
      for _, id in ipairs(order.ids) do
        if not Wire.typeIds({ id }) then bad[#bad + 1] = ("%q"):format(id) end
      end
      mod.log:warn("type chart id %s cannot ride the wire, so this fight has "
        .. "no rule that names a type (Gold's badge type boost; Red's POISON "
        .. "and FIRE side-effect checks) -- the type chart is unchanged. Give "
        .. "the type a registry id made of letters, digits, _ and - (40 "
        .. "characters at most)",
        table.concat(bad, ", "))
    end
  end
  return out
end

local function intOr(value, fallback)
  local n = tonumber(value)
  if not n or n ~= n then return fallback end
  return floor(n)
end

local function clamp(value, low, high)
  return min(high, max(low, value))
end

-- What the sim needs to resolve one move, read off the player's own move
-- record.
--
-- `accuracy` is converted rather than copied: the engine keeps a percent and
-- Gen 1 compares an 8-bit value against a 0-255 roll, which is the whole
-- mechanism behind the 1-in-256 miss -- `floor(acc * 255 / 100)` is the
-- conversion the engine's own `Damage.accuracyRoll` does, so a mediated fight
-- misses exactly as often as the same fight played offline.
--
-- `effect` and `chance` ride on the wire as integers.  The engine names an
-- effect with a string id ("SLEEP_EFFECT"); `Effects.idOf` is the shared
-- numbering both runtimes agree on.  `chance` is the secondary effect's odds
-- in percent, which the referee turns back into the cart's byte.
--
-- **Read under the name each cart's record spells it.**  Red's records carry
-- no odds at all (pokered folds them into the effect; the Gen 1 referee owns
-- them), so Gen 1 reads `chance` -- a content mod's -- and nothing else.  Gold
-- stores the odds per move, the `move` macro's effect-chance byte
-- (pokegold data/moves/moves.asm), and the importer keeps it twice
-- (src/import/RomExtractorGen2.lua extractMoves): `effectChance`, the percent,
-- and `effectChanceRaw`, the byte.  The Gold engine fights on `effectChance`
-- (src/battle/gen2/Battle.lua), and so must this.  The sheet used to read
-- `def.chance` on both carts, a field no Gold record has, so every Gold move
-- went out at chance 0: no burn, freeze, paralysis, flinch, poison, stat drop
-- or confusion off a hit ever fired in a refereed Gold fight, and THIEF (100
-- on the cart) never stole -- the referee only runs `thief` when the chance
-- byte lands.  An explicit `chance` still wins on Gold, so a content mod that
-- states one is heard.
--
-- The percent, not the byte, because the wire carries a percent
-- (Wire.battleMove, 0..100) and `effectChance` is the field a content mod
-- patches (src/link/Fingerprint.lua GEN2_MOVE_FIELDS) -- `effectChanceRaw`
-- would go stale under one.  The round trip is exact for every value the cart
-- uses: RGBDS `percent` is `* $ff / 100` in integer arithmetic, the importer's
-- `percentOf` rounds that back to the nearest percent, and BattleSim2's
-- `sideChanceProc` takes `floor(pct * 255 / 100)` -- 10, 20, 30, 40, 50 and
-- 100 come back as 25, 51, 76, 102, 127 and 255, the bytes on the cart.
--
-- The defaults are what a client with no record for a move sends -- a modded
-- move whose definition did not survive, most likely.  40 power at full
-- accuracy on type 0 is a plain hit: weaker than assuming the best and far
-- better than refusing the move, which would refuse the monster and then the
-- whole party.
--
-- Engine Damage.lua HIGH_CRIT fallback for imported caches that predate the
-- move-record `highCrit` field. The hub has no move table, so the client has
-- to stamp the flag on the sheet.
local HIGH_CRIT_MOVES = {
  KARATE_CHOP = true, RAZOR_LEAF = true, CRABHAMMER = true, SLASH = true,
}

-- Gold's own high-crit list: pokegold (and pokecrystal) data/moves/
-- critical_hit_moves.asm, the `CriticalHitMoves` table BattleCommand_Critical's
-- `.CheckCritical` looks the move id up in for its two extra levels.  Gen 2
-- keys the rule on the move, not the effect, and an imported Gold record names
-- nothing that says "high crit" -- no `highCrit`, and no EFFECT_ALWAYS_CRIT,
-- which is not an effect either cart has (pokegold constants/
-- move_effect_constants.asm).  The sheet used to stamp Gen 2 high-crit off
-- that effect name alone, so no move in a refereed Gold fight ever rolled on
-- the high-crit rung.  It is the Gen 1 list plus RAZOR_WIND, AEROBLAST and
-- CROSS_CHOP.
local HIGH_CRIT_MOVES2 = {
  KARATE_CHOP = true, RAZOR_WIND = true, RAZOR_LEAF = true, CRABHAMMER = true,
  SLASH = true, AEROBLAST = true, CROSS_CHOP = true,
}

-- ------- PP Ups (contract K8 of docs/plans/gen12-referee-gaps-fix.md)
--
-- What one PP Up adds to a move's maximum, on both carts: a fifth of the base
-- PP, **capped at 7** -- pokered AddBonusPP (engine/items/item_effects.asm,
-- "1/5 of normal max PP (capped at 7) is added for each PP Up": `cp 8` /
-- `ld a, 7`) and pokegold / pokecrystal ComputeMaxPP (the same `cp $8` /
-- `ld a, $7`, whose comment says why: a 40-PP move would otherwise reach 64
-- with three PP Ups and overflow into the PP-Up bits, so it stops at 61).
-- `base + ups * floor(base / 5)` with no cap -- what this mod used to add --
-- is right for every base PP under 40 and three too many per PP Up from 40
-- up.  Exported for src/Coop.lua's heal and src/CoopBattle.lua's move pane,
-- so the rule lives in one place.
M.PP_UP_BONUS_MAX = 7
function M.ppUpBonus(base)
  base = tonumber(base)
  if not base or base ~= base or base <= 0 then return 0 end
  return min(floor(base / 5), M.PP_UP_BONUS_MAX)
end

-- A move's maximum PP with `ups` PP Ups (0..3), the cart's GetMaxPP: the
-- base, plus one capped bonus per PP Up.
function M.maxPpOf(base, ups)
  base = tonumber(base)
  if not base or base ~= base then return nil end
  base = max(0, floor(base))
  ups = clamp(intOr(ups, 0), 0, Wire.PP_UPS_MAX)
  return base + ups * M.ppUpBonus(base)
end

-- The PP Ups used on one move slot, 0..3 -- the top two bits of the cart's PP
-- byte (PP_UP_MASK), which both engines keep as `slot.ppUps` (src/pokemon/
-- Pokemon.lua, src/battle/gen2/Mon.lua).  Gold's engine also accepts a slot
-- that states only its raised `maxPp`, and recovers the count from it
-- (Mon.ppUpsOf: the excess over the base, in whole capped bonuses); read the
-- same way here so a Gold slot the engine never stamped still says how many
-- it has.  Gen 1 slots never state a `maxPp`, so the derivation is Gold's.
local function ppUpsOf(slot, def, generation)
  local ups = tonumber(slot.ppUps)
  if (ups == nil or ups ~= ups) and generation == 2 then
    local base = def and tonumber(def.pp)
    local stored = tonumber(slot.maxPp)
    ups = 0
    if base and stored and stored > base then
      local bonus = M.ppUpBonus(base)
      if bonus > 0 and (stored - base) % bonus == 0 then
        ups = (stored - base) / bonus
      end
    end
  end
  return clamp(intOr(ups, 0), 0, Wire.PP_UPS_MAX)
end
M.slotPpUps = ppUpsOf

-- Gold's move priority, as the cart's GetMovePriority answers it (pokecrystal
-- engine/battle/core.asm, identical in pokegold): VITAL_THROW is 0 by its move
-- id (`cp VITAL_THROW` / `ld a, 0`), every other move takes its effect's row
-- in MoveEffectPriorities (data/moves/effects_priorities.asm), and a move with
-- no row is BASE_PRIORITY (constants/battle_constants.asm, 1).  The raw byte,
-- unsigned, exactly as the Gen 2 referee numbers it (src/BattleSim2/Effects.lua
-- MOVE_PRIORITY / BASE_PRIORITY), so a sheet's number and the referee's table
-- agree for every vanilla move.  Keyed by effect here, where the referee has
-- to key by move id: the client holds the move record and its EFFECT_* name,
-- and that is what lets a content mod's own move with a priority effect move
-- in its bracket (known gap #11) -- the table on the referee could only ever
-- know vanilla ids.
local GOLD_EFFECT_PRIORITY = {
  EFFECT_PROTECT = 3,
  EFFECT_ENDURE = 3,
  EFFECT_PRIORITY_HIT = 2,
  EFFECT_FORCE_SWITCH = 0,
  EFFECT_COUNTER = 0,
  EFFECT_MIRROR_COAT = 0,
}
M.GOLD_EFFECT_PRIORITY = GOLD_EFFECT_PRIORITY
M.GOLD_BASE_PRIORITY = 1

-- One Gold move's priority byte.  A move record that states its own
-- `priority` wins (a content mod's move), clamped to the byte the wire carries
-- (Wire.PRIORITY2_MAX); otherwise the cart's rule above.
function M.goldPriority(id, def)
  local own = type(def) == "table" and tonumber(def.priority) or nil
  if own and own == own then return clamp(floor(own), 0, Wire.PRIORITY2_MAX) end
  if id == "VITAL_THROW" then return 0 end
  local effect = type(def) == "table" and def.effect or nil
  local row = effect ~= nil and GOLD_EFFECT_PRIORITY[effect] or nil
  if row ~= nil then return row end
  return M.GOLD_BASE_PRIORITY
end

moveOf = function(data, slot, order, generation)
  if type(slot) ~= "table" then return nil end
  local id = Wire.id(slot.id)
  if not id then return nil end

  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[slot.id] or nil
  -- A record, or nothing: Gold's moves table holds the scalars `generation`
  -- and `source` beside its records (see the Metronome pool walk), and every
  -- read below indexes `def`.
  if type(def) ~= "table" then def = nil end

  local accuracy = 255
  if def and tonumber(def.accuracy) then
    accuracy = clamp(floor(tonumber(def.accuracy) * 255 / 100), 0, 255)
  end

  local typeId = 0
  if order and def and order.index[def.type] then typeId = order.index[def.type] end

  local effect = 0
  local chance = 0
  if def then
    if def.effect then
      -- Gen 2 EFFECT_* names (Crystal moveEffectOrder) only resolve on
      -- BattleSim2; an unmapped name becomes effect 0 and a status move
      -- does nothing.
      local pack = Effects1
      if generation == 2 then
        if not Effects2 then Effects2 = need("BattleSim2/Effects") end
        pack = Effects2
      end
      effect = pack.idOf(def.effect) or 0
    end
    -- See the header: Gold's odds are `effectChance`, a `chance` a record
    -- states wins, and Gen 1 reads `chance` alone.
    local odds = def.chance
    if odds == nil and generation == 2 then odds = def.effectChance end
    chance = clamp(intOr(odds, 0), 0, 100)
  end

  local pp = clamp(intOr(slot.pp, 0), 0, 99)
  local ppUps = ppUpsOf(slot, def, generation)
  -- The slot's own maximum when it states one (Gold's engine keeps it);
  -- otherwise the cart's GetMaxPP over the record's base PP and this slot's PP
  -- Ups -- Red's engine slot is `{ id, pp, ppUps }` and states none.  Before
  -- K8 the fallback was the *current* PP, so a Red move that came into the
  -- fight already spent said its maximum was what it had left, and an ETHER
  -- or ELIXER (the referee's `ppRestore`, capped at `maxPp`) could restore
  -- nothing past it.  Never below the current PP -- except on Red, where a
  -- slot can hold more than its maximum: DecrementPP on a slot at 0 wraps the
  -- PP byte to 63 and borrows a PP Up (`M.ppByteStep1`), and the cart goes on
  -- showing GetMaxPP over the base and the PP Up bits beside it (pokered
  -- PrintMenuItem), so the upload states that, as the save's byte holds it.
  -- The record-less move keeps the old reading.
  local maxPp = intOr(slot.maxPp, nil)
  if maxPp == nil and def then maxPp = M.maxPpOf(def.pp, ppUps) end
  if generation == 1 and maxPp ~= nil then
    maxPp = clamp(maxPp, 0, 99)
  else
    maxPp = clamp(maxPp or pp, pp, 99)
  end
  local highCrit = false
  if def and def.highCrit ~= nil then
    -- The move-record field wins, including an explicit false that opts a
    -- vanilla high-crit id back to ordinary odds -- on either cart.
    highCrit = def.highCrit == true
  elseif generation == 2 then
    -- Gold's CriticalHitMoves by id (BattleSim2 reads `move.highCrit` the way
    -- Gen 1 does).  EFFECT_ALWAYS_CRIT is the Gold engine port's spelling
    -- (src/battle/gen2/Battle.lua hitOnce) and is still honoured for a record
    -- that names it; no imported record does.
    highCrit = HIGH_CRIT_MOVES2[id] == true
      or (def ~= nil and def.effect == "EFFECT_ALWAYS_CRIT")
  elseif HIGH_CRIT_MOVES[id] then
    highCrit = true
  end
  local out = {
    id       = id,
    -- What the referee narrates this move under (PROTOCOL 26).  `id` is a
    -- registry key -- DOUBLE_KICK -- and every sentence the sim writes used to
    -- print it, because it was the only spelling of the move on the wire.  The
    -- referee holds no move table to look a name up in, so the name travels
    -- with the move the way `species` does with the monster.  nil when this
    -- build has no record for the move: the sim then falls back to the id,
    -- which is the sentence a protocol-25 fight has always shown.
    name     = def and Wire.moveName(def.name) or nil,
    pp       = pp,
    maxPp    = maxPp,
    power    = clamp(intOr(def and def.power, 40), 0, 999),
    accuracy = accuracy,
    type     = typeId,
    effect   = effect,
    chance   = chance,
    -- Contract K8: the PP Ups used on this slot, which the cart's move pick
    -- reads in the raw PP byte (pokered `.chooseMove`: a move at 0 PP that
    -- has PP Ups is still selectable) -- every Red and Gold row.
    ppUps    = ppUps,
  }
  if highCrit then out.highCrit = true end
  -- ...and Gold's priority byte (K8; `M.goldPriority`), on every Gold row so
  -- the referee reads the sheet before its move-id table.  Red has no move
  -- priority, and Wire.battleMove neither copies nor refuses one on a Gen 1
  -- row, so none is stated there.
  if generation == 2 then out.priority = M.goldPriority(id, def) end
  return out
end

-- Battle stats for the wire sheet.
--
-- Gen 1: atk/def/spd/spc (engine attack/defense/speed/special). SPC is one
-- stat — Special did not split until Gen 2.
-- Gen 2: atk/def/spe/spa/spd from specialAttack/specialDefense (or spa/spd
-- aliases) with Speed as `spe`.
--
-- Clamped rather than refused, which is the opposite of what Wire does with the
-- same numbers and is right on this side of the boundary: Wire is judging a
-- stranger's claim and a number out of range there means the sender is not to
-- be believed, while here the number is our own truth and the only alternative
-- to trimming it is uploading a party the far end throws away whole -- a
-- player losing a fight they never got to start, over a stat nothing can fight
-- with anyway.
local function statsOf(mon, generation)
  local stats = type(mon.stats) == "table" and mon.stats or nil
  if not stats then return nil end
  if generation == 2 then
    local spa = stats.specialAttack or stats.spa or stats.special
    local spDef = stats.specialDefense or stats.spd or stats.special
    return {
      atk = clamp(intOr(stats.attack, 1), 1, Wire.STAT_MAX),
      def = clamp(intOr(stats.defense, 1), 1, Wire.STAT_MAX),
      spe = clamp(intOr(stats.speed, 1), 1, Wire.STAT_MAX),
      spa = clamp(intOr(spa, 1), 1, Wire.STAT_MAX),
      spd = clamp(intOr(spDef, 1), 1, Wire.STAT_MAX),
    }
  end
  return {
    atk = clamp(intOr(stats.attack, 1), 1, Wire.STAT_MAX),
    def = clamp(intOr(stats.defense, 1), 1, Wire.STAT_MAX),
    spd = clamp(intOr(stats.speed, 1), 1, Wire.STAT_MAX),
    spc = clamp(intOr(stats.special, 1), 1, Wire.STAT_MAX),
  }
end

-- A full set of the dialect's keys or nothing at all, on Wire's own rule: a
-- snapshot from a client that does not track DVs is ordinary, while one
-- carrying two of the required keys is a bug on this side that the far end
-- would silently zero the rest of.
--
-- Gen 2 DVs / Stat Exp still use one `special` word (engine gen2 Mon); both
-- spa and spd on the wire are fed from that single engine field.
local function sheetOf(raw, low, high, generation)
  if type(raw) ~= "table" then return nil end
  local out = {}
  if generation == 2 then
    local keys = {
      atk = "attack", def = "defense", spe = "speed",
      spa = "special", spd = "special",
    }
    for wireKey, engineKey in pairs(keys) do
      local n = tonumber(raw[engineKey])
      if wireKey == "spa" and (not n or n ~= n) then
        n = tonumber(raw.specialAttack)
      end
      if wireKey == "spd" and (not n or n ~= n) then
        n = tonumber(raw.specialDefense or raw.special)
      end
      if not n or n ~= n then return nil end
      out[wireKey] = clamp(floor(n), low, high)
    end
  else
    local keys = { atk = "attack", def = "defense", spd = "speed", spc = "special" }
    for wireKey, engineKey in pairs(keys) do
      local n = tonumber(raw[engineKey])
      if not n or n ~= n then return nil end
      out[wireKey] = clamp(floor(n), low, high)
    end
  end
  -- Optional HP Stat Exp for HP_UP (engine key `hp`).
  local hp = tonumber(raw.hp)
  if hp and hp == hp then
    out.hp = clamp(floor(hp), low, high)
  end
  return out
end

-- ------- contract K7 (docs/plans/gen12-referee-gaps-fix.md)
--
-- What the cart computes a monster's stats *from*, in the cart's own shape:
-- the species' base stats, the four DVs it stores, and its five stat-exp
-- words.  The referee needs them where it must compute a stat itself -- a
-- transformed computer foe's crit stat (pokered GetEnemyMonStat runs
-- CalcStat over the copied species with the foe's own DVs), the copied
-- species' base Speed for Red's crit rate, and the rebuild after a mid-fight
-- level-up (K9) -- and the hub holds no species table, so they ride the sheet
-- the way `baseSpd` always has.  `ivs` / `evs` above stay what they were (the
-- older blocks keyed like `stats`, which the vitamin store reads); these are
-- the same numbers in the shape the cart keeps them.
--
-- The wire keys are Wire's own (K7_KEYS1 / K7_KEYS2); each maps to the
-- engine's field of the same meaning.  Gold's base stats split Special
-- (`specialAttack` / `specialDefense` -- src/import/RomExtractorGen2.lua's
-- BaseData row) while its DVs and stat exp keep one Special word, exactly as
-- the party struct does (pokecrystal box_struct: four DVs in two bytes, five
-- stat-exp words ending at SpcExp), and the engine spells that word `special`
-- (src/battle/gen2/Mon.lua Mon.stats; an older record's `specialAttack` is
-- read as the fallback the engine reads it as).
local K7_ENGINE = {
  [1] = {
    base = { hp = { "hp" }, atk = { "attack" }, def = { "defense" },
             spd = { "speed" }, spc = { "special" } },
    dvs = { atk = { "attack" }, def = { "defense" }, spd = { "speed" },
            spc = { "special" } },
    statExp = { hp = { "hp" }, atk = { "attack" }, def = { "defense" },
                spd = { "speed" }, spc = { "special" } },
  },
  [2] = {
    base = { hp = { "hp" }, atk = { "attack" }, def = { "defense" },
             spe = { "speed" }, spa = { "specialAttack", "special" },
             spd = { "specialDefense", "special" } },
    dvs = { atk = { "attack" }, def = { "defense" }, spe = { "speed" },
            spc = { "special", "specialAttack", "specialDefense" } },
    statExp = { hp = { "hp" }, atk = { "attack" }, def = { "defense" },
                spe = { "speed" },
                spc = { "special", "specialAttack", "specialDefense" } },
  },
}
local K7_BOUNDS = {
  base = function() return Wire.BASE_STAT_MAX end,
  dvs = function() return Wire.DV_MAX end,
  statExp = function() return Wire.STAT_EXP_MAX end,
}

-- One K7 block off an engine table, or nil.  All of the dialect's keys or
-- none, on Wire's own rule (a present block with a hole refuses the monster
-- there, and with it the party): a monster this client does not track a
-- block for -- a Red trainer mon has no stat exp, a hand-built test mon has
-- no DVs -- states none, and the referee reads the absence as the cart's
-- computer does (GetEnemyMonStat's zero stat exp; plan §8).  Clamped rather
-- than refused, `statsOf`'s reasoning: here the number is our own truth.
local function k7Block(raw, block, generation)
  if type(raw) ~= "table" then return nil end
  local keys = (generation == 2 and Wire.K7_KEYS2 or Wire.K7_KEYS1)[block]
  local engine = K7_ENGINE[generation == 2 and 2 or 1][block]
  local high = K7_BOUNDS[block]()
  local out = {}
  for _, key in ipairs(keys) do
    local n
    for _, field in ipairs(engine[key] or {}) do
      n = tonumber(raw[field])
      if n and n == n then break end
      n = nil
    end
    if n == nil then return nil end
    out[key] = clamp(floor(n), 0, high)
  end
  return out
end

-- The three K7 blocks for one engine monster, onto `sheet`: `base` off its
-- species record, `dvs` and `statExp` off the monster.  Gen 1 / Gen 2 only.
function M.stampK7(sheet, def, mon, generation)
  if type(sheet) ~= "table" or type(mon) ~= "table" then return sheet end
  local base = type(def) == "table" and def.baseStats or nil
  sheet.base = k7Block(base, "base", generation)
  sheet.dvs = k7Block(mon.dvs, "dvs", generation)
  sheet.statExp = k7Block(mon.statExp, "statExp", generation)
  -- Contract K15 (wave 5): Gold's BASE_GENDER byte inside the `base` block --
  -- the next byte of the same base-stats row (pokecrystal data/pokemon/
  -- base_stats/*.asm `db GENDER_*`), which the engine imports as the species'
  -- `genderRatio` (src/import/RomExtractorGen2.lua: 0 GENDER_F0 male-only,
  -- 254 GENDER_F100 female-only, 255 GENDER_UNKNOWN).  ATTRACT's
  -- CheckOppositeGender runs GetGender over it with the Attack and Speed DVs
  -- (BattleSim2 Effects.gender), on every monster -- this player's own and
  -- every foe it describes -- since the hub holds no species table.  Only
  -- with a `base` block to ride in, and only when the record states one: a
  -- sheet with no ratio is read as genderless, and ATTRACT fails on it rather
  -- than inventing a gender.  Red has no genders, and its dialect none.
  if generation == 2 and sheet.base and type(def) == "table" then
    local ratio = tonumber(def.genderRatio)
    if ratio and ratio == ratio then
      sheet.base.gender = clamp(floor(ratio), 0, 255)
    end
  end
  return sheet
end

-- What this monster is called on the other player's screen.
--
-- The nickname when it has one, then the species record's display name, then
-- the raw id.  The display name is what the game itself prints, and it is the
-- one of the three that survives Wire.name intact for the species whose ids
-- carry punctuation the sanitiser drops.
local function speciesName(data, mon)
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  local name = mon.nickname
  if type(name) ~= "string" or name == "" then name = def and def.name end
  if type(name) ~= "string" or name == "" then name = mon.species end
  return Wire.name(name)
end

-- The types a species has, as indices into the uploaded chart.
--
-- Both sanitisers carry the field now -- `Wire.battleMon` and its JS twin keep a
-- present-and-readable `types` and refuse the battler outright when it is
-- present and unreadable, on the same rule a half-filled EV block gets -- so a
-- matchup and STAB apply to a mediated fight the way they do to a local one.
-- The indices are into *this match's* uploaded chart rather than into anything
-- shipped here, which is the whole reason they are numbers: the chart came from
-- the player's own decoded copy and is thrown away with the battle.  A monster
-- whose species this client cannot describe sends no types at all, and the sim
-- reads that absence as neutral rather than refusing the party.
local function typesOf(data, mon, order)
  if not order then return nil end
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  if not (def and type(def.types) == "table") then return nil end
  local out = {}
  for _, id in ipairs(def.types) do
    local index = order.index[id]
    if index then out[#out + 1] = index end
  end
  if #out == 0 then return nil end
  return out
end

-- ------- the referee-fidelity sheet fields (docs/plans/gen12-referee-fidelity.md)

-- Contract K1: is this monster somebody else's?  The obedience check's one fact
-- about a player's own monster, read the way both carts read it -- the 16-bit
-- OT id on the party struct against the save's own player id (pokered
-- engine/battle/core.asm and pokecrystal engine/battle/core.asm compare
-- MON_OTID with wPlayerID; the engines keep them as `mon.otId` and
-- `save.player.id`, Gen 1's BattleState.stampOT and Gold's Mon.stampOT).
--
-- `true` or nil, never `false`: the wire keeps `true` and drops `false`
-- anyway, and an absent field is the ordinary rules.  A monster with no OT id
-- on record is the player's own -- the Gold engine's own checkObedience
-- (src/battle/gen2/Battle.lua) answers the same, and so does contract K1 -- even
-- where Gen 1's engine counts a repaired `traded` flag for its exp boost
-- (SaveData.repairTradedOtIds): a cart's monster always has an OT id, and a
-- missing one is a port's record, not a trade this player made.  No player id
-- (a save that never stamped one) is nothing to compare against, and nil too.
function M.tradedOf(game, mon)
  local save = type(game) == "table" and game.save or nil
  local player = type(save) == "table" and save.player or nil
  local playerId = type(player) == "table" and tonumber(player.id) or nil
  local otId = type(mon) == "table" and tonumber(mon.otId) or nil
  if not (playerId and otId) or playerId ~= playerId or otId ~= otId then return nil end
  if floor(otId) % 65536 == floor(playerId) % 65536 then return nil end
  return true
end

-- The Gold item modules, resolved on first use and only by a Gen 2 caller: the
-- loader throws on a cross-generation require (modkit MK403), so nothing here
-- is reached at file scope or off a Gold boot -- `goldBadges`' posture, a
-- pcall'd require of a module the running engine owns.  A success is kept; a
-- failure is asked again next time rather than remembered as "no modules".
local goldItemMods = {}
local function goldItemModule(key, name)
  local hit = goldItemMods[key]
  if hit then return hit end
  local ok, module = pcall(require, name)
  if ok and type(module) == "table" then
    goldItemMods[key] = module
    return module
  end
  return nil
end

local warnedHoldEffect2 = false

-- Contract K2: everything the Gold referee reads off one held item, from this
-- client's own item data at sheet-build time -- the hub holds no item table,
-- and no value here is shipped by this mod.
--
--   heldItem    the engine's item id (Wire.id), the field Gold sheets always had
--   holdEffect  the item's HELD_* token, as the engine merged it
--               (src/core/gen2/ItemEffects.lua heldItemFor: the `held_items`
--               registry, a content mod's patch included, else the item row's
--               own columns -- data/items/attributes.asm's effect byte)
--   holdParam   the parameter byte beside it (0..255)
--   itemName    the name the cart prints (ItemNames, ITEM_NAME_LENGTH - 1)
--   mail        `true` for a mail item -- Thief cannot take one -- by the
--               engine's own test (src/core/gen2/Mail.lua isMail, pokecrystal
--               ItemIsMail over data/items/mail_items.asm)
--
-- A field the sanitiser would refuse is left off instead (Wire.battleMon refuses
-- the whole monster for a present-and-unreadable one): a content mod's hold
-- effect spelled outside the HELD_* alphabet rides as the bare id, said once in
-- the log, rather than costing the player the monster -- and then the party.
-- nil for no item.
function M.heldFields2(game, itemId)
  local id = Wire.id(itemId)
  if not id then return nil end
  local out = { heldItem = id }
  local data = type(game) == "table" and game.data or nil
  local ItemEffects = goldItemModule("ItemEffects", "src.core.gen2.ItemEffects")
  local row
  if ItemEffects and type(ItemEffects.heldItemFor) == "function" then
    local ok, got = pcall(ItemEffects.heldItemFor, itemId, data)
    if ok and type(got) == "table" then row = got end
  end
  if row and row.heldEffect ~= nil then
    local effect = Wire.holdEffect2(row.heldEffect)
    if effect then
      out.holdEffect = effect
      local param = tonumber(row.heldParameter)
      if param and param == param then
        out.holdParam = clamp(floor(param), 0, Wire.HOLD_PARAM2_MAX)
      end
    elseif not warnedHoldEffect2 then
      warnedHoldEffect2 = true
      mod.log:warn("the held item %s names a hold effect (%s) the battle referee "
        .. "cannot read, so it is fought as an item with no effect -- spell a "
        .. "modded hold effect HELD_ and capitals, digits or underscores",
        tostring(itemId), tostring(row.heldEffect))
    end
  end
  local items = type(data) == "table" and type(data.items) == "table" and data.items or nil
  local def = items and items[itemId]
  local name = Wire.text(type(def) == "table" and def.name or nil, Wire.ITEM_NAME2_MAX)
  if name then out.itemName = name end
  local Mail = goldItemModule("Mail", "src.core.gen2.Mail")
  if Mail and type(Mail.isMail) == "function" then
    local ok, isMail = pcall(Mail.isMail, itemId)
    if ok and isMail == true then out.mail = true end
  end
  return out
end

-- The K2 fields onto a sheet: `itemId`'s, or none of them for nil.  Every one
-- is cleared first, so a sheet never pairs one item's id with another's effect.
local ITEM_FIELDS2 = { "heldItem", "holdEffect", "holdParam", "itemName", "mail" }
function M.setSheetItem2(game, sheet, itemId)
  if type(sheet) ~= "table" then return nil end
  for _, key in ipairs(ITEM_FIELDS2) do sheet[key] = nil end
  local fields = itemId ~= nil and M.heldFields2(game, itemId) or nil
  for key, value in pairs(fields or {}) do sheet[key] = value end
  return fields
end

-- A Gold wild monster's held item, rolled the way the cart rolls it -- because
-- the engine does not (src/battle/gen2/Mon.lua: "wild mons roll one from
-- BaseData's two item slots on the cart, which is not modeled yet").
--
-- pokecrystal (and pokegold) engine/battle/core.asm LoadEnemyMon, `.WildItem`:
-- a BATTLETYPE_FORCEITEM encounter (Ho-Oh, Lugia, Snorlax) always holds item 1;
-- otherwise one BattleRandom against `75 percent + 1` -- below it, no item --
-- and a second against `8 percent`, below which item 2, else item 1.  `percent`
-- is `* $ff / 100` in integer arithmetic, so the thresholds are 192 and 20: an
-- item 64 times in 256, item 2 on 20 of those 256.  The two slots are the
-- species' own (`data.pokemon[id].items`, BaseData's item1 / item2, which the
-- importer reads off the player's ROM; either may be absent -- NO_ITEM).
--
-- `opts.random` is a function answering one byte (0..255): the caller's own
-- source, never the referee's stream.  Where that source is the generator the
-- fight's seed comes off too (SoloBattle's `_randomByte` and `_seed` both draw
-- love.math.random when no suite hands either in), the caller draws the seed
-- first (SoloBattle:_begin), so the roll never moves it: a fight's seed is the
-- same draw whether its wild monster has item slots or not.  A co-op fight's
-- seed is the hub's to deal (src/Hub.lua `battleSeed`, off its entropy pool;
-- server/hub.js), never a draw this roll stands in front of.  The cart spends
-- both draws even for a species with no items; a species with none spends
-- nothing here, since a byte from a source the referee does not read changes
-- nothing it fights with.
-- `opts.battleType` is the Gold battle's own (src/battle/gen2/Battle.lua
-- BATTLETYPE_FORCEITEM = 10).
--
-- Writes the item onto the engine monster -- the one a catch keeps -- and
-- answers it; a monster that already holds one (a scripted gift's) is left as
-- it is.  Gen 2 only, and nil anywhere else.
M.WILD_ITEM_NONE_BELOW2 = 192   -- 75 percent + 1
M.WILD_ITEM2_BELOW2 = 20        -- 8 percent
M.BATTLETYPE_FORCEITEM2 = 10
-- pokecrystal / pokegold constants/pokemon_data_constants.asm BASE_HAPPINESS:
-- what LoadEnemyMon `.Happiness` gives every wild and trainer monster
-- (`snapshotMons`, contract K14 on a foe's sheet).
M.BASE_HAPPINESS2 = 70
function M.rollWildItem2(game, mon, opts)
  if type(mon) ~= "table" then return nil end
  if Gen.generation(game) ~= 2 then return nil end
  if type(mon.item) == "string" and mon.item ~= "" then return mon.item end
  opts = type(opts) == "table" and opts or {}
  local data = type(game) == "table" and game.data or nil
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  local slots = type(def) == "table" and type(def.items) == "table" and def.items or {}
  local function slot(i)
    local id = slots[i]
    if type(id) ~= "string" or id == "" or id == "NO_ITEM" then return nil end
    return id
  end
  local item1, item2 = slot(1), slot(2)
  local item
  if tonumber(opts.battleType) == M.BATTLETYPE_FORCEITEM2 then
    item = item1
  elseif item1 or item2 then
    local random = opts.random
    if type(random) ~= "function" then return nil end
    local function byte()
      local ok, value = pcall(random)
      value = ok and tonumber(value) or nil
      if not value or value ~= value then return 0 end
      return floor(value) % 256
    end
    if byte() >= M.WILD_ITEM_NONE_BELOW2 then
      item = (byte() < M.WILD_ITEM2_BELOW2) and item2 or item1
    end
  end
  if item then mon.item = item end
  return item
end

-- Any team, as the intermediator will fight it.
--
-- Split out from `snapshotParty` because a co-op fight has more than one team
-- to describe from one client: src/CoopBattle.lua uploads its own party *and*,
-- when it is the host of a battle against an NPC, the trainer's -- and neither
-- of those two is `game.save.party`.  `game` is still handed in whole because
-- what a monster looks like on the wire is read off the player's own `data`
-- (the move records, the species names, the type ordering) whoever owns the
-- monster.
--
-- Best-effort throughout: a monster that cannot be described is skipped rather
-- than taking the party with it, because a party of five is a fight and a party
-- of none is not.  An empty result is the caller's to refuse -- see M:start.
--
-- `opts` on Gen 1 / Gen 2 (Gen 3 hands it to Sheet3.mons): `{ own = true }`
-- for this player's own monsters, which then carry contract K1's `traded`
-- unless `link` is set too -- a link battle runs no obedience check on either
-- cart, and a sheet built for one states none.  A foe's sheet (a wild monster,
-- a trainer's) is never `own`: the cart asks the question of the player's
-- battle monster alone.  `own` also picks a Gold sheet's happiness (K14): the
-- monster's own byte, or for a foe the cart's BASE_HAPPINESS.
function M.snapshotMons(game, party, opts)
  if type(party) ~= "table" then return {} end
  -- Gen 3: the C4 sheet.  Every sheet built here carries its species' catch
  -- rate (a wild seat reads it; Gen 1 / Gen 2 always sent one); the player's
  -- own party goes through snapshotParty, which does not.
  if Gen.generation(game) == 3 then
    return Sheet3.mons(game, party, opts or { wild = true })
  end

  local data = game and game.data
  local order = typeOrder(data)
  local generation = Gen.generation(game)
  local own = type(opts) == "table" and opts.own == true
  local stampTraded = own and opts.link ~= true

  local out = {}
  for index = 1, #party do
    if #out >= Config.BATTLE_MON_MAX then break end
    local mon = party[index]
    if type(mon) == "table" then
      local stats = statsOf(mon, generation)
      local species = speciesName(data, mon)
      if stats and species then
        local maxHp = clamp(intOr(mon.stats and mon.stats.hp, 1), 1, Wire.HP_MAX)
        local moves = {}
        for _, slot in ipairs(mon.moves or {}) do
          if #moves >= Config.BATTLE_MOVE_MAX then break end
          local move = moveOf(data, slot, order, generation)
          if move then moves[#moves + 1] = move end
        end
        if #moves > 0 then
          local sheet = {
            species = species,
            -- Registry id for battle art (local only; the wire keeps `species`
            -- as the display / nickname token the sim narrates under).
            speciesId = mon.species,
            level   = clamp(intOr(mon.level, 1), 1, Wire.LEVEL_MAX),
            hp      = clamp(intOr(mon.hp, maxHp), 0, maxHp),
            maxHp   = maxHp,
            stats   = stats,
            generation = generation,
            -- The engine spells a condition with the same three-letter token
            -- the wire does ("SLP", "PSN", ...), so this passes through rather
            -- than being translated.  nil is healthy and is a real answer.
            status  = Wire.battleStatus(mon.status) or nil,
            slot    = clamp(index - 1, 0, Wire.SLOT_MAX),
            ivs     = sheetOf(mon.dvs, 0, 15, generation),
            evs     = sheetOf(mon.statExp, 0, 65535, generation),
            types   = typesOf(data, mon, order),
            moves   = moves,
          }
          -- Gen 2 held item (engine field `item`), and with it what the Gold
          -- referee reads off it (contract K2: hold effect, parameter, name,
          -- mail) -- all of it absent when nothing is held.  Optional;
          -- Wire.id cleans the id.
          if generation == 2 and type(mon.item) == "string" and mon.item ~= "" then
            M.setSheetItem2(game, sheet, mon.item)
          end
          -- Contract K1, on this player's own monsters outside a link battle.
          if stampTraded then sheet.traded = M.tradedOf(game, mon) end
          out[#out + 1] = sheet
          local def = type(data) == "table" and type(data.pokemon) == "table"
            and data.pokemon[mon.species] or nil
          local rate = def and tonumber(def.catchRate)
          if rate then
            out[#out].catchRate = clamp(floor(rate), 0, 255)
          end
          -- Species base Speed for Gen 1 crit. Not battle Speed: paralysis and
          -- the Speed badge must not change the rate, and the hub has no
          -- species table to look this up in.
          if generation ~= 2 then
            local base = def and type(def.baseStats) == "table"
              and tonumber(def.baseStats.speed) or nil
            if base ~= nil and base == base then
              out[#out].baseSpd = clamp(floor(base), 0, 255)
            end
          end
          -- Contract K7, on every Red and Gold sheet this builds -- this
          -- player's own and every foe it describes (a wild monster, a
          -- trainer's), since a transformed foe's crit stat is computed from
          -- the foe's own DVs (M.stampK7).
          M.stampK7(sheet, def, mon, generation)
          -- Contract K14: Gold's happiness (MON_HAPPINESS, 0..255), which
          -- RETURN and FRUSTRATION read (pokecrystal BattleCommand_
          -- HappinessPower / FrustrationPower).  This player's own monster
          -- sends its own: the engine keeps it on the monster
          -- (src/battle/gen2/Mon.lua: 70 for a caught one, 120 for a gift or
          -- a hatchling), and one that states none sends none.  A foe this
          -- client describes -- a wild monster, a trainer's -- fights on the
          -- cart's constant whatever its engine record says: LoadEnemyMon
          -- `.Happiness` (pokecrystal engine/battle/core.asm, pokegold the
          -- same) writes BASE_HAPPINESS into wEnemyMonHappiness for every
          -- wild and trainer monster, and the computer's RETURN and
          -- FRUSTRATION read that byte.  A link opponent's sheet is its own
          -- client's `own` one, as InitEnemyMon copies the other cart's party
          -- struct.  Red has no happiness byte, and its dialect never carries
          -- one.
          if generation == 2 then
            if not own then
              sheet.happiness = M.BASE_HAPPINESS2
            else
              local happy = tonumber(mon.happiness)
              if happy and happy == happy then
                sheet.happiness = clamp(floor(happy), 0, 255)
              end
            end
          end
        end
      end
    end
  end
  return out
end

-- This player's own team.
--
-- `opts`: `{ link = true }` for a fight between two players (LINK_MODES).  On
-- Gen 3 that is where Deoxys fights on its link-battle stats; on every
-- generation it is the fight whose sheets state no `traded` (contract K1 of
-- docs/plans/gen12-referee-fidelity.md on Gen 1 / Gen 2, Sheet3's own on Gen 3),
-- because no cart runs its obedience check in a link battle.
function M.snapshotParty(game, opts)
  local link = type(opts) == "table" and opts.link == true
  -- Gen 3: the live session party, not game.save (a snapshot there).
  if Gen.generation(game) == 3 then
    return Sheet3.party(game, { link = link })
  end
  local save = game and game.save
  return M.snapshotMons(game, save and save.party, { own = true, link = link })
end

-- ------- what goes out before the fight opens, in one place
--
-- Two senders and one validator, shared with src/CoopBattle.lua rather than
-- copied into it.  The uploads are the only thing a client says that decides
-- what the fight *is* -- there is no move table and no chart on either
-- intermediator -- so a second copy of "how a party is put on the wire" is a
-- second place for a 1v1 and a 2-on-2 to start describing the same monster
-- differently.

-- The host's chart, and nobody else's.  Not because a guest's would be worse,
-- but because two charts is a fight with no answer to "which", and both
-- intermediators refuse a ruleset from anyone but the seat they brokered as
-- host.
function M.sendRuleset(transport, game, opts)
  if not transport then return false end
  transport:send(Wire.BATTLE_RULESET, M.snapshotRuleset(game, opts))
  return true
end

-- One seat's team.  `side` is optional for a 1v1 -- there are two combatants and
-- the intermediator knows which is which from the session it brokered -- and is
-- what tells an NPC upload apart: only the initiator fills the synthetic npc
-- seat (side "b") without displacing their own. 1v1 / 2v2 humans each send
-- their own party (and bag). `bag` is the optional inventory claim for this
-- fight (PROTOCOL 15); omit or pass nil for an empty sheet.
-- `badges` is optional: a list of earned badge ids for human seats (not NPC).
-- `seat` is optional too, and only an NPC upload's (`M.npcSeat`): the
-- trainer's `name` and Red move-choice layers (`aiMods`), which the hub hands
-- the computer seat it fills (Wire.battleParty, wave 6).
function M.sendParty(transport, battle, mons, side, bag, badges, seat)
  if not (transport and battle) then return false end
  if type(mons) ~= "table" or #mons == 0 then return false end
  local msg = { battle = battle, mons = mons, side = side, bag = bag }
  if badges then msg.badges = badges end
  if type(seat) == "table" then
    msg.name, msg.aiMods = seat.name, seat.aiMods
  end
  -- Party-level generation when every mon agrees (Wire prefers this, then shape).
  local gen = mons[1] and mons[1].generation
  if gen == 1 or gen == 2 or gen == 3 then
    local same = true
    for i = 2, #mons do
      if mons[i].generation ~= gen then same = false; break end
    end
    if same then msg.generation = gen end
  end
  transport:send(Wire.BATTLE_PARTY, msg)
  return true
end

-- What an NPC party says about the trainer rather than its monsters (wave 6
-- of docs/plans/gen12-referee-gaps-fix.md), for `sendParty`'s `seat`:
--
--   aiMods  Red only: pokered AIEnemyTrainerChooseMoves runs the class's
--           TrainerClassMoveChoiceModifications row (data/trainers/
--           move_choices.asm) -- the engine record's `aiMods`, the same list
--           src/SoloBrain.lua scores with (`trainer.aiMods`) -- and a coop_npc
--           computer seat the Red referee picks for runs exactly that list
--           (BattleSim Turn `_aiTrainerMoves`).  The wire takes the cart's four
--           AIMoveChoiceModification numbers and refuses the whole party over
--           anything else (Wire.battleParty), so a registered layer named by
--           id is sent as its number ("LAYER_2" is 2, the key the engine
--           resolves a number through: TrainerAI) and a layer no number names
--           -- a mod's own class record -- is one the referee cannot run and
--           is left out.  An empty row is a real answer (`.useOriginalMoveSet`).
--   name    Red and Gold: the trainer as the cart's lines name it (pokered
--           AIBattleUseItemText's wTrainerName, Gold's PlaceEnemysName) --
--           the record's own `name`, "YOUNGSTER JOEY" on Gold, the class name
--           on Red (`fallback`, the caller's display name, without one).  The
--           hub names the seat "TRAINER" when none rides.
--
-- nil on Gen 3 (its referee reads its own trainer) and with nothing to say.
function M.npcSeat(game, trainer, fallback)
  local generation = Gen.generation(game)
  if generation ~= 1 and generation ~= 2 then return nil end
  local out = {}
  local record = type(trainer) == "table" and trainer or nil
  local name = record and record.name
  if type(name) ~= "string" or name == "" then name = fallback end
  if type(name) == "string" and name ~= "" then out.name = name end
  local raw = record and record.aiMods
  if generation == 1 and type(raw) == "table" then
    local layers = {}
    for _, entry in ipairs(raw) do
      local n = tonumber(entry)
      if n == nil and type(entry) == "string" then n = tonumber(entry:match("^LAYER_(%d+)$")) end
      if n and n == floor(n) and n >= 1 and n <= (Wire.AI_MOD_MAX or 4)
         and #layers < (Wire.AI_MODS_MAX or 8) then
        layers[#layers + 1] = n
      end
    end
    out.aiMods = layers
  end
  if out.name == nil and out.aiMods == nil then return nil end
  return out
end

-- Wire-shaped moves for a save mon, the same `moveOf` the opening upload
-- used. A learn that wrote only `{ id, pp }` onto the save copy has to
-- travel with power / accuracy / effect or the referee treats it as a
-- 40-power type-0 hit.
--
-- **Stated with the boot's generation**, the way `snapshotMons` states it.
-- It used to call `moveOf` with none, so every resend after a mid-fight learn
-- was encoded through Gen 1's effect table and high-crit list -- on Gold that
-- turned a learned EFFECT_* status move into effect 0 (a move that does
-- nothing) for the rest of the fight.  Gen 3 rows come from Sheet3.
function M.sheetMoves(game, mon)
  local generation = Gen.generation(game)
  if generation == 3 then return Sheet3.moves(mon) end
  local data = game and game.data
  local order = typeOrder(data)
  local moves = {}
  for _, slot in ipairs((mon and mon.moves) or {}) do
    if #moves >= Config.BATTLE_MOVE_MAX then break end
    local move = moveOf(data, slot, order, generation)
    if move then moves[#moves + 1] = move end
  end
  return moves
end

-- What a mid-fight level-up tells the referee (contract K9 of docs/plans/
-- gen12-referee-gaps-fix.md): the save monster's new level, its new stats in
-- the sheet's own dialect -- `statsOf`, the same reading the opening upload
-- made -- and its new maximum HP.  The client is the only party that ran the
-- Exp award, so it is the only one that knows the monster grew; the referee
-- rebuilds its battle stats from these the way the cart does after a level-up
-- in battle (badge boosts re-run, current HP raised by the maximum's step:
-- pokered / pokecrystal GainExperience).  Gen 1 / Gen 2 only, and nil for a
-- monster this client cannot describe -- a K9 field the referee cannot read
-- would refuse the whole message, moves included.
function M.growthOf(game, mon)
  if type(mon) ~= "table" then return nil end
  local generation = Gen.generation(game)
  if generation ~= 1 and generation ~= 2 then return nil end
  local stats = statsOf(mon, generation)
  local maxHp = intOr(type(mon.stats) == "table" and mon.stats.hp or nil, nil)
  local level = intOr(mon.level, nil)
  if not (stats and maxHp and level) then return nil end
  return {
    level = clamp(level, 1, Wire.LEVEL_MAX),
    stats = stats,
    maxHp = clamp(maxHp, 1, Wire.HP_MAX),
  }
end

-- PROTOCOL 28: tell the referee this party member's moveset changed.
--
-- `generation` (optional) is the boot's, and is the dialect the pre-send check
-- reads the rows in (Wire.battleMoveset's `generation`, the one the hub reads
-- them in); nil asks the live boot.  Gen 1 / Gen 2 rows read the same either
-- way -- none carries the `num` that alone would pick Gen 3's reader.
--
-- `growth` (optional; `M.growthOf`) makes the same message a level-up (K9):
-- `level`, `stats` and `maxHp` ride beside the current move list, which may
-- be the referee's own unchanged (a level that taught nothing is as valid as
-- a learn).  Gen 1 / Gen 2 only -- Gen 3's reader reads none of them, and a
-- Gen 3 caller never passes one.
function M.sendMoveset(transport, battle, monIndex0, moves, generation, growth)
  if not (transport and battle) then return false end
  if type(moves) ~= "table" or #moves == 0 then return false end
  local msg = { battle = battle, mon = monIndex0, moves = moves }
  local gen = generation or Gen.generation(nil)
  if type(growth) == "table" and (gen == 1 or gen == 2) then
    msg.level, msg.stats, msg.maxHp = growth.level, growth.stats, growth.maxHp
  end
  if not Wire.battleMoveset(msg, gen) then return false end
  if transport:send(Wire.BATTLE_MOVESET, msg) == false then return false end
  return true
end

-- Gold's badges, as `M.badgesOf` sends them: each one the save holds, by the
-- engine's own ownership test (src/battle/gen2/Battle.lua Battle:hasBadge),
-- walked in the cart's bit order -- wJohtoBadges, then wKantoBadges.
local function goldBadges(save)
  if type(save) ~= "table" then return nil end
  local ok, Battle = pcall(require, "src.battle.gen2.Battle")
  if not (ok and type(Battle) == "table" and type(Battle.hasBadge) == "function") then
    return nil
  end
  -- Battle:hasBadge reads `self.save` and nothing else of the battle.
  local probe = { save = save }
  local out = {}
  for _, store in ipairs({
    { "badges", Battle.JOHTO_BADGE_ORDER },
    { "kantoBadges", Battle.KANTO_BADGE_ORDER },
  }) do
    for _, badge in ipairs(type(store[2]) == "table" and store[2] or {}) do
      local okHas, has = pcall(Battle.hasBadge, probe, store[1], badge)
      if okHas and has then out[#out + 1] = badge end
    end
  end
  if #out == 0 then return nil end
  return out
end

-- The badges this player has earned, as a list for the wire -- or nil where
-- they count for nothing.
--
-- `mode` is the fight's (`1v1`, `coop_pvp`, `wild`, `coop_npc`, ...).  A link
-- mode (M.LINK_MODES) sends none on every generation: no cart boosts in a
-- link battle (Gen 1 skips the badge step there, Gen 2's BadgeStatBoosts
-- returns early, Gen 3's Engine.hasBadge answers false -- battle/engine.lua:167)
-- and no cart runs its obedience check there either; the referees ignore a set
-- in those modes anyway (docs/plans/gen3-badge-rules.md §3 decision 3: the
-- referee owns the rule, this is the belt).  Any other mode, nil included --
-- the host-built co-op path asks without one -- is a fight against the
-- computer and sends what the save holds.
--
-- Gen 3 reads the cart's badge flags (Gen3.badgeList: the badge numbers
-- { "1", "3", ... }, contract K1), which BattleSim3 turns into the badge
-- boosts and the obedience caps.
--
-- Gen 2 sends every badge the save holds, the eight Johto then the eight
-- Kanto, by the Gold names (ZEPHYR .. RISING, BOULDER .. EARTH) BattleSim2's
-- boosts are keyed on.  Ownership is the Gold engine's own answer
-- (src/battle/gen2/Battle.lua Battle:hasBadge, the reading FieldMoves.hasBadge
-- also makes): `save.player.badges` for Johto and `save.player.kantoBadges`
-- for Kanto, each keyed by name or by wJohtoBadges / wKantoBadges bit
-- position.  Not the bag -- a Gold badge is never an item -- and not
-- `data.constants.badgeBoosts`, which holds Gen 1's rows: Gold's
-- BadgeStatBoosts never reads them.
--
-- Gen 1 reads the badge *rows* rather than a list written down here, so a mod
-- that adds a badge -- or retunes which ones boost what -- is covered without
-- this file knowing about it.  Behind them go the four badges pokered's
-- obedience check reads (contract K4 of docs/plans/gen12-referee-fidelity.md:
-- engine/battle/core.asm CheckForDisobedience tests EARTHBADGE, MARSHBADGE,
-- RAINBOWBADGE and CASCADEBADGE for the level cap), which no boost row names:
-- those are the cart's own bits, so they are a list here, held the way the save
-- holds every Gen 1 badge -- under its inventory key (src/inventory/Badges.lua
-- itemFor: the `constants.badges` record's `item`, else the badge id), or in
-- `player.badges` -- and sent by the same id the boost rows use.
--
-- MK403: never hard-require Gen 1 `src.battle.Damage` on Gold.  Gold asks a
-- soft-required Gen 2 Battle module and nothing else; Gen 1 prefers
-- `data.constants.badgeBoosts`, then Gen 1 Damage.  Missing rows soft-degrade
-- to no boost badges (the four obedience badges are still read).
M.OBEDIENCE_BADGES1 = { "CASCADEBADGE", "RAINBOWBADGE", "MARSHBADGE", "EARTHBADGE" }

-- The inventory key a Gen 1 badge is held under: its `constants.badges`
-- record's `item` when it names one, else the id (Badges.itemFor's reading,
-- restated so a Gold boot never requires a Gen 1 inventory module).
local function badgeKey1(data, id)
  local list = type(data) == "table" and type(data.constants) == "table"
    and data.constants.badges or nil
  for _, entry in ipairs(type(list) == "table" and list or {}) do
    if type(entry) == "table" and entry.id == id then
      return (type(entry.item) == "string" and entry.item ~= "") and entry.item or id
    end
  end
  return id
end

function M.badgesOf(game, mode)
  if M.LINK_MODES[mode] then return nil end
  local generation = Gen.generation(game)
  if generation == 3 then return Gen3.badgeList() end
  local data = game and game.data
  local save = game and game.save
  if not (data and save) then return nil end
  if generation == 2 then return goldBadges(save) end

  local rows = data.constants and data.constants.badgeBoosts
  if not rows then
    -- Concat so gen2check does not treat this as a hard Gen1 Damage site
    -- on a Gold boot (MK403); this arm only runs on Gen 1.
    local ok, Damage = pcall(require, table.concat({ "src", "battle", "Damage" }, "."))
    rows = ok and Damage and Damage.BADGE_BOOSTS or nil
  end

  local inventory = save.inventory or {}
  local playerBadges = save.player and save.player.badges
  local out, seen = {}, {}
  local function take(id, key)
    if not id or seen[id] then return end
    local has = inventory[key or id]
    if not has and type(playerBadges) == "table" then
      has = playerBadges[id]
    end
    if has then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  for _, row in ipairs(type(rows) == "table" and rows or {}) do take(row.badge) end
  for _, id in ipairs(M.OBEDIENCE_BADGES1) do take(id, badgeKey1(data, id)) end
  if #out == 0 then return nil end
  return out
end

-- Battle-usable stacks from the local save, for the hub bag proof.
-- Only ids BattleSim knows (`itemEffect`); vitamins included (fight-local EV).
-- Truncated to BATTLE_BAG_MAX so the menu and the upload stay the same set.
function M.itemIsBattleUsable(id, game)
  -- Gen 3 ids are numbers (pret ITEM_*), and the §4 catalog is the whole of
  -- what may be used: key items and TMs are simply not in it.
  if Gen.generation(game) == 3 then return Sheet3.itemEffect(id) end
  if type(id) ~= "string" or id == "" then return nil end
  local effect = effectsFor(game).itemEffect(id)
  if not effect then return nil end
  local items = (game and game.data and game.data.items) or {}
  local def = items[id]
  if effect.pokeFlute or effect.noConsume then return effect end
  if def and (def.key or def.machine) then return nil end
  return effect
end

-- Trainer kit as a `{id, count}` list for a side-"b" NPC upload. From the
-- initiator's game data (SoloBrain.bagEntries), filtered to BattleSim-known
-- ids so an unknown class item cannot refuse the whole party sheet.
function M.trainerBagEntries(trainer, game)
  if not trainer then return nil end
  -- Gen 3: the trainer row's own item list (numeric ids), §4 only.  Never
  -- SoloBrain's Gen 1 class kit, which would reach Gen 1's TrainerAI.
  if Gen.generation(game) == 3 then return Sheet3.trainerBag(trainer) end
  local ok, entries = pcall(SoloBrain.bagEntries, trainer,
    game and game.data, Gen.generation(game))
  if not (ok and type(entries) == "table") then return nil end
  local out = {}
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and M.itemIsBattleUsable(entry.id, game) then
      out[#out + 1] = entry
    end
  end
  return out
end

-- Engine save.statExp keys for BattleSim vitaminStat tokens.
-- Gen 1 wire: spd/spc. Gen 2 wire: spe/spa (BattleSim2). Engine gen2 Mon still
-- stores one Special Stat Exp word (`special`) that feeds both SpA and SpD.
local VITAMIN_SAVE_KEY = {
  hp = "hp", atk = "attack", def = "defense",
  spd = "speed", spc = "special",
  spe = "speed", spa = "special",
}

-- Live mon.stats field updated after a vitamin, by generation.
-- Gen 2 has no single `special` battle stat — write specialAttack (Calcium)
-- or the matching physical/speed field; SpD shares Special Stat Exp so both
-- specials are refreshed when spa is applied via Mon.stats when available.
local function vitaminLiveKeys(wireStat, generation)
  if wireStat == "hp" then return { "hp" } end
  if generation == 2 then
    if wireStat == "atk" then return { "attack" } end
    if wireStat == "def" then return { "defense" } end
    if wireStat == "spe" then return { "speed" } end
    -- spa (Calcium) / legacy spc: one Special Stat Exp word feeds both SpA/SpD.
    if wireStat == "spa" or wireStat == "spc" or wireStat == "spd" then
      return { "specialAttack", "specialDefense" }
    end
  end
  if wireStat == "atk" then return { "attack" } end
  if wireStat == "def" then return { "defense" } end
  if wireStat == "spd" or wireStat == "spe" then return { "speed" } end
  if wireStat == "spc" or wireStat == "spa" then return { "special" } end
  return nil
end

-- Write vitamin Stat Exp onto save.party[partyIndex] (1-based).
-- Fight-local sheet mutation is the hub's job; permanence is the client's.
-- Only call after an `item` event with amount=1 (vitamin applied).
function M.writebackVitamin(game, partyIndex, itemId)
  -- Gen 3 has no fight-local effort: a vitamin is not a battle item there
  -- (the §4 bag excludes them), so there is never anything to write back.
  if Gen.generation(game) == 3 then return false end
  -- Gen 2 resolves vitamins via BattleSim2/Effects only (spa/spe tokens);
  -- Gen 1 stays on BattleSim/Effects. Never try Gen1 Effects first on Gen2.
  local EffectsMod = Effects
  if Gen.generation(game) == 2 then
    local ok2, Effects2 = pcall(function() return need("BattleSim2/Effects") end)
    if ok2 and Effects2 and Effects2.itemEffect then
      EffectsMod = Effects2
    else
      return false
    end
  end
  local effect = EffectsMod.itemEffect(itemId)
  local wireStat = effect and effect.vitaminStat
  local saveKey = wireStat and VITAMIN_SAVE_KEY[wireStat]
  if not saveKey then return false end
  local party = game and game.save and game.save.party
  local mon = party and party[partyIndex]
  if type(mon) ~= "table" then return false end
  mon.statExp = mon.statExp or {}
  local before = math.max(0, math.floor(tonumber(mon.statExp[saveKey]) or 0))
  if before >= EffectsMod.VITAMIN_FAIL_AT then return false end
  local after = math.min(65535, before + EffectsMod.VITAMIN_GAIN)
  mon.statExp[saveKey] = after

  local generation = Gen.generation(game)
  -- Recalc live battle stats / max HP so the party screen does not lag.
  local oldMax = tonumber(mon.stats and mon.stats.hp) or tonumber(mon.hp) or 0
  local level = math.max(1, math.floor(tonumber(mon.level) or 1))
  local applied = false
  local def = game.data and game.data.pokemon and game.data.pokemon[mon.species]
  if generation == 2 then
    local okMon, Mon2 = pcall(require, "src.battle.gen2.Mon")
    if okMon and Mon2 and type(Mon2.stats) == "function"
       and type(def) == "table" and type(def.baseStats) == "table" then
      local ok, stats = pcall(Mon2.stats, def.baseStats, mon.dvs or {}, level,
        mon.statExp)
      if ok and type(stats) == "table" then
        mon.stats = stats
        local newMax = tonumber(stats.hp) or oldMax
        local cur = tonumber(mon.hp) or oldMax
        if wireStat == "hp" and newMax > oldMax then
          mon.hp = math.min(newMax, cur + (newMax - oldMax))
        else
          mon.hp = math.max(0, math.min(cur, newMax))
        end
        applied = true
      end
    end
  else
    local okStats, Stats = pcall(require, "src.pokemon.Stats")
    if okStats and Stats and type(Stats.calc) == "function"
       and type(def) == "table" and type(def.baseStats) == "table" then
      local ok, stats = pcall(Stats.calc, def, level, mon.dvs or {}, mon.statExp)
      if ok and type(stats) == "table" then
        mon.stats = stats
        local newMax = tonumber(stats.hp) or oldMax
        local cur = tonumber(mon.hp) or oldMax
        if wireStat == "hp" and newMax > oldMax then
          mon.hp = math.min(newMax, cur + (newMax - oldMax))
        else
          mon.hp = math.max(0, math.min(cur, newMax))
        end
        applied = true
      end
    end
  end
  if not applied then
    local function contrib(ev)
      return math.floor(math.sqrt(math.max(0, ev)) / 4)
    end
    local delta = math.floor((contrib(after) - contrib(before)) * level / 100)
    mon.stats = mon.stats or {}
    if wireStat == "hp" then
      local newMax = math.max(1, oldMax + delta)
      mon.stats.hp = newMax
      local cur = tonumber(mon.hp) or oldMax
      mon.hp = math.min(newMax, cur + math.max(0, delta))
    else
      local liveKeys = vitaminLiveKeys(wireStat, generation) or { saveKey }
      for _, liveKey in ipairs(liveKeys) do
        local curStat = math.max(1, math.floor(tonumber(mon.stats[liveKey]) or 1))
        mon.stats[liveKey] = math.max(1, curStat + delta)
      end
      local cur = tonumber(mon.hp) or oldMax
      local maxHp = tonumber(mon.stats.hp) or oldMax
      if maxHp > 0 then mon.hp = math.max(0, math.min(cur, maxHp)) end
    end
  end
  return true
end

-- Resolve which save.party index a co-op seat mon is.
-- `seatPartyIndex` (optional) names seat.party[i] after an ITEM party pick;
-- default is the seat's active. Prefers identity match against save.party,
-- then the seat index as a last resort.
function M.vitaminPartyIndex(game, seat, seatPartyIndex)
  if type(seat) ~= "table" then return 1 end
  local idx = seatPartyIndex or seat.active or 1
  local fieldMon = seat.party and seat.party[idx]
  if not fieldMon and seat.battler then fieldMon = seat.battler.mon end
  local saveParty = game and game.save and game.save.party
  if fieldMon and type(saveParty) == "table" then
    for i, mon in ipairs(saveParty) do
      if mon == fieldMon then return i end
    end
  end
  if type(idx) == "number" and idx >= 1 then return idx end
  return 1
end

function M.bagCounts(list)
  local map = {}
  for _, entry in ipairs(list or {}) do
    -- Gen 3 bag ids are numbers; Gen 1 / Gen 2 ids are strings.
    if type(entry) == "table"
       and (type(entry.id) == "string" or type(entry.id) == "number")
       and type(entry.count) == "number" and entry.count > 0 then
      map[entry.id] = entry.count
    end
  end
  return map
end

function M.snapshotBag(game)
  -- Gen 3: the session's pockets, §4 ids, with display names for the
  -- referee's "X used POTION!".
  if Gen.generation(game) == 3 then return Sheet3.bag(game) end
  local out = {}
  local inventory = (game and game.save and game.save.inventory) or {}
  for id, count in pairs(inventory) do
    if (count or 0) > 0 and M.itemIsBattleUsable(id, game) then
      local n = count
      if n > Config.BATTLE_BAG_COUNT_MAX then n = Config.BATTLE_BAG_COUNT_MAX end
      out[#out + 1] = { id = id, count = n }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  while #out > Config.BATTLE_BAG_MAX do
    out[#out] = nil
  end
  return out
end

-- One turn's intent.  A choice and never a result: the fields name what was
-- pressed, and what it costs is the intermediator's to decide.
--
-- Checked before it goes rather than after it is refused: both hubs answer a
-- malformed choice with silence, and silence at a battle screen is a turn the
-- player believes they spent.  Checked in the generation the hub will read it
-- in (`generation`, else the live boot's): only Gen 3 reads a choice's
-- `pass` / `dexCaught`, so only a Gen 3 check can catch a malformed one before
-- the hub drops it.  A Gen 1 / Gen 2 choice reads exactly as it did.
function M.submitChoice(transport, battle, fields, generation)
  if not (transport and battle) then return false end
  if transport.isReady and not transport:isReady() then return false end
  local out = { battle = battle }
  for key, value in pairs(fields or {}) do out[key] = value end
  if not Wire.battleChoice(out, generation or Gen.generation(nil)) then
    mod.log:warn("a battle choice would not have been understood and was not "
      .. "sent; press again, or wait for the turn clock")
    return false
  end
  -- `false` is a real refusal (already answered, a switch that names
  -- nobody). The hub send returns true/nil; only an explicit false must
  -- keep the menu open. A no-target FIGHT is a skip at the referee now,
  -- not a failed send.
  if transport:send(Wire.BATTLE_CHOICE, out) == false then return false end
  return true
end

-- Is `id` in this list of player ids?
--
-- Exported because an outcome is read by asking it twice, and both screens ask:
-- a 1v1 asks about the peer (the side they are not on is ours) and a 2-on-2
-- asks about itself (there are four ids and no single "other side").
function M.holds(list, id)
  if id == nil then return false end
  for _, entry in ipairs(list or {}) do
    if entry == id then return true end
  end
  return false
end

-- ------- the fight

-- How long a freshly shown line is safe from the button that dismisses it, and
-- how long it stays up when nobody presses anything.  CoopBattle's numbers and
-- CoopBattle's argument: a player holding A through a battle -- which is every
-- player -- otherwise swallows lines they never saw.
local MSG_MIN_DWELL = 0.25
local MSG_AUTO_ADVANCE = 1.6

-- ------- display clock (Battlefield arena only)
--
-- Two clocks, the engine's own: `slot.hp` is the referee's number and lands
-- the instant an event says so, and `slot.shownHp` is the number the arena
-- plates are drawn from.  The gap between the two *is* the animation, and it
-- is closed only by a queued row -- so nothing on screen can jump ahead of
-- the line that explains it.
--
-- None of this exists on the classic 160x144 path or on Gen2: those HUDs read
-- `slot.hp` straight and have no renderer for an effect, so a display clock
-- there would animate nothing and only cost the queue rows.  Every emitter
-- below is gated on `usesBattlefield()`.

-- Effect lifetimes in seconds.  `lunge` is held to the battlefield anim dwell
-- in tickMessages (0.35) so an attacker's lean is never cut off half way.
local FX_SPAN = {
  lunge = 0.35,
  flash = 0.30,
  shake = 0.25,
  faint = 0.60,
  spawn = 0.40,
  -- The ball flow. One constant per kind, and each one is also the dwell the
  -- queued row that emits it is held for -- the row *is* the effect, so a
  -- throw that outlives its row would be cut off by the next line and a row
  -- that outlives its throw would stall the fight on a finished animation.
  recall = 0.35, -- HIDEPIC: the monster shrinks into the ball
  ball   = 0.60, -- TOSS / GREATTOSS / ULTRATOSS: the arc
  wobble = 0.70, -- SHAKE: one rock, one per shake the referee counted
  poof   = 0.45, -- POOF / SHOWPIC: the burst, and what comes out of it
  -- Particles (src/Vfx.lua). One span for every look, because a span here is a
  -- pacing decision and the catalogue is a *visual* one -- the two must not be
  -- able to drift, or adding a prettier Fire effect would silently lengthen
  -- every Fire attack. A spec that genuinely needs longer says so on the
  -- record (`duration`), which is how Explosion and a Poke Flute get their
  -- extra fifth of a second without moving anything else.
  --
  -- 0.50 rather than the lunge's 0.35 on purpose: the effect is emitted on the
  -- lunge beat and is meant to still be running when the hit beat lands behind
  -- it, so a fired move is in the air while the attacker leans and bursts as
  -- the defender flashes. It outliving its beat costs nothing -- `stepFx` runs
  -- on its own clock and retires it wherever the queue has got to.
  vfx    = 0.50,
  -- Dig / Fly vanish. Held at t == 1 (VANISH_HIDE_FX) until release or clear.
  dig    = 0.45,
  fly    = 0.45,
  emerge = 0.35,
  -- Mid-battle evolution movie. Real lifetime is EvolveFx.MOVIE_SECONDS;
  -- this default is only what emitFx needs to accept the kind.
  evolve = 6.14,
}

-- The per-attack chronology's two deliberate gaps. One attack is four beats on
-- the arena, in this order and never two of them in the same tick:
--
--   1. the trainer's callout bubble, alone          (BEAT_SPAN.callout)
--   2. the attacker's lunge                         (FX_SPAN.lunge)
--   3. the defender's flash and the field's nudge   (BEAT_SPAN.hit)
--   4. the bar falling                              (the drain, DRAIN_BUDGET)
--
-- Beats 2 and 4 are effects and a descent with lifetimes of their own; 1 and 3
-- are *holds* the queue takes with nothing else running, so they are their own
-- table rather than more `FX_SPAN` entries -- no `emitFx` call ever names
-- either. Shared verbatim with CoopBattle's twin, which plays the same
-- chronology over its own queue: the two screens must not drift on the timing
-- a player reads as the game's rhythm.
local BEAT_SPAN = {
  -- 1 -> 2. The shout is a moment of its own: the bubble goes up over the
  -- trainer, and only then does the monster lean in. Comfortably inside the
  -- bubble's own life (BUBBLE_LIFE, 90 frames) with the lunge's 0.35s on top
  -- -- 33 + 21 of 90 -- so the shout is still on screen for the whole of the
  -- lunge it introduces, which is the point of saying it first, and it is
  -- never re-noted for the second beat (that would restart its fade).
  callout = 0.55,
  -- 3 -> 4. The strike reads before the bar answers it: the defender flashes
  -- and the field takes its nudge with the bar held exactly where it was, and
  -- only once that has been seen does the drain start. Exactly the flash it
  -- opens (FX_SPAN.flash, and `stepFx` keeps running through the hold), so the
  -- white is on the defender for the whole beat and gone as the bar begins to
  -- move -- the two are one hit, not two.
  hit = 0.30,
}

-- The engine's ball markers, and what each one is on the arena. Ball ids vary
-- with the ball (`_emitBallChain` in BattleSim/Turn.lua picks the toss by item),
-- so the toss is listed three times rather than pattern-matched.
local BALL_FX = {
  TOSS_ANIM      = "ball",
  GREATTOSS_ANIM = "ball",
  ULTRATOSS_ANIM = "ball",
  HIDEPIC_ANIM   = "recall",
  SHAKE_ANIM     = "wobble",
  POOF_ANIM      = "poof",
  SHOWPIC_ANIM   = "poof",
}

-- The kinds that mean "this seat is inside the ball". Held at t == 1 the way a
-- faint sink is (see stepFx): the queue leaves a frame or two between one row
-- ending and the next starting, and a monster that flickered back into view in
-- that gap would be out of the ball and in it again twice a throw.
--
-- `ball` is deliberately not one of them. The arc is a ball still in the air,
-- and the monster is standing on the seat it is flying at -- HIDEPIC is the row
-- that puts it inside, and it arrives *after* the toss (`_emitBallChain`:
-- TOSS, POOF, HIDEPIC, SHAKE...). Hiding on the throw put the monster in the
-- ball before the ball reached it, and Battlefield's own renderer already
-- refuses to hide for a `ball` effect for exactly that reason -- so listing it
-- here only kept a finished arc alive at t == 1 and dropped it again on a
-- side-wide clear that has nothing to do with it.
local BALL_HIDE_FX = { recall = true, wobble = true }

-- Charge/vanish setup. `anim.amount == 1` is the first turn (BattleSim).
local VANISH_MOVES = { DIG = true, FLY = true }
local CHARGE_SETUP_MOVES = {
  DIG = true, FLY = true,
  SOLARBEAM = true, SKULL_BASH = true, RAZOR_WIND = true, SKY_ATTACK = true,
}
local VANISH_HIDE_FX = { dig = true, fly = true }

local function vanishKey(side, seatIndex)
  return tostring(side or "") .. ":" .. tostring(seatIndex or 1)
end

-- The fields a `vfx` record carries beyond the shared kind / side / seatIndex
-- / t. Written out longhand rather than copied by pairs() so the wire this
-- screen publishes to Battlefield stays a closed set: a field invented here
-- and never read there is a look that silently does nothing, and a field that
-- shadowed `kind` or `elapsed` would be an effect that never retires.
local VFX_KEYS = {
  "style", "palette", "delivery", "scale", "intensity", "seed",
  "fromSide", "fromSeat",
}

-- A Gen 3 ability visibly acting: a short shine on the seat that owns it, the
-- same look the evolution movie's shine uses (a style Battlefield draws).
local ABILITY_VFX = { style = "shine", palette = "NORMAL", delivery = "burst" }

-- Most wobbles one SHAKE row is allowed to spend. Gen 1 counts three; the
-- number came off the wire, and a hub claiming a thousand would otherwise
-- queue a thousand rows the player cannot skip past.
local BALL_SHAKE_MAX = 8

-- The bar's *rate*, not its duration: `max(1, maxHp / 96)` a frame is what the
-- engine uses (BattleState's HP drain) and what CoopBattle's twin uses, so a
-- big monster empties over about a second and a half and a small one -- whose
-- 96th of a bar is under a point -- falls at the engine's one-HP-a-frame floor
-- instead of crawling.  The budget is the second half of that: a step that
-- loses its last fraction to floating point would never land on `to` exactly,
-- and a drain is deliberately unskippable -- so one that overruns a whole
-- descent is snapped home rather than left holding the queue forever.
local DRAIN_FRAMES = 96
local DRAIN_BUDGET = 120

-- The exp strip's rate, and CoopBattle's numbers verbatim: a whole bar in
-- about 1.2 seconds, counted in 60Hz frames like the drain above. Linear
-- rather than the cart's accelerating three-frames-a-pixel crawl
-- (AnimateExpBar) because the strip here is a fraction rather than 64 discrete
-- pixels -- there are no pixel steps to lengthen, and a constant rate reads as
-- the same deliberate crawl. The two screens must not drift on a rhythm the
-- player reads as the game's.
local EXP_FILL_FRAMES = 72
local EXP_FILL_STEP = 1 / EXP_FILL_FRAMES

-- How many 60Hz frames one update covers.  In game this is always 1 (the
-- engine's step is fixed at 1/60); the headless suite drives whole seconds at
-- a time and has to land on the far end of a drain rather than wedge on it.
local function frameCount(dt)
  local n = floor((tonumber(dt) or 0) * 60 + 0.5)
  if n < 1 then return 1 end
  if n > DRAIN_BUDGET then return DRAIN_BUDGET end
  return n
end

-- Side a takes field slots 0..COOP_SIDE-1 and side b takes COOP_SIDE.. .
-- Mirrored from src/BattleSim/events.lua's SIDE_SLOTS rather than derived,
-- because it is the numbering every event on the wire is already stated in:
-- a 1v1 leaves the partner seats empty so that "which box is this" does not
-- change meaning with the mode (foe is slot COOP_SIDE, not 1).
local function slotOfSide(side)
  return side == "b" and Config.COOP_SIDE or 0
end

-- ...and back the other way. Side a holds 0..COOP_SIDE-1, side b holds
-- COOP_SIDE upward, so the read is a threshold rather than an equality -- a
-- co-op seat past the lead of its side is no less that side's for it. A slot
-- this build cannot read as a number is nobody's, and answers "a" so that the
-- one caller (the exp credit below) treats it as *not* a foe -- the
-- conservative half.
local function sideOfSlot(index)
  local n = tonumber(index)
  if not n then return "a" end
  return (math.floor(n) >= Config.COOP_SIDE) and "b" or "a"
end

-- How many `exp` events one observed foe knockout may pay for.
--
-- **Six, because vanilla participation is a whole party wide.** The referee
-- pays every monster of yours that was ever in against the fallen foe and is
-- still alive (round 6; `src/BattleSim/Turn.lua` and its Node twin), one `exp`
-- event each, and the own-slot gate lets *all* of yours through -- they differ
-- by the new `mon` field, not by `slot`. A player who cycled all six of their
-- team through one long foe is owed six awards for that single knockout, so
-- the old bound of two would have silently eaten four of them.
--
-- Still a bound, and still the same one in spirit: a party is six monsters and
-- cannot be paid seven times for one faint. The guard that spends this exists
-- to cap a hostile hub streaming awards nobody refereed, never to argue with a
-- well-behaved one. Declared up here rather than beside `gainExp` because
-- `onEvent` is the one that banks it, and a local is only in scope after its
-- own line.
local EXP_PER_FAINT = 6

-- The party this client's save keeps -- the one exp, a level's moves, a held
-- item's writeback and a catch are written into.  Gen 3's is the live
-- session party (game.save there is a snapshot rebuilt at save time).
local function savePartyOf(game)
  if Gen3.active() then
    local party = Gen3.party()
    if type(party) == "table" then return party end
    local session = type(game) == "table" and game.session or nil
    return type(session) == "table" and session.party or nil
  end
  return game and game.save and game.save.party
end
M.savePartyOf = savePartyOf

-- The Gen 3 message box pages wider than the Game Boy's 18 columns: the
-- referee writes sentences up to 60 characters (C5 §7) and the GBA box / the
-- arena band carry two lines of about thirty.
local GEN3_BOX_COLS = 30

local function pageText(text)
  if Gen3.active() then return ClassicBattle.pageBoxText(text, GEN3_BOX_COLS) end
  return ClassicBattle.pageBoxText(text)
end

-- The command grid, row-major.  Gen 3 lays it out the cart's way: FIGHT BAG
-- over POKeMON RUN (pokefirered battle_controller_player.c's action menu).
local COMMANDS3 = { "FIGHT", "ITEM", "SWITCH", "RUN" }
local COMMAND_LABEL3 = { FIGHT = "FIGHT", ITEM = "BAG", SWITCH = "POKéMON", RUN = "RUN" }

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    transport = opts.transport,
    ui        = opts.ui,
    game      = opts.game,
    battle    = opts.battle,
    role      = opts.role,
    peerId    = opts.peerId,
    peerName  = opts.peerName or "FRIEND",
    onDone    = opts.onDone,

    -- The NPC the other seat is fighting as, on a `coop_npc` fight -- the
    -- engine's own `data.trainers` record, handed straight through by
    -- src/SoloBattle.lua. Read for exactly one thing: the overworld walk sheet
    -- the arena stands on the foe edge (`battlefieldCtx`). Nil on every other
    -- shape, including a peer fight, where the figure on that edge is a
    -- player and comes from the roster instead.
    trainer   = opts.trainer,
    -- Trainer sheets for a solo 1xNPC upload (side "b"), same claim the
    -- co-op host sends. Nil on wild (wildParty) and on every peer fight.
    npcParty  = opts.npcParty,

    -- A test hook, and named as one.  With it set, a turn is answered the
    -- instant it opens with the first move at the default target, which is
    -- what lets the headless suite drive a whole fight with no input device.
    -- It is never set in the game: the intermediator already auto-picks for a
    -- player who says nothing before BATTLE_CHOICE_TIMEOUT, so a client that
    -- silently picked as well would be spending turns the player is still
    -- thinking about.
    autoPick  = opts.autoPick == true,

    -- Protocol-only wild: mode "wild", optional wildParty sheets + engine mon
    -- kept for Party.add / Boxes.deposit on a catch outcome.
    mode         = opts.mode or "1v1",
    wildParty    = opts.wildParty,
    wildCatchMon = opts.wildCatchMon,

    -- What src/Sessions.lua's isFightState looks for.  A mediated battle is
    -- not a BattleState and carries none of the engine's markers, so without
    -- this an invite could pop over a live fight.
    mmoBattle = true,

    -- Same contract as engine BattleState / CoopBattle: without isOpaque the
    -- stack keeps drawing the overworld underneath and beginFrame clears the
    -- UI canvas transparent. Letterbox voids stay the engine default (black)
    -- -- letterboxWhite would paint SGB paper pink against this screen's
    -- colors=false white fill.
    isOpaque = true,

    phase     = "setup",   -- setup | play | choose | move | target | item | item_party | item_move | switch | over
    uploaded  = false,
    finished  = false,
    left      = false,
    mine      = nil,       -- our own snapshot, which the move menu reads
    active    = 1,         -- which of ours is out, as an index into `mine`
    mySide    = (opts.role == "guest") and "b" or "a",
    slots     = {},        -- field slot -> { species, hp, maxHp }
    -- field slot -> the referee's roster string for that seat ("oosx"), from
    -- the `team` event. The ONLY thing this screen is ever told about a
    -- monster that is not on the field, and the only source there is for the
    -- seat opposite: nobody uploads a party to anybody but the referee. Read
    -- by `battlefieldCtx` and by nothing else -- it is a chip and never a rule.
    teams     = {},
    lines     = {},
    shown     = nil,
    dwell     = 0,
    cursor    = 1,
    -- The move each of ours was last sent into a turn with, keyed by its index
    -- into `mine`. Purely where the cursor opens (see `rememberedMove`): a
    -- Gen 1 fight is mostly one attack repeated, and re-walking the list to it
    -- every turn is the tax this removes. Per monster, not per battle -- the
    -- fourth row of the mon you switched to is a different move.
    moveMemory = {},
    commandIndex = 1,
    itemIndex = 1,
    switchIndex = 1,
    itemPick = nil,        -- { id, effect } while picking party/move
    itemList = nil,
    bagSheet = nil,        -- id → count matching the uploaded PROTOCOL 15 bag
    pendingItem = nil,     -- choice sent; debit only after hub `item` event
    -- 1-based index into `mine` (the uploaded sheets), which is what the wire
    -- is stated in. `savePartyIndex` is what turns it into a save.party slot.
    pendingItemSlot = nil,
    -- Awards this client may still honour, banked by the foe knockouts it has
    -- actually seen narrated. See EXP_PER_FAINT and the `exp` event branch.
    expCredit = 0,
    -- EXP.ALL's *second* pass, which belongs to the knockout rather than to
    -- the award. Three-valued, like CoopBattle's: nil / true (armed by a foe
    -- faint) / false (spent by the award after it). Deliberately left nil
    -- rather than false here: nil means "no faint has ever been armed on this
    -- screen", which is the direct-call path (`gainExp` driven straight from a
    -- harness) and runs the pass the way it always did. See `gainExp`'s
    -- EXP.ALL block for the whole argument.
    expAllCredit = nil,
    seq       = 0,         -- the highest event sequence applied
    gaps      = 0,         -- events that arrived out of order
    pendingTurn = false,
    answeredTurn = false, -- own seat already answered (forced skip or filed choice)
    mustReplace = false,  -- faint with bench: next turn opens the switch picker
    replaceOnly = false,  -- B cannot cancel out of a forced replacement
    -- The field slot the referee is asking for a send-out, while it is asking.
    -- Set by a `turn` that carries a slot (the replace phase -- see the `turn`
    -- branch in `onEvent`), cleared by the send that answers it, by the
    -- slot-less `turn` that opens the choice window behind it, and by every
    -- teardown that puts the screen back where the referee says it is.
    replaceWait = nil,
    anim = nil,           -- { anim = id, slot = n } while AnimPlayer runs
    animPlayer = nil,
    result    = nil,
    -- Set while the hub link is down under a live fight: the intermediator's
    -- reconnect grace is running, and onTransportReady is what resumes it.
    awaitingReconnect = false,
    reconnectSent = false,
    liveMoves   = nil,     -- Transform/Mimic overlay; PP-only syncs write mine[]
    disabledMove = nil,    -- our monster's disabled slot, off the referee's lines
    -- Gen1 Battlefield theatre (top-down arena). Unused when classicUi is
    -- latched or Battlefield.enabled is false.
    frame = 0,
    -- Display clock, arena only. `fx` is the list Battlefield renders from;
    -- `draining` / `faintFx` / `expFilling` are the three states that hold the
    -- message queue while the bar falls, the monster after it, and the exp
    -- strip that answers the award. All of them stay nil until something is
    -- actually playing.
    fx = nil,
    -- The move whose particles are on screen, kept so the impact burst on the
    -- beat behind it can borrow that move's colours (`startMoveVfx`).
    moveVfx = nil,
    -- Counts up per emission and wraps; it is what stops two casts of the same
    -- move from drawing the identical particles. Deliberately a counter and
    -- not a roll: both players' screens step it the same way over the same
    -- event stream, so a shared fight stays a shared sight.
    vfxSeed = 0,
    draining = nil,
    faintFx = nil,
    -- Seats holding an arrival that has not had its spawn beat yet: slot index
    -- -> true, raised by `queueSpawnFx` for an *empty* seat and dropped by the
    -- `spawnfx` row that pops. `battlefieldSeat` draws nothing while one is
    -- held, so a monster materialises with its pop rather than standing on the
    -- arena from the moment the packet was parsed. CoopBattle's `introHide`
    -- (src/CoopBattle.lua:1067, dropped by the intro `act` row at :957/:995/
    -- :1027) is the twin. A seat that still has somebody on it is covered by
    -- `slot.pending` instead -- see `noteSlot`.
    spawnHide = nil,
    -- The exp strip mid-crawl: { slot, mon, toLevel, toFrac, frames }. The two
    -- clocks it drives (`shownExpFrac` / `shownLevel`) live on the seat's own
    -- `slots` entry beside `shownHp`, not here -- this is only what is moving
    -- them. Own seat only: the peer's client draws the peer's own strip, the
    -- same ownership rule the whole exp path runs on.
    expFilling = nil,
    -- Moves a level-up produced for a monster that already knows four.
    -- Offered mid-fight via `LearnMove.open`; leftover entries ride out with
    -- `onDone` if the player left before answering (CoopBattle's same shape).
    toLearn = nil,
    -- A forget prompt is on the stack: `{ mon, move, name }`. Holds the
    -- message queue the way `evolving` does, so the next turn does not open
    -- under the Yes/No box.
    learning = nil,
    -- #36: the fanfare finish() parked because the arena still owed one of those.
    victoryMusicHeld = nil,
    battlefieldLoaded = false,
    battlefieldBubbles = nil, -- { { side, humanIndex, text, born }, ... }
    targetIndex = 1,          -- field cursor when a target list exists
    -- Latched at construct: the manager row is live, but swapping chrome
    -- mid-fight would tear the 640×360 arena down under a queued drain.
    -- `opts.classicUi` is the suite hook; nil reads the live row.
    classicUi = ClassicBattle.latched(opts.classicUi),
  }, M)
end

-- The exp-awarding modes that have a *trainer* on the other side.
--
-- The referee's own gate is `EXP_MODES` = wild / coop_wild / coop_npc
-- (server/lib/battle/Turn.js, src/BattleSim/Turn.lua). Two of those three are
-- wildlife; only `coop_npc` fields a trainer, so the x1.5 belongs to it alone
-- and every other token -- including a mode this screen never learned -- pays
-- the plain wild rate.
--
-- Declared here, with the file's constants, rather than beside the exp award
-- that was its first reader: `battlefieldCtx` now asks the same question to
-- decide whether the foe edge of the arena holds a trainer or a peer, and a
-- `local` is only in scope *below* its declaration -- left where it was, that
-- read would have found the global nil and indexed it.
local TRAINER_MODES = { coop_npc = true }

-- The fights the cart fights under link rules: two players, each on their own
-- cart.  Every generation reads it for the badges (`badgesOf` sends none in
-- a link battle: no cart boosts or obedience there), and Gen 3 reads it twice
-- more.  Deoxys uploads its link-battle stats in them (Sheet3's `link`
-- option, pokefirered/src/pokemon.c:6163 -- each version's Deoxys is a
-- different forme, so a cross-version fight uses the ROM's link row), and
-- nothing the fight does to a held item is written home
-- from them: the cart saves the party before a Cable Club battle and loads it
-- back after (pokefirered/src/cable_club.c:776 CB2_ReturnFromCableClubBattle
-- -> load_save.c:170 LoadPlayerParty; the engine's link/battle.lua LB.finish
-- runs the same special), so a berry eaten, an item stolen with THIEF or
-- swapped with TRICK is back where it was once the link closes.  Exported for
-- src/CoopBattle.lua, whose `coop_pvp` is the other one.
local LINK_MODES = { ["1v1"] = true, coop_pvp = true }
M.LINK_MODES = LINK_MODES

-- ...and the fights whose item changes the cart *keeps*: a wild or NPC
-- trainer battle, where the battle party's held items are copied home at the
-- end (the engine's battle_bridge.lua writeback, pret
-- battle_controller_player.c:1909) -- a berry eaten stays eaten, a THIEF from
-- a wild mon keeps the item.  A mode on neither list (a newer token) writes
-- nothing home, the safe way round.  Gold keeps the same list: pokecrystal's
-- ConsumeHeldItem and BattleCommand_Thief write the player's party struct as
-- well as the battle's (engine/battle/consume_held_item.asm,
-- move_effects/thief.asm -- "if the enemy steals your item, it's gone for good
-- if you don't get it back"), so a berry eaten against the computer stays
-- eaten and a THIEF from a wild mon keeps its item -- and a fight between
-- players here never writes home on any generation (owner decision,
-- docs/plans/gen12-referee-fidelity.md §9).  Exported for src/CoopBattle.lua's
-- Gen 2 arm.
local KEEPS_HELD_MODES = { wild = true, coop_npc = true, coop_wild = true }
M.KEEPS_HELD_MODES = KEEPS_HELD_MODES

-- ------- Gen1 Battlefield theatre gate
--
-- Hard-cut when Battlefield.enabled(game) and CLASSIC BATTLE UI is off:
-- wide fill canvas + arena draw. The option (latched on `classicUi`) and
-- any generation that fails the theatre gate keep the classic 160×144
-- side-view path below.

local BUBBLE_LIFE = 90

function M:usesBattlefield()
  if self.classicUi then return false end
  return Battlefield.enabled(self.game)
end

function M:isWideBattleLayout()
  return self:usesBattlefield()
end

function M:uiSize()
  if self:usesBattlefield() then
    return Battlefield.WIDTH, Battlefield.HEIGHT
  end
  return 160, 144
end

function M:wantsFillScale()
  return self:usesBattlefield()
end

function M:ensureBattlefield()
  if self.battlefieldLoaded then return end
  self.battlefieldLoaded = true
  pcall(Battlefield.reloadArena)
  pcall(Battlefield.load, mod)
end

-- Soft: local OW sprite id from mod save/options (same sources Client uses).
local function selfSpriteId()
  local ok, id = pcall(function()
    local chosen = mod.save and mod.save:get("sprite")
    if type(chosen) ~= "string" or chosen == "" then
      chosen = mod.options and mod.options:get("sprite")
    end
    if type(chosen) ~= "string" or chosen == "" then return nil end
    local Chars = need("Chars")
    if Chars and Chars.resolve then return Chars.resolve(chosen) end
    return chosen
  end)
  if ok and type(id) == "string" and id ~= "" then return id end
  return nil
end

-- Soft: the peer's row off the live roster export, if any.
local function peerRow(peerId)
  if peerId == nil then return nil end
  local ok, players = pcall(function()
    return mod.exports and mod.exports.players and mod.exports.players()
  end)
  if not (ok and type(players) == "table") then return nil end
  for _, row in ipairs(players) do
    if type(row) == "table" and row.id == peerId then return row end
  end
  return nil
end

-- Soft: peer OW sprite from the live roster export, if any.
local function peerSpriteId(peerId)
  if peerId == nil then return nil end
  local ok, players = pcall(function()
    return mod.exports and mod.exports.players and mod.exports.players()
  end)
  if not (ok and type(players) == "table") then return nil end
  for _, row in ipairs(players) do
    if type(row) == "table" and row.id == peerId
        and type(row.sprite) == "string" and row.sprite ~= "" then
      return row.sprite
    end
  end
  return nil
end

local function playerName(game)
  if Gen3.active() then
    local player = Gen3.player()
    local name = (player and player.name)
      or (type(game) == "table" and type(game.session) == "table" and game.session.name)
    if type(name) == "string" and name ~= "" then return name end
    return "YOU"
  end
  local name = game and game.save and game.save.player and game.save.player.name
  if type(name) == "string" and name ~= "" then return name end
  return "YOU"
end

-- Bag icon for a field seat. Soft-fail to nil; Battlefield draws a stand-in.
function M:seatIcon(speciesKey, monHint)
  -- Gen 3's menu icon is the engine's own two-frame record (32x32 frames),
  -- which the arena animates itself (Battlefield.gen3Icon / gen3IconFrame).
  if self:generation() == 3 then
    local sp = tonumber(speciesKey)
    if sp and type(Battlefield.gen3Icon) == "function" then
      local ok, icon = pcall(Battlefield.gen3Icon, (type(monHint) == "table"
        and tonumber(monHint.species) == sp) and monHint or sp)
      if ok then return icon end
    end
    return nil
  end
  if type(speciesKey) ~= "string" or speciesKey == "" then return nil end
  local data = self.game and self.game.data
  if not data then return nil end
  local eng = loadEngine()
  local Sprites = eng and eng.Sprites
  local icons = data.icons
  local def = data.pokemon and data.pokemon[speciesKey]
  local mon = monHint or { species = speciesKey }
  local path, name
  pcall(function()
    local entry = (icons and icons.bySpecies and icons.bySpecies[speciesKey])
      or (def and def.icon)
    if type(entry) == "string" then
      name = entry
      path = icons and icons.icons and icons.icons[entry]
    elseif type(entry) == "table" then
      path = entry.image
    end
    if not path and def and def.dex and icons and icons.byDex then
      name = icons.byDex[def.dex]
      path = name and icons.icons and icons.icons[name]
    end
    if Sprites and Sprites.iconPath then
      path = Sprites.iconPath(data, mon, path, { name = name })
    end
  end)
  if type(path) ~= "string" or path == "" then return nil end
  local ok, img = pcall(function()
    local Assets = require("src.render.Assets")
    if Assets and Assets.image then return Assets.image(path) end
    return love.graphics.newImage(path)
  end)
  if ok then return img end
  return nil
end

-- Battle FRONT pic for the arena (player slots hold backs in classic 1v1).
--
-- **The one genuinely generation-shaped source the theatre needs.** Gen 1 gets
-- it by building a throwaway battler -- `BattleState.makeBattler` resolves the
-- pic as a side effect of making one -- and that module does not exist on Gold.
-- Gen 2 keeps the front path on the species record itself
-- (`def.spriteFront`, which `src/ui/gen2/BattleState.lua:pic` reads), so the
-- Gold arm is a lookup and a load rather than a probe.
--
-- It does raise `pokemon.sprite` (inside `Battlefield.gen2FrontImage`), the
-- seam every Gen 2 mon pic goes through: a battle-sprite mod that reskins the
-- solo fight has to reskin this arena too. `ctx.mon` is the SAVE mon when this
-- client has one -- never a seat's `Wire.battleMon`, whose `species` is the
-- display token -- and nil for a peer's or a wild's, so a hook keyed on species
-- works for every seat and a per-instance skin only for the monsters we own.
--
-- What the Gold arm deliberately does *not* reproduce is the Unown form row.
-- It needs the live battler's DVs, which a wire sheet does not carry -- the
-- seat here is built from `Wire.battleMon`, not from a save mon -- so
-- re-deriving it would be inventing a form off data this screen was never
-- sent. A form that resolves to nothing falls back to the species row, which
-- is what the cart draws for every Unown that is not its own letter anyway.
function M:seatFront(speciesKey, monHint, slot, isOwn)
  -- A Gen 3 key is the internal species number (a number off EvolveFx, the
  -- same number as a string off the wire).
  if type(speciesKey) == "number" then speciesKey = tostring(speciesKey) end
  if type(speciesKey) ~= "string" or speciesKey == "" then return nil end
  local movie = self.evolving
  if movie and isOwn then
    local hit = EvolveFx.formCacheGet(movie, "front", speciesKey)
    if hit ~= nil then return hit or nil end
  end
  if slot and slot._bfFront ~= nil and slot._bfFrontSpecies == speciesKey then
    local cached = slot._bfFront
    return (cached ~= false) and cached or nil
  end
  local resolved = nil
  -- Gen 3: the cart's own 64x64 front pic, mon-aware (shiny from the OT and
  -- personality, Unown letter, Spinda spots, Castform form) for a monster this
  -- client owns, by species for anybody else's -- a wire sheet carries no
  -- personality, so a peer's is drawn as its species, the honest answer.
  if self:generation() == 3 then
    local sp = tonumber(speciesKey)
    local subject = sp
    if slot == nil and type(monHint) == "table" and tonumber(monHint.species) == sp then
      subject = monHint
    elseif isOwn then
      local own = self:saveMon(self.active)
      if own and tonumber(own.species) == sp then subject = own end
    end
    local pic = sp and Gen3.frontPic(subject, { form = slot and slot.form }) or nil
    resolved = pic and pic.image or nil
    if movie and isOwn then
      EvolveFx.formCachePut(movie, "front", speciesKey, resolved)
    end
    if slot then
      slot._bfFront = resolved or false
      slot._bfFrontSpecies = speciesKey
    end
    return resolved
  end
  local eng = loadEngine()
  local data = self.game and self.game.data
  local save = self.game and self.game.save
  -- **A save-mon-shaped stub, and never the wire sheet itself.**
  --
  -- `BattleState.makeBattler` is written against the engine's own mon: it
  -- indexes `data.pokemon[mon.species]` for the definition it names the
  -- battler from, and it measures the HP bar with
  -- `Timing.hpBarPixels(mon.hp, math.max(1, mon.stats.hp))`. A `Wire.battleMon`
  -- sheet answers neither. Its `species` is the *display* token (the nickname
  -- wherever the player set one), and its `stats` is the wire dialect --
  -- `atk`/`def`/`spd`/`spc`, with **no `hp` at all**, because the maximum
  -- travels beside it as `maxHp`. So `mon.stats.hp` was nil, `math.max` threw,
  -- the pcall swallowed it and this function returned nil for *every* seat on
  -- Gen 1.
  --
  -- Which looked like it worked, because the caller falls back to
  -- `slot.sprite`: a foe's slot pic is already the front (`refreshSlotSprite`
  -- passes isPlayer=false), so the opponent drew correctly by accident, while
  -- this client's own monster drew the *back* pic the classic 1v1 stage wants
  -- -- the arena showing PIKACHU from behind, mirrored, where co-op shows the
  -- front pic. The two screens agree again now, which is the whole point of
  -- `seatFrontFor` in src/CoopBattle.lua being this function's twin: it never
  -- hit this because it is handed a real `battler.mon`.
  --
  -- Same shape as `refreshSlotSprite`'s stub, deliberately -- the id in
  -- `species` and the narrated token kept as `nickname` -- so the two pics a
  -- seat can hold are resolved off the same description.
  local mon = nil
  if data then
    local maxHp = (slot and slot.maxHp) or (monHint and monHint.maxHp) or 1
    mon = {
      species = speciesKey,
      nickname = (slot and slot.species) or (monHint and monHint.species),
      level = (monHint and monHint.level) or (slot and slot.level) or 5,
      hp = (slot and slot.hp) or (monHint and monHint.hp) or maxHp,
      stats = {
        hp = maxHp,
        attack = 1, defense = 1, speed = 1, special = 1,
      },
      moves = (monHint and monHint.moves) or { { id = "TACKLE", pp = 1 } },
      status = slot and slot.status or nil,
    }
  end
  if Gen.generation(self.game) == 2 then
    local def = data and type(data.pokemon) == "table" and data.pokemon[speciesKey]
    local path = type(def) == "table" and def.spriteFront or nil
    if type(path) == "string" and path ~= "" then
      -- Baked, not loaded raw: a Gold front pic is a grey four-shade sheet.
      -- `Battlefield.gen2FrontImage` resolves it through `pokemon.sprite` and
      -- applies the species palette -- see its header.
      -- **Shiny comes from whichever copy of the monster actually knows.**
      -- Two callers ask, and they hand in different shapes:
      --
      --   * An ARENA SEAT hands in a `Wire.battleMon`, which carries no
      --     `shiny` at all -- so asking the sheet would be an argument that is
      --     structurally always false, which reads like working code and is
      --     worse than not asking. Those fall through to the save mon behind
      --     this client's own seat, gated on **`isOwn` and not a species
      --     match**: that is the trap the first version walked into, where a
      --     foe running the same species as our active monster matched on the
      --     name and inherited *our* flag, drawn in a palette the referee
      --     never described. A peer's or a wild's stays false, which is the
      --     honest answer, because nothing on the wire ever told us.
      --   * The PARTY PREVIEW hands in the SAVE mon, which does carry the
      --     flag, for a monster that is usually not the active one. A hint
      --     that carries it answers for itself -- probing the active seat
      --     instead would paint the wrong bench monster gold.
      local shiny
      if monHint ~= nil and monHint.shiny ~= nil then
        shiny = monHint.shiny and true or false
      else
        local own = isOwn and self:saveMon(self.active) or nil
        shiny = (own and own.species == speciesKey and own.shiny)
          and true or false
      end
      -- `pokemon.sprite`'s ctx.mon, on the same principle: the save copy
      -- where there is one. A slot-less caller (the party preview, the
      -- evolution movie) hands in the save mon -- `partyFront` falls back to
      -- the sheet only when the save slot will not resolve -- and a seat's is
      -- the one behind our own active, or nothing.
      local known = nil
      if slot == nil then
        known = monHint
      elseif isOwn then
        local own = self:saveMon(self.active)
        if own and own.species == speciesKey then known = own end
      end
      resolved = Battlefield.gen2FrontImage(self.game, speciesKey, path, shiny,
        known)
      if not resolved then
        local ok, img = pcall(function()
          local Assets = require("src.render.Assets")
          if Assets and Assets.image then return Assets.image(path) end
          return love.graphics.newImage(path)
        end)
        if ok and img then resolved = img end
      end
    end
  elseif eng and eng.BattleState and eng.BattleState.makeBattler and mon and data then
    local ok, probe = pcall(eng.BattleState.makeBattler, data, mon, false, save)
    if ok and probe and probe.sprite then resolved = probe.sprite end
  end
  if movie and isOwn then
    EvolveFx.formCachePut(movie, "front", speciesKey, resolved)
  end
  if slot then
    slot._bfFront = resolved or false
    slot._bfFrontSpecies = speciesKey
  end
  return resolved
end

-- One Battlefield seat from a live field slot (player or foe active).
function M:battlefieldSeat(slotIndex, isPlayer)
  local slot = self.slots[slotIndex]
  if not slot or not slot.species then return nil end
  -- An arrival that has not had its spawn beat yet is not on the arena. The
  -- seat record is already filled -- the referee's field moved the moment the
  -- packet was parsed and the rules read it from here -- but nothing is drawn
  -- until the queued `spawnfx` row plays and `applySwap` drops the hold.
  -- Same shape as the ball flow's hold below (`BALL_HIDE_FX`) and as
  -- CoopBattle's `introHide` (src/CoopBattle.lua:5030).
  if self.spawnHide and self.spawnHide[slotIndex] then return nil end
  -- Keep KO'd seats until releasePic clears the sprite, matching classic hold.
  -- A seat whose display clock has not caught up is still falling: dropping it
  -- here would take the bar off the arena in the middle of its own drain.
  if (slot.hp or 0) <= 0 and not slot.sprite and not slot.koHold
      and (slot.shownHp or 0) <= 0 then
    return nil
  end
  local monHint = nil
  if isPlayer then
    monHint = self.mine and self.mine[self.active]
    -- ...but only while it still describes who is standing here. `self.active`
    -- moves at parse, because the referee is already asking this client about
    -- the monster it just sent; the seat moves at the swap. In the window
    -- between, the hint is the *arrival's* sheet, and the pic and level pill it
    -- would furnish belong to a monster that is not on the arena yet.
    if monHint and slot.pending ~= nil and monHint.species ~= slot.species then
      monHint = nil
    end
  end
  local key = self:seatSpeciesKey(slot, isPlayer) or slot.species
  local movie = self.evolving
  local evolvingHere = movie and isPlayer
    and self:saveMon(self.active) == movie.mon
  if evolvingHere then
    key = EvolveFx.picSpecies(movie) or key
    -- Gen 3 species are numbers on the save mon and strings on the seat.
    if type(key) == "number" then key = tostring(key) end
  end
  local acting = false
  if self.anim and self.anim.slot == slotIndex then acting = true end
  local icon
  if evolvingHere then
    local cached = EvolveFx.formCacheGet(movie, "icon", key)
    if cached ~= nil then
      icon = cached or nil
    else
      icon = self:seatIcon(key, monHint and {
        species = monHint.speciesId or key,
        hp = slot.hp,
      } or { species = key })
      EvolveFx.formCachePut(movie, "icon", key, icon)
    end
  else
    icon = slot.icon
    if icon == nil then
      icon = self:seatIcon(key, monHint and {
        species = monHint.speciesId or key,
        hp = slot.hp,
      } or { species = key })
      slot.icon = icon or false
    elseif icon == false then
      icon = nil
    end
  end
  local frontMon = monHint
  if not frontMon then
    frontMon = {
      species = key,
      level = slot.level or 5,
      hp = slot.hp,
      maxHp = slot.maxHp,
    }
  elseif not frontMon.species then
    frontMon = {
      species = frontMon.speciesId or key,
      level = frontMon.level or slot.level or 5,
      hp = slot.hp,
      maxHp = slot.maxHp,
    }
  end
  local front = self:seatFront(key, frontMon, slot, isPlayer) or slot.sprite or nil
  -- The exp strip's two clocks, and only ever on this client's own seat.
  --
  -- Ownership is the whole rule: the fraction is read off *this* save file, and
  -- nothing on the wire carries one, so the peer's plate is drawn by the peer's
  -- own client from their own party and this one leaves theirs nil -- which is
  -- Battlefield's no-data state and draws no strip at all. Seeded here, at
  -- first sight, because a `slots` entry is built from a wire event and the
  -- wire knows nothing about exp; `seedExpClock` only ever fills a nil, so a
  -- clock mid-fill is never yanked back to truth by a draw.
  local expFrac, shownLevel
  if isPlayer and slotIndex == self:mySlot() then
    self:seedExpClock(slot)
    expFrac = slot.shownExpFrac
    shownLevel = slot.shownLevel
  end
  return {
    index = slotIndex,
    name = slot.species,
    level = slot.level or (monHint and monHint.level) or 1,
    hp = slot.hp or 0,
    -- Display clocks, plate-only (see Battlefield's seat HP contract). nil
    -- keeps meaning "no exp data" all the way down to drawPlate; the pill
    -- prefers `shownLevel` so it ticks over as the strip tops out rather than
    -- a message later.
    expFrac = expFrac,
    shownLevel = shownLevel,
    -- Display clock. Battlefield falls back to `hp` when this is absent, so a
    -- seat that never drained reads exactly as it did before.
    shownHp = self:shownHpOf(slot),
    maxHp = slot.maxHp or 1,
    -- Own-seat fallback: the snapshot sheet already named the condition, and
    -- a send that predates carrying `status` would otherwise draw a healthy
    -- card over a poisoned monster. The foe's chip is the send itself -- we
    -- hold no sheet for them.
    status = slot.status or (monHint and monHint.status) or nil,
    confused = slot.confused or false,
    species = key,
    icon = icon,
    front = front,
    acting = acting,
    -- Gen 3's field state on this seat (nil everywhere else): the substitute
    -- doll standing in for the monster, Castform's form, and how far the cart
    -- floats this species over its platform.
    substitute = slot.substitute or nil,
    form = slot.form,
    elevation = self:seatElevation(key),
  }
end

-- pret gEnemyMonElevation for a Gen 3 species (Battlefield reads it off the
-- engine's per-version pic coords); nil off Gen 3 and for a species that
-- stands on the ground.
function M:seatElevation(key)
  if self:generation() ~= 3 or type(Battlefield.gen3Elevation) ~= "function" then
    return nil
  end
  local ok, elev = pcall(Battlefield.gen3Elevation, tonumber(key))
  if ok then return elev end
  return nil
end

function M:pruneBattlefieldBubbles()
  local list = self.battlefieldBubbles
  if type(list) ~= "table" then return end
  local frame = self.frame or 0
  local kept = {}
  for _, b in ipairs(list) do
    if type(b) == "table" then
      local born = tonumber(b.born) or 0
      local age = frame - born
      if age < BUBBLE_LIFE then
        local t = 1 - (age / BUBBLE_LIFE)
        kept[#kept + 1] = {
          side = b.side,
          humanIndex = b.humanIndex or 1,
          text = b.text,
          -- Optional, and only on a move callout: the renderer emphasises it.
          moveName = b.moveName,
          -- The acting mon's display name, carried like `moveName` so a
          -- rebuilt bubble keeps the line the renderer draws above the move.
          name = b.name,
          t = t,
          born = born,
        }
      end
    end
  end
  self.battlefieldBubbles = (#kept > 0) and kept or nil
end

-- Trainer callout when a human-owned mon acts. Never for the wild foe.
--
-- Returns true when a bubble was actually put up, which is what `startAnim`
-- reads to decide whether the row has a callout beat to hold for: a move with
-- nobody to shout it (the wild foe) must not stall the arena on a bubble that
-- was never drawn.
function M:noteBattlefieldBubble(row)
  if not self:usesBattlefield() then return end
  if type(row) ~= "table" then return end
  local anim = row.anim
  if type(anim) ~= "string" or anim == "" then return end
  -- Engine ball / hide / shake markers are not move callouts.
  if anim:find("_ANIM", 1, true) then return end

  -- The bubble is one sentence in two parts, CoopBattle's twin exactly: "used"
  -- is the small lead-in and `moveName` is the line the renderer emphasises.
  -- The raw id used to be the text as well, on the theory that nothing reading
  -- the bubble should change meaning -- but the renderer draws both parts, so
  -- a bubble said the move twice ("FIX_BOOST" over "FIX BOOST"). `moveName` is
  -- the registry name, or the wire id again when the build has no record for
  -- the move (a modded move whose definition did not survive).
  local moveName = self:moveLabel(anim)

  local mine = row.slot == self:mySlot()
    or (row.side ~= nil and row.side == self.mySide)
  if not mine then
    if self.mode == "wild" then return end
    self.battlefieldBubbles = {{
      side = "foe",
      humanIndex = 1,
      text = "used",
      moveName = moveName,
      name = self:battlefieldSeatName(row.slot or self:foeSlot()),
      born = self.frame or 0,
    }}
    return true
  end
  self.battlefieldBubbles = {{
    side = "ally",
    humanIndex = 1,
    text = "used",
    moveName = moveName,
    name = self:battlefieldSeatName(row.slot or self:mySlot()),
    born = self.frame or 0,
  }}
  return true
end

-- The acting mon's display name for a field slot: exactly the string the seat
-- plate shows, because it is the same field `battlefieldSeat` puts in `name`
-- (the slot's wire species label, which plateModel then truncates). Reading
-- the slot rather than re-deriving it is what keeps a bubble and the plate
-- under it from ever naming two different mons. nil when the slot is gone, and
-- a bubble with no `name` renders as it always did.
function M:battlefieldSeatName(slotIndex)
  local slot = slotIndex and self.slots and self.slots[slotIndex]
  local name = slot and slot.species
  if type(name) == "string" and name ~= "" then return name end
  return nil
end

-- The Gen 3 move row a token names, off the sheets this client uploaded (or
-- the referee's Transform / Mimic overlay): the only move table a Gen 3
-- screen holds.  nil for a move none of ours knows (the foe's).
function M:gen3MoveRow(id)
  if type(id) ~= "string" or id == "" then return nil end
  for _, row in ipairs(self.liveMoves or {}) do
    if type(row) == "table" and row.id == id then return row end
  end
  for _, sheet in ipairs(self.mine or {}) do
    for _, row in ipairs((type(sheet) == "table" and sheet.moves) or {}) do
      if type(row) == "table" and row.id == id then return row end
    end
  end
  return nil
end

-- A move's display name, CoopBattle's lookup: the registry name when the build
-- has one, the wire id otherwise.
-- A move's type under the name the player reads on the classic TYPE/ strip.
--
-- `TypeChart.displayName` is the mapping that turns PSYCHIC_TYPE into PSYCHIC
-- and a modded type into its registered name, and it answers from the module's
-- own vanilla records when nothing called `load` -- so this is safe on a
-- screen that never touched the chart. A build without the module at all falls
-- through to the raw id, which still says something true.
function M:moveTypeName(id)
  if self:generation() == 3 then
    local row = self:gen3MoveRow(id)
    return row and Gen3.typeName(row.type) or nil
  end
  local moves = self.game and self.game.data and self.game.data.moves
  local def = type(moves) == "table" and moves[id] or nil
  local typeId = def and def.type
  if type(typeId) ~= "string" or typeId == "" then return nil end
  local TypeChart = (loadEngine() or {}).TypeChart
  if TypeChart and type(TypeChart.displayName) == "function" then
    local ok, name = pcall(TypeChart.displayName, typeId)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return typeId
end

function M:moveLabel(id)
  if type(id) ~= "string" or id == "" then return nil end
  -- Gen 3: the name the sheet carried, else the token spelled out (a foe's
  -- move: the referee narrates it the same way, C4 "Move row").
  if self:generation() == 3 then
    local row = self:gen3MoveRow(id)
    if row and type(row.name) == "string" and row.name ~= "" then return row.name end
    return (id:gsub("_", " "))
  end
  local moves = self.game and self.game.data and self.game.data.moves
  local def = type(moves) == "table" and moves[id] or nil
  local name = def and def.name
  if type(name) == "string" and name ~= "" then return name end
  return id
end

-- Living foe seats for a field cursor (1v1 has exactly one).
function M:battlefieldTargets()
  local foe = self:battlefieldSeat(self:foeSlot(), false)
  if not foe then return {} end
  if (foe.hp or 0) <= 0 and not foe.front then return {} end
  return { foe }
end

-- The roster the chip beside a trainer's name draws, for one field seat.
--
-- The referee's word first, and our own uploaded sheets only as the fallback.
-- Two reasons, and the second is the one that matters: the referee is what has
-- been *fighting* with those sheets, so where the two could disagree it is
-- right -- and a PROTOCOL 22 intermediator emits no `team` at all, in which
-- case falling back is what still gets the player their own row rather than
-- leaving both sides blank. There is no fallback for the seat opposite, and
-- there cannot be: nobody uploads a party to anybody but the referee.
--
-- nil rather than an empty list when there is nothing to say, because
-- `rosterModel` reads nil as "this trainer published no roster" and draws no
-- chip, while six blank rings would claim they have nothing left.
function M:seatRoster(slot, ownSheets)
  local roster = slot and self.teams and self.teams[slot]
  if type(roster) == "string" and roster ~= "" then return roster end
  if ownSheets and type(self.mine) == "table" and #self.mine > 0 then
    return self.mine
  end
  return nil
end

function M:battlefieldCtx()
  local mode = (self.mode == "wild") and "wild" or "1v1"
  local allyHumans = {{
    id = "self",
    name = playerName(self.game),
    spriteId = selfSpriteId(),
    party = self:seatRoster(self:mySlot(), true),
  }}
  local gen3 = self:generation() == 3
  if gen3 then
    -- Gen 3 maps a player's overworld graphic through their version and
    -- gender (contract C3); ours are this boot's.
    local player = Gen3.player()
    allyHumans[1].version = Gen3.version()
    allyHumans[1].gender = player and player.gender or nil
  end
  local foeHumans = {}
  -- Who is standing on the foe edge: an NPC trainer, a peer, or nobody.
  --
  -- **The trainer arm has to come first**, because `mode` above folds every
  -- non-wild shape into "1v1" for the arena's geometry -- so a `coop_npc`
  -- fight fell into the peer arm and was drawn from `self.peerId`, which a
  -- solo battle never has. `peerSpriteId(nil)` is nil, and a human with no
  -- sheet is `Battlefield.drawHuman`'s placeholder silhouette: the dark box
  -- that stood where the trainer should have been for the whole of every solo
  -- trainer fight.
  --
  -- One entry and never a player's, exactly as
  -- `CoopBattle:battlefieldFoeHumans` builds it: the entry is unconditional
  -- even when the walk sheet cannot be named, because the trainer *is* on the
  -- field either way and the silhouette is still a trainer standing there.
  --
  -- Both arms carry the foe's roster off the referee and neither has a
  -- fallback: an NPC's party is as invisible to this screen as a peer's is.
  -- That is not a gap in the solo path -- a solo fight runs the same referee
  -- over a table transport (`SoloBattle:_transport`), so the `team` events
  -- arrive there exactly as they do off a hub, and the trainer's ball row is
  -- filled by the same code that fills a stranger's.
  if TRAINER_MODES[self.mode] then
    foeHumans[1] = {
      id = (self.trainer and self.trainer.id) or self.peerId,
      name = (self.trainer and self.trainer.name) or self.peerName or "FRIEND",
      spriteId = Gen.trainerWalkSpriteId(self.trainer, self.game),
      party = self:seatRoster(self:foeSlot(), false),
    }
    -- A Gen 3 NPC stands on the field as the cart shows one: its own
    -- TRAINER_PIC_* front pic (the engine trainer row names it).
    local t = self.trainer
    if gen3 and type(t) == "table" then
      foeHumans[1].trainerPic = tonumber(t.trainerPic or t.pic or t.picId)
    end
  elseif mode == "1v1" then
    foeHumans[1] = {
      id = self.peerId,
      name = self.peerName or "FRIEND",
      spriteId = peerSpriteId(self.peerId),
      party = self:seatRoster(self:foeSlot(), false),
    }
    if gen3 then
      local row = peerRow(self.peerId)
      foeHumans[1].version = row and row.version or nil
      foeHumans[1].gender = row and row.gender or nil
    end
  end

  local ally = self:battlefieldSeat(self:mySlot(), true)
  local foe = self:battlefieldSeat(self:foeSlot(), false)
  local allySeats = ally and { ally } or {}
  local foeSeats = foe and { foe } or {}

  -- Target card: show while picking FIGHT / moves. 1v1 has no multi-target
  -- picker, but the card still lands on the lone foe.
  local targets, targetIndex = nil, nil
  local showTarget = false
  if self.phase == "move" or self.phase == "mimic" then
    showTarget = true
  elseif self.phase == "choose" and self:commandList()[self.commandIndex or 1] == "FIGHT" then
    showTarget = true
  elseif self.phase == "target" then
    showTarget = true
  end
  if showTarget then
    targets = self:battlefieldTargets()
    if #targets > 0 then
      targetIndex = self.targetIndex or 1
      if targetIndex < 1 or targetIndex > #targets then targetIndex = 1 end
      self.targetIndex = targetIndex
    end
  end

  local frame = self.frame
  if not frame or frame == 0 then
    local ok, t = pcall(function()
      return love and love.timer and love.timer.getTime() * 60
    end)
    frame = (ok and t) or 0
  end

  self:pruneBattlefieldBubbles()

  return {
    mode = mode,
    allyHumans = allyHumans,
    foeHumans = foeHumans,
    allySeats = allySeats,
    foeSeats = foeSeats,
    targets = targets,
    targetIndex = targetIndex,
    showTarget = showTarget,
    frame = frame,
    bubbles = self.battlefieldBubbles,
    -- One direction only: this screen advances `t`, Battlefield draws whatever
    -- `t` says. Absent when nothing is playing -- the renderer tolerates that.
    fx = self.fx,
    -- Bench / EXP.ALL movie: no plate to flash, so a front pic in the middle
    -- of the field. Nil when the evolving mon is on a seat.
    evolveCenter = self:evolveCenterCtx(),
    -- The weather over the field ("RAIN" | "SUN" | "SAND" | "HAIL"), as of
    -- the queue's own position: Gen 3's `weather` events, Gold's weather
    -- lines (`weatherOfLine2`); nil when the sky is clear, and always on Red.
    weather = self.weatherShown,
  }
end

-- Classic 160×144 chrome drawn into Battlefield.MENU_BAND at the bottom.
-- Scissor matches CoopBattle.drawMenuBand: clip chrome to the menu band only.
function M:withMenuBand(drawFn)
  local g = love and love.graphics
  if not (g and g.push) then
    pcall(drawFn)
    return
  end
  local bandY = Battlefield.FIELD_BOTTOM
  local band = Battlefield.MENU_BAND
  local classicBox = 48 -- Font.drawBox(0, 12, 20, 6) occupies y=96..144
  g.push()
  g.translate(0, bandY)
  g.scale(Battlefield.WIDTH / 160, band / classicBox)
  g.translate(0, -96)
  if g.setScissor then
    local prev = { g.getScissor() }
    g.setScissor(0, bandY, Battlefield.WIDTH, band)
    pcall(drawFn)
    if prev[1] then
      g.setScissor(prev[1], prev[2], prev[3], prev[4])
    else
      g.setScissor()
    end
  else
    pcall(drawFn)
  end
  g.pop()
end

function M:say(text)
  if type(text) ~= "string" or text == "" then return end
  -- A Gen 3 line out of the cart's text pack pages the way the cart does: a
  -- blank line (what Gen3.battleText makes of the printer's `\p`) starts a
  -- page of its own.  A line that still carries the printer's raw codes is
  -- cleaned first (Exp3.cleanText).
  if Gen3.active() then
    if text:find("\\", 1, true) then text = Exp3.cleanText(text) end
    if text:find("\n%s*\n") then
      for part in (text .. "\n\n"):gmatch("(.-)\n%s*\n%s*") do
        if part ~= "" then self:say(part) end
      end
      return
    end
  end
  self.lines = self.lines or {}
  -- Page here so wrap cannot hide a third line at draw. Coop does the
  -- same in `say`; drawBox paints one page, not "wrap and clip".
  for _, page in ipairs(pageText(text)) do
    if page ~= "" then self.lines[#self.lines + 1] = page end
  end
end

function M:mySlot() return slotOfSide(self.mySide) end
function M:foeSlot() return slotOfSide(self.mySide == "a" and "b" or "a") end

-- Upload what we are bringing.  Idempotent, because two things call it: the
-- session, the moment the hub pairs us, and `enter`, when the screen actually
-- goes up.  The session's call is the one that matters -- it is what lets the
-- suite drive the exchange with no state stack at all -- and `enter` is the
-- belt for a screen pushed by some other route.
function M:start(game)
  if game then self.game = game end
  if self.uploaded then return true end
  if not (self.transport and self.battle) then return false end

  local mons = M.snapshotParty(self.game, { link = LINK_MODES[self.mode] == true })
  if #mons == 0 then
    -- Uploading nothing would leave the intermediator holding a seat open
    -- until its grace expired, and the player watching a screen that never
    -- starts.  Ended here instead, with the reason on it.
    mod.log:warn("no POKeMON could be described for a mediated battle, so "
      .. "there is nothing to fight with -- check the party from START > "
      .. "POKeMON, and report this if it is not empty")
    self.uploaded = true
    self:say("You have no POKeMON\nto battle with!")
    self:finish("draw", "gone")
    return false
  end

  self.uploaded = true
  self.mine = mons
  -- Gen 3: which held items this fight's uploads brought, taken before any
  -- `held` event can move one (see `ownItem`), and the hold effect each was
  -- uploaded with (see `holdEffect3`).
  if self:generation() == 3 then
    self.ownItems = nil
    self:ownItemSet()
    self.uploadHoldMap = nil
    self:uploadHolds()
  elseif self:generation() == 2 then
    -- Gold's: the same set, by item id (see `ownItem2`).
    self.ownItems2 = nil
    self:ownItemSet2()
  end

  if self.role == "host" or self.mode == "wild" then
    M.sendRuleset(self.transport, self.game, { wild = self.mode == "wild" })
  end
  -- No side: a 1v1 has none to name. NPC uploads (wild / trainer) are side
  -- "b" from this client, the initiator. Wild carries no bag; a trainer
  -- carries the kit from this game's data, for this fight only.
  local bag = M.snapshotBag(self.game)
  self.bagSheet = M.bagCounts(bag)
  -- The badges count only against the computer (`badgesOf`): a 1v1 sends none.
  M.sendParty(self.transport, self.battle, mons, nil, bag, M.badgesOf(self.game, self.mode))
  if self.mode == "wild" and type(self.wildParty) == "table" and #self.wildParty > 0 then
    M.sendParty(self.transport, self.battle, self.wildParty, "b")
  elseif type(self.npcParty) == "table" and #self.npcParty > 0 then
    M.sendParty(self.transport, self.battle, self.npcParty, "b",
      M.trainerBagEntries(self.trainer, self.game), nil,
      M.npcSeat(self.game, self.trainer, self.peerName))
  end
  return true
end

-- ------- inbound

-- The field is assembled and the first turn is open.
--
-- The sides are read back rather than assumed, and the peer's id is what
-- decides them: this client does not carry its own hub id down here, but it
-- does know who it is fighting, so "the side the peer is not on is mine" is an
-- answer that needs nothing else.  The role is the fallback for a hub that
-- named the sides some other way -- the asker hosts, and the hub seats the
-- asker on side a.
function M:onReady(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end

  local function holds(list, id)
    for _, entry in ipairs(list or {}) do
      if entry == id then return true end
    end
    return false
  end
  local sides = msg.sides or {}
  if self.peerId then
    if holds(sides.b, self.peerId) then
      self.mySide = "a"
    elseif holds(sides.a, self.peerId) then
      self.mySide = "b"
    end
  elseif self.mode == "wild" then
    -- Solo wild: we sit on side a; the synthetic seat is the peer for resultFor.
    self.mySide = "a"
    self.peerId = sides.b and sides.b[1] or self.peerId
    self.selfId = sides.a and sides.a[1] or self.selfId
  end

  if msg.mode then self.mode = msg.mode end

  if self.phase == "setup" then
    self.phase = "play"
    if self:generation() == 3 then
      -- The cart's openings: "Wild X appeared!" / "X\nwould like to battle!"
      -- -- the name on a line of its own, the way pret's
      -- sText_Trainer1WantsToBattle / sText_LinkTrainerWantsToBattle break it.
      local wild = type(self.wildParty) == "table" and self.wildParty[1] or nil
      if self.mode == "wild" then
        self:say(("Wild %s\nappeared!"):format(tostring(wild and wild.species or "POKéMON")))
      else
        self:say(("%s\nwould like to battle!"):format(
          M.trainerLabel3(self.trainer) or tostring(self.peerName or "?")))
      end
    elseif self.mode == "wild" then
      -- pokered _WildMonAppearedText / pokecrystal WildPokemonAppearedText:
      -- "Wild <MON>\nappeared!" -- and nothing more when it comes out (the
      -- send-out below says nothing for a wild seat).
      local wild = type(self.wildParty) == "table" and self.wildParty[1] or nil
      self:say(("Wild %s\nappeared!"):format(tostring(wild and wild.species or "POKéMON")))
    elseif self:generation() == 2 then
      -- pokecrystal WantsToBattleText: "<ENEMY>\nwants to battle!"
      self:say(("%s\nwants to battle!"):format(self:foeTrainerName()))
    else
      -- pokered _TrainerWantsToFightText: "<TRAINER> wants\nto fight!"
      self:say(("%s wants\nto fight!"):format(self:foeTrainerName()))
    end
  end
end

-- A trainer's send-out line, in each cart's words, as the pages it is read
-- in (one `say` each).
--
--   Red    pokered _TrainerSentOutText (data/text/text_2.asm): "<TRAINER>
--          sent" / line "out <MON>!" -- "X sent\nout Y!".
--   Gold   pokecrystal BattleText_EnemySentOut (data/text/battle.asm):
--          "<ENEMY>" / line "sent out" / cont "<MON>!".  `cont` waits for the
--          button and scrolls one line (home/text.asm _ContText), so the box
--          is read twice: "X\nsent out", then "sent out\nY!".  <ENEMY> is
--          the trainer's class and name (PlaceEnemysName), or a link
--          opponent's name.
--   Gen 3  this screen's own "X sent out\nY!", as before.
--
-- Shared with src/CoopBattle.lua for a foe seat's send-out.
function M.sentOutPages(who, mon, generation)
  who, mon = tostring(who or "?"), tostring(mon or "?")
  if generation == 1 then return { ("%s sent\nout %s!"):format(who, mon) } end
  if generation == 2 then
    return { ("%s\nsent out"):format(who), ("sent out\n%s!"):format(mon) }
  end
  return { ("%s sent out\n%s!"):format(who, mon) }
end

-- ------- Gold's drag-out: the send-out line the cart never shows
--
-- pokecrystal BattleCommand_ForceSwitch (engine/battle/effect_commands.asm,
-- pokegold the same), outside a wild fight: ForceEnemySwitch /
-- SwitchPlayerMon field the monster it drew with the send-out animation
-- alone (ShowSetEnemyMonAndSendOutAnimation, SendOutPlayerMon -- neither
-- prints a line), and DraggedOutText, "<MON> was dragged out!", is the whole
-- of what is said.  The Gold referee states the arrival as any send-out
-- (`switch` + `send`, BattleSim2 Turn `_sendOut`) and the line straight
-- behind it (`_forceSwitch`) -- with at most the departing monster's `moves`
-- between them -- so this screen says a send-out's line as always and takes
-- it back when the next event is that line about the same monster: neither
-- the trainer's "<TRAINER> sent out <MON>!" pages nor our own "Go! <MON>!".
-- The arrival (the throw, the burst) stays; the cart plays it.
function M.draggedOutLine(text, species)
  if type(text) ~= "string" then return false end
  local who = text:match("^(.-) was dragged out!?$")
  if not who or who == "" then return false end
  return species == nil or who == species
end

-- The send-out just queued (`self.lines[from..to]`, the pages `say` put
-- there, then `queueSpawnFx`'s rows), held for the event behind it.  Gold
-- only: no other referee drags a monster out.
function M:noteSendLine(msg, from, to)
  self.sendHeld = nil
  if self:generation() ~= 2 or type(msg.text) ~= "string" then return end
  if not (from and to and to >= from) then return end
  local row = self.lines[#self.lines]
  if not (type(row) == "table" and row.spawnfx ~= nil) then return end
  local pages = {}
  for i = from, to do
    if type(self.lines[i]) ~= "string" then return end
    pages[#pages + 1] = self.lines[i]
  end
  self.sendHeld = { species = msg.text, pages = pages, row = row }
end

-- Takes a held send-out's pages back off the queue: found behind the arrival
-- row they were queued ahead of (by identity, so a page string said elsewhere
-- is never touched), skipping the ball's row between.  A page already shown
-- is left -- the queue had moved past it.
function M:dropSendLine(held)
  local lines = self.lines
  if type(held) ~= "table" or type(lines) ~= "table" or held.row == nil then return false end
  local at = nil
  for i = #lines, 1, -1 do
    if lines[i] == held.row then at = i; break end
  end
  if not at then return false end
  local j = at - 1
  while type(lines[j]) == "table" and lines[j].sendball ~= nil do j = j - 1 end
  local dropped = false
  for k = #held.pages, 1, -1 do
    if j < 1 or lines[j] ~= held.pages[k] then break end
    table.remove(lines, j)
    j = j - 1
    dropped = true
  end
  return dropped
end

-- Who is on the other side, in the words the engine's own battle uses for a
-- trainer: the record's `name` (src/battle/BattleState.lua's `self.trainer.name
-- or self.opponentName`, src/ui/gen2/BattleState.lua's `battle.trainer.name`)
-- -- Gold's "YOUNGSTER JOEY", Red's class name -- whole.  `peerName` is the
-- referee's seat label, a class id cut to Wire.label's length (SoloBattle
-- `foeName`), or the peer's own name in a fight between players, which is
-- what is said when there is no trainer record.  Red and Gold: a Gen 3 screen
-- is handed its label whole (SoloBattle.gen3FoeLabel), and its record's
-- `name` is the trainer's alone.
function M:foeTrainerName()
  local trainer = self.trainer
  if self:generation() ~= 3 and type(trainer) == "table"
     and type(trainer.name) == "string" and trainer.name ~= "" then
    return trainer.name
  end
  return tostring(self.peerName or "?")
end

-- ------- a mon that would not obey (contract K3)
--
-- The cart's line for each outcome of the engine's `disobedient`
-- (battle/engine.lua:1291, pret IsMonDisobedient; docs/plans/gen3-battle-sheet.md
-- §7.2.1), keyed by the `obey` event's token (Wire.OBEY_TOKENS3).  The four
-- loaf lines are pret gInobedientStringIds.  `hits_itself` opens with the same
-- line as the `wont_obey` loaf (BattleScript_IgnoresAndHitsItself prints
-- STRINGID_PKMNWONTOBEY); its second line, STRINGID_ITHURTCONFUSION, and the
-- nap's STRINGID_PKMNFELLASLEEP are the referee's own `msg`s after it, said
-- the way every confusion self-hit and every sleep is.
M.OBEY_STRINGS3 = {
  ignores_asleep     = "STRINGID_PKMNIGNORESASLEEP",
  uses_random_move   = "STRINGID_PKMNIGNOREDORDERS",
  falls_asleep       = "STRINGID_PKMNBEGANTONAP",
  hits_itself        = "STRINGID_PKMNWONTOBEY",
  loafing            = "STRINGID_PKMNLOAFING",
  wont_obey          = "STRINGID_PKMNWONTOBEY",
  turned_away        = "STRINGID_PKMNTURNEDAWAY",
  pretend_not_notice = "STRINGID_PKMNPRETENDNOTNOTICE",
}

-- That line for a mon on the player's side, in the player's own text pack.
--
-- The referee narrates every outcome in a sentence of its own English right
-- behind the `obey` event (Move.lua Bm:_obeyLine), and that sentence is the
-- fallback rather than the line: the cart prints these from its own string
-- table -- the engine says them with sayId and `{ atk = user }` -- so the
-- player reads them in their cart's words and line breaks.  Only ever the
-- player's side (pret IsMonDisobedient returns 0 for B_SIDE_OPPONENT), so the
-- mon is named without a prefix (battle_text.lua withPrefix, `side`
-- "player").  nil for a token with no line, a seat with no name, or no text
-- pack -- and the caller then lets the referee's sentence through instead.
function M.obeyText3(token, name)
  local id = type(token) == "string" and M.OBEY_STRINGS3[token] or nil
  if not id or type(name) ~= "string" or name == "" then return nil end
  return Gen3.battleText(id, { atk = { side = "player", name = name } })
end

-- The `obey` event: the cart's line in place of the referee's sentence.
--
-- No sight goes with it -- the engine plays no animation for a disobedient mon
-- (Engine.disobedient only says its lines; a nap's sleep is the `status`
-- event that follows) -- so the whole of it is the one line.  Named after the
-- seat's occupant as the referee sees it, which is the parked arrival when one
-- is waiting (`noteSlot`).  True when the line went into the queue: the `msg`
-- immediately behind it is then the same outcome in the referee's words and
-- is not said (`onEvent`).
function M:sayObey3(msg)
  if self:generation() ~= 3 then return false end
  if sideOfSlot(msg.slot) ~= (self.mySide or "a") then return false end
  local seat = msg.slot ~= nil and self.slots[msg.slot] or nil
  local on = seat and (seat.pending or seat)
  local line = M.obeyText3(msg.text, on and on.species)
  if not line then return false end
  self:say(line)
  return true
end

-- One thing to draw, in order.
--
-- `seq` is what makes the stream a stream: an event whose sequence is one this
-- side has already passed is a duplicate and is dropped, and a jump forward is
-- counted rather than refused.  Refusing the jump would leave the screen
-- waiting on a message that is not coming; counting it means the gap is
-- visible in a log if a hub really is losing messages, while the fight -- whose
-- state lives on the intermediator anyway -- carries on from what did arrive.
function M:onEvent(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end
  if msg.seq <= self.seq then return end
  if msg.seq > self.seq + 1 and self.seq > 0 then
    self.gaps = self.gaps + 1
  end
  self.seq = msg.seq

  if self.phase == "setup" then self.phase = "play" end

  local kind = msg.t
  -- A Gold send-out's line, held for the event behind it (`noteSendLine`):
  -- a ROAR / WHIRLWIND drag-out says "<MON> was dragged out!" there instead.
  -- The `moves` a send-out may state for the monster that left rides between
  -- the two and is no answer.
  local heldSend = self.sendHeld
  if heldSend and kind ~= "moves" then self.sendHeld = nil end
  if heldSend and kind == "msg" and M.draggedOutLine(msg.text, heldSend.species) then
    self:dropSendLine(heldSend)
  end
  -- A foe's sleep clip held behind its line (`M.viewerAnim`) goes on the
  -- queue ahead of anything that is not that line.
  if kind ~= "msg" then self:flushAnimBehind() end
  -- An `obey` this screen phrased in the cart's words owns exactly the next
  -- event -- the referee's own sentence for it, which it always emits straight
  -- behind (Move.lua Bm:_obeyLine) -- and nothing after.  Matched on `seq` so a
  -- lossy stream that dropped that sentence cannot swallow the line after it.
  local obeyed = self.obeyed3
  self.obeyed3 = nil
  -- Gen 3 prices a knockout whole (Exp3): the `exp` events of one faint are
  -- banked as they arrive and paid the moment anything else follows them.
  if kind ~= "exp" and self.expBatch then self:flushExp3() end
  if kind == "msg" then
    -- Gold's weather has no event of its own: the referee states it in the
    -- cart's lines (M.weatherOfLine2), and the sky follows the line that says
    -- so -- queued ahead of it, as Gen 3's `weather` row is.
    local sky = nil
    if self:generation() == 2 then sky = M.weatherOfLine2(msg.text) end
    if sky ~= nil then
      self.lines[#self.lines + 1] = { stateRow = "weather", value = sky }
    end
    if not (obeyed and msg.seq == obeyed + 1) then self:say(msg.text) end
    self:flushAnimBehind()
    self:noteBideLine(msg.text, msg.seq)
    -- Our monster's Disable, as the referee says it (`noteDisableLine`), and
    -- Gold's FOCUS ENERGY / MIST / BATON PASS for the item bits (`noteItemFlags2`).
    self:noteDisableLine(msg.text)
    self:noteItemFlags2(msg.text)
    -- The referee has narrated an escape itself (M.escapeLine): the ending
    -- adds no second one (`finish`).
    if M.escapeLine(msg.text) then self.escapeSaid = true end

  elseif kind == "anim" then
    -- Whose move the next used line is (`noteBideAnim`).
    self:noteBideAnim(msg)
    -- Queued with the message stream so the flash lands in referee order.
    -- `amount` is shake count on SHAKE_ANIM; ball id is stashed from `item`.
    -- A Red / Gold status animation is this viewer's variant (`M.viewerAnim`), and
    -- the arena wears it as the condition's look (Vfx.forStatusAnim); a
    -- foe's sleep clip waits behind the line it follows on this cart.
    if msg.text then
      local mine = msg.slot == self:mySlot()
        or (msg.side ~= nil and msg.side == self.mySide)
      local anim, behind = M.viewerAnim(msg.text, mine)
      local rows = { {
        anim = anim, slot = msg.slot, side = msg.side, amount = msg.amount,
      } }
      local seat = msg.slot ~= nil and self.slots[msg.slot] or nil
      local look = self:usesBattlefield()
        and Vfx.forStatusAnim(anim, seat and seat.status) or nil
      if look then rows[#rows + 1] = { vfxrow = look, slot = msg.slot } end
      if behind then
        self.animBehind = rows
      else
        for _, row in ipairs(rows) do self.lines[#self.lines + 1] = row end
      end
    end

  elseif kind == "switch" then
    -- Nothing. The referee emits `switch` and `send` as a *pair* for the same
    -- arrival -- voluntary switches and forced post-faint replacements alike
    -- (`_resolveSwitches`, src/BattleSim/Turn.lua:1432, mirrored in
    -- server/lib/battle/Turn.js) -- and both carry the same seat, the same
    -- species and the same `mon` stamp. Running the arrival branch for both
    -- fielded the newcomer twice: two send lines printed one after the other
    -- and two arrival chains queued, the first of them bursting over whoever
    -- was still standing on the seat. `send` is the one place a seat's
    -- occupant changes here, exactly as it is in CoopBattle's twin
    -- (src/CoopBattle.lua:8062).

  elseif kind == "send" then
    -- **The referee says what the bar is out of** (`maxHp`, PROTOCOL 24), and
    -- that is the whole of what a seat's maximum is now taken from.  Before
    -- it, an event carried current HP and nothing else, so the largest value
    -- ever seen on the seat had to stand in for the maximum -- true only for a
    -- monster that walks out whole, and the reason one that walked out hurt
    -- drew a full bar over a number that was not its maximum.  `noteSlot`
    -- keeps that reading as the fallback for a stream that states none.
    self:noteSlot(msg)
    -- Gen 3: an AMULET COIN walking on doubles this fight's Pay Day coins
    -- (the cart's switch-in item check; see `noteAmulet3`).  Gold's doubles
    -- the trainer's prize the same way (`noteAmulet2`).
    if self:generation() == 3 then
      self:noteAmulet3(msg)
    elseif self:generation() == 2 then
      self:noteAmulet2(msg)
    end
    -- Parked behind somebody still finishing their exit (`noteSlot`): the seat
    -- below is still *theirs*, so everything that describes what is drawn on it
    -- -- the level pill, the pic, the exp clocks -- is deferred to the swap
    -- (`arriveOnSeat`, called from `applySwap`). Everything that describes the
    -- *rules* -- which sheet is out, whether a replacement is still owed --
    -- stays here, at parse, because the referee is already asking about it.
    local parked = (self.slots[msg.slot] or {}).pending ~= nil
    -- The solicitation this send answers is over -- for whichever seat it was.
    -- Cleared on the *event* rather than only on the slot-less `turn` behind
    -- it, because the referee can answer for a player who ran out of time and
    -- because the band's hold line is about a seat that is empty: the moment
    -- the referee says it is filled, the line stops being true. (`mustReplace`
    -- below is the same clear for our own seat's picker, and has always been.)
    if self.replaceWait ~= nil and self.replaceWait == msg.slot then
      self.replaceWait = nil
    end
    -- The foe's newcomer: which of its sheets is out, and none of the last
    -- one's TRANSFORM / MIMIC list -- what a Red MIMIC pick lists
    -- (`foeMoveList`).
    if msg.slot == self:foeSlot() then
      self.foeMon = tonumber(msg.mon)
      self.foeMoves = nil
    end
    -- New mon on our seat drops any Transform/Mimic overlay until the
    -- referee publishes another `moves` list for it -- and any Bide.
    if msg.slot == self:mySlot() then
      self.liveMoves = nil
      self.bideFiled, self.bideStoring, self.bideLocked = nil, nil, nil
      self.bideOn1 = nil
      -- ...and its Disable (`noteDisableLine`): a newcomer has none.
      self.disabledMove = nil
      -- ...and Gold's item bits, unless a BATON PASS carried them over
      -- (`noteItemFlags2`).
      self.itemFlags2 = self.itemFlags2Passed
      self.itemFlags2Passed = nil
      self.mustReplace = false
      if self.replaceOnly then
        self.replaceOnly = false
        if self.phase == "switch" then self.phase = "play" end
      end
      -- ...and the exp clocks go with it. They describe the monster that was
      -- standing here, and a fraction left behind would be the departing
      -- monster's progress drawn under the newcomer's name until the next
      -- award. Cleared rather than recomputed: nil is what `seedExpClock`
      -- reads as "ask again", and the answer it wants comes off `self.active`,
      -- which `trackActive` has not updated yet this far up the branch.
      local slot = self.slots[msg.slot]
      if slot and not parked then
        slot.shownExpFrac = nil
        slot.shownLevel = nil
      end
      -- A crawl already running on this seat goes too. Events arrive off the
      -- wire while the queue is held, so a send *can* land mid-fill, and a
      -- fill that kept stepping would write the departed monster's target
      -- straight back over the clocks just cleared. The queued-row case is
      -- caught by `startExpFill`'s occupant check; this is the live one.
      --
      -- Not while an arrival is parked: the monster the strip is filling for is
      -- still the one on the seat, and the fill is one of the rows the swap is
      -- waiting behind. `arriveOnSeat` clears the clocks when it lands.
      if not parked and self.expFilling and self.expFilling.slot == msg.slot then
        self.expFilling = nil
      end
    end
    -- The sentence comes FIRST, and the arrival is queued behind it.
    --
    -- A trainer says who they are sending out and *then* throws: the line, the
    -- ball, the burst, the monster. Queued the other way round -- which is what
    -- this did until round 8 -- the pop took no dwell at all, so the monster
    -- appeared and the sentence introducing it printed one tick later over a
    -- monster already standing there. Only the two queue appends move; the
    -- seat record still follows the referee at parse (`noteSlot` above), which
    -- is what every rule on this screen is read from.
    self.lines = self.lines or {}
    local lineFrom = #self.lines + 1
    if msg.text then
      if msg.slot ~= self:mySlot() then
        -- A wild POKeMON is nobody's send-out: the cart's "Wild X\nappeared!"
        -- (`onReady`) is its whole introduction, on both carts.  A trainer's --
        -- or the other player's -- is the cart's own line (M.sentOutPages).
        if not (self.mode == "wild" and self:generation() ~= 3) then
          for _, page in ipairs(M.sentOutPages(self:foeTrainerName(), msg.text,
              self:generation())) do
            self:say(page)
          end
        end
        if not parked then self:refreshSlotSprite(msg.slot, false) end
      else
        self:say(("Go! %s!"):format(msg.text))
        self:trackActive(msg.text, msg)
        if not parked then self:arriveOnSeat(msg.slot, true) end
      end
    end
    local lineTo = #self.lines
    -- ...and then the arrival itself: the throw, and the burst it comes out of
    -- (`queueSpawnFx`). Queued, like every other effect, so it plays where the
    -- stream put it rather than the instant the packet was parsed.
    self:queueSpawnFx(msg.slot, msg.side)
    self:noteSendLine(msg, lineFrom, lineTo)

  elseif kind == "damage" or kind == "drain" then
    -- Truth first, then the bar. `syncMineHp` keeps the party sheet on the
    -- referee's number -- partyRows / mustReplace read it and must never see
    -- a display clock.
    self:noteSlot(msg)
    self:syncMineHp(msg)
    -- The flash and the field's nudge are not emitted here: a resolved turn
    -- arrives as one batch, so both seats would jolt in the same frame, ahead
    -- of the text that explains either. `startDrain` fires them when the bar
    -- this row queued actually starts falling.
    self:queueDrain(msg.slot, msg.status)

  elseif kind == "faint" then
    local slot = self:noteSlot(msg)
    -- Whoever the referee just knocked down, which is the parked arrival when
    -- one is waiting: a monster switched in and KO'd inside the same batch is
    -- down before its own `spawnfx` row has played, and zeroing the seat there
    -- would put its knockout on the monster still walking off. `noteSlot` has
    -- already routed the number; this is the belt-and-braces beside it, routed
    -- the same way.
    local down = slot and (slot.pending or slot) or nil
    if down then down.hp = 0 end
    if msg.slot == self:mySlot() then
      local mon = self.mine and self.mine[self.active]
      if mon then mon.hp = 0 end
      -- The Transform / Mimic overlay ends with the monster wearing it: both
      -- referees give a fallen monster its own list back at the faint
      -- (BattleSim Effects.untransform, BattleSim2 `_clearSubstatus` -- the
      -- cart's party struct is what LoadBattleMonFromParty / InitBattleMon
      -- reads next).  Dropped at parse, as the send-out drops it, so a
      -- `moves` the referee states for this party slot behind the faint --
      -- Gold's party PP a MYSTERYBERRY restored under Transform, which it
      -- cannot send through the overlay -- lands on the sheet (`syncMinePp`)
      -- rather than becoming a new overlay for a monster that is down.  Red
      -- and Gold only: a Gen 3 screen still names a copied move's type off
      -- the overlay (`gen3MoveRow`) for rows queued ahead of the faint, and
      -- its send-out drops it as before.
      if self:generation() ~= 3 then self.liveMoves = nil end
      self.bideFiled, self.bideStoring, self.bideLocked = nil, nil, nil
      self.bideOn1 = nil
      -- Authoritative: hub/sim sets amount=1 when a living bench remains.
      -- Absent amount (older stream) falls back to local party HP.
      if msg.amount == 1 then
        self.mustReplace = true
      elseif msg.amount ~= nil then
        self.mustReplace = false
      else
        local hasBench = false
        for _, m in ipairs(self.mine or {}) do
          if (m.hp or 0) > 0 then hasBench = true; break end
        end
        self.mustReplace = hasBench
      end
    end
    -- Arena order, which is the engine's: the bar finishes falling, then the
    -- monster sinks, and only then does the line print. Both rows block the
    -- queue while they play; neither exists on the classic path, where the
    -- faint line still comes straight after the event.
    self:queueDrain(msg.slot)
    self:queueFaintFx(msg.slot)
    if msg.text then self:say(("%s fainted!"):format(msg.text)) end
    -- After the faint line has been read (and any anim still ahead of it in
    -- `lines` has played), drop the pic. Queued behind the say so the KO stays
    -- on screen through the flash + "X fainted!". Stamped with its occupant
    -- for the same reason the drain row is: an auto-replacement batched behind
    -- the KO would otherwise have this row take the newcomer's pic down.
    self.lines[#self.lines + 1] = { clearPic = msg.slot, species = down and down.species }
    -- A knockout on the *other* side is the only thing that can owe this
    -- client experience, so this is where the credit for one is banked. See
    -- the `exp` branch below for what spends it.
    if sideOfSlot(msg.slot) ~= (self.mySide or "a") then
      self.expCredit = (self.expCredit or 0) + EXP_PER_FAINT
      -- ...and exactly one EXP.ALL party pass, however many participants this
      -- knockout ends up paying. The engine runs its second pass once per
      -- `awardExp` call -- once per faint -- not once per participant
      -- (BattleState's `vanillaExpAward`), and from round 6 a single faint can
      -- put six `exp` events on this wire.
      --
      -- A flag, not a counter, and the same three-valued one CoopBattle keeps
      -- (`nil` unmetered / `true` armed / `false` spent): armed by each foe
      -- knockout, spent by the first award that follows it, re-armed by the
      -- next knockout. A tally would have to be *spent* to come back down, and
      -- a knockout that pays this client nothing -- every one of its
      -- participants already fainted, or every share aimed at another seat --
      -- leaves the count standing, so the award after the *following* faint
      -- would run the party pass twice.
      self.expAllCredit = true
    end

  elseif kind == "exp" then
    -- The spoils of the faint just above, and they arrive *after* it for the
    -- same reason the engine awards after `enemyMonFainted`: the bar falls,
    -- the monster sinks, "X fainted!" prints, and only then is anybody paid.
    -- Nothing here reorders that -- the lines this queues go on the back of a
    -- queue those rows are already sitting in.
    --
    -- One event per *alive participant*, so a knockout the whole team took
    -- turns on puts one of these on the wire per monster and every client sees
    -- all of them. Only ours is ours to pay: the referee holds no save file
    -- and this client holds exactly one, so a share aimed at somebody else's
    -- seat is theirs to apply on their own copy. Same own-slot rule the `item`
    -- debit and the faint's bench check run on, a few lines up.
    --
    -- `slot` is still the owning *seat* -- the gate below is unchanged -- and
    -- the new `mon` field says which of that seat's six banks this particular
    -- share. Several events therefore pass the gate for one faint now, where
    -- round 5 let through at most one; see EXP_PER_FAINT.
    --
    -- **Bounded by the knockouts actually seen.** `exp` is the one event on
    -- this wire that writes the save file, and nothing else in the stream
    -- limits how many of them a hub may send -- an unbounded loop of them is a
    -- party levelled to 100 by a server the player merely connected to. The
    -- bound is the referee's own contract rather than a rate limit: a faint
    -- comes before the exp it pays for (`_awardExp` runs off the knockout, in
    -- both halves of the intermediator), so each observed foe knockout banks
    -- credit for the handful of awards it can honestly owe and every award
    -- spends one. A well-behaved hub is never refused; a hostile one gets at
    -- most what the fights it actually narrated were worth. Refused, warned
    -- through the same one-line `warnNoExp`, and never thrown -- an event
    -- handler that throws takes the whole stream with it.
    --
    -- The one honest cost: a hub that genuinely *lost* the faint message (a
    -- counted `gaps` jump above) loses the award with it. That is the same
    -- trade the rest of this handler makes for a dropped event, and it is the
    -- right way round -- a missing knockout should cost one payout, not open
    -- the save file to a stream nobody can account for.
    -- And never in a fight between players (LINK_MODES): no cart pays EXP in
    -- a link battle (pokered GainExperience's `cp LINK_STATE_BATTLING / ret
    -- z`; pokecrystal and Gen 3 reload the party after one), and neither
    -- referee emits any there (their EXP_MODES) -- refused here as well, so
    -- a hub that sent one could not level a party in a spar.
    if msg.slot == self:mySlot() and LINK_MODES[self.mode] then
      self:warnNoExp("the referee paid experience in a fight between players, "
        .. "which no cart does; nothing was banked")
    elseif msg.slot == self:mySlot() then
      if (self.expCredit or 0) <= 0 then
        self:warnNoExp("the referee paid experience with no knockout ahead of "
          .. "it, which is not a payout this client can account for")
      elseif self:generation() == 3 then
        if self:bankExp3(msg) then self.expCredit = self.expCredit - 1 end
      elseif self:gainExp(msg) then
        self.expCredit = self.expCredit - 1
      end
    end

  elseif kind == "status" then
    -- `noteSlot` writes the token, or clears the chip when the event carries
    -- none -- wake, thaw, and every status-heal item travel that way. The
    -- sheet and the save mon stay in step so a party card and the fight after
    -- this one do not keep a condition the referee already lifted.
    --
    -- A `status` naming a party member (`mon`, Gold's HEAL BELL: one per
    -- cured monster, benched ones too) is the seat's chip only when that
    -- member is the one standing there (`standsOn`); the rest is the party's.
    local standing = msg.mon == nil or self:standsOn(msg)
    if standing then self:noteSlot(msg) end
    self:syncMineStatus(msg)
    -- A condition lifting is a sentence rather than a sight: the catalogue
    -- answers nil for the token that is not there, so nothing is filed.
    -- Anchored on the seat that took it, in that condition's colours.
    if standing then
      self:queueVfx(Vfx.forStatus(msg.status)
        or (msg.confused == 1 and Vfx.forStatus("confusion") or nil), msg.slot)
    end

  elseif kind == "stat" then
    -- Arrows on the seat, and the direction comes off the sentence rather than
    -- off `amount` or `stage`: the referee sends the resulting *stage*, not
    -- the change, so the number alone cannot say which way it went (a drop
    -- from +2 lands on +1).  `M.statFell` reads Gen 3's `delta`, then the
    -- sentence, then K10's signed `stage` as the last word.
    local down = M.statFell(msg)
    self:queueVfx(Vfx.forStat(down and -1 or 1), msg.slot)

  elseif kind == "item" then
    -- Debit only once the hub has accepted and resolved the item choice.
    -- Spending on send left a soft-lock when the bag proof refused: phase
    -- "play", item gone, no `chose`.
    if msg.slot == self:mySlot() then
      self:confirmPendingItem(msg.text, msg.amount)
    end
    -- ...and what it looks like, on the seat of whoever opened the bag. Balls
    -- answer nil (`Vfx.forItem`) and are left to the throw chain below, which
    -- already draws the arc, the rocking and the burst -- a second effect over
    -- that would be drawing the same throw twice.
    self:queueVfx(itemVfx(msg.text), msg.slot, msg.slot)
    -- Ball id for AnimPlayer opts on the following toss/shake chain.
    local effect = msg.text and effectsFor(self.game).itemEffect(msg.text)
    if effect and effect.ball then
      self.medBall = msg.text
      -- ...and the same id, kept past the `over` that clears medBall, for the
      -- `ball` field of the caught announcement. Only our own throws: the
      -- catcher is the thrower, and in a co-op fight the last ball on the
      -- wire may have been somebody else's.
      if msg.slot == self:mySlot() then self.caughtBall = msg.text end
    end

  -- ------- Gen 3's seven (C5 §7.2, `obey` K3).  Each is narrated by the
  -- referee's own `msg` beside it; what arrives here is the sight and the
  -- state.
  elseif kind == "ability" then
    -- An ability visibly acted (Intimidate, Drizzle, Levitate...).  The seat
    -- remembers which, and a shine plays on it in the stream's order.
    local slot = msg.slot ~= nil and self.slots[msg.slot] or nil
    if slot then slot.ability = { id = msg.amount, name = msg.text } end
    self:queueVfx(ABILITY_VFX, msg.slot)

  elseif kind == "weather" then
    -- Started (1), continues (2), ended (0).  Applied when its row plays, so
    -- the sky changes under the line that says so rather than at parse.
    local sky = (msg.amount ~= 0) and msg.text or nil
    self.lines[#self.lines + 1] = { stateRow = "weather", value = sky or false }

  elseif kind == "held" and self:generation() == 2 then
    -- Gold's own `held` (contract K3 of docs/plans/gen12-referee-fidelity.md):
    -- `text` is the item's id and `amount` says whether the mon still holds it
    -- -- Leftovers, a berry eaten, a Focus Band, THIEF on either end.  The
    -- referee's own sentence is the `msg` behind it; this is the writeback
    -- (`applyHeld2`) and the look, which Gold names by id like an `item`.
    self:applyHeld2(msg)
    self:queueVfx(itemVfx(msg.text), msg.slot, msg.slot)

  elseif kind == "held" then
    -- A held item acted: Leftovers, a berry, a Focus Band, Thief / Knock Off /
    -- Trick.  `holding` is what the mon holds now, and it is the writeback.
    self:applyHeld(msg)
    self:queueVfx(itemVfx(msg.amount and tostring(msg.amount) or nil), msg.slot, msg.slot)

  elseif kind == "form" then
    -- The battler's picture changed: Castform's form, or Transform's species.
    self.lines[#self.lines + 1] = {
      stateRow = "form", slot = msg.slot, form = msg.amount,
      speciesId = msg.speciesId,
    }

  elseif kind == "sub" then
    self.lines[#self.lines + 1] = { stateRow = "sub", slot = msg.slot, value = msg.amount == 1 }

  elseif kind == "ball" then
    -- One throw, as the arena's ball flow already plays it (TOSS, POOF,
    -- HIDEPIC, SHAKE, and POOF + SHOWPIC on a break-out) -- the rows Gen 1 and
    -- Gen 2's referees emit one by one, stated by Gen 3's in one event.
    self:queueBall3(msg)

  elseif kind == "obey" then
    -- A player's mon disobeyed -- traded and over its badge cap, or a Mew /
    -- Deoxys whose sheet says `unfateful` (K3): the cart's line, and
    -- the referee's sentence behind it is not said twice.  Whatever the
    -- outcome does next -- the called move's stream, the nap's `status`, the
    -- self-hit's line and `damage` -- arrives as its own events and plays as
    -- any other does.
    if self:sayObey3(msg) then self.obeyed3 = msg.seq end

  elseif kind == "turn" then
    -- Held rather than acted on: the lines this turn's events produced are
    -- still being read, and opening the menu over them would take the box the
    -- player is reading out from under them.  update() opens it once the
    -- queue is empty — unless the hub already filed our choice (forced skip /
    -- recharge / trap), in which case answeredTurn keeps the menu closed.
    --
    -- ------- and a `turn` that names a slot is not that turn at all
    --
    -- It is the referee's replacement solicitation (`Battle:_openReplace` in
    -- src/BattleSim/Turn.lua): the seat at that field slot fainted with a bench
    -- left, and the choice window does **not** open until it has answered and
    -- the referee has sent the successor out behind a slot-less `turn`. So the
    -- two readings are told apart here and nowhere else -- everything below
    -- reads `pendingTurn`, and the whole of "no menu yet" is not setting it.
    --
    -- An older referee sends no `slot`, `owed` is nil, and every `turn` opens
    -- the window exactly as it did.
    local owed = msg.slot
    self.replaceWait = owed
    self.answeredTurn = false
    self.passMove = nil
    -- A level-up the referee was told of (contract K9, `syncLevelHp`) is in
    -- its numbers from the next batch on, and this slot-less `turn` closes the
    -- one it came in: the climb stops being added to its packets.
    if owed == nil then
      local mine = self:mySlot()
      local seat = mine ~= nil and self.slots[mine] or nil
      if type(seat) == "table" then seat.levelHpRefereed = nil end
      -- A Bide going on (Gold, `noteBideLine`): the turn just closed said our
      -- monster is storing energy, so this one's FIGHT is `.locked_in`.  Read
      -- afresh every turn -- a turn that did not say so ends it.
      -- Red reads its own (`bideOn1`): a Bide that started and has not been
      -- released or ended since.
      self.bideLocked = (self:generation() == 2 and self.bideFiled == true
        and self.bideStoring == true)
        or (self:generation() == 1 and self.bideOn1 == true)
      self.bideStoring = nil
      self.confusedNow = nil
      -- A call filed last turn said what it called there, or called no BIDE.
      self.callFiled = nil
      -- A BATON PASS that sent nobody out (it failed) carries nothing over.
      self.itemFlags2Passed = nil
    end
    if owed == nil then
      self.pendingTurn = true
    elseif owed == self:mySlot() then
      -- Our own seat: this is the picker the faint already asked for, so it is
      -- opened by the flow that has always opened it -- `mustReplace` +
      -- `replaceOnly` in update(), which waits for the faint's own rows (the
      -- drain, the sink, "X fainted!") to drain before it takes the box. Set
      -- here rather than trusted from the `faint`, because the referee has now
      -- said it out loud: a lossy stream that dropped the faint would otherwise
      -- open the *command* menu over an empty seat, which is the exact thing
      -- this phase exists to make unreachable.
      --
      -- Except on an empty bench, which is not a picker at all -- `partyRows`
      -- would list nothing and `updateSwitch` has no B to leave with, since the
      -- replacement is forced. The referee does not solicit a seat with nothing
      -- to send, so this is a disagreement about our own party; the screen sits
      -- and waits for the referee rather than opening a menu with no way out.
      local hasBench = false
      for _, m in ipairs(self.mine or {}) do
        if (m.hp or 0) > 0 then hasBench = true; break end
      end
      if hasBench then
        self.mustReplace = true
        self.pendingTurn = true
      else
        self.mustReplace = false
        self.pendingTurn = false
        self.replaceWait = nil
      end
    else
      -- Somebody else's decision: no menu, and a line that says whose. Queued
      -- through `say` rather than printed, so it lands **behind** the rows the
      -- faint that caused it already queued -- the bar falling, the monster
      -- sinking, "X fainted!" -- which is the order they happened in. The band
      -- keeps saying it after the line is dismissed, for as long as the seat is
      -- still empty (see `drawModernBand`).
      self.pendingTurn = false
      self:say(("%s is choosing\nwho to send out..."):format(self.peerName))
    end
    -- Hub refused the item (never debited) or spend already landed via `item`.
    self.pendingItem = nil
    self.pendingItemSlot = nil
    -- Keep medBall through the queued toss/shake anims (they drain after turn).

  elseif kind == "over" then
    -- The field is done; the outcome is a separate message and is what this
    -- screen actually ends on.
    self.pendingTurn = false
    self.answeredTurn = false
    self.mustReplace = false
    self.replaceOnly = false
    self.replaceWait = nil
    self.pendingItem = nil
    self.pendingItemSlot = nil
    self.medBall = nil
    self.foePicHidden = nil

  elseif kind == "wait" then
    if msg.text then self:say(("Waiting for\n%s..."):format(msg.text)) end

  elseif kind == "reconnect" then
    -- Their return, or ours after we re-announced: either way the waiting
    -- caption is done.
    self.awaitingReconnect = false
    if msg.text then self:say(("%s is back!"):format(msg.text)) end

  elseif kind == "run" then
    -- Whose side left: an escape this side made is the cart's "Got away
    -- safely!" at the end (`finish`), one the foe made is its own line.
    self.ranSide = msg.side

  elseif kind == "chose" or kind == "unchose" then
    if msg.slot == self:mySlot() then
      if kind == "chose" then
        -- Forced skip / our filed answer: do not open (or keep) the command
        -- menu for a turn the hub has already spent -- nor a BATON PASS
        -- successor still being picked for it.
        self.answeredTurn = true
        self.pendingTurn = false
        self.passMove = nil
        if self.phase == "choose" or self.phase == "move"
           or self.phase == "target" or self.phase == "mimic"
           or self.phase == "item" or self.phase == "item_party"
           or self.phase == "item_move" or self.phase == "switch" then
          self.phase = "play"
        end
      else
        self.answeredTurn = false
        self.pendingItem = nil
        self.pendingItemSlot = nil
      end
    end

  elseif kind == "moves" then
    -- The foe's battle list, when the referee states one: a TRANSFORM or a
    -- MIMIC of theirs (no `mon`), or a list for the monster standing there.
    -- wEnemyMonMoves is what the cart's MIMIC menu lists (`foeMoveList`).
    if msg.slot == self:foeSlot() and type(msg.moves) == "table"
       and (msg.mon == nil or tonumber(msg.mon) == self.foeMon) then
      self.foeMoves = msg.moves
    end
    if msg.slot == self:mySlot() and type(msg.moves) == "table" then
      -- `mon` (0-based party index) is the PP-spend/restore discriminator.
      -- Transform/Mimic omit it -- overlay only, even when the copied ids
      -- match the upload (a mirror match). A present `mon` writes that
      -- sheet unless a transform overlay is up on that monster -- the one
      -- standing here -- in which case the overlay is refreshed so FIGHT
      -- tracks the copied PP.  The overlay is gone once its wearer leaves --
      -- a send-out on this seat and its faint both drop it -- so the party
      -- list a referee states behind either (Gold's MYSTERYBERRY restore
      -- under Transform) writes its sheet; and a benched monster's list is
      -- its sheet's whatever the one standing here wears.
      if msg.mon ~= nil then
        local index = (tonumber(msg.mon) or 0) + 1
        local wearing = self.liveMoves and index == (self.active or 1)
        -- Gold's SKETCH, written home first (M.sketchHome): onto the save
        -- monster behind that sheet and onto the sheet itself, so the spend
        -- below -- and every later one -- matches a list that holds it.
        self:sketchMine(index, wearing and self.liveMoves
          or (self.mine and self.mine[index] and self.mine[index].moves), msg.moves)
        if wearing then
          self.liveMoves = self:overlayRows(msg.moves)
          -- A MIMIC's spends, onto the party's list by slot (M.mimicOverlay /
          -- M.slotPp): Red's mimicked slot pays MIMIC's PP; Gold's never does,
          -- though its other slots still pay theirs.
          if self.liveMovesMimic then
            local sheet = self.mine and self.mine[index]
            M.slotPp(sheet and sheet.moves, msg.moves, self:generation())
          end
        else
          self:syncMinePp(msg.moves, index)
        end
      else
        -- A TRANSFORM or a MIMIC overlay.  Which one decides whether the PP
        -- the referee states for it later is also the party's (a MIMIC's,
        -- `M.mimicOverlay`), so it is told apart here, as it lands.
        local sheet = self.mine and self.mine[self.active or 1]
        local generation = self:generation()
        self.liveMovesMimic = generation ~= 3
          and M.mimicOverlay(self.game, sheet and sheet.moves, msg.moves, generation)
        self.liveMoves = self:overlayRows(msg.moves)
        -- Gold's TRANSFORM lifts the user's own Disable (pokecrystal
        -- BattleCommand_Transform's ResetActorDisable; BattleSim2 Effects).
        -- Red's keeps it, as the Red referee does.
        if generation == 2 and not self.liveMovesMimic then self.disabledMove = nil end
      end
    end

  elseif kind == "team" then
    -- Both sides, and our own is not skipped as redundant: `mine` is the sheets
    -- we uploaded and the referee is the thing that has been fighting with
    -- them, so on the one seat where the two could disagree the referee is
    -- right. Stored raw; `Battlefield.rosterModel` reads the string dialect.
    if msg.slot ~= nil and type(msg.team) == "string" then
      self.teams[msg.slot] = msg.team
    end
  end
end

-- Gold's SKETCH on this screen's own seat (M.sketchHome): the save monster
-- behind sheet `index` takes the sketched move, and the sheet takes the same
-- slot rebuilt off it (moveOf -- the record's power, type and effect, as the
-- opening upload described every move), so the FIGHT list and every later
-- PP spend read the new move.  `prior` is the list this screen showed for
-- that monster -- the overlay it wears, else its sheet.
function M:sketchMine(index, prior, incoming)
  local sheet = self.mine and self.mine[index]
  if type(sheet) ~= "table" or type(sheet.moves) ~= "table" then return nil end
  local save = self:saveMon(index)
  if not save then return nil end
  local wrote = M.sketchHome(self.game, self.mode, prior, incoming, save)
  if not wrote then return nil end
  local data = self.game and self.game.data
  local order = typeOrder(data)
  for _, i in ipairs(wrote) do
    local row = moveOf(data, save.moves[i], order, 2)
    if row and sheet.moves[i] then sheet.moves[i] = row end
  end
  return wrote
end

-- ------- Red's PP byte past the wrap
--
-- pokered keeps a move's PP in one byte: the PP in the low six bits, the PP
-- Ups in the top two (PP_UP_MASK).  DecrementPP's `dec [hl]` and
-- IncrementMovePP's `inc [hl]` step the whole byte (engine/battle/
-- decrement_pp.asm, core.asm), so a slot at 0 PP that pays wraps to 63 PP and
-- one PP Up fewer -- none wraps to three -- and a refund at 63 carries back
-- (the Red referee steps it the same way, BattleSim Turn `stepPp`, wave 5).
-- The referee's `moves` rows state the PP and no PP Ups, so the client reads
-- the borrow off the step it sees -- 0 to 63 is a borrow, 63 to 0 a carry: no
-- Red move reaches 63 any other way (AddBonusPP caps a PP Up's bonus at 7, so
-- the largest maximum is 61) -- and writes the PP Ups beside the PP, so the
-- save holds the byte the cart's party struct holds.  A row that does state
-- its `ppUps` is taken as it is.  `row` is the client's slot (a sheet's or the
-- save's), before its `pp` is overwritten; `incoming` the referee's.
function M.ppByteStep1(row, incoming)
  if type(row) ~= "table" or type(incoming) ~= "table" then return end
  local stated = tonumber(incoming.ppUps)
  if stated then
    row.ppUps = clamp(floor(stated), 0, Wire.PP_UPS_MAX or 3)
    return
  end
  local was, now = tonumber(row.pp), tonumber(incoming.pp)
  local ups = intOr(row.ppUps, 0)
  if was == 0 and now == 63 then
    row.ppUps = (ups + 3) % 4
  elseif was == 63 and now == 0 then
    row.ppUps = (ups + 1) % 4
  end
end

-- What a slot's maximum reads as on the cart: GetMaxPP over the move's base
-- PP and the slot's PP Ups -- pokered PrintMenuItem, pokecrystal / pokegold
-- MoveInfoBox's GetMaxPPOfMove -- nil for a move with no record.  Named for
-- the cart it was written for; Gold's overlay reads it too (`overlayRows`).
function M.redMaxPp(game, row)
  local data = game and game.data
  local def = type(row) == "table" and type(data) == "table"
    and type(data.moves) == "table" and data.moves[row.id] or nil
  if type(def) ~= "table" or tonumber(def.pp) == nil then return nil end
  return M.maxPpOf(def.pp, row.ppUps)
end

-- The list a TRANSFORM or a MIMIC lays over the party's, as this screen
-- shows it.  Red's move menu prints GetMaxPP over the battle struct
-- (pokered PrintMenuItem: BATTLE_MON_DATA, so engine/items/item_effects.asm
-- GetMaxPP reads wBattleMonMoves for the move id and wBattleMonPP's top two
-- bits for the PP Ups), not the referee's working ceiling: a Transform copy
-- holds 5 PP and no PP Ups (transform.asm `.copyPPLoop` writes the whole
-- byte), so it reads "5/<the copied move's base PP>"; a mimicked slot keeps
-- MIMIC's PP byte (MimicEffect writes the move id alone), so it reads the
-- mimicked move's base with MIMIC's PP Ups.  The Red referee states each
-- row's `ppUps` (BattleSim Turn `_emitMoves`), so the cart's number is
-- `redMaxPp` over the row; a row with no move record keeps the stated
-- maximum.  Copies, so the event's own rows are left as they came.
--
-- Gold's the same way: pokecrystal / pokegold MoveInfoBox prints the PP
-- under the cursor over GetMaxPPOfMove with wMonType WILDMON
-- (engine/items/item_effects.asm), which reads the move id out of
-- wBattleMonMoves and the PP Ups out of wBattleMonPP's PP_UP_MASK bits
-- (`wEnemyMonPP - wEnemyMonMoves` from wBattleMonMoves) and runs
-- ComputeMaxPP over them -- the battle struct, not the party's.  A TRANSFORM
-- copy is 5 PP with the PP-Up bits clear (transform.asm `.pp_loop` writes the
-- whole byte; a copied SKETCH 1) and a MIMIC'd slot likewise (mimic.asm
-- `ld [hl], 5`), so the cart reads "5/<the copied move's base PP>" where the
-- Gold referee states its working ceiling, 5 (BattleSim2 Effects MIMIC_PP /
-- TRANSFORM_PP); every slot it did not touch keeps its own PP Ups, which the
-- referee's rows state (K8, BattleSim2 Turn `_emitMoves`).  Gen 3 keeps the
-- list as stated (its rows carry the cart's own ceiling).
function M:overlayRows(moves)
  local generation = self:generation()
  if (generation ~= 1 and generation ~= 2) or type(moves) ~= "table" then return moves end
  local out = {}
  for i, row in ipairs(moves) do
    if type(row) == "table" then
      local copy = {}
      for k, v in pairs(row) do copy[k] = v end
      copy.maxPp = M.redMaxPp(self.game, row) or row.maxPp
      out[i] = copy
    else
      out[i] = row
    end
  end
  return out
end

-- Keep `mine[index].moves[].pp` in step with the referee so the FIGHT menu
-- (bandMoveRows / pickMove) shows the live count. Same-length, same-ids
-- only: a mismatched list is not the real sheet.  Red's PP Ups follow the
-- byte (`M.ppByteStep1`), and its maximum is the cart's GetMaxPP over them
-- (`M.redMaxPp`) -- a slot past its wrap reads 63 over that, never 63/63.
function M:syncMinePp(moves, index)
  local mon = self.mine and self.mine[index or self.active]
  if not (type(mon) == "table" and type(mon.moves) == "table") then return false end
  if type(moves) ~= "table" or #moves ~= #mon.moves then return false end
  for i, slot in ipairs(mon.moves) do
    local incoming = moves[i]
    if not (type(incoming) == "table" and incoming.id == slot.id) then
      return false
    end
  end
  local red = self:generation() == 1
  for i, slot in ipairs(mon.moves) do
    local incoming = moves[i]
    if red then M.ppByteStep1(slot, incoming) end
    local pp = tonumber(incoming.pp)
    if pp then slot.pp = pp end
    local maxPp = tonumber(incoming.maxPp)
    if red then maxPp = M.redMaxPp(self.game, slot) or maxPp end
    if maxPp then slot.maxPp = maxPp end
  end
  return true
end

-- Which way a `stat` event moved the stat, for the arrows on the seat: true
-- for a drop.  Shared with src/CoopBattle.lua's twin reading.
--
--   * Gen 3 states the change itself (`delta`, C5 §7.1), which beats any
--     reading of a sentence.
--   * Otherwise the referee's sentence says it, in its cart's words (wave 5):
--     Red's StatModifierUpEffect / StatModifierDownEffect "rose!" / "greatly
--     rose!" and "fell!" / "greatly fell!" (pokered data/text/text_6.asm
--     _GreatlyRoseText, _FellText...), Gold's StatUpMessage / StatDownMessage
--     "went up!" / "went way up!" and "fell!" / "sharply fell!" (pokecrystal
--     data/text/common_2.asm, BattleSim2 Effects.statUpLine / statDownLine),
--     and a vitamin's "rose" on either.
--   * A sentence naming neither (or none at all) falls back on the signed
--     stage the stat now sits at (contract K10 of docs/plans/
--     gen12-referee-gaps-fix.md: `stage`, -6..6, on Gen 1 / Gen 2 since the
--     wire's unsigned `amount` could never carry a stage below zero).  The
--     stage is where the stat *is*, not which way it went, so it only breaks
--     a tie the words left -- below zero reads as a drop.
--
-- No Gen 1 / Gen 2 screen keeps a stage table off these events (the plates
-- show no stage), so the arrows are the whole of what `stage` feeds here.
function M.statFell(msg)
  if type(msg) ~= "table" then return false end
  local delta = tonumber(msg.delta)
  if delta then return delta < 0 end
  local text = type(msg.text) == "string" and msg.text:lower() or ""
  if text:find("fell", 1, true) then return true end
  if text:find("rose", 1, true) or text:find("went up", 1, true)
     or text:find("went way up", 1, true) then
    return false
  end
  local stage = tonumber(msg.stage)
  return stage ~= nil and stage < 0
end

-- How much HP a seat's plate holds above what the referee's packets state:
-- a level-up's climb the stream has not caught up with (`syncLevelHp` --
-- `levelHpGrown` for a growth the referee never hears of, `levelHpRefereed`
-- for one it was told of and holds from its next batch), never negative.
function M.levelHpOwed(slot)
  if type(slot) ~= "table" then return 0 end
  local grown = (tonumber(slot.levelHpGrown) or 0) + (tonumber(slot.levelHpRefereed) or 0)
  if grown ~= grown or grown < 0 then return 0 end
  return grown
end

-- Keep `mine[].hp` in step with field damage so partyRows / mustReplace see
-- the same numbers the referee just applied.
function M:syncMineHp(msg)
  if msg.slot ~= self:mySlot() then return end
  local mon = self.mine and self.mine[self.active]
  if not mon then return end
  local slot = self.slots[msg.slot]
  local grown = M.levelHpOwed(slot)
  if msg.hp ~= nil then
    local hp = msg.hp
    if hp > 0 and grown > 0 then hp = hp + grown end
    mon.hp = hp
  elseif msg.amount ~= nil and msg.t == "damage" then
    mon.hp = max(0, (mon.hp or 0) - msg.amount)
  end
end

-- What a Red or Gold party monster's status byte can hold for the referee's
-- condition: TOX is PSN.  Badly poisoned is a battle-only flag on both carts
-- -- pokered's BADLY_POISONED is a wPlayerBattleStatus3 bit beside the PSN bit
-- of wBattleMonStatus, pokecrystal's SUBSTATUS_TOXIC a wPlayerSubStatus5 bit
-- -- and the party struct gets wBattleMonStatus alone, at a switch-out and as
-- the fight ends (pokered ReadPlayerMonCurHPAndStatus, pokecrystal
-- UpdateBattleMonInParty), so a TOXIC leaves every fight as plain poison.  A
-- save left holding TOX was a token neither engine's party code knows, and
-- the next fight's upload (Wire.STATUSES carries it) started that monster
-- badly poisoned, its counter at 1.  Shared with src/CoopBattle.lua and
-- src/SoloBattle.lua, the other two writers.  Gen 3 keeps TOX: its status
-- word is the party's own (STATUS1_TOXIC_POISON).
function M.partyStatus12(status, generation)
  if status == "TOX" and (generation == 1 or generation == 2) then return "PSN" end
  return status
end

-- Is the party member a `status` event names (`mon`, 0-based into the
-- uploaded party) the one standing on its seat?  Ours by the sheet index
-- this screen fields (`active`), the foe's by the one its last send-out
-- named (`foeMon`); a seat this screen tracks no index for answers yes.
function M:standsOn(msg)
  local at = tonumber(msg and msg.mon)
  if not at then return true end
  at = floor(at)
  if msg.slot == self:mySlot() then return at + 1 == (self.active or 1) end
  if msg.slot == self:foeSlot() and self.foeMon ~= nil then return at == self.foeMon end
  return true
end

-- Keep the fight sheet -- and the save mon behind it -- on the referee's
-- condition. `noteSlot` owns the seat chip; this is the party copy the
-- POKéMON panel and the next fight both read. A `status` event with no
-- token is a cure, the same contract the seat uses.
function M:syncMineStatus(msg)
  if msg.t ~= "status" then return end
  if msg.slot ~= self:mySlot() then return end
  -- Confusion is fight-local; a confused-only event must not write the save
  -- (snap-out would otherwise clear PSN).
  if msg.confused ~= nil and (type(msg.status) ~= "string" or msg.status == "") then
    return
  end
  local status = msg.status
  if type(status) ~= "string" or status == "" then status = nil end
  -- Which of our monsters: the one standing, or the party member the event
  -- names.  Gold's HEAL BELL (pokecrystal BattleCommand_HealBell) zeroes
  -- every wPartyMon status byte of the user's side, PARTY_LENGTH of them --
  -- the benched ones as well as the battle monster's -- and the Gold referee
  -- states each cure with that member's `mon` (BattleSim2 Turn `_healBell`).
  -- A `mon` the uploaded party has no sheet at is a monster this client never
  -- sent, and nothing is written for it (`gainExp`'s rule).
  local index = self.active
  if msg.mon ~= nil then
    index = self:paidSheetIndex(msg)
    if type(self.mine) == "table" and #self.mine > 0 and self.mine[index] == nil then
      return
    end
  end
  local sheet = self.mine and self.mine[index]
  if sheet then sheet.status = status end
  -- A link fight leaves the save alone, on every generation (M.LINK_MODES,
  -- wave 5 -- Red and Gold used to write it): no cart lets a Cable Club
  -- battle's status outlast it.  Gold reloads the party it saved before the
  -- Colosseum (pokecrystal engine/link/link.asm: `farcall LoadPokemonData`
  -- after StartBattle), Gen 3 likewise (pokefirered cable_club.c
  -- CB2_ReturnFromCableClubBattle -> LoadPlayerParty), and Red heals it
  -- (pokered engine/link/cable_club.asm CableClub_DoBattleOrTradeAgain:
  -- `predef HealParty` after the battle) -- so a paralysis from a spar is
  -- gone on the way out, the rule applyHeld keeps for items.  The fight's own
  -- sheet above still follows the referee.
  if LINK_MODES[self.mode] then return end
  local save = self:saveMon(index)
  if save then
    -- Red / Gold: the party holds PSN for a TOXIC (`M.partyStatus12`).  The
    -- sheet above keeps the referee's TOX, which is the fight's own.
    save.status = M.partyStatus12(status, self:generation())
    -- A Gen 3 mon keeps its sleep counter beside the token; a cure takes it.
    if status ~= "SLP" and save.sleep ~= nil then save.sleep = nil end
  end
end

-- ------- exp
--
-- **Two monsters, and telling them apart is the whole of this section.**
-- `self.mine[self.active]` is a *wire sheet* -- what the referee is fighting
-- with, carrying level, HP and moves and no exp at all -- and it is thrown
-- away with the battle. The monster that keeps what it earns is the one in
-- `game.save.party`, and that is the only one written to here.
--
-- The referee sends no amount, and cannot: the hub holds no species table (no
-- ROM bytes on a hub, the legal floor), so `baseExp` is a number it has never
-- seen. It states facts -- who fell, at what level, split how many ways -- and
-- each client prices them with the engine's own `Experience.apply`, which is
-- also what divides the stat exp, recomputes the stats and decides whether a
-- level was crossed. A hub-computed number would skip all three, and would be
-- a hub deciding how strong somebody's party gets.
--
-- Applied here, at event receipt, rather than at `finish`: a mediated battle
-- has several ends that never reach finish (a dropped hub, a referee timeout,
-- the player closing the game), and exp banked only at the end would be exp
-- lost on every one of them. Same precedent as the vitamin writeback above --
-- fight-local sheet mutation is the referee's job, permanence is the client's.

-- Where the monster behind a fight sheet actually lives in the save file.
--
-- **The drift this closes, stated where it was assumed:** `mine[i]` is *not*
-- `save.party[i]`. `snapshotMons` skips a monster it cannot describe (no
-- stats, no species, no moves; see the comment on it), and one skip shifts
-- every index after it -- which would be exp paid to the wrong party member,
-- and Stat Exp written onto the wrong one at the vitamin writeback below.
-- The snapshot already stamps the party position it cut each sheet from
-- (`slot`, 0-based, `M.snapshotMons`), so both sites resolve through here
-- rather than through the array index. A sheet with no `slot` -- an older
-- upload, or a hand-built one in a test -- falls back to the array index,
-- which is exactly the behaviour this replaces.
function M:savePartyIndex(sheetIndex)
  local index = sheetIndex or self.active or 1
  local sheet = self.mine and self.mine[index]
  local slot = sheet and tonumber(sheet.slot)
  if not slot then return index end
  slot = math.floor(slot) + 1
  if slot < 1 then return index end
  return slot
end

-- The save-file monster behind a fight sheet index.
function M:saveMon(index)
  local party = savePartyOf(self.game)
  local mon = party and party[self:savePartyIndex(index)]
  if type(mon) ~= "table" then return nil end
  return mon
end

-- Which uploaded sheet an `exp` event names, as an index into `mine`.
--
-- **The referee counts in the party it was given.** `mon` is 0-based over the
-- monsters this client actually uploaded (`snapshotParty` order, which is what
-- the hub holds and the only party it has ever seen), so +1 lands on the sheet
-- and `savePartyIndex` turns that into the save slot -- the same two-step every
-- other party-addressed field on this wire takes (`pendingItemSlot`, the
-- vitamin writeback). Doing it in one step would pay `save.party[mon+1]`, which
-- is a different monster the moment `snapshotMons` skipped one.
--
-- **Absent is the round-5 referee**, which paid whoever was standing at the
-- faint and had no field to say so with. Falling back to the active sheet is
-- exactly what this did before `mon` existed, so a PROTOCOL 21 hub that never
-- learned the field keeps paying the same monster it always did.
function M:paidSheetIndex(msg)
  local raw = msg and tonumber(msg.mon)
  if not raw or raw ~= raw then return self.active or 1 end
  local index = floor(raw) + 1
  if index < 1 then return self.active or 1 end
  return index
end

-- Warn once per screen rather than once per faint: a build with no Experience
-- module loses exp on every knockout, and forty identical lines in the log
-- describe the same single fact.
function M:warnNoExp(why)
  if self.expWarned then return false end
  self.expWarned = true
  mod.log:warn("no experience could be awarded in this battle (%s), so the "
    .. "fight still plays out but nothing levels up -- report this with the "
    .. "game version; levelling still works in ordinary battles", why)
  return true
end

-- Pay the monster of this client's the referee just named, for a faint it just
-- narrated.
--
-- **Not necessarily the one on the field.** Vanilla pays every monster that was
-- ever in against the fallen foe and is still alive, benched included, and from
-- round 6 the referee says which by name (`mon`). So this resolves a *target*
-- first and asks afterwards whether that target happens to be the one standing
-- -- because only the standing one has a bar on screen to fill.
function M:gainExp(msg)
  local data = self.game and self.game.data
  local paidIndex = self:paidSheetIndex(msg)
  -- A `mon` the uploaded party has no sheet for is a referee talking about a
  -- monster this client never sent it. Refused rather than resolved through
  -- the array-index fallback, which would quietly pay whichever save member
  -- happened to sit at that number. Only checked when there *is* an uploaded
  -- party: a screen driven straight from a harness has none, and its indices
  -- are save indices by definition.
  local mine = self.mine
  if msg and msg.mon ~= nil and type(mine) == "table" and #mine > 0
     and mine[paidIndex] == nil then
    self:warnNoExp("the referee paid a party member this client never uploaded")
    return false
  end
  local mon = self:saveMon(paidIndex)
  if not (type(data) == "table" and mon) then
    self:warnNoExp("this client holds no save party to pay")
    return false
  end

  -- **Wire tolerance.** An older or more lenient hub can send this event with
  -- any of the three facts missing, and every one of them is load-bearing: no
  -- species is no `baseExp` and no stat exp, no level is no formula, no
  -- participant count is a division by an unknown. There is no honest default
  -- for any of them -- inventing one pays a number nobody refereed -- so the
  -- award is skipped and said so, and the fight carries on. Never thrown: an
  -- event handler that throws takes the whole stream with it.
  --
  -- `speciesId` first, for the reason `seatSpeciesKey` gives: `species` is the
  -- name the fight was narrated under, which is the *nickname* when the fallen
  -- monster had one -- and a nickname resolves to no pokedex row, so a
  -- nicknamed foe used to fall for nothing at all. The name stays as the
  -- fallback so a PROTOCOL 21 referee pays exactly what it always did.
  local pokedex = type(data.pokemon) == "table" and data.pokemon or nil
  local id = msg.speciesId
  local key = nil
  if pokedex and type(id) == "string" and id ~= "" and pokedex[id] then
    key = id
  end
  local label = msg.species
  if not key and type(label) == "string" and label ~= "" then
    key = self:speciesKeyFor(label)
  end
  local def = key and pokedex and pokedex[key] or nil
  local level = tonumber(msg.level)
  local participants = tonumber(msg.participants)
  if not (def and level and participants and participants >= 1) then
    self:warnNoExp("the referee's exp event named no species, level or share "
      .. "count this build could read")
    return false
  end
  level = math.max(1, math.floor(level))
  participants = math.max(1, math.floor(participants))

  -- Which generation's formula prices this faint.
  --
  -- The referee's facts are generation-free by construction, and that is the
  -- whole reason a Gen 2 hub needed no new event and no PROTOCOL bump to start
  -- paying: "Beta fell at level 20, split two ways" is the same sentence in
  -- both games. What differs is everything downstream of it -- the exp field
  -- (`mon.exp` vs `mon.experience`), the stat-exp block, the item that taxes
  -- the pool (EXP.ALL vs EXP.SHARE) and two extra x1.5 multipliers -- so the
  -- branch is here, once, and both arms answer with the same three values.
  local generation = Gen.generation(self.game)
  local eng = loadEngine()
  if generation == 2 then
    if not Exp2.available() then
      self:warnNoExp("the engine's Gen 2 experience modules are unavailable")
      return false
    end
  elseif not (eng and eng.Experience and eng.Experience.apply) then
    self:warnNoExp("the engine's Experience module is unavailable")
    return false
  end

  -- Wild or trainer, decided from the mode this screen already knows.
  --
  -- **Deliberately not CoopBattle's unconditional `true`.** The trainer x1.5
  -- is a real rule of the formula (experience.asm), and paying it for a
  -- *wild* mediated kill would make the same PIDGEY worth more fought in the
  -- MMO than fought alone -- the kind of divergence a player finds in an
  -- afternoon.
  --
  -- Named as a positive set rather than "anything that is not `wild`", for
  -- two reasons the negative test got wrong: `coop_wild` is a wild fight too
  -- (the referee's own `EXP_MODES` is `wild` / `coop_wild` / `coop_npc`, and
  -- only the last of those has a trainer on the other side), and a screen
  -- whose `mode` never arrived reads as nil -- which under `~= "wild"` paid
  -- the bonus off a fact nobody stated. Unknown now means the smaller,
  -- unearned-nothing payout.
  local isTrainer = TRAINER_MODES[self.mode] or false

  local save = self.game.save
  local inventory = save and save.inventory
  -- EXP.ALL, the way the original splits it: the monster that fought takes
  -- half, and the other half is divided again across the whole living party.
  -- The engine expresses that as a *divisor* rather than a fraction (the base
  -- values are halved in place and the second pass inherits the participant
  -- division), so holding one doubles the divisor on the first pass and the
  -- second pass divides by the party size on top. Verbatim from
  -- BattleState:awardExp's own `vanillaExpAward`, so a mediated wild fight and
  -- a local one pay the same party the same numbers.
  local party = (save and save.party) or {}
  local expAll = generation ~= 2
    and inventory and (tonumber(inventory.EXP_ALL) or 0) > 0

  -- **Gen 2's EXP.SHARE is not Gen 1's EXP.ALL**, and reading it as one would
  -- pay the wrong monsters the wrong amounts in both directions.
  --
  --   * it is a HELD item, not a bag item, so it is found on the party (by
  --     item id, the way `IsAnyMonHoldingExpShare`'s `cp EXP_SHARE` does) and
  --     not in the inventory.
  --   * any living holder halves the pool *once*, up front, for **both**
  --     passes -- it is not a doubled divisor on the first pass.
  --   * the second pass pays the **holders only**, not the whole party, so a
  --     holder that also fought collects twice and a bystander collects
  --     nothing.
  --
  -- The holder list is taken here, before the first pass, because that pass
  -- can level a holder and a list rebuilt afterwards would be a different one.
  local shareHolders = (generation == 2) and Exp2.holders(party) or nil
  local halved = shareHolders ~= nil and #shareHolders > 0

  -- The three fields the award writes through without checking, and the one it
  -- reads. Filled rather than trusted because the award adds the exp *before*
  -- it recomputes the stats: a missing `dvs` or `stats` would throw half way
  -- and leave a monster holding exp it never levelled for -- and the pcall
  -- below would swallow the reason, so the damage would be silent. A save mon
  -- that has no stat block at all is not a save mon this fight uploaded (see
  -- the drift note on `savePartyIndex`), so it is refused rather than invented.
  --
  -- Gen 2 banks its exp on `mon.experience`; `mon.exp` is Gen 1's field and
  -- seeding it on a Gold save would leave a number nothing ever reads.
  local pokedex = (type(data.pokemon) == "table") and data.pokemon or {}
  mon.statExp = mon.statExp or {}
  mon.dvs = mon.dvs or {}
  if generation == 2 then
    mon.experience = mon.experience or 0
  else
    mon.exp = mon.exp or 0
  end
  if type(mon.stats) ~= "table" then
    self:warnNoExp("the party monster this fight is holding has no stat block")
    return false
  end
  -- Max HP before any apply pass. A level raises both numbers on the save
  -- mon; the arena still holds the referee's pre-level pair, so the plate
  -- is told the *delta* after every pass (EXP.ALL included) rather than
  -- copied from the save -- the save is not taking mid-fight damage.
  local oldMax = tonumber(mon.stats.hp)
  -- The fourth thing `apply` reads, and the one this used to look up *after*
  -- the award: recomputing the stats needs the receiving monster's own species
  -- record, so a species this build cannot name is the same half-way throw.
  -- Hoisted above the first `apply` and refused there.
  local myDef = pokedex[mon.species]
  if type(myDef) ~= "table" then
    self:warnNoExp("this build has no species record for the party monster "
      .. "being paid")
    return false
  end

  -- Where the strip is *now*, read before the award lands.
  --
  -- `Experience.apply` mutates `mon.exp` and `mon.level` in place, so once it
  -- has run there is nothing left to work the starting fraction back out of.
  -- That is the whole job of this capture, and its only one: `startExpFill`
  -- starts from the *live* display clock and reaches for `from*` only when
  -- that clock is still nil, precisely so a second award in the same batch
  -- (both foes down in one 2-on-2 turn) begins where the first fill stopped
  -- rather than rewinding under it.
  --
  -- On-field only: the strip on this seat's HUD is the *standing* monster's.
  -- Classic 160×144 now draws the same clock (a 1px bar on the player HUD);
  -- a benched award still has nowhere to crawl. The award still lands and
  -- still persists either way.
  --
  -- **And on-field only, which is the round-6 half of the same gate.** The
  -- strip on this seat's plate is the *standing* monster's -- one bar, one
  -- occupant -- so a benched participant's award has nowhere to draw itself.
  -- Crawling it there anyway would run somebody else's exp across the fighter's
  -- plate and leave the pill on a level the fighter never reached; freezing the
  -- fighter's own clocks to make room would be worse. A bench award is
  -- therefore text and save-file only: the "gained EXP" line, the "grew to
  -- level N!" lines, and the moves that come with them (`toLearn` and its
  -- forget prompt included) all still run, because those are the monster's,
  -- not the plate's. Nothing below writes `shownExpFrac` / `shownLevel` for a
  -- benched award -- not even the `seedExpClock` that would look harmless,
  -- since seeding the *seat* off a *bench* monster is exactly the mix-up this
  -- gate exists to prevent.
  local onField = paidIndex == (self.active or 1)
  local wide = onField
  local index = self:mySlot()
  local slot = self.slots[index]
  local fromFrac, fromLevel
  if wide and slot then
    self:seedExpClock(slot, mon)
    fromFrac = slot.shownExpFrac
    fromLevel = slot.shownLevel or mon.level or 1
  end

  -- The first pass. Both arms hand back the same two values -- the list of
  -- levels reached and the raw amount the "gained N EXP" line says -- so
  -- everything below this point is generation-free again.
  -- No `learned` here on purpose: `Exp2.apply` returns the move list as its
  -- third value, but `levelled` below derives the same list per level through
  -- `Exp2.movesLearnedAt` -- capturing it would be a value nothing reads.
  local ok, levels, gained
  if generation == 2 then
    -- `participants` is the referee's divisor unmodified: Gen 2's Share tax is
    -- the `halved` flag on the pool, not a doubling of the divisor.
    levels, gained = Exp2.apply(self.game, mon, def, {
      level = level, participants = participants, isTrainer = isTrainer,
      halved = halved, save = save,
    })
    ok = levels ~= nil
    if not ok then
      -- `gained` is the reason string on the failure arm.
      self:warnNoExp(type(gained) == "string" and gained
        or "the engine refused the award for this monster")
      return false
    end
  else
    ok, levels, gained = pcall(eng.Experience.apply, data, mon, def,
      level, isTrainer, participants * (expAll and 2 or 1), mon.traded)
    if not ok then
      self:warnNoExp("the engine refused the award for this monster")
      return false
    end
  end

  -- The name the box has been calling it all fight: the referee narrates under
  -- the sheet's `species` (a nickname when there is one), so the exp line must
  -- not suddenly switch to the species def and read as a different monster.
  -- Read off the sheet being *paid* rather than the one on the field -- a bench
  -- award announced under the fighter's name is a player watching the wrong
  -- monster level up.
  local sheet = mine and mine[paidIndex]
  local name = (sheet and sheet.species) or mon.nickname or myDef.name or "?"

  -- One tally per award actually applied, for the e2e to assert on.
  --
  -- Exp is the one part of a refereed fight with no visible artefact a driver
  -- can wait for: the referee emits facts, the client prices them, and the
  -- result lands in a save field. A leg that only watched the party's
  -- `experience` climb would pass just as happily if the referee never emitted
  -- anything and the number moved for some other reason -- and would fail on a
  -- fight that ended by catch, where paying nothing is correct. This counts the
  -- awards this screen actually applied, which is the fact worth asserting.
  self.expPaid = (self.expPaid or 0) + 1
  self:say(name .. " gained\n" .. tostring(gained or 0) .. " EXP. Points!")

  -- ...and *then* the strip crawls, which is the cart's chronology: the line
  -- is read, and the bar answers it. Queued ahead of the level lines
  -- deliberately -- the pill ticks over as the strip tops out (`stepExpFill`),
  -- so "grew to level N!" prints after the plate already says N rather than a
  -- beat before it.
  --
  -- No target rides on the row: it is read off the mon when the row comes up,
  -- because the mon is *still being written to* after this point (the EXP.ALL
  -- pass below walks `save.party`, and this fighter is in it). A target frozen
  -- here would be the first half of the award and would leave the pill short
  -- of the "grew to level N!" lines printed beside it.
  if wide and slot then
    self.lines[#self.lines + 1] = {
      expfill = index,
      mon = mon,
      name = name,
      fromFrac = fromFrac,
      fromLevel = fromLevel,
      -- Stamped with its occupant like every other display row here: a switch
      -- landing between queue and play would otherwise crawl this monster's
      -- award across the newcomer's plate.
      species = slot.species,
    }
  end

  self:levelled(mon, name, levels)

  -- **HP climb is queued after every apply pass**, not here. EXP.ALL /
  -- EXP.SHARE can still raise this same mon; `syncLevelHp` at the end of
  -- `gainExp` sees the full delta.

  -- ...and the other half, spread over everyone still standing -- including
  -- the monster that fought, exactly as the original's second pass does.
  -- Fainted party members are skipped, and no "gained EXP" line is printed for
  -- any of them: the original prints only what a level-up produces.
  --
  -- Every member is held to the same four checks the fighter above is, and for
  -- the same reason: `apply` banks the exp before it recomputes the stats, so
  -- a member with no `dvs`, no stat block or a species this build cannot name
  -- throws *after* the level has already moved, and the `pcall` here would
  -- report a skip while leaving the monster holding a level its stats never
  -- caught up with. A member that fails them is passed over whole.
  --
  -- **Once per knockout, not once per award** -- the round-6 correction. The
  -- engine's second pass is inside `vanillaExpAward`, which runs once per
  -- `awardExp`, i.e. once per faint, *after* the loop over participants
  -- (BattleState). Round 5 got that for free: the own-slot gate let exactly one
  -- `exp` event through per faint, so one award meant one pass. Now a faint can
  -- pay up to six of this client's monsters, and running the party pass on each
  -- of them would hand an EXP.ALL holder six second-halves for one kill -- the
  -- item quietly becoming several times better in the MMO than in the cart.
  --
  -- So the pass spends its own credit, armed by the foe knockout the same way
  -- the awards' is. Three-valued, exactly as CoopBattle's is: `nil` means no
  -- faint was ever narrated to this screen (`gainExp` driven straight from a
  -- harness) and runs unmetered -- the wire path always arms, so nil is never a
  -- hub the meter was meant to catch, and `expCredit` has already refused a hub
  -- that pays with no knockout at all. `true` is armed, `false` is spent, and
  -- the next knockout re-arms. A running tally instead would strand a credit
  -- whenever a knockout pays this client nothing at all.
  --
  -- Only the second pass is metered. The first one's divisor still doubles for
  -- everyone holding the item (`participants * 2` above), because that halving
  -- is the item's cost and is charged per participant in the cart too.
  if expAll and self.expAllCredit ~= false then
    if self.expAllCredit then self.expAllCredit = false end
    for _, member in ipairs(party) do
      local memberDef = type(member) == "table" and pokedex[member.species] or nil
      if type(memberDef) == "table" and (tonumber(member.hp) or 0) > 0
         and type(member.stats) == "table" then
        member.statExp = member.statExp or {}
        member.dvs = member.dvs or {}
        member.exp = member.exp or 0
        local gotOk, gotLevels = pcall(eng.Experience.apply, data, member, def,
          level, isTrainer, participants * 2 * math.max(1, #party),
          member.traded)
        if gotOk then self:levelled(member, nil, gotLevels) end
      end
    end
  end

  -- ...and Gen 2's own second pass: the EXP.SHARE holders, divided by how many
  -- of them there are rather than by the party size, and taxed by the same
  -- `halved` the first pass paid. A holder that fought is in both passes on
  -- purpose -- that is the item, and it is what the cart does.
  --
  -- Metered by the same one-knockout credit the EXP.ALL pass is, and for the
  -- identical reason: the engine's second pass runs once per `awardExperience`
  -- (i.e. once per faint) *after* the loop over participants, so running it on
  -- each of up to six `exp` events would hand a holder six second helpings for
  -- one kill. The credit is shared with the Gen 1 arm because only one of the
  -- two can ever be live on a given boot.
  if halved and self.expAllCredit ~= false then
    if self.expAllCredit then self.expAllCredit = false end
    local shares = math.max(1, #shareHolders)
    for _, holderIndex in ipairs(shareHolders) do
      local member = party[holderIndex]
      local memberDef = type(member) == "table" and pokedex[member.species] or nil
      if type(memberDef) == "table" and (tonumber(member.hp) or 0) > 0
         and type(member.stats) == "table" then
        member.statExp = member.statExp or {}
        member.dvs = member.dvs or {}
        member.experience = member.experience or 0
        local gotLevels = Exp2.apply(self.game, member, def, {
          level = level, participants = shares, isTrainer = isTrainer,
          halved = true, save = save,
        })
        if gotLevels then self:levelled(member, nil, gotLevels) end
      end
    end
  end

  -- A level raises both HP numbers, and the bar has to be told. The field
  -- is the referee's sheet, the save mon is a different table, and copying
  -- save HP onto the plate would heal to full (the save is not taking the
  -- fight's damage). The delta is the level's own gain, added to the
  -- referee's pair, then the bar climbs -- same chronology CoopBattle uses
  -- (gen1recomp #224). Bench awards stay text and save-file only.
  self:syncLevelHp(paidIndex, oldMax, mon, onField)
  -- The bench's K9 sends (EXP.ALL / EXP.SHARE) have no plate to settle.
  self.levelSent = nil
  return true
end

-- Apply a level-up's HP growth to the plate (and the fight sheet the party
-- menu reads). `grown` is maxHP after Experience.apply minus maxHP before;
-- current HP on the arena rises by the same amount, never to the save mon's
-- post-award HP.
function M:syncLevelHp(paidIndex, oldMax, mon, onField)
  -- Whether the referee was told (contract K9, `syncFightMoves`): taken here
  -- and cleared whatever the HP did, so the next award asks again.
  local refereed = type(self.levelSent) == "table" and mon ~= nil
    and self.levelSent[mon] == true
  if type(self.levelSent) == "table" and mon ~= nil then self.levelSent[mon] = nil end
  local newMax = tonumber(mon and mon.stats and mon.stats.hp)
  -- A Gen 3 mon keeps its maximum flat on the mon (Pokemon.applyStats).
  if self:generation() == 3 then newMax = tonumber(mon and mon.maxHp) end
  if not newMax or newMax ~= newMax then return end
  newMax = floor(newMax)
  local grown = newMax - floor(tonumber(oldMax) or newMax)
  if grown <= 0 then return end
  local sheet = self.mine and self.mine[paidIndex]
  if type(sheet) == "table" then
    sheet.maxHp = newMax
    sheet.hp = min(newMax, (tonumber(sheet.hp) or 0) + grown)
    if mon.level then sheet.level = mon.level end
  end
  if not onField then return end
  local index = self:mySlot()
  local arena = index ~= nil and self.slots[index]
  if type(arena) ~= "table" then return end
  arena.maxHp = max(1, (tonumber(arena.maxHp) or 1) + grown)
  arena.hp = max(0, (tonumber(arena.hp) or 0) + grown)
  if arena.hp > arena.maxHp then arena.maxHp = arena.hp end
  -- Remember the delta: every event still in this batch was resolved before
  -- the referee heard of the level, so the next `damage` here states the
  -- pre-level pair. noteSlot / syncMineHp add this back rather than snapping
  -- the plate (and the party sheet) to the old numbers.
  --
  -- How long for is the question K9 changed.  A referee that was told
  -- (`refereed`, Gen 1 / Gen 2) rebuilds the pair itself -- maximum and
  -- current HP raised by the same step, as the cart does -- so from its next
  -- batch on its numbers already hold the climb, and adding it again would
  -- count the level twice.  That delta is kept apart (`levelHpRefereed`) and
  -- dropped at the slot-less `turn` that closes this batch: the client files
  -- its next choice after this message on the same ordered transport, so the
  -- next resolution has the level in hand.  Anything the referee never hears
  -- -- Gen 3, whose referee rebuilds nothing; a send the transport refused;
  -- an evolution's growth (`refreshAfterEvolve`) -- stays on `levelHpGrown`
  -- for as long as the monster stands there, as before.
  if refereed then
    arena.levelHpRefereed = (tonumber(arena.levelHpRefereed) or 0) + grown
    return self:queueDrain(index)
  end
  arena.levelHpGrown = (tonumber(arena.levelHpGrown) or 0) + grown
  -- Raise the ceiling before the climb so startDrain does not clamp `to`
  -- against the old maximum. Classic reads the same `shownHp` clock, so
  -- it queues the climb too -- welding here snapped the bar past the
  -- level-up line.
  self:queueDrain(index)
end

-- What a level-up costs, wherever it happened: a line, whatever moves come
-- with the level, and -- when this mon now qualifies -- the mid-battle
-- evolution movie. The after-battle fallback (`Coop.offerEvolutions`) still
-- runs for a level-up whose row never played; `leveledUp` is that set.
function M:levelled(mon, fallbackName, levels)
  if not (levels and #levels > 0) then return false end
  local data = self.game and self.game.data
  local def = type(data) == "table" and (data.pokemon or {})[mon.species] or nil
  local name = mon.nickname or fallbackName or (def and def.name) or "?"
  local eng = loadEngine()
  -- A move learned into a free slot below is told to the referee once, with
  -- the level-up, after the loop (contract K9) -- not once per move and then
  -- again for the level.
  local deferred = self.deferMoveset
  self.deferMoveset = true
  for _, newLevel in ipairs(levels) do
    self:say(name .. " grew to\nlevel " .. tostring(newLevel) .. "!")
    -- Levelled here, so the moves it learns are decided here too -- the
    -- referee cannot know, because it never held the copy that gained them.
    --
    -- Unpacked in full rather than through `select(2, pcall(...))`: on a
    -- failure that second value is the error *string*, and `ipairs` over a
    -- string throws -- out of a function whose whole contract is that a
    -- level-up never takes the event stream down with it.
    --
    -- Gen 2 keeps its level-up table on `def.levelMoves` where Gen 1 uses
    -- `def.learnset`, and has no `Experience` module to ask -- so the lookup
    -- goes through `Exp2.movesLearnedAt`, which answers the same list shape off
    -- the Gold record. Everything after this line is generation-free.
    local moves
    if def and Gen.generation(self.game) == 2 then
      local ok, got = pcall(Exp2.movesLearnedAt, def, newLevel)
      if ok and type(got) == "table" then moves = got end
    elseif def and eng and eng.Experience
       and type(eng.Experience.movesLearnedAt) == "function" then
      local ok, got = pcall(eng.Experience.movesLearnedAt, def, newLevel)
      if ok and type(got) == "table" then moves = got end
    end
    for _, moveId in ipairs(moves or {}) do
      self:teach(mon, name, moveId)
    end
  end
  self.deferMoveset = deferred
  -- Contract K9: the referee hears about every level-up of a monster this
  -- client uploaded, on the field or on the bench, with or without a new
  -- move -- the cart rebuilds the battle stats after a level-up in battle
  -- (pokered / pokecrystal GainExperience), and before K9 the referee fought
  -- on the stats the monster walked in with.  One message: the current move
  -- list (whatever `teach` just learned) and the new level, stats and max HP.
  -- Gen 3 never reaches here (`levelled3`).
  self:syncFightMoves(mon, true)
  self.leveledUp = self.leveledUp or {}
  self.leveledUp[mon] = true
  self.lines = self.lines or {}
  EvolveFx.enqueue(self.lines, self.game, mon, self)
  return true
end

-- ------- learning a move
--
-- A free slot is applied to the save mon *and* the fight sheet, then published
-- to the referee so the new move is usable this fight. A full moveset queues
-- the generation's own forget prompt (`LearnMove.open`) as a blocking row --
-- this screen is 1v1 / wild, so the pause is the same one vanilla takes.
-- Co-op banks the fifth move for after the fight instead (see CoopBattle).
-- `toLearn` is the leftover if the player leaves before answering.
function M:teach(mon, name, moveId)
  if self:generation() == 3 then return self:teach3(mon, name, moveId) end
  local data = self.game and self.game.data
  local status = LearnMove.apply(mon, moveId, data)
  if status == "missing" or status == "known" then return false end
  local def = type(data) == "table" and (data.moves or {})[moveId] or nil
  name = name or "?"
  if status == "learned" then
    self:say(name .. " learned\n" .. ((def and def.name) or moveId) .. "!")
    -- Inside a level-up `levelled` sends the list once, with the level (K9).
    if not self.deferMoveset then self:syncFightMoves(mon) end
    return true
  end
  self.toLearn = self.toLearn or {}
  self.toLearn[#self.toLearn + 1] = { mon = mon, move = moveId }
  self.lines = self.lines or {}
  self.lines[#self.lines + 1] = { learn = { mon = mon, move = moveId, name = name } }
  return true
end

-- Which uploaded sheet a save-party mon sits behind. Identity on the table
-- `Experience.apply` already mutated -- an index into the party can move.
function M:sheetIndexFor(mon)
  if type(mon) ~= "table" then return nil end
  for i = 1, #(self.mine or {}) do
    if self:saveMon(i) == mon then return i end
  end
  return nil
end

-- Do two move lists name the same moves in the same slots?  What tells a
-- learn (a slot added or replaced) from a list resent unchanged beside a
-- level-up (contract K9).  Shared with src/CoopBattle.lua.
function M.sameMoveIds(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  if #a ~= #b then return false end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if not (type(x) == "table" and type(y) == "table" and x.id == y.id) then
      return false
    end
  end
  return true
end

-- ------- SKETCH, written home (Gold)
--
-- pokecrystal BattleCommand_Sketch (engine/battle/move_effects/sketch.asm,
-- pokegold the same): "This move replacement shall be permanent."  It finds
-- SKETCH in the user's *battle* list (`.find_sketch`, from the last slot
-- down) and writes the opponent's last counter move there, with that move's
-- base PP (Moves + MOVE_PP) as the slot's PP byte -- and, for the player's
-- monster (`.user_trainer`), the same id and the same PP byte into its party
-- struct at the same slot (`UserPartyAttr` MON_MOVES / MON_PP).  The byte is
-- the bare base PP, so the slot's PP-Up bits are gone with the move.  A link
-- battle never gets there (`wLinkMode` -> "But nothing happened"), and the
-- cart's bug lets a TRANSFORMed user through (it tests the *opponent's*
-- SUBSTATUS_TRANSFORMED): the slot it writes is the battle list's SKETCH
-- slot, whatever the party holds there -- a MIMIC'd SKETCH overwrites MIMIC.
--
-- The referee states it as a `moves` event that carries `mon` (a party list,
-- as a PP spend is) whose ids differ from the list this screen last showed
-- for that monster in exactly the SKETCH slot.  That is the whole test, and it
-- is deliberately narrow: a TRANSFORM or MIMIC overlay arrives with no `mon`
-- and is never written home, and a PP spend changes no id.

-- Is this move row SKETCH -- by id, or by its Gold record's effect (a content
-- mod's own move that sketches)?
local function isSketch2(game, row)
  if type(row) ~= "table" then return false end
  if row.id == "SKETCH" then return true end
  local data = game and game.data
  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[row.id] or nil
  return type(def) == "table" and def.effect == "EFFECT_SKETCH"
end

-- The slots a SKETCH just rewrote: every index where `prior` (the list this
-- screen showed for the monster) holds SKETCH and `incoming` (the referee's
-- party list) another move -- or nil when the two lists differ in any other
-- slot, or in length, or nowhere at all.  Shared with src/CoopBattle.lua.
function M.sketchedSlots(game, prior, incoming)
  if type(prior) ~= "table" or type(incoming) ~= "table" then return nil end
  if #prior ~= #incoming or #prior == 0 then return nil end
  local slots = nil
  for i = 1, #prior do
    local was, now = prior[i], incoming[i]
    if not (type(was) == "table" and type(now) == "table") then return nil end
    if was.id ~= now.id then
      if not (isSketch2(game, was) and Wire.id(now.id) ~= nil) then return nil end
      slots = slots or {}
      slots[#slots + 1] = i
    end
  end
  return slots
end

-- One sketched slot onto the engine's party monster: the referee's move id
-- and PP (the cart's PP byte, the new move's base PP), the base as its
-- maximum, and no PP Ups -- the shape Mon.learnMove gives a new Gold move
-- (src/battle/gen2/Mon.lua: `{ id, pp, maxPp }`).  The slot table is written
-- in place, so a FIGHT list that reads the party's own (co-op's live party)
-- sees it at once.  Returns the slot, or nil when the party has no such slot.
function M.writeSketch(game, mon, index, row)
  local moves = type(mon) == "table" and mon.moves or nil
  local slot = type(moves) == "table" and moves[index] or nil
  if type(slot) ~= "table" or type(row) ~= "table" then return nil end
  local data = game and game.data
  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[row.id] or nil
  local base = type(def) == "table" and tonumber(def.pp) or nil
  local maxPp = base or tonumber(row.maxPp) or tonumber(row.pp) or 0
  maxPp = max(0, floor(maxPp))
  slot.id = row.id
  slot.pp = clamp(intOr(row.pp, maxPp), 0, maxPp)
  slot.maxPp = maxPp
  slot.ppUps = nil
  return slot
end

-- Write every SKETCH this `moves` event states onto the party monster behind
-- it -- Gold, a fight against the computer (KEEPS_HELD_MODES: the cart's
-- link battle refuses the move, and a fight between players never writes
-- home), on this client's own seat (the caller's check).  `prior` is the list
-- the screen showed for that monster.  Returns the slots written, or nil.
function M.sketchHome(game, mode, prior, incoming, partyMon)
  if Gen.generation(game) ~= 2 or not KEEPS_HELD_MODES[mode] then return nil end
  local slots = M.sketchedSlots(game, prior, incoming)
  if not slots then return nil end
  -- The referee's slot numbers are the uploaded sheet's, which skips a move
  -- it cannot describe (`sheetMoves`); a party list of another length is one
  -- whose slots do not line up, and nothing is written rather than the wrong
  -- move overwritten.
  local own = type(partyMon) == "table" and partyMon.moves or nil
  if type(own) ~= "table" or #own ~= #incoming then
    mod.log:warn("a SKETCH could not be written to your party (its move list "
      .. "does not line up with the battle's); the move is kept for this "
      .. "battle only -- check the POKeMON's moves after the fight")
    return nil
  end
  local wrote = nil
  for _, i in ipairs(slots) do
    if M.writeSketch(game, partyMon, i, incoming[i]) then
      wrote = wrote or {}
      wrote[#wrote + 1] = i
    end
  end
  return wrote
end

-- ------- a MIMIC's PP, by the party's slots
--
-- A MIMIC writes the picked move's id over the user's battle slot and leaves
-- every other slot alone, and the carts part on whose PP the copy spends:
--
--   Red   pokered MimicEffect (engine/battle/move_effects/mimic.asm) keeps the
--         slot's PP, and DecrementPP (engine/battle/decrement_pp.asm) spends
--         wBattleMonPP *and* the party struct's PP at wPlayerMoveListIndex --
--         the slot -- unless the user is TRANSFORMed: every use of the
--         mimicked move comes off the party's MIMIC.
--   Gold  pokecrystal BattleCommand_Mimic (engine/battle/move_effects/
--         mimic.asm) gives the copy 5 PP (`ld [hl], 5`), and DoTurn's party
--         spend asks CheckMimicUsed, which skips the party's PP for a MIMIC
--         slot holding another move: the copy's uses never reach MIMIC, while
--         every other slot's still reach the party.
--
-- Is `overlay` -- the list a `moves` event with no `mon` just stated -- a
-- MIMIC of `own`, the list the party holds?  Same length; every slot the same
-- id at the same PP (the overlay lands behind the turn's own PP spend, which
-- `own` has already taken), or one where the party holds MIMIC (on Red at the
-- same PP too); at least one that differs.  A TRANSFORM -- every copied slot at
-- 5 PP, a list the party does not hold -- answers false, and so does a MIMIC
-- used while transformed (none of its party PP is spent).
function M.mimicOverlay(game, own, overlay, generation)
  if type(own) ~= "table" or type(overlay) ~= "table" then return false end
  if #own ~= #overlay or #own == 0 then return false end
  local mimicEffect = Effects1.idOf("MIMIC_EFFECT")
  local data = game and game.data
  local differs = false
  for i = 1, #own do
    local mine, shown = own[i], overlay[i]
    if not (type(mine) == "table" and type(shown) == "table") then return false end
    local samePp = tonumber(mine.pp) == tonumber(shown.pp)
    if mine.id ~= shown.id then
      local def = type(data) == "table" and type(data.moves) == "table"
        and data.moves[mine.id] or nil
      local mimic = mine.id == "MIMIC"
        or (mimicEffect ~= nil and tonumber(mine.effect) == mimicEffect)
        or (type(def) == "table"
            and (def.effect == "MIMIC_EFFECT" or def.effect == "EFFECT_MIMIC"))
      if not mimic then return false end
      if generation ~= 2 and not samePp then return false end
      differs = true
    elseif not samePp then
      return false
    end
  end
  return differs
end

-- The PP of each slot of the referee's list, onto the party's own list by
-- slot (above): Red's every slot, the mimicked one onto MIMIC; Gold's every
-- slot that holds the party's own move, never the copy's.  Ids are left alone.
function M.slotPp(own, incoming, generation)
  if type(own) ~= "table" or type(incoming) ~= "table" then return false end
  if #own ~= #incoming then return false end
  for i, row in ipairs(own) do
    local shown = incoming[i]
    local pp = type(shown) == "table" and tonumber(shown.pp) or nil
    local mine = type(row) == "table" and (generation ~= 2 or row.id == shown.id)
    if mine and pp then
      if generation == 1 then M.ppByteStep1(row, shown) end
      row.pp = max(0, floor(pp))
    end
  end
  return true
end

-- Rebuild this sheet from the save mon and tell the referee.  The real sheet
-- always updates, so the new move is there when a Transform ends.  What the
-- `liveMoves` overlay does is the cart's LearnMove, which the referee's learn
-- follows (src/Hub.lua `learnTo`):
--
--   * Red: pokered LearnMove (engine/pokemon/learn_move.asm) copies the
--     party's moves and PP over wBattleMonMoves / wBattleMonPP for the
--     monster standing in battle whatever its substatus, so a transformed (or
--     MIMICking) monster that learns fights on with its own list -- the
--     overlay goes, and FIGHT reads the sheet.  Only on a learn: a level-up
--     that taught nothing never reaches LearnMove (LearnMoveFromLevelUp finds
--     no move for the level), and its resent list leaves the overlay up.
--   * Gold: pokecrystal LearnMove (engine/pokemon/learn.asm) skips that copy
--     under SUBSTATUS_TRANSFORMED, so the copied moves stay in the fight and
--     the overlay stays with them.
--
-- `grew` (Gen 1 / Gen 2): the monster just levelled, so the message carries
-- its new level, stats and max HP too (contract K9; `M.growthOf`), and the
-- sheet takes the same stats.  A successful level-up send is remembered in
-- `levelSent` so `syncLevelHp` knows the referee will fight on the levelled
-- pair from its next batch on.
function M:syncFightMoves(mon, grew)
  -- Never in a fight between players (LINK_MODES): no cart learns a move or
  -- gains a level in a link battle -- pokered GainExperience (engine/battle/
  -- experience.asm) returns at once on LINK_STATE_BATTLING, pokecrystal
  -- GiveExperiencePoints (engine/battle/core.asm) on wLinkMode, and nothing
  -- else in a Cable Club fight reaches LearnMove -- and both hubs ignore the
  -- message there.  A screen that got here anyway (a stray exp) sends nothing.
  if LINK_MODES[self.mode] then return false end
  local index = self:sheetIndexFor(mon)
  if not index then return false end
  local sheet = self.mine and self.mine[index]
  if type(sheet) ~= "table" then return false end
  local moves = M.sheetMoves(self.game, mon)
  if #moves == 0 then return false end
  local learned = not M.sameMoveIds(sheet.moves, moves)
  sheet.moves = moves
  local growth = nil
  if grew and self:generation() ~= 3 then
    growth = M.growthOf(self.game, mon)
    if growth then sheet.stats = growth.stats end
  end
  local sent = M.sendMoveset(self.transport, self.battle, index - 1, moves,
    self:generation(), growth)
  if sent and growth then
    self.levelSent = self.levelSent or {}
    self.levelSent[mon] = true
  end
  -- Red's LearnMove copy (above): the referee was told, so the monster
  -- standing here fights on with its own list.
  if sent and learned and self.liveMoves and index == (self.active or 1)
     and self:generation() == 1 then
    self.liveMoves = nil
  end
  return sent
end

-- ------- Gen 3: the award, the held items, the throw, the catch

-- Is this `exp` event BattleSim3's holders-only fact (sheet doc §7.1)?
-- `participants` 0 and no `mon`: this seat fought the fallen foe, every
-- monster of it that did has fainted since, and something of it still stands
-- -- pret Cmd_getexp then pays the living Exp. Share holders alone
-- (`viaSentIn` 0 behind a SAFE_DIV).  Only Wire's Gen 3 reading keeps a zero.
function M.holdersOnly(msg)
  return type(msg) == "table" and msg.mon == nil and tonumber(msg.participants) == 0
end

-- Bank one `exp` event of a knockout (see `flushExp3`).  True when it was
-- taken, which is what spends the knockout's credit.
--
-- The holders-only fact banks the knockout with an **empty** sentIn set, so
-- Exp3.award prices it as `split(calculated, 0, holders)` and pays each living
-- Exp. Share holder its half and nobody else -- never the active mon, which is
-- what a `mon`-less event falls back to otherwise (a PROTOCOL 21 referee).  It
-- is the seat's whole share of that knockout (the referee sends it only to a
-- seat nothing else of that knockout pays), so it is a batch of its own: one
-- already open is priced first, and the next event starts another rather than
-- merging a second knockout of the same species and level into this one.
function M:bankExp3(msg)
  local holdersOnly = M.holdersOnly(msg)
  local paidIndex = self:paidSheetIndex(msg)
  local mine = self.mine
  if msg and msg.mon ~= nil and type(mine) == "table" and #mine > 0
     and mine[paidIndex] == nil then
    self:warnNoExp("the referee paid a party member this client never uploaded")
    return false
  end
  local species = tonumber(msg and msg.speciesId)
  local level = tonumber(msg and msg.level)
  if not (species and level) then
    self:warnNoExp("the referee's exp event named no species or level this "
      .. "build could read")
    return false
  end
  species, level = math.floor(species), math.max(1, math.floor(level))
  local key = species .. ":" .. level
  local batch = self.expBatch
  if batch and (batch.key ~= key or batch.holdersOnly or holdersOnly) then
    self:flushExp3()
    batch = nil
  end
  if not batch then
    batch = { key = key, species = species, level = level, sentIn = {},
              holdersOnly = holdersOnly or nil }
    self.expBatch = batch
  end
  if not holdersOnly then batch.sentIn[self:savePartyIndex(paidIndex)] = true end
  return true
end

-- Price one knockout on the session party, the cart's way (Exp3.award:
-- Cmd_getexp's split over the living participants, the Exp. Share holders'
-- half, Lucky Egg / trainer / traded, the EVs), and queue what the cart shows
-- for it: "X gained N EXP. Points!" for every mon paid, the strip filling on
-- the plate of the one standing, then each level's line, its moves and any
-- evolution.
function M:flushExp3()
  local batch = self.expBatch
  if not batch then return false end
  self.expBatch = nil
  if not Exp3.available() then
    self:warnNoExp("the engine's Gen 3 experience modules are unavailable")
    return false
  end
  local party = savePartyOf(self.game)
  if type(party) ~= "table" then
    self:warnNoExp("this client holds no save party to pay")
    return false
  end
  -- Where the standing monster's strip is *now*: Experience.apply mutates the
  -- mon, so the start has to be read before the award lands.
  local index = self:mySlot()
  local slot = self.slots[index]
  local activeParty = self:savePartyIndex(self.active)
  local fromFrac, fromLevel
  local fighter = party[activeParty]
  if slot and type(fighter) == "table" then
    self:seedExpClock(slot, fighter)
    fromFrac = slot.shownExpFrac
    fromLevel = slot.shownLevel or fighter.level or 1
  end
  local results, why = Exp3.award({
    species = batch.species, level = batch.level,
    isTrainer = TRAINER_MODES[self.mode] or false,
    sentIn = batch.sentIn, party = party, session = Gen3.session(),
    battle = self,
  }, { alive = self:standingInFight() })
  if not results then
    self:warnNoExp(why or "the engine refused the award")
    return false
  end
  for _, r in ipairs(results) do
    local mon = r.mon
    local sheetIndex = self:sheetIndexFor(mon)
    -- This client's own sentence about its own monster: the cart's spelling
    -- (NIDORAN♂, an é in a nickname), not the wire's.
    local name = Sheet3.localName(mon, tonumber(mon.species or mon.speciesId))
    self.expPaid = (self.expPaid or 0) + 1
    self:say(Exp3.gainedText(name, r.gained or r.amount, r.boosted))
    local onField = r.index == activeParty
    if onField and slot then
      self.lines[#self.lines + 1] = {
        expfill = index, mon = mon, name = name,
        fromFrac = fromFrac, fromLevel = fromLevel, species = slot.species,
      }
    end
    self:levelled3(mon, name, r.levels)
    if sheetIndex then self:syncLevelHp(sheetIndex, r.fromMaxHp, mon, onField) end
  end
  return true
end

-- Who is standing in *this* fight, by save-party index, for Exp3.award's
-- `alive` question.  The save party cannot answer it: this screen never writes
-- HP home mid-fight, so the save still holds the HP the fight started with --
-- an Exp. Share holder that fainted two turns ago would be paid, and a mon
-- revived with a REVIVE would not.  The referee's roster for our seat (the
-- `team` event, one token per uploaded sheet, `x` = fainted) is the fight's
-- own truth and is current by the time an award is priced: the referee
-- restates it after every faint and every revive, ahead of the `exp` events
-- that follow.  A screen that has not seen one yet reads its own sheets' HP.
-- nil (no sheets at all) leaves Exp3 on the save's HP.
function M:standingInFight()
  local mine = self.mine
  if type(mine) ~= "table" or #mine == 0 then return nil end
  local roster = self.teams and self.teams[self:mySlot()]
  if type(roster) ~= "string" then roster = nil end
  local byParty = {}
  for i = 1, #mine do
    local up
    if roster and #roster >= i then
      up = roster:sub(i, i) ~= "x"
    else
      local hp = type(mine[i]) == "table" and tonumber(mine[i].hp) or nil
      if hp ~= nil then up = hp > 0 end
    end
    if up ~= nil then byParty[self:savePartyIndex(i)] = up end
  end
  return function(partyIndex) return byParty[partyIndex] end
end

-- `levelled`, the Gen 3 way: each level's line in the cart's words, the
-- moves the cart's learnset gives at that level, then the evolution check.
function M:levelled3(mon, name, levels)
  if not (type(levels) == "table" and #levels > 0) then return false end
  name = name or Sheet3.localName(mon, tonumber(mon.species or mon.speciesId))
  for _, newLevel in ipairs(levels) do
    self:say(Exp3.grewText(name, newLevel))
    for _, moveId in ipairs(Exp3.movesLearnedAt(mon, newLevel)) do
      self:teach(mon, name, moveId)
    end
  end
  self.leveledUp = self.leveledUp or {}
  self.leveledUp[mon] = true
  self.lines = self.lines or {}
  EvolveFx.enqueue(self.lines, self.game, mon, self)
  return true
end

-- `teach`, with Gen 3's numeric move ids and the cart's sentence.
function M:teach3(mon, name, moveId)
  local id = tonumber(moveId)
  local status = LearnMove.apply(mon, id, nil)
  if status == "missing" or status == "known" then return false end
  name = name or "?"
  if status == "learned" then
    self:say(Exp3.learnedText(name, Gen3.moveName(id) or tostring(id)))
    self:syncFightMoves(mon)
    return true
  end
  self.toLearn = self.toLearn or {}
  self.toLearn[#self.toLearn + 1] = { mon = mon, move = id }
  self.lines = self.lines or {}
  self.lines[#self.lines + 1] = { learn = { mon = mon, move = id, name = name } }
  return true
end

-- Every held item this client itself put into the fight: its own sheets as
-- uploaded and the wild / NPC sheets it uploaded for the other side (a solo
-- or hub-wild fight's foe is described by this client from its own cart).
-- Taken once, at the upload, before any `held` event has moved an item; a
-- screen that never uploaded (a harness) takes it at first use.
function M:ownItemSet()
  local set = self.ownItems
  if set then return set end
  set = {}
  local function add(list)
    if type(list) ~= "table" then return end
    for _, sheet in ipairs(list) do
      local id = type(sheet) == "table" and tonumber(sheet.heldItem) or nil
      if id and id > 0 then set[math.floor(id)] = true end
    end
  end
  add(self.mine)
  add(self.wildParty)
  add(self.npcParty)
  self.ownItems = set
  return set
end

-- May this item id enter this player's save?  Nothing, always; otherwise only
-- an item one of this client's own uploads held.  THIEF / COVET / TRICK hand a
-- mon whatever the other seat's sheet claimed, and a sheet is a claim -- so an
-- id this client never uploaded (a key item, a ticket) is never written home,
-- whoever the referee says it came from.
function M:ownItem(id)
  id = tonumber(id)
  if not id then return false end
  if id == 0 then return true end
  return self:ownItemSet()[math.floor(id)] == true
end

-- A `held` event: what the mon holds now (C5 §7.2).
--
-- The foe's is remembered, by its party index, for a catch (`caughtHolding`):
-- its `holding` is the party truth the caught sheet cannot carry (KNOCK OFF).
--
-- Ours goes onto the fight sheet always -- the BAG and POKeMON pages read it
-- -- and onto the save mon only where the cart keeps battle item changes
-- (KEEPS_HELD_MODES; a link fight's party is reloaded after, see LINK_MODES),
-- and only as an item this client uploaded itself (`ownItem`).  The
-- referee's `mon` is the index into the party we uploaded.
function M:applyHeld(msg)
  if not (msg and msg.side ~= nil) then return false end
  local holding = tonumber(msg.holding)
  if not holding or holding < 0 then return false end
  holding = math.floor(holding)
  if msg.side ~= self.mySide then
    local index = tonumber(msg.mon)
    if index and index >= 0 then
      self.foeHeld = self.foeHeld or {}
      self.foeHeld[math.floor(index)] = holding
    end
    return false
  end
  local sheetIndex = tonumber(msg.mon) and (math.floor(tonumber(msg.mon)) + 1)
    or self.active
  local sheet = self.mine and self.mine[sheetIndex]
  if type(sheet) == "table" then sheet.heldItem = holding end
  if not KEEPS_HELD_MODES[self.mode] then return false end
  local mon = self:saveMon(sheetIndex)
  if type(mon) ~= "table" then return false end
  local had = tonumber(mon.heldItem) or tonumber(mon.item) or 0
  if holding ~= had and not self:ownItem(holding) then
    if not self.heldWarned then
      self.heldWarned = true
      mod.log:warn("the battle referee handed one of your POKeMON item %d, which "
        .. "nothing in this fight was holding, so it was not added to your save "
        .. "-- report this with the server you were playing on", holding)
    end
    return false
  end
  mon.heldItem = holding
  mon.item = holding
  return true
end

-- The index of the caught mon in the foe party this client uploaded (the
-- referee's `mon` for that seat), by its personality and species; the lone
-- sheet of a one-mon wild party otherwise.  nil when it cannot be told.
function M:caughtFoeIndex(caught)
  local list = self.wildParty
  if type(list) ~= "table" or type(caught) ~= "table" then return nil end
  local pid, sp = tonumber(caught.personality), tonumber(caught.speciesNum)
  if pid then
    for i, sheet in ipairs(list) do
      if type(sheet) == "table" and tonumber(sheet.personality) == pid
         and (not sp or tonumber(sheet.speciesNum) == sp) then
        return i - 1
      end
    end
  end
  if #list == 1 then return 0 end
  return nil
end

-- What a caught monster holds leaving the fight.  The referee's caught sheet
-- states the *battle's* item, and that is not the party's after KNOCK OFF:
-- the item is gone for the rest of the fight only (pokefirered/src/
-- battle_script_commands.c:2730, the knocked-off mons; BattleSim3 keeps it as
-- `mon.knockedOff`), so the monster that goes into the ball still holds it.  The foe's last `held`
-- event states exactly that party truth (`holding` is the knocked-off item;
-- THIEF's zero, TRICK's swap), so it wins over the sheet.  Either way the id
-- must be one this client uploaded (`ownItem`); anything else leaves the
-- monster with what it held (`current`, the engine mon this client rolled)
-- or nothing.
function M:caughtHolding(caught, current)
  local held
  local index = self:caughtFoeIndex(caught)
  if index ~= nil and type(self.foeHeld) == "table" then held = self.foeHeld[index] end
  if held == nil and type(caught) == "table" and tonumber(caught.heldItem) then
    held = math.floor(tonumber(caught.heldItem))
  end
  if held == nil then return nil end
  if self:ownItem(held) then return held end
  local had = type(current) == "table"
    and (tonumber(current.heldItem) or tonumber(current.item)) or 0
  return math.floor(had)
end

-- ------- Gold's held items (docs/plans/gen12-referee-fidelity.md, K2 / K3)
--
-- The Gen 3 four above, in Gold's dialect: items are string ids (the engine's
-- `mon.item`), and a `held` event says the item and whether the mon still has
-- it (`text`, `amount` 1 / 0) where Gen 3's says what it holds now.

-- Every held item this client itself put into the fight, by id: its own sheets
-- as uploaded and the wild / trainer sheets it uploaded for the other side.
-- Taken once, at the upload, before any `held` event has moved an item; a
-- screen that never uploaded (a harness) takes it at first use.  `ownItemSet`'s
-- twin, for `ownItem2`.
function M:ownItemSet2()
  local set = self.ownItems2
  if set then return set end
  set = {}
  local function add(list)
    if type(list) ~= "table" then return end
    for _, sheet in ipairs(list) do
      local id = type(sheet) == "table" and Wire.id(sheet.heldItem) or nil
      if id then set[id] = true end
    end
  end
  add(self.mine)
  add(self.wildParty)
  add(self.npcParty)
  self.ownItems2 = set
  return set
end

-- May this item enter this player's save?  Only one this client's own uploads
-- held: THIEF hands a mon whatever the other seat's sheet claimed, and a sheet
-- is a claim -- a key item, a ticket, a Master Ball the far side wrote onto its
-- monster is never written home, whoever the referee says it came from.  (A
-- monster losing its item needs no such test; see `applyHeld2`.)
function M:ownItem2(id)
  id = Wire.id(id)
  if not id then return false end
  return self:ownItemSet2()[id] == true
end

-- The engine's mail test, guarded like every Gold require here.
local function isMail2(itemId)
  if type(itemId) ~= "string" or itemId == "" then return false end
  local Mail = goldItemModule("Mail", "src.core.gen2.Mail")
  if not (Mail and type(Mail.isMail) == "function") then return false end
  local ok, is = pcall(Mail.isMail, itemId)
  return ok and is == true
end
M.isMail2 = isMail2

-- What a Gold `held` event leaves the mon holding: the item id when `amount`
-- is 1, nil when it is 0 -- and `false` for an event that says neither (no
-- `amount`, or a 1 with no item), which changes nothing anybody keeps.
local function heldAfter2(msg)
  local amount = tonumber(msg and msg.amount)
  if amount == 0 then return nil end
  if amount == 1 then
    local id = Wire.id(msg.text)
    if id then return id end
  end
  return false
end
M.heldAfter2 = heldAfter2

-- A Gold `held` event.
--
-- The foe's is remembered, by its party index, for a catch (`caughtHolding2`):
-- what the wild monster still holds at the throw is what the caught one keeps
-- (pokecrystal PokeBallEffect saves wEnemyMonItem across its LoadEnemyMon and
-- puts it back), so a berry it ate or an item a THIEF took is gone from it.
--
-- Ours goes onto the fight sheet always -- every K2 field re-read for the item
-- it now holds, so an AMULET COIN taken with THIEF counts at its next send-out
-- (`noteAmulet2`) -- and onto the save mon only where the cart keeps a fight's
-- item changes (KEEPS_HELD_MODES: never a fight between players), only for the
-- seat that is this client's own (`msg.side`), and only as an item this client
-- uploaded itself (`ownItem2`).  Losing an item needs no such proof -- the cart
-- writes NO_ITEM over the party struct for a berry eaten or a THIEF suffered --
-- except a letter: Thief cannot take mail and no Gold item effect consumes it,
-- so a referee saying a mail is gone is wrong, and the save's letter (which
-- `save.mail` keeps by party slot) is not orphaned on its word.
function M:applyHeld2(msg)
  if not (type(msg) == "table" and msg.side ~= nil) then return false end
  local holding = heldAfter2(msg)
  if holding == false then return false end
  local index = tonumber(msg.mon)
  index = index and index >= 0 and floor(index) or nil
  if msg.side ~= self.mySide then
    if index then
      self.foeHeld2 = self.foeHeld2 or {}
      self.foeHeld2[index] = holding or false
    end
    return false
  end
  -- Before the sheet below moves: what this client brought is what it
  -- uploaded, not what the referee has since said.
  self:ownItemSet2()
  local sheetIndex = index and (index + 1) or self.active
  local sheet = self.mine and self.mine[sheetIndex]
  -- A `mon` past what this client uploaded is a monster it cannot name: the
  -- save is never written through an index no sheet stands behind.
  if type(sheet) ~= "table" then return false end
  M.setSheetItem2(self.game, sheet, holding)
  if not KEEPS_HELD_MODES[self.mode] then return false end
  local mon = self:saveMon(sheetIndex)
  if type(mon) ~= "table" then return false end
  local had = (type(mon.item) == "string" and mon.item ~= "") and mon.item or nil
  if holding == had then return true end
  if holding ~= nil and not self:ownItem2(holding) then
    if not self.heldWarned2 then
      self.heldWarned2 = true
      mod.log:warn("the battle referee handed one of your POKeMON a %s, which "
        .. "nothing in this fight was holding, so it was not added to your save "
        .. "-- report this with the server you were playing on", holding)
    end
    return false
  end
  if had and isMail2(had) then
    if not self.mailWarned2 then
      self.mailWarned2 = true
      mod.log:warn("the battle referee took a letter (%s) off one of your POKeMON, "
        .. "which no move or item can do, so your save keeps it -- report this "
        .. "with the server you were playing on", had)
    end
    return false
  end
  mon.item = holding
  return true
end

-- What a caught Gold monster holds leaving the fight, by the foe's last `held`
-- event: the item it names when this client described that item itself
-- (`ownItem2`), else `false` -- nothing -- for a berry eaten, a THIEF suffered,
-- and an item this client never described alike.  nil when there was no `held`
-- about it, which leaves the engine monster holding what it already holds (the
-- item `rollWildItem2` gave it, or nothing).  pokecrystal PokeBallEffect keeps
-- wEnemyMonItem as the battle left it.
--
-- The foreign item is nothing and not "what the monster had": the wild monster
-- only comes to hold an item it was not rolled by a THIEF of its own, and THIEF
-- takes only when its user holds nothing (pokecrystal BattleCommand_Thief
-- `.enemy`, BattleSim2 `_thief`), so the item it was rolled is already eaten
-- or taken -- and the one it took is a claim this client cannot tell from a
-- forgery, which never enters the save.
function M:caughtHolding2(index)
  if not (type(self.foeHeld2) == "table" and index ~= nil) then return nil end
  local held = self.foeHeld2[index]
  if held == nil then return nil end
  if held ~= false and self:ownItem2(held) then return held end
  return false
end

-- pokecrystal CheckAmuletCoin (engine/battle/core.asm), in SendOutPlayerMon:
-- the player's monster coming out holding a HELD_AMULET_COIN item sets
-- wAmuletCoin, nothing clears it for the rest of the fight, and the win's
-- prize is doubled (WinTrainerBattle `.give_money` -> `.DoubleReward`).  Only
-- the player's own monster -- the cart reads wBattleMonItem and nothing of the
-- foe's.  Read off our sheet as it stands at the `send` (`applyHeld2` keeps it
-- on the item the monster holds now), by the K2 hold effect the sheet carries.
M.HELD_AMULET_COIN2 = "HELD_AMULET_COIN"
function M:noteAmulet2(msg)
  if not (type(msg) == "table" and msg.side == self.mySide) then return false end
  local index = tonumber(msg.mon)
  local sheet
  if type(self.mine) == "table" then
    if index then
      sheet = index >= 0 and self.mine[floor(index) + 1] or nil
    else
      sheet = self.mine[self.active or 1]
    end
  end
  if type(sheet) ~= "table" or sheet.heldItem == nil then return false end
  if sheet.holdEffect ~= M.HELD_AMULET_COIN2 then return false end
  self.amuletOut2 = true
  return true
end

-- Whether this fight's prize is doubled: an AMULET COIN came out on our seat.
function M:amuletCoin2()
  return self.amuletOut2 == true
end

-- One Gen 3 `ball` event as the ball-flow rows the arena and the classic page
-- already play.  `amount` is the shakes (0..3) or 4 for a catch, which rocks
-- three times and clicks.
function M:queueBall3(msg)
  local ballId = tonumber(msg.text)
  local toss = (ballId == 4 and "TOSS_ANIM") or (ballId == 3 and "GREATTOSS_ANIM")
    or "ULTRATOSS_ANIM"
  local caught = tonumber(msg.amount) == 4
  local shakes = caught and 3 or math.max(0, math.floor(tonumber(msg.amount) or 0))
  local function anim(text, amount)
    self.lines[#self.lines + 1] = {
      anim = text, slot = msg.slot, side = msg.side, amount = amount,
    }
  end
  anim(toss)
  anim("POOF_ANIM")
  if not caught and shakes == 0 then return end
  anim("HIDEPIC_ANIM")
  anim("SHAKE_ANIM", shakes)
  if not caught then
    anim("POOF_ANIM")
    anim("SHOWPIC_ANIM")
  end
end

-- ------- Red's and Gold's status animations, as this viewer's cart plays them
--
-- The Red referee names the sleeping and the confused monster's clip from
-- the cart's own branches (BattleSim Turn `_statusAnim`, wave 5): pokered
-- CheckPlayerStatusConditions plays SLP_PLAYER_ANIM *ahead of* FastAsleepText
-- and CONF_PLAYER_ANIM behind IsConfusedText; CheckEnemyStatusConditions
-- plays SLP_ANIM *behind* FastAsleepText and CONF_ANIM behind IsConfused
-- Text (engine/battle/core.asm).  The Gold referee states its ANIM_SLP /
-- ANIM_CONFUSED by the same four ids, placed alike (BattleSim2 Turn
-- `_statusAnim`: pokegold CheckPlayerTurn / CheckEnemyTurn), so this reads
-- both carts.  "The player" is the owner's rule
-- (docs/plans/gen12-referee-gaps-fix.md): against the computer side a, and in
-- a link fight *both* sides -- each seat carries its own console's variant.
-- So the screen across swaps it for a monster that is not its own: on this
-- viewer's cart that monster is the enemy's, and its clip is the enemy's
-- variant (and the other way round for one of ours named plain, which no
-- referee does today).  `behind` is true for a sleep clip turned into the
-- enemy's: the cart plays it after the line, so the caller holds it until the
-- line is queued.  Every other id comes back unchanged (BURN_PSN_ANIM has one
-- variant, faced by the seat it plays over).
local STATUS_ANIM_SWAP = {
  SLP_ANIM = "SLP_PLAYER_ANIM", SLP_PLAYER_ANIM = "SLP_ANIM",
  CONF_ANIM = "CONF_PLAYER_ANIM", CONF_PLAYER_ANIM = "CONF_ANIM",
}
function M.viewerAnim(anim, mine)
  local other = type(anim) == "string" and STATUS_ANIM_SWAP[anim] or nil
  if not other then return anim, false end
  local playerVariant = anim:find("_PLAYER_ANIM", 1, true) ~= nil
  if playerVariant == (mine == true) then return anim, false end
  return other, other == "SLP_ANIM"
end

-- The held rows (`viewerAnim`'s `behind`), onto the queue.
function M:flushAnimBehind()
  local rows = self.animBehind
  if not rows then return end
  self.animBehind = nil
  self.lines = self.lines or {}
  for _, row in ipairs(rows) do self.lines[#self.lines + 1] = row end
end

-- Gold's weather, read off the referee's own lines (pokecrystal
-- data/text/battle.asm, which src/BattleSim2/Effects.lua WEATHER_LINES holds
-- word for word): a start or a between-turn continuation names the sky the
-- field is under -- "RAIN" | "SUN" | "SAND", the arena's painter's keys
-- (Battlefield.weatherKey) -- and an end clears it (false).  nil for any
-- other line.  The cart draws no standing sky (the weather animation plays
-- under each of these lines); the arena's painter is this mod's, the same one
-- Gen 3's `weather` events drive, so Gold reads the same on it.
local WEATHER_KEYS2 = { rain = "RAIN", sun = "SUN", sandstorm = "SAND" }
local weatherByLine2 = nil
function M.weatherOfLine2(text)
  if type(text) ~= "string" then return nil end
  if not weatherByLine2 then
    if not Effects2 then Effects2 = need("BattleSim2/Effects") end
    weatherByLine2 = {}
    for kind, lines in pairs(Effects2.WEATHER_LINES or {}) do
      local key = WEATHER_KEYS2[kind]
      if key and type(lines) == "table" then
        if lines.start then weatherByLine2[lines.start] = key end
        if lines.continues then weatherByLine2[lines.continues] = key end
        if lines.ended then weatherByLine2[lines.ended] = false end
      end
    end
  end
  return weatherByLine2[text]
end

-- A queued Gen 3 state change reaching the head of the queue: the sky, a
-- picture, the substitute doll.  No hold -- the referee's sentence about it
-- is the next row.
function M:applyStateRow(row)
  local what = row and row.stateRow
  if what == "weather" then
    self.weatherShown = row.value or nil
    return true
  end
  local slot = row and row.slot ~= nil and self.slots[row.slot] or nil
  if not slot then return false end
  if what == "sub" then
    slot.substitute = row.value == true or nil
  elseif what == "form" then
    if row.speciesId ~= nil then
      slot.transformId = row.speciesId
    else
      slot.form = tonumber(row.form)
    end
    slot._bfFront = nil
    slot._bfFrontSpecies = nil
    slot.sprite = nil
    self:refreshSlotSprite(row.slot, row.slot == self:mySlot())
  end
  return true
end

-- The catch, the way Catching.storeCaught writes it: the catcher as original
-- trainer, the dex capture, where and when it was met (Gen.recordCatch ->
-- Gen3.recordCatch), the ball it was caught in, the fight's own ending HP /
-- status / held item, and a home -- the session party, else the PC by the
-- cart's own box rule (Storage.sendMonToPC, which also heals it the way the
-- PC does).
function M:grantCatch3(msg)
  local game = self.game
  local caught = type(msg) == "table" and type(msg.caught) == "table" and msg.caught or nil
  local mon = self.wildCatchMon
  if type(mon) == "table" and caught then
    Sheet3.applyToMon(mon, { hp = caught.hp, status = caught.status })
    local held = self:caughtHolding(caught, mon)
    if held then
      mon.heldItem = held
      mon.item = held
    end
  end
  if type(mon) ~= "table" and caught then
    mon = Sheet3.monFromSheet(caught)
    if type(mon) == "table" then
      local held = self:caughtHolding(caught, nil) or 0
      mon.heldItem = held
      mon.item = held
    end
  end
  if type(mon) ~= "table" then
    self:say("Caught, but could not\nadd to the party.")
    return
  end
  local session = Gen3.session() or (type(game) == "table" and game.session) or nil
  if type(session) ~= "table" then return end
  local ball = tonumber(self.caughtBall) or tonumber(caught and caught.ball)
  mon.pokeball = ball or tonumber(mon.pokeball) or 4
  local species = tonumber(mon.species or mon.speciesId)
  -- Every sentence below is this client's own, in the cart's font: the
  -- cart's spelling of the species (NIDORAN♀), which the wire's cannot carry.
  local label = Sheet3.localName({ nickname = "" }, species)
  local isNew = Gen.recordCatch(game, mon)
  session.party = type(session.party) == "table" and session.party or {}
  local destination, placed
  if #session.party < 6 then
    session.party[#session.party + 1] = mon
    destination = "party"
  else
    local Storage = Gen3.engine("src.core.game3.storage")
    local ok, sent = false, false
    if Storage and type(Storage.sendMonToPC) == "function" then
      ok, sent = pcall(Storage.sendMonToPC, session, mon)
    end
    if not (ok and sent) then
      self:say("But every BOX\nis full!")
      return
    end
    destination = "box"
    local okMsg, text = false, nil
    if type(Storage.pcTransferMessage) == "function" then
      okMsg, text = pcall(Storage.pcTransferMessage, session, label)
    end
    if okMsg and type(text) == "string" and text ~= "" then placed = text end
  end
  if isNew then self:say(Gen.dexAddedText(game, label)) end
  if destination == "party" then
    self:say(label .. " was\nadded to the party!")
  else
    self:say(placed or (label .. " was\nsent to the PC!"))
  end
  self:oweNickname(mon, label)
  M.announceCaught(self, game, mon, destination, isNew, self.caughtBall)
end

function M:finishLearn(row, learned)
  self.learning = nil
  if type(row) ~= "table" then return end
  LearnMove.drop(self.toLearn, row.mon, row.move)
  if learned then self:syncFightMoves(row.mon) end
end

function M:startLearn(row)
  if type(row) ~= "table" or type(row.mon) ~= "table" then return false end
  self.learning = row
  local opened = LearnMove.open(self.game, row.mon, row.move, function(learned)
    self:finishLearn(row, learned)
  end, { ui = self.ui, battle = true })
  if opened then return true end
  -- No forget UI on this build: keep the toLearn leftover for after-battle
  -- and announce the try so the award sequence still reads as a level-up.
  self.learning = nil
  local moveName
  if self:generation() == 3 then
    moveName = Gen3.moveName(row.move)
  else
    local data = self.game and self.game.data
    local def = type(data) == "table" and (data.moves or {})[row.move] or nil
    moveName = def and def.name
  end
  self:say((row.name or "?") .. " is trying to\nlearn "
    .. (moveName or tostring(row.move)) .. "!")
  return false
end

-- Record whatever an event said about a field slot.  Every event that names one
-- carries the HP that slot is now on, so one place reads it and the screen
-- never has to guess.
--
-- **A seat's occupant changes when the queued row says so, never when the
-- packet is parsed.** That is the invariant this screen and CoopBattle share,
-- and it is the whole of bug "the sent-out animation plays with the monster
-- already drawn". A `send` batched behind the knockout it replaces used to
-- relabel the seat here, at parse: the newcomer stood on the arena for the
-- two and a half seconds its own pop was still queued behind, and -- worse --
-- every one of the departing monster's exit rows then refused itself on its
-- own occupant stamp (`startDrain`, `startFaintFx`, `releasePic` all check
-- `slot.species ~= row.species`), so the monster that just fainted neither
-- drained nor sank. It was simply overwritten.
--
-- So an arrival into a seat that still has somebody on it is *parked* as
-- `slot.pending` and installed by `applySwap` where the queued `spawnfx` row
-- pops. This is CoopBattle's display shadow (`shownBattler` /
-- `src/CoopBattle.lua:3500-3525`), whose `applySwap` does exactly this for the
-- same reason and against the same failure. An arrival into an *empty* seat
-- lands immediately and is covered by `spawnHide` instead (`queueSpawnFx`);
-- both windows end at the same row.

-- The referee's reading of a condition, onto a seat or a parked arrival.
-- A `status` event with no token **cleared** it -- wake, thaw, item cure --
-- which is the contract in BattleSim/Events.lua. Every other event only
-- writes a condition when it states one: a residual `damage` carries the
-- status that dealt it, a `send` carries the newcomer's, and neither is
-- allowed to wipe a chip they never mentioned.
--
-- Confusion is a fight-local volatile, not a standing status: `confused=1/0`
-- is independent of PSN/SLP/… and a confused-only event must not clear them.
-- A send that omits the flag means the newcomer is not confused.
local function applyMsgStatus(target, msg)
  if type(target) ~= "table" or type(msg) ~= "table" then return end
  if msg.confused ~= nil then
    target.confused = (tonumber(msg.confused) or 0) == 1 or nil
  elseif msg.t == "send" then
    target.confused = nil
  end
  if msg.t == "status" then
    local status = msg.status
    if type(status) ~= "string" or status == "" then
      if msg.confused == nil then
        target.status = nil
      end
    else
      target.status = status
    end
  elseif msg.status ~= nil then
    target.status = msg.status
  end
end

function M:noteSlot(msg)
  local index = msg.slot
  if index == nil then return nil end
  local slot = self.slots[index]
  if not slot then
    slot = { species = nil, hp = 0, maxHp = 1 }
    self.slots[index] = slot
  end
  -- While an arrival is parked, the referee is talking about *it*: it is the
  -- monster the field holds, and the one still drawn is only finishing its
  -- exit. So a `damage` / `faint` / `status` that lands in the window is
  -- written to the parked record and never to the seat -- the departing
  -- monster's numbers are what its own queued rows are still animating
  -- against.
  --
  -- That window is not the rarity it was once taken for: **a voluntary switch
  -- and the attack that answers it resolve in the same batch**, so every hit
  -- landing on a monster the turn it walked out arrives here. `hp` moves and
  -- `shownHp` does not, which is what leaves the fall for `queueDrain` to file
  -- and `applySwap` to hand over -- see the pair of them.
  local parked = slot.pending
  if parked and not (msg.text and (msg.t == "send" or msg.t == "switch")) then
    if msg.maxHp ~= nil then parked.maxHp = msg.maxHp end
    if msg.hp ~= nil then
      parked.hp = msg.hp
    elseif msg.amount ~= nil and msg.t == "damage" then
      parked.hp = max(0, (parked.hp or 0) - msg.amount)
    end
    applyMsgStatus(parked, msg)
    if msg.t == "faint" then parked.hp = 0 end
    return slot
  end
  local fresh = false
  if msg.text and (msg.t == "send" or msg.t == "switch") then
    -- Occupied seat: park the newcomer until the queued `spawnfx` row
    -- (`applySwap`). Classic now queues that row too (no theatre ball), so
    -- a switch-and-hit in one batch keeps the departing pic on screen and
    -- the newcomer's bar starts where it walked out.
    if slot.species ~= nil then
      -- Somebody is still on this seat -- draining, sinking, or merely waiting
      -- for the `clearPic` behind their faint line. Park the newcomer whole:
      -- everything the seat is rebuilt from at the swap, and nothing of it
      -- written here. Deliberately not gated on the two names differing: a
      -- trainer fielding two of the same species is the case where a relabel
      -- is *least* visible and most wrong, and the sink it cancels is the same
      -- sink either way.
      slot.pending = {
        species = msg.text,
        speciesId = msg.speciesId,
        hp = msg.hp,
        -- Where this monster's bar *starts*, frozen at the HP it walked out
        -- with. `hp` above follows the referee for the whole of the park
        -- window; this does not, and the gap between the two is the fall the
        -- queue still owes. Without it an arrival that was struck before its
        -- own `spawnfx` row played was installed at its post-hit number with
        -- nothing left to animate -- which is why an attack on a monster that
        -- had just switched in read as no attack at all: no flash, no nudge,
        -- no impact burst and a bar that never moved.
        shownHp = msg.hp,
        -- What that HP is out of, when the referee stated it (PROTOCOL 24).
        -- Installed by `applySwap`, not written to the seat here: the bar
        -- underneath still belongs to the monster finishing its exit, and its
        -- own maximum is what its queued fall is being drawn against.
        maxHp = msg.maxHp,
        status = msg.status,
        -- The referee's, when it stated one (it has said so since PROTOCOL 22);
        -- otherwise filled by `arriveOnSeat` at the swap, own seat only.
        level = msg.level,
      }
      applyMsgStatus(slot.pending, msg)
      return slot
    end
    slot.species = msg.text
    -- Cleared before it is re-set, not merely overwritten: a referee that
    -- predates the field says nothing about the newcomer's species, and the
    -- previous occupant's id left standing would draw the monster that just
    -- walked off. Same for the level pill.
    slot.speciesId = msg.speciesId
    slot.level = msg.level
    slot.sprite = nil
    slot.icon = nil
    slot.koHold = nil
    -- Gen 3's picture state belongs to the monster that left (a Transform, a
    -- Castform form, the substitute doll); nil on every other generation.
    slot.transformId, slot.form, slot.substitute = nil, nil, nil
    fresh = true
  end
  -- **The referee's own maximum, when it states one (PROTOCOL 24).**
  -- Everything below it is the older reading of this wire, kept as the
  -- fallback rather than deleted: an event used to carry current HP and
  -- nothing else, so the largest HP a seat had ever shown was taken for its
  -- maximum. That is right for a monster that walks out whole and wrong for
  -- every one that does not -- a party mon that ended the last fight on 42 of
  -- 200 opened the next one with a *full* bar over the number 42. A stated
  -- maximum ends the guessing for that seat; `max` keeps it above whatever HP
  -- arrives with it, so a stream that disagrees with itself still draws a
  -- fraction rather than a bar past its own end.
  --
  -- A local level-up is the other disagreement: the referee never applies
  -- Experience, so a packet resolved before it heard of the level still
  -- carries the pre-level pair (on Gen 1 / Gen 2 that is the rest of the
  -- batch the level-up came in -- K9 tells it, `syncLevelHp`; on Gen 3, and
  -- for an evolution's growth, for good). `M.levelHpOwed` is that delta; it is
  -- added here rather than letting the packet take the climb back off the
  -- plate. A fresh send is a new occupant, so the delta is dropped and the
  -- referee's numbers win.
  if fresh then slot.levelHpGrown, slot.levelHpRefereed = 0, nil end
  local grown = (not fresh) and M.levelHpOwed(slot) or 0
  if msg.maxHp ~= nil then slot.maxHp = max(1, msg.maxHp) + grown end
  if msg.hp ~= nil then
    slot.hp = msg.hp
    if slot.hp > 0 and grown > 0 then slot.hp = slot.hp + grown end
    if slot.hp > slot.maxHp then slot.maxHp = slot.hp end
  elseif msg.amount ~= nil and msg.t == "damage" then
    slot.hp = max(0, slot.hp - msg.amount)
  end
  -- Seed the display clock, or keep it welded to truth where nothing draws
  -- from it. A monster that just walked on has nothing to animate down from,
  -- so its bar starts where the referee says it is.
  -- Seed the display clock, or keep it where it is so `queueDrain` can
  -- crawl. Classic used to weld `shownHp` here (`not usesBattlefield()`),
  -- which made every hit snap and left the queued drain with nothing to
  -- fall. Fresh send-outs still start at truth -- they have no prior bar.
  if slot.shownHp == nil or fresh then
    slot.shownHp = slot.hp
  end
  applyMsgStatus(slot, msg)
  -- Do not clear the pic here. Faint often arrives in the same batch as the
  -- move's `anim`, which is only played later from `lines` -- nil'ing the
  -- sprite the moment HP hits 0 made the mon vanish under the still-queued
  -- flash. `clearPic` (queued after the faint line) releases it.
  if msg.t == "faint" then
    slot.koHold = true
  end
  return slot
end

-- Which of ours is out.
--
-- **The referee says so where it can.** From round 6 a `send` / `switch` on
-- this client's own seat carries `mon` -- the 0-based index into the party
-- this client uploaded, the same space `exp` states its payee in -- so it goes
-- through the same two-step every other party-addressed field on this wire
-- takes (`paidSheetIndex`, then `savePartyIndex` wherever a save slot is
-- wanted). A `mon` the uploaded party has no sheet for is refused rather than
-- resolved, exactly as `gainExp` refuses one: the alternative is silently
-- pointing the move list at whichever sheet happens to sit at that number.
--
-- **Otherwise the name, preferring a living sheet.** Only the name crosses on
-- an older stream, and a party holding two monsters under one name would
-- always match the first -- including a first that is already face down, which
-- is precisely the monster the referee cannot have sent. Preferring a living
-- entry mirrors the referee's own `firstLiving` (src/BattleSim/Turn.lua:405),
-- so both ends land on the same sheet in every case a duplicate name can
-- produce; the dead-or-alive first match stays as the fallback so a stream
-- this client cannot reconcile behaves exactly as it did before.
--
-- This is `self.active`, which drives the move list, the party rows, the level
-- pill and the exp strip -- so a mis-point is visible, not merely academic.
function M:trackActive(species, msg)
  local mine = self.mine or {}
  local raw = msg and tonumber(msg.mon)
  if raw and raw == raw then
    local index = floor(raw) + 1
    if index >= 1 and (mine[index] ~= nil or #mine == 0) then
      self.active = index
      return
    end
  end
  local fallback = nil
  for index, mon in ipairs(mine) do
    if mon.species == species or mon.speciesId == species then
      if (tonumber(mon.hp) or 1) > 0 then
        self.active = index
        return
      end
      if fallback == nil then fallback = index end
    end
  end
  if fallback ~= nil then self.active = fallback end
end

-- The registry id for whoever is standing on a seat, art and all.
--
-- The referee states it outright from PROTOCOL 22 (`send` / `switch` carry
-- `speciesId`), and that is the only reading that survives a nickname: the
-- prose name a fight is narrated under is the *nickname* when the monster has
-- one, so a peer's MALBABISCO matched no pokedex row, drew no front pic and
-- printed no level -- a plain box on the arena where a monster should be.
--
-- Everything below it is the pre-22 ladder, kept whole: an id this build has no
-- row for is not preferred over a name it can still resolve, and a referee that
-- states none leaves the seat exactly where it was.
function M:seatSpeciesKey(slot, isPlayer)
  if type(slot) ~= "table" then return nil end
  -- Gen 3: the internal species number the referee stated (a Transform
  -- overrides it for the picture), which needs no pokedex to be believed.
  if self:generation() == 3 then
    local id3 = slot.transformId or slot.speciesId
    if tonumber(id3) then return tostring(math.floor(tonumber(id3))) end
    return self:speciesKeyFor(slot.species, isPlayer)
  end
  local id = slot.speciesId
  if type(id) == "string" and id ~= "" then
    local data = self.game and self.game.data
    local pokedex = data and data.pokemon
    if type(pokedex) == "table" and pokedex[id] then return id end
  end
  return self:speciesKeyFor(slot.species, isPlayer)
end

-- Map a narrated name back to a pokemon registry id for battle art.
function M:speciesKeyFor(label, preferMine)
  if type(label) ~= "string" or label == "" then return nil end
  if preferMine then
    for _, mon in ipairs(self.mine or {}) do
      if mon.species == label and mon.speciesId then return mon.speciesId end
    end
    local active = self.mine and self.mine[self.active]
    if active and active.species == label and active.speciesId then
      return active.speciesId
    end
  end
  local data = self.game and self.game.data
  local pokedex = data and data.pokemon
  if type(pokedex) ~= "table" then return nil end
  if pokedex[label] then return label end
  for id, def in pairs(pokedex) do
    if type(def) == "table" then
      local name = Wire.name(def.name or id)
      if name == label then return id end
    end
  end
  return nil
end

function M:refreshSlotSprite(index, isPlayer)
  local slot = self.slots[index]
  if not slot or not slot.species or (slot.hp or 0) <= 0 then
    if slot then slot.sprite = nil end
    return
  end
  -- Gen 3: the cart's own 64x64 pics -- the back pic on our own seat, the
  -- front pic opposite -- mon-aware for the monster this client owns.
  if self:generation() == 3 then
    local sp = tonumber(self:seatSpeciesKey(slot, isPlayer))
    if not sp then
      slot.sprite = false
      return
    end
    local own = isPlayer and self:saveMon(self.active) or nil
    if own and (tonumber(own.species) ~= sp or slot.transformId) then own = nil end
    local subject = own or sp
    local opts = { form = slot.form }
    local pic = isPlayer and Gen3.backPic(subject, opts) or Gen3.frontPic(subject, opts)
    -- `false` is "looked, and this cache has none": the classic page asks
    -- again only on nil (`gen3SeatModel`), so a missing pic is one read per
    -- arrival rather than one a frame -- the `_bfFront` convention.  Every
    -- `slot.sprite = nil` above and below is what re-arms the read.
    slot.sprite = pic and pic.image or false
    local monHint = isPlayer and self.mine and self.mine[self.active] or nil
    slot.level = slot.level or (monHint and monHint.level) or 1
    return
  end
  local data = self.game and self.game.data
  if not data then
    slot.sprite = nil
    return
  end
  local key = self:seatSpeciesKey(slot, isPlayer)
  if not key or not data.pokemon or not data.pokemon[key] then
    slot.sprite = nil
    return
  end
  local monHint = nil
  if isPlayer then
    monHint = self.mine and self.mine[self.active]
  end

  -- Gen 2: Gen2Compat's BattleState has no makeBattler. Resolve spriteFront /
  -- spriteBack the way ui/gen2/BattleState:pic does -- through
  -- `pokemon.sprite`, in the species palette (`Battlefield.gen2MonPic`) --
  -- because this is the pic the classic stage draws, and its zone turns the
  -- palette shader off: loaded raw it was a grey monster.
  if Gen.generation(self.game) == 2 then
    -- Only our own seat has a save mon behind it; see `seatFront`.
    local own = isPlayer and self:saveMon(self.active) or nil
    if own and own.species ~= key then own = nil end
    local ok, image = pcall(Battlefield.gen2MonPic, self.game, key,
      isPlayer and "back" or "front", (own and own.shiny) and true or false,
      own)
    if ok and image then
      slot.sprite = image
      slot.level = (monHint and monHint.level) or slot.level or 1
    else
      slot.sprite = nil
    end
    return
  end

  local eng = loadEngine()
  if not (eng and eng.BattleState and eng.BattleState.makeBattler) then
    slot.sprite = nil
    return
  end
  local stub = {
    species = key,
    nickname = slot.species,
    level = (monHint and monHint.level) or slot.level or 1,
    hp = slot.hp or 1,
    stats = {
      hp = slot.maxHp or 1,
      attack = 1, defense = 1, speed = 1, special = 1,
    },
    moves = (monHint and monHint.moves) or { { id = "TACKLE", pp = 1 } },
    status = slot.status,
  }
  local save = isPlayer and self.game and self.game.save or nil
  local ok, battler = pcall(eng.BattleState.makeBattler, data, stub, isPlayer, save)
  if ok and battler and battler.sprite then
    slot.sprite = battler.sprite
    slot.level = stub.level
  else
    slot.sprite = nil
  end
end

-- The display side of a monster walking onto a seat: the pic, the level the
-- pill prints, and the two exp clocks the strip is drawn from.
--
-- Split out because it happens at one of two moments and never at both. A seat
-- that was empty is furnished at parse (the `send` branch); a seat somebody was
-- still standing on is furnished by `applySwap`, at the swap, because until
-- then every one of these describes the monster that is still being shown out.
-- Nothing here touches the rules -- `self.active`, `mustReplace`, `liveMoves`
-- all move at parse, where the referee is already asking about them.
function M:arriveOnSeat(index, isPlayer)
  local slot = self.slots[index]
  if not slot then return false end
  if isPlayer then
    -- Cleared rather than recomputed: nil is what `seedExpClock` reads as "ask
    -- again", and the answer it wants comes off `self.active`, which is already
    -- pointing at the arrival by the time this runs.
    slot.shownExpFrac = nil
    slot.shownLevel = nil
    local mon = self.mine and self.mine[self.active]
    if type(mon) == "table" then
      if mon.level then slot.level = mon.level end
      -- Fill, don't clobber: a send that named the condition already wrote
      -- the seat, and a send that predates the field still gets the chip
      -- from the snapshot sheet.
      if slot.status == nil and mon.status then slot.status = mon.status end
    end
  end
  self:refreshSlotSprite(index, isPlayer)
  return true
end

function M:activeMon()
  local mon = self.mine and self.mine[self.active] or nil
  if mon and self.liveMoves then
    local copy = {}
    for k, v in pairs(mon) do copy[k] = v end
    copy.moves = self.liveMoves
    return copy
  end
  return mon
end

-- How it ended, from the only party that knows.
--
-- **No mmo.result goes out for this fight.**  The dual-client vote exists
-- because neither peer in a relayed battle could be believed about its own
-- win; here the intermediator did every roll, so it says who won and both hubs
-- ignore a client's report about a battle they ran.  Sessions never records a
-- `lastBattle` on this path, which is what makes that structural rather than a
-- rule somebody has to remember.
function M:onOutcome(msg)
  if self.finished then return end
  if msg.battle ~= self.battle then return end
  if self.expBatch then self:flushExp3() end
  self.pendingTurn = false
  self:finish(M.resultFor(msg, self.peerId), msg.reason, msg)
  if self:generation() == 3 then
    self:payDay3(msg)
  else
    self:payDay12(msg)
  end
end

-- ------- Gen 3: Pay Day
--
-- pret Cmd_givepaydaymoney (pokefirered/src/battle_script_commands.c:7064):
-- a battle the player's side won pays the coins Pay Day scattered, times the
-- battle's money multiplier, and says "PLAYER picked up ¥N!".  The referee
-- counts the coins (BattleSim3 `outcome().payDay`, side a's total, never in a
-- link fight); the multiplier and the wallet are this client's, the way the
-- engine's own battle keeps them (battle/init.lua give_payday_money_and_pickup
-- over battle/prize.lua Prize.payDay / Prize.payDayMessage).

-- pret include/constants/hold_effects.h HOLD_EFFECT_DOUBLE_PRIZE (AMULET COIN).
local HOLD_EFFECT_DOUBLE_PRIZE = 32
M.HOLD_EFFECT_DOUBLE_PRIZE = HOLD_EFFECT_DOUBLE_PRIZE

-- The hold effect of one item id: the cart's item row first (Gen3.itemInfo),
-- then the hold effect a sheet this client uploaded stated for that same item
-- (`uploadHolds`, taken at the upload like `ownItemSet`).  0 for no item.
function M:holdEffect3(itemId)
  local id = tonumber(itemId)
  if not id or id <= 0 then return 0 end
  id = math.floor(id)
  local info = Gen3.itemInfo(id)
  local he = type(info) == "table" and tonumber(info.holdEffect) or nil
  if he then return math.floor(he) end
  local holds = self:uploadHolds()
  return holds[id] or 0
end

-- item id -> hold effect, as this client's own uploads stated them.  Taken at
-- the upload (`start`), before any `held` event can move an item onto a sheet
-- whose stated hold effect belonged to another; a screen that never uploaded
-- (a harness) takes it at first use.
function M:uploadHolds()
  local holds = self.uploadHoldMap
  if holds then return holds end
  holds = {}
  local function add(list)
    if type(list) ~= "table" then return end
    for _, sheet in ipairs(list) do
      local id = type(sheet) == "table" and tonumber(sheet.heldItem) or nil
      local he = type(sheet) == "table" and tonumber(sheet.holdEffect) or nil
      if id and id > 0 and he then holds[math.floor(id)] = math.floor(he) end
    end
  end
  add(self.mine)
  add(self.wildParty)
  add(self.npcParty)
  self.uploadHoldMap = holds
  return holds
end

-- A `send`: did an AMULET COIN just come out?  pret ItemBattleEffects
-- ITEMEFFECT_ON_SWITCH_IN (the engine's held_items.lua onSwitchIn) sets the
-- battle's money multiplier to 2 for a holder on the player's side, and --
-- FireRed / LeafGreen only; Emerald's `amuletCoinPlayerOnly` -- for one on
-- the foe's.  Read at the switch-in, as the cart reads it: the item the mon
-- holds *now* (a `held` event may have moved one -- TRICK hands a coin to a
-- mon that only counts once it next comes out), and a multiplier once set
-- stays set for the rest of the fight.
--
-- Our seat's sheets are ours; the foe's are the wild / trainer sheets this
-- client uploaded for side b (a solo or hub-wild fight), whose `held` events
-- `applyHeld` keeps in `foeHeld`.  A foe this client never described (a peer)
-- is unknown and counts for nothing -- and a fight against a peer pays no
-- Pay Day anyway.
function M:noteAmulet3(msg)
  local index = tonumber(msg and msg.mon)
  if not index or index < 0 then return false end
  index = math.floor(index)
  local mine = msg.side == self.mySide
  local held
  if mine then
    local sheet = self.mine and self.mine[index + 1]
    held = type(sheet) == "table" and sheet.heldItem or nil
  else
    local foes = self.wildParty or self.npcParty
    local sheet = type(foes) == "table" and foes[index + 1] or nil
    held = self.foeHeld and self.foeHeld[index]
    if held == nil and type(sheet) == "table" then held = sheet.heldItem end
  end
  if self:holdEffect3(held) ~= HOLD_EFFECT_DOUBLE_PRIZE then return false end
  if mine then self.amuletMine = true else self.amuletFoe = true end
  return true
end

-- Does an AMULET COIN on the foe's side count?  The running cart's battle
-- profile says (Emerald's `amuletCoinPlayerOnly`); a build without the
-- profile module falls back to the cart family, which is the same answer.
local function amuletCoinPlayerOnly()
  local BP = Gen3.engine("src.core.game3.battle.profile")
  if BP and type(BP.get) == "function" then
    local ok, bp = pcall(BP.get, Gen3.session())
    if ok and type(bp) == "table" and type(bp.rules) == "table" then
      return bp.rules.amuletCoinPlayerOnly == true
    end
  end
  return Gen3.family() == "rse"
end

-- This fight's money multiplier (gBattleStruct->moneyMultiplier): 2 once an
-- AMULET COIN has come out where the cart counts it, else 1.
function M:moneyMultiplier3()
  if self.amuletMine then return 2 end
  if self.amuletFoe and not amuletCoinPlayerOnly() then return 2 end
  return 1
end

-- Pay the coins an outcome reports, once, and owe the line.
--
-- Paid only to a player the outcome makes a winner on side a -- the side the
-- referee counts the coins for -- and never in a link fight (the referee sends
-- none there; this is the belt).  The money lands now, the moment the verdict
-- does, so nothing between here and the screen closing can lose it; the line
-- waits for the ending to finish printing (`update`'s over branch), which puts
-- it where the cart says it: after the knockout's exp, and after whatever the
-- caller prints behind `onOutcome` -- src/SoloBattle.lua's defeated line and
-- trainer prize, which the cart's BattleScript_LocalTrainerBattleWon says
-- before BattleScript_PayDayMoneyAndPickUpItems.  Answers the amount paid
-- (the coins times the multiplier), 0 when nothing was owed.
function M:payDay3(msg)
  if self.payDayPaid ~= nil then return 0 end
  local coins = tonumber(type(msg) == "table" and msg.payDay or nil)
  if not coins or coins < 1 then return 0 end
  coins = math.floor(coins)
  if LINK_MODES[self.mode] or self.mySide ~= "a" or self.result ~= "win" then return 0 end
  self.payDayPaid = 0
  local session = Gen3.session()
  if type(session) ~= "table" then
    mod.log:warn("this fight's Pay Day coins could not be paid because no save "
      .. "is loaded -- start or continue a game before battling; the fight's "
      .. "result still counts")
    return 0
  end
  local mult = self:moneyMultiplier3()
  local Prize = Gen3.engine("src.core.game3.battle.prize")
  local bonus
  if Prize and type(Prize.payDay) == "function" then
    local ok, paid = pcall(Prize.payDay, session, coins, { moneyMultiplier = mult })
    bonus = ok and tonumber(paid) or nil
  end
  if not bonus then
    -- The engine's arithmetic without the engine: coins x multiplier into the
    -- wallet, capped where the cart caps money (Prize.MAX_MONEY).
    bonus = coins * mult
    local before = tonumber(session.money) or 0
    session.money = math.min(999999, before + bonus)
  end
  bonus = math.floor(bonus)
  if bonus <= 0 then return 0 end
  self.payDayPaid = bonus
  local name = playerName(self.game)
  local text
  if Prize and type(Prize.payDayMessage) == "function" then
    local ok, line = pcall(Prize.payDayMessage, name, bonus)
    if ok and type(line) == "string" and line ~= "" then text = line end
  end
  -- pret's buffer is a halfword (PREPARE_HWORD_NUMBER_BUFFER): a doubled
  -- 65535 prints as what fits, exactly as Prize.payDayMessage does.
  self.payDayLine = text or (("%s picked up\n¥%d!"):format(name, bonus % 65536))
  return bonus
end

-- ------- Red and Gold: Pay Day (contract K11 of docs/plans/gen12-referee-gaps-fix.md)
--
-- The referee counts the pot (`outcome().payDay`, side a's whole pile -- on
-- Red it includes the computer's own PAY DAY coins, pokered's
-- wTotalPayDayMoney; Gold's wPayDayMoney likewise) and reports it on a fight
-- against the computer only; the wallet and Gold's AMULET COIN are this
-- client's, as they are the cart's:
--
--   Red   EndOfBattle (engine/battle/end_of_battle.asm): outside a link
--         battle, with wBattleResult 0, the pot is added to the player's
--         money (AddBCD, which saturates the three BCD bytes at 999999) and
--         "<PLAYER> picked up ¥N!" is printed (_PickUpPayDayMoneyText,
--         text_bcd LEADING_ZEROES | LEFT_ALIGN: the number as it is).
--         wBattleResult is 0 on a win and on the escapes that never write
--         it -- a TELEPORT / ROAR / WHIRLWIND by either side
--         (SwitchAndTeleportEffect sets wEscapedFromBattle only), a wild
--         monster's flight, a POKé DOLL -- so Red pays those too.  The
--         player's own RUN writes 2 (TryRunningFromBattle `.canEscape`) and
--         a catch writes 2, so neither pays.  The referee tells them apart
--         (BattleSim Turn `_payDayOn`): a `run` outcome carries `payDay` only
--         for an escape that pays, and this pays whatever it carries,
--         whichever side the escape leaves in `losers` -- the player who
--         TELEPORTs away fled, and is still the one who picks the coins up.
--   Gold  ExitBattle -> CheckPayDay (engine/battle/core.asm, pokecrystal and
--         pokegold): on a WIN only (a flee is a DRAW), the pot is doubled
--         under wAmuletCoin (`sla` / `rl`, saturating at $ffffff), paid with
--         AddBattleMoneyToAccount (clamped at MAX_MONEY 999999), and
--         BattleText_PlayerPickedUpPayDayMoney says the doubled pot
--         ("<PLAYER> picked up / ¥N!", text_decimal 3 bytes, 6 digits).
--
-- Paid only where the cart keeps what a fight does (KEEPS_HELD_MODES: wild,
-- coop_wild, coop_npc -- a link fight pays nothing, and the referee sends
-- none there; this is the belt), and only to a player on side a, the side the
-- pot is counted for.  Once per fight; the money lands with the verdict and
-- the line waits for the ending to finish printing (`sayPayDay3`), where both
-- carts print it: after the knockout's exp and the trainer's prize.
-- Answers the amount the line names (the pot, doubled on Gold under an AMULET
-- COIN), 0 when nothing was owed.
function M:payDay12(msg)
  if self.payDayPaid ~= nil then return 0 end
  local coins = tonumber(type(msg) == "table" and msg.payDay or nil)
  if not coins or coins ~= coins or coins < 1 then return 0 end
  coins = min(floor(coins), Wire.PAYDAY12_MAX)
  if not KEEPS_HELD_MODES[self.mode] or self.mySide ~= "a" then return 0 end
  local generation = self:generation()
  local won = self.result == "win"
  -- Red's paying escape keeps wBattleResult at 0 (the referee states the pot
  -- only for one).  Gold's every escape -- ours, or a foe that fled with
  -- side a left the winner -- is a DRAW (SetBattleDraw) and ExitBattle skips
  -- CheckPayDay on one, so a Gold `run` pays nothing whatever it carries;
  -- its referee states no pot on one either.
  local ran = type(msg) == "table" and msg.reason == "run"
  if ran and generation ~= 1 then return 0 end
  if not (won or ran) then return 0 end
  self.payDayPaid = 0
  local save = self.game and self.game.save
  if type(save) ~= "table" then
    mod.log:warn("this fight's Pay Day coins could not be paid because no save "
      .. "is loaded -- start or continue a game before battling; the fight's "
      .. "result still counts")
    return 0
  end
  local pot = coins
  if generation == 2 and self:amuletCoin2() then pot = coins * 2 end
  M.addMoney(save, pot)
  self.payDayPaid = pot
  self.payDayLine = M.payDayText(playerName(self.game), pot)
  return pot
end

-- The wallet, capped where both carts cap it (pokered AddBCD's 999999,
-- pokecrystal AddBattleMoneyToAccount's MAX_MONEY), through the save format
-- the boot keeps money in (Gen.money).  Shared with src/CoopBattle.lua.
M.MONEY_MAX = 999999
function M.addMoney(save, amount)
  if type(save) ~= "table" then return 0 end
  amount = floor(tonumber(amount) or 0)
  if amount <= 0 then return 0 end
  local before = tonumber(Gen.money.get(save)) or 0
  local after = min(M.MONEY_MAX, before + amount)
  Gen.money.set(save, after)
  return after - before
end

-- The carts' Pay Day line, both of them the same words (pokered
-- _PickUpPayDayMoneyText, pokecrystal / pokegold
-- BattleText_PlayerPickedUpPayDayMoney): `text "<PLAYER> picked up"`,
-- `line "¥..."`, `!`, the number as it is (Red's left-aligned BCD without
-- leading zeroes; Gold's `text_decimal` of the pot).  Gold's printer has six
-- digit places, and only an AMULET COIN doubling a pot already past 499999
-- could need a seventh -- no fight scatters that much (a PAY DAY that lands
-- scatters twice its user's level) -- so the whole number is printed rather
-- than a cart's overflow tile.
function M.payDayText(name, amount)
  amount = max(0, floor(tonumber(amount) or 0))
  return ("%s picked up\n¥%d!"):format(tostring(name or "PLAYER"), amount)
end

-- Say the owed Pay Day line, once (Gen 3's `payDay3` and Red / Gold's
-- `payDay12` both leave it here).  True when it queued one (the caller then
-- lets the queue print it before anything else happens).
function M:sayPayDay3()
  local line = self.payDayLine
  if not line then return false end
  self.payDayLine = nil
  self:say(line)
  return true
end

-- This player's result, worked out from who is named rather than from the
-- outcome token.
--
-- `outcome` is stated from the *field's* point of view -- "win" means the
-- winners list won -- so it is the same value in both clients' copies of the
-- message and says nothing on its own about the recipient.  The peer's id is
-- what turns it into a sentence: the side they are not on is ours.  A draw
-- carries no lists at all (Wire refuses an empty one), which is why the
-- absence is read as a draw rather than as a missing field.
function M.resultFor(msg, peerId)
  if peerId then
    if M.holds(msg.winners, peerId) then return "loss" end
    if M.holds(msg.losers, peerId) then return "win" end
  end
  return "draw"
end

-- The same verdict read the other way round: from this client's *own* id.
--
-- A 1v1 can reason from the peer because there is exactly one of them.  A
-- 2-on-2 cannot -- four ids arrive, two of them allies -- so the only question
-- with a single answer is "am I named", and it is asked here rather than in the
-- co-op screen so both readings of one message live side by side.
function M.resultForSelf(msg, selfId)
  if selfId then
    if M.holds(msg.winners, selfId) then return "win" end
    if M.holds(msg.losers, selfId) then return "loss" end
  end
  return "draw"
end

local ENDINGS = {
  win  = "You won!",
  loss = "You lost!",
  draw = "It was a draw.",
}

-- Why it ended, for the reasons a sentence exists for.  An unknown token --
-- a newer intermediator naming something this build cannot phrase -- is
-- deliberately silent rather than printed raw: the result is the part that
-- matters and it has already landed.
--
-- No `catch`: every referee says the catch itself, in its cart's words, as
-- one line -- pokered ItemUseBall's ItemUseBallText05 "All right! <MON> was
-- caught!" (BattleSim Turn, wave 5), pokecrystal / pokegold Text_BallCaught
-- "Gotcha! <MON> was caught!" (BattleSim2 Turn's ball branch), Gen 3's
-- "Gotcha! <MON> was caught!" -- so a "Gotcha!" of this screen's under it was
-- a line said twice.
local REASONS = {
  timeout    = "Nobody answered\nin time.",
  disconnect = "The link was lost.",
  run        = "Someone ran away!",
  forfeit    = "Someone gave up.",
  agree      = "The battle was\ncalled off.",
}

-- An escape from a wild fight, in the carts' words, said once.
--
-- The player's own RUN ends on GotAwayText, "Got away safely!" (pokered
-- TryRunningFromBattle `.canEscape`; pokecrystal TryToRunAwayFromBattle
-- `.fled`, after a SMOKE BALL's own line too), and nothing else -- no win or
-- loss line.  A move's escape ends on the move's line instead: pokered
-- SwitchAndTeleportEffect's "<USER> ran from battle!" / "<TARGET> ran away
-- scared!" / "<TARGET> was blown away!", pokecrystal BattleCommand_Teleport's
-- "<USER> fled from battle!", BattleCommand_ForceSwitch's "<TARGET> fled in
-- fear!" (ROAR) / "<TARGET> was blown away!" -- and a POKé DOLL's.  Red's
-- doll ends on its use line alone: ItemUsePokeDoll sets wEscapedFromBattle
-- behind PrintItemUseTextAndRemoveItem's "<PLAYER> used POKé DOLL!" and the
-- cart prints nothing after it (the referee's "<PLAYER> used POKe DOLL!",
-- BattleSim Turn `_resolveOneItem`, printed only in a wild fight); Gold's
-- ends on its own, ItemUsedText's "<PLAYER> used the POKé DOLL." --
-- PokeDollEffect sets wForcedSwitch and a DRAW behind UseItemText and prints
-- nothing more (pokegold engine/items/item_effects.asm; BattleSim2 Turn's
-- doll branch).  Both tails are read with the accent or without (the
-- referees' spellings).  The Red referee says "Got
-- away safely!" itself for a coop_wild runner (BattleSim Turn `_tryRun`, the
-- roll R1d added), Gold's too (wave 5); SoloBattle rolls a solo wild RUN on
-- the client and says nothing on a success.  So the ending says it only when
-- the stream did not, and the old "Someone ran away!" no longer follows an
-- escape the referee had already narrated.  A fight between players keeps
-- its concession lines.
M.GOT_AWAY = "Got away safely!"
local ESCAPE_TAILS = {
  " ran from battle!", " ran away scared!", " was blown away!", " fled from battle!",
  " fled in fear!", " used POKe DOLL!", " used POKé DOLL!",
  " used the POKe DOLL.", " used the POKé DOLL.",
}
function M.escapeLine(text)
  if type(text) ~= "string" then return false end
  if text == M.GOT_AWAY then return true end
  for _, tail in ipairs(ESCAPE_TAILS) do
    if #text > #tail and text:sub(-#tail) == tail then return true end
  end
  return false
end

function M:grantCatch(msg)
  if self:generation() == 3 then return self:grantCatch3(msg) end
  local mon = self.wildCatchMon
  if not mon and msg and msg.caught then
    -- Sheet-only path: cannot rebuild a full engine mon without ROM data.
    self:say("Caught, but could not\nadd to the party.")
    return
  end
  if not mon then return end
  local game = self.game
  local save = game and game.save
  if not save then return end
  -- Gold: the item the wild monster still holds at the throw (`caughtHolding2`
  -- -- the lone wild sheet is the referee's party index 0).
  if self:generation() == 2 then
    local held = self:caughtHolding2(0)
    if held == false then
      mon.item = nil
    elseif held ~= nil then
      mon.item = held
    end
  end
  -- The name the prompt will ask about: a fresh catch has no nickname, so
  -- this is the species record's display name -- the same thing the engine's
  -- own catch prompt asks about (BattleState:storeCaughtMon passes
  -- `self.enemy.name`).
  local label = speciesName(game and game.data, mon)
  -- The #DEX, the OT stamp and (on Gold) the UNOWN form, before the monster
  -- is put anywhere -- the order `BattleState:storeCaughtMon` writes them in,
  -- and the reason a catch with nowhere to go still counts as seen.
  local isNew = Gen.recordCatch(game, mon)
  local okParty, Party = pcall(require, "src.pokemon.Party")
  local okBoxes, Boxes = pcall(require, "src.pokemon.Boxes")
  local destination
  if okParty and Party.add(save.party, mon) then
    destination = "party"
  elseif okBoxes and Boxes.deposit(save, mon) then
    destination = "box"
  else
    self:say("But every BOX\nis full!")
    return
  end
  -- The new-entry line goes in front of the line saying where the monster
  -- went, which is where the engine prints it. The #DEX *page* that follows
  -- it there is deliberately not opened: this screen has one queue and one
  -- prompt seam, and a dex entry over a co-op battle three other people are
  -- still leaving is a screen nobody asked for.
  if isNew then self:say(Gen.dexAddedText(game, label)) end
  if destination == "party" then
    self:say((mon.nickname or mon.species or "It") .. " was\nadded to the party!")
  else
    self:say((mon.nickname or mon.species or "It") .. " was\nsent to the PC!")
  end
  -- Asked for a boxed catch too: AddPartyMon and SendNewMonToBox both call
  -- AskName on the cart (item_effects.asm), so a full party costs the player
  -- the slot, never the naming.
  self:oweNickname(mon, label)
  M.announceCaught(self, game, mon, destination, isNew, self.caughtBall)
end

-- The engine's own `pokemon.caught`, for a catch the engine never saw.
--
-- **Emitted through `src.mods.Runtime` rather than `mod.events:emit`**, which
-- is the one place this mod reaches past the facade on purpose. The facade
-- namespaces a mod's emits to `mod.<id>.*` so no mod can forge an engine
-- event, and CoopBattle's own `announce` obeys that rule for battle
-- start/end. This is the other case, and src/Trade2.lua already draws the
-- line here: that file *is* the Gen 2 TradeSession the engine has not got, so
-- it emits `pokemon.received` and `trade.completed` under the engine's names
-- rather than inventing private ones nothing listens for. A caught monster is
-- the same -- `grantCatch` stands in for `storeCaughtMon`, which emits this,
-- and a dex tracker or a shiny logger listening for `pokemon.caught` should
-- see an MMO catch exactly as it sees a solo one. Announcing it under a
-- private name instead would mean every such mod needs an rby_mmo special
-- case to keep working in an MMO game, which is the outcome the rule exists
-- to prevent, not to cause.
--
-- Same payload keys as both engine sites, so one listener covers all three:
-- `isNew` is the dex answer read before the stamp, `destination` is the home
-- the monster actually got, and `ball` is the id this client last threw.
-- `battle` is this screen and not a `BattleState` -- there is no BattleState
-- in a mediated fight -- so a listener that reaches into it must check what
-- it got. Wrapped in pcall + `wants` for the same reason every hot path in
-- this mod is: a listener that throws must not take the catch down with it.
function M.announceCaught(screen, game, mon, destination, isNew, ball)
  pcall(function()
    local Runtime = require("src.mods.Runtime")
    if type(Runtime.emit) ~= "function" then return end
    if Runtime.wants and not Runtime.wants("pokemon.caught") then return end
    local payload = {
      battle = screen, mon = mon, species = mon.species,
      isNew = isNew and true or false, ball = ball,
      destination = destination, game = game,
    }
    -- Gen 3's own emit (battle/catching.lua emit_caught) names the species
    -- and the ball in words and carries the numbers beside them; a listener
    -- written against the engine's catch sees the same keys here.
    if Gen3.active() and type(mon.species) == "number" then
      payload.species = Gen3.speciesName(mon.species) or mon.species
      payload.speciesId = mon.species
      payload.ballId = tonumber(ball)
      payload.ball = tonumber(ball) and Gen3.itemName(tonumber(ball)) or ball
    end
    Runtime.emit("pokemon.caught", payload)
  end)
end

-- ------- the nickname the catcher is owed
--
-- Recorded here and asked *later*, and the gap is the whole point: this runs
-- inside `finish`, behind the referee's catch line and while the rest of
-- the ending is still to print.  A grid pushed now would land on top of the
-- lines that say what just happened -- the player would be typing a name for
-- a catch they have not been told about yet.
--
-- So it waits for the message queue to run dry (see `update`'s over branch),
-- which is exactly where the engine asks it: after the caught text, and
-- before the player is allowed to leave the battle.
function M:oweNickname(mon, label)
  if type(mon) ~= "table" then return false end
  self.owedNickname = { mon = mon, label = label }
  return true
end

-- Put the prompt up, once, when there is nothing left on screen to read.
--
-- Returns true when it took the frame -- the screen is no longer the top of
-- the stack, so the A that would have closed the battle must not also be
-- read as one.  The record is cleared before the push rather than after the
-- answer: a prompt that failed to open is not owed a second attempt, and the
-- fight has to stay leavable either way.
function M:askOwedNickname()
  local owed = self.owedNickname
  if not owed then return false end
  self.owedNickname = nil
  local ui = self.ui
  if not (ui and type(ui.askNickname) == "function" and self.game) then
    return false
  end
  local ok = pcall(function()
    ui:askNickname(self.game, owed.mon, owed.label)
  end)
  return ok
end

function M:finish(result, reason, msg)
  if self.finished then return end
  self.finished = true
  self.pendingItem = nil
  self.pendingItemSlot = nil
  self.result = result or "draw"
  self.phase = "over"
  self.cursor = 1
  -- Fanfare once the outcome is known. Same guard CoopBattle uses so a second
  -- finish path cannot restart the jingle.
  --
  -- On the arena the outcome can land while the loser's bar is still falling
  -- and its monster has not sunk yet, so the jingle is held until those rows
  -- have played (#36 -- a fanfare over a KO that still looks alive was the
  -- reported bug). The classic 160x144 path queues no such rows and fires
  -- here exactly as it did.
  --
  -- Never for an escape on Red / Gold: a "win" with reason `run` is the foe
  -- leaving -- a wild monster's flight, or the player's ROAR / WHIRLWIND
  -- sending it off (the target's side leaves: BattleSim Turn `_concedeRun`
  -- since FX-R1, BattleSim2's) -- and the carts play the fanfare from the
  -- knockout alone (pokered FaintEnemyPokemon's `.wild_win` /
  -- TrainerBattleVictory, pokecrystal's the same way): SwitchAndTeleportEffect
  -- and BattleCommand_ForceSwitch end the fight on their line with no music.
  local escaped = reason == "run" and self:generation() ~= 3
  if self.result == "win" and not escaped then
    if self:usesBattlefield() and self:hasPendingHpFx() then
      self.victoryMusicHeld = true
    else
      self:playVictoryMusic()
    end
  end
  -- Anything the arena is still holding with nothing left to release it is
  -- dropped here too -- but only when the arena owes nothing, which is the
  -- same question the fanfare above just asked. It has to be gated on that:
  -- the outcome lands while the rows that show it are still queued, and on a
  -- catch those rows *are* the throw. Snapping here would stand the caught
  -- monster back up on its seat one line before the catch line printed, and on an
  -- ordinary win it would cut the last KO short. When the answer is "something
  -- is still owed", the rows themselves finish the job: a KO's `clearPic` takes
  -- the sink down with the pic, a failed throw's closing burst clears the flow,
  -- a catch keeps it (nothing undoes a ball that was never opened), and `exit`
  -- clears whatever is left on the way out.
  if not self:hasPendingHpFx() then self:snapDisplay() end
  if reason == "catch" and result == "win" then
    -- Every referee has already said it, the cart's way (REASONS: Red's "All
    -- right! X was caught!", Gold's and Gen 3's "Gotcha!"); a line of this
    -- screen's under it would be its echo.
    self:grantCatch(msg)
  elseif self:generation() == 3 then
    self:sayEnding3(reason)
  elseif reason == "run" and self.mode == "wild" then
    -- An escape (M.GOT_AWAY): the cart's one line, never a win or a loss
    -- line, and never twice.  The foe's own escape said its line already.
    local mine = self.mySide or "a"
    if not self.escapeSaid and (self.ranSide == nil or self.ranSide == mine) then
      self:say(M.GOT_AWAY)
    end
  else
    self:say(ENDINGS[self.result] or ENDINGS.draw)
    local why = REASONS[reason]
    if why then self:say(why) end
  end
end

-- How a Gen 3 fight ends in words: the cart's, and only the cart's.
--
-- A fight between players ends on the cart's link-battle line (pret
-- BufferStringBattle STRINGID_BATTLEEND: "Player defeated\nBOB!" / "Player
-- lost against\nBOB!" / "...battled to a draw against..."), then whatever
-- this screen's own reason adds (a timeout, a dropped link -- nothing the cart
-- has a sentence for).  A wild or NPC fight ends on no generic line at all:
-- the referee has narrated the knockout, the escape or the catch in the
-- cart's words, and the caller (src/SoloBattle.lua) prints the cart's own
-- after-words -- the defeated line and the prize, or the whiteout -- so a
-- "You won!" ahead of them was a line the cart never shows.  A run needs no
-- reason line either: "Got away safely!" is the referee's.
function M:sayEnding3(reason)
  if LINK_MODES[self.mode] then
    local outcome = (self.result == "win" and "won") or (self.result == "loss" and "lost")
      or "drew"
    self:say(Gen3.battleText("STRINGID_BATTLEEND", {
      outcome = outcome, linkOpponent1Name = tostring(self.peerName or "?"),
    }) or ENDINGS[self.result] or ENDINGS.draw)
  elseif reason == "run" then
    return
  end
  local why = REASONS[reason]
  if why then self:say(why) end
end

-- A Gen 3 NPC trainer the way the cart names one: CLASS NAME.  A few cart rows
-- spell part of the class into the name as well -- FireRed's trainer 511 is
-- class "POKéMON PROF." named "PROF. OAK" -- and joined naively that reads
-- "POKéMON PROF. PROF. OAK"; the repeated word is said once.  nil without a
-- trainer record (the caller falls back to the peer name).
function M.trainerLabel3(trainer)
  if type(trainer) ~= "table" then return nil end
  local function str(v) return (type(v) == "string" and v ~= "") and v or nil end
  local class = str(trainer.className) or str(trainer.trainerClassName)
  local name = str(trainer.trainerName)
  if not (class and name) then return name or class end
  local upperName, upperClass = name:upper(), class:upper()
  if upperName:sub(1, #upperClass) == upperClass then return name end
  local last = upperClass:match("(%S+)%s*$")
  local first, rest = name:match("^(%S+)%s+(.+)$")
  if last and first and first:upper() == last then return class .. " " .. rest end
  return class .. " " .. name
end

-- ------- outbound

-- The hub link came back under a fight that is still open.
--
-- Both hubs already run reconnect grace + sim.reconnect(); until PROTOCOL 10's
-- clients actually sent mmo.battle_reconnect, every drop rode to forfeit. This
-- is that message. Idempotent per drop cycle: Sessions / Coop call it when
-- transport:isReady() flips false→true, and the headless suite calls it
-- directly as notifyReconnect.
function M:onTransportReady()
  if self.finished or self.left then return false end
  if not (self.transport and self.battle) then return false end
  if self.reconnectSent then return false end
  self.reconnectSent = true
  self.awaitingReconnect = false
  self.transport:send(Wire.BATTLE_RECONNECT, { battle = self.battle })
  return true
end

function M:notifyReconnect()
  return self:onTransportReady()
end

-- The hub link dropped under a live fight. Narrate and wait: finishing here
-- would take the screen away before the intermediator's grace (or a reconnect)
-- can resolve it.
function M:onTransportLost()
  if self.finished or self.left then return end
  if self.awaitingReconnect then return end
  self.awaitingReconnect = true
  self.reconnectSent = false
  self:say("Connection lost.\nWaiting to reconnect...")
end

-- One turn's intent, through the shared sender so a 1v1 and a 2-on-2 put the
-- same shape on the wire.  What is left here is this screen's own bookkeeping:
-- the menu closes on a choice that actually went.
function M:sendChoice(fields)
  if self.finished then return false end
  -- The hub is in reconnect grace: filing now would mark the turn answered
  -- locally even when the wire never takes it (or when the referee refuses
  -- because fighter.connected is false).
  if self.awaitingReconnect then return false end
  if not (self.transport and self.transport.isReady
          and self.transport:isReady()) then
    return false
  end
  if not M.submitChoice(self.transport, self.battle, fields, self:generation()) then
    return false
  end
  self.phase = "play"
  self.pendingTurn = false
  self.answeredTurn = true
  -- Whatever went, it is not a Bide going on until `pickMove` / `sendLockedFight`
  -- says so: an item or a switch ends one (pokecrystal `.reset_bide`), and
  -- another move is not one -- nor a METRONOME / MIRROR MOVE, until the
  -- referee reports what it called (`noteBideAnim`).
  self.bideFiled, self.bideLocked = nil, nil
  self.callFiled = nil
  self.passMove = nil
  return true
end

-- ------- Gold's BATON PASS successor
--
-- pokecrystal BattleCommand_BatonPass (engine/battle/move_effects/
-- baton_pass.asm, pokegold the same): the player's side, once
-- CheckAnyOtherAlivePartyMons has found somebody to pass to, opens the party
-- menu after the move (SetUpBattlePartyMenu / ForcePickSwitchMonInBattle) --
-- in a wild fight, a trainer's and a link battle alike -- and the monster
-- picked comes in.  A mediated fight cannot open a menu mid-move, so the pick
-- is asked as BATON PASS is chosen and rides the FIGHT choice (`pass`, the
-- party position the referee's `partyIndexOf` reads, as a switch's `slot`;
-- Wire.battleChoice reads it on a Gen 2 hub since wave 5), the way Red's MIMIC
-- asks its pick up front.  With nobody else able to fight, nothing is asked:
-- the cart fails before the menu ("But it failed!", FailedBatonPass) and so
-- does the referee.  Without a pick -- a BATON PASS called by METRONOME or
-- SLEEP TALK, which no menu could have asked for -- the referee chooses as
-- it chooses a fainted monster's successor (BattleSim2 Turn `_batonPass`:
-- the best super-effective bench, else the first living).  B goes back to
-- the move list: a choice not yet sent is the player's to take back.

-- Is this row Gold's BATON PASS?  By the sheet's effect number (BattleSim2
-- Effects.BATON_PASS), else the move record's effect name.
function M.isBatonPass2(move, game)
  if type(move) ~= "table" then return false end
  if not Effects2 then Effects2 = need("BattleSim2/Effects") end
  local effect = tonumber(move.effect)
  if effect ~= nil then return effect == Effects2.BATON_PASS end
  local data = game and game.data
  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[move.id] or nil
  return type(def) == "table" and def.effect == "EFFECT_BATON_PASS"
end

-- Does choosing this move ask for BATON PASS's successor here?
function M:asksPass(move)
  if self:generation() ~= 2 or not M.isBatonPass2(move, self.game) then return false end
  for _, row in ipairs(self:partyRows()) do
    if not row.fainted and not row.active then return true end
  end
  return false
end

-- A party sheet's position on the wire: the save-party position the snapshot
-- stamped on it (`slot`, 0-based -- what the referee's `partyIndexOf` matches
-- first), else its place in the upload.  A switch, an item's party pick and
-- BATON PASS's successor all name a monster this way; the sheet's own index
-- named the wrong one whenever `snapshotMons` had skipped a party member
-- ahead of it (an EGG), since the referee matched it against the stamps.
function M:wireSlotOf(sheetIndex)
  local sheet = self.mine and self.mine[sheetIndex]
  local slot = type(sheet) == "table" and tonumber(sheet.slot) or nil
  if slot and slot >= 0 then return floor(slot) end
  return (sheetIndex or 1) - 1
end

-- ------- STRUGGLE at the menu, and the DISABLE it reads
--
-- pokered AnyMoveToSelect (engine/battle/core.asm, MoveSelectionMenu's
-- `.regularmenu`) and pokecrystal / pokegold CheckPlayerHasUsableMoves
-- (MoveSelectionScreen, reached from ParsePlayerAction): before the move list
-- opens, the cart asks whether there is anything to pick, and when there is
-- not it prints NoMovesLeftText / BattleText_MonHasNoMovesLeft and hands the
-- player STRUGGLE without ever drawing the list.  With no move disabled that
-- is the four PP bytes ORed and masked (`and PP_MASK`): every slot at 0 PP.
-- With one disabled it is the other three slots' bytes ORed and tested with
-- `and a` -- unmasked on both carts (pokecrystal's own comment calls it the
-- PP Up bug) -- so a 0-PP slot that carries PP Ups keeps STRUGGLE away, and
-- the menu then refuses that slot for its PP and the disabled one for being
-- disabled: the player can only switch or run.  The Red referee reproduces
-- that (BattleSim Turn `mustStruggle`); the Gold referee does not -- with no
-- RUN from a trainer and no one to switch to it leaves nothing to press, a
-- freeze -- and counts the PP alone (BattleSim2 Turn `noUsableMoves`, FX-R2).
-- Either reads any FIGHT index as STRUGGLE then, and this follows each.
--
-- `moves` is the list FIGHT shows (a Transform or Mimic overlay included),
-- `disabled` its disabled slot (1-based) or nil, `generation` the cart's.
-- An empty list is never STRUGGLE here: no slot is a FIGHT the referee could
-- take (its `_normaliseChoice` needs a move at the index), and the list's
-- own guard (`updateMoveMenu`) sends the player back to the commands.
function M.mustStruggle(moves, disabled, generation)
  if type(moves) ~= "table" or #moves == 0 then return false end
  disabled = tonumber(disabled)
  if disabled and type(moves[disabled]) == "table" then
    local raw = generation == 1
    for i, move in ipairs(moves) do
      if i ~= disabled and type(move) == "table"
         and ((tonumber(move.pp) or 0) > 0 or (raw and (tonumber(move.ppUps) or 0) > 0)) then
        return false
      end
    end
    return true
  end
  for _, move in ipairs(moves) do
    if type(move) == "table" and (tonumber(move.pp) or 0) > 0 then return false end
  end
  return true
end

-- The menu's lines, each cart's own: NoMovesLeftText ("<MON> has no\nmoves
-- left!", pokered data/text/text_2.asm) / BattleText_MonHasNoMovesLeft
-- ("<MON>\nhas no moves left!", pokecrystal data/text/battle.asm); a pick
-- at 0 PP, MoveNoPPText ("No PP left for\nthis move!") /
-- BattleText_TheresNoPPLeftForThisMove; the disabled pick, MoveDisabledText
-- ("The move is\ndisabled!") / BattleText_TheMoveIsDisabled ("The move
-- is\nDISABLED!").  Shared with src/CoopBattle.lua.
function M.noMovesLeftLine(name, generation)
  name = tostring(name or "POKéMON")
  if generation == 2 then return name .. "\nhas no moves left!" end
  return name .. " has no\nmoves left!"
end
function M.noPpLine(generation)
  if generation == 1 then return "No PP left for\nthis move!" end
  return "There's no PP left\nfor this move!"
end
function M.moveDisabledLine(generation)
  if generation == 2 then return "The move is\nDISABLED!" end
  return "The move is\ndisabled!"
end

-- The wire carries no Disable: the referee says it, in its cart's words, and
-- that is what this client reads.  pokered DisableEffect's MoveWasDisabledText
-- "<TARGET>'s <MOVE> was disabled!" (BattleSim Effects), pokecrystal
-- BattleCommand_Disable's "<TARGET>'s <MOVE> was DISABLED!" (BattleSim2
-- Effects), and DisabledNoMoreText "<USER>'s disabled no more!" on both when
-- the count runs out.  `species` is the name the referee narrates the monster
-- under (its sheet's), `moves` the list it fights with; returns "on" and the
-- slot the line names, "off", or nil for any other line.  The move is matched
-- by the referee's label for it -- the row's `name`, else its id -- or this
-- build's name for the id.
function M.disableLine(text, species, moves, game)
  if type(text) ~= "string" or type(species) ~= "string" or species == "" then return nil end
  local flat = text:gsub("\n", " ")
  local prefix = species .. "'s "
  if flat:sub(1, #prefix) ~= prefix then return nil end
  local rest = flat:sub(#prefix + 1)
  if rest == "disabled no more!" then return "off" end
  local label = rest:match("^(.-) was disabled!$") or rest:match("^(.-) was DISABLED!$")
  if not label or label == "" then return nil end
  label = label:upper()
  local data = game and game.data
  local defs = type(data) == "table" and type(data.moves) == "table" and data.moves or nil
  local function names(name) return type(name) == "string" and name:upper() == label end
  for i, move in ipairs(type(moves) == "table" and moves or {}) do
    if type(move) == "table" then
      local def = defs and type(move.id) == "string" and defs[move.id] or nil
      if names(move.name) or names(move.id) or (type(def) == "table" and names(def.name)) then
        return "on", i
      end
    end
  end
  return nil
end

-- This screen's half: our monster's disabled slot (`disabledMove`).  A line
-- that disables a move of ours is taken only when the DISABLE was not our own
-- monster's -- both referees put the move's animation on its user's seat
-- straight ahead of the used line (`noteBideAnim`), and DISABLE is aimed at
-- the foe, so in a mirror match "<MON>'s <MOVE> was disabled!" after our own
-- DISABLE is the foe's monster.  Taking one that is not ours is the costly
-- mistake -- FIGHT would hand over STRUGGLE (or refuse a move) the referee
-- does not think is barred -- so that reading is the guarded one; the end
-- ("disabled no more!") is taken unconditionally, since dropping ours early
-- only shows the move list the referee then answers.  Also gone with the
-- monster (`send` on our seat), with Red's HAZE (HazeEffect_ zeroes both
-- wPlayerDisabledMove and wEnemyDisabledMove: "All STATUS changes are
-- eliminated!", BattleSim Effects `hazeReset`) and with a Gold TRANSFORM of
-- ours (ResetActorDisable; the `moves` branch of `onEvent`).
function M:noteDisableLine(text)
  local generation = self:generation()
  if generation == 3 then return end
  if generation == 1 and text == "All STATUS changes are eliminated!" then
    self.disabledMove = nil
    return
  end
  local mon = self:activeMon()
  local said, slot = M.disableLine(text, mon and mon.species, mon and mon.moves, self.game)
  if said == "off" then
    self.disabledMove = nil
  elseif said == "on" and (self.animSlot == nil or self.animSlot ~= self:mySlot()) then
    self.disabledMove = slot
  end
end

-- Does FIGHT hand this monster STRUGGLE (`M.mustStruggle`)?  Red and Gold:
-- Gen 3 has its own menu rules (src/SoloBattle.lua `refusalText3`).
function M:struggles()
  local generation = self:generation()
  if generation == 3 then return false end
  local mon = self:activeMon()
  return M.mustStruggle(mon and mon.moves, self.disabledMove, generation)
end

-- FIGHT as the cart answers it with nothing to pick: no move list, the line,
-- and STRUGGLE.  The slot named is the disabled one when a Disable is why --
-- the referee reads any index as STRUGGLE in that state, and should it not
-- think the move is barred after all, the move it runs is the one with PP
-- rather than a 0-PP slot it would refuse with silence -- else the first.
-- The line goes up once the choice is really on the wire: a refused send
-- leaves the commands open with nothing said.
function M:sendStruggle()
  local mon = self:activeMon()
  local moves = mon and mon.moves or {}
  local slot = tonumber(self.disabledMove)
  if not (slot and moves[slot]) then slot = 1 end
  local sent = self:sendChoice({ action = "fight", move = slot - 1 })
  if sent then
    self:say(M.noMovesLeftLine(mon and mon.species, self:generation()))
  end
  return sent
end

-- FIGHT with the move at `index` (1-based here, zero-based on the wire).  No
-- target: a 1v1 has exactly one thing to hit, and the sim picks the first
-- living foe when none is named -- naming one would be a field slot this
-- screen would have to keep in step for no gain.  `mimic` (1-based) is a Red
-- MIMIC's pick off the foe's list, which the move asks for first; `pass`
-- (a sheet index) is Gold's BATON PASS successor, likewise (`asksPass`).
function M:pickMove(index, mimic, pass)
  local mon = self:activeMon()
  local moves = mon and mon.moves
  if not (moves and moves[index]) then return false end
  -- Nothing to pick (`M.mustStruggle`): the cart never opened this list, and
  -- FIGHT is STRUGGLE whatever row the cursor is on.
  if self:struggles() then return self:sendStruggle() end
  -- The menu's two refusals, in the carts' order (pokered `.moveselected`,
  -- pokecrystal MoveSelectionScreen): a slot whose PP -- masked, so PP Ups
  -- do not count -- is 0, then the disabled slot.  Each says the cart's line
  -- and stays on the list.  Sent, the referee would refuse either with
  -- silence (`_normaliseChoice`) while this screen marked the turn answered,
  -- and both players would wait out BATTLE_CHOICE_TIMEOUT.
  local generation = self:generation()
  local pp = tonumber(moves[index].pp) or 0
  if generation == 3 then
    -- Gen 3 as it was: one empty slot is refused, every slot empty still
    -- sends (its referee's own Struggle rule).
    if pp <= 0 then
      local leftover = false
      for _, move in ipairs(moves) do
        if (tonumber(move.pp) or 0) > 0 then leftover = true; break end
      end
      if leftover then
        self:say("There's no PP left\nfor this move!")
        return false
      end
    end
  else
    if pp <= 0 then
      self:say(M.noPpLine(generation))
      return false
    end
    if tonumber(self.disabledMove) == index then
      self:say(M.moveDisabledLine(generation))
      return false
    end
  end
  -- Red's MIMIC against the computer: the foe's move list first (M.asksMimic).
  if mimic == nil and self:asksMimic(moves[index]) then
    self.mimicMove = index
    self.mimicIndex = 1
    self.phase = "mimic"
    return false
  end
  -- Gold's BATON PASS: the successor, in the party picker (`updateSwitch`).
  if pass == nil and self:asksPass(moves[index]) then
    self.passMove = index
    self.switchIndex = 1
    self.phase = "switch"
    return false
  end
  local sent = self:sendChoice({ action = "fight", move = index - 1,
                                 mimic = mimic and (mimic - 1) or nil,
                                 pass = pass and self:wireSlotOf(pass) or nil })
  -- Remembered only once the choice is really on the wire: a refused send
  -- leaves the turn unspent, and moving the cursor for it would be the menu
  -- reporting a decision that was not taken.
  if sent then
    self.moveMemory = self.moveMemory or {}
    self.moveMemory[self.active or 1] = index
    -- A BIDE chosen: the turns after it may be a Bide going on (`bideLocked`).
    -- A METRONOME or a MIRROR MOVE may call one: filed as a call, and a Bide
    -- only once the referee reports BIDE on our seat (`noteBideAnim`).
    if M.isBideMove(moves[index], self.game) then
      self.bideFiled, self.bideSlot = true, index
    elseif self:generation() ~= 3 and M.isCallMove(moves[index], self.game) then
      self.callFiled = index
    end
  end
  return sent
end

-- Where the move list opens: the move this monster last actually used, or its
-- first move if it has not attacked yet.
--
-- Clamped against the list it has *now* rather than the one it had then --
-- Transform and Mimic rewrite a sheet mid-fight, and a cursor left past the
-- end would open on a row that is not drawn.
function M:rememberedMove()
  local mon = self:activeMon()
  local moves = (mon and mon.moves) or {}
  local want = math.floor(tonumber((self.moveMemory or {})[self.active or 1]) or 1)
  if want < 1 or want > #moves then return 1 end
  return want
end

-- Classic Gen 1 order (row-major): FIGHT SWITCH / ITEM RUN.
M.COMMANDS = { "FIGHT", "SWITCH", "ITEM", "RUN" }
M.COMMANDS3 = COMMANDS3

-- This boot's grid (the Gen 3 one is the cart's order; see COMMANDS3).
function M:commandList()
  if self:generation() == 3 then return COMMANDS3 end
  return M.COMMANDS
end

-- One step around a `cols`-wide grid of `count` items, clamped at every edge
-- (Gen 1 never wraps the command menu).
--
-- `cols` defaults to 2, which is the classic 160x144 chrome and Gen2: at two
-- columns and four commands this is byte-identical to the 2x2 stepping it
-- replaces. The battlefield band lays the same four commands out four across
-- when it has the width for it, and a cursor that still stepped 2x2 under a
-- 1x4 paint was the bug: RIGHT from the second slab did nothing (there is no
-- column 2 to move into) and UP / DOWN jumped two slabs sideways.
local function gridStep(index, count, direction, cols)
  cols = math.floor(tonumber(cols) or 2)
  if cols < 1 then cols = 2 end
  local lastRow = math.max(0, math.ceil(count / cols) - 1)
  local row = math.floor((index - 1) / cols)
  local col = (index - 1) % cols
  if direction == "left" then col = math.max(0, col - 1)
  elseif direction == "right" then col = math.min(cols - 1, col + 1)
  elseif direction == "up" then row = math.max(0, row - 1)
  elseif direction == "down" then row = math.min(lastRow, row + 1)
  else return index end
  local moved = row * cols + col + 1
  -- A ragged last row has holes in it; a press into one stays put rather than
  -- selecting a command that is not on screen.
  if moved > count then return index end
  return moved
end

local GRID_KEYS = { "left", "right", "up", "down" }

local function gridPress(index, count, input, cols)
  for _, key in ipairs(GRID_KEYS) do
    if input:wasPressed(key) then return gridStep(index, count, key, cols) end
  end
  return nil
end

function M:usableItems()
  if self.itemList then return self.itemList end
  if self:generation() == 3 then return self:usableItems3() end
  local out = {}
  local inventory = (self.game and self.game.save and self.game.save.inventory) or {}
  local items = (self.game and self.game.data and self.game.data.items) or {}
  -- Menu follows the uploaded bag sheet so players cannot pick stacks the hub
  -- never received (truncation / unknown ids).
  local bag = self.bagSheet
  if type(bag) ~= "table" then bag = {} end
  for id, bagCount in pairs(bag) do
    local effect = M.itemIsBattleUsable(id, self.game)
    if effect and (bagCount or 0) > 0 then
      local inv = inventory[id] or 0
      local count
      if effect.noConsume then
        count = (inv >= 1 or bagCount >= 1) and 1 or 0
      else
        count = math.min(bagCount, inv)
      end
      if count > 0 then
        local def = items[id]
        out[#out + 1] = {
          id = id,
          name = (def and def.name) or id,
          count = count,
          effect = effect,
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  self.itemList = out
  return out
end

-- Gen 3: the uploaded bag sheet (numeric ids) against what the session's
-- pockets still hold, named the cart's way, in bag-id order.
function M:usableItems3()
  local out = {}
  for id, bagCount in pairs(type(self.bagSheet) == "table" and self.bagSheet or {}) do
    local num = tonumber(id)
    local effect = num and Sheet3.itemEffect(num)
    if effect and (bagCount or 0) > 0 then
      local have = Gen3.bag.count(num)
      local count = effect.noConsume and ((have >= 1 or bagCount >= 1) and 1 or 0)
        or math.min(bagCount, have)
      if count > 0 then
        out[#out + 1] = {
          id = num,
          name = Gen3.itemName(num) or ("ITEM " .. num),
          count = count,
          effect = effect,
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  self.itemList = out
  return out
end

-- Hub resolved our pending item choice (`item` event on our seat).
-- No `owed`: the hub already decremented; abandon must not refund a spent stack.
-- `amount == 1` on a vitamin means the hub applied Stat Exp (writeback owed);
-- a failed vitamin still debits the bag but must not touch save.statExp.
function M:confirmPendingItem(itemId, amount)
  local id = self.pendingItem
  if not id then return false end
  if self:generation() == 3 then return self:confirmPendingItem3(itemId) end
  if itemId and itemId ~= id then return false end
  local sheetIndex = self.pendingItemSlot or self.active
  self.pendingItem = nil
  self.pendingItemSlot = nil
  local effect = effectsFor(self.game).itemEffect(id)
  -- Red's PP item on a TRANSFORMed monster out: ItemUsePPRestore restores
  -- the PARTY's moves -- its own, under the copies -- and `.afterRestoringPP`
  -- copies their PP over the battle struct (BattleSim Turn `ownMoves` /
  -- `syncCopies`, FX-R1).  The `moves` event behind it states the copies, so
  -- the sheet's own rows (what the item's move picker lists and
  -- `itemWontHaveEffect` reads) take the same restore here, by the referee's
  -- own rule (Effects `restorePp`).  Without an overlay the event writes them.
  local moveIndex = self.pendingItemMove
  self.pendingItemMove = nil
  if self:generation() == 1 and type(effect) == "table"
     and (effect.ppRestore or effect.ppRestoreAll) and sheetIndex == (self.active or 1)
     and self.liveMoves and not self.liveMovesMimic then
    local sheet = self.mine and self.mine[sheetIndex]
    local rows = type(sheet) == "table" and type(sheet.moves) == "table" and sheet.moves or {}
    if effect.ppRestore then
      if type(rows[moveIndex or 0]) == "table" then Effects1.restorePp(rows[moveIndex], effect.ppRestore) end
    else
      for _, row in ipairs(rows) do
        if type(row) == "table" then Effects1.restorePp(row, effect.ppRestoreAll) end
      end
    end
  end
  -- Gold's X ACCURACY / GUARD SPEC. / DIRE HIT set their bit on the monster
  -- out (`itemFlags2`): the referee took the use, so the bit is set now.
  if self:generation() == 2 and type(effect) == "table" and sheetIndex == (self.active or 1) then
    self.itemFlags2 = self.itemFlags2 or {}
    for key in pairs(FLAG_OF_ITEM) do
      if effect[key] then self.itemFlags2[key] = true end
    end
  end
  -- Never in a fight between players (LINK_MODES, wave 5): the Stat Exp a
  -- vitamin gave there is the fight's alone, as everything else a link
  -- battle does to the party is (`syncMineStatus` has the carts' reasons).
  -- The bag is still spent below -- the bag working in a fight between
  -- players is this mod's rule (the carts lock it), and it is the bag's.
  if effect and effect.vitamin and amount == 1 and not LINK_MODES[self.mode] then
    -- `pendingItemSlot` is the sheet index `commitItem` was handed -- an
    -- index into `mine`, which is *not* the save.party position:
    -- `snapshotMons` skips a monster it cannot describe and one skip shifts
    -- every later index.  (The wire named the same monster by the party
    -- position the snapshot stamped on that sheet, `wireSlotOf`.)  The
    -- writeback resolves the sheet through that stamp too -- see
    -- `savePartyIndex`, which the exp writeback reads as well.
    M.writebackVitamin(self.game, self:savePartyIndex(sheetIndex), id)
  end
  if effect and effect.noConsume then
    self.itemList = nil
    return true
  end
  local inventory = self.game and self.game.save and self.game.save.inventory
  if not (inventory and (inventory[id] or 0) > 0) then return false end
  inventory[id] = inventory[id] - 1
  if inventory[id] <= 0 then inventory[id] = nil end
  if self.bagSheet and self.bagSheet[id] then
    self.bagSheet[id] = self.bagSheet[id] - 1
    if self.bagSheet[id] <= 0 then self.bagSheet[id] = nil end
  end
  self.itemList = nil
  return true
end

-- Gen 3's debit: the event names the item as its number in a string, and the
-- spend comes out of the session's own pocket (Bag.remove).
function M:confirmPendingItem3(itemId)
  local id = self.pendingItem
  if itemId ~= nil and tostring(itemId) ~= tostring(id) then return false end
  self.pendingItem = nil
  self.pendingItemSlot = nil
  local num = tonumber(id)
  local effect = num and Sheet3.itemEffect(num)
  if effect and effect.noConsume then
    self.itemList = nil
    return true
  end
  if not (num and Gen3.bag.remove(num, 1)) then return false end
  if self.bagSheet and self.bagSheet[num] then
    self.bagSheet[num] = self.bagSheet[num] - 1
    if self.bagSheet[num] <= 0 then self.bagSheet[num] = nil end
  end
  self.itemList = nil
  return true
end

function M:partyRows()
  local out = {}
  for i, mon in ipairs(self.mine or {}) do
    out[#out + 1] = {
      index = i,
      label = tostring(mon.species or ("#" .. i)),
      fainted = (mon.hp or 0) <= 0,
      active = i == self.active,
    }
  end
  return out
end

-- Same ordered list `updateSwitch` / `updateItemParty` index into, with the
-- preview fields the full-page classic picker paints. `all` is the item
-- menu (Revive wants the fainted one); SWITCH filters living non-active.
function M:classicPickerRows(all)
  local out = {}
  local data = self.game and self.game.data
  local pokemon = (data and data.pokemon) or {}
  local TypeChart = (loadEngine() or {}).TypeChart
  for _, row in ipairs(self:partyRows()) do
    if all or (not row.fainted and (self.replaceOnly or not row.active)) then
      local sheet = (self.mine or {})[row.index]
      local save = self:saveMon(row.index)
      local speciesKey = (save and save.species)
        or (sheet and sheet.speciesId)
        or (sheet and sheet.species)
      local def = (speciesKey and pokemon[speciesKey])
        or (sheet and pokemon[sheet.species])
      local hp = sheet and tonumber(sheet.hp)
      local maxHp = sheet and tonumber(sheet.maxHp)
      if save then
        if hp == nil then hp = tonumber(save.hp) end
        if maxHp == nil then
          maxHp = save.stats and tonumber(save.stats.hp)
        end
      end
      local frac = expFraction(self.game, save)
      -- The active seat's shownExpFrac is the bar the HUD already
      -- animates; save exp is exact-level (0 fill) on a freshly built
      -- Pokemon.new and would paint an empty track.
      if row.active then
        local slot = self.slots and self.slots[self:mySlot()]
        if slot and type(slot.shownExpFrac) == "number" then
          frac = slot.shownExpFrac
        end
        -- Same clock the plate drains: picker HP used to print sheet.hp
        -- and jump while the HUD bar crawled. Only overlay when the seat
        -- actually has HP -- shownHpOf returns 0 for a table with neither
        -- shownHp nor hp (an exp-only stub), which must not wipe the sheet.
        if type(slot) == "table"
           and (tonumber(slot.shownHp) ~= nil or tonumber(slot.hp) ~= nil) then
          hp = self:shownHpOf(slot)
          maxHp = tonumber(slot.maxHp) or maxHp
        end
      end
      out[#out + 1] = {
        label = row.label,
        level = (sheet and sheet.level) or (save and save.level),
        status = (sheet and sheet.status) or (save and save.status),
        hp = hp,
        maxHp = maxHp,
        types = ClassicBattle.typeNames(def, TypeChart),
        expFrac = frac,
        fainted = row.fainted,
        front = self:partyFront(row.index, save or sheet),
        icon = (type(speciesKey) == "string" and speciesKey ~= "")
          and self:seatIcon(speciesKey, save or sheet) or nil,
        species = speciesKey,
        hpForIcon = hp,
        maxHpForIcon = maxHp,
      }
    end
  end
  return out
end

function M:drawClassicPartyPicker(Font, HudTiles)
  local all = self.phase == "item_party"
  local rows = self:classicPickerRows(all)
  if #rows == 0 then return false end
  local eng = loadEngine() or {}
  local counter = 0
  if love and love.timer and love.timer.getTime then
    local ok, t = pcall(love.timer.getTime)
    if ok and type(t) == "number" then counter = math.floor(t * 60) end
  end
  return ClassicBattle.drawPartyPicker(Font, HudTiles, {
    rows = rows,
    cursor = self.switchIndex or 1,
    game = self.game,
    modules = { PokemonIcon = eng.PokemonIcon, PartyMenu = eng.PartyMenu },
    counter = counter,
  })
end


-- ------- an item the cart does not use
--
-- Both carts answer a use that would do nothing with "It won't have any /
-- effect." and keep the item and the turn: pokered ItemUseNoEffect ->
-- ItemUseFailed (wActionResultOrTookBattleTurn 0, RemoveUsedItem never
-- reached, UseBagItem back to BagWasSelected); pokecrystal / pokegold
-- WontHaveAnyEffectMessage / WontHaveAnyEffect_NotUsedMessage
-- (wItemEffectSucceeded 0 / 2, BattlePack's `.BattleField` / `.BattleOnly`
-- keeping the pack open).  Both referees refuse such a choice at the door
-- (BattleSim Turn `_itemFails`, FX-R1; BattleSim2 Turn `_itemWontHaveEffect`,
-- FX-R2) -- a hub answers a refused choice with silence, which would leave
-- the seat on a turn it never spent -- so this client asks the same question
-- first, of its own sheets, and answers it the cart's way: the line, the bag
-- back up, nothing sent and nothing spent (`commitItem`).
M.NO_EFFECT_LINE = "It won't have any\neffect."

-- The referees' status names for the wire's tokens (the engine's are the same
-- tokens), so an item's cure set (Effects `clearStatuses`) can be read.
local STATUS_NAME = {
  PSN = "poison", TOX = "toxic", BRN = "burn", FRZ = "freeze",
  PAR = "paralysis", SLP = "sleep",
}
local function statusNameOf(token)
  if type(token) ~= "string" or token == "" then return nil end
  return STATUS_NAME[token:upper()] or token:lower()
end

-- pokecrystal GetItemHealingAction's cure-everything rows, which
-- IsItemUsedOnConfusedMon lets cure confusion in battle (BattleSim2 Turn
-- CURES_CONFUSION -- read there, so the two never drift).
local function curesConfusion2(itemId)
  local ok, Turn2 = pcall(need, "BattleSim2/Turn")
  local set = ok and type(Turn2) == "table" and Turn2.CURES_CONFUSION or nil
  return type(set) == "table" and set[itemId] == true
end

-- Whether the cart's bag would turn this use down: a pure question over one
-- party monster as this client holds it (`mon`: hp, maxHp or stats.hp, a
-- status token, its own `moves` rows -- pp, ppUps, maxPp), for `generation`
-- 1 or 2, mirroring the referee of that generation exactly.  `ctx`:
--   onField     the monster is the one out (X items, GUARD SPEC., confusion)
--   move        the 1-based slot an ETHER restores
--   confused    the monster out is confused (Gold's cure-everything items)
--   xAccuracy, focusEnergy, mist   Gold's wPlayerSubStatus4 bits on it
-- Red (`_itemFails`): a medicine with no HP to restore and no status it
-- cures (a FULL RESTORE at full HP still cures one); a PP item whose
-- `.restorePP` would restore nothing on the monster's own moves (Effects
-- `restorePp` on a scratch row, the referee's own rule); its X ACCURACY /
-- GUARD SPEC. / DIRE HIT always set their bit.  Gold
-- (`_itemWontHaveEffect`): X ACCURACY / GUARD SPEC. / DIRE HIT on a bit
-- already set; an HP item at full HP (a FULL RESTORE then needs a status or
-- confusion to cure); a cure with nothing of its kind to cure (a cure-
-- everything item still takes confusion); an ETHER on a full move, an
-- ELIXER with every move full.  An X item is never one on either cart (it
-- prints its use line before the stat fails), nor a ball, a vitamin, the
-- flute, a revive; a fainted monster's cases are the party picker's own
-- (`itemFailsOnFainted`, `faintedOnly`).
function M.itemWontHaveEffect(generation, game, itemId, effect, mon, ctx)
  if generation ~= 1 and generation ~= 2 then return false end
  if type(effect) ~= "table" or type(mon) ~= "table" then return false end
  ctx = ctx or {}
  local onField = ctx.onField == true
  if generation == 2 then
    if effect.xAccuracy then return onField and ctx.xAccuracy == true end
    if effect.focusEnergy then return onField and ctx.focusEnergy == true end
    if effect.mist then return onField and ctx.mist == true end
  end
  if effect.ball or effect.vitamin or effect.pokeFlute or effect.pokeDoll
     or effect.revive or effect.stage or effect.xAccuracy or effect.focusEnergy
     or effect.mist then
    return false
  end
  local hp = tonumber(mon.hp) or 0
  if hp <= 0 then return false end
  local maxHp = tonumber(mon.maxHp)
    or (type(mon.stats) == "table" and tonumber(mon.stats.hp)) or hp
  local moves = type(mon.moves) == "table" and mon.moves or {}
  local data = game and game.data
  local defs = type(data) == "table" and type(data.moves) == "table" and data.moves or {}
  -- A row's maximum as the referee holds it: the stated one, else GetMaxPP
  -- over the record's base and the row's PP Ups (an engine slot states none).
  local function maxPpOf(row)
    local stated = tonumber(row.maxPp)
    if stated then return stated end
    local def = type(row.id) == "string" and defs[row.id] or nil
    return (type(def) == "table" and M.maxPpOf(def.pp, row.ppUps)) or tonumber(row.pp) or 0
  end
  local function restores(row, amount)
    if type(row) ~= "table" then return false end
    if generation == 1 then
      return Effects1.restorePp({ pp = row.pp, ppUps = row.ppUps, maxPp = maxPpOf(row) }, amount)
    end
    local pp = tonumber(row.pp) or 0
    return pp < max(maxPpOf(row), pp, 1)
  end
  if effect.ppRestore then
    local row = moves[tonumber(ctx.move) or 0]
    if generation == 2 and row == nil then return false end
    return not restores(row, effect.ppRestore)
  end
  if effect.ppRestoreAll then
    for _, row in ipairs(moves) do
      if restores(row, effect.ppRestoreAll) then return false end
    end
    return true
  end
  local status = statusNameOf(mon.status)
  local cures = status ~= nil and (effect.clearAllStatus
    or (type(effect.clearStatuses) == "table" and effect.clearStatuses[status] == true))
  if generation == 1 then
    local heals = (effect.healFull or (tonumber(effect.heal) or 0) > 0) and hp < maxHp
    return not (heals or cures)
  end
  local confused = onField and ctx.confused == true
  if effect.heal or effect.healFull then
    if hp < maxHp then return false end
    if effect.clearAllStatus then return status == nil and not confused end
    return true
  end
  if effect.clearStatuses or effect.clearAllStatus then
    if cures then return false end
    return not (curesConfusion2(itemId) and confused)
  end
  return false
end

-- This screen's question for one pick (`M.itemWontHaveEffect` over the sheet
-- of party member `partyIndex`, the one out by default).
function M:itemNoEffect(pick, effect, partyIndex, moveIndex)
  local generation = self:generation()
  if generation ~= 1 and generation ~= 2 then return false end
  local index = partyIndex or self.active or 1
  local mon = self.mine and self.mine[index]
  local seat = self.slots and self.slots[self:mySlot()]
  seat = type(seat) == "table" and (seat.pending or seat) or nil
  local flags = self.itemFlags2 or {}
  return M.itemWontHaveEffect(generation, self.game, pick and pick.id, effect, mon, {
    onField = index == (self.active or 1), move = moveIndex,
    confused = seat ~= nil and seat.confused == true,
    xAccuracy = flags.xAccuracy, focusEnergy = flags.focusEnergy, mist = flags.mist,
  })
end

-- Gold's wPlayerSubStatus4 bits on our monster out (`itemFlags2`), which X
-- ACCURACY, GUARD SPEC. and DIRE HIT refuse to set twice: set by our own use
-- of one (its `item` event, `confirmPendingItem`) and by our FOCUS ENERGY /
-- MIST ("<MON>'s getting pumped!" / "<MON>'s shrouded in MIST!", BattleSim2
-- Effects, after a used line of ours -- `usedLineOurs`'s anim seat), gone with
-- the monster (`send` on our seat) unless BATON PASS carried them over
-- (pokecrystal BattleCommand_BatonPass keeps SubStatus4; BattleSim2 Turn
-- `_batonPass` passes all three).  HAZE leaves them (BattleCommand_ResetStats
-- resets the stat levels alone).
function M:noteItemFlags2(text)
  if self:generation() ~= 2 or type(text) ~= "string" then return end
  local sheet = self.mine and self.mine[self.active or 1]
  local species = sheet and sheet.species
  if type(species) ~= "string" or species == "" then return end
  local ours = self.animSlot == nil or self.animSlot == self:mySlot()
  if not ours then return end
  self.itemFlags2 = self.itemFlags2 or {}
  if text == species .. "'s getting pumped!" then
    self.itemFlags2.focusEnergy = true
  elseif text == species .. "'s shrouded in MIST!" then
    self.itemFlags2.mist = true
  else
    local label = text:match("^" .. species:gsub("%W", "%%%0") .. " used (.-)!$")
    if label then
      label = label:upper()
      local mon = self:activeMon()
      for _, move in ipairs((mon and mon.moves) or {}) do
        local name = self:moveLabel(move.id)
        if M.isBatonPass2(move, self.game)
           and (label == tostring(name):upper() or label == tostring(move.id):upper()) then
          -- What this monster's send-out on our seat carries over.
          local carried = {}
          for key in pairs(FLAG_OF_ITEM) do carried[key] = self.itemFlags2[key] end
          self.itemFlags2Passed = carried
          break
        end
      end
    end
  end
end

function M:commitItem(partyIndex, moveIndex)
  local pick = self.itemPick
  if not pick then return false end
  local effect = pick.effect or effectsFor(self.game).itemEffect(pick.id)
  if not effect then
    self:say("But it failed")
    self.phase = "choose"
    self.itemPick = nil
    return false
  end
  -- An item the cart would not use (`M.itemWontHaveEffect`): its line, the
  -- bag back up, nothing sent and nothing spent.
  if self:itemNoEffect(pick, effect, partyIndex, moveIndex) then
    self:say(M.NO_EFFECT_LINE)
    self.phase = "item"
    self.itemPick = nil
    return false
  end
  local bagCount = self.bagSheet and self.bagSheet[pick.id] or 0
  if bagCount < 1 then
    self:say("You have nothing\nto use!")
    self.phase = "choose"
    self.itemPick = nil
    return false
  end
  local gen3 = self:generation() == 3
  if not effect.noConsume then
    local have
    if gen3 then
      have = Gen3.bag.count(pick.id)
    else
      local inventory = self.game and self.game.save and self.game.save.inventory
      have = inventory and (inventory[pick.id] or 0) or 0
    end
    if not (have > 0) then
      self:say("You have nothing\nto use!")
      self.phase = "choose"
      self.itemPick = nil
      return false
    end
  end
  -- Do not debit yet: wait for the hub `item` event (or clear on turn/unchose).
  self.pendingItem = pick.id
  self.pendingItemSlot = partyIndex or self.active
  self.pendingItemMove = moveIndex
  -- Gen 3 names the item by its number, spelled as a string so the id
  -- sanitiser takes it (the referee reads either).  A ball also says whether
  -- this player's dex already has the wild species caught -- the Repeat
  -- Ball's x3 (docs/plans/gen3-battle-sheet.md §1.2).
  local fields = { action = "item", item = gen3 and tostring(pick.id) or pick.id }
  if gen3 and effect.ball then fields.dexCaught = self:wildDexCaught() end
  -- The party position the referee matches (`wireSlotOf`), as a switch names it.
  if partyIndex then fields.slot = self:wireSlotOf(partyIndex) end
  if moveIndex then fields.move = moveIndex - 1 end
  self.itemPick = nil
  if not self:sendChoice(fields) then
    self.pendingItem = nil
    self.pendingItemSlot = nil
    return false
  end
  return true
end

-- How many columns the command menu is *drawn* in, which is what the cursor
-- has to step in. The band widget owns that rule (`Battlefield.bandGridCols`,
-- which `drawCommandGrid` reads too), so it is asked rather than restated --
-- the two drifting apart is a highlight that walks onto a slab the player is
-- not looking at. Classic 160x144 chrome and Gen2 are always 2x2, and so is
-- an arena too old to answer: nothing to remediate, the fallback is the layout
-- those paths draw anyway.
function M:commandCols()
  if not self:usesBattlefield() then return 2 end
  local cols = Battlefield and Battlefield.bandGridCols
  if type(cols) ~= "function" then return 2 end
  local ok, got = pcall(cols, #self:commandList())
  got = ok and tonumber(got) or nil
  if not got or got < 1 then return 2 end
  return math.floor(got)
end

-- Does this player's dex already have the wild seat's species caught?
function M:wildDexCaught()
  local sheet = type(self.wildParty) == "table" and self.wildParty[1] or nil
  local sp = sheet and tonumber(sheet.speciesNum or sheet.speciesId)
  local session = Gen3.session()
  local Dex = Gen3.engine("src.core.game3.dex")
  if not (sp and session and type(session.dex) == "table" and Dex
      and type(Dex.isCaught) == "function") then
    return false
  end
  local ok, caught = pcall(Dex.isCaught, session.dex, sp)
  return ok and caught == true
end

function M:updateCommand(input)
  self.commandIndex = self.commandIndex or 1
  local commands = self:commandList()
  local moved = gridPress(self.commandIndex, #commands, input, self:commandCols())
  if moved then
    self.commandIndex = moved
  elseif input:wasPressed("a") then
    local command = commands[self.commandIndex]
    local locked = command == "FIGHT" and self:lockedFightSlot() or nil
    if locked then
      -- A Bide going on (Gold's `.locked_in`), or Red's monster asleep or
      -- frozen: the cart opens no move list behind this FIGHT.
      self:sendLockedFight(locked)
    elseif command == "FIGHT" and self:struggles() then
      -- Nothing to pick (AnyMoveToSelect / CheckPlayerHasUsableMoves): no
      -- move list either -- the line, and STRUGGLE (`sendStruggle`).
      self:sendStruggle()
    elseif command == "FIGHT" then
      self.cursor = self:rememberedMove()
      self.phase = "move"
    elseif command == "SWITCH" then
      self.switchIndex = 1
      self.passMove = nil
      self.phase = "switch"
    elseif command == "ITEM" then
      self.itemIndex = 1
      self.itemList = nil
      self.phase = "item"
    elseif command == "RUN" then
      -- PvP RUN is a concession. The trainer refuse line belongs only to
      -- NPC modes -- printing it on 1v1 then sending run made the match
      -- look like a wasted turn. Honest trainer menus never file `run`
      -- (#86): the sim no-ops a filed one as modified-client proof.
      -- 1v1 says you forfeited only after the send lands.
      if self.mode == "wild" then
        self:sendChoice({ action = "run" })
      elseif TRAINER_MODES[self.mode] then
        self:say("No! There's no\nrunning from a\ntrainer battle!")
      elseif self:sendChoice({ action = "run" }) then
        self:say("You forfeited\nthe battle!")
      end
    end
  end
end

function M:updateMoveMenu(input)
  local mon = self:activeMon()
  local moves = (mon and mon.moves) or {}
  if #moves == 0 then
    self.phase = "choose"
    return
  end
  if input:wasPressed("up") then
    self.cursor = self.cursor > 1 and self.cursor - 1 or #moves
  elseif input:wasPressed("down") then
    self.cursor = self.cursor < #moves and self.cursor + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    self:pickMove(self.cursor)
  end
end

-- ------- a Bide that asks (Gold)
--
-- pokecrystal CheckPlayerLockedIn (engine/battle/core.asm, pokegold the same)
-- quits on a recharge, a charge, a rampage and ROLLOUT -- not on
-- SUBSTATUS_BIDE -- so a biding player is shown the battle menu every turn of
-- the Bide: PKMN and PACK end it, and FIGHT goes straight on with it
-- (ParsePlayerAction's `and 1 << SUBSTATUS_BIDE / jr nz, .locked_in`, ahead
-- of the move menu).  The Gold referee asks such a seat and reads any FIGHT
-- as the Bide going on (BattleSim2 Turn `_asksBide` / `_normaliseChoice`), so
-- this screen opens the command menu as for any turn -- and FIGHT sends the
-- Bide on at once instead of opening a move list the cart never shows.
--
-- The wire states no Bide, so it is read off what this client did and saw:
-- it chose BIDE (or went on with one), and the turn just resolved said its
-- monster is in one.  The first turn says it with the used line alone --
-- "<MON> used BIDE!": BattleCommand_StoreEnergy returns at once while
-- SUBSTATUS_BIDE is clear, and `usedmovetext` prints it before
-- BattleCommand_UnleashEnergy sets the substatus (move_effects/bide.asm;
-- the referee's "began storing energy" is gone since wave 5) -- and every
-- storing turn after it with StoringEnergyText, "<MON> is storing energy!"
-- (the referee's `bideStore`).  A turn that said neither -- the release
-- ("unleashed energy!"), or a CantMove that ended the Bide (sleep,
-- paralysis, a flinch, confusion) -- reopens the move list.
--
-- The two readings do not cost the same.  One that ends a Bide too early
-- reopens the move list -- a screen the cart would not have shown, whose
-- pick the referee overrides while the Bide holds.  One that starts a Bide
-- that is not ours sends FIGHT with no move list: a move the player never
-- picked.  And both referees name every monster by its bare species, so in
-- a mirror match -- a foe or a co-op partner of our species -- "<MON> used
-- BIDE!" can be the other one's.  So a start is taken only (a) when this
-- client filed BIDE (`bideFiled`), or a METRONOME / MIRROR MOVE whose call
-- the referee reported as BIDE on our seat (`noteBideAnim`), and (b) when
-- the used line is not straight behind a move animation on another seat
-- (`usedLineOurs`: both referees put the `anim` on the user's seat just
-- ahead of its used line).  The release and the CantMove ends stay
-- unconditional: wrong, they only cost the screen.  Red's reading
-- (`bideLine1`) takes its start the same way.

-- A sheet row by its effect number -- both referees number BIDE's 26
-- (BattleSim Effects BIDE_EFFECT, BattleSim2 EFFECT_BIDE) -- and an engine
-- party slot, which states none, by its move record's effect name.
function M.isBideMove(move, game)
  if type(move) ~= "table" then return false end
  local effect = tonumber(move.effect)
  if effect ~= nil then return effect == Effects1.idOf("BIDE_EFFECT") end
  local data = game and game.data
  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[move.id] or nil
  return type(def) == "table"
    and (def.effect == "EFFECT_BIDE" or def.effect == "BIDE_EFFECT")
end

-- A move an `anim` names (its `text`, the move's id) is a Bide: the row of
-- that id on `moves` (the list the seat fights with), else the move record,
-- else the id BIDE itself -- a METRONOME's call is off the pool, which no
-- sheet of ours holds.
function M.isBideId(id, moves, game)
  if type(id) ~= "string" or id == "" then return false end
  for _, move in ipairs(type(moves) == "table" and moves or {}) do
    if type(move) == "table" and move.id == id then return M.isBideMove(move, game) end
  end
  if id:upper() == "BIDE" then return true end
  return M.isBideMove({ id = id }, game)
end

-- A move that calls another: METRONOME and MIRROR MOVE, numbered alike by
-- both referees (BattleSim Effects METRONOME_EFFECT / MIRROR_MOVE_EFFECT,
-- BattleSim2 EFFECT_METRONOME / EFFECT_MIRROR_MOVE: 83 and 9), by the move
-- record's effect name for an engine slot.  pokered MirrorMoveCheck /
-- `.metronomeCheck` and pokecrystal BattleCommand_Metronome / MirrorMove run
-- the called move as their own, its used line and all, so a call may be a
-- BIDE.
local CALL_EFFECT_NAMES = {
  METRONOME_EFFECT = true, EFFECT_METRONOME = true,
  MIRROR_MOVE_EFFECT = true, EFFECT_MIRROR_MOVE = true,
}
function M.isCallMove(move, game)
  if type(move) ~= "table" then return false end
  local effect = tonumber(move.effect)
  if effect ~= nil then
    return effect == Effects1.idOf("METRONOME_EFFECT")
      or effect == Effects1.idOf("MIRROR_MOVE_EFFECT")
  end
  local data = game and game.data
  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[move.id] or nil
  return type(def) == "table" and CALL_EFFECT_NAMES[def.effect] == true
end

-- Gold's Bide, read off the referee's lines in pokecrystal's words (wave 5;
-- BattleSim2 Turn `_useMove`): "start" for "<MON> used BIDE!" (`labels`, as
-- `bideLine1` reads it: the upper-case names a Bide row goes by on this
-- sheet, BIDE itself always), "store" for StoringEnergyText's "<MON> is
-- storing energy!", "release" for UnleashedEnergyText's "<MON> unleashed
-- energy!", nil for anything else and for a line about another monster.  The
-- closing "!" is optional, so an older referee's bare line still reads.
function M.bideLine(text, species, labels)
  if type(text) ~= "string" or type(species) ~= "string" or species == "" then
    return nil
  end
  local line = text:gsub("!+$", "")
  if line == species .. " is storing energy" then return "store" end
  if line == species .. " unleashed energy" then return "release" end
  local prefix = species .. " used "
  if line:sub(1, #prefix) == prefix then
    local label = line:sub(#prefix + 1):upper()
    if label == "BIDE" or (type(labels) == "table" and labels[label]) then
      return "start"
    end
  end
  return nil
end

-- Red's Bide, read off the lines that bound it (wave 5).  pokered BideEffect
-- (engine/battle/effects.asm) prints nothing past "<MON> used BIDE!" and a
-- store turn prints nothing at all (CheckPlayerStatusConditions `.BideCheck`
-- jumps straight to ExecutePlayerMoveDone; SavingEnergyText is never
-- referenced), so there is no per-turn "storing" line to read, as Gold's
-- reading has.  But the Bide is bounded by lines that do exist: it starts on
-- the used line, lasts 2..3 more turns, and ends on UnleashedEnergyText --
-- or, early, on the two gates that clear STORING_ENERGY: a confusion
-- self-hit (`.ConfusedCheck`: `and 1 << CONFUSED` keeps nothing else) and
-- full paralysis (`.ParalysisCheck`'s mask).  A switch-out or a faint ends it
-- too (the send-out / faint branches clear it); an item does not -- the cart
-- leaves wPlayerBattleStatus1 alone and the next FIGHT goes on storing.
--
--   "start"    "<MON> used BIDE" (the referee's used line; `labels` holds the
--              upper-case names a Bide row goes by on this sheet, BIDE
--              itself always)
--   "release"  "<MON> unleashed energy"
--   "end"      "<MON> hurt itself in confusion", "<MON> is fully paralyzed"
--              / "<MON>'s fully paralyzed!" (the cart's spelling), or the
--              cart's "It hurt itself in its confusion!" right after
--              "<MON> is confused!" (`confusedNow`: the species the last
--              confusion line named)
--
-- nil for anything else, and for a line about another monster.
function M.bideLine1(text, species, labels, confusedNow)
  if type(text) ~= "string" or type(species) ~= "string" or species == "" then
    return nil
  end
  local line = text:gsub("!+$", "")
  if line == species .. " unleashed energy" then return "release" end
  if line == species .. " hurt itself in confusion"
     or line == species .. " is fully paralyzed"
     or line == species .. "'s fully paralyzed" then
    return "end"
  end
  if line == "It hurt itself in its confusion" and confusedNow == species then
    return "end"
  end
  local prefix = species .. " used "
  if line:sub(1, #prefix) == prefix then
    local label = line:sub(#prefix + 1):upper()
    if label == "BIDE" or (type(labels) == "table" and labels[label]) then
      return "start"
    end
  end
  return nil
end

-- The upper-case names this sheet's Bide rows go by (the used line's label:
-- the move's `name`, else its id), for `bideLine1`.
function M.bideLabels(moves, game)
  local out = {}
  for _, move in ipairs(type(moves) == "table" and moves or {}) do
    if M.isBideMove(move, game) then
      if type(move.name) == "string" then out[move.name:upper()] = true end
      if type(move.id) == "string" then out[move.id:upper()] = true end
    end
  end
  return out
end

-- This screen's half: a line about our monster's Bide.  Gold reads the
-- storing line every turn (`bideLine`); Red the lines that bound it
-- (`bideLine1`, kept in `bideOn1` from the start to the end).  A start is
-- ours only when this client filed the BIDE and the used line is not another
-- seat's (`usedLineOurs`) -- the "Bide that asks" note above has why.
-- `seq` is the line's own event number.
function M:noteBideLine(text, seq)
  local sheet = self.mine and self.mine[self.active or 1]
  local species = sheet and sheet.species
  if self:generation() == 1 then
    if type(text) == "string" and type(species) == "string" then
      local who = text:match("^(.-) is confused!?$")
      if who then self.confusedNow = who end
    end
    local said = M.bideLine1(text, species, M.bideLabels(sheet and sheet.moves, self.game),
      self.confusedNow)
    if said == "start" then
      if self.bideFiled and self:usedLineOurs(seq) then self.bideOn1 = true end
    elseif said == "release" or said == "end" then
      self.bideOn1, self.bideFiled = nil, nil
    end
    return
  end
  if not self.bideFiled then return end
  local said = M.bideLine(text, species, M.bideLabels(sheet and sheet.moves, self.game))
  if said == "store" or (said == "start" and self:usedLineOurs(seq)) then
    self.bideStoring = true
  elseif said == "release" then
    self.bideFiled, self.bideStoring = nil, nil
  end
end

-- An `anim` event, for the Bide reading: which seat the next used line is
-- about (both referees emit the move's animation on the user's seat straight
-- ahead of its used line -- BattleSim / BattleSim2 Turn `_useMove`), and a
-- METRONOME / MIRROR MOVE this client filed that called BIDE on our seat --
-- pokered MetronomePickMove / MirrorMoveCopyMove and pokecrystal
-- BattleCommand_Metronome / MirrorMove run the called move as their own, so
-- the call's animation names it there -- a Bide filed as surely as one
-- picked off the list.
function M:noteBideAnim(msg)
  self.animSeq, self.animSlot = tonumber(msg.seq), msg.slot
  if self.callFiled and msg.slot ~= nil and msg.slot == self:mySlot() then
    local sheet = self.mine and self.mine[self.active or 1]
    local moves = self.liveMoves or (sheet and sheet.moves)
    if M.isBideId(msg.text, moves, self.game) then
      self.bideFiled, self.bideSlot = true, self.callFiled
      self.callFiled = nil
    end
  end
end

-- False when the used line at `seq` follows straight on a move animation on
-- another seat (`noteBideAnim`): that seat's line, whatever species it names.
-- A stream with no animation ahead of the line (an older referee) is read as
-- before.
function M:usedLineOurs(seq)
  seq = tonumber(seq)
  if not (seq and self.animSeq and self.animSeq == seq - 1) then return true end
  return self.animSlot == nil or self.animSlot == self:mySlot()
end

-- ...and Red's own: pokered MainInBattleLoop (engine/battle/core.asm) runs
-- DisplayBattleMenu every turn and, on FIGHT, skips MoveSelectionMenu for a
-- monster asleep or frozen (`and (1 << FRZ) | SLP_MASK / jr nz,
-- .selectEnemyMove` -- wPlayerSelectedMove, last turn's selection, stands),
-- storing energy, using a trapping move, or held by the enemy's.  The Red
-- referee asks those seats and reads their FIGHT as the lock-in whatever slot
-- it names (BattleSim Turn `_menuFight`; asleep or frozen, any slot holding a
-- move, no PP or Disable test).  Of the five, this client can be sure of
-- three -- the seat's status is the referee's, event by event, and a Bide is
-- bounded by its used line and its release (`bideLine1`, wave 5) -- and skips
-- the move list for them.  A trap's last turn is the referee's to know (the
-- trapper's counter -- TrappingEffect's 1..4 continuations -- and the foe's
-- that holds us ride no event, and CheckNumAttacksLeft lets go in silence),
-- so those two keep the move list, whose pick the referee overrides while the
-- lock holds.  That costs a screen; skipping it on a guess would send the
-- trapping move -- or last turn's -- for a player whose cart had reopened the
-- move menu.

-- The move slot a FIGHT sends with no move list, or nil for the list.
function M:lockedFightSlot()
  if self.bideLocked then return self.bideSlot or 1 end
  if self:generation() == 1 then
    local sheet = self.mine and self.mine[self.active or 1]
    local status = type(sheet) == "table" and sheet.status or nil
    if status == "SLP" or status == "FRZ" then return self:rememberedMove() end
  end
  return nil
end

-- FIGHT with no move list: the slot `lockedFightSlot` named, past its PP (a
-- Bide's first turn spent BIDE's, and a locked-in FIGHT reads none).
function M:sendLockedFight(slot)
  local biding = self.bideLocked
  local sent = self:sendChoice({ action = "fight", move = (slot or 1) - 1 })
  if sent and biding then self.bideFiled = true end
  return sent
end

-- ------- Red's MIMIC pick
--
-- pokered MimicEffect (engine/battle/move_effects/mimic.asm): outside a link
-- battle the player's MIMIC opens a menu of the enemy's moves
-- (`.letPlayerChooseMove`: MoveSelectionMenu with wMoveMenuType 1, which lists
-- wEnemyMonMoves, the cursor on its first row), and the move under the cursor
-- is the one copied; a link battle -- both sides -- and the computer's turn
-- take `.getRandomMove`.  A mediated fight cannot open a menu mid-turn, so the
-- pick is asked here as MIMIC is chosen and rides the choice (`mimic`, 0-based
-- into the target's list; Wire.battleChoice reads it on a Gen 1 hub only), as
-- Gen 3 asks BATON PASS's destination up front.  The referee checks it against
-- the moves the target holds when MIMIC lands, and with no pick uses the
-- menu's first row (BattleSim Turn `_mimicPick`).  B goes back to the move
-- list: a choice not yet sent is the player's to take back.

-- Is this Red's MIMIC, in a fight where the cart asks the player?
function M:asksMimic(move)
  if self:generation() ~= 1 or not KEEPS_HELD_MODES[self.mode] then return false end
  if type(move) ~= "table" then return false end
  local data = self.game and self.game.data
  local def = type(data) == "table" and type(data.moves) == "table"
    and data.moves[move.id] or nil
  local mimicEffect = Effects1.idOf("MIMIC_EFFECT")
  local mimic = move.id == "MIMIC"
    or (mimicEffect ~= nil and tonumber(move.effect) == mimicEffect)
    or (type(def) == "table" and def.effect == "MIMIC_EFFECT")
  if not mimic then return false end
  return #self:foeMoveList() > 0
end

-- wEnemyMonMoves as this screen knows it: the list the referee last stated
-- for the monster standing across (a TRANSFORM or MIMIC of its own), else
-- the sheet it was uploaded with (this client described the wild / trainer
-- side), else nothing.
function M:foeMoveList()
  if type(self.foeMoves) == "table" and #self.foeMoves > 0 then return self.foeMoves end
  local foes = self.wildParty or self.npcParty
  local at = tonumber(self.foeMon)
  local sheet = type(foes) == "table" and foes[(at and floor(at) or 0) + 1] or nil
  return (type(sheet) == "table" and type(sheet.moves) == "table") and sheet.moves or {}
end

-- The pick list's rows, as names.
function M:mimicRows()
  local rows = {}
  for _, move in ipairs(self:foeMoveList()) do
    if #rows >= Config.BATTLE_MOVE_MAX then break end
    rows[#rows + 1] = { label = self:moveLabel(move.id) or tostring(move.id or "-") }
  end
  return rows
end

function M:updateMimic(input)
  local rows = self:mimicRows()
  if #rows == 0 then
    self.phase = "move"
    return
  end
  local at = self.mimicIndex or 1
  if at < 1 or at > #rows then at = 1 end
  if input:wasPressed("up") then
    self.mimicIndex = at > 1 and at - 1 or #rows
  elseif input:wasPressed("down") then
    self.mimicIndex = at < #rows and at + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "move"
  elseif input:wasPressed("a") then
    self:pickMove(self.mimicMove or self.cursor, at)
  end
end

-- The classic page: the foe's moves in the box MoveSelectionMenu's
-- `.mimicmenu` draws (hlcoord 0, 7: four rows, names only), over the
-- player's own move pane.
function M:drawMimicPick(Font)
  self:drawMoves(Font)
  local rows = self:mimicRows()
  Font.drawBox(0, 7, 16, 6)
  love.graphics.setColor(0, 0, 0, 1)
  for i, row in ipairs(rows) do
    if i > 4 then break end
    ClassicBattle.drawFittedText(Font, row.label, 16, 56 + i * 8, 112)
  end
  if #rows > 0 then Font.drawCode(0xED, 8, 56 + (self.mimicIndex or 1) * 8) end
end

-- A POKé DOLL outside a wild fight, as both carts answer it at the bag: the
-- cart's line, the bag back up, the item kept and the turn not spent --
-- pokered ItemUsePokeDoll (`ld a, [wIsInBattle] / dec a / jp nz,
-- ItemUseNotTime`: a trainer or a link battle) and pokecrystal
-- PokeDollEffect (`.not_wild` leaves wItemEffectSucceeded 0, and the battle
-- pack's `.BattleOnly` answers that with `.Oak`, OakThisIsntTheTimeText --
-- engine/items/pack.asm), both "OAK: <PLAYER>! This isn't the time to use
-- that!", the same refusal
-- `updateCommand` gives a trainer RUN.  The Red referee files a doll it is
-- sent there as a spent turn with the same line, so the screen does not send
-- it.  The line, or nil where the doll is usable (a wild fight) or the cart
-- is not Red / Gold (Gen 3 reads its own bag).  Shared with
-- src/CoopBattle.lua.
local DOLL_MODES = { wild = true, coop_wild = true }
function M.dollRefusal(game, mode)
  if Gen.generation(game) == 3 or DOLL_MODES[mode] then return nil end
  return "OAK: " .. playerName(game) .. "!\nThis isn't the\ntime to use that!"
end

function M:updateItemMenu(input)
  local items = self:usableItems()
  if #items == 0 then
    self:say("You have nothing\nto use!")
    self.phase = "choose"
    return
  end
  if input:wasPressed("up") then
    self.itemIndex = self.itemIndex > 1 and self.itemIndex - 1 or #items
  elseif input:wasPressed("down") then
    self.itemIndex = self.itemIndex < #items and self.itemIndex + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    local pick = items[self.itemIndex]
    local effect = pick.effect
    self.itemPick = pick
    local notTime = effect and effect.pokeDoll and M.dollRefusal(self.game, self.mode)
    if not effect then
      -- Unknown bag id: still spend it and let the sim announce failure.
      self:commitItem(self.active, nil)
    elseif notTime then
      self.itemPick = nil
      self:say(notTime)
    elseif effect.ball or effect.pokeDoll or effect.pokeFlute then
      self:commitItem(nil, nil)
    elseif effect.activeOnly then
      self:commitItem(self.active, nil)
    elseif effect.needsMove then
      self.cursor = 1
      self.phase = "item_party"
    elseif effect.needsParty or effect.faintedOnly then
      self.switchIndex = 1
      self.phase = "item_party"
    else
      self:commitItem(self.active, nil)
    end
  end
end

function M:updateItemParty(input)
  local rows = self:partyRows()
  if #rows == 0 then
    self.phase = "item"
    return
  end
  if input:wasPressed("up") then
    self.switchIndex = self.switchIndex > 1 and self.switchIndex - 1 or #rows
  elseif input:wasPressed("down") then
    self.switchIndex = self.switchIndex < #rows and self.switchIndex + 1 or 1
  elseif input:wasPressed("b") then
    self.itemPick = nil
    self.phase = "item"
  elseif input:wasPressed("a") then
    local row = rows[self.switchIndex]
    local effect = self.itemPick and self.itemPick.effect
    -- Gen 1: Potion/Ether/status/vitamin on a fainted mon (and Revive on a
    -- living one) print "It won't have any effect" and stay on the picker —
    -- the bag is not spent and the turn is not committed. `_normaliseChoice`
    -- refuses the same cases if a choice is submitted anyway.
    local Effects = effectsFor(self.game)
    if effect and (
         (effect.faintedOnly and not row.fainted)
         or (row.fainted and Effects.itemFailsOnFainted(effect))
       ) then
      self:say(M.NO_EFFECT_LINE)
      return
    end
    if effect and effect.needsMove then
      self.cursor = 1
      self.itemPartyIndex = row.index
      self.phase = "item_move"
      return
    end
    self:commitItem(row.index, nil)
  end
end

function M:updateItemMove(input)
  local mon = (self.mine or {})[self.itemPartyIndex or self.active]
  local moves = (mon and mon.moves) or {}
  if #moves == 0 then
    self.phase = "item_party"
    return
  end
  if input:wasPressed("up") then
    self.cursor = self.cursor > 1 and self.cursor - 1 or #moves
  elseif input:wasPressed("down") then
    self.cursor = self.cursor < #moves and self.cursor + 1 or 1
  elseif input:wasPressed("b") then
    self.phase = "item_party"
  elseif input:wasPressed("a") then
    self:commitItem(self.itemPartyIndex or self.active, self.cursor)
  end
end

function M:updateSwitch(input)
  local rows = self:partyRows()
  local choices = {}
  for _, row in ipairs(rows) do
    -- Forced replace: active is fainted / empty, so every living mon is legal.
    if not row.fainted and (self.replaceOnly or not row.active) then
      choices[#choices + 1] = row
    end
  end
  if #choices == 0 then
    self:say("There's no one\nto switch to!")
    if not self.replaceOnly then self.phase = self.passMove and "move" or "choose" end
    self.passMove = nil
    return
  end
  if self.switchIndex > #choices then self.switchIndex = #choices end
  if input:wasPressed("up") then
    self.switchIndex = self.switchIndex > 1 and self.switchIndex - 1 or #choices
  elseif input:wasPressed("down") then
    self.switchIndex = self.switchIndex < #choices and self.switchIndex + 1 or 1
  elseif input:wasPressed("b") then
    -- Out of BATON PASS's picker is back to the move list it came from.
    if self.passMove then
      self.passMove = nil
      self.phase = "move"
    elseif not self.replaceOnly then
      self.phase = "choose"
    end
  elseif input:wasPressed("a") then
    local row = choices[self.switchIndex]
    if row and self.passMove then
      -- BATON PASS's successor (`asksPass`): the move goes, naming it.
      self:pickMove(self.passMove, nil, row.index)
    elseif row then
      self:sendChoice({ action = "switch", slot = self:wireSlotOf(row.index) })
    end
  end
end

-- ------- theatre (battle / victory / map music)
--
-- Same contract as CoopBattle: play the fight theme on enter, the fanfare
-- once on a win, and restore the map theme on the way out win or lose -- a
-- Defeated* song ends in `sound_loop 0` and would otherwise follow the player
-- into the overworld. 1v1 is the link cue; protocol-only wild is the wild cue.

function M:musicKind()
  if self.cachedMusicKind then return self.cachedMusicKind end
  self.cachedMusicKind = (self.mode == "wild") and "wild" or "link"
  return self.cachedMusicKind
end

function M:playVictoryMusic()
  if self.result ~= "win" or self.victoryMusicPlayed then return end
  self.victoryMusicPlayed = true
  -- Gen 3 plays the cart's own jingle through the m4a player; there is no
  -- Gen 1 Music module to hand over.
  if self:generation() == 3 then
    Gen.playVictoryMusic(self.game, self:gen3MusicOpts())
    return
  end
  local eng = loadEngine()
  if not (eng and eng.Music and self.game) then return end
  -- Gen 1: kind .. "Win" (final→gym). Gen 2: BattleMusic victory label.
  Gen.playVictoryMusic(self.game, {
    Music = eng.Music,
    kind = self:musicKind(),
    mode = self.mode,
  })
end

-- ------- the screen
--
-- enter/exit/update/draw is the whole of the engine's state interface, and
-- src/Ui.lua's RbyMmoState screen hands this object straight to the stack.

-- The battle opts Gen.playBattleMusic / playVictoryMusic read on Gen 3: the
-- mode, and the NPC (a numeric Gen 3 trainer row) on a solo trainer fight.
function M:gen3MusicOpts()
  return { kind = self:musicKind(), mode = self.mode, trainer = self.trainer }
end

-- What the theme is restored with after an evolution movie.
function M:battleMusicOpts(eng)
  if self:generation() == 3 then return self:gen3MusicOpts() end
  return { Music = eng and eng.Music, kind = self:musicKind(), mode = self.mode }
end

function M:enter()
  loadEngine()
  if self:usesBattlefield() then self:ensureBattlefield() end
  local eng = engine
  if self:generation() == 3 then
    if self.game then Gen.playBattleMusic(self.game, self:gen3MusicOpts()) end
  elseif eng and eng.Music and self.game then
    Gen.playBattleMusic(self.game, {
      Music = eng.Music,
      kind = self:musicKind(),
      mode = self.mode,
    })
  end
  self:start(self.game)
end

function M:exit()
  if self.left then return end
  self.left = true
  -- Pending choice was never accepted: inventory untouched. Confirmed spends
  -- already match the hub and must not be refunded.
  self.pendingItem = nil
  self.pendingItemSlot = nil
  -- A fanfare still waiting on a drain is dropped rather than started over
  -- the map theme this is about to restore.
  self.victoryMusicHeld = nil
  -- And the arena stops animating. Nothing draws this screen after here, so
  -- this is hygiene rather than a fix -- but it is the one place every path
  -- off the screen passes through, and a held effect is a hold on an object
  -- the session may still be holding a reference to.
  self:snapDisplay()
  -- Map theme back unconditionally: victory jingles loop until something
  -- stops them (same reason the engine's BattleState:finish restores).
  local eng = loadEngine()
  if self:generation() == 3 then
    if self.game then Gen.restoreMapMusic(self.game) end
  elseif eng and eng.Music and self.game then
    Gen.restoreMapMusic(self.game, { Music = eng.Music })
  end
  -- Leftover `toLearn` rides out if the player left before answering a
  -- mid-fight forget prompt. Sessions / Coop still offer those after the
  -- screen pops. A prompt still on the stack must not hold a dead queue.
  self.learning = nil
  if self.onDone then self.onDone(self.result or "draw", self.toLearn) end
end

function M:leave()
  -- Gen 3 has no game.stack: the screen is a game3 layer, and Gen3Ui.pop is
  -- what takes it down (and runs `exit` on the way).
  if self:generation() == 3 then
    pcall(Gen3Ui.pop, self.game, self)
    return
  end
  if self.game and self.game.stack then
    pcall(function() self.game.stack:pop() end)
  end
end

-- Advance the message queue.  Returns true while a line is still being read,
-- which is what holds the menu closed.
function M:tickMessages(dt, input)
  -- Move flash holds the queue the way CoopBattle does: AnimPlayer when the
  -- build has battle_anims, otherwise a short dwell so the stream still paces.
  if self.anim then
    if self.animPlayer and self.animPlayer.update then
      pcall(self.animPlayer.update, self.animPlayer)
    end
    self:pollAnimEffects()
    local done = true
    if self.animPlayer and self.animPlayer.isDone then
      local ok, finished = pcall(self.animPlayer.isDone, self.animPlayer)
      done = (not ok) or finished
    else
      -- 0.35 is the plain move dwell; a ball-flow row sets its own hold to the
      -- lifetime of the effect it emitted, so the throw, the wobble and the
      -- burst each finish before the row behind them starts.
      local hold = tonumber(self.animHold) or 0.35
      self.dwell = self.dwell + (dt or 0)
      done = self.dwell >= hold
        or (input and (input:wasPressed("a") or input:wasPressed("b"))
            and self.dwell >= MSG_MIN_DWELL)
    end
    if done or (input and input:wasPressed("b") and self.dwell >= MSG_MIN_DWELL) then
      self:applyPendingHitFx()
      self.anim = nil
      self.animHold = nil
      self.dwell = 0
    end
    return true
  end

  -- Three more blocking states, all display-only and all unskippable: the hit
  -- landing, the bar falling, and the monster after it. There is deliberately
  -- no input here to find -- the queue itself is what holds them, the way the
  -- engine reads a button only for a text page that has finished printing.
  --
  -- The hit beat is `startDrain`'s half of the same split the callout does:
  -- the flash and the nudge have already been emitted and the drain row is
  -- back at the head of the queue, frozen behind this hold. Falling *through*
  -- on the tick it expires rather than returning is what keeps the bar's first
  -- frame in the same tick as the last frame of the flash -- returning here
  -- left one frame with no beat running at all, and the band drew the gap.
  if self.hitHold then
    self.hitHold = self.hitHold - (dt or 0)
    if self.hitHold > 0 then
      self.dwell = 0
      return true
    end
    self.hitHold = nil
  end
  if self.draining then
    self:stepDrain(dt)
    self.dwell = 0
    return true
  end
  -- ...and a filling exp strip holds the queue the same way, for the same
  -- reason: it is a bar crawling on the cart's own unskippable loop, not a text
  -- page with a button to answer it.
  if self.expFilling then
    self:stepExpFill(dt)
    self.dwell = 0
    return true
  end
  -- The evolution movie holds the queue the same way a filling strip does:
  -- it is not a text page, A does not skip it, and MSG_AUTO_ADVANCE must
  -- not dismiss "is evolving!" while the flash is still running.
  if self.evolving then
    self:stepEvolve(dt, input)
    self.dwell = 0
    return true
  end
  -- Forget prompt on the stack: hold the award sequence the way a filling
  -- strip does, so the next `turn` does not open under Yes/No.
  if self.learning then
    self.dwell = 0
    return true
  end
  if self.faintFx then
    -- Retired by stepFx once its `t` reaches 1.
    self.dwell = 0
    return true
  end

  self.dwell = self.dwell + (dt or 0)

  if self.shown == nil then
    if #self.lines == 0 then
      -- The queue is spent and nothing is playing, so a throw still standing
      -- here has nothing left to end it: the rows that would have -- the burst,
      -- the SHOWPIC -- are never coming. That is a hub drop mid-chain, and
      -- without this the seat stays inside a ball for the rest of the fight.
      -- Only while the fight is live: a finished one is *meant* to end holding
      -- a caught monster in its ball (see `snapDisplay`).
      if self.ballFlow and not self.finished then self:snapDisplay() end
      return false
    end
    local next = table.remove(self.lines, 1)
    if type(next) == "table" and next.anim then
      self:startAnim(next)
      self.dwell = 0
      return true
    end
    if type(next) == "table" and next.drain ~= nil then
      -- A bar already where it was going costs nothing but the row.
      self:startDrain(next)
      return true
    end
    if type(next) == "table" and next.expfill ~= nil then
      -- A strip already where it was going costs nothing but the row:
      -- `startExpFill` answers false and the queue moves on this same tick.
      self:startExpFill(next)
      return true
    end
    if type(next) == "table" and next.evolve ~= nil then
      self:startEvolve(next)
      return true
    end
    if type(next) == "table" and next.learn ~= nil then
      self:startLearn(next.learn)
      return true
    end
    if type(next) == "table" and next.faintfx ~= nil then
      self:startFaintFx(next)
      return true
    end
    if type(next) == "table" and next.vfxrow ~= nil then
      -- No dwell and no hold: the line this effect belongs to is the very next
      -- row, and the effect is meant to play under it. See `startVfxRow`.
      self:startVfxRow(next)
      return true
    end
    if type(next) == "table" and next.sendball ~= nil then
      -- The throw, held for the arc's own lifetime.
      self:startSendBall(next)
      return true
    end
    if type(next) == "table" and next.spawnfx ~= nil then
      -- ...and the reveal it lands on: the swap, the burst, the monster.
      -- Holds for the burst -- unless the row was superseded, in which case it
      -- emits nothing and costs no more than the row (`startSpawnFx`).
      self:startSpawnFx(next)
      return true
    end
    if type(next) == "table" and next.stateRow ~= nil then
      -- A Gen 3 state change (the sky, a picture, the doll): no dwell, the
      -- line about it is the next row.
      self:applyStateRow(next)
      return true
    end
    if type(next) == "table" and next.clearPic ~= nil then
      self:releasePic(next.clearPic, next)
      -- No dwell: the faint line ahead already held the screen. Keep ticking
      -- if more of the queue remains.
      return true
    end
    -- Belt for strings that skipped `say` (same split Coop applies when
    -- popping a hub line). Already-paged copy stays one entry.
    if type(next) == "string" then
      local pages = pageText(next)
      next = pages[1] or ""
      for i = #pages, 2, -1 do
        table.insert(self.lines, 1, pages[i])
      end
    end
    self.shown = next
    self.dwell = 0
    return true
  end

  local pressed = input
    and (input:wasPressed("a") or input:wasPressed("b"))
  if self.dwell >= MSG_AUTO_ADVANCE or (pressed and self.dwell >= MSG_MIN_DWELL) then
    self.shown = nil
    self.dwell = 0
  end
  return true
end

function M:ensureAnimPlayer()
  if self.animPlayer ~= nil then return self.animPlayer end
  local eng = loadEngine()
  local data = self.game and self.game.data
  if not (eng and eng.AnimPlayer and data and data.battle_anims) then
    self.animPlayer = false
    return nil
  end
  local ok, player = pcall(eng.AnimPlayer.new, data.battle_anims)
  self.animPlayer = (ok and player) or false
  return self.animPlayer or nil
end

-- ------- move / catch SFX (same contract as CoopBattle / BattleState)

-- The effectiveness line in either cart's spelling: pokered's "It's super
-- effective!" and pokecrystal's "It's super-effective!" (data/text/
-- battle.asm SuperEffectiveText, which the Gold referee says word for word
-- since wave 5) -- the hyphen read as the space it stands for -- and both
-- carts' "It's not very effective...".  Shared with src/CoopBattle.lua.
function M.hitSfxFromText(text)
  if type(text) ~= "string" then return nil end
  -- Engine / BattleSim lines may break mid-phrase ("It's super\neffective!").
  local lower = text:lower():gsub("[%s%-]+", " ")
  if lower:find("super effective", 1, true) then
    return { sound = "Super_Effective", pitch = 0xe0 }
  end
  if lower:find("not very effective", 1, true) then
    return { sound = "Not_Very_Effective", pitch = 0x50 }
  end
  return nil
end
local hitSfxFromText = M.hitSfxFromText

function M:peekHitSfx()
  -- Mirror CoopBattle / solo: thud only when a following effectiveness line,
  -- faint line, or real HP-drain cue exists. Status flashes (GROWL etc.) and
  -- bare move-id anims stay silent — no default Damage fallthrough.
  local sawDamage = false
  local function remap(sfx)
    if not sfx then return nil end
    return {
      sound = Gen.sfx(self.game, sfx.sound),
      pitch = sfx.pitch,
    }
  end
  for _, row in ipairs(self.lines or {}) do
    if type(row) == "table" then
      if row.anim then break end
      if row.drain or row.faintfx then sawDamage = true end
    elseif type(row) == "string" then
      local sfx = remap(hitSfxFromText(row))
      if sfx then return sfx end
      local lower = row:lower()
      if lower:find("fainted", 1, true) then sawDamage = true end
    end
  end
  if sawDamage then
    return { sound = Gen.sfx(self.game, "Damage"), pitch = 0x20 }
  end
  return nil
end

function M:playAnimSound(soundMove)
  local eng = loadEngine()
  local Sound = eng and eng.Sound
  if not Sound then return end
  local data = self.game and self.game.data
  if not data then return end
  local animName = self.anim and self.anim.anim
  local mdef = data.moves and data.moves[soundMove]
  if animName == "GROWL" or animName == "ROAR" then
    local slot = self.anim and self.slots and self.slots[self.anim.slot]
    local species = slot and self:seatSpeciesKey(slot, true)
    if not species and slot then species = slot.species end
    if species and Sound.playMoveCry then
      pcall(Sound.playMoveCry, data, species,
        mdef and mdef.anim and mdef.anim.tempo)
    end
    return
  end
  if mdef and mdef.anim then
    if Sound.playMove then
      pcall(Sound.playMove, data, mdef.anim)
    elseif mdef.anim.sound and Sound.play then
      pcall(Sound.play, data, mdef.anim.sound)
    end
  end
end

function M:applyAnimEffect(ev)
  if type(ev) ~= "table" then return end
  if ev.sound then self:playAnimSound(ev.sound) end
  if ev.effect == "SFX_TINK" then
    local eng = loadEngine()
    local Sound = eng and eng.Sound
    local data = self.game and self.game.data
    if Sound and Sound.play and data then
      pcall(Sound.play, data, Gen.sfx(self.game, "Tink"))
    end
  end
end

function M:pollAnimEffects()
  local player = self.animPlayer
  if not (player and player.pollEffects) then return end
  local ok, events = pcall(player.pollEffects, player)
  if not ok or type(events) ~= "table" then return end
  for _, ev in ipairs(events) do
    self:applyAnimEffect(ev)
  end
end

function M:applyPendingHitFx()
  local hit = self.pendingHit
  self.pendingHit = nil
  if not hit or not hit.sfx then return end
  -- Gen 3: the SE_* name Gen.sfx mapped (peekHitSfx), through the cart's own
  -- sound-effect table.
  if self:generation() == 3 then
    local name = type(hit.sfx) == "table" and hit.sfx.sound or hit.sfx
    if type(name) == "string" then Gen3.audio.playSe(name) end
    return
  end
  local eng = loadEngine()
  local Sound = eng and eng.Sound
  local data = self.game and self.game.data
  if not (Sound and data) then return end
  if type(hit.sfx) == "table" then
    if Sound.playMove then
      pcall(Sound.playMove, data, hit.sfx)
    elseif hit.sfx.sound and Sound.play then
      pcall(Sound.play, data, hit.sfx.sound)
    end
  elseif Sound.play then
    pcall(Sound.play, data, hit.sfx)
  end
end

-- Gen 3's sounds for a queued row: a GROWL / ROAR is the user's cry, and the
-- ball flow has the cart's own throw / wobble / break-out effects.
local BALL_SE3 = {
  TOSS_ANIM = "SE_BALL_THROW", GREATTOSS_ANIM = "SE_BALL_THROW",
  ULTRATOSS_ANIM = "SE_BALL_THROW", SHAKE_ANIM = "SE_BALL",
  POOF_ANIM = "SE_BALL_OPEN",
}

function M:playGen3RowSound(row)
  if type(row) ~= "table" or type(row.anim) ~= "string" then return end
  if row.anim == "GROWL" or row.anim == "ROAR" then
    local slot = row.slot and self.slots and self.slots[row.slot]
    local sp = slot and tonumber(self:seatSpeciesKey(slot, row.slot == self:mySlot()))
    if sp then Gen3.audio.playCry(sp) end
    return
  end
  local se = BALL_SE3[row.anim]
  if se then Gen3.audio.playSe(se) end
end

function M:playMoveAnimFallback(row)
  if self:generation() == 3 then return self:playGen3RowSound(row) end
  local eng = loadEngine()
  local Sound = eng and eng.Sound
  local data = self.game and self.game.data
  if not (data and Sound and row and row.anim) then return end
  local mdef = data.moves and data.moves[row.anim]
  local anim = mdef and mdef.anim
  if row.anim == "GROWL" or row.anim == "ROAR" then
    local slot = row.slot and self.slots and self.slots[row.slot]
    local species = slot and self:seatSpeciesKey(slot, true)
    if not species and slot then species = slot.species end
    if species and Sound.playMoveCry then
      pcall(Sound.playMoveCry, data, species, anim and anim.tempo)
    end
  elseif anim and anim.sound then
    if Sound.playMove then
      pcall(Sound.playMove, data, anim)
    elseif Sound.play then
      pcall(Sound.play, data, anim.sound)
    end
  end
end

function M:startAnim(row)
  self.anim = row
  self.animHold = nil
  self.pendingHit = nil
  -- Only on the first pass: a move row reaches here twice (the callout beat
  -- below puts it straight back at the head of the queue), and re-noting the
  -- bubble for the lunge would restart a fade the lunge is meant to be read
  -- under. The bubble outlives both beats on its own -- see BEAT_SPAN.callout.
  local spoke = (not row.calledOut) and self:noteBattlefieldBubble(row)
  -- Ball chain: HIDEPIC / SHOWPIC gate foe stage pics (engine enemyHidden).
  if row.anim == "HIDEPIC_ANIM" then
    self.foePicHidden = true
  elseif row.anim == "SHOWPIC_ANIM" then
    self.foePicHidden = nil
  end

  -- ------- beat 1: the callout, on its own.
  --
  -- The shout and the lean used to land in the same tick, which read as one
  -- indistinct event -- the bubble appeared over a monster already mid-lunge.
  -- They are two beats now, and the split is the queue's own: this pass puts
  -- the bubble up, holds for BEAT_SPAN.callout and pushes the *same row* back at
  -- the head of the queue (the SHAKE fan-out in `startBallFx` does exactly
  -- this), so the next pass through here plays the lunge with nothing else on
  -- screen to compete with it. Same row and not a copy, so `self.anim` is the
  -- identical table across both beats and everything that reads it -- the
  -- acting-seat mark, `playAnimSound`, `hasPendingHpFx` -- cannot tell one
  -- beat from the other.
  --
  -- Gated on a bubble actually having gone up, which is also the gate on
  -- everything this beat is for: no bubble on the classic 160x144 path, none
  -- on Gen2, none for a ball marker, and none for the wild foe -- and each of
  -- those plays exactly as it did before, in one beat.
  if spoke then
    row.calledOut = true
    table.insert(self.lines, 1, row)
    self.animHold = BEAT_SPAN.callout
    -- Deliberately before `peekHitSfx`: the thud belongs to the lunge, and
    -- arming it here would sound it at the end of the callout *and* again on
    -- the beat that follows.
    return
  end

  local hitSfx = self:peekHitSfx()
  if hitSfx then self.pendingHit = { sfx = hitSfx } end
  -- Top-down theatre: skip classic AnimPlayer stage flashes (coords are
  -- 160×144); message/SFX timing still runs via the dwell path below.
  if self:usesBattlefield() then
    -- The attacker leans in -- but only for a real move. `HIDEPIC_ANIM`,
    -- `SHOWPIC_ANIM`, `TOSS_ANIM` and `SHAKE_ANIM` are the engine's ball
    -- markers, and a thrown ball must not make the thrower lurch. Same filter
    -- noteBattlefieldBubble uses on the same field.
    local moveAnim = type(row.anim) == "string" and row.anim ~= ""
      and not row.anim:find("_ANIM", 1, true)
    if moveAnim then
      -- Beat 2, with the callout above already spent and its bubble still up.
      -- Charge/vanish setup (`amount == 1`) is not a lunge: Dig/Fly leave the
      -- seat, SolarBeam-class glows in place. Release is a normal lean+strike.
      local setup = CHARGE_SETUP_MOVES[row.anim] and tonumber(row.amount) == 1
      if VANISH_MOVES[row.anim] and setup then
        self:startVanish(row.anim == "DIG" and "dig" or "fly", row)
        self:startChargeVfx(row)
      elseif VANISH_MOVES[row.anim] then
        self:clearVanishAt(row.slot, row.side)
        self:emitFx("emerge", row.slot, row.side)
        self:emitFx("lunge", row.slot, row.side)
        self:startMoveVfx(row)
      elseif setup then
        self:startChargeVfx(row)
      else
        self:emitFx("lunge", row.slot, row.side)
        self:startMoveVfx(row)
      end
    else
      -- ...and the markers it excludes are the throw itself: the arc, the
      -- recall, each wobble and the burst, one per queued row and each held
      -- for as long as it plays.
      self:startBallFx(row)
    end
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    return
  end
  -- Classic 160×144: Dig/Fly charge hides the pic and skips the landing
  -- AnimPlayer (that clip is the strike). Release clears the hold and
  -- falls through so the hit waits on the second turn. Gen 2 host-sim
  -- charges arrive as SLIDE_DOWN_ANIM / TELEPORT — same aliases Coop uses.
  do
    local already = self:seatVanished(row.slot)
    local setup = CHARGE_SETUP_MOVES[row.anim] and tonumber(row.amount) == 1
    local slideDown = row.anim == "SLIDE_DOWN_ANIM"
    local flyCharge = row.anim == "TELEPORT"
      and (not already or self:slotVanishKind(row.slot) == "fly")
    local firstVanish = VANISH_MOVES[row.anim] and not already
    if firstVanish or slideDown or flyCharge
        or (VANISH_MOVES[row.anim] and setup and not already) then
      self:startVanish((row.anim == "DIG" or slideDown) and "dig" or "fly", row)
      self.pendingHit = nil
      self:playMoveAnimFallback(row)
      self.animHold = (row.anim == "FLY" or flyCharge) and FX_SPAN.fly or FX_SPAN.dig
      return
    elseif VANISH_MOVES[row.anim] and already then
      self:clearVanishAt(row.slot, row.side)
    end
  end
  local player = self:ensureAnimPlayer()
  if not (player and player.start) then
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    -- Still hold briefly via dwell path when there is no player.
    return
  end
  -- Field slot on the wire; fall back to side so a missing slot still faces
  -- the flash the right way rather than always as the foe.
  local mine = row.slot == self:mySlot()
    or (row.side ~= nil and row.side == self.mySide)
  local ball = self.medBall
  local opts = {
    shakes = row.amount,
    ball = ball,
    ballFlicker = ball == "MASTER_BALL" or ball == "ULTRA_BALL" or nil,
  }
  local ok = pcall(player.start, player, row.anim, mine, opts)
  if not ok then
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    -- still hold briefly via dwell path
    return
  end
  self:pollAnimEffects()
end

-- Drop a KO'd pic after its faint line (and any anim queued ahead of it).
--
-- `row` is the queued row, which names the occupant the release was filed for.
-- Same refusal as `startDrain`: a send batched behind the KO means the seat has
-- already changed hands, and the pic standing on it is the newcomer's -- taking
-- it down here left the arrival invisible until something else refreshed it.
-- The held sink still goes, though: it belongs to the monster that left, and
-- there is no pic of theirs for it to apply to any more.
function M:releasePic(index, row)
  local slot = self.slots[index]
  if not slot then return end
  if row ~= nil and slot.species ~= row.species then
    self:dropFaintFx(index)
    self:clearVanishAt(index)
    return
  end
  slot.sprite = nil
  slot.icon = nil
  slot.koHold = nil
  -- Nothing is drawn from this seat any more; put the two clocks back in step
  -- so a later send into the same slot cannot inherit a stale descent.
  slot.shownHp = slot.hp or 0
  -- And drop the held sink (stepFx keeps a finished one so the KO stays down
  -- while its line is read) -- there is no pic left for it to apply to, and a
  -- fresh monster on this seat must not walk on already face down.
  self:dropFaintFx(index)
  -- And the same for a throw held on this seat: there is no monster left here
  -- to keep inside a ball.
  if self.ballFlow and self.ballFlow.index == index then self:clearBallFlow() end
  self:clearVanishAt(index)
end

-- Retire any faint effect on the seat a released pic sat on.
--
-- Matched by seat and not by side alone: `emitFx` stamps `seatIndex`, and in a
-- future multi-seat mode one seat's release would otherwise drop a
-- co-occupant's sink. An entry carrying no stamp still matches on side, so
-- nothing filed before this survives a release that used to clear it.
function M:dropFaintFx(index, seatIndex)
  local list = self.fx
  if type(list) ~= "table" then return end
  local side = self:fxSideFor(index)
  local seat = seatIndex or 1
  local kept = {}
  for _, fx in ipairs(list) do
    local mine = type(fx) == "table" and fx.kind == "faint" and fx.side == side
      and (fx.seatIndex == nil or fx.seatIndex == seat)
    if not mine then kept[#kept + 1] = fx end
  end
  self.fx = (#kept > 0) and kept or nil
end

-- ------- the bar falling, and the monster after it

-- Which arena side a field slot sits on. `side` is the fallback for a row
-- that names no slot, so an effect still lands the right way round rather
-- than always as the foe.
function M:fxSideFor(index, side)
  if index ~= nil and index == self:mySlot() then return "ally" end
  if index == nil and side ~= nil then
    return (side == self.mySide) and "ally" or "foe"
  end
  return "foe"
end

-- Start one effect. Returns the record so a caller that needs to wait on it
-- (the faint row) can hold the reference rather than search the list.
--
-- `seatIndex` is 1-based within the side; a mediated 1v1 has exactly one seat
-- per side, and the argument is here so a future multi-seat mode does not
-- have to change the contract Battlefield renders against.
function M:emitFx(kind, index, side, seatIndex, extra)
  if not self:usesBattlefield() then return nil end
  local span = FX_SPAN[kind]
  if not span then return nil end
  local fx = {
    kind = kind,
    side = self:fxSideFor(index, side),
    seatIndex = seatIndex or 1,
    t = 0,
    elapsed = 0,
    duration = span,
  }
  -- `extra` is the particle record's own payload (style, palette, delivery,
  -- scale, intensity, seed, and the seat a travelling effect launches from).
  -- Copied key by key rather than merged wholesale so a caller cannot
  -- accidentally overwrite `kind`, `t` or `elapsed` -- the three fields
  -- `stepFx` owns -- and so a spec table from the catalogue can be handed in
  -- directly without being defensively copied first.
  if type(extra) == "table" then
    for _, key in ipairs(VFX_KEYS) do
      if extra[key] ~= nil then fx[key] = extra[key] end
    end
    local span2 = tonumber(extra.duration)
    if span2 and span2 > 0 then fx.duration = span2 end
  end
  local list = self.fx
  if type(list) ~= "table" then
    list = {}
    self.fx = list
  end
  list[#list + 1] = fx
  return fx
end

-- ------- particles
--
-- One emission, from a spec src/Vfx.lua resolved. Everything that has a look
-- goes through here -- a move, an item, a condition landing, a stat stage
-- moving -- so there is exactly one place that decides what a seed is, which
-- seat an effect is anchored to and which one it travels from.
--
-- `targetIndex` is the field slot the effect lands on; `fromIndex` the slot it
-- comes from, and it is only meaningful for the travelling deliveries
-- (projectile / beam) and for `self`. A nil spec is not an error -- the
-- catalogue answers nil for a thrown ball, which already has a whole flow of
-- its own, and for an item that does nothing -- so it is simply not drawn.
function M:emitVfx(spec, targetIndex, fromIndex)
  if type(spec) ~= "table" then return nil end
  if not self:usesBattlefield() then return nil end
  -- The seed is what stops two Flamethrowers in a row from drawing the
  -- identical sixteen sparks. Counted rather than random: two clients watching
  -- the same fight see the same particles, and a headless run is reproducible.
  self.vfxSeed = ((tonumber(self.vfxSeed) or 0) + 1) % 512
  local extra = {
    style = spec.style,
    palette = spec.palette,
    delivery = spec.delivery,
    scale = spec.scale,
    intensity = spec.intensity,
    duration = spec.duration,
    seed = self.vfxSeed,
  }
  if fromIndex ~= nil then
    extra.fromSide = self:fxSideFor(fromIndex)
    extra.fromSeat = 1
  end
  return self:emitFx("vfx", targetIndex, nil, nil, extra)
end

-- The move a queued `anim` row names, as the engine's own record. nil for a
-- ball marker, for a row naming a move this build does not have, and headless.
function M:moveDefFor(animId)
  if type(animId) ~= "string" or animId == "" then return nil end
  local data = self.game and self.game.data
  local moves = data and data.moves
  if type(moves) ~= "table" then return nil end
  local def = moves[animId]
  return (type(def) == "table") and def or nil
end

-- The seat opposite a slot, which is where a move aimed at "the other side"
-- lands. A mediated fight is 1v1, so this is exact rather than a guess.
function M:opposingSlot(index)
  if index == self:foeSlot() then return self:mySlot() end
  return self:foeSlot()
end

-- A move's particles, on the lunge beat.
--
-- The spec is also kept (`self.moveVfx`) because beat 3's impact burst is
-- drawn in the *attacking move's* colours, and that beat is a different row --
-- so the two are joined by remembering the last move played rather than by
-- either row carrying the other's business. Cleared first, so a row this
-- refuses to draw for cannot leave the previous move's palette standing.
--
-- Returns the effect record, or nil for a row with no move behind it.
function M:startMoveVfx(row)
  self.moveVfx = nil
  if not self:usesBattlefield() then return nil end
  if type(row) ~= "table" then return nil end
  local animId = row.anim
  if type(animId) ~= "string" or animId == "" then return nil end

  -- `moveDefFor` is nil for a move this build does not carry -- a Gen 2 id on
  -- a Gen 1 boot, a referee running a mod this client does not have -- and the
  -- catalogue answers for a nil definition rather than refusing: an unknown
  -- move draws NORMAL's impact, which is the right amount of "something
  -- happened" for a move nobody here can name.
  -- Gen 3's token is the sheet's move id, not a data.moves key (Emerald has
  -- no data.moves at all), so its type and power come from the move row.
  local spec
  if Gen3.active() then
    spec = Vfx.forMove3(animId, Sheet3.rowByToken(animId))
  else
    spec = Vfx.forMove(animId, self:moveDefFor(animId))
  end
  self.moveVfx = spec

  local from = row.slot
  if from == nil and row.side ~= nil then from = slotOfSide(row.side) end
  if from == nil then from = self:mySlot() end
  -- A move that acts on its user plays on the user's own seat; everything else
  -- is aimed at the seat opposite, which in a 1v1 is exactly one seat.
  local target = (spec.delivery == "self") and from or self:opposingSlot(from)
  return self:emitVfx(spec, target, from)
end

-- A queued particle row -- an item opening, a condition landing, a stat stage
-- moving -- reaching the head of the queue.
--
-- **It takes no hold.** Every one of these has a sentence of its own coming
-- immediately behind it ("X was healed", "X was poisoned!"), and the effect is
-- meant to be running *under* that line rather than before it: holding here
-- would insert half a second of empty arena between the item being used and
-- the box saying so. The row costs one tick and the queue moves straight on.
function M:startVfxRow(row)
  if type(row) ~= "table" then return false end
  local spec = row.vfxrow
  if type(spec) ~= "table" then return false end
  self:emitVfx(spec, row.slot, row.from)
  return true
end

-- File one, in referee order. Called at parse rather than at play so the
-- effect keeps its place in the stream relative to the lines around it; a nil
-- spec (a thrown ball, an item with no look, a condition clearing) files
-- nothing at all.
function M:queueVfx(spec, index, fromIndex)
  if type(spec) ~= "table" then return false end
  if not self:usesBattlefield() then return false end
  self.lines[#self.lines + 1] = {
    vfxrow = spec, slot = index, from = fromIndex,
  }
  return true
end

-- ------- the ball flow
--
-- Five queued rows describe one throw -- toss, burst, recall, shake, and the
-- pair that ends a failure -- and each one of them is played here as it
-- reaches the head of the queue, never when the packet carrying it arrived.
-- `_emitBallChain` (src/BattleSim/Turn.lua, mirrored in server/lib/battle) is
-- the order they come in.

-- The seat a ball row is really about.
--
-- Every row in the chain is stamped with the *thrower's* slot and side, and
-- the engine's own chain hides the enemy pic whoever threw -- so the arc, the
-- recall and the wobbles all belong to the seat opposite the thrower.
function M:ballTargetSlot(row)
  local threw = self:mySlot()
  if type(row) == "table" then
    if row.slot ~= nil then
      threw = row.slot
    elseif row.side ~= nil then
      threw = slotOfSide(row.side)
    end
  end
  if threw == self:foeSlot() then return self:mySlot() end
  return self:foeSlot()
end

-- Retire the hiding effects on one side. Paired with the emit that replaces
-- them, so the seat is never uncovered between two rows of the same throw.
function M:dropBallFx(side)
  local list = self.fx
  if type(list) ~= "table" then return end
  local kept = {}
  for _, fx in ipairs(list) do
    local hiding = type(fx) == "table" and BALL_HIDE_FX[fx.kind] and fx.side == side
    if not hiding then kept[#kept + 1] = fx end
  end
  self.fx = (#kept > 0) and kept or nil
end

-- The monster is out of the ball (or the seat it was on is gone): drop the
-- hold that kept it hidden.
function M:clearBallFlow()
  local flow = self.ballFlow
  if not flow then return end
  self.ballFlow = nil
  self:dropBallFx(flow.side)
end

function M:dropVanishFx(side, seatIndex)
  local list = self.fx
  if type(list) ~= "table" then return end
  local kept = {}
  for _, fx in ipairs(list) do
    local hiding = type(fx) == "table" and VANISH_HIDE_FX[fx.kind]
      and fx.side == side
      and (fx.seatIndex == nil or fx.seatIndex == (seatIndex or 1))
    if not hiding then kept[#kept + 1] = fx end
  end
  self.fx = (#kept > 0) and kept or nil
end

function M:clearVanishAt(index, side)
  local fxSide = self:fxSideFor(index, side)
  local key = vanishKey(fxSide, 1)
  if self.vanishFlow then self.vanishFlow[key] = nil end
  self:dropVanishFx(fxSide, 1)
end

function M:startVanish(kind, row)
  if not VANISH_HIDE_FX[kind] then return nil end
  local index = row and row.slot
  local fxSide = self:fxSideFor(index, row and row.side)
  self:dropVanishFx(fxSide, 1)
  self.vanishFlow = self.vanishFlow or {}
  self.vanishFlow[vanishKey(fxSide, 1)] = { kind = kind, index = index, side = fxSide }
  -- Theatre particles only: classic hides the pic via `seatVanished`.
  if self:usesBattlefield() then
    self:emitFx(kind, index, row and row.side)
  end
  return kind
end

function M:seatVanished(index)
  return self:slotVanishKind(index) ~= nil
end

-- Dig vs Fly on this seat. Prefers the hide we armed; falls back to a
-- charge id on the slot so a Gen 2 TELEPORT charge still names Fly.
function M:slotVanishKind(index)
  if index == nil then return nil end
  if self.vanishFlow then
    local rec = self.vanishFlow[vanishKey(self:fxSideFor(index), 1)]
    if type(rec) == "table" and rec.kind then return rec.kind end
  end
  local slot = self.slots and self.slots[index]
  local id = slot and (slot.chargeMove or slot.charging)
  if type(id) == "table" then id = id.id or id.moveId end
  if type(id) == "string" then
    id = string.upper(id)
    if id == "DIG" then return "dig" end
    if id == "FLY" then return "fly" end
  end
  return nil
end

function M:startChargeVfx(row)
  if type(row) ~= "table" then return nil end
  local spec = Vfx.CHARGE_STYLE and Vfx.CHARGE_STYLE[row.anim]
  if not spec then return nil end
  return self:emitVfx(spec, row.slot, row.slot)
end

-- A ball marker reaches the head of the queue. Returns the effect kind it
-- played, or nil for a row with nothing left to show.
--
-- Only ever called from the battlefield branch of `startAnim`: the classic
-- 160x144 path and Gen2 run the engine's AnimPlayer over these same rows and
-- have no arena for any of this.
function M:startBallFx(row)
  if not self:usesBattlefield() then return nil end
  if type(row) ~= "table" then return nil end
  local kind = BALL_FX[row.anim]
  if not kind then return nil end

  local index = self:ballTargetSlot(row)
  local side = self:fxSideFor(index)
  local flow = self.ballFlow
  if flow and flow.side ~= side then
    -- A throw at the other seat: the old one is over whatever it was waiting
    -- for, and leaving it held would keep a monster in a ball nobody threw.
    self:clearBallFlow()
    flow = nil
  end
  local hidden = (flow ~= nil) and flow.hidden == true

  if kind == "poof" then
    -- A POOF with no throw open is a send-out marker rather than part of a
    -- chain, and the arrival pop is already the `spawnfx` row queued by the
    -- send (see tickMessages) -- bursting again here would double it over a
    -- monster that has only just walked on.
    if flow == nil then return nil end
    -- POOF is both halves of a throw: the ball bursting open on the way in,
    -- and the monster coming back out of it when it breaks free. Which one it
    -- is is which side of HIDEPIC the row landed on. A failure ends
    -- POOF + SHOWPIC and only the first of those is the reappearance -- the
    -- second would be a burst over a monster already standing there.
    if row.anim == "SHOWPIC_ANIM" and not hidden then return nil end
    self:emitFx("poof", index)
    -- Either way the ball is open, so the hold that hid the seat for the arc
    -- ends here: a throw the referee gave no shakes at all is TOSS + POOF and
    -- nothing else (`_emitBallChain` returns early), and leaving the flow
    -- standing kept the seat inside a ball that had already burst for the rest
    -- of the fight. The recall behind a real attempt opens a fresh flow of its
    -- own -- HIDEPIC is the next row.
    self:clearBallFlow()
    -- ...and if it *was* hidden, this POOF is the monster coming back out.
    if hidden then self:emitFx("spawn", index) end
    self.animHold = FX_SPAN.poof
    return kind
  end

  -- SHAKE carries the whole count on a single row (`anim("SHAKE_ANIM", shakes)`
  -- in both twins), and the contract is one wobble per effect -- so the row
  -- plays the first rock and puts the remainder back at the head of the queue.
  -- Still queue-ordered, and still one thing at a time: nothing behind it can
  -- start until the last wobble has been through here.
  if kind == "wobble" then
    local left = floor(tonumber(row.amount) or 1)
    if left > BALL_SHAKE_MAX then left = BALL_SHAKE_MAX end
    if left > 1 then
      table.insert(self.lines, 1, {
        anim = row.anim, slot = row.slot, side = row.side, amount = left - 1,
      })
    end
  end

  -- The hiding kinds. The previous one is dropped in the same call the next is
  -- emitted in, and `stepFx` holds a finished one at its last frame, so the
  -- seat stays covered from the recall to the burst that undoes it.
  self:dropBallFx(side)
  self.ballFlow = { side = side, index = index, hidden = hidden or kind == "recall" }
  self:emitFx(kind, index)
  self.animHold = FX_SPAN[kind]
  return kind
end

-- Advance every live effect and retire the finished ones. Scaled by dt so the
-- fixed 60Hz step reads as one frame and a headless second still completes.
function M:stepFx(dt)
  local list = self.fx
  if type(list) ~= "table" or #list == 0 then return end
  local step = tonumber(dt) or 0
  if step <= 0 then step = 1 / 60 end
  local kept = {}
  for _, fx in ipairs(list) do
    if type(fx) == "table" then
      local span = tonumber(fx.duration) or FX_SPAN[fx.kind] or 0.3
      if span <= 0 then span = 0.3 end
      fx.elapsed = (tonumber(fx.elapsed) or 0) + step
      local t = fx.elapsed / span
      if t >= 1 then
        fx.t = 1
        -- The faint row waits on this one; releasing it is what lets the
        -- "X fainted!" line behind it print.
        if self.faintFx == fx then self.faintFx = nil end
        -- A finished sink is *held* rather than retired: its end state is the
        -- monster face down and invisible, and the pic is still on the seat
        -- for another second and a half behind the "X fainted!" line. Retiring
        -- it here popped the KO back to full opacity for exactly that long.
        -- `releasePic` drops it when the seat is genuinely cleared.
        if fx.kind == "faint" then
          kept[#kept + 1] = fx
        elseif BALL_HIDE_FX[fx.kind] and self.ballFlow
            and self.ballFlow.side == fx.side then
          -- Same hold, same reason, for a monster inside a ball: its end state
          -- is a seat with nothing standing on it, and the row that undoes that
          -- is still to come. `startBallFx` replaces it as each row plays and
          -- `clearBallFlow` drops it when the monster comes back out (or the
          -- seat is released), so nothing here outlives the throw.
          kept[#kept + 1] = fx
        elseif VANISH_HIDE_FX[fx.kind] and self.vanishFlow
            and self.vanishFlow[vanishKey(fx.side, fx.seatIndex)] then
          -- Dig / Fly charge: stay gone through the foe's turn until release.
          kept[#kept + 1] = fx
        end
      else
        fx.t = t
        kept[#kept + 1] = fx
      end
    end
  end
  self.fx = (#kept > 0) and kept or nil
end

-- The HP the arena plates are drawn from, which trails `slot.hp` while a
-- drain plays.
--
-- Rounded the engine's way: a bar on its way down rounds up and one on its
-- way up rounds down, so the number always lags the animation by less than a
-- point rather than reaching the destination before the bar does.
function M:shownHpOf(slot)
  if type(slot) ~= "table" then return 0 end
  local truth = tonumber(slot.hp) or 0
  local shown = tonumber(slot.shownHp)
  if shown == nil then return truth end
  if shown > truth then return math.ceil(shown) end
  return floor(shown)
end

-- The arrival, queued rather than played the moment the packet was parsed.
--
-- **Two rows, not one** -- a monster is *thrown* onto the field:
--
--   1. `sendball` -- the ball leaves the owning trainer and arcs at the seat,
--      held for `FX_SPAN.ball` (`startSendBall`);
--   2. `spawnfx`  -- the reveal: the ball opens, and the monster comes out of
--      the burst. `applySwap` + `poof` + `spawn` in one row, held for
--      `FX_SPAN.poof` (`startSpawnFx`).
--
-- The send line is already ahead of both (`onEvent`'s `send` branch), so the
-- whole of it reads as one sentence: "BOB sent out RATTATA!", the throw, the
-- burst, the monster. Nothing appears before the ball lands -- which is the
-- point, and was the bug: the pop used to be the *first* row of a send and
-- took no dwell, so the monster was standing there before its own line.
--
-- Nobody throws a wild monster. A wild-side arrival (`sendThrows`) keeps the
-- plain poof + spawn it always had -- one row, no ball -- and so does any seat
-- with no trainer to throw from.
--
-- Both rows now hold the queue, so both are in `hasPendingHpFx`: a fanfare
-- must not start over a ball still in the air.
--
-- **The reveal row is also where the arrival window closes**, for the seat
-- nobody is standing on.
--
-- A seat that already has an occupant is covered by `slot.pending`: the
-- newcomer is not on the seat record at all yet, so there is nothing to hide
-- and the monster still being shown out keeps its bar, its pic and its sink.
-- An *empty* seat -- the intro, and any replacement whose predecessor has
-- already been released -- has no such cover, because `noteSlot` filled it at
-- parse: the arrival is on the record and `battlefieldSeat` would draw it.
-- So that case raises a hold instead, and both windows end at the same row.
--
-- The gate matters. Hiding unconditionally is the fix's failure mode: it takes
-- a KO'd monster off the arena in the middle of its own sink, which is a worse
-- bug than the one being fixed.
--
-- This is the ball flow's `BALL_HIDE_FX` hold (see `startBallFx`) with one
-- difference worth stating: a ball hold is *held at t == 1* by `stepFx`,
-- because the row that undoes it may be several rows away. A spawn hold is
-- dropped by the very row that emits the effect, so it needs no retention at
-- all -- there is no window in which the hold outlives its own row. The seat
-- stays hidden for the whole of the throw, which is exactly what an empty seat
-- with a ball flying at it should look like.
--
-- The send chain is deliberately *not* `ballFlow`. That flow exists for a
-- throw at an occupied seat -- it hides a monster that is standing there and
-- holds the hiding effect until the row that opens the ball again. Here the
-- seat is empty (`spawnHide`) or still somebody else's (`slot.pending`), so
-- there is nothing to hide and nothing to hold: the two rows carry their own
-- `animHold` and answer to nobody else. A catch throw landing in the middle of
-- one is therefore unchanged, which is the property worth keeping.
--
-- The row names the arrival it was queued for, the same way the drain, the
-- sink and the release name their occupant: two sends can reach this queue
-- before either row plays, and a row that installed whatever happened to be
-- parked would then hand the seat to the *second* newcomer at the *first*
-- one's pop -- collapsing the exit sequence the park exists to protect.
-- `hide` is the same stamp for the other window: the row that raised the hold
-- is the row that drops it.
function M:queueSpawnFx(index, side)
  if index == nil then return false end
  local slot = self.slots[index]
  local arrive = slot and slot.pending or nil
  local hide = nil
  if not arrive then
    self.spawnHide = self.spawnHide or {}
    self.spawnHide[index] = true
    hide = true
  end
  -- Theatre only: the ball arc. Classic still queues the reveal row below
  -- so `applySwap` can install a parked arrival.
  local thrown = self:usesBattlefield() and self:sendThrows(index) or nil
  if thrown then
    -- Stamped with the same arrival the reveal row is, so both halves of one
    -- chain live or die together: a throw whose reveal has been superseded (or
    -- closed forwards by `snapDisplay`) must not fly at a seat that is already
    -- showing the monster it was going to deliver.
    self.lines[#self.lines + 1] = {
      sendball = index, side = side, arrive = arrive, hide = hide,
    }
  end
  self.lines[#self.lines + 1] = {
    spawnfx = index, side = side, arrive = arrive, hide = hide,
  }
  return true
end

-- Is there a trainer to throw this arrival's ball?
--
-- Everybody on a mediated field is somebody's monster except the wild foe: a
-- protocol-only wild encounter fields a synthetic seat that no trainer owns
-- (`mode == "wild"`, our own seat excepted -- we throw ours), and a ball
-- arcing out of an empty patch of grass is worse than no ball at all. That
-- seat keeps the plain burst it has always had.
--
-- Written as "wild, and not mine" rather than "not mine": every other mode on
-- this screen (1v1, and the coop modes CoopBattle drives) has a trainer on
-- both sides, and `ballOrigin`'s own fallback already covers a side whose
-- trainer is not placed.
function M:sendThrows(index)
  if not self:usesBattlefield() then return false end
  if self.mode ~= "wild" then return true end
  return index == self:mySlot()
end

-- Is this row's arrival still the one the seat is waiting for?
--
-- One test for both rows of a chain, and it is the round-7 stamp rule read
-- once rather than twice: a row filed against a parked arrival is live while
-- that arrival is still parked (`slot.pending == row.arrive`), and a row filed
-- against an empty seat is live while the hold it raised is still standing
-- (`spawnHide`). Anything else -- a second send that re-parked the seat, a
-- `snapDisplay` that closed the window forwards -- means the monster this
-- chain was going to deliver is already accounted for, and every effect the
-- chain would play would land on somebody else.
function M:sendChainLive(row)
  if type(row) ~= "table" then return false end
  local index = row.sendball or row.spawnfx
  if index == nil then return false end
  if row.arrive ~= nil then
    local slot = self.slots[index]
    return slot ~= nil and slot.pending == row.arrive
  end
  if row.hide then
    return (self.spawnHide and self.spawnHide[index]) and true or false
  end
  return false
end

-- The `sendball` row comes up: the ball is in the air.
--
-- Held for its own lifetime the way every ball-flow row is (`startBallFx`),
-- with `self.anim` set so the message band shows the empty box a throw plays
-- under rather than the line before it -- again exactly as the catch chain
-- does. The seat it is flying at is hidden or still the departing monster's,
-- and stays that way until the reveal row behind this one.
--
-- `own` is what tells Battlefield the arc starts on the *thrower's* side: a
-- catch ball comes from the seat opposite its target, a send-out ball comes
-- from the trainer who owns the seat.
function M:startSendBall(row)
  if type(row) ~= "table" then return false end
  -- The same liveness test the reveal row applies, asked one row earlier: a
  -- chain whose arrival is no longer the one this seat is waiting for throws
  -- nothing at all.
  if not self:sendChainLive(row) then return false end
  local fx = self:emitFx("ball", row.sendball, row.side)
  if not fx then return false end
  fx.own = true
  self.anim = row
  self.animHold = FX_SPAN.ball
  self.dwell = 0
  return true
end

-- The `spawnfx` row comes up: the ball opens and the monster is on the arena.
--
-- Three things in one row because they are one moment: the seat changes hands
-- (`applySwap` -- the parked arrival is installed, or the hold on an empty
-- seat dropped), the burst is emitted over it, and the monster scales out of
-- the burst. Every frame before this one showed the seat as it was -- empty,
-- or somebody else's -- which is the point.
--
-- **A row that did not land emits nothing.** Two sends can reach the queue
-- before either row plays; the first row's arrival has then been superseded by
-- the second's (`applySwap` answers false, `slot.pending ~= row.arrive`) and
-- the seat still belongs to whoever is being shown out. Bursting anyway --
-- which is what this did until round 8 -- popped a spawn over the *outgoing*
-- monster, the second half of the doubled send the owner reported. The same
-- test covers the other window: a `hide` row whose hold is already gone (a
-- `snapDisplay` closed it forwards) is stale too, and the monster it would
-- announce has been standing there since.
function M:startSpawnFx(row)
  if type(row) ~= "table" then return false end
  local index = row.spawnfx
  -- Asked before the swap, because the swap is what consumes the park this
  -- reads. `applySwap` still runs either way -- on a stale row it is a no-op
  -- that answers false, and it is the only thing allowed to change a seat's
  -- occupant.
  local live = self:sendChainLive(row)
  self:applySwap(row)
  if not live then return false end
  self:emitFx("poof", index, row.side)
  self:emitFx("spawn", index, row.side)
  -- The reveal is a beat of its own now that the send line is ahead of it
  -- rather than behind it: the burst is read, and only then does the queue move
  -- on. `FX_SPAN.poof` is the burst's own lifetime, which is the same rule
  -- every ball row is held by -- the row *is* the effect.
  self.anim = row
  self.animHold = FX_SPAN.poof
  self.dwell = 0
  return true
end

-- The queued `spawnfx` row comes up: this is the frame the arrival is on the
-- arena, and the only frame on which the seat's occupant is allowed to change.
--
-- CoopBattle's `applySwap` (src/CoopBattle.lua:3518), same beat and same
-- argument -- there the shadow is dropped and `noteBattlefieldSpawn` fires;
-- here the parked record is installed and the pop is emitted. Both windows the
-- send opened close here: the hold on an empty seat, and the park on an
-- occupied one.
function M:applySwap(row)
  if type(row) ~= "table" then return false end
  local index = row.spawnfx
  local slot = self.slots[index]
  -- The hold this row raised, dropped by this row. A later row's hold is not
  -- this row's to release.
  if row.hide and self.spawnHide then self.spawnHide[index] = nil end
  local arrival = row.arrive
  -- Superseded: a second send landed on this seat before either row played, so
  -- the park no longer describes this row's newcomer. The row behind is the one
  -- that installs; the seat keeps who it is showing until then.
  if not (arrival and slot and slot.pending == arrival) then return false end
  slot.pending = nil
  if index ~= nil then self:clearVanishAt(index) end
  slot.species = arrival.species
  slot.speciesId = arrival.speciesId
  slot.level = arrival.level
  slot.sprite = nil
  slot.icon = nil
  slot.koHold = nil
  slot.transformId, slot.form, slot.substitute = nil, nil, nil
  -- Same reading of an arrival's numbers as `noteSlot`'s, and for the same
  -- reason: the maximum the referee stated for this monster (PROTOCOL 24) is
  -- what its bar is out of, and the older guess -- the biggest HP the seat has
  -- ever been told about -- is only what is left when it stated none.
  slot.hp = arrival.hp or 0
  -- The bar starts where this monster *walked out*, which is where it already
  -- stands on every ordinary arrival and is higher than it on the one that
  -- matters: a hit landing inside the park window moved `arrival.hp` and left
  -- `arrival.shownHp` where the send put it, and the gap between the two is
  -- the drain row waiting behind this one. Taking the current number here
  -- swallowed that fall -- the newcomer simply appeared already low and the
  -- attack that hurt it showed nothing at all.
  --
  -- The predecessor's descent, which ended on this same seat record, is
  -- overwritten either way: it is never inherited.
  slot.shownHp = arrival.shownHp or slot.hp
  if arrival.maxHp ~= nil then slot.maxHp = max(1, arrival.maxHp) end
  if slot.hp > (slot.maxHp or 1) then slot.maxHp = slot.hp end
  if slot.shownHp > (slot.maxHp or 1) then slot.maxHp = slot.shownHp end
  slot.status = arrival.status
  slot.confused = arrival.confused
  -- A level-up's climb belonged to the monster that walked off (`noteSlot`
  -- drops it on a fresh send for the same reason): carried over, the
  -- newcomer's every later packet was read that much too high.
  slot.levelHpGrown, slot.levelHpRefereed = 0, nil
  self:arriveOnSeat(index, index == self:mySlot())
  return true
end

-- Queue the fall for a slot whose truth HP has already moved.
--
-- Draining to an absolute target is idempotent, which is why a `damage` event
-- and the `faint` behind it can both queue one for the same seat without the
-- bar moving twice: the second finds the first has already landed.
--
-- The row carries the occupant it was queued for, not just the seat: a switch
-- can land between queue and play, and a fall meant for the monster that left
-- would otherwise be run against the one that replaced it. CoopBattle's twin
-- names the battler for the same reason.
-- `residual` is the `damage` event's own `status` field, present when a burn
-- or poison ticking dealt the damage rather than a move. It rides on the row
-- because beat 3's impact burst borrows the *attacking move's* palette, and a
-- residual has no attacking move -- taking the last one's colours would paint
-- a poison tick in the last Fire attack's orange.
--
-- **Filed against whoever this seat will be showing when the row comes up**,
-- which is not always who is standing on it now. An arrival parked behind a
-- monster still finishing its exit (`noteSlot`) is already the one the referee
-- is talking about, and its own `spawnfx` row is ahead of this one in the
-- queue -- so a hit that lands inside that window is filed against the
-- *newcomer* and falls after the swap that puts it on the seat. Read off the
-- seat instead, the fall was measured between the departing monster's HP and
-- its own display clock, found them equal, and queued nothing: the switch and
-- the attack that answers it resolve in one batch, so that was every attack on
-- a monster the turn it came in. CoopBattle asks the queue the same question
-- for the same reason (`showing`, src/CoopBattle.lua:3158).
function M:queueDrain(index, residual)
  if index == nil then return false end
  -- Classic draws the same `shownHp` clock the arena does (`shownHpOf` on
  -- both HUDs). Gating this on the theatre left a parked switch-in with
  -- nowhere to fall: the newcomer appeared already low and the attack
  -- that hit it showed nothing.
  local slot = self.slots[index]
  if not slot then return false end
  local occupant = slot.pending or slot
  local to = tonumber(occupant.hp) or 0
  if occupant.shownHp == nil then
    occupant.shownHp = to
    return false
  end
  if occupant.shownHp == to then return false end
  self.lines[#self.lines + 1] = {
    drain = index, to = to, species = occupant.species,
    residual = (residual ~= nil) or nil,
  }
  return true
end

-- A queued drain row comes up.
--
-- `to` is clamped and NaN refused, and that is a wire rule rather than a tidy
-- one: the number came off the hub, `stepDrain` stops on exact equality, and
-- a drain is deliberately unskippable -- so an infinity is a stop condition
-- that never comes true and a message queue that never moves again.
function M:startDrain(row)
  local slot = self.slots[row and row.drain]
  local to = tonumber(row and row.to)
  if not (slot and to) then return false end
  if to ~= to then return false end
  -- Somebody else is standing here now: the row belongs to the monster that
  -- was recalled, and running it would drain the newcomer's bar to a number
  -- that was never theirs. Dropped, not deferred.
  if slot.species ~= row.species then return false end
  local maxHp = tonumber(slot.maxHp) or 0
  to = max(0, min(maxHp, to))
  if slot.shownHp == nil then
    slot.shownHp = to
    return false
  end
  if slot.shownHp == to then return false end

  -- ------- beat 3: the hit, with the bar still frozen.
  --
  -- Now, with the bar about to move, is when the hit reads: the defender
  -- flashes white and the field takes a nudge. Emitted here rather than when
  -- the `damage` event arrived because a resolved turn arrives as one batch --
  -- both seats would jolt in the same frame, ahead of any text.
  --
  -- And *before* the fall rather than under it, the callout's split again: a
  -- flash over a bar already sliding is one indistinct event, so the strike
  -- gets BEAT_SPAN.hit of its own with the bar held exactly where it was, and
  -- the row goes back at the head of the queue to start the drain when the
  -- hold expires. Re-validated on the way back through, which is the point of
  -- re-queueing the row instead of remembering it: a switch landing between
  -- the two beats drops the fall the same way it always did.
  --
  -- A climb (a heal, a drain move's restore) gets no beat and no effects at
  -- all: nothing was struck, so the bar starts moving on this very tick, as
  -- before. Multi-hit is one anim row and one damage event per strike
  -- (`BattleSim/Turn.lua` loops `_damage` under a single `_emit("anim")`), so
  -- the callout and the lunge play once and each strike gets its own beat here.
  if slot.shownHp > to and not row.hit then
    row.hit = true
    table.insert(self.lines, 1, row)
    self:emitFx("flash", row.drain)
    self:emitFx("shake", row.drain)
    -- The punctuation on the blow, in the attacking move's own colours: a
    -- compact impact burst on the seat that took it. Small and short on
    -- purpose -- the move's own effect is very likely still running over this
    -- same seat, and this is the moment of contact inside it, not a second
    -- effect competing with it. `self.anim` is the row that opened this
    -- exchange, so a residual or a recoil with no move behind it gets the
    -- neutral white burst rather than borrowing the last move's palette.
    self:emitVfx(Vfx.forImpact(not row.residual and self.moveVfx or nil), row.drain)
    self.hitHold = BEAT_SPAN.hit
    return true
  end

  -- ------- beat 4: the fall.
  self.draining = { slot = row.drain, to = to, frames = DRAIN_BUDGET }
  return true
end

function M:stepDrain(dt)
  local at = self.draining
  if not at then return end
  local slot = self.slots[at.slot]
  if not slot then
    self.draining = nil
    return
  end
  local frames = frameCount(dt)
  at.frames = (tonumber(at.frames) or DRAIN_BUDGET) - frames
  local step = max(1, (tonumber(slot.maxHp) or 1) / DRAIN_FRAMES) * frames
  local shown = tonumber(slot.shownHp) or at.to
  if shown > at.to then
    shown = max(at.to, shown - step)
  else
    shown = min(at.to, shown + step)
  end
  slot.shownHp = shown
  -- Out of budget: the bar has had longer than a full descent and still has
  -- not landed, so it is put there. There is no button out of a drain, and
  -- the only other end to this is a queue that never moves again.
  if shown == at.to or at.frames <= 0 then
    slot.shownHp = at.to
    self.draining = nil
  end
end

-- The fall of the monster itself, queued as its own row so the sink finishes
-- before "X fainted!" prints -- the engine's order, and the reason the pic is
-- not released until the line behind it has been read.
--
-- Stamped with its occupant, exactly like the drain row: the referee can batch
-- an auto-replacement behind the KO, and a sink meant for the monster that left
-- would otherwise play against the one standing there now.
--
-- A parked arrival is stamped in preference to the seat, exactly as the drain
-- row is: the monster that walked in and fell inside one batch has not been
-- installed yet, and a sink named after the one still walking off would be
-- dropped by `startFaintFx` the moment the swap landed.
function M:queueFaintFx(index)
  if index == nil then return false end
  if not self:usesBattlefield() then return false end
  local slot = self.slots[index]
  local occupant = slot and (slot.pending or slot) or nil
  self.lines[#self.lines + 1] = { faintfx = index, species = occupant and occupant.species }
  return true
end

function M:startFaintFx(row)
  local index = row and row.faintfx
  -- Drop Dig/Fly hide first so the sink is drawn; `fxSeat.hidden` would skip
  -- it, and a send batched behind the KO would inherit the empty seat.
  if index ~= nil then self:clearVanishAt(index) end
  local slot = self.slots[index]
  -- Somebody else is standing here now: the sink belongs to the monster that
  -- was recalled, and playing it would drop the newcomer through the floor
  -- under a "X fainted!" that never named them. Dropped, not deferred.
  if slot and row ~= nil and slot.species ~= row.species then return false end
  local fx = self:emitFx("faint", index)
  if not fx then return false end
  self.faintFx = fx
  return true
end

-- ------- the exp strip filling, which is the arena's third display clock
--
-- Same shape as the drain above and for the same reason: `Experience.apply`
-- runs the instant the `exp` event is received and moves `mon.exp` and
-- `mon.level` in one step, so the number the plate is drawn from has to be a
-- separate clock that trails it. `slot.shownExpFrac` is the strip's fill (0..1,
-- or nil for "no strip") and `slot.shownLevel` is the number the level pill
-- prints; the gap between those two and the save mon's own truth *is* the
-- animation, exactly as `shownHp` is for the bar.
--
-- Own seat only. The peer's plate is driven by the peer's own client off their
-- own save file -- there is no wire field for a fraction and there must not be
-- one -- so no other seat is ever seeded and no other seat draws a strip.
--
-- Classic 160×144 now draws the same clocks on the player HUD (a 1px bar).
-- A benched award still has nowhere to crawl. The text flow is unchanged --
-- the strip answers the "gained N EXP" line, it does not replace it.

-- Seed the two display clocks off the save monster's own truth.
--
-- Lazy rather than at build time, because a `slots` entry is built from a wire
-- event and the wire knows nothing about exp. Idempotent: it only ever fills a
-- nil, so a clock mid-fill is never yanked back to truth by a draw.
--
-- A seeded-nil `shownExpFrac` is not a failure to seed -- it is the honest
-- "this monster has no fraction to show" (no Growth module, no save mon, a
-- species this build cannot describe) -- and it is re-asked every call
-- precisely so a monster that gains one later picks it up.
function M:seedExpClock(slot, mon)
  if type(slot) ~= "table" then return false end
  mon = mon or self:saveMon()
  if type(mon) ~= "table" then return false end
  if slot.shownLevel == nil then
    slot.shownLevel = tonumber(mon.level) or tonumber(slot.level) or 1
  end
  if slot.shownExpFrac == nil then
    slot.shownExpFrac = expFraction(self.game, mon)
  end
  return true
end

-- A queued exp-fill row comes up. Answered on the spot (returning false) when
-- there is nothing to crawl, so the queue never stalls on one.
--
-- The row carries the *save* mon it was queued for as well as the seat, and
-- both are checked: the award belongs to that monster wherever it now is, and
-- the clocks belong to the seat, so a switch that landed between queue and
-- play means the strip on that plate is describing somebody else. Dropped in
-- that case, with the clocks cleared so the newcomer reseeds from its own
-- truth rather than inheriting a fraction that was never theirs.
--
-- **Both ends are read here, not at queue time, and each for its own reason.**
--
-- The *target* comes off the mon now because the mon is still being written to
-- after the row is queued: with an EXP.ALL held, `gainExp` runs a second
-- `Experience.apply` pass over the whole party -- and the fighter is in that
-- party, so a target frozen before that pass is short by whatever the second
-- half added. Reading it at row-start means every pass has landed, so the
-- strip and the pill agree with the "grew to level N!" lines beside them.
--
-- The *start* is the live display clock, because that is where the strip
-- visibly is. Two awards in one batch (both foes down in one 2-on-2 turn) both
-- capture their `from*` before either has played, so honouring the second
-- row's capture would drag the strip back down to where the first one started.
-- `row.from*` remains the fallback for a clock that is still nil -- the
-- capture `gainExp` takes before `Experience.apply` mutates the mon, which is
-- the one thing that genuinely cannot be worked back out later.
function M:startExpFill(row)
  local index = row and row.expfill
  local slot = self.slots[index]
  local mon = row and row.mon
  if not (type(slot) == "table" and type(mon) == "table") then return false end
  if row.species ~= nil and slot.species ~= row.species then
    slot.shownExpFrac = nil
    slot.shownLevel = nil
    return false
  end
  local function level(value, fallback)
    local got = tonumber(value)
    if not got or got ~= got then return fallback end
    return max(1, floor(got))
  end
  local function frac(value)
    local got = tonumber(value)
    -- NaN refused rather than clamped: `stepExpFill` stops on a comparison
    -- against a target, and a NaN target is a stop condition that never comes
    -- true -- the same rule `startDrain` applies to a wire `to`.
    if not got or got ~= got then return nil end
    return max(0, min(1, got))
  end
  local toLevel = level(mon.level, 1)
  local toFrac = frac(expFraction(self.game, mon)) or 0
  local from = frac(slot.shownExpFrac)
  if from == nil then from = frac(row.fromFrac) end
  -- No fraction to start from means this monster draws no strip at all, so
  -- there is nothing to fill. The pill is still put where the level is: it is
  -- printed from `shownLevel` and would otherwise sit a level behind forever.
  if from == nil then
    slot.shownLevel = toLevel
    return false
  end
  local fromLevel = min(level(slot.shownLevel, level(row.fromLevel, toLevel)),
    toLevel)
  slot.shownExpFrac = from
  slot.shownLevel = fromLevel
  -- Nothing crossed and nothing added (a rounding-sized gain, or an award that
  -- priced to zero): put the strip where it belongs and let the queue move on
  -- rather than holding it for a crawl nobody can see.
  if fromLevel == toLevel and toFrac <= from then
    slot.shownExpFrac = toFrac
    return false
  end
  -- The budget, and it is the same guarantee the drain's is: a fill is
  -- deliberately unskippable, so the only other end to a target it somehow
  -- cannot reach is a message queue that never moves again. One whole bar per
  -- level to cross plus two bars of slack, after which it is snapped home.
  self.expFilling = {
    slot = index,
    mon = mon,
    toLevel = toLevel,
    toFrac = toFrac,
    frames = EXP_FILL_FRAMES * (2 + (toLevel - fromLevel)),
  }
  return true
end

-- One frame of it -- or however many this update covers, the way `stepDrain`
-- counts them, so the headless suite can drive whole seconds at a time.
--
-- A level crossing is the cart's own (AnimateExpBar, engine/battle/core.asm):
-- the segment fills to full, the level the HUD prints ticks up, and the strip
-- restarts at empty -- which is why the pill changes as the bar tops out and
-- not a message later. Two levels in one award is that twice.
function M:stepExpFill(dt)
  local at = self.expFilling
  if not at then return end
  local slot = self.slots[at.slot]
  if not (type(slot) == "table" and type(at.mon) == "table") then
    self.expFilling = nil
    return
  end
  local frames = frameCount(dt)
  at.frames = (tonumber(at.frames) or 0) - frames
  if at.frames <= 0 then
    slot.shownExpFrac = at.toFrac
    slot.shownLevel = at.toLevel
    self.expFilling = nil
    return
  end
  local shownLevel = tonumber(slot.shownLevel) or at.toLevel
  -- Every level still to cross fills the whole strip; the last one stops
  -- wherever the award actually left the monster.
  local target = (shownLevel < at.toLevel) and 1 or at.toFrac
  local shown = min(target, (tonumber(slot.shownExpFrac) or 0)
    + EXP_FILL_STEP * frames)
  slot.shownExpFrac = shown
  if shown < target then return end
  if shownLevel < at.toLevel then
    slot.shownLevel = shownLevel + 1
    slot.shownExpFrac = 0
    return
  end
  self.expFilling = nil
end

-- Mid-battle evolution movie. Twin of CoopBattle's: timing and apply in
-- EvolveFx, queue hold and seat FX here. Local only -- the hub keeps the
-- uploaded pre-evo sheet for the rest of this fight.
function M:evolveSlot(mon)
  if not mon then return nil end
  for i = 1, #(self.mine or {}) do
    if self:saveMon(i) == mon then
      if i == (self.active or 1) then return self:mySlot() end
      return nil
    end
  end
  return nil
end

-- Front pic for a bench / EXP.ALL movie: no plate, so the arena (or the
-- classic stage) paints it in the middle of the field.
function M:evolveCenterFront()
  local movie = self.evolving
  if not (movie and movie.center) then return nil end
  local species = EvolveFx.picSpecies(movie)
  if type(species) == "number" then species = tostring(species) end
  if type(species) ~= "string" then return nil end
  local hit = EvolveFx.formCacheGet(movie, "front", species)
  if hit ~= nil then return hit or nil end
  local resolved = self:seatFront(species, movie.mon, nil, true)
  EvolveFx.formCachePut(movie, "front", species, resolved)
  return resolved
end

function M:evolveCenterCtx()
  local movie = self.evolving
  if not (movie and movie.center) then return nil end
  local front = self:evolveCenterFront()
  if not front then return nil end
  return { front = front, flash = EvolveFx.flashPulse(movie) }
end

function M:startEvolve(row)
  local movie = EvolveFx.begin(row)
  if not movie then return false end
  self.evolving = movie
  self.shown = EvolveFx.evolvingLine(movie)
  self.dwell = 0
  local eng = loadEngine()
  EvolveFx.playMusic(self.game, eng and eng.Music)
  local index = self:evolveSlot(movie.mon)
  movie.slot = index
  movie.center = index == nil
  if index then
    local slot = self.slots[index]
    movie.oldSprite = slot and slot.sprite or nil
    if slot then slot.icon = nil end
    if self:usesBattlefield() then
      self:emitFx("evolve", index, self:fxSideFor(index), 1,
        { duration = EvolveFx.MOVIE_SECONDS })
      self:emitVfx({ style = "sparkle", palette = "FAIRY", delivery = "burst" },
        index)
      self:emitVfx({ style = "shine", palette = "NORMAL", delivery = "burst" },
        index)
    end
  end
  return true
end

function M:stepEvolve(dt, input)
  local movie = self.evolving
  if type(movie) ~= "table" then
    self.evolving = nil
    return
  end
  local pressedB = input and input:wasPressed("b")
  EvolveFx.advance(movie, dt, pressedB)
  -- Classic path: refresh the slot pic when the flash wants the other form.
  if not self:usesBattlefield() and movie.slot then
    local want = EvolveFx.picSpecies(movie)
    if want ~= movie._shownPic then
      movie._shownPic = want
      local slot = self.slots[movie.slot]
      if slot then
        local saved = slot.speciesId
        slot.speciesId = want
        self:refreshSlotSprite(movie.slot, true)
        slot.speciesId = saved
      end
    end
  end
  if not movie.done then return end
  local snapMax, snapHp
  if movie.slot then
    local slot = self.slots[movie.slot]
    if type(slot) == "table" then
      snapMax = slot.maxHp
      snapHp = slot.hp
    end
  end
  self.evolving = nil
  local eng = loadEngine()
  local line
  if movie.canceled then
    EvolveFx.markResolved(self, movie.mon)
    if movie.slot then self:refreshSlotSprite(movie.slot, true) end
    line = EvolveFx.stoppedLine(movie)
  else
    local applied = EvolveFx.applyTo(self.game, movie, self)
    if applied then
      EvolveFx.markResolved(self, applied)
      self:refreshAfterEvolve(applied, snapMax, snapHp)
      EvolveFx.playCry(self.game, eng and eng.Sound, movie.into)
      for _, moveId in ipairs(EvolveFx.learnMoveIds(self.game, applied)) do
        self:teach(applied, movie.name, moveId)
      end
      line = EvolveFx.evolvedLine(movie, self.game)
    else
      line = EvolveFx.stoppedLine(movie)
      if movie.slot then self:refreshSlotSprite(movie.slot, true) end
    end
  end
  EvolveFx.restoreBattleMusic(self.game, self:battleMusicOpts(eng))
  self.shown = line
  self.dwell = 0
end

function M:refreshAfterEvolve(mon, snapMax, snapHp)
  if not mon then return end
  local data = self.game and self.game.data
  local def = data and data.pokemon and data.pokemon[mon.species]
  if self:generation() == 3 then
    -- The evolved species' name as the plate prints it (a nickname stays),
    -- and its number as the seat's id: a stand-in for the species record the
    -- two lines below read on Gen 1 / Gen 2.
    local sp = tonumber(mon.species or mon.speciesId)
    def = { name = Sheet3.displayName(mon, sp) }
  end
  local saveMax = tonumber(mon.stats and mon.stats.hp) or tonumber(mon.maxHp)
  if self:generation() == 3 then saveMax = tonumber(mon.maxHp) or saveMax end
  if saveMax and saveMax == saveMax and saveMax > 0 then
    saveMax = floor(saveMax)
    mon.maxHp = saveMax
  end
  for i = 1, #(self.mine or {}) do
    if self:saveMon(i) == mon then
      local sheet = self.mine[i]
      local oldMax = tonumber(snapMax)
        or (type(sheet) == "table" and tonumber(sheet.maxHp))
      local oldHp = tonumber(snapHp)
        or (type(sheet) == "table" and tonumber(sheet.hp))
      local grown, newMax, newHp = EvolveFx.hpGrowth(oldMax, saveMax, oldHp)
      if type(sheet) == "table" then
        sheet.speciesId = (self:generation() == 3) and tostring(mon.species) or mon.species
        if def and type(def.name) == "string" then
          sheet.species = def.name
        end
        sheet.level = mon.level
        if newMax then sheet.maxHp = newMax end
        if newHp then sheet.hp = newHp end
      end
      if i == (self.active or 1) then
        local index = self:mySlot()
        local slot = index and self.slots[index]
        if type(slot) == "table" then
          slot.speciesId = (self:generation() == 3) and tostring(mon.species) or mon.species
          if def and type(def.name) == "string" then
            slot.species = def.name
          end
          slot._bfFront = nil
          slot._bfFrontSpecies = nil
          slot.sprite = nil
          slot.icon = nil
          if grown > 0 then
            slot.maxHp = newMax
            if newHp then slot.hp = newHp end
            slot.levelHpGrown = (tonumber(slot.levelHpGrown) or 0) + grown
            if self:usesBattlefield() then
              self:queueDrain(index)
            else
              slot.shownHp = slot.hp
            end
          end
          self:refreshSlotSprite(index, true)
        end
      end
    end
  end
end

-- Is a bar still falling, or a monster still on its way down?
--
-- The fanfare waits on this (#36): a win announced while the loser's bar is
-- mid-drain plays the jingle over a monster that still looks alive. Asked of
-- the queue as well as of the live states, because the outcome message can
-- land while the rows that show the last KO are still stacked up.
-- A throw counts too, and for the same reason one step further on: a catch is
-- decided by the referee the moment the last shake lands, but the ball on the
-- arena is still wobbling. Without this the "Gotcha!" fanfare started over a
-- ball that had not settled -- the outcome message is queued behind the anim
-- rows and prints in order, but the jingle is not a line and had nothing
-- holding it. The rows are what is asked about (plus the one playing now), so
-- the hold ends with the last wobble rather than with the throw's result: a
-- caught monster stays in its ball and the fanfare still plays.
function M:hasPendingHpFx()
  -- `hitHold` counts for the same reason `draining` does, and is the beat
  -- immediately before it: the fanfare must not start in the gap between a
  -- strike landing and the bar that answers it. (The re-queued drain row in
  -- `lines` already answers true below; this says it directly, so the hold
  -- still holds if that row is ever dropped rather than re-queued.)
  -- A filling exp strip counts as well, live or still queued, and for the
  -- plainest reading of the same rule: the award is the last thing a knockout
  -- owes, so a jingle over a bar still crawling is a fight congratulating
  -- itself before it has finished paying out.
  if self.draining or self.faintFx or self.hitHold or self.expFilling
      or self.evolving then
    return true
  end
  -- A send-out counts for the same reason a throw does, and it is the same
  -- animation seen from the other end: the referee can call the fight the
  -- moment a replacement is fielded, and a jingle over a ball still in the air
  -- -- or over a burst the monster has not come out of yet -- congratulates a
  -- field that is not on screen yet. Both rows of the chain, queued or
  -- playing: they hold the queue, so they are owed.
  if type(self.anim) == "table"
      and (BALL_FX[self.anim.anim] or self.anim.sendball ~= nil
           or self.anim.spawnfx ~= nil) then
    return true
  end
  for _, row in ipairs(self.lines or {}) do
    if type(row) == "table" then
      if row.drain ~= nil or row.faintfx ~= nil or row.expfill ~= nil
          or row.evolve ~= nil then
        return true
      end
      if row.sendball ~= nil or row.spawnfx ~= nil then return true end
      if row.anim ~= nil and BALL_FX[row.anim] then return true end
    end
  end
  return false
end

-- Put the arena back where the referee says the field is, and stop animating.
--
-- CoopBattle's `snapDisplay`, and the same argument. Two of the arena's
-- effects deliberately outlive their own clock -- a sink that keeps a KO face
-- down, and a throw that keeps a monster inside its ball -- and the only thing
-- that ever ends either one is the row that was going to undo it. A chain that
-- never finishes (a hub drop between HIDEPIC and the burst that opens the ball
-- again) therefore left a seat invisible for the rest of the fight. This is
-- the way out: the flow goes first and the effects it justified go with it, so
-- nothing is left held by a hold that no longer exists.
--
-- Never called while the fight is over. The last frame of a finished battle is
-- part of the outcome -- a monster face down, a caught monster inside its ball
-- -- and snapping it would stand both of them back up under the ending line.
function M:snapDisplay()
  -- The replace phase goes too, and forwards like everything else here: this is
  -- "put the screen where the referee says the field is", and a seat whose
  -- arrival is being installed below is not a seat anybody is still choosing
  -- for. Left standing it would hold the band on "X is choosing who to send
  -- out..." over a monster already on the field, for the rest of a fight that
  -- was re-synced or ended mid-solicitation.
  self.replaceWait = nil
  self.ballFlow = nil
  self.fx = nil
  -- The last move's palette goes with the effects it coloured: the next thing
  -- to strike after a re-sync has no move behind it yet, and beat 3 would
  -- otherwise open in the colours of an attack from before the gap.
  self.moveVfx = nil
  self.animHold = nil
  self.hitHold = nil
  self.draining = nil
  self.faintFx = nil
  self.expFilling = nil
  -- A movie in flight is abandoned without applying: leveledUp stays so the
  -- after-battle fallback still offers. Unplayed evolve rows stay in `lines`.
  if self.evolving then
    local eng = loadEngine()
    EvolveFx.restoreBattleMusic(self.game, self:battleMusicOpts(eng))
    self.evolving = nil
  end
  -- The arrival window closes here too, and it closes *forwards*: this is
  -- "put the arena where the referee says the field is", and the referee says
  -- the newcomer is out. A parked arrival is therefore installed rather than
  -- dropped -- discarding it would leave the seat showing a monster the field
  -- no longer holds -- and any hold on an empty seat is released, so a battle
  -- that ends (or is re-synced) mid-window can never strand a seat invisible.
  -- Same shape as the ball flow above, for the same reason.
  self.spawnHide = nil
  for index, slot in pairs(self.slots or {}) do
    if type(slot) == "table" and slot.pending then
      local arrival = slot.pending
      slot.pending = nil
      slot.species = arrival.species
      slot.sprite = nil
      slot.icon = nil
      slot.koHold = nil
      slot.hp = arrival.hp or 0
      if arrival.maxHp ~= nil then slot.maxHp = max(1, arrival.maxHp) end
      if slot.hp > (slot.maxHp or 1) then slot.maxHp = slot.hp end
      slot.status = arrival.status
      slot.confused = arrival.confused
      -- No `arriveOnSeat` here: `exit` calls this on stubs that carry neither a
      -- game nor a party, and the pic is refreshed by the next draw anyway
      -- (`battlefieldSeat` resolves a nil sprite through `seatFront`). The
      -- clocks below are welded by the loop that follows.
      slot.shownExpFrac = nil
      slot.shownLevel = nil
      if index ~= nil then self:refreshSlotSprite(index, index == self:mySlot()) end
    end
  end
  -- And the two clocks back in step: a descent abandoned half way is a bar
  -- that would otherwise sit at a number nobody holds until the next drain.
  for _, slot in pairs(self.slots or {}) do
    if type(slot) == "table" then slot.shownHp = slot.hp or 0 end
  end
  -- The exp clocks are welded the same way, and only on the one seat that owns
  -- them: a battle that ends mid-fill would otherwise leave a strip frozen
  -- part-way and a pill a level behind the monster it names. Welding wider than
  -- the own seat would invent clocks on plates that read none. nil stays nil:
  -- a monster with no fraction still shows none. Classic 160×144 reads these
  -- clocks too (the player-HUD exp bar), so the weld is not theatre-gated.
  --
  -- Queued `expfill` rows are deliberately *not* dropped here (this screen
  -- drops no queued rows -- see the drain rows, which stay too): a row that
  -- comes up after a weld finds its target already reached and answers false
  -- without crawling, which is the same outcome one fewer branch.
  do
    -- `or {}` for the same reason the loop above has one: `exit` calls this on
    -- any object holding the screen's methods, and the suite's stubs do not
    -- carry a field table.
    local slot = (self.slots or {})[self:mySlot()]
    local mon = self:saveMon()
    if type(slot) == "table" and type(mon) == "table" then
      slot.shownExpFrac = expFraction(self.game, mon)
      slot.shownLevel = tonumber(mon.level) or slot.shownLevel
    end
  end
end

function M:update(dt)
  self.frame = (self.frame or 0) + 1
  -- No exp flush here.  A knockout's `exp` events can straddle two frames (a
  -- hub's packets land when they land), and paying the half that arrived
  -- first would price the knockout twice -- each half split over its own
  -- participants.  The referee always follows an exp run with another event
  -- (the next line, a `turn`, the outcome), and `onEvent` / `onOutcome` pay
  -- the batch the moment that arrives.
  self:pruneBattlefieldBubbles()
  self:stepFx(dt)
  -- Held fanfare: the outcome was known before the arena had finished showing
  -- the KO that produced it.
  if self.victoryMusicHeld and not self:hasPendingHpFx() then
    self.victoryMusicHeld = nil
    self:playVictoryMusic()
  end

  local input = self.game and self.game.input

  if self:tickMessages(dt, input) then return end

  if self.phase == "over" then
    -- The Pay Day line, owed since `onOutcome` paid the coins: after the
    -- whole ending -- ours and the caller's -- has printed (`payDay3`,
    -- `payDay12`).
    if self:sayPayDay3() then return end
    -- The catch's naming prompt, owed since `grantCatch` and asked now that
    -- the ending has finished printing -- the engine's own ordering, and the
    -- last thing between the player and the way out.
    if self:askOwedNickname() then return end
    if input and input:wasPressed("a") then self:leave() end
    return
  end

  if self.pendingTurn and not self.answeredTurn then
    if self.mustReplace then
      -- Outranks an open command menu: the seat has no active mon.
      self.pendingTurn = false
      self.replaceOnly = true
      self.switchIndex = 1
      self.phase = "switch"
      if self.autoPick then
        local rows = self:partyRows()
        for _, row in ipairs(rows) do
          if not row.fainted then
            self:sendChoice({ action = "switch", slot = self:wireSlotOf(row.index) })
            return
          end
        end
      end
    elseif self.phase ~= "choose" and self.phase ~= "move"
       and self.phase ~= "item" and self.phase ~= "item_party"
       and self.phase ~= "item_move" and self.phase ~= "switch"
       and self.phase ~= "target" and self.phase ~= "mimic" then
      self.pendingTurn = false
      self.replaceOnly = false
      self.phase = "choose"
      self.commandIndex = 1
      self.cursor = 1
      if self.autoPick then
        self:pickMove(1)
        return
      end
    end
  elseif self.pendingTurn and self.answeredTurn then
    self.pendingTurn = false
  end

  if not input then return end
  if self.phase == "choose" then return self:updateCommand(input) end
  if self.phase == "move" then return self:updateMoveMenu(input) end
  if self.phase == "target" then return self:updateTarget(input) end
  if self.phase == "mimic" then return self:updateMimic(input) end
  if self.phase == "item" then return self:updateItemMenu(input) end
  if self.phase == "item_party" then return self:updateItemParty(input) end
  if self.phase == "item_move" then return self:updateItemMove(input) end
  if self.phase == "switch" then return self:updateSwitch(input) end
end

-- Field cursor among living foe seats. 1v1 has a single target, so this is
-- mostly dormant; kept so a future multi-target mediated mode shares the API.
function M:updateTarget(input)
  local targets = self:battlefieldTargets()
  if #targets == 0 then
    self.phase = "move"
    return
  end
  if self.targetIndex > #targets then self.targetIndex = #targets end
  if input:wasPressed("left") or input:wasPressed("up") then
    self.targetIndex = Battlefield.nextTarget(targets, self.targetIndex, -1) or 1
  elseif input:wasPressed("right") or input:wasPressed("down") then
    self.targetIndex = Battlefield.nextTarget(targets, self.targetIndex, 1) or 1
  elseif input:wasPressed("b") then
    self.phase = "move"
  elseif input:wasPressed("a") then
    -- Mediated 1v1 still omits an explicit target on the wire (sim picks the
    -- first living foe); the cursor is presentation-only.
    self:pickMove(self.cursor)
  end
end

-- ------- drawing
--
-- Classic Gen1 1v1: foe front pic (top-right) + HUD (top-left); ally back pic
-- (bottom-left) + HUD (lower-right); message / menus in the bottom box.
-- Coordinates mirror BattleState:drawHUDs / drawPicsLayer.

local function nameX(Font, tx, name)
  local n = 8
  if Font and Font.split then
    local ok, parts = pcall(Font.split, name)
    if ok and type(parts) == "table" then n = #parts end
  else
    n = #tostring(name or "")
  end
  return tx * 8 + (n <= 2 and 16 or n <= 4 and 8 or 0)
end

function M:enemyPicXY(sprite)
  if not sprite then return CLASSIC_ENEMY.x, CLASSIC_ENEMY.y end
  local ok, w, h = pcall(sprite.getDimensions, sprite)
  if not ok then return CLASSIC_ENEMY.x, CLASSIC_ENEMY.y end
  local tw = floor(w / 8)
  local th = floor(h / 8)
  if tw < 1 then tw = 1 elseif tw > 7 then tw = 7 end
  if th < 1 then th = 1 elseif th > 7 then th = 7 end
  local hPad = floor((8 - tw) / 2)
  local vPad = 7 - th
  return 96 + 8 * hPad, 8 * vPad
end

function M:playerPicXY(sprite)
  local scale = playerPicScale(self.game)
  if not sprite then return CLASSIC_PLAYER.x, CLASSIC_PLAYER.y, scale end
  local ok, w, h = pcall(sprite.getDimensions, sprite)
  if not ok then return CLASSIC_PLAYER.x, CLASSIC_PLAYER.y, scale end
  -- Gen 2: feet in the 6x6 box at (16, 48) — same as BattleState.PLAYER_PIC_*.
  if Gen.generation(self.game) == 2 then
    return 16, 48 + (48 - h), scale
  end
  -- Gen 1: Same contract as BattleState.backPlacement: feet flush on y=96.
  local BS = engine and engine.BattleState
  if BS and BS.backPlacement then
    local x, y, s = BS.backPlacement(w, h, 0, 0, scale)
    return x, y, s
  end
  return 8, 96 - h * scale, scale
end

-- This screen resolves its own colours (same contract as CoopBattle / WideBattle).
--
-- Pics come out of BattleState.makeBattler already species-paletted, and the
-- HUD/boxes are the engine's own tiles. Without an opt-out, OG / OG INV /
-- CLASSIC invent a whole-screen GRAYS remap (PaletteFX.ensureZones) and treat
-- those coloured pixels as DMG shades -- pink paper, black outlines, solid
-- black HP bars. Game.lua reads sgbPalettes; zones() is the hook twin.
function M:sgbPalettes()
  return self:zones()
end

-- **The rect is in the RECEIVING generation's space, which is not the space
-- this screen draws in.**
--
-- Gen 1 zone rects live in the widened UI canvas' own coordinates, so an arena
-- fight states 640x360 and `Renderer:blitCanvas` scissors exactly the canvas.
-- Gold's are always 160x144 *screen* space whatever the state drew:
-- `Game2:blitZones` scales every rect by `w/160, h/144` before scissoring, so
-- a 640-wide rect there means 4x the window, not "the arena".
--
-- It happened to render correctly -- `blitZones` clamps with `math.min(..., w)`
-- and 4x the window clamps to the window -- but correct-by-clamp is not a
-- contract, and the size had a second, real cost: a non-empty zone list sets
-- `zoned` in `Game2:draw`, which pushes every frame onto the present-canvas
-- path (a render-target bind plus a full-screen blit) that a Gold frame with
-- no zones does not pay. The opt-out this list exists for (`colors = false`)
-- works at any size, so the honest rect is the one the receiver understands.
function M:zones()
  local w, h = 160, 144
  if self:usesBattlefield() and self:generation() ~= 2 then
    w, h = Battlefield.WIDTH, Battlefield.HEIGHT
  end
  return { { colors = false, x = 0, y = 0, w = w, h = h } }
end

function M:drawEvolveCenterClassic()
  local movie = self.evolving
  if not (movie and movie.center) or not love then return end
  local sprite = self:evolveCenterFront()
  if not sprite then return end
  local ok, iw, ih = pcall(sprite.getDimensions, sprite)
  iw = (ok and type(iw) == "number" and iw) or 56
  ih = (ok and type(ih) == "number" and ih) or 56
  local x = math.floor((160 - iw) / 2)
  local y = math.floor((96 - ih) / 2)
  love.graphics.setColor(1, 1, 1, 1)
  pcall(love.graphics.draw, sprite, x, y)
end

function M:drawFieldPics()
  local foe = self.slots[self:foeSlot()]
  local mine = self.slots[self:mySlot()]
  love.graphics.setColor(1, 1, 1, 1)
  -- Draw while the sprite is held -- including at 0 HP through the move flash
  -- and "X fainted!". `releasePic` (after that line) is what takes it down.
  if foe and foe.sprite and not self.foePicHidden
      and not self:seatVanished(self:foeSlot()) then
    local x, y = self:enemyPicXY(foe.sprite)
    pcall(love.graphics.draw, foe.sprite, x, y)
  end
  if mine and mine.sprite and not self:seatVanished(self:mySlot()) then
    -- Move / item menus replace the lower pic rows on the GB tilemap.
    local clipMenus = self.phase == "move" or self.phase == "mimic" or self.phase == "item"
      or self.phase == "item_party" or self.phase == "item_move"
      or self.phase == "switch" or self.phase == "choose"
    local scx, scy, scw, sch
    if clipMenus and love.graphics.getScissor then
      scx, scy, scw, sch = love.graphics.getScissor()
      ClassicBattle.setPageScissor(0, 0, 160, 96)
    end
    local x, y, scale = self:playerPicXY(mine.sprite)
    scale = scale or playerPicScale(self.game)
    pcall(love.graphics.draw, mine.sprite, x, y, 0, scale, scale)
    if clipMenus and love.graphics.setScissor then
      if scx then love.graphics.setScissor(scx, scy, scw, sch)
      else love.graphics.setScissor() end
    end
  end
end

function M:drawRemainingBalls()
  if not ClassicBattle.wantsFoeBalls(self.mode) then return end
  local eng = loadEngine()
  local BS = eng and eng.BattleState
  local team = self.teams and self.teams[self:foeSlot()]
  local party = ClassicBattle.partyFromRoster(team)
  if not party then
    party = ClassicBattle.partyFromRoster(self.npcParty)
  end
  if not party then return end
  if love and love.graphics then love.graphics.setColor(1, 1, 1, 1) end
  ClassicBattle.drawBallRow(BS, party,
    ClassicBattle.FOE_BALL_X, ClassicBattle.FOE_BALL_Y, ClassicBattle.FOE_BALL_DX)
end

function M:drawEnemyHUD(Font, HudTiles)
  local slot = self.slots[self:foeSlot()]
  -- Keep chrome up at 0 HP while the pic is still held (same rule as the
  -- player HUD): classic clears after the faint line, not on the damage tick.
  if not (slot and slot.species) then return end
  if (slot.hp or 0) <= 0 and not slot.sprite and not slot.koHold then return end
  local name = tostring(slot.species):sub(1, 10)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(name, nameX(Font, 1, name), 0)
  -- Classic Gen 1 / engine BattleState: status replaces Lxx. Group battles
  -- put status on the HP bar instead (CoopBattle.drawReadout).
  if slot.status then
    -- A Red / Gold TOX is the PSN the cart's HUD prints (ClassicBattle.statusLabel).
    Font.draw(ClassicBattle.statusLabel(tostring(slot.status)) or "", 40, 8)
  elseif slot.confused then
    Font.draw("CNF", 40, 8)
  elseif slot.level then
    if HudTiles and HudTiles.tile then
      pcall(HudTiles.tile, 0x6E, 32, 8) -- <LV>
    end
    Font.draw(tostring(slot.level), 40, 8)
  end
  if HudTiles and HudTiles.tile then
    pcall(HudTiles.tile, 0x73, 8, 16)
    pcall(HudTiles.tile, 0x74, 8, 24)
    for i = 2, 9 do pcall(HudTiles.tile, 0x76, i * 8, 24) end
    pcall(HudTiles.tile, 0x78, 80, 24)
  end
  local shownHp = self:shownHpOf(slot)
  local shown = { hp = shownHp, stats = { hp = slot.maxHp or 1 } }
  local drew = HudTiles and pcall(HudTiles.drawHPBar, self.game and self.game.data,
    2, 2, shown, nil, false)
  if not drew then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%d/%d"):format(shownHp, slot.maxHp or 0), 16, 16)
  end
end

function M:drawPlayerHUD(Font, HudTiles)
  local slot = self.slots[self:mySlot()]
  if not (slot and slot.species) then return end
  -- Keep the chrome up at 0 HP until the faint line finishes (classic clears
  -- after the slide); still draw name/bar at 0 so the KO is visible.
  local name = tostring(slot.species):sub(1, 10)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(name, nameX(Font, 10, name), 56)
  if slot.status then
    Font.draw(ClassicBattle.statusLabel(tostring(slot.status)) or "", 120, 64)
  elseif slot.confused then
    Font.draw("CNF", 120, 64)
  else
    local level = slot.shownLevel or slot.level
      or (self.mine and self.mine[self.active] and self.mine[self.active].level)
    if level then
      if HudTiles and HudTiles.tile then
        pcall(HudTiles.tile, 0x6E, 112, 64)
      end
      Font.draw(tostring(level), 120, 64)
    end
  end
  local shownHp = self:shownHpOf(slot)
  local shown = { hp = shownHp, stats = { hp = slot.maxHp or 1 } }
  local drew = HudTiles and pcall(HudTiles.drawHPBar, self.game and self.game.data,
    10, 9, shown, 1, false)
  if not drew then
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%d/%d"):format(shownHp, slot.maxHp or 0), 88, 72)
  else
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(("%3d/%3d"):format(shownHp, slot.maxHp or 0), 88, 80)
  end
  if HudTiles and HudTiles.tile then
    pcall(HudTiles.tile, 0x73, 144, 80)
    pcall(HudTiles.tile, 0x77, 144, 88)
    for i = 10, 17 do pcall(HudTiles.tile, 0x76, i * 8, 88) end
    pcall(HudTiles.tile, 0x6F, 72, 88)
  end
  -- Gen 2-style EXP track on the player underline. Seeded lazily so a
  -- headless award that never drew still has a clock for the suite.
  if slot.shownExpFrac == nil then
    self:seedExpClock(slot, self:saveMon())
  end
  if slot.shownExpFrac ~= nil then
    pcall(ClassicBattle.drawExpBar, slot.shownExpFrac,
      ClassicBattle.hpBarFillX(10), 90, ClassicBattle.HP_BAR_PX)
  end
end

function M:drawAnim()
  local row = self.anim
  if not (row and self.animPlayer and self.animPlayer.draw) then return end
  pcall(self.animPlayer.draw, self.animPlayer)
end

function M:drawBox(Font, text, opts)
  opts = opts or {}
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local y = 112
  local row = 0
  for _, line in ipairs(ClassicBattle.wrapBoxLines(text, ClassicBattle.BOX_COLS)) do
    Font.draw(line, 8, y)
    y = y + 16
    row = row + 1
    if row >= ClassicBattle.BOX_ROWS then break end
  end
  -- Hold lines pass `{ hint = false }` so a page caret cannot look like
  -- "press A" while the player is waiting on the other seat. Other boxes
  -- keep today's no-caret default; only an explicit hint draws ▼.
  if opts.hint then
    pcall(Font.drawCode, Font, 0xEE, 144, 144)
  end
end

function M:drawList(Font, rows, cursor)
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local shown = min(#rows, 3)
  local first = 1
  if cursor > 3 then first = cursor - 2 end
  for i = 0, shown - 1 do
    local row = rows[first + i]
    if row then
      local label = type(row) == "table" and (row.label or row.name or row.id) or tostring(row)
      Font.draw(tostring(label):sub(1, 16), 16, 112 + i * 16)
    end
  end
  Font.drawCode(0xED, 8, 112 + (cursor - first) * 16)
end

function M:drawCommands(Font)
  -- Full-width 2x2. SWITCH shows as the two-tile PKMN mark so it does not
  -- overlap FIGHT (same columns as CoopBattle).
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  for i, command in ipairs(M.COMMANDS) do
    local row = math.floor((i - 1) / 2)
    local col = (i - 1) % 2
    local x = col == 0 and 24 or 112
    local y = 112 + row * 16
    if command == "SWITCH" then
      Font.drawCode(0xE1, x, y)
      Font.drawCode(0xE2, x + 8, y)
    else
      Font.draw(command, x, y)
    end
  end
  local i = self.commandIndex or 1
  local row = math.floor((i - 1) / 2)
  local col = (i - 1) % 2
  Font.drawCode(0xED, col == 0 and 16 or 104, 112 + row * 16)
end

function M:drawMoves(Font)
  local mon = self:activeMon()
  if self.phase == "item_move" then
    mon = (self.mine or {})[self.itemPartyIndex or self.active]
  end
  local moves = (mon and mon.moves) or {}
  -- Vanilla RBY pane: every known move on the left, TYPE/ + PP of the
  -- cursor on the right. `drawList` was names-only and capped at three.
  Font.drawBox(0, 12, 13, 6)
  Font.drawBox(12, 12, 8, 6)
  if Font.BORDER then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 96, 96, 8, 8)
    Font.drawCode(Font.BORDER.h, 96, 96)
  end
  love.graphics.setColor(0, 0, 0, 1)
  local index = self.cursor or 1
  if index < 1 then index = 1 end
  if #moves > 0 and index > #moves then index = #moves end
  local nameX, nameW = ClassicBattle.MOVE_NAME_X, ClassicBattle.MOVE_NAME_MAX_W
  for i, move in ipairs(moves) do
    if i > 4 then break end
    local label = self:moveLabel(move.id) or tostring(move.id or "-")
    ClassicBattle.drawFittedText(Font, label, nameX, ClassicBattle.MOVE_NAME_Y(i), nameW)
  end
  if #moves > 0 then
    Font.drawCode(0xED, 8, ClassicBattle.MOVE_NAME_Y(index))
  end
  local pick = moves[index]
  if not pick then return end
  local typeName = self:moveTypeName(pick.id)
  if typeName then
    Font.draw("TYPE/", 104, ClassicBattle.MOVE_TYPE_LABEL_Y)
    Font.draw(tostring(typeName):sub(1, 6), 104, ClassicBattle.MOVE_TYPE_NAME_Y)
  end
  local pp = tonumber(pick.pp)
  local maxPp = tonumber(pick.maxPp)
  if not maxPp then
    local movesData = self.game and self.game.data and self.game.data.moves
    local def = type(movesData) == "table" and movesData[pick.id] or nil
    if def then
      -- The cart's GetMaxPP: a fifth of the base per PP Up, capped at 7.
      maxPp = M.maxPpOf(def.pp or 0, pick.ppUps)
    end
  end
  if pp and maxPp then
    Font.draw(("%2d/%2d"):format(pp, maxPp), 104, ClassicBattle.MOVE_PP_Y)
  elseif pp then
    Font.draw(("PP %2d"):format(pp), 104, ClassicBattle.MOVE_PP_Y)
  end
end

-- ------- the modern band (battlefield path only)
--
-- The same phases the GB chrome below draws, drawn instead as Battlefield's
-- panel widgets. Draw-only: every row source and every cursor is the one the
-- input handlers already read, so what a press does is untouched -- a list
-- drawn from a different set than `updateSwitch` filters would pick the mon
-- above the one the player is looking at.
--
-- Classic 160x144 and Gen2 never reach here; `drawSafe` sends them to the GB
-- path, which is byte-identical to what it always was.

-- The commands, with SWITCH under the name the player knows it by. The order
-- and the index are `M.COMMANDS`' own -- `updateCommand` steps that grid.
function M:bandCommandItems()
  local items = {}
  if self:generation() == 3 then
    for i, command in ipairs(COMMANDS3) do
      items[i] = { label = COMMAND_LABEL3[command] or command }
    end
    return items
  end
  for i, command in ipairs(M.COMMANDS) do
    items[i] = { label = (command == "SWITCH") and "PKMN" or command }
  end
  return items
end

function M:bandMoveRows()
  local mon = self:activeMon()
  if self.phase == "item_move" then
    mon = (self.mine or {})[self.itemPartyIndex or self.active]
  end
  local rows = {}
  for _, move in ipairs((mon and mon.moves) or {}) do
    -- `pp` / `maxPp` are what a sheet carries (`moveOf`); a referee-published
    -- list after Transform/Mimic carries `pp` and may carry no maximum, so the
    -- right column is dropped rather than invented.
    local row = { label = self:moveLabel(move.id) or tostring(move.id) }
    -- The type, in the column left of PP. Same reason PP is on the row rather
    -- than under it: what the player is comparing four ways is on the four
    -- rows, not on a strip that only ever describes the highlighted one.
    row.tag = self:moveTypeName(move.id)
    local pp = tonumber(move.pp)
    local maxPp = tonumber(move.maxPp)
    if pp and maxPp then
      row.right = ("%d/%d"):format(pp, maxPp)
    elseif pp then
      row.right = tostring(floor(pp))
    end
    if pp and pp <= 0 then row.dim = true end
    rows[#rows + 1] = row
  end
  return rows
end

-- The same battle FRONT pic the arena draws, for a party monster that is not
-- on the field -- what the POKeMON panel shows beside its rows.
--
-- The SAVE mon is the source, not the uploaded sheet: `Wire.battleMon` carries
-- no shiny flag (see `seatFront`), and the save copy is the only one that
-- knows. It falls back to the sheet when the save slot will not resolve, so a
-- party the save no longer matches still shows a monster rather than a hole.
--
-- Cached on the screen and keyed by species + shiny. `seatFront`'s own cache
-- lives on a field slot and holds one species at a time, which is right for a
-- seat and wrong here -- a six-monster party walk would evict it on every row.
--
-- Gen 3 keys by the monster rather than the species: its pic is a function of
-- the personality and the OT (shiny is personality xor OT id, Spinda's spots
-- and Unown's letter are the personality), none of which is a `shiny` flag,
-- so two SPINDA -- or a shiny and a plain one -- would share whichever pic
-- was drawn first.
function M:partyFront(index, sheet)
  local mon = self:saveMon(index)
  if type(mon) ~= "table" then mon = sheet end
  if type(mon) ~= "table" then return nil end
  local species = mon.species
  -- A Gen 3 save mon's species is its number.
  if type(species) == "number" then species = tostring(species) end
  if type(species) ~= "string" or species == "" then return nil end
  local key = species .. (mon.shiny and "*" or "")
  if self:generation() == 3 then
    key = ("%s:%s:%s"):format(species, tostring(tonumber(mon.personality) or ""),
      tostring(tonumber(mon.otId) or ""))
  end
  local cache = self._bfPartyFronts
  if not cache then
    cache = {}
    self._bfPartyFronts = cache
  end
  local hit = cache[key]
  if hit == nil then
    -- No slot: nothing here belongs to a field seat, so nothing may write
    -- into a seat's cache either.
    hit = self:seatFront(species, mon, nil, true) or false
    cache[key] = hit
  end
  return hit or nil
end

function M:bandPartyRows(all)
  local rows = {}
  for _, row in ipairs(self:partyRows()) do
    -- SWITCH shows what it will let you pick; the item menu shows the whole
    -- party (a Revive wants the fainted one). Both match their handler.
    if all or (not row.fainted and (self.replaceOnly or not row.active)) then
      local mon = (self.mine or {})[row.index]
      local entry = {
        label = row.label,
        dim = row.fainted or nil,
        front = self:partyFront(row.index, mon),
      }
      local hp = mon and tonumber(mon.shownHp)
      if hp == nil then hp = mon and tonumber(mon.hp) end
      local maxHp = mon and tonumber(mon.maxHp)
      if row.active then
        local slot = self.slots and self.slots[self:mySlot()]
        if type(slot) == "table"
           and (tonumber(slot.shownHp) ~= nil or tonumber(slot.hp) ~= nil) then
          hp = self:shownHpOf(slot)
          maxHp = tonumber(slot.maxHp) or maxHp
        end
      end
      if hp ~= nil and maxHp then
        entry.right = ("%d/%d"):format(hp, maxHp)
      end
      rows[#rows + 1] = entry
    end
  end
  return rows
end

-- A widget's verdict. The band widgets report `false` when they could not
-- draw; an older Battlefield returns nothing at all, and that has always meant
-- "drawn" -- so only an explicit `false` sends the frame to the GB chrome.
local function bandDrew(ok)
  return ok ~= false
end

function M:drawModernBand()
  local message = Battlefield.drawMessagePanel
  local grid = Battlefield.drawCommandGrid
  local list = Battlefield.drawListPanel
  -- An arena without the band widgets (an older Battlefield) still gets the
  -- GB chrome rather than an empty band. Nothing to remediate, and nothing to
  -- warn about either -- the second return says so, and the caller falls back
  -- quietly.
  if type(message) ~= "function" or type(grid) ~= "function"
     or type(list) ~= "function" then
    return false, "unavailable"
  end
  if type(Battlefield.drawBandBackdrop) == "function" then
    -- Once, here, and never inside a widget: two scrims would double-darken
    -- the band. Without it the panels float on grass with no ground of their
    -- own, which is what the arena art runs edge to edge into.
    Battlefield.drawBandBackdrop()
  end

  -- From here every branch reports what the widget reported: a widget that
  -- could not draw leaves the band empty over a live fight, and the GB chrome
  -- is a worse-looking menu rather than no menu at all.
  if self.shown then
    return bandDrew(message(tostring(self.shown)))
  end
  if self.anim then
    return bandDrew(message(""))
  end
  if self.phase == "choose" then
    return bandDrew(grid(self:bandCommandItems(), self.commandIndex or 1))
  end
  if self.phase == "move" or self.phase == "item_move" then
    return bandDrew(list(self:bandMoveRows(), self.cursor, { title = "MOVES" }))
  end
  if self.phase == "mimic" then
    return bandDrew(list(self:mimicRows(), self.mimicIndex or 1, { title = "MIMIC" }))
  end
  if self.phase == "target" then
    local rows = {}
    for _, seat in ipairs(self:battlefieldTargets()) do
      local entry = { label = tostring(seat.name or "?") }
      if tonumber(seat.maxHp) then
        entry.right = ("%d/%d"):format(seat.shownHp or seat.hp or 0, seat.maxHp)
      end
      if (seat.hp or 0) <= 0 then entry.dim = true end
      rows[#rows + 1] = entry
    end
    return bandDrew(list(rows, self.targetIndex or 1, { title = "TARGET" }))
  end
  if self.phase == "item" then
    local rows = {}
    for _, item in ipairs(self:usableItems()) do
      rows[#rows + 1] = {
        label = tostring(item.name or item.id),
        right = item.count and ("x%d"):format(item.count) or nil,
      }
    end
    return bandDrew(list(rows, self.itemIndex or 1, { title = "ITEMS" }))
  end
  if self.phase == "item_party" then
    return bandDrew(list(self:bandPartyRows(true), self.switchIndex or 1,
      { title = "POKeMON" }))
  end
  if self.phase == "switch" then
    return bandDrew(list(self:bandPartyRows(false), self.switchIndex or 1,
      { title = "POKeMON" }))
  end
  if self.phase == "setup" then
    return bandDrew(message("Getting ready..."))
  end
  if self.phase == "over" then
    return bandDrew(message(self.shown or ""))
  end
  return bandDrew(message(self:holdLine(), { hint = false }))
end

-- What the band says when there is no menu and no queued line: which of the two
-- waits this is.
--
-- "Waiting for X..." is a turn they have not answered yet. A seat still owed a
-- send-out is a different thing and reads as one -- the field is a monster
-- short, and the player is owed the reason it has stopped rather than a line
-- that sounds like an ordinary slow opponent. Our own solicitation never
-- reaches here: that one is a picker.
function M:holdLine()
  if self.replaceWait ~= nil and self.replaceWait ~= self:mySlot() then
    return ("%s is choosing\nwho to send out..."):format(self.peerName)
  end
  return ("Waiting for\n%s..."):format(self.peerName)
end

function M:drawBattlefieldMenus(Font)
  local ok, drew, why = pcall(self.drawModernBand, self)
  if ok and drew then return end
  if not Font then return end
  -- The band failing is a visible downgrade in the middle of a fight, and the
  -- GB chrome hides it well enough that nobody would report it -- so it is
  -- said once, with what went wrong. `why == "unavailable"` is the one
  -- expected way down here (an arena with no band widgets at all), and is not
  -- worth a line.
  if not self.bandWarned and not (ok and why == "unavailable") then
    self.bandWarned = true
    mod.log:warn("the battle band could not draw (%s); this fight falls back "
      .. "to the classic menu chrome inside the band and stays playable -- "
      .. "report this with the message above so the arena widgets can be fixed",
      ok and "a band widget reported failure" or tostring(drew))
  end

  local function chrome()
    if self.shown then
      return self:drawBox(Font, self.shown)
    end
    if self.anim then
      return self:drawBox(Font, "")
    end
    if self.phase == "choose" then
      return self:drawCommands(Font)
    end
    if self.phase == "move" or self.phase == "item_move" then
      return self:drawMoves(Font)
    end
    if self.phase == "mimic" then
      return self:drawMimicPick(Font)
    end
    if self.phase == "target" then
      local targets = self:battlefieldTargets()
      local rows = {}
      for _, seat in ipairs(targets) do
        rows[#rows + 1] = tostring(seat.name or "?")
      end
      return self:drawList(Font, rows, self.targetIndex or 1)
    end
    if self.phase == "item" then
      return self:drawList(Font, self:usableItems(), self.itemIndex or 1)
    end
    if self.phase == "item_party" then
      local rows = {}
      for _, row in ipairs(self:partyRows()) do
        rows[#rows + 1] = row.label .. (row.fainted and " *" or "")
      end
      return self:drawList(Font, rows, self.switchIndex or 1)
    end
    if self.phase == "switch" then
      local rows = {}
      for _, row in ipairs(self:partyRows()) do
        if not row.fainted and (self.replaceOnly or not row.active) then
          rows[#rows + 1] = row.label
        end
      end
      return self:drawList(Font, rows, self.switchIndex or 1)
    end
    if self.phase == "setup" then
      return self:drawBox(Font, "Getting ready...")
    end
    if self.phase == "over" then
      return self:drawBox(Font, self.shown or "")
    end
    self:drawBox(Font, self:holdLine(), { hint = false })
  end
  self:withMenuBand(chrome)
end

function M:drawBattlefieldSafe()
  self:ensureBattlefield()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, Battlefield.WIDTH, Battlefield.HEIGHT)

  local eng = loadEngine()
  local engBag = {
    Font = eng and eng.Font,
    Sprites = eng and eng.Sprites,
    -- `Gen.spriteCatalog`, not `data.sprites`: Gold keeps its walk sheets on
    -- `data.gen2Sprites`, and handing the renderer Gen 1's table on a Gold boot
    -- is why the arena's trainers were invisible there.
    sprites = Gen.spriteCatalog(self.game),
    game = self.game,
  }
  do
    local ok, SR = pcall(require, "src.render.SpriteRenderer")
    if ok then engBag.SpriteRenderer = SR end
  end
  pcall(Battlefield.draw, self, self:battlefieldCtx(), engBag)

  -- Gen 3 has no Game Boy font to fall back on; the band widgets carry their
  -- own, and a band that cannot draw simply stays empty.
  if eng and eng.gen3 then
    self:drawBattlefieldMenus(nil)
    return
  end
  if not (eng and eng.Font) then return end
  self:drawBattlefieldMenus(eng.Font)
end

-- ------- how the arena reaches the screen, per generation
--
-- **The two games hand a screen its surface through different seams, and this
-- is the whole of what round 7 had to find out.**
--
-- Gen 1 asks the state: `uiSize()` widens the render surface to 640x360 and
-- `wantsFillScale()` scales it to the window aspect-preserved
-- (`src/core/Game.lua:471` -> `Renderer:setUISize` / `Renderer.uiFill`). The
-- state then draws in canvas units and the engine does the rest.
--
-- **Gold has neither.** `src/core/Game2.lua` never calls `setUISize`, and
-- `src/ui/gen2/Chrome.lua:fitScale` hardcodes the 160x144 panel grid -- so a
-- 640x360 arena drawn the Gen 1 way lands in a 160-wide surface and the window
-- shows the arena's top-left corner at 6x. (That is exactly what it did: see
-- the first Gold run of `run-battlefield-e2e-gen2.sh`.)
--
-- What Gold has instead is `drawsWidescreen()` / `drawWidescreen(w, h)`: a
-- state that opts in paints the **whole window, in window units**, and its GB
-- panel blits on the integer grid over that (`Game2:drawScene`, the `wide`
-- branch). It is the same seam Gold's own battle screen uses
-- (`src/ui/gen2/BattleState.lua:3133`), which is why this is a public state
-- contract rather than an `engine_internals` reach-around: the arena is a
-- widescreen layer on Gold in exactly the sense the engine already means.
--
-- So the theatre is identical and the *delivery* differs by one function. The
-- fill-scale transform below is Renderer's `uiFill` arithmetic
-- (`Up = min(ph/uih, pw/uiw)`, centred) reproduced in window space, so a Gold
-- arena and a Red arena are the same picture at the same aspect -- which is
-- also what lets one screenshot driver assert both.
-- The boot's generation, resolved once per screen.
--
-- `Gen.generation` allocates a closure for each of the two `pcall`s it makes,
-- and `drawsWidescreen` is asked every frame by `Game2:drawScene` (and again
-- by `drawSafe`). A fight cannot change cart mid-battle, so the answer is
-- memoised on the instance -- `false` is never a valid answer, so a plain
-- `if not` re-resolve is safe and there is no separate "asked yet" flag.
function M:generation()
  local cached = self._generation
  if cached then return cached end
  local ok, gen = pcall(Gen.generation, self.game)
  gen = (ok and tonumber(gen)) or 1
  self._generation = gen
  return gen
end

-- Gen 3 takes the same window-space path: its render.hud pass
-- (Gen3Ui.drawWidescreen) paints a pushed state that says yes here edge to
-- edge and the game3 layers above it at the game rect.  CLASSIC BATTLE UI says
-- no and draws its 240x160 page into the game3 canvas instead.
function M:drawsWidescreen()
  local gen = self:generation()
  if gen ~= 2 and gen ~= 3 then return false end
  return self:usesBattlefield()
end

function M:drawWidescreen(winW, winH)
  local G = love.graphics
  winW = tonumber(winW) or 0
  winH = tonumber(winH) or 0
  if winW <= 0 or winH <= 0 then return end

  -- **Also called with the arena OFF.** Gold asks an `isOpaque` screen whose
  -- `drawsWidescreen()` said no for its SURROUND (`Game2:drawScene`'s
  -- cleartilemap safety net), then blits the 160x144 page over it. Painting
  -- the arena here put the whole theatre around and under the classic stage.
  -- A classic page takes Gold's own paper white, the void it paints for a
  -- page with no surround of its own.
  if not self:usesBattlefield() then
    G.setColor(1, 1, 1, 1)
    G.rectangle("fill", 0, 0, winW, winH)
    return
  end

  -- The void around the arena. Black rather than Gold's paper white: the
  -- arena is its own dark chrome (the same vote `refreshLetterbox` withdraws
  -- on the battlefield path), and a white surround around a night field reads
  -- as a rendering fault rather than a border.
  G.setColor(0, 0, 0, 1)
  G.rectangle("fill", 0, 0, winW, winH)

  local up = math.min(winH / Battlefield.HEIGHT, winW / Battlefield.WIDTH)
  if not (up > 0) then return end
  local ox = math.floor((winW - Battlefield.WIDTH * up) / 2)
  local oy = math.floor((winH - Battlefield.HEIGHT * up) / 2)

  G.push()
  G.translate(ox, oy)
  G.scale(up, up)
  -- Guarded so the pop always runs: a leaked transform would drag whatever
  -- Game2 blits next (a text box pushed over the fight) off its own grid.
  local ok, err = pcall(self.drawBattlefieldSafe, self)
  G.pop()
  G.setColor(1, 1, 1, 1)

  if not ok and not self.drawFailed then
    self.drawFailed = true
    mod.log:error("the mediated battle arena failed to draw on this "
      .. "generation (%s); the fight is still running and can be finished "
      .. "blind, but report this", tostring(err))
  end
end

function M:drawSafe()
  -- Already painted, edge to edge, by `drawWidescreen`. Drawing again here
  -- would put a second 160x144 copy of the arena on the panel grid on any
  -- frame Game2 also blits the stack -- which it does the moment anything is
  -- pushed over the fight.
  if self:drawsWidescreen() then return end
  -- Gen 3 without the arena: the 240x160 GBA page.
  if self:generation() == 3 then return self:drawGen3Classic() end
  if self:usesBattlefield() then
    return self:drawBattlefieldSafe()
  end

  -- Fill first so a missing Font still covers the frame; without isOpaque the
  -- stack would otherwise leave the overworld visible at the top of the view.
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)

  local eng = loadEngine()
  if not (eng and eng.Font) then return end
  local Font = eng.Font
  local HudTiles = eng.HudTiles

  -- Full-page party picker covers the stage; faint/anim lines still use
  -- the field + bottom box so a send-out is not painted over a KO.
  if not self.shown and not self.anim
      and (self.phase == "switch" or self.phase == "item_party") then
    if self:drawClassicPartyPicker(Font, HudTiles) then return end
  end

  self:drawFieldPics()
  -- Gold's sky (`weatherOfLine2`) over the field and under the HUDs, by the
  -- arena's own painter at the page's scale -- the Gen 3 page's reading
  -- (ClassicBattle's `BF.drawWeather` over its field).
  if self.weatherShown and self:generation() == 2 then
    pcall(Battlefield.drawWeather, self.weatherShown, 0, 0, 160, 96,
      self.frame or 0, 0.4)
  end

  self:drawEvolveCenterClassic()
  self:drawEnemyHUD(Font, HudTiles)
  self:drawPlayerHUD(Font, HudTiles)
  self:drawRemainingBalls()
  self:drawAnim()

  if self.shown then
    return self:drawBox(Font, self.shown)
  end
  if self.anim then
    return self:drawBox(Font, "")
  end
  if self.phase == "choose" then
    return self:drawCommands(Font)
  end
  if self.phase == "move" or self.phase == "item_move" then
    return self:drawMoves(Font)
  end
  if self.phase == "mimic" then
    return self:drawMimicPick(Font)
  end
  if self.phase == "item" then
    return self:drawList(Font, self:usableItems(), self.itemIndex or 1)
  end
  if self.phase == "item_party" then
    local rows = {}
    for _, row in ipairs(self:partyRows()) do
      rows[#rows + 1] = row.label .. (row.fainted and " *" or "")
    end
    return self:drawList(Font, rows, self.switchIndex or 1)
  end
  if self.phase == "switch" then
    local rows = {}
    for _, row in ipairs(self:partyRows()) do
      if not row.fainted and (self.replaceOnly or not row.active) then
        rows[#rows + 1] = row.label
      end
    end
    return self:drawList(Font, rows, self.switchIndex or 1)
  end
  if self.phase == "setup" then
    return self:drawBox(Font, "Getting ready...")
  end
  self:drawBox(Font, self:holdLine(), { hint = false })
end

-- ------- the Gen 3 page (CLASSIC BATTLE UI, or no arena)
--
-- What this screen hands a GBA-shaped renderer: the two seats as the plates
-- show them (display clocks, not the referee's truth), whatever the box says
-- or which menu is open, and the field's state -- the `view` of
-- `ClassicBattle.drawGen3(view, state)` (the cart-chrome layout, see its
-- contract in src/ClassicBattle.lua), which draws it when the cart's battle
-- chrome is reachable; `drawGen3Plain` below is the plain 240x160 page
-- otherwise (a headless load, a cache without the chrome).
function M:gen3SeatModel(index, isPlayer)
  local slot = self.slots[index]
  if not (slot and slot.species) then return nil end
  if (slot.hp or 0) <= 0 and not slot.sprite and not slot.koHold
     and (slot.shownHp or 0) <= 0 then
    return nil
  end
  if slot.sprite == nil then self:refreshSlotSprite(index, isPlayer) end
  local sprite = slot.sprite or nil
  local movie = self.evolving
  if isPlayer and movie and movie.slot == index then
    sprite = slot.sprite or nil
  end
  local hidden = self:seatVanished(index) or (not isPlayer and self.foePicHidden)
    or (self.ballFlow and self.ballFlow.index == index and self.ballFlow.hidden) or false
  local key = self:seatSpeciesKey(slot, isPlayer)
  local seat = {
    name = slot.species,
    level = (isPlayer and slot.shownLevel) or slot.level or 1,
    hp = self:shownHpOf(slot),
    maxHp = slot.maxHp or 1,
    status = slot.status,
    confused = slot.confused or nil,
    sprite = sprite,
    -- Looked for and missing: the page must not go looking again every frame.
    noPic = (sprite == nil and slot.sprite == false) or nil,
    hidden = hidden and true or false,
    substitute = slot.substitute or nil,
    speciesId = key or slot.speciesId,
    form = slot.form,
    elevation = (not isPlayer) and self:seatElevation(key) or nil,
  }
  if isPlayer then
    if slot.shownExpFrac == nil then self:seedExpClock(slot, self:saveMon()) end
    seat.expFrac = slot.shownExpFrac
    local own = self:saveMon(self.active)
    if own and tonumber(own.species) == tonumber(key) then
      seat.mon = own
      seat.gender = own.gender
    end
  else
    -- The owned-ball marker a wild foe's box carries on the cart: this
    -- player's dex already has its species caught.
    if self.mode == "wild" then seat.caught = self:wildDexCaught() end
    local sheet = type(self.wildParty) == "table" and self.wildParty[1] or nil
    if sheet and sheet.speciesId == key then seat.gender = sheet.gender end
  end
  if seat.gender ~= "M" and seat.gender ~= "F" then seat.gender = nil end
  return seat
end

function M:gen3ClassicModel()
  local phase = self.phase
  local model = {
    foe = self:gen3SeatModel(self:foeSlot(), false),
    ally = self:gen3SeatModel(self:mySlot(), true),
    phase = phase,
    mode = self.mode,
    frame = self.frame,
    weather = self.weatherShown,
    message = self.shown or (self.anim and "" or nil),
    -- ▼ under a line the player is being asked to read.
    hint = self.shown ~= nil,
    -- The foe's remaining party for the ball row (the referee's roster).
    foeParty = self.teams and self.teams[self:foeSlot()] or nil,
  }
  local player = Gen3.player()
  model.playerBack = { gender = player and player.gender or 0 }
  if TRAINER_MODES[self.mode] and type(self.trainer) == "table" then
    local pic = tonumber(self.trainer.trainerPic or self.trainer.pic or self.trainer.picId)
    if pic then model.trainer = { pic = pic } end
  end
  local active = self.mine and self.mine[self.active]
  model.prompt = ("What will\n%s do?"):format(tostring(active and active.species or "?"))
  if phase == "choose" then
    local items = {}
    for i, entry in ipairs(self:bandCommandItems()) do items[i] = entry.label end
    model.commands, model.commandIndex = items, self.commandIndex or 1
  elseif phase == "move" or phase == "item_move" then
    local mon = (phase == "item_move") and (self.mine or {})[self.itemPartyIndex or self.active]
      or self:activeMon()
    local rows = {}
    for _, move in ipairs((mon and mon.moves) or {}) do
      rows[#rows + 1] = {
        label = self:moveLabel(move.id) or tostring(move.id),
        -- The pret type number (the renderer names it in the cart's words);
        -- a row without one falls back to the name off our sheets.
        type = tonumber(move.type) or self:moveTypeName(move.id),
        pp = tonumber(move.pp), maxPp = tonumber(move.maxPp),
      }
    end
    model.moves, model.cursor = rows, self.cursor or 1
  elseif phase == "item" then
    local rows = {}
    for _, item in ipairs(self:usableItems()) do
      rows[#rows + 1] = { label = tostring(item.name or item.id), right = "x" .. tostring(item.count or 0) }
    end
    model.list = { title = "BAG", rows = rows, cursor = self.itemIndex or 1 }
  elseif phase == "item_party" or phase == "switch" then
    model.list = { title = "POKéMON", rows = self:gen3PartyRows(phase == "item_party"),
                   cursor = self.switchIndex or 1 }
  elseif phase == "target" then
    local rows = {}
    for _, seat in ipairs(self:battlefieldTargets()) do rows[#rows + 1] = { label = tostring(seat.name or "?") } end
    model.list = { title = "TARGET", rows = rows, cursor = self.targetIndex or 1 }
  end
  if model.message == nil and not (model.commands or model.moves or model.list) then
    if phase == "setup" then
      model.message = "Getting ready..."
    elseif phase == "over" then
      model.message = ""
    else
      model.message, model.hold = self:holdLine(), true
    end
  end
  local movie = self.evolving
  if movie and movie.center then
    model.evolveFront = self:evolveCenterFront()
    model.evolveFlash = EvolveFx.flashPulse(movie)
  end
  return model
end

-- The POKeMON page's rows: the same set and order `updateSwitch` /
-- `updateItemParty` index into, with what the cart's party page shows for
-- each (front pic, icon, level, HP, condition).
function M:gen3PartyRows(all)
  local rows = {}
  for _, row in ipairs(self:partyRows()) do
    if all or (not row.fainted and (self.replaceOnly or not row.active)) then
      local sheet = (self.mine or {})[row.index]
      local save = self:saveMon(row.index)
      local key = sheet and sheet.speciesId
      local hp, maxHp = sheet and tonumber(sheet.hp), sheet and tonumber(sheet.maxHp)
      if row.active then
        local slot = self.slots and self.slots[self:mySlot()]
        if type(slot) == "table" and (tonumber(slot.shownHp) ~= nil or tonumber(slot.hp) ~= nil) then
          hp, maxHp = self:shownHpOf(slot), tonumber(slot.maxHp) or maxHp
        end
      end
      rows[#rows + 1] = {
        label = row.label,
        dim = row.fainted or nil,
        front = self:partyFront(row.index, sheet),
        icon = key and self:seatIcon(key, save) or nil,
        level = sheet and sheet.level,
        hp = hp, maxHp = maxHp,
        status = sheet and sheet.status,
        right = (hp and maxHp) and ("%d/%d"):format(hp, maxHp) or nil,
      }
    end
  end
  return rows
end

function M:drawGen3Classic()
  local model = self:gen3ClassicModel()
  if type(ClassicBattle.drawGen3) == "function" then
    local ok, drew = pcall(ClassicBattle.drawGen3, model, self)
    if ok and drew ~= false then return end
  end
  return self:drawGen3Plain(model)
end

local GEN3_W, GEN3_H = 240, 160

local function hpColor(frac)
  if frac > 0.5 then return 0.25, 0.85, 0.35 end
  if frac > 0.2 then return 0.95, 0.80, 0.15 end
  return 0.95, 0.30, 0.25
end

-- One plate: name, level (or condition), the HP bar, and on our own the
-- numbers and the exp strip.
local function drawGen3Plate(g, Font, seat, x, y, w, own)
  g.setColor(0.97, 0.97, 0.90, 1)
  g.rectangle("fill", x, y, w, own and 38 or 28)
  g.setColor(0.25, 0.30, 0.30, 1)
  g.rectangle("line", x + 0.5, y + 0.5, w - 1, (own and 38 or 28) - 1)
  Font.draw(Font.fit(tostring(seat.name or "?"), w - 44), x + 5, y + 1)
  local tag = seat.status or (seat.confused and "CNF") or ("Lv" .. tostring(seat.level or 1))
  Font.drawRight(tag, x + w - 5, y + 1)
  local maxHp = math.max(1, tonumber(seat.maxHp) or 1)
  local hp = math.max(0, math.min(maxHp, tonumber(seat.hp) or 0))
  local frac = hp / maxHp
  local bx, by, bw = x + w - 5 - 64, y + 18, 64
  g.setColor(0.2, 0.2, 0.2, 1)
  g.rectangle("fill", bx - 1, by - 1, bw + 2, 5)
  g.setColor(hpColor(frac))
  g.rectangle("fill", bx, by, math.floor(bw * frac + 0.5), 3)
  if own then
    Font.drawRight(("%d/%d"):format(hp, maxHp), x + w - 5, y + 21)
    local exp = tonumber(seat.expFrac)
    if exp then
      g.setColor(0.2, 0.2, 0.2, 1)
      g.rectangle("fill", x + 4, y + 34, w - 8, 3)
      g.setColor(0.30, 0.55, 0.95, 1)
      g.rectangle("fill", x + 5, y + 35, math.floor((w - 10) * math.max(0, math.min(1, exp)) + 0.5), 1)
    end
  end
  g.setColor(1, 1, 1, 1)
end

local function drawGen3Pic(g, seat, cx, bottom, flip)
  if not (seat and seat.sprite) or seat.hidden then return end
  local ok, w, h = pcall(seat.sprite.getDimensions, seat.sprite)
  if not ok then return end
  g.setColor(1, 1, 1, 1)
  pcall(g.draw, seat.sprite, math.floor(cx - w / 2), bottom - h)
end

function M:drawGen3Plain(model)
  local g = love and love.graphics
  if not g then return end
  local Font = Gen3Ui.Font
  -- The field: a sky over a ground line, the two platforms, the weather tint.
  g.setColor(0.86, 0.93, 0.99, 1)
  g.rectangle("fill", 0, 0, GEN3_W, 112)
  g.setColor(0.72, 0.86, 0.58, 1)
  g.rectangle("fill", 0, 64, GEN3_W, 48)
  if g.ellipse then
    g.setColor(0.60, 0.76, 0.46, 1)
    g.ellipse("fill", 176, 70, 44, 9)
    g.ellipse("fill", 72, 108, 52, 10)
  end
  local tint = ({ RAIN = { 0.3, 0.4, 0.8, 0.18 }, SUN = { 1.0, 0.8, 0.3, 0.18 },
                  SAND = { 0.8, 0.65, 0.35, 0.22 }, HAIL = { 0.85, 0.9, 1.0, 0.25 } })[model.weather or ""]
  if tint then
    g.setColor(tint[1], tint[2], tint[3], tint[4])
    g.rectangle("fill", 0, 0, GEN3_W, 112)
  end
  g.setColor(1, 1, 1, 1)
  drawGen3Pic(g, model.foe, 176, 72)
  drawGen3Pic(g, model.ally, 72, 112)
  if model.evolveFront then
    local ok, w, h = pcall(model.evolveFront.getDimensions, model.evolveFront)
    if ok then
      g.setColor(1, 1, 1, 1)
      pcall(g.draw, model.evolveFront, math.floor((GEN3_W - w) / 2), math.floor((112 - h) / 2))
    end
  end
  local flash = tonumber(model.evolveFlash) or 0
  if flash > 0 then
    g.setColor(1, 1, 1, math.min(1, flash))
    g.rectangle("fill", 0, 0, GEN3_W, 112)
  end
  if model.foe then drawGen3Plate(g, Font, model.foe, 8, 8, 110, false) end
  if model.ally then drawGen3Plate(g, Font, model.ally, 124, 70, 110, true) end

  -- The bottom: the message box, or a menu.
  if model.list then
    local list = model.list
    Gen3Ui.frame(2, 2, 26, 11)
    Font.draw(list.title or "", 16, 16, { color = "BLUE" })
    local rows, cursor = list.rows or {}, math.max(1, list.cursor or 1)
    local first = math.max(1, math.min(cursor - 2, #rows - 4))
    for i = 0, 4 do
      local row = rows[first + i]
      if row then
        local y = 32 + i * 14
        Font.draw(Font.fit(tostring(row.label or "?"), 150), 24, y,
          { color = row.dim and "MUTED" or nil })
        if row.right then Font.drawRight(tostring(row.right), 220, y) end
        if first + i == cursor then Gen3Ui.cursor(14, y) end
      end
    end
    Gen3Ui.dialogueFrame()
    Font.draw("A: choose  B: back", 16, 121)
    return
  end
  if model.moves then
    Gen3Ui.frame(2, 15, 17, 4)
    local cursor = math.max(1, model.cursor or 1)
    for i, row in ipairs(model.moves) do
      local col, line = (i - 1) % 2, math.floor((i - 1) / 2)
      local x, y = 24 + col * 72, 121 + line * 16
      Font.draw(Font.fit(row.label or "-", 62), x, y)
      if i == cursor then Gen3Ui.cursor(x - 9, y) end
    end
    Gen3Ui.frame(21, 15, 7, 4)
    local pick = model.moves[cursor]
    if pick then
      if pick.pp and pick.maxPp then
        Font.draw(("PP %d/%d"):format(pick.pp, pick.maxPp), 172, 121)
      end
      local typeName = tonumber(pick.type) and Gen3.typeName(pick.type) or pick.type
      Font.draw("TYPE/" .. Font.fit(tostring(typeName or "?"), 26), 172, 137)
    end
    return
  end
  if model.commands then
    Gen3Ui.frame(2, 15, 12, 4)
    local l1, l2 = tostring(model.prompt or ""):match("^([^\n]*)\n?(.*)$")
    Font.draw(l1 or "", 16, 121, { color = "WHITE" })
    Font.draw(l2 or "", 16, 137, { color = "WHITE" })
    Gen3Ui.frame(16, 15, 12, 4)
    for i, label in ipairs(model.commands) do
      local col, line = (i - 1) % 2, math.floor((i - 1) / 2)
      local x, y = 136 + col * 50, 121 + line * 16
      Font.draw(label, x, y)
      if i == (model.commandIndex or 1) then Gen3Ui.cursor(x - 9, y) end
    end
    return
  end
  Gen3Ui.dialogueFrame()
  local text = tostring(model.message or "")
  local lines = Font.wrap(text:gsub("\n", " "), 208)
  for i = 1, math.min(2, #lines) do
    Font.draw(lines[i], 16, 121 + (i - 1) * 16, { color = model.hold and "MUTED" or nil })
  end
end

function M:draw()
  local ok, err = pcall(self.drawSafe, self)
  if ok then return end
  if self.drawFailed then return end
  self.drawFailed = true
  mod.log:error("the mediated battle screen failed to draw (%s); the fight is "
    .. "still running and can be finished blind, but report this", tostring(err))
end

return M
