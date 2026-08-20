-- The 2-on-2 battle screen: four monsters on one field.
--
-- `CoopSim` is the rules; this is the screen. It is a plain state object of the
-- shape `src/core/StateStack.lua` expects -- enter, exit, update, draw,
-- isOpaque -- pushed through the mod's own `screens` registry, which is why
-- the mod can own a whole battle without touching `game.stack` directly.
--
-- ------- why host-authoritative, and not four-way lockstep
--
-- The engine's `LinkBattle` is lockstep: two peers run the same simulation off
-- one shared seed and exchange only choices. That works at two because both
-- ends draw from the same RNG stream in the same order, and the tie-break is
-- inverted on one side so the two agree.
--
-- At four it stops being cheap. Every client would have to consume the same
-- draws in the same order across four action resolutions, four faints and four
-- send-outs, and any one of them lagging a message would desync the field
-- rather than one battler. So one client simulates and the other three replay
-- the **events** it produces. The cost is honest -- the host decides, and a
-- modified host could decide wrongly -- and it is the same trust the engine's
-- own host-authoritative branch already takes for `action`/`event` in a link
-- battle, one player wider.
--
-- The upshot for this file: for **hub-refereed** coop modes (always the three
-- in Config.MEDIATED_COOP — `coop_pvp` / `coop_npc` / `coop_wild`), the
-- intermediator decides and this screen draws an ordered `mmo.battle_event`
-- stream — same as MediatedBattle. `CoopSim` is still constructed to hold the
-- field the screen is drawn from, and is not asked to *decide* anything. See
-- "the intermediator, when there is one" near the bottom.
--
-- ------- what this covers
--
-- All four battle commands, and the whole move-effect surface.
--
-- FIGHT resolves through `src/CoopField.lua`, which is a BattleState-shaped
-- object over the four slots -- so the move that runs is the engine's own
-- `performMove` and every `move_effects` record behind it. Charge moves charge,
-- Substitute absorbs, Hyper Beam recharges, Metronome calls, multi-hit hits,
-- recoil recoils, stat stages move. None of that is reimplemented here; see
-- CoopField's header for why it did not have to be.
--
-- ITEM goes through the engine's own `ItemEffects.use`, so a potion heals what
-- a potion heals and an item that refuses mid-battle refuses in the engine's
-- words. SWITCH costs the turn, as it does in the original.
--
-- A thrown ball is **refused** against a trainer (`coop_npc` / host-sim), and
-- that is the complete behaviour rather than a missing one: every monster on
-- the far side belongs to somebody, and Gen 1 does not let you catch somebody
-- else's. It is refused in the original's own words, taken from the game's
-- text table. Against **`coop_wild`** the far side is wildlife, so balls are
-- legal — the referee resolves them (speed-ordered among ball choices).
--
-- RUN is three questions wearing one label, and they are answered separately.
-- Against an **NPC trainer** it is the original's question and keeps the
-- original's refusal, word for word. Against **two other players** it is a
-- question Gen 1 never had to ask -- and the answer is yes, with the consent of
-- the partner who shares the loss. Against a **partied wild** (`coop_wild`) it
-- is solo-wild semantics: either player flees unilaterally, no consent ask.
-- See "RUN, in a battle where the other side is people" below for the PvP half.

local need, mod = ...
local Config = need("Config")
local Wire = need("Wire")
local Gen = need("Gen")
local CoopSim = need("CoopSim")
local CoopField = need("CoopField")
local Battlefield = need("Battlefield")
-- The Gen 2 half of the award. See `src/Exp2.lua`'s header: Gold has no
-- `src/battle/Experience.lua` twin, so a mediated Gen 2 faint is priced through
-- the engine's own `src/battle/gen2/Mon` primitives instead.
local Exp2 = need("Exp2")
-- The 1v1 mediated client, for its snapshots and its senders rather than for
-- its screen: what a party looks like on the wire must not depend on how many
-- monsters are on the field.
local Mediated = need("MediatedBattle")

local M = {}
M.__index = M

-- ------- the engine, loaded once and never at file scope
--
-- Lazily, and behind pcall, for the reason src/Sessions.lua loads the link
-- stack lazily: a player who never fights a co-op battle should not drag the
-- battle renderer in, and `modkit validate` -- which loads this file headlessly
-- with no love and no data -- must not meet a require that throws.
--
-- **Gen 2:** Gen1 `BattleState` / `Damage` are not required. Hub-mediated co-op
-- (Config.MEDIATED_COOP) is refereed by BattleSim2 on a Gen 2 hub; this screen
-- only holds slots and replays `mmo.battle_event`. The Gen1 host-sim CoopField
-- path is refused on Gen 2 rather than hard-failing the whole load (MK403).
local engine, engineTried, gen2HostSimWarned

local function loadEngine(game)
  if engineTried then return engine end
  engineTried = true
  local parts = {}
  local function grab(key, path)
    local good, value = pcall(require, path)
    if good then
      parts[key] = value
      return true
    end
    return false
  end
  -- Soft-grab everything. Gen 1 `M.new` still requires the host-sim set;
  -- Gen 2 only needs Protocol (+ Font for drawing) for mediated replay.
  grab("BattleState", "src.battle.BattleState")
  grab("Damage", "src.battle.Damage")
  grab("TurnOrder", "src.battle.TurnOrder")
  grab("Status", "src.battle.Status")
  grab("TypeChart", "src.battle.TypeChart")
  grab("Font", "src.render.Font")
  grab("HudTiles", "src.render.HudTiles")
  grab("Protocol", "src.link.Protocol")
  -- The real trainer AI: the Gen 1 move layers, and the per-class item and
  -- switch behaviour a strongest-move heuristic has no idea about.
  grab("TrainerAI", "src.battle.TrainerAI")
  -- The theatre: the battle theme, the victory theme, and the map music to go
  -- back to afterwards.
  grab("Music", "src.core.Music")
  -- The move-effect pipeline and the item table. These are what turn a co-op
  -- battle from a damage calculator into a battle on the Gen1 host-sim path.
  grab("EffectRegistry", "src.battle.EffectRegistry")
  grab("ItemEffects", "src.inventory.ItemEffects")
  grab("Experience", "src.battle.Experience")
  -- The curves behind the exp strip on the ally plates. Soft-grabbed beside
  -- Experience because it is a *display* dependency: a build without it still
  -- awards exp and still levels, the plate simply draws no strip (see
  -- `expFraction`).
  grab("Growth", "src.pokemon.Growth")
  grab("Pokemon", "src.pokemon.Pokemon")
  grab("Stats", "src.pokemon.Stats")
  -- Optional: a build with no battle_anims still fights, it just does not
  -- flash. Grabbed like the rest so a missing one is one warning, not a crash
  -- in the middle of somebody's turn.
  grab("AnimPlayer", "src.battle.AnimPlayer")
  -- Soft: party icons + OW walk sheets for the Gen1 Battlefield theatre.
  grab("Sprites", "src.pokemon.Sprites")
  grab("SpriteRenderer", "src.render.SpriteRenderer")

  local generation = Gen.generation(game)
  if not parts.Protocol then
    mod.log:error("the engine's link modules are unavailable, so 2-on-2 "
      .. "battles cannot open; everything else about co-op still works -- "
      .. "report this with the game version")
    engine = false
    return engine
  end
  -- Completeness for Gen1 host-sim is enforced in M.new, not here: the first
  -- loadEngine call may happen without a game (generation defaults to 1) on a
  -- Gen 2 boot, and must not cache a hard failure over missing BattleState.
  if generation == 2 and not (parts.BattleState and parts.Damage)
      and not gen2HostSimWarned then
    gen2HostSimWarned = true
    mod.log:warn("Gen 2 co-op uses hub-mediated BattleSim2 (no Gen1 "
      .. "BattleState/Damage host-sim); connect to a Gen 2 hub so mediated "
      .. "coop_pvp / coop_npc / coop_wild can be refereed -- local CoopField "
      .. "resolve is disabled on this boot")
  end
  -- Optional SFX (Ball_Poof, entrance cries). Missing Sound must not fail the
  -- whole load — headless / no-audio builds still fight without it.
  do
    local good, value = pcall(require, "src.core.Sound")
    if good then parts.Sound = value end
  end
  engine = parts
  return engine
end

M.loadEngine = loadEngine


-- ------- how far along its level a monster is
--
-- The Gen 2 HUD's own `HpBar.expFraction` (engine src/battle/gen2/HpBar.lua),
-- ported over Gen 1's spellings: the exp a mon carries is `mon.exp` here
-- (Gen 2 calls it `experience`), and the curve comes off the species def's
-- `growthRate` through `Growth.expForLevel` -- the same call
-- `Experience.apply` levels by, so the strip and the level can never disagree
-- about where a level ends.
--
-- **nil is a real answer and means "draw no strip".** No species def, no
-- Growth module, no `mon.exp`: three states where any number this could return
-- would be invented, and an invented exp bar on somebody's plate is worse than
-- no bar at all. Battlefield's `plateModel` treats a nil `expFrac` as the
-- no-data state for exactly this. Everything is pcall-guarded because it runs
-- inside the draw path.
-- `game` rather than `data`, since round 7, for the reason MediatedBattle's
-- twin gives: a Gen 2 monster's progress is `mon.experience` against Gold's own
-- curve, and reading Gen 1's `Growth.expForLevel` off `mon.exp` answers nil on
-- every Gold boot -- a plate that silently never drew its strip. Callers with
-- only a dataset pass `{ data = data }`.
local function expFraction(game, mon)
  local data = game and game.data
  if type(data) ~= "table" or type(mon) ~= "table" then return nil end
  if Gen.generation(game) == 2 then
    local okFrac, frac2 = pcall(Exp2.fraction, game, mon)
    if okFrac then return frac2 end
    return nil
  end
  if mon.exp == nil then return nil end
  local eng = engine
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


-- ------- packing a party for the wire
--
-- Through the engine's own pack/unpack, and -- this is the part that matters --
-- **both** sides go through it, exactly as LinkBattle does. A mon that has been
-- packed and rebuilt has had its stats recomputed from real species data, so
-- every client is looking at the same numbers; using the live save on the local
-- side and a rebuilt copy on the remote one would give the host slightly
-- different stats from everyone else's replay.
--
-- Gen 2 uses packMon2 / unpackMon2 (held item, SpA/SpD shape); Gen 1 keeps
-- Protocol.packParty / unpackMon.
function M.packParty(party, game)
  local eng = loadEngine(game)
  if not (eng and eng.Protocol) then return nil end
  if Gen.generation(game) == 2 and type(eng.Protocol.packMon2) == "function" then
    local out = {}
    for _, mon in ipairs(party or {}) do
      local ok, packed = pcall(eng.Protocol.packMon2, mon)
      if not (ok and packed) then return nil end
      out[#out + 1] = packed
    end
    if #out == 0 then return nil end
    return out
  end
  local ok, packed = pcall(eng.Protocol.packParty, party)
  return ok and packed or nil
end

function M.unpackParty(game, packed)
  local eng = loadEngine(game)
  if not (eng and eng.Protocol) then return nil end
  local out = {}
  local unpack = eng.Protocol.unpackMon
  if Gen.generation(game) == 2 and type(eng.Protocol.unpackMon2) == "function" then
    unpack = eng.Protocol.unpackMon2
  end
  for _, entry in ipairs(packed or {}) do
    local ok, mon = pcall(unpack, game.data, entry, {})
    if not (ok and mon) then return nil end
    out[#out + 1] = mon
  end
  if #out == 0 then return nil end
  return out
end

-- An NPC trainer's party, built the way the engine builds one.
--
-- `data.trainers[class].parties[index]` is a list of *specs* -- species and
-- level, sometimes moves -- not monsters. BattleState.newTrainer turns them
-- into real mons with the fixed trainer DVs and recomputed stats, and this
-- does the same thing for the same reason: a spec handed to the field would
-- have no stats to fight with.
--
-- Fixed DVs and the same stat recompute, so a co-op battle against a trainer
-- meets exactly the monsters a solo battle against them would.
function M.trainerParty(game, oppClass, partyIndex)
  local eng = loadEngine(game)
  if not (eng and eng.Pokemon and eng.Stats) then return nil end
  local record = (game.data.trainers or {})[oppClass]
  local specs = record and record.parties and record.parties[partyIndex or 1]
  if not (specs and #specs > 0) then return nil end

  local dvs = (game.data.constants and game.data.constants.trainerDvs)
    or { attack = 9, defense = 8, speed = 8, special = 8 }

  local out = {}
  for _, spec in ipairs(specs) do
    local ok, mon = pcall(eng.Pokemon.new, game.data, spec.species, spec.level)
    if not (ok and mon) then return nil end
    mon.dvs = dvs
    local statsOk, stats = pcall(eng.Stats.calc,
      game.data.pokemon[spec.species], spec.level, dvs)
    if statsOk and stats then
      mon.stats = stats
      mon.hp = stats.hp
    end
    if spec.moves then
      mon.moves = {}
      for _, moveId in ipairs(spec.moves) do
        local def = game.data.moves[moveId]
        mon.moves[#mon.moves + 1] = { id = moveId, pp = def and def.pp or 0 }
      end
    end
    out[#out + 1] = mon
  end
  return out
end

-- Map a battleMon / caught-sheet species token to a pokedex registry id.
-- Sheets narrate under Wire.name(display); Pokemon.new needs the registry key.
-- Prefer speciesId when present (upload-time snapshots); else the species
-- field as an id; else a display-name scan — same idea as MediatedBattle's
-- speciesKeyFor, without needing a live party.
local function speciesKeyFromSheet(game, sheet)
  if type(sheet) ~= "table" then return nil end
  local data = game and game.data
  local pokedex = data and data.pokemon
  if type(pokedex) ~= "table" then return nil end
  local id = sheet.speciesId
  if type(id) == "string" and id ~= "" and pokedex[id] then return id end
  local label = sheet.species
  if type(label) ~= "string" or label == "" then return nil end
  if pokedex[label] then return label end
  for key, def in pairs(pokedex) do
    if type(def) == "table" then
      local name = Wire.name(def.name or key)
      if name == label then return key end
    end
  end
  return nil
end

-- Rebuild a depositable engine mon from a catch-outcome battleMon sheet.
-- Used when this client never held the encounter (joiner / partner catcher):
-- wildCatchMon is nil, but the outcome still carries Effects.caughtSheet.
-- Best-effort: DVs/EVs from ivs/evs when present, else combat stats from the
-- sheet; moves and current HP always prefer the sheet. Returns nil when the
-- species cannot be resolved or Pokemon.new fails.
function M.monFromCaughtSheet(game, sheet)
  if type(sheet) ~= "table" then return nil end
  local eng = loadEngine(game)
  if not (eng and eng.Pokemon and eng.Stats) then return nil end
  local species = speciesKeyFromSheet(game, sheet)
  if not species then return nil end
  local level = tonumber(sheet.level) or 1
  if level < 1 then level = 1 end
  local ok, mon = pcall(eng.Pokemon.new, game.data, species, level)
  if not (ok and mon) then return nil end

  local wireToEngine = { atk = "attack", def = "defense", spd = "speed", spc = "special" }

  if type(sheet.ivs) == "table" then
    local dvs = {}
    for wireKey, engineKey in pairs(wireToEngine) do
      local n = tonumber(sheet.ivs[wireKey])
      if not n then dvs = nil break end
      dvs[engineKey] = math.max(0, math.min(15, math.floor(n)))
    end
    if dvs then
      dvs.hp = (dvs.attack % 2) * 8 + (dvs.defense % 2) * 4
        + (dvs.speed % 2) * 2 + (dvs.special % 2)
      mon.dvs = dvs
    end
  end

  if type(sheet.evs) == "table" then
    local statExp = mon.statExp or {
      hp = 0, attack = 0, defense = 0, speed = 0, special = 0,
    }
    for wireKey, engineKey in pairs(wireToEngine) do
      local n = tonumber(sheet.evs[wireKey])
      if n then
        statExp[engineKey] = math.max(0, math.min(65535, math.floor(n)))
      end
    end
    if sheet.evs.hp ~= nil then
      local n = tonumber(sheet.evs.hp)
      if n then statExp.hp = math.max(0, math.min(65535, math.floor(n))) end
    end
    mon.statExp = statExp
  end

  if mon.dvs then
    local def = game.data.pokemon[species]
    local statsOk, stats = pcall(eng.Stats.calc, def, level, mon.dvs, mon.statExp)
    if statsOk and stats then mon.stats = stats end
  elseif type(sheet.stats) == "table" then
    mon.stats = mon.stats or {}
    for wireKey, engineKey in pairs(wireToEngine) do
      local n = tonumber(sheet.stats[wireKey])
      if n then mon.stats[engineKey] = math.max(1, math.floor(n)) end
    end
    local maxHp = tonumber(sheet.maxHp)
    if maxHp then mon.stats.hp = math.max(1, math.floor(maxHp)) end
  elseif sheet.maxHp ~= nil then
    mon.stats = mon.stats or {}
    local maxHp = tonumber(sheet.maxHp)
    if maxHp then mon.stats.hp = math.max(1, math.floor(maxHp)) end
  end

  if type(sheet.moves) == "table" and #sheet.moves > 0 then
    local moves = {}
    for _, slot in ipairs(sheet.moves) do
      if type(slot) == "table" and type(slot.id) == "string" and slot.id ~= "" then
        local mdef = game.data.moves and game.data.moves[slot.id]
        local pp = tonumber(slot.pp)
        if not pp then pp = mdef and mdef.pp or 0 end
        moves[#moves + 1] = { id = slot.id, pp = math.max(0, math.floor(pp)) }
      end
    end
    if #moves > 0 then mon.moves = moves end
  end

  local hp = tonumber(sheet.hp)
  if hp then
    local maxHp = (mon.stats and mon.stats.hp) or tonumber(sheet.maxHp) or 1
    mon.hp = math.max(0, math.min(math.floor(hp), maxHp))
  end

  if sheet.catchRate ~= nil then
    local rate = tonumber(sheet.catchRate)
    if rate then mon.catchRate = math.max(0, math.min(255, math.floor(rate))) end
  end
  if sheet.status ~= nil then mon.status = sheet.status end

  return mon
end

-- ------- the way in
--
-- **The entry veil: this screen fades up out of black, and that is a
-- transition the mod draws itself rather than one it borrows.**
--
-- A vanilla encounter never cuts to the battle screen. `OverworldState:
-- pushBattle` (Gen 1) and `World:startBattle` (Gen 2) both push a
-- BattleTransition *first*, and only when the wipe has finished blacking the
-- overworld out does the battle come up on top of the black it left behind. So
-- a fight arriving without one reads as a dropped frame.
--
-- One of the two clients in a co-op battle gets that for free and one does not.
-- The **waiter** walked into the encounter, so the engine already ran its wipe
-- for them and their engine battle is on screen (that is what the wait now
-- stands behind -- src/Coop.lua's beginWait). The **joiner** is pulled in from
-- the overworld by a message: nothing on their machine ever pushed a
-- transition, and the arena used to land on their overworld as a hard cut.
--
-- **Why the engine's own wipe is not what plays here.** Both wipe classes are
-- engine internals -- `src.render.BattleTransition` and `src.ui.gen2.
-- BattleTransition` -- and a mod may only require `src.link.*` under the
-- `network` permission; requiring either would trip the loader's permissions
-- tripwire and land as a private-require finding in `modkit pack`. The two
-- public-ish ways to reach one are worse than the problem: the `transitions`
-- registry only *registers styles* and cannot play one, and the overworld
-- object handed out by `mod.world` plays one only as a side effect of starting
-- a whole engine battle (`pushBattle` / `startBattle`), which would push the
-- battle theme a second time, wants a Gen-1-shaped battle object, has a
-- different name and signature on Gen 2, and would hold the co-op screen off
-- the stack for the two-plus seconds of wipe + `BLACK_HOLD` -- two seconds
-- during which a refereed turn is already open and this client is not
-- answering it.
--
-- So it is drawn here, in this screen's own draw, over the arena it is
-- revealing: a short hold on black and a fade off it. That is the *tail* of
-- the engine's transition -- the part that reads as "the battle is arriving"
-- -- and it costs nothing, because the screen underneath is live and updating
-- from the first frame.
--
-- Armed for **both** clients, not just the joiner. The waiter's engine wipe
-- ended several seconds and one whole trainer entrance ago, and the swap from
-- their engine battle to the co-op arena is its own hard cut; the same fade
-- covers it, and the two players see the fight begin the same way.
--
-- Frames, not seconds, because everything else on this screen that moves is
-- counted in fixed steps (`growIn`, FAINT_FRAMES, EXP_FILL_FRAMES).
local ENTRY_HOLD = 6    -- full black, while the arena builds its first frame
local ENTRY_FADE = 18   -- ...and off it
M.ENTRY_FRAMES = ENTRY_HOLD + ENTRY_FADE

-- How black the veil is on a given frame of the entry, 0 once it is over.
--
-- Pure and exported for the reason M.hpBarWidth and Ui.cancelRow are: the
-- curve is the whole of the effect, and a headless suite can assert it without
-- a renderer, a window, or a frame ever being drawn.
function M.entryAlpha(frame)
  frame = tonumber(frame) or 0
  if frame < 0 then return 1 end
  if frame < ENTRY_HOLD then return 1 end
  local into = frame - ENTRY_HOLD
  if into >= ENTRY_FADE then return 0 end
  return (ENTRY_FADE - into) / ENTRY_FADE
end

-- ------- construction
--
-- opts:
--   slots   four { side, owner, name, party } in a1,a2,b1,b2 order
--   mine    the slot index this player controls
--   host    true if this client runs the simulation
--   net     { send = fn(payload), poll = fn() -> { payload } } or nil
--   onDone  called with "win"|"loss"|"draw" once the battle ends
--
-- ...and four more for a fight the intermediator may referee. All optional: a
-- screen built without them is the client-simulated battle this file always was.
--   transport the mod's hub connection, for the mmo.battle_* types. Not `net`:
--             those are addressed to the hub itself rather than relayed to the
--             other three, which is the whole difference between the two paths
--   battleId  the hub's id for this fight, which every mediated message names
--   selfId    this client's own hub id, which is how an outcome naming four
--             players is read as a result for one
--   mode      "coop_npc" | "coop_pvp" | "coop_wild", the hub's word for which
--             shape this is (Config.MEDIATED_COOP)
--   wildCatchMon  engine mon kept for Party.add / Boxes.deposit on a catch
--                 (coop_wild; host and preferably partner both stash one)
--   wildParty     optional prebuilt battleMon sheets for the host's side-"b"
--                 upload; else snapshotMons of wildCatchMon
function M.new(game, opts)
  local eng = loadEngine(game)
  if not eng then return nil, "2-on-2 battles need the engine's battle modules." end

  local generation = Gen.generation(game)
  -- Gen 2: never attach Gen1 CoopField / Damage host-sim. Hub-mediated modes
  -- replay BattleSim2 events; CoopSim holds slots with fallback battlers.
  local gen2Mediated = generation == 2
  if not gen2Mediated then
    local need = {
      "BattleState", "Damage", "TurnOrder", "Status", "TypeChart",
      "Font", "HudTiles", "TrainerAI", "Music", "EffectRegistry",
      "ItemEffects", "Experience", "Pokemon", "Stats",
    }
    for _, key in ipairs(need) do
      if not eng[key] then
        return nil, "2-on-2 battles need the engine's battle modules."
      end
    end
  elseif not eng.Protocol then
    return nil, "2-on-2 battles need the engine's link modules."
  elseif not (eng.BattleState and eng.Damage) and not gen2HostSimWarned then
    gen2HostSimWarned = true
    mod.log:warn("Gen 2 co-op uses hub-mediated BattleSim2 (no Gen1 "
      .. "BattleState/Damage host-sim); connect to a Gen 2 hub so mediated "
      .. "coop_pvp / coop_npc / coop_wild can be refereed -- local CoopField "
      .. "resolve is disabled on this boot")
  end

  local ruleset
  do
    local rulesets = game.data.rulesets
    local selected = game.save and game.save.options and game.save.options.ruleset
    ruleset = (rulesets and selected and rulesets[selected])
      or (rulesets and rulesets.gen1_faithful)
      or (rulesets and rulesets.gen2_faithful)
      or {}
  end

  local self = setmetatable({
    game = game,
    isOpaque = true,
    mine = opts.mine or 1,
    host = opts.host and true or false,
    -- Which player is simulating. Held so a disconnect can tell "the host
    -- left" (nobody can resolve another turn) from "a player left" (the fight
    -- continues three ways).
    hostId = opts.hostId,
    -- The trainer this battle stood in for: their picture, their music, and
    -- the line they say when they lose. oppClass + partyIndex travel with the
    -- id so computeMusicKind can tell a badge gym fight from the same class's
    -- non-badge parties (Giovanni #3 vs #2).
    trainer = opts.trainer,
    oppClass = opts.oppClass,
    partyIndex = opts.partyIndex,
    trainerPic = opts.trainerPic,
    endBattleText = opts.endBattleText,
    -- Whether winning this one moves anybody's rating. Handed in rather than
    -- worked out here: Coop owns that rule (see its `ranksPoints`), and a
    -- second copy of it living in the battle screen is a second copy to get
    -- out of step.
    ranksPoints = opts.ranksPoints and true or false,
    net = opts.net,
    onDone = opts.onDone,
    -- The mod's screen pusher, for the prompts this fight earns. Only the
    -- catcher's naming grid uses it today, and a screen built without one
    -- (the headless suite) simply never asks -- the catch is still granted.
    ui = opts.ui,
    -- ------- the intermediator's half, all of it inert until it answers
    --
    -- `mediated` is the flag every cut below is gated on, and it is set by
    -- mmo.battle_ready and by nothing else -- not by the mode, not by having a
    -- transport. Modes in Config.MEDIATED_COOP never host-sim while waiting
    -- (tryResolve/openTurn/autoPickLate no-op); upload failure sets medFailed
    -- and ends the fight rather than falling through to engine ItemEffects.
    transport = opts.transport,
    battleId = opts.battleId,
    selfId = opts.selfId,
    mode = opts.mode,
    -- coop_wild grant material: engine mon for Party.add, optional sheets for
    -- the host's side-b upload (else snapshot of wildCatchMon at upload time).
    wildCatchMon = opts.wildCatchMon,
    wildParty = opts.wildParty,
    mediated = false,
    medUploaded = false,
    medFailed = false, -- upload refused; do not fall back to host-sim
    bagSheet = nil,    -- uploaded PROTOCOL 15 bag counts when mediated
    pendingItem = nil, -- item choice awaiting hub `item` event
    pendingItemSlot = nil, -- 1-based seat.party index for vitamin writeback
    itemPick = nil,    -- mediated ITEM menu selection awaiting party/move
    itemPartyIndex = nil,
    medPending = {},   -- rows built from events, played when the turn closes
    medSeq = 0,        -- the highest event sequence applied
    medGaps = 0,       -- events that arrived out of order
    awaitingReconnect = false,
    reconnectSent = false,
    -- Gen 2: shell is replay-only; host-sim resolve must not run.
    gen2Mediated = gen2Mediated or nil,
    phase = "intro",
    moveIndex = 1,
    targetIndex = 1,
    frame = 0,
    messages = {},
    shown = nil,
    events = {},
    pending = {},      -- actions collected this turn, keyed by slot
    -- Two silences, measured separately. `waitClock` is the host waiting on a
    -- player's choice; `hostClock` is everybody else waiting on the host.
    waitClock = 0,
    hostClock = 0,
    sent = false,
    result = nil,
    hitSlot = nil,
    stageAlly = nil,
    stageFoe = nil,
    slideAlly = nil,
    slideFoe = nil,
    lastFoeFocus = nil,
    -- Gen1 top-down theatre: speech bubbles over human trainers when their
    -- mon acts. Nil until the first human-owned move text / anim lands.
    battlefieldBubbles = nil,
    battlefieldLoaded = nil,
    -- The per-attack chronology's two deliberate gaps (`BEAT_SPAN`): how long
    -- the queue is held for, how much of that has been spent, and which
    -- attacker + move already had its shout so a multi-hit move does not get
    -- one per strike. All nil outside a beat.
    beatHold = nil,
    beatDwell = nil,
    calloutSpent = nil,
    -- ...and which attack has already been *shouted*, which is a different
    -- question from which one spent a beat: one attack reaches the bubble from
    -- two directions (the anim row and the "X used MOVE" line beside it), and
    -- only the first of them may raise a shout. See `noteBattlefieldBubble`.
    calloutShout = nil,
  }, M)

  local rng = function(a, b)
    if love and love.math then return love.math.random(a, b) end
    return a
  end

  -- Back sprites for the local seat's side (bottom after viewPos), front for
  -- the far side. Must be known before CoopSim.new runs sendOut, or the first
  -- field would face the wrong way until a switch rebuilt it.
  local facingSide = "a"
  do
    local mineSpec = (opts.slots or {})[self.mine]
    if mineSpec and mineSpec.side == "b" then facingSide = "b" end
  end

  local field
  if not gen2Mediated then
    -- The adapter first, because the sim resolves moves through it. It reads the
    -- sim's slot list live rather than a copy, so a send-out the sim does is
    -- visible to the next move the engine resolves.
    local slots = {}
    field = CoopField.new(
      { BattleState = eng.BattleState, rng = rng, game = game },
      game, slots, ruleset)
    if not field then
      return nil, "2-on-2 battles need Gen1 BattleState for host-sim."
    end
  end

  self.sim = CoopSim.new({
    data = game.data,
    ruleset = ruleset,
    game = game,
    damage = (not gen2Mediated) and eng.Damage or nil,
    status = eng.Status,
    turnOrder = eng.TurnOrder,
    makeBattler = (not gen2Mediated) and eng.BattleState
      and eng.BattleState.makeBattler or nil,
    field = field,
    drain = field and CoopField.drain or nil,
    itemUse = (not gen2Mediated) and eng.ItemEffects and eng.ItemEffects.use or nil,
    experience = eng.Experience,
    movesAt = eng.Experience and eng.Experience.movesLearnedAt,
    trainerAI = (not gen2Mediated) and eng.TrainerAI or nil,
    -- The trainer the NPC side came from, and how many class actions it may
    -- spend. wAICount in the original; without it every gym leader would
    -- potion on every turn it was allowed to.
    trainer = opts.trainer,
    aiUses = opts.aiUses,
    save = game.save,
    facingSide = facingSide,
    onError = function(err)
      mod.log:warn("a move failed to resolve in a co-op battle (%s); the "
        .. "battle continues -- report the move it happened on", tostring(err))
    end,
    rng = rng,
  }, opts.slots)

  if not self.sim then
    return nil, "2-on-2 battles could not build the field."
  end

  -- The field was built before the sim had slots; point it at the real list
  -- now that there is one.
  if field then field.slots = self.sim.slots end

  if eng.TypeChart and eng.TypeChart.load then
    pcall(eng.TypeChart.load, game.data)
  end

  -- The engine's own subanimation player, driving the engine's own animation
  -- data. It draws in the classic 160x144 coordinate space with one player pic
  -- and one enemy pic, so drawAnim below translates each frame onto the slot
  -- that actually acted -- the same trick WideBattle uses to move an animation
  -- between two anchors it was not authored for.
  if eng.AnimPlayer and game.data.battle_anims then
    local ok, player = pcall(eng.AnimPlayer.new, game.data.battle_anims)
    if ok then self.animPlayer = player end
  end
  -- Which surround the presenter paints, decided before the first frame rather
  -- than on the first update (see `refreshLetterbox`).
  self:refreshLetterbox()
  -- Armed at construction rather than in `enter()`, so it is already true of
  -- the object src/Coop.lua's startBattle is about to push -- a screen that
  -- drew one frame before entering would otherwise show the arena first and
  -- then fade *in* from it. See "the way in" above.
  self.entryFrame = 0
  return self
end

-- ------- lifecycle

-- Announced to any mod that cares, on this mod's own event names.
--
-- **Not `battle.started` / `battle.ended`.** `mod.events:emit` is namespaced by
-- the loader -- a mod may only emit `mod.<id>.*` -- and that rule is a good
-- one: it is what stops any installed mod forging an engine event and having
-- every listener believe the engine said it. So a co-op battle says so under
-- its own name, and a mod that wants to hear about one listens for that.
--
-- The payload carries the same three things the engine's own battle events
-- carry, plus the slot roster, because "who is in it" is the question a
-- four-way battle raises that a 1v1 does not.
-- Tell the rest of the game a co-op battle happened.
--
-- **The engine's own `battle.started` and `battle.ended` never fire for one**,
-- and cannot be made to. `battle.started` is emitted from `BattleState:enter`,
-- and the trainer battle this displaced is taken off the stack before it ever
-- enters; `battle.ended` is emitted from `BattleState:finish`, and the co-op
-- flow calls that battle's `onFinish` directly rather than finishing it. So a
-- mod watching the engine's events sees nothing at all -- not a co-op battle
-- starting, and not a trainer being beaten by two people.
--
-- A mod cannot emit an engine event: `mod.events:emit` is namespaced to
-- `mod.<id>.*` precisely so that no mod can forge one. So these are the mod's
-- own, under `mod.rby_mmo.`, and the payload is shaped to be worth listening
-- to rather than to be a notification -- a listener that has to reach into
-- `battle` for everything might as well not have been told.
function M:announce(name, extra)
  local slots = (self.sim and self.sim.slots) or {}
  local human = 0
  for _, slot in ipairs(slots) do
    if slot.owner then human = human + 1 end
  end
  local payload = {
    -- The running battle, handed over as the engine's own `battle.started`
    -- hands over its BattleState. **Read only**: it is not a copy, so a
    -- listener that writes to it desyncs all four clients. Said in the README
    -- beside the snippet, which is where somebody writing a listener looks.
    battle = self,
    -- What *kind* of battle, as a word. This used to be the slot count -- a
    -- number, under a name that reads like a category -- so a listener asking
    -- "is this a party battle?" got `4` and could only be wrong.
    --
    -- Asked through `M:partyBattle`, which is the same question the RUN rule
    -- turns on -- one definition, so a listener and the rules can never
    -- disagree about which sort of battle this is.
    kind = self:partyBattle() and "party" or "npc",
    fighters = #slots,
    humans = human,
    -- Who this client is in it, so a listener does not have to work out which
    -- of the four is the player it is running inside.
    mine = self.mine,
    side = slots[self.mine] and slots[self.mine].side,
    host = self.host,
    trainerId = self.trainer and self.trainer.id,
    -- Whether it moves anybody's rating -- see Coop.ranksPoints.
    ranked = self.ranksPoints and true or false,
    slots = {},
  }
  for i, slot in ipairs(slots) do
    payload.slots[i] = {
      side = slot.side, owner = slot.owner, name = slot.name,
      species = slot.battler and slot.battler.mon and slot.battler.mon.species,
    }
  end
  for k, v in pairs(extra or {}) do payload[k] = v end
  local ok, err = pcall(function()
    mod.events:emit("mod.rby_mmo." .. name, payload)
  end)
  if not ok then
    mod.log:warn("could not announce %s (%s); the battle is unaffected",
      name, tostring(err))
  end
end

-- Which battle theme this is, decided by the engine's own rule rather than by
-- a guess here.
--
-- "trainer" is not good enough: a gym leader has their own theme, the rival's
-- last fight has another, and the rule that separates them reads a badge table
-- this mod has no business duplicating. So the engine's `computeMusicKind` is
-- run against a stand-in carrying the fields it reads -- trainer id (Lance /
-- Rival3), plus `oppClass` + `partyIndex` (badge gym leaders; Giovanni's gym
-- is #3, not #1). A client that joined by invitation and never met this
-- trainer would otherwise hear the ordinary trainer theme while the host
-- heard the gym leader's.
--
-- Answered once. The victory theme is `kind .. "Win"`, so a kind that moved
-- between the start of the battle and the end of it would answer the gym
-- leader's theme with the wrong jingle.
function M.musicKind(self)
  if self.cachedMusicKind then return self.cachedMusicKind end
  -- Party vs Wild is wildlife, not a trainer fight or a PvP link cue.
  if self.mode == "coop_wild" then
    self.cachedMusicKind = "wild"
    return "wild"
  end
  local kind = self.trainer and "trainer" or "link"
  if self.trainer then
    -- Badge gym leaders key victories as oppClass#partyIndex. Prefer
    -- self.oppClass / self.partyIndex (PROTOCOL 20 invite path) so Brock is
    -- not stuck on "trainer". Trainer.id alone still covers Lance / Rival3.
    -- After a generation=2 headless load, Gen2Compat may have shimmed
    -- BattleState without a working computeMusicKind — fall back to the same
    -- victories / rival / Lance rules (audio/play_battle_music.asm).
    local trainer = self.trainer
    local oppClass = self.oppClass
      or trainer.oppClass
      or trainer.id
      or trainer.class
    local partyIndex = tonumber(self.partyIndex)
      or tonumber(trainer.partyIndex)
      or 1
    local eng = engine
    local decided
    if eng and eng.BattleState and type(eng.BattleState.computeMusicKind) == "function" then
      local probe = setmetatable({
        kind = "trainer",
        trainer = trainer,
        oppClass = oppClass,
        partyIndex = partyIndex,
      }, { __index = eng.BattleState })
      local ok, result = pcall(eng.BattleState.computeMusicKind, probe)
      if ok and type(result) == "string" then decided = result end
    end
    if not decided then
      if trainer.id == "OPP_RIVAL3" then
        decided = "final"
      else
        local okV, victories = pcall(require, "data.scripts.victories")
        local reward = okV and victories
          and oppClass
          and victories[oppClass .. "#" .. tostring(partyIndex)]
        if (reward and reward.badge) or trainer.id == "OPP_LANCE" then
          decided = "gym"
        end
      end
    end
    if decided then kind = decided end
  end
  self.cachedMusicKind = kind
  return kind
end

-- Display name for the opening "Wild X appeared!" line (Gen 1 BattleState).
-- Prefer the stashed encounter mon; else the first ownerless field party lead.
function M:wildIntroName()
  local mon = self.wildCatchMon
  if mon then
    local name = mon.nickname or mon.species
    if type(name) == "string" and name ~= "" then
      return Wire.name(name) or name
    end
  end
  if self.wildParty and self.wildParty[1] then
    local sheet = self.wildParty[1]
    local name = sheet.species or sheet.speciesId
    if type(name) == "string" and name ~= "" then
      return Wire.name(name) or name
    end
  end
  if self.sim then
    for _, slot in ipairs(self.sim.slots or {}) do
      if slot.owner == nil then
        local lead = slot.party and slot.party[1]
        if lead then
          local name = lead.nickname or lead.species
          if type(name) == "string" and name ~= "" then
            return Wire.name(name) or name
          end
        end
      end
    end
  end
  return "POKeMON"
end

-- Display name for an on-field battler (Go! / sent out lines).
local function seatMonName(slot)
  local battler = slot and slot.battler
  if not battler then return "?" end
  return battler.name
    or (battler.mon and (battler.mon.nickname or battler.mon.species))
    or "?"
end

-- Wire-safe trainer/player label for "Name sent out Y!".
local function seatOwnerName(slot)
  if not slot then return "Someone" end
  local raw = slot.name
  if type(raw) == "string" and raw ~= "" then
    return Wire.name(raw) or raw
  end
  return "Someone"
end

-- Clear intro presentation flags (exit, forfeit, or battle over).
function M:clearIntroFlags()
  self.introBalls = nil
  self.introHide = nil
  self.growIn = nil
  self.showEnemyTrainer = nil
end

-- Display name for trainer appear / "sent out" lines (BattleState introText).
function M:trainerIntroName()
  local t = self.trainer
  if type(t) == "table" and type(t.name) == "string" and t.name ~= "" then
    return Wire.name(t.name) or t.name
  end
  if self.sim then
    for _, slot in ipairs(self.sim.slots or {}) do
      if slot.owner == nil and self:foeSide(slot.index) then
        local raw = slot.name
        if type(raw) == "string" and raw ~= "" then
          return Wire.name(raw) or raw
        end
      end
    end
  end
  return "Trainer"
end

-- Live foe party list for intro ball chrome (one row; shared tables once).
function M:foeIntroParty()
  if not self.sim then return nil end
  local seen, flat = {}, {}
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner == nil and self:foeSide(slot.index) and slot.party then
      if not seen[slot.party] then
        seen[slot.party] = true
        for _, mon in ipairs(slot.party) do
          flat[#flat + 1] = mon
        end
      end
    end
  end
  if #flat == 0 then return nil end
  return flat
end

-- Trainer theatrical intro: appear uses trainer face + foe ball row; foes are
-- hidden until their send-out (mirrors BattleState EnemySendOutFirstMon without
-- introSlide / trainer-back walk-off). Wild and party-vs-party never arm this.
-- Invite joiners often have a trainer record but nil trainerPic -- do not hide
-- foes behind an empty face; keep the old visible-foes / "2 on 2" open.
function M:usesTrainerIntro()
  if not self.trainer or not self.trainerPic then return false end
  if self.mode == "coop_wild" or self.mode == "coop_pvp" then return false end
  return true
end

-- Entrance cry via optional Sound (same clips BattleState:playEntranceCry).
function M:playEntranceCry(battler)
  local mon = battler and battler.mon
  if not mon then return end
  local Sound = engine and engine.Sound
  if not (Sound and Sound.playCry) then return end
  pcall(Sound.playCry, self.game.data, mon.species,
    mon.status == "SLP" and 37 or 11)
end

-- Grow-in scale for a slot this frame (nil when not growing). Stages match
-- BattleState:growInScale: 0 / 3/7 / 5/7 over ~12 frames, then full.
function M:growInScale(index)
  local grow = self.growIn
  if not grow or grow.slot ~= index then return nil end
  local f = grow.frame or 0
  return f < 3 and 0 or f < 7 and 3 / 7 or 5 / 7
end

-- After the trainer appear line: drop chrome / face, then sequential foe
-- send-outs (POOF + grow + cry) before the ally Go! gap.
function M:queueFoeIntroSendOut()
  self.messages[#self.messages + 1] = {
    act = function(battle)
      battle.introBalls = nil
      battle.showEnemyTrainer = nil
    end,
  }
  local name = self:trainerIntroName()
  local foes = {}
  for _, slot in ipairs((self.sim and self.sim.slots) or {}) do
    if self:foeSide(slot.index) then
      foes[#foes + 1] = slot
    end
  end
  if #foes == 0 then
    if self.introHide then
      for idx, _ in pairs(self.introHide) do
        local slot = self.sim and self.sim:slot(idx)
        if slot and slot.owner == nil then self.introHide[idx] = nil end
      end
    end
    return
  end
  for _, slot in ipairs(foes) do
    local idx = slot.index
    self:say(("%s sent\nout %s!"):format(name, seatMonName(slot)))
    -- Line, then the arc, then the burst -- the same three beats a refereed
    -- arrival gets (see `queueSendBall`), and the seat is already held under
    -- `introHide` for the whole of it.
    self:queueSendBall(idx)
    self.messages[#self.messages + 1] = {
      anim = "POOF_ANIM", from = idx, attackerIsPlayer = false,
    }
    self.messages[#self.messages + 1] = {
      act = function(battle)
        if battle.introHide then battle.introHide[idx] = nil end
        local s = battle.sim and battle.sim:slot(idx)
        local battler = s and s.battler
        if battler then
          battle.growIn = { slot = idx, frame = 0 }
          -- The arena's own send-out beat, at the same moment (see
          -- noteBattlefieldSpawn); growIn is the classic stage's.
          battle:noteBattlefieldSpawn(idx)
          battle:playEntranceCry(battler)
        end
      end,
    }
    self.messages[#self.messages + 1] = { wait = 12 }
  end
end

-- After the opening appear line: wait, then sequential viewer-centric
-- send-outs (my Go! → POOF/grow/cry, then partner sent out). Ball chrome is
-- cleared when the appear page advances (see messages dismiss / foe intro
-- clear act), not here.
-- The gap the engine leaves between the opening line and the first monster
-- coming out (BattleState's own constant, with the engine's default under a
-- build that does not export it).
local function sendOutWait()
  local ok, Timing = pcall(require, "src.core.Timing")
  if ok and Timing and Timing.BATTLE_START_SENDOUT then
    return Timing.BATTLE_START_SENDOUT
  end
  return 40
end

-- A refereed fight's intro is the **referee's** send-outs, so all this client
-- queues is the gap in front of them.
--
-- Both halves of the client-side intro are skipped in that case
-- (`queueFoeIntroSendOut` / `queueIntroSendOut`), and the reason is that they
-- were being played twice. The hub's `_start` emits one `send` per seat the
-- moment every party is uploaded, `medRows` narrates each one and `playEvents`
-- queues the swap that reveals it -- so a co-op player watched their monster
-- come out under "Go! X!", and then watched the same monster come out again a
-- second later under "ANN sent out X!", with `sim:sendOut` rebuilding every
-- battler underneath. Two sentences, two bursts, one arrival. The referee's
-- copy is the one that is kept: it is the one that is authoritative about
-- *which* monster (`mon` stamp), and it is the only one the other three
-- clients can be sure they are seeing the same version of.
--
-- The chrome still has to come down, and here that is this act's whole job:
-- the ball row and the trainer's face are dropped by the intro rows on the
-- client path, and with those gone nothing else would ever clear them.
function M:queueMediatedIntro()
  self.messages[#self.messages + 1] = {
    act = function(battle)
      battle.introBalls = nil
      battle.showEnemyTrainer = nil
    end,
  }
  self.messages[#self.messages + 1] = { wait = sendOutWait() }
end

function M:queueIntroSendOut()
  local sendWait = sendOutWait()
  self.messages[#self.messages + 1] = { wait = sendWait }

  local mine = self.mine
  local mySlot = self:mySlot()
  self:say(("Go! %s!"):format(seatMonName(mySlot)))
  self:queueSendBall(mine)
  self.messages[#self.messages + 1] = {
    anim = "POOF_ANIM", from = mine, attackerIsPlayer = true,
  }
  self.messages[#self.messages + 1] = {
    act = function(battle)
      if battle.introHide then battle.introHide[mine] = nil end
      local slot = battle.sim and battle.sim:slot(mine)
      local battler = slot and slot.battler
      if battler then
        battle.growIn = { slot = mine, frame = 0 }
        -- The arena's own send-out beat, at the same moment (see
        -- noteBattlefieldSpawn); growIn is the classic stage's.
        battle:noteBattlefieldSpawn(mine)
        battle:playEntranceCry(battler)
      end
    end,
  }
  self.messages[#self.messages + 1] = { wait = 12 }

  local partner = self:partnerOf(mySlot)
  if not partner then
    -- Seats we hid in enter() but will not animate must not stay blank.
    if self.introHide then
      for idx, _ in pairs(self.introHide) do
        if idx ~= mine then self.introHide[idx] = nil end
      end
    end
    return
  end
  local pIndex = partner.index
  self:say(("%s sent out\n%s!"):format(
    seatOwnerName(partner), seatMonName(partner)))
  self:queueSendBall(pIndex)
  self.messages[#self.messages + 1] = {
    anim = "POOF_ANIM", from = pIndex, attackerIsPlayer = true,
  }
  self.messages[#self.messages + 1] = {
    act = function(battle)
      if battle.introHide then battle.introHide[pIndex] = nil end
      local slot = battle.sim and battle.sim:slot(pIndex)
      local battler = slot and slot.battler
      if battler then
        battle.growIn = { slot = pIndex, frame = 0 }
        -- The arena's own send-out beat, at the same moment (see
        -- noteBattlefieldSpawn); growIn is the classic stage's.
        battle:noteBattlefieldSpawn(pIndex)
        battle:playEntranceCry(battler)
      end
    end,
  }
  self.messages[#self.messages + 1] = { wait = 12 }
end

function M:enter()
  -- Gen 1: Music.playBattle(kind) via computeMusicKind. Gen 2: BattleMusic
  -- song labels (Gold has no data.audio.battle[kind] ladder). See Gen.
  local eng = engine
  if eng and eng.Music then
    Gen.playBattleMusic(self.game, {
      Music = eng.Music,
      kind = self:musicKind(),
      mode = self.mode,
      trainer = self.trainer,
      oppClass = self.oppClass,
      partyIndex = self.partyIndex,
    })
  end
  -- Arena load once per fight (Gen1 theatre). Soft-fail if the asset is
  -- missing -- Battlefield.draw still paints a flat stand-in.
  if Battlefield.enabled(self.game) then
    self.battlefieldLoaded = true
    pcall(Battlefield.load, mod)
  end
  -- Intro ball chrome + hide ally humans until their Go!/sent-out step.
  -- Trainer theatrical: also hide foes and hold the trainer face through the
  -- appear line (no introSlide / trainer-back). Wild / party-vs-party leave
  -- foes visible and never arm a trainer face.
  self.introBalls = true
  self.introHide = {}
  local theatrical = self:usesTrainerIntro()
  -- A refereed fight hides **every** seat, both sides, whatever the mode: the
  -- referee sends one `send` per seat out of `_start` before the first turn
  -- opens (src/BattleSim/Turn.lua), and each of those is what reveals its own
  -- seat (`applySwap`). A seat left visible would be a monster standing on the
  -- arena before the sentence that puts it there -- the very complaint the
  -- doubled intro produced. Nothing is left hidden by a referee that never
  -- speaks: `failMediation` ends the battle, and `snapDisplay` reveals
  -- anything still held once the opening sends have played.
  local refereed = M.mediates(self.mode)
  for _, slot in ipairs((self.sim and self.sim.slots) or {}) do
    if refereed then
      self.introHide[slot.index] = true
    elseif slot.owner ~= nil and not self:foeSide(slot.index) then
      self.introHide[slot.index] = true
    elseif theatrical and self:foeSide(slot.index) then
      self.introHide[slot.index] = true
    end
  end
  if theatrical then
    self.showEnemyTrainer = self.trainerPic ~= nil
    local Sound = eng and eng.Sound
    if Sound and Sound.play then
      -- Gen 2 has no Trainer_Appeared clip; sfx() leaves the Gen 1 name and
      -- Sound.play soft-no-ops when the build lacks it.
      pcall(Sound.play, self.game.data, Gen.sfx(self.game, "Trainer_Appeared"))
    end
    self:say(("%s wants\nto fight!"):format(self:trainerIntroName()))
    if not refereed then self:queueFoeIntroSendOut() end
  elseif self.mode == "coop_wild" then
    -- Party vs Wild: same sentence solo wild uses (BattleState introText).
    self:say(("Wild %s\nappeared!"):format(self:wildIntroName()))
  else
    self:say("2 on 2 battle!")
  end
  -- The opening line is this client's either way -- it is the frame round the
  -- fight, not a send-out. What follows it is the referee's send-outs on a
  -- refereed fight and this client's own on any other. See `queueMediatedIntro`.
  if refereed then
    self:queueMediatedIntro()
  else
    self:queueIntroSendOut()
  end
  self.phase = "messages"
  self.after = "choose"
  self:announce("coop_battle_started")
  -- ...and this is where a refereed fight is offered its field. Last, because
  -- everything above is what the player sees either way: an upload that goes
  -- nowhere leaves a client-simulated battle rather than a screen that never
  -- opened.
  self:uploadMediated()
end

-- The fanfare, once, when the result is known.
--
-- Gen 1 looks up `kind .. "Win"` (rival-final folds to gym). Gen 2 plays a
-- BattleMusic victory label. Guarded against a second call because a result
-- can be reached twice -- a forfeit racing the last knockout.
function M:playVictoryMusic()
  if self.result ~= "win" or self.victoryMusicPlayed then return end
  self.victoryMusicPlayed = true
  local eng = engine
  if not (eng and eng.Music) then return end
  Gen.playVictoryMusic(self.game, {
    Music = eng.Music,
    kind = self:musicKind(),
    mode = self.mode,
    trainer = self.trainer,
    oppClass = self.oppClass,
    partyIndex = self.partyIndex,
  })
end

-- Give back an item paid for on a turn that never happened.
--
-- Host-sim only: the bag is debited when the action is committed. Mediated
-- fights debit only after the hub `item` event, so there is nothing to refund
-- for a refused choice (never spent) or an accepted one (hub already spent).
function M:refundUnspent()
  if self.mediated then
    self.pendingItem = nil
    self.pendingItemSlot = nil
    self.owed = nil
    return
  end
  local id = self.owed
  self.owed = nil
  if not id then return end
  local inventory = self.game.save and self.game.save.inventory
  if not inventory then return end
  inventory[id] = (inventory[id] or 0) + 1
  self.itemList = nil
end

function M:exit()
  self:refundUnspent()
  self:clearIntroFlags()

  -- The world gets its music back on the way out, win or lose. The victory
  -- theme loops until something stops it -- each Defeated* song ends in a
  -- `sound_loop 0` -- so a win that did not restore here would follow the
  -- players back into the overworld and play there forever. The engine's own
  -- finish() restores unconditionally for the same reason.
  local eng = engine
  if eng and eng.Music then
    Gen.restoreMapMusic(self.game, { Music = eng.Music })
  end
  if self.onDone and not self.reported then
    self.reported = true
    self:announce("coop_battle_ended", { result = self.result or "draw" })
    self.onDone(self.result or "draw", self.toLearn)
  end
end

-- Inner columns of the bottom box (20-tile box, one tile of border each side).
-- Every battle line and every list label is cut to this so nothing paints past
-- the right edge -- Gen 1's own fight box is the same budget.
local BOX_COLS = 18
local BOX_ROWS = 2

-- Soft-wrap one string into lines that fit the bottom box.
--
-- Prefers a break at the last space that still fits; otherwise hard-cuts. Keeps
-- author newlines as paragraph breaks so curated two-line pages stay two lines
-- when each half already fits.
local function wrapBoxLines(text, width)
  width = width or BOX_COLS
  local lines = {}
  local raw = tostring(text or "")
  if raw == "" then return { "" } end
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    local rest = line
    if rest == "" then
      lines[#lines + 1] = ""
    else
      while #rest > width do
        local chunk = rest:sub(1, width)
        local space = chunk:match("^.*()%s")
        local breakAt = width
        if space and space > 1 then breakAt = space - 1 end
        lines[#lines + 1] = rest:sub(1, breakAt):gsub("%s+$", "")
        rest = rest:sub(breakAt + 1):gsub("^%s+", "")
      end
      lines[#lines + 1] = rest
    end
  end
  return lines
end

-- Pages of at most BOX_ROWS lines, each line already <= BOX_COLS.
local function pageBoxText(text)
  local lines = wrapBoxLines(text, BOX_COLS)
  local pages = {}
  for i = 1, #lines, BOX_ROWS do
    local page = lines[i]
    if lines[i + 1] then page = page .. "\n" .. lines[i + 1] end
    pages[#pages + 1] = page
  end
  if #pages == 0 then pages[1] = "" end
  return pages
end

-- One step on a vertical list. UP/DOWN move; LEFT/RIGHT are aliases (same habit
-- as the target column and the move list). Clamped -- no wrap.
local function listPress(index, count, input)
  if count < 1 then return nil end
  local step = 0
  if input:wasPressed("up") or input:wasPressed("left") then step = -1
  elseif input:wasPressed("down") or input:wasPressed("right") then step = 1 end
  if step == 0 then return nil end
  return math.max(1, math.min(count, (index or 1) + step))
end

-- The battle-command grid. Each arrow moves on its own axis and clamps at the
-- edge (BattleState / WideBattle).
--
-- `cols` is how many columns the menu is *actually drawn in*, and it has to be
-- passed rather than assumed: the classic 160×144 chrome and Gen 2 draw the
-- four commands 2×2, but the modern band lays them out four across whenever it
-- has the width for it (`Battlefield.bandGridCols`). Stepping a 2×2 grid under
-- a 1×4 paint sent LEFT/RIGHT nowhere from FIGHT and made UP/DOWN jump two
-- slabs -- the highlight landed on a button that is not next to the one it
-- left. Defaults to 2, which is byte-identical to what this did before: for
-- cols == 2 and count == 4 the row clamp below is the same 1 it was hard-coded
-- to, and for any smaller count the out-of-range guard already refused the
-- move.
local function gridStep(index, count, direction, cols)
  cols = math.floor(tonumber(cols) or 2)
  if cols < 1 then cols = 2 end
  local lastCol = cols - 1
  local lastRow = math.max(0, math.ceil(count / cols) - 1)
  local row = math.floor((index - 1) / cols)
  local col = (index - 1) % cols
  if direction == "left" then col = math.max(0, col - 1)
  elseif direction == "right" then col = math.min(lastCol, col + 1)
  elseif direction == "up" then row = math.max(0, row - 1)
  elseif direction == "down" then row = math.min(lastRow, row + 1)
  else return index end
  local moved = row * cols + col + 1
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

function M:say(text)
  for _, page in ipairs(pageBoxText(text)) do
    self.messages[#self.messages + 1] = page
  end
end

function M:mySlot() return self.sim:slot(self.mine) end

-- ------- input
--
-- The same four commands the original offers, as a 2x2 grid
-- (FIGHT/SWITCH over ITEM/RUN), navigated with every d-pad direction.

-- How long a freshly shown line is safe from the button that dismisses it.
--
-- A line used to offer its dismiss window on the very tick it was created:
-- `shown` is set and the A/B check below runs in the same call, before one
-- frame has painted it. So a player holding A through a battle -- which is
-- every player -- swallowed lines they never saw, and the ones printed by a
-- menu that answers itself were invisible: press A on ITEM with an empty bag
-- and "You have nothing to use!" was queued, shown and eaten inside a single
-- frame, leaving a flicker and a menu that appeared to do nothing at all.
--
-- A quarter of a second is longer than any button edge and shorter than any
-- deliberate press, and it is a floor rather than a delay: the auto-advance
-- below is untouched, so nothing waits longer than it did.
local MSG_MIN_DWELL = 0.25

-- ...and how long a line stays up when nobody presses anything. Named rather
-- than written twice: the run-consent states read it too (M:updateRunAsk), and
-- two copies of a timing constant are two things to move separately.
local MSG_AUTO_ADVANCE = 1.6

function M:update(dt)
  self.frame = self.frame + 1
  -- The surround the presenter paints round this screen depends on which stage
  -- is up, and it reads the answer off this object every frame (see
  -- `refreshLetterbox`).
  self:refreshLetterbox()
  -- Arena effects advance on wall time whatever the phase: a lunge or a sink
  -- started under one phase must not freeze because a menu opened over it.
  self:stepFx(dt)
  -- Grow-in advances on the same fixed step as the engine's AnimateSendingOutMon.
  if self.growIn then
    self.growIn.frame = (self.growIn.frame or 0) + 1
    if self.growIn.frame >= 12 then self.growIn = nil end
  end
  -- The way in, counted on the same fixed step and dropped the instant it is
  -- spent so the ordinary case is one nil test a frame. Nothing waits on it:
  -- the battle underneath is running from frame one, and the veil is only what
  -- the player can see of it. See "the way in".
  if self.entryFrame then
    self.entryFrame = self.entryFrame + 1
    if self.entryFrame >= M.ENTRY_FRAMES then self.entryFrame = nil end
  end
  if self.sim and not self.result then
    self:stepFocusSlides()
  end
  local input = self.game.input

  if self.medFailed and not self.result then
    self:failMediation()
  end

  if self.net then
    self:drainNet()
    self:tickStalls(dt or 0)
  end

  if self.phase == "messages" then
    -- An animation holds the queue while it runs, so a move's flash lands
    -- before the line that says what it did -- the engine's own ordering.
    if self.anim then
      if self.animPlayer and self.animPlayer.update then
        pcall(self.animPlayer.update, self.animPlayer)
      end
      -- Same contract as BattleState: poll SE_* / sound rows after each tick.
      self:pollAnimEffects()
      local done = true
      if self.animPlayer and self.animPlayer.isDone then
        local ok, finished = pcall(self.animPlayer.isDone, self.animPlayer)
        done = (not ok) or finished
      end
      -- ...and a row that started an arena effect is held for as long as that
      -- effect plays, on top of whatever the engine's player wanted. The row
      -- *is* the throw: one that ended first would cut the arc off mid-air and
      -- let the next line print over a ball still in flight. Only ever set on
      -- the battlefield path (`startBallFx`), so classic and Gen 2 keep the
      -- player's own timing exactly.
      if self.animHold then
        self.animDwell = (self.animDwell or 0) + (dt or 0)
        if self.animDwell < self.animHold then done = false end
      end
      if done or (input and input:wasPressed("b")) then
        -- Hit thud after the flash (PlayApplyingAttackSound timing).
        self:applyPendingHitFx()
        self.anim = nil
        self.animHold = nil
        self.animDwell = nil
      end
      return
    end
    -- ------- a display beat: the gap that makes two things two things
    --
    -- Some of the chronology is a *pause* rather than a thing being drawn. The
    -- trainer's shout has to be on screen before the monster leans in, and the
    -- defender has to flash before its bar starts falling -- otherwise the two
    -- halves land in the same tick and read as one event with decoration on it.
    --
    -- Held here, and queue-pure: the row that was about to start goes back at
    -- the head of the queue (`splitCalloutBeat`, `splitHitBeat`) and this is
    -- the gap in front of it. Exactly what `startBallFx` does to give a SHAKE
    -- row's extra wobbles a row each -- still one thing at a time, and the
    -- queue is still the only sequencer.
    --
    -- Held like an animation is, and for the same reasons: the line already on
    -- screen stays up (nothing here touches `shown`), the dwell clock below is
    -- not ticked while it runs, and B skips it. The tick the beat *ends* on
    -- falls straight through to the row waiting behind it rather than spending
    -- a frame doing nothing.
    if self.beatHold then
      self.beatDwell = (self.beatDwell or 0) + (dt or 0)
      if self.beatDwell < self.beatHold
         and not (input and input:wasPressed("b")) then
        return
      end
      self.beatHold = nil
      self.beatDwell = nil
    end
    -- A falling bar holds the queue exactly as an animation does, and -- like
    -- the engine's -- it cannot be hurried. `UpdateHPBar` is not a text page:
    -- the engine reads the button only for a page that has finished printing,
    -- so A and B do nothing here. Stepped once per call rather than by `dt`,
    -- because this screen's update runs on the same fixed 60Hz step the engine
    -- counts its frames in.
    if self.draining then
      self:stepDrain()
      return
    end
    -- ...and a filling exp strip holds it the same way, for the same reason:
    -- it is a bar crawling on the cart's own unskippable loop, not a text page
    -- with a button to answer it.
    if self.expFilling then
      self:stepExpFill()
      return
    end
    if self.faintFx then
      self:stepFaint()
      return
    end
    -- A swap costs no time at all: it is the moment the screen catches up with
    -- a send-out the field applied a while ago, and everything the departed
    -- monster was owed has just finished playing. Taken here rather than in
    -- the effect branch below because it neither blocks nor clears the line on
    -- screen -- "CAL sent out X!" is printed over a field that already has X
    -- standing on it, which is the order the original prints it in. Drained in
    -- a loop so a slot swapped twice in one turn does not cost a frame each.
    while true do
      local head = self.messages[1]
      if type(head) == "table" and head.swap then
        table.remove(self.messages, 1)
        self:applySwap(head)
      else
        break
      end
    end
    if #self.messages > 0 then
      -- An effect runs *under* the line already on screen.
      --
      -- These used to wait for `self.shown` to clear, which meant the box went
      -- blank for the whole of every flash and every drain: the monster was
      -- hit by a move nothing on screen still named. The engine keeps the last
      -- page up while its effects play, so the head of the queue is taken as
      -- soon as it is an effect, `shown` is left where it is, and the dwell
      -- clock below is not ticked while one runs -- a line must not time out
      -- in the middle of the thing it is describing.
      local head = self.messages[1]
      if type(head) == "table"
         and (head.anim or head.drain or head.faintfx or head.expfill
              or head.wait or head.act or head.ballsend) then
        -- Hold wait/act/anim behind opening appear line(s). Drop ball chrome
        -- when the post-appear wait starts (not on every page advance), so a
        -- multi-page appear does not begin the gap early.
        if (head.wait or head.act or head.anim)
           and self.shown ~= nil and self.introBalls then
          -- fall through to dwell
        elseif head.wait then
          if self.introBalls then self.introBalls = nil end
          if self.showEnemyTrainer then self.showEnemyTrainer = nil end
          head._t = (head._t or 0) + 1
          if head._t >= (tonumber(head.wait) or 0) then
            table.remove(self.messages, 1)
          end
          return
        else
          table.remove(self.messages, 1)
          if head.act then
            if type(head.act) == "function" then pcall(head.act, self) end
          elseif head.ballsend then
            self:startSendBall(head)
          elseif head.anim then
            self.acting = head.from or self.acting
            self:startAnim(head)
          elseif head.drain then
            self:startDrain(head)
          elseif head.expfill then
            self:startExpFill(head)
          else
            self:startFaint(head)
          end
          return
        end
      end
      if self.shown == nil then
        local next = table.remove(self.messages, 1)
        local fromSlot = nil
        if type(next) == "table" then
          self.acting = next.from or self.acting
          fromSlot = next.from
          next = next.text
        end
        -- Hub / playEvents lines skip M:say, so wrap here too: a single long
        -- referee sentence must not paint past the box edge.
        if type(next) == "string" then
          local pages = pageBoxText(next)
          next = pages[1]
          for i = #pages, 2, -1 do
            table.insert(self.messages, 1, pages[i])
          end
          -- Bubble when a human-owned mon's "used MOVE" line lands (Gen1
          -- theatre). fromSlot is preferred; mediated msg rows often omit it
          -- and leave the actor on self.acting from the prior row.
          --
          -- ...and only when the anim row beside it has not shouted already.
          -- One attack reaches the bubble from both rows, and the referee does
          -- not agree with itself about their order (the Node half emits the
          -- anim first, CoopSim the sentence), so `noteBattlefieldBubble` owns
          -- the "once per attack" rule and answers whether this call is the
          -- one that raised it.
          local _, raised = self:noteBattlefieldBubble(fromSlot or self.acting,
            next)
          -- ...and a shout *raised* by an announcement line is a **new attack**,
          -- so the callout beat is owed again. This is what keeps a multi-hit
          -- move to one shout: the coop queue announces once and then puts an
          -- anim row in front of every strike, all of them stamped with the
          -- same actor, so `splitCalloutBeat` needs something other than the
          -- row itself to tell "the move started" from "it landed again". A
          -- line that merely refreshed the shout the anim row already made is
          -- the same attack and re-arms nothing.
          if raised then self.calloutSpent = nil end
        end
        self.shown = next
        self.msgClock = 0
      end
    end
    -- ------- the dwell, which the **last** line of a queue is owed too
    --
    -- This used to live inside the queue check above, and that is the whole of
    -- the reported flicker. A line is *removed* from the queue at the moment
    -- it is shown, so the last one leaves the queue empty -- and on the very
    -- next tick the handover below cleared it and opened a menu over the top,
    -- whatever the player did. Every batch's final line therefore got exactly
    -- one frame, and a batch of exactly one line -- "You have nothing to
    -- use!", "There's no one else to send out!" -- was never readable at all:
    -- press A on an empty bag and the menu blinked and did nothing.
    --
    -- So the queue and the line on screen are two separate questions now. A
    -- line is up until it is dismissed, and only then is the box handed back.
    if self.shown ~= nil then
      self.msgClock = (self.msgClock or 0) + (dt or 0)
      -- advanced by A, or by a short dwell, so a long exchange does not need
      -- four buttons pressed for every hit -- but not before the line has been
      -- on screen long enough to be read (see MSG_MIN_DWELL). The clock is not
      -- ticked while an effect runs, so the floor is a quarter of a second of
      -- the line actually being *up*, not of wall time under a flash.
      local advance = false
      if self.msgClock >= MSG_MIN_DWELL
         and input
         and (input:wasPressed("a") or input:wasPressed("b")) then
        advance = true
      elseif self.msgClock > MSG_AUTO_ADVANCE then
        advance = true
      end
      if advance then
        self.shown = nil
      end
      return
    end
    -- A row that carried no text at all (an empty `msg` event) leaves nothing
    -- on screen and nothing to wait for -- the next tick takes the row behind
    -- it rather than treating the queue as spent.
    if #self.messages > 0 then return end
    -- The catch's naming prompt, owed since `grantCatch` and asked here:
    -- everything the ending had to say has been read, and the screen is about
    -- to pop. It takes this tick (the push makes it no longer the top of the
    -- stack), and `finish` runs on the tick after the player answers.
    if self.result and self:askOwedNickname() then return end
    if self.result then return self:finish() end
    -- The queue is empty and nobody is mid-effect, so whatever the bars were
    -- animating towards is simply where they are. Snapped rather than left to
    -- arrive on its own: the next thing to happen is a menu, and a bar still
    -- creeping under one is a bar that will still be creeping when the answer
    -- to that menu resolves.
    self:snapDisplay()
    -- ...and the box is handed back empty. The line that was on it has already
    -- been dismissed by the dwell above -- including the case this clear was
    -- written for, a queue that *ends* on an effect row and pops it while
    -- `shown` is still set. That line now keeps the box until it is dismissed
    -- like any other, rather than either vanishing on the next tick or sitting
    -- there through the whole of the next wait, on top of the wait and
    -- spectating lines that exist to say the battle has not hung. Cleared here
    -- anyway, because the clock has to be put away and a `shown` that somehow
    -- survived would outlive the phase that owns it.
    self.shown = nil
    self.msgClock = nil
    -- ------- and `acted` is deliberately NOT cleared here
    --
    -- This used to reset it, on the reading that a menu about to open is a
    -- turn nobody has answered yet. It is not: the four clients leave the
    -- messages phase at their own pace -- each line is held until *that*
    -- player dismisses it -- so somebody who reads quickly commits while
    -- somebody else is still two lines behind, and the `act` that arrives
    -- meanwhile was thrown away by this clear the moment the slow reader
    -- finally reached their menu. The wait line then named a player who had
    -- already answered, for the rest of the turn.
    --
    -- The turn boundary is covered where the turn actually turns: `tryResolve`
    -- clears it on the host beside `pending`, and `applyTurn` clears it on
    -- every replayer -- above its seq-gap early return, so a turn that arrives
    -- out of order still resets the answers. Both of those happen once per
    -- turn, which is the thing being counted; this handover happens whenever a
    -- batch of messages runs out, which is not.
    -- ...on to whatever this batch was leading to -- **unless somebody still
    -- owes a send-out**, in which case the field is a monster short and there
    -- is no turn behind these messages to answer yet. The box is handed back to
    -- the wait line naming them (`waitLine` reads the same `awaiting` flag) and
    -- the grid stays shut until the send lands and the referee opens the turn
    -- for real. See `M:replaceHold`.
    if self:replaceHold() then
      self.phase = "wait"
    else
      self.phase = self.after or "choose"
    end
    -- ...and this is where the turn deadline starts, on the host. See
    -- `M:openTurn` for why it is stamped here and nowhere else.
    self:openTurn()
    -- ...and the countdown the *other three* read starts from the same event.
    -- It is a display of the host's budget, so it has to be measured from the
    -- moment the turn became answerable and not from the moment this particular
    -- client got round to answering -- see the tick in `tickStalls`. Reset on
    -- every client, host included, because the host is showing the same line.
    self.waitShown = 0
    -- ...and so are both halves of the "this wait has gone wrong" state, for
    -- the same reason: a new turn is a new wait, owed its own question if it
    -- too runs past the number it is showing (see `tickStalls`).
    --
    -- `wedged` is cleared here and not only inside `unwedge`, and that matters
    -- more than it looks: a client that flagged a wait and then recovered the
    -- ordinary way -- the host's `res` finally arriving -- would otherwise hold
    -- the flag for the rest of the battle, and the *next* snapshot it ever
    -- received, for any reason, would reopen a menu behind a playing batch.
    -- That is precisely the case `unwedge` promises cannot happen.
    self.wedgeAsked = nil
    self.wedged = nil
    -- ...and this is where the host-silence clock starts, too.
    --
    -- It measures a host that has stopped answering, so it has to be measured
    -- from the moment the host owes an answer -- the handover -- rather than
    -- from its last message. Ticked from the last `res` instead, it was
    -- counting the *narration* that message produced (a dozen lines at
    -- MSG_AUTO_ADVANCE apiece is twenty seconds) plus the deliberation after
    -- it, which together routinely exceed COOP_STALL_TIMEOUT on a perfectly
    -- healthy battle: the 75-versus-60 headroom the timeout is documented to
    -- have only exists if the 60 and the 75 start at the same event.
    self.hostClock = 0
    return
  end

  -- Your own monster comes back to the front the moment the turn is yours to
  -- decide, which is when you need to see it.
  if self.phase == "choose" or self.phase == "move"
     or self.phase == "target" then
    self.acting = nil
    self.hitSlot = nil
  end
  -- A replacement outranks the turn: this slot has nothing on the field, so
  -- there is no move for it to make until one is chosen.
  if self.replacing then return self:updateReplace(input) end
  -- ...and a run consent outranks whatever was underneath it, the same way and
  -- for the same reason: it is a question this player has to answer before the
  -- menu behind it means anything.
  --
  -- Placed **after** the messages branch above, which returns while a batch is
  -- still being read -- so an ask that arrives mid-narration is deferred to the
  -- handover rather than opening a picker over the top of a turn nobody has
  -- finished watching. (And if that turn's own `res` gets there first, it takes
  -- the ask down with it: see `playEvents`.)
  if self.runAsk then return self:updateRunAsk(input, dt) end

  -- Out of the fight, and so out of the decisions.
  --
  -- A player whose last monster fell has nothing to send out and nothing to
  -- act with -- the host already stops waiting on their slot, and files
  -- nothing for it. Without this they were still shown the command menu,
  -- picked a move, and were dropped into "wait" while the turn resolved
  -- around them: a menu that answers nothing, offered over and over, for the
  -- rest of a battle they are no longer in. Their side is still alive while
  -- their partner stands, so the right state is watching, not leaving.
  if self:spectating() then
    self.phase = "wait"
    return
  end

  if self.phase == "choose" then return self:updateCommand(input) end
  if self.phase == "move" then return self:updateMove(input) end
  if self.phase == "target" then return self:updateTarget(input) end
  if self.phase == "switch" then return self:updateSwitch(input) end
  if self.phase == "item" then return self:updateItem(input) end
  if self.phase == "item_party" then return self:updateItemParty(input) end
  if self.phase == "item_move" then return self:updateItemMove(input) end
  -- "wait" does nothing but let drainNet do its work
end

-- Who this client is waiting for, and how long it has been waiting.
--
-- Returns a name and the seconds left on that wait, or nil when nothing is
-- being waited on. Answered on every client from the field itself rather than
-- from the host's bookkeeping: the slot that owes an answer is marked on all
-- four copies, so all four can name the same person.
--
-- The clock each client shows is its own -- a replayer cannot read the host's
-- -- and all four start theirs on the **handover**, the moment the last of a
-- turn's messages is dismissed and the box is handed back. That is an event
-- every client reaches from its own copy of the same batch, which is why the
-- four numbers say the same thing rather than merely something similar.
-- Returns the **budget first** and the name second, and that order is load
-- bearing: callers ask `if self:waitingOn() then`, and a general wait has no
-- name to give -- so a signature that led with the name answered "no, nothing
-- is being waited for" in exactly the case where something was, and the clock
-- never started.
--
-- The general wait answers COOP_TURN_TIMEOUT on **every** client, and that is
-- honest again now that the host really enforces it (see `tickStalls`). It was
-- not, for one release: the only clock at that budget forfeited the host to
-- itself and never touched an idle player, so three of the four clients
-- counted down a number nothing would act on. What each client counts is still
-- its own -- a replayer cannot read the host's -- and all four start it at the
-- handover, which is the same event the host's own deadline is stamped at.
-- ------- is the field paused on somebody else's replacement?
--
-- True while a *refereed* fight is inside the replace phase and the seat being
-- asked is not ours. That is the one state where a batch of messages runs out
-- and there is still nothing to answer: the referee has not opened a turn, it
-- has asked one seat for a send-out, and it will not resolve anything until
-- that seat answers. Handing the command grid back here is the bug this exists
-- to close -- a player picking a move at a foe seat that is empty, whose choice
-- the referee refuses (`Battle:submitChoice` rejects a standing seat's answer
-- in the replace phase) and who is then left in a menu nothing will take.
--
-- Read off `sim:awaiting` rather than off `medReplaceWait` on purpose: the flag
-- is set by the `choose` row and cleared by `CoopSim:sendOut`
-- (src/CoopSim.lua:214) the moment the referee's `send` for that seat is
-- applied in `playEvents`, so the hold ends on the event that answers it and
-- needs no clearing of its own. `medReplaceWait` is the phase gate -- it keeps
-- this off the host-simulated path, where the identical `choose` row means
-- something the local host is already clocking (`tickStalls`) and where the
-- grid's behaviour is not this round's to change.
--
-- Never against our own seat: that one has `replacing`, which outranks the
-- phase entirely (see `update`).
function M:replaceHold()
  if not self.mediated then return false end
  if self.result or self.replacing then return false end
  if not self.medReplaceWait then return false end
  local pending = self.sim and self.sim:awaitingChoice()
  return (pending ~= nil and pending.index ~= self.mine)
end

function M:waitingOn()
  if self.result or self.replacing then return nil end
  local pending = self.sim and self.sim:awaitingChoice()
  if pending and pending.index ~= self.mine then
    return Config.COOP_CHOICE_TIMEOUT, (pending.name or "Someone")
  end
  if self.phase == "wait" then
    if self.mediated then
      return Config.BATTLE_CHOICE_TIMEOUT, nil
    end
    return Config.COOP_TURN_TIMEOUT, nil
  end
  return nil
end

-- ------- who has not answered yet
--
-- Which slots owe this turn an action, by name. Every client can answer it,
-- because every client hears every `act` -- the relay fans them out to all
-- four and only the host used to read them (see `drainNet`).
--
-- Never this client's own slot. You are not waiting for yourself: your own
-- action is filed the moment you commit, and a wait line that named the
-- person reading it would be a bug report rather than reassurance. (The host's
-- auto-pick makes no such exclusion, and must not: a host that has not
-- answered is exactly what the deadline is for. This is a *display* rule.)
--
-- NPCs are skipped (`slot.owner ~= nil`): their move is chosen inside
-- `tryResolve` and there is nobody to wait for. So are slots that are down --
-- the host stops waiting on those too.
function M:missingActors()
  local out = {}
  if not self.sim then return out end
  local acted = self.acted or {}
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner ~= nil and slot.index ~= self.mine
       and not self.sim:isDown(slot) and not acted[slot.index] then
      out[#out + 1] = tostring(slot.name or "Someone")
    end
  end
  return out
end

-- This slot has answered for this turn, on whichever client noticed.
--
-- Lazily built, because every reader tolerates its absence and the suite
-- builds clients straight out of `setmetatable` without one.
function M:markActed(index)
  if not index then return end
  self.acted = self.acted or {}
  self.acted[index] = true
end

function M:unmarkActed(index)
  if not index then return end
  self.acted = self.acted or {}
  self.acted[index] = false
end

-- The line a wait puts in the message box once it has gone on long enough to
-- need explaining. Nil until then, because a clock that flashed up on every
-- ordinary turn would be noise rather than reassurance.
--
-- ------- the name **and** the number
--
-- The general wait spent one release saying only who, and the reason was
-- sound at the time: `tickStalls` acted on that budget on the host alone, so a
-- replayer counted 60 down to 0 and then sat on "(0)" for as long as the wait
-- lasted, saying the battle had hung when it had not.
--
-- The deadline is real on every slot now -- the host auto-picks for anybody
-- still deciding at COOP_TURN_TIMEOUT, itself included -- so the number is
-- honest again and comes back beside the name. Each of the four ticks its own
-- `waitShown`, and all four reset it at the **handover**: the moment the turn's
-- last message is dismissed and the menu opens. That is the same event
-- `openTurn` stamps the host's deadline at, so the number a player reads is a
-- promise that something happens around then, and that promise is now kept.
function M:waitLine()
  local budget, who = self:waitingOn()
  if not budget then return nil end
  local spent = self.waitShown or 0
  if spent < Config.COOP_WAIT_HINT then return nil end
  local left = math.max(0, math.ceil((budget or 0) - spent))
  -- Split so a full-length name still fits. The box is eighteen characters
  -- wide, a trainer name is up to ten, and "<NAME> is choosing... (30)" on one
  -- line ran off the right edge -- which is how a clipped line gets shipped:
  -- it looks fine for every short name anybody tests with.
  if who then return ("%s is\nchoosing... (%d)"):format(who, left) end
  local missing = self:missingActors()
  if #missing > 0 then
    local name = missing[1]:sub(1, Config.NAME_MAX)
    -- Gen1 font has no '+'; use " &N" so the wait line stays drawable.
    local tail = (#missing > 1) and (" &" .. (#missing - 1)) or ""
    local clock = (" (%d)"):format(left)
    if #name + 3 + #tail + #clock > 18 then tail = "" end
    if #name + 3 + #clock > 18 then clock = "" end
    return ("Waiting for\n%s...%s%s"):format(name, tail, clock)
  end
  -- Nobody nameable -- an older host that sends no `act` this client can read,
  -- or a turn whose last answer is already in flight. The number still stands
  -- on its own: the deadline is what makes the box worth reading, and a client
  -- that cannot name anybody is exactly the one that most needs telling the
  -- wait is bounded. No host special case any more -- there is one budget and
  -- one mechanism behind it now, so there is one line.
  return ("Waiting for the\nothers... (%d)"):format(left)
end

-- Has this player anything left to do?
--
-- Down *and* not being asked for a replacement means down for good: a slot
-- with a reserve is `replacing` instead, and one that is merely waiting on
-- somebody else is not down at all. `gone` counts too -- a forfeited slot is
-- as out as an empty one.
function M:spectating()
  if self.result then return false end
  if self.replacing then return false end
  -- Guarded on the field, not only on the slot: this is read from `draw`,
  -- which runs every frame including the ones where the battle is being torn
  -- down, and a nil field there would take the screen out through the pcall
  -- that guards drawing rather than through anything that could report it.
  if not self.sim then return false end
  local slot = self:mySlot()
  return slot ~= nil and self.sim:isDown(slot)
end

function M:liveMoves()
  if self.medMoveList then return self.medMoveList end
  local slot = self:mySlot()
  local battler = slot and slot.battler
  return (battler and battler.curMoves) or {}
end

function M:hasLivePP()
  if self.medMoveList then
    for _, move in ipairs(self.medMoveList) do
      if (move.pp or 0) > 0 then return true end
    end
    return false
  end
  local slot = self:mySlot()
  return self.sim:hasPP(slot and slot.battler)
end

-- Classic Gen 1 order (row-major): FIGHT SWITCH / ITEM RUN.
M.COMMANDS = { "FIGHT", "SWITCH", "ITEM", "RUN" }

-- How many columns the command menu the player is looking at is laid out in.
--
-- Asked of the renderer rather than restated here, so the cursor and the paint
-- cannot drift: `Battlefield.bandGridCols` is the same rule `drawCommandGrid`
-- itself uses to place the slabs. Only the battlefield path asks -- the classic
-- 160×144 chrome and Gen 2 draw `drawCommand`'s own 2×2 and always get 2.
--
-- pcall-guarded with the classic answer as the fallback: an older Battlefield
-- beside this screen has no such export, and a band that has to guess is better
-- off guessing the layout the GB fallback would draw. Nothing to remediate --
-- `drawModernBand` already declines the widgets in that build.
function M:commandCols()
  if not self:usesBattlefield() then return 2 end
  local cols = Battlefield and Battlefield.bandGridCols
  if type(cols) ~= "function" then return 2 end
  local ok, got = pcall(cols, #M.COMMANDS)
  got = ok and math.floor(tonumber(got) or 0) or 0
  if got < 1 then return 2 end
  return got
end

function M:updateCommand(input)
  self.commandIndex = self.commandIndex or 1
  local moved = gridPress(self.commandIndex, #M.COMMANDS, input, self:commandCols())
  if moved then
    self.commandIndex = moved
  elseif input:wasPressed("a") then
    local command = M.COMMANDS[self.commandIndex]
    if command == "FIGHT" then
      self.moveIndex = 1
      self.phase = "move"
    elseif command == "SWITCH" then
      self.switchIndex = 1
      self.phase = "switch"
    elseif command == "ITEM" then
      self.itemIndex = 1
      self.phase = "item"
    elseif command == "RUN" then
      -- Three different questions behind one command.
      --
      -- Against a **partied wild** (`coop_wild`) it is solo-wild semantics:
      -- either player flees unilaterally. No COOP_RUN_ASK / partner consent —
      -- the choice goes straight to the referee (or host-sim commit).
      --
      -- Against a **trainer** it is the original's question, and the original's
      -- answer: you cannot run from a trainer battle. Filed as an action rather
      -- than answered here, so the refusal arrives in the turn's own message
      -- flow and costs the turn exactly as the original's does.
      --
      -- Against **two other players** it is a question Gen 1 never had to ask,
      -- and the answer is neither the refusal nor a unilateral escape: leaving
      -- ends the battle for four people and books the pair who left a ranked
      -- loss, so the other half of that pair is asked first (M:askToRun).
      -- Nothing is committed until they answer -- see the state machine there.
      if self.mode == "coop_wild" then
        self:commit({ slot = self.mine, kind = "run" })
      elseif self:partyBattle() then
        self:askToRun()
      else
        self:commit({ slot = self.mine, kind = "run" })
      end
    end
  end
end

-- ------- moves that are aimed at nobody
--
-- Three effects that a zero-power primary record does not tell apart from a
-- Swords Dance, because each of them reads the monster the player picked:
--
--   * HAZE_EFFECT (MoveEffects.lua:234) walks `{ user, target }` and resets
--     both sides' stages, screens and counters;
--   * CONVERSION_EFFECT (MoveEffects.lua:277) copies the *target's* types
--     onto the user, and fails outright against a mid-Fly target;
--   * TRANSFORM_EFFECT (MoveEffects.lua:292) becomes the target -- its
--     species, its sprite, its stats and its moves.
--
-- So they keep the picker even though the predicate below would clear them.
local READS_ITS_TARGET = {
  HAZE_EFFECT = true, CONVERSION_EFFECT = true, TRANSFORM_EFFECT = true,
}

-- Does this move have to be aimed at somebody?
--
-- The question the move menu is really asking, and the reason "Attack who?"
-- used to open on a Swords Dance: a self-only move was made to pick one of two
-- foes for no reason, and whichever the player chose changed nothing.
--
-- Answered from the engine's own bookkeeping rather than from a list of move
-- names. A zero-power move whose merged `move_effects` record is `primary` and
-- is **not** `accuracyChecked` is self-targeting by construction: pokered's
-- ACC_CHECKED set (MoveEffects.lua:377-388) is exactly the status handlers
-- that call MoveHitTest against the other side -- Growl, Thunder Wave, Toxic,
-- Sleep Powder, Leech Seed, Disable, Confuse Ray -- and the comment beside it
-- says the rest of `MoveEffects.primary` "is self-targeting and never rolls
-- accuracy". That leaves Swords Dance, Rest, Recover, Light Screen, Reflect,
-- Mist, Substitute, Focus Energy and the rest of their family.
--
-- Conservative in every other direction, because a picker offered needlessly
-- costs a button press and one skipped wrongly costs a turn: anything with
-- power, anything whose record is missing, and every `kind == "full"` record
-- (Roar and Whirlwind, Mimic, Metronome -- effects that run their own flow and
-- cannot be classified this way) keeps the picker.
--
-- `data` is reached through a guard rather than off `self.game` directly: every
-- other nil path in here lands on `true` -- no move, no record, no effect all
-- keep the picker -- and this was the one that threw instead, on a screen built
-- without a game (which is how the suite builds one) or during a teardown that
-- has already let go of it.
function M:needsTarget(moveInst)
  local data = self.game and self.game.data or {}
  local def = moveInst and (data.moves or {})[moveInst.id]
  if not def then return true end
  if (def.power or 0) > 0 then return true end
  local record = (data.move_effects or {})[def.effect]
  if not record then return true end
  if record.kind ~= "primary" then return true end
  if record.accuracyChecked then return true end
  if READS_ITS_TARGET[def.effect] then return true end
  return false
end

function M:updateMove(input)
  local moves = self:liveMoves()
  if #moves == 0 then return end
  -- One name per row (drawMoves), so UP/DOWN step the list. LEFT/RIGHT stay
  -- aliases -- same habit as the target column -- and both ends clamp.
  local step = 0
  if input:wasPressed("up") or input:wasPressed("left") then step = -1
  elseif input:wasPressed("down") or input:wasPressed("right") then step = 1 end
  if step ~= 0 then
    self.moveIndex = math.max(1, math.min(#moves, (self.moveIndex or 1) + step))
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    -- Nothing to aim at yet.
    --
    -- A slot whose monster has fainted is *down* until its trainer sends the
    -- next one out. On the host-sim path that pauses the field; on the
    -- mediated path their replace and your fight share one choice window, so
    -- `targetsFor` still names those seats when the side has party left.
    -- Only a wiped side returns nothing here -- refused with a sentence rather
    -- than an empty picker that no key gets out of.
    --
    -- Checked ahead of the self-move shortcut below, and for both of them: a
    -- Swords Dance committed during that window would still carry a target
    -- slot, and there is none to name.
    local targets = self.sim:targetsFor(self:mySlot())
    if #targets == 0 then
      self.phase = "messages"
      self.after = "choose"
      self:say("Wait for the other\ntrainer!")
      return
    end
    -- Every aimable seat is mid-replace (empty on the field, party still
    -- alive): skip "Attack who?" -- the player cannot see a mon to pick, and
    -- the hub retargets onto whoever they send out. Committing is what breaks
    -- the old deadlock of looping the wait line while the referee waited on us.
    local anyUp = false
    for _, entry in ipairs(targets) do
      if not self.sim:isDown(entry) then anyUp = true; break end
    end
    if not anyUp then
      return self:commit({ slot = self.mine, move = self.moveIndex,
                           target = targets[1].index })
    end
    -- A move that is aimed at nobody is committed on the spot.
    --
    -- The target that travels with it is the first living opponent, and it is
    -- **semantically inert**: `CoopSim.runAction` passes the chosen slot
    -- through to `performMove`, and a self-targeting effect record never reads
    -- it. So the wire shape is the one it always was, the sim resolves the
    -- same turn it would have, and the player is spared a question whose
    -- answer could not matter.
    --
    -- Gated on the battler having PP left, and that is not belt and braces:
    -- Gen 1's rule is all-or-nothing, so a monster with every move empty has
    -- Struggle substituted for whatever it picked (`CoopSim.runAction`), and
    -- Struggle *does* read its target -- it is an ordinary attack with recoil.
    -- Shortcutting on the chosen move's own record would therefore aim a real
    -- attack at the first living opponent without asking, on the one turn a
    -- player most wants to choose.
    local pick = moves[self.moveIndex]
    local mine = self:mySlot()
    local hasPP = self:hasLivePP()
    if pick and hasPP and not self:needsTarget(pick) then
      local first = targets[1]
      return self:commit({ slot = self.mine, move = self.moveIndex,
                           target = first.index })
    end
    self.targetIndex = 1
    self.phase = "target"
  end
end

-- The mons this trainer could send out instead: alive, and not the one
-- already standing there.
function M:benchOf(slot)
  local out = {}
  for i, mon in ipairs(slot.party or {}) do
    if i ~= slot.active and (mon.hp or 0) > 0 then
      out[#out + 1] = { index = i, mon = mon }
    end
  end
  return out
end

-- Choosing who comes out after a faint.
--
-- The same bench the SWITCH command shows, with one difference that matters:
-- it cannot be cancelled. A monster has fainted and its slot is empty -- there
-- is no "never mind" available, so B does nothing here rather than dropping
-- the player back into a turn they cannot take.
function M:updateReplace(input)
  local slot = self.sim:slot(self.mine)
  local bench = self:benchOf(slot)
  if #bench == 0 then
    self.replacing = nil
    return
  end
  self.switchIndex = math.min(self.switchIndex or 1, #bench)
  local moved = listPress(self.switchIndex, #bench, input)
  if moved then
    self.switchIndex = moved
  elseif input:wasPressed("a") then
    self.replacing = nil
    self:sendAction({ slot = self.mine, kind = CoopSim.REPLACE,
                      index = bench[self.switchIndex].index })
  end
end

function M:updateSwitch(input)
  local bench = self:benchOf(self:mySlot())
  if #bench == 0 then
    -- Said out loud and routed back through the message flow rather than
    -- bounced silently: a menu that opens and closes on the same button looks
    -- like a broken screen, and gives a player mashing A no way out.
    self:say("There's no one\nelse to send out!")
    self.phase = "messages"
    self.after = "choose"
    return
  end
  local moved = listPress(self.switchIndex or 1, #bench, input)
  if moved then
    self.switchIndex = moved
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    self:commit({ slot = self.mine, kind = "switch",
                  index = bench[self.switchIndex].index })
  end
end

-- What is in the bag that can be used in a battle at all.
--
-- Mediated fights follow the uploaded bag sheet (same set the hub proves).
-- Host-sim fights still read the live save, but only ids BattleSim knows.
function M:usableItems()
  if self.itemList then return self.itemList end
  local out = {}
  local inventory = (self.game.save and self.game.save.inventory) or {}
  local items = self.game.data.items or {}
  if self.mediated and type(self.bagSheet) == "table" then
    for id, bagCount in pairs(self.bagSheet) do
      local effect = Mediated.itemIsBattleUsable(id, self.game)
      if effect and (bagCount or 0) > 0 then
        local inv = inventory[id] or 0
        local count = effect.noConsume
          and ((inv >= 1 or bagCount >= 1) and 1 or 0)
          or math.min(bagCount, inv)
        if count > 0 then
          local def = items[id]
          out[#out + 1] = {
            id = id, name = (def and def.name) or id, count = count, effect = effect,
          }
        end
      end
    end
  else
    for id, count in pairs(inventory) do
      if type(id) == "string" and (count or 0) > 0 then
        local effect = Mediated.itemIsBattleUsable(id, self.game)
        if effect then
          local def = items[id]
          out[#out + 1] = {
            id = id, name = (def and def.name) or id, count = count, effect = effect,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  self.itemList = out
  return out
end

function M:updateItem(input)
  local items = self:usableItems()
  if #items == 0 then
    self:say("You have nothing\nto use!")
    self.phase = "messages"
    self.after = "choose"
    return
  end
  local moved = listPress(self.itemIndex or 1, #items, input)
  if moved then
    self.itemIndex = moved
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    local pick = items[self.itemIndex]
    local Effects = need("BattleSim/Effects")
    local effect = pick.effect or Effects.itemEffect(pick.id)
    if self.mediated then
      -- Parity with MediatedBattle: party / move pickers for heals, Revive,
      -- Ether, vitamins; balls/doll/flute/X-items commit without a bench pick.
      self.itemPick = pick
      local seat = self:mySlot()
      local active = (seat and seat.active) or 1
      if not effect then
        self:commitMediatedItem(active, nil)
      elseif effect.ball or effect.pokeDoll or effect.pokeFlute then
        self:commitMediatedItem(nil, nil)
      elseif effect.activeOnly then
        self:commitMediatedItem(active, nil)
      elseif effect.needsMove or effect.needsParty or effect.faintedOnly then
        self.switchIndex = 1
        self.phase = "item_party"
      else
        self:commitMediatedItem(active, nil)
      end
    else
      -- Host-sim: debit on commit; owed refunds if the turn never resolves.
      local inventory = self.game.save and self.game.save.inventory
      if inventory and (inventory[pick.id] or 0) > 0
         and not (effect and effect.noConsume) then
        inventory[pick.id] = inventory[pick.id] - 1
        if inventory[pick.id] <= 0 then inventory[pick.id] = nil end
        self.owed = pick.id
      end
      self.itemList = nil
      self:commit({ slot = self.mine, kind = "item", item = pick.id })
    end
  end
end

-- Own party rows for mediated item targeting (1-based party index).
function M:itemPartyRows()
  local seat = self:mySlot()
  local party = (seat and seat.party) or {}
  local active = (seat and seat.active) or 1
  local out = {}
  for i, mon in ipairs(party) do
    out[#out + 1] = {
      index = i,
      label = tostring(mon.nickname or mon.species or ("#" .. i)),
      fainted = (mon.hp or 0) <= 0,
      active = i == active,
    }
  end
  return out
end

function M:updateItemParty(input)
  local rows = self:itemPartyRows()
  if #rows == 0 then
    self.phase = "item"
    return
  end
  local moved = listPress(self.switchIndex or 1, #rows, input)
  if moved then
    self.switchIndex = moved
  elseif input:wasPressed("b") then
    self.itemPick = nil
    self.phase = "item"
  elseif input:wasPressed("a") then
    local row = rows[self.switchIndex]
    local effect = self.itemPick and self.itemPick.effect
    if effect and effect.faintedOnly and not row.fainted then
      self:say("It won't have\nany effect.")
      return
    end
    if effect and effect.needsMove then
      self.moveIndex = 1
      self.itemPartyIndex = row.index
      self.phase = "item_move"
      return
    end
    self:commitMediatedItem(row.index, nil)
  end
end

function M:updateItemMove(input)
  local seat = self:mySlot()
  local party = (seat and seat.party) or {}
  local mon = party[self.itemPartyIndex or (seat and seat.active) or 1]
  local moves = (mon and mon.moves) or {}
  if #moves == 0 then
    self.phase = "item_party"
    return
  end
  local moved = listPress(self.moveIndex or 1, #moves, input)
  if moved then
    self.moveIndex = moved
  elseif input:wasPressed("b") then
    self.phase = "item_party"
  elseif input:wasPressed("a") then
    self:commitMediatedItem(self.itemPartyIndex or (seat and seat.active) or 1,
                            self.moveIndex)
  end
end

-- Mediated item commit: debit after hub `item` event; partySlot is 1-based.
function M:commitMediatedItem(partyIndex, moveIndex)
  local pick = self.itemPick
  if not pick then return false end
  local effect = pick.effect
  local bagCount = self.bagSheet and self.bagSheet[pick.id] or 0
  if bagCount < 1 and not (effect and effect.noConsume) then
    self:say("You have nothing\nto use!")
    self.phase = "choose"
    self.itemPick = nil
    return false
  end
  if not (effect and effect.noConsume) then
    local inventory = self.game.save and self.game.save.inventory
    if not (inventory and (inventory[pick.id] or 0) > 0) then
      self:say("You have nothing\nto use!")
      self.phase = "choose"
      self.itemPick = nil
      return false
    end
  end
  self.pendingItem = pick.id
  self.pendingItemSlot = partyIndex
  self.itemList = nil
  self.itemPick = nil
  local fields = {
    slot = self.mine, kind = "item", item = pick.id,
  }
  if partyIndex then fields.partySlot = partyIndex - 1 end
  if moveIndex then fields.move = moveIndex - 1 end
  if not self:commit(fields) then
    self.pendingItem = nil
    self.pendingItemSlot = nil
    return false
  end
  return true
end

function M:updateTarget(input)
  local targets = self.sim:targetsFor(self:mySlot())
  -- The picker was opened on a target that has since fainted or left. The
  -- early return this used to be swallowed B as well as everything else, so
  -- the player sat on a blank "Attack who?" with no key that did anything --
  -- a wedged battle for all four, from one monster fainting at the wrong
  -- moment. Back out instead; the command menu is still answerable.
  if #targets == 0 then
    self.phase = "choose"
    return
  end
  if self.targetIndex > #targets then self.targetIndex = #targets end
  -- Gen1 battlefield: d-pad walks a field cursor (wraps). Classic / Gen2
  -- keeps the clamped list picker (LEFT/RIGHT stay aliases for UP/DOWN).
  local step = 0
  if input:wasPressed("up") or input:wasPressed("left") then step = -1
  elseif input:wasPressed("down") or input:wasPressed("right") then step = 1 end
  if step ~= 0 then
    if self:usesBattlefield() then
      local nextIdx = Battlefield.nextTarget(targets, self.targetIndex or 1, step)
      if nextIdx then self.targetIndex = nextIdx end
    else
      self.targetIndex =
        math.max(1, math.min(#targets, self.targetIndex + step))
    end
  elseif input:wasPressed("b") then
    self.phase = "choose"
  elseif input:wasPressed("a") then
    local target = targets[self.targetIndex]
    self:commit({ slot = self.mine, move = self.moveIndex, target = target.index })
  end
end

-- ------- RUN, in a battle where the other side is people
--
-- **A party cannot leave one of these on one person's say-so.** Two players
-- share a side, share the loss, and share the ranked points that go with it --
-- so one of them pressing RUN is a proposal, not a decision, and the whole of
-- this section is the shape of that proposal.
--
-- Four states, and every one of them is torn down by something that cannot be
-- forgotten:
--
--   asking    -- the asker, waiting. Nothing has been committed: their slot
--                still owes the turn an action, so the deadline treats them
--                exactly as it treats anybody who has not answered.
--   deciding  -- the partner, holding a two-answer picker over whatever they
--                were doing. Offered to a partner who is *spectating* too:
--                their monsters are gone, their half of the decision is not.
--   fleeing   -- the answer was yes; the host's closing events are on their way.
--   refused   -- the answer was no; a line to read, and then the command menu
--                back exactly as it was left, with the turn's own clock still
--                running.
--
-- ------- what rides on the wire, and why the hub never had to learn it
--
-- Two payload kinds inside the battle's existing relay envelope
-- (Wire.COOP_RUN_ASK / Wire.COOP_RUN_ANSWER). Both hubs forward a co-op payload
-- unread -- shape is the only thing they judge -- so this needed no hub change
-- on either side, and a client built before it drops both through its inbound
-- dispatch without a branch. A mixed-version battle therefore degrades to
-- today's behaviour rather than to a hang: the ask is never answered, and the
-- turn deadline files it as a refusal like any other.
--
-- Neither message names a slot. Who asked is the `from` the hub stamps, and
-- which slot that is, is a fact the receiving client reads off its own copy of
-- the field -- the same rule the `act` handler follows, and for the same
-- reason: a slot named in a payload is a slot a modified client could claim.
--
-- ------- and the host is still the only one that may end a battle
--
-- A yes does not end anything by itself. It is *reported*, and the host
-- resolves the flee -- and only after checking it saw the ask that a yes is an
-- answer to, so a modified client cannot forfeit its partner's battle by
-- posting consent nobody asked for.

-- Is this a battle between four players, or two players and a trainer?
--
-- Answered off the field rather than off the trainer record, because that is
-- the description all four clients were built from: a co-op battle against an
-- NPC carries two ownerless slots and a party battle carries none.
-- `self.trainer` would be a weaker test -- a script-driven battle need not name
-- a trainer at all -- and this is the question the run rule turns on.
function M:partyBattle()
  local slots = (self.sim and self.sim.slots) or {}
  if #slots == 0 then return false end
  for _, slot in ipairs(slots) do
    if slot.owner == nil then return false end
  end
  return true
end

-- The other player on this slot's side, if there is still somebody there.
--
-- "Still there" means **present**, not standing. A partner whose last monster
-- fell is spectating -- they have a screen, they are watching this battle, and
-- half of the decision to leave it is theirs exactly as it was before. A
-- partner whose client has gone is the other thing entirely: there is nobody to
-- ask, so this answers nil and the ask is skipped rather than waited on.
function M:partnerOf(slot)
  if not (slot and self.sim) then return nil end
  for _, other in ipairs(self.sim.slots or {}) do
    if other.index ~= slot.index and other.side == slot.side
       and other.owner ~= nil and not other.gone then
      return other
    end
  end
  return nil
end

-- Which slot a player id is sitting in, on this client's copy of the field.
function M:slotOwnedBy(id)
  if id == nil or not self.sim then return nil end
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner ~= nil and slot.owner == id then return slot end
  end
  return nil
end

-- Two answers, laid out in the box four commands normally sit in. Published so
-- the suite can assert the picker without a graphics device.
local RUN_ANSWERS = { "YES", "NO" }
M.RUN_ANSWERS = RUN_ANSWERS

-- ------- and the cursor starts on **NO**, which is the whole safety of it
--
-- Every other picker on this screen opens on the answer a player most often
-- wants. This one opens on the answer that costs nothing, because of *when* it
-- appears: a consent prompt lands at the messages->choose handover, which is
-- the exact moment all four players are holding A to get through the last
-- turn's narration. Opening on YES would mean one already-travelling press
-- forfeits the battle for four people and books two ranked losses -- a decision
-- nobody consciously made, and one that cannot be taken back.
--
-- So the button that is already down answers "no", which is the answer that
-- leaves everything exactly as it was. Saying yes takes a direction and then a
-- press, which is what a deliberate decision looks like.
local RUN_DEFAULT = 2   -- "NO"
M.RUN_DEFAULT = RUN_DEFAULT

-- ------- and on a refereed fight the partner cannot be asked at all
--
-- **This is a real loss, so it is written down rather than worked around.** The
-- ask and the answer ride `mmo.coop_relay`, and both hubs stop forwarding a
-- co-op payload the moment they start refereeing the fight (src/Hub.lua's
-- COOP_RELAY handler) -- so on the mediated path there is no channel left to put
-- a question on. There is no room in the mmo.battle_* vocabulary for one either:
-- a choice says what was pressed, and "may I?" is not a choice.
--
-- What is kept is the half of the consent flow that was protecting against an
-- accident rather than against a partner: the picker, and its cursor starting on
-- NO. See RUN_DEFAULT -- the prompt lands at the exact moment all four players
-- are holding A through the last turn's narration, and one already-travelling
-- press must not forfeit a ranked battle. So the player is asked to confirm,
-- with the safe answer under the cursor, and their partner is not consulted.
--
-- Restoring the veto is an additive wire change (a run-consent pair inside the
-- battle vocabulary, refereed like everything else) and belongs with whoever
-- teaches the intermediator about it.
function M:mediatedRunAsk()
  local partner = self:partnerOf(self:mySlot())
  self.runAsk = { role = "confirming", name = partner and partner.name,
                  index = RUN_DEFAULT, clock = 0 }
  return true
end

-- Ask the partner. Commits nothing — except `coop_wild`, which never asks:
-- flee is unilateral (solo-wild), so this routes to a run choice instead.
function M:askToRun()
  if self.mode == "coop_wild" then
    return self:commit({ slot = self.mine, kind = "run" })
  end
  if not self:partyBattle() then return false end
  if self.mediated then return self:mediatedRunAsk() end
  local partner = self:partnerOf(self:mySlot())
  self.runAsk = { role = "asking", slot = partner and partner.index,
                  name = partner and partner.name }
  if self.net then self.net.send({ t = Wire.COOP_RUN_ASK }) end
  -- The host hears its own ask directly rather than off the wire: the relay
  -- fans a message out to everyone *except* its sender, so a host that waited
  -- to receive its own ask would wait forever.
  if self.host then self:hostRunAsk(self.mine) end
  return true
end

-- The partner's answer, sent and -- when this client is also the host --
-- acted on in the same breath, for the reason above.
function M:answerRun(ok)
  if not self.runAsk then return false end
  ok = ok and true or false
  -- A refereed fight has one answer to give and one place to give it: the run is
  -- a choice like any other, and what it costs -- one side leaving loses the
  -- battle with reason `run` -- is the intermediator's policy rather than this
  -- screen's. A no is simply the prompt coming down.
  if self.mediated then
    self.runAsk = nil
    if not ok then return true end
    self.runAsk = { role = "fleeing" }
    self:markActed(self.mine)
    self.phase = "wait"
    return self:sendMediatedChoice({ kind = "run" })
  end
  -- A yes leaves this player watching for the host's closing events; a no puts
  -- them straight back where they were, because nothing about their own turn
  -- was ever touched.
  self.runAsk = ok and { role = "fleeing" } or nil
  if self.net then
    self.net.send({ t = Wire.COOP_RUN_ANSWER, ok = ok })
  end
  if self.host then self:hostRunAnswer(self.mine, ok) end
  return true
end

-- The host, noting an ask.
--
-- Recorded rather than acted on, because the thing that acts on it is the
-- answer -- with one exception, which is the whole reason this returns
-- something: a player whose partner is **gone** has nobody to get permission
-- from, and holding them in a battle until a disconnected client answers would
-- be the deadlock this consent flow exists to avoid. They leave immediately.
function M:hostRunAsk(index)
  if not (self.host and self.sim) or self.result then return false end
  if not self:partyBattle() then return false end
  local slot = self.sim:slot(index)
  if not (slot and slot.owner ~= nil and not slot.gone) then return false end
  self.runAsks = self.runAsks or {}
  self.runAsks[index] = true
  if not self:partnerOf(slot) then return self:resolveFlee(index) end
  return true
end

-- The host, hearing an answer.
--
-- A no is nothing to the host: the asker closes their own wait on the same
-- message, and no turn state was ever written. A yes is checked against the ask
-- it claims to answer -- the answerer's partner must be a slot this host
-- actually saw ask, on this turn -- and only then does the party leave.
function M:hostRunAnswer(index, ok)
  if not (self.host and self.sim) or self.result then return false end
  if not ok then return false end
  local slot = self.sim:slot(index)
  local partner = slot and self:partnerOf(slot)
  if not (partner and (self.runAsks or {})[partner.index]) then
    mod.log:warn("a co-op run answer arrived with no ask behind it, so it is "
      .. "ignored; the battle carries on and whoever wanted to leave can pick "
      .. "RUN again")
    return false
  end
  return self:resolveFlee(partner.index)
end

-- The party leaves, and the battle ends for all four.
--
-- Broadcast as an ordinary resolved batch -- a numbered `res` with the field's
-- signature on it -- so the three replayers apply it through exactly the path
-- every turn takes. The `over` event inside it is the *same* event a knockout
-- produces, which is what makes `resultFor` answer "loss" on both clients that
-- left and "win" on both they left, and the ranked report that follows is the
-- one that was already there. Nothing new reaches the outcome vocabulary.
--
-- No action is resolved, so nothing is spent: an item paid for on the turn that
-- was being decided is still owed, and `refundUnspent` gives it back on the way
-- out.
function M:resolveFlee(index)
  if not (self.host and self.sim) or self.result then return false end
  -- Not on a refereed fight: this broadcasts a resolved batch, which is the one
  -- thing a mediated host may not do. Unreachable today -- `askToRun` never
  -- reaches here and the relay carries no consent -- and guarded anyway, because
  -- what it would produce is four clients ending a battle the referee is still
  -- running.
  if self.mediated then return false end
  local slot = self.sim:slot(index)
  if not (slot and slot.side) then return false end

  local events = {}
  events[#events + 1] = { kind = "msg",
    text = (slot.name or "Someone") .. "'s party\nfled the battle!" }
  if not self.sim:fled(slot.side, function(e) events[#events + 1] = e end) then
    return false
  end

  -- The turn that was being decided is void, and everything that belonged to it
  -- goes with it -- including the deadline, which has nothing left to enforce.
  self.pending = {}
  self.acted = nil
  self.runAsks = nil
  self.turnOpened = nil

  self.seq = (self.seq or 0) + 1
  if self.net then
    self.net.send({ t = "res", seq = self.seq, sig = self.sim:signature(),
                    events = events })
  end
  self:playEvents(events)
  return true
end

-- The prompt and the wait, driven as a vertical YES/NO list -- same box as
-- every other picker on this screen.
function M:updateRunAsk(input, dt)
  local ask = self.runAsk
  if not ask then return end
  -- Ticked for every state, and counted from the first frame this prompt is
  -- actually being *driven* -- which is not the frame it arrived, if it arrived
  -- behind a batch of messages (see the branch order in `update`).
  ask.clock = (ask.clock or 0) + (dt or 0)

  -- "confirming" is the mediated path's own question (see `mediatedRunAsk`) and
  -- is driven by exactly the same two answers, the same safe default and the
  -- same settle floor -- only who is being asked differs, and that is a fact
  -- about the words on the box rather than about the picker.
  if ask.role == "deciding" or ask.role == "confirming" then
    ask.index = ask.index or RUN_DEFAULT
    local moved = listPress(ask.index, #RUN_ANSWERS, input)
    if moved then
      ask.index = moved
      return
    end
    -- ------- and no button counts until the box has been on screen
    --
    -- The same floor a freshly printed line gets (MSG_MIN_DWELL), for the same
    -- reason and against a worse consequence. This prompt opens at the handover
    -- with A held down; without a floor the press that dismissed the last line
    -- of narration would also answer a question the player has not seen yet.
    -- A quarter of a second is longer than any button edge and shorter than any
    -- deliberate press, so it costs a deciding player nothing.
    --
    -- The cursor is exempt: moving it is not an answer, and a player who
    -- pre-positions on YES during the floor and then presses A has made exactly
    -- the two-step decision this is asking for.
    if ask.clock < MSG_MIN_DWELL then return end
    if input:wasPressed("a") then
      self:answerRun(ask.index == 1)
    elseif input:wasPressed("b") then
      -- B backs out of every other picker on this screen, and backing out of
      -- "shall we leave?" is saying no.
      self:answerRun(false)
    end
    return
  end

  -- "asking" and "fleeing" are ended by the message that answers them, never
  -- by a button: there is nothing here for a press to mean. "refused" is a line
  -- to read, and it is read the way every other line on this screen is -- a
  -- floor before a press counts, and an auto-advance behind it (MSG_MIN_DWELL).
  --
  -- Deliberately **not** routed through the message queue, which is what would
  -- otherwise have said this: reaching the messages phase would hand the box
  -- back through `openTurn` on the way out, and re-arm the very turn deadline
  -- this refusal must leave running.
  if ask.role ~= "refused" then return end
  if ask.clock >= MSG_MIN_DWELL
     and (input:wasPressed("a") or input:wasPressed("b")) then
    self.runAsk = nil
  elseif ask.clock > MSG_AUTO_ADVANCE then
    self.runAsk = nil
  end
end

function M:drawRunAsk()
  local ask = self.runAsk
  if not ask then return end
  local name = ask.name
  if ask.role == "confirming" then
    -- Its own words, because the honest sentence is different: nobody is being
    -- asked for permission, and a title that named the partner would be
    -- promising a veto they are not being given.
    return self:drawList(RUN_ANSWERS, ask.index or RUN_DEFAULT, "RUN AWAY?")
  end
  if ask.role == "deciding" then
    -- Short on purpose: the title row is one line of the box, and at NAME_MAX
    -- "%s: RUN?" is eighteen columns exactly.
    return self:drawList(RUN_ANSWERS, ask.index or RUN_DEFAULT,
      ((name or "They") .. ": RUN?"))
  end
  if ask.role == "refused" then
    return self:drawText((name or "They") .. " says\nNO!")
  end
  if ask.role == "fleeing" or not name then
    return self:drawText("Getting away...")
  end
  return self:drawText("Asking " .. name .. "\nto RUN...")
end

-- ------- one turn, across four clients

-- This client has chosen. The host files it; everybody else posts it and waits.
-- Send an action that is not part of a turn.
--
-- A replacement is answered immediately rather than collected with everybody
-- else's choices: the turn is already paused waiting for it, and holding it
-- back would deadlock the pause against itself.
function M:sendAction(action)
  -- A refereed fight asks for a switch after a faint with bench left (same
-- `switch` choice as voluntary SWITCH). Timeout / autoPick still lands
-- firstLiving. Answered as a switch on the wire.
  if self.mediated then
    return self:sendMediatedChoice({ kind = "switch", index = action.index })
  end
  if self.host then return self:applyReplace(action) end
  if self.net then self.net.send({ t = "act", action = action }) end
end

function M:applyReplace(action)
  local events = {}
  -- Said before the monster is sent out, and said to everybody: a choice that
  -- was made *for* somebody by a clock looks exactly like a choice they made,
  -- and the player who ran out of time is owed the difference.
  if action.forced then
    local slot = self.sim:slot(action.slot)
    events[#events + 1] = { kind = "msg",
      text = ((slot and slot.name) or "Someone") .. "\ntook too long!" }
  end
  -- Who is on screen, taken before the field moves. See M:holdDisplay: this is
  -- the one client that simulates first and shows afterwards, so a battler it
  -- does not hold on to here is one it can no longer draw.
  self:holdDisplay()
  local ok = self.sim:replace(action.slot, action.index,
    function(event) events[#events + 1] = event end)
  if not ok then return false end
  self.seq = (self.seq or 0) + 1
  if self.net then
    self.net.send({ t = "res", seq = self.seq,
                    sig = self.sim:signature(), events = events })
  end
  self:playEvents(events)
  self:tryResolve()
  return true
end

function M:commit(action)
  self.phase = "wait"
  -- Your own answer is in, whoever else's is not -- which is what keeps the
  -- wait line from naming the person reading it.
  self:markActed(action.slot)
  -- ------- and on the mediated path that is the whole of it
  --
  -- One choice, addressed to the referee, and nothing fanned out to the other
  -- three: they will see what this turn did when the intermediator tells them,
  -- which is the only account any of the four gets. Taken before the `act`
  -- below rather than beside it -- sending both would put a second, unrefereed
  -- opinion about this turn on a wire that has already cut it.
  if self.mediated then
    local ok = self:sendMediatedChoice(action)
    if not ok and action.kind == "item" then
      self.pendingItem = nil
      self.pendingItemSlot = nil
      self:unmarkActed(action.slot)
      self.phase = "choose"
    end
    return ok
  end
  -- ...and everybody else is told, **including when this client is the host**.
  --
  -- The host used to file straight into `pending` and return, so its own
  -- choice never went on the wire at all. The other three learn who has
  -- answered by watching `act` go past (see the observe-only branch in
  -- `drainNet`), so they could never learn the host had chosen: their wait
  -- line named the host for the whole of every turn, while the host sat in
  -- `tryResolve` waiting on *them*. The one player who is never late was the
  -- one everybody was told to wait for.
  --
  -- Sent unconditionally, and it cannot come back: the relay fans a message
  -- out to every member of the group **except its sender** (server/lib/relay.js
  -- and src/Hub.lua both skip `client.id`), so the host never receives its own
  -- `act` and the branch that files somebody else's action can never re-file
  -- this one on top of the copy going into `pending` below.
  if self.net then self.net.send({ t = "act", action = action }) end
  if self.host then
    self.pending[action.slot] = action
    return self:tryResolve()
  end
end

-- Everything the host is still waiting on, filled in for the slots nobody is
-- sitting at. An NPC's move is chosen here rather than on its "own" client
-- because there is no such client -- and choosing it anywhere but the host
-- would be a second opinion about what the same NPC did.
function M:tryResolve()
  if not self.host then return end
  -- ------- and the host stops deciding the moment somebody else is
  --
  -- The single cut that makes a co-op battle mediated. Everything below rolls
  -- dice: `npcAction`, `resolveTurn`, and the `res` broadcast that three other
  -- clients apply as truth. A second set of those beside the intermediator's is
  -- not a fallback, it is the desync it looks like -- two fields diverging from
  -- the same turn, and both hubs would refuse the broadcast anyway.
  --
  -- Guarded here rather than at every caller because there are five of them
  -- (`commit`, `applyReplace`, `drainNet`'s `act`, `autoPickLate`, and its own
  -- recursion) and one of them missed is a host quietly refereeing beside the
  -- referee.
  if self.mediated then return end
  -- Shipped MEDIATED_COOP modes must not fall through to host-sim (BattleSim
  -- vs engine ItemEffects diverge on items/effects). Wait for battle_ready, or
  -- abort if mediation was refused at upload.
  if M.mediates(self.mode) then
    if self.medFailed then
      self:failMediation()
    end
    return
  end
  -- Nobody takes a turn while a slot is still empty. The player choosing has
  -- nothing on the field to act with, and resolving around them would spend
  -- the other three's moves on a field that is about to change.
  if self.sim:awaitingChoice() then return end
  local actions = {}
  for _, slot in ipairs(self.sim.slots) do
    if not self.sim:isDown(slot) then
      if slot.owner == nil then
        local npc = self.sim:npcAction(slot)
        if npc then actions[#actions + 1] = npc end
      elseif self.pending[slot.index] then
        actions[#actions + 1] = self.pending[slot.index]
      else
        return -- still waiting on a human
      end
    end
  end

  self.pending = {}
  -- Any consent ask the host was holding belongs to the turn that is now over,
  -- and goes with it: an answer that arrives after this finds no ask behind it
  -- and is refused (see `hostRunAnswer`), which is precisely what "unanswered
  -- at the deadline counts as no" means on the authoritative side.
  self.runAsks = nil
  -- ------- and the deadline stops here, because the turn has been taken
  --
  -- `turnOpened` used to be disarmed only by *firing*, so it ran straight on
  -- through the messages phase -- and a batch of narration is not free: every
  -- line holds the box for at least 1.6 seconds, and a four-slot turn produces
  -- a dozen of them. Deliberation plus narration crossed 60 seconds routinely,
  -- and `autoPickLate` then filed a turn for players who had not been offered
  -- one, with "took too long!" against their names.
  --
  -- An idle host made it near-certain rather than merely likely: it never
  -- leaves the messages phase on its own, so the clock it holds was the one
  -- clock nothing was going to stop.
  --
  -- Cleared at the moment this commits to resolving, beside `pending` and for
  -- the same reason -- both belong to the turn that is now over. `openTurn`
  -- re-arms it at the handover, which is where a turn becomes decidable *to a
  -- player* rather than merely computable. (`autoPickLate` guards the phase
  -- itself as well; the two halves close the window from both ends.)
  self.turnOpened = nil
  self.owed = nil
  self.turnCount = (self.turnCount or 0) + 1
  -- The four monsters as the screen currently has them, held before the turn
  -- resolves. A monster that faints and is replaced inside `resolveTurn` --
  -- which is every NPC replacement, since there is nobody to pause for -- is
  -- gone from its slot by the time any of this is drawn, and this is the only
  -- moment it can still be caught. See M:holdDisplay.
  self:holdDisplay()
  local events = self.sim:resolveTurn(actions) or {}
  -- Whoever the clock picked for is named first, ahead of the turn their
  -- absence produced -- so the reason arrives before the consequence, and it
  -- arrives on all four clients rather than only on the one holding the clock.
  -- Cleared here whether or not there were any: a note that outlived its turn
  -- would blame somebody on the *next* one.
  if self.lateNotes then
    for i = #self.lateNotes, 1, -1 do
      table.insert(events, 1, self.lateNotes[i])
    end
    self.lateNotes = nil
  end
  -- A new turn is owed a new set of answers, so the old ones go with the
  -- turn they belonged to -- the same moment `pending` was emptied above.
  self.acted = nil
  -- Numbered, and stamped with what the field looks like afterwards.
  --
  -- A replayer applies HP straight out of these events, so a single lost
  -- message used to leave it showing numbers that were never true, forever,
  -- with nothing to notice it by. The sequence catches a message that never
  -- arrived; the signature catches the subtler case where they all arrived and
  -- the two copies still disagree.
  self.seq = (self.seq or 0) + 1
  if self.net then
    self.net.send({ t = "res", seq = self.seq,
                    sig = self.sim:signature(), events = events })
  end
  self:playEvents(events)
end

-- Is this client applying somebody else's arithmetic rather than its own?
--
-- True for the three clients that are not the host, and true for **all four** on
-- the mediated path -- the host included, because a refereed turn was resolved
-- somewhere else and its `sim` never touched the numbers the events carry. The
-- two branches in `playEvents` that ask are exactly the two that write sim truth
-- (`damage` applies HP, `send` swaps a battler), and a host that skipped them
-- because it "already did it" would draw a field nobody ever changed: bars that
-- never move, and a monster that faints on three screens out of four.
function M:replaying()
  return (not self.host) or self.mediated
end

-- Apply a turn's events -- the host to its own screen, everybody else to
-- theirs. One function for both, which is what makes a replay and a simulation
-- land on the same screen rather than merely a similar one.
function M:playEvents(events)
  -- The first resolved turn is what takes the trainer's picture off the field,
  -- on every client rather than only the one that resolved it.
  self.turnCount = self.turnCount or 0

  -- ------- which monster a queued row belongs to
  --
  -- Every display row is queued against the battler *object* it is about, not
  -- against the slot it stands in. A slot's battler is replaced outright on a
  -- send-out (see `M:shownBattlerAt` for the whole story), so a row that named
  -- only the slot would be spent on whoever walked on next -- which is exactly
  -- what a same-turn NPC replacement produces.
  --
  -- `showing` answers "who is on screen in this slot at this point in the
  -- batch": the display shadow to begin with, and then whatever each `send`
  -- swaps in as the walk passes it. Rows queued before that `send` therefore
  -- hold the outgoing monster and rows queued after it hold the new one.
  -- `queuing` is per call, and the shadow it falls back to only advances when
  -- a queued `swap` row is finally consumed -- so between the two there is a
  -- window where neither has caught up: two batches played before the queue
  -- drained. The host reaches it on every forced replacement (`applyReplace`
  -- plays a batch and `tryResolve` can resolve the next turn in the same
  -- frame), and a replayer reaches it whenever two `res` arrive in one poll.
  -- Falling back to the shadow there answered with the *departed* monster, so
  -- the new turn's drain and faint rows were spent on a monster that is no
  -- longer on the field: a bar that never moves, and the wrong sprite sunk.
  --
  -- So the queue is asked first. The newest `swap` still waiting for this slot
  -- is what the screen will be showing by the time these rows come up, which
  -- is the question every caller is really asking.
  local queuing = {}
  local function showing(index)
    local held = queuing[index]
    if held ~= nil then return held end
    for i = #self.messages, 1, -1 do
      local row = self.messages[i]
      if type(row) == "table" and row.swap == index then return row.battler end
    end
    return self:shownBattlerAt(index)
  end

  for _, event in ipairs(events or {}) do
    if event.kind == "msg" then
      -- Carried with the line rather than applied now: the spotlight has to
      -- move when the message is *shown*, not when the turn is received, or
      -- all four moves would light up the last actor at once.
      self.messages[#self.messages + 1] =
        { text = event.text, from = event.from }
    elseif event.kind == "anim" then
      -- Queued alongside the messages rather than played now, so it arrives in
      -- the order the turn produced it rather than all at once at the end.
      self.messages[#self.messages + 1] =
        { anim = event.anim, from = event.from, to = event.to,
          attackerIsPlayer = event.attackerIsPlayer, amount = event.amount }
    elseif event.kind == "damage" then
      -- The replayers are told the resulting HP rather than the amount, so a
      -- dropped or reordered event cannot leave a bar drifting away from the
      -- host's.
      local slot = self.sim:slot(event.slot)
      if slot and slot.battler and self:replaying() then
        slot.battler.mon.hp = event.hp
      end
      -- The number above is the truth and it lands now. The *bar* is a queued
      -- row like any other, so it falls when its turn in the queue comes round
      -- rather than the moment the turn was received -- otherwise all four
      -- bars drop at once while the lines that explain them are still being
      -- read, which is the one thing the engine's 1v1 never does.
      --
      -- Queued on the host too. Its sim applied the HP during `resolveTurn`,
      -- long before any of this is shown, so the host needs the wait more than
      -- the replayers do, not less.
      --
      -- Queued for *every* damage event rather than only the ones with no
      -- drain row beside them: residual damage and a used item produce no
      -- drain row at all, and a row that asks a bar for where it already is
      -- costs a frame and does nothing.
      local shownAt = showing(event.slot)
      if shownAt and not self:skipHealShapedDrain(shownAt, event.hp) then
        self.messages[#self.messages + 1] =
          { drain = shownAt, slot = event.slot, to = event.hp }
      end
    elseif event.kind == "drain" then
      -- One per strike, placed by the field in the engine's own queue order --
      -- after the hit animation, before the effectiveness line. It carries how
      -- far the bar may fall on *this* strike, which is what stops a multi-hit
      -- move draining straight to the post-last-hit HP and leaving the later
      -- strikes with nothing to animate.
      --
      -- No HP is applied here. Sim truth arrives only on `damage`, so a drain
      -- row that went missing costs an animation and never a number.
      local shownAt = showing(event.slot)
      if shownAt and not self:skipHealShapedDrain(shownAt, event.to) then
        self.messages[#self.messages + 1] =
          { drain = shownAt, slot = event.slot, to = event.to }
      end
    elseif event.kind == "faint" then
      -- ------- "this one is down", as a *drawing* fact, handed to the queue
      --
      -- `CoopField.onFaint` marks the battler the instant the move lands, and
      -- on the host that is inside `resolveTurn` -- before one frame of the
      -- turn has been shown. Drawing straight off that flag made the beaten
      -- monster vanish a second before the sink that exists to show it
      -- falling, and only on the host, so the four clients disagreed about
      -- what they had just watched.
      --
      -- Display hide uses `displayFainted` (set only when the faint row runs),
      -- not CoopField's early `fainted` -- that adapter flag stays for the
      -- effect registry's "do not faint twice" guard. Cleared here so a stale
      -- display flag cannot survive a re-queue. Nothing about the *rules*
      -- changes: `sim:isDown` is still what every rule reads.
      --
      -- The sink is queued rather than played: the monster stands on the field
      -- until the row that fells it comes up, and the "fainted!" line is
      -- printed over the top of it -- the engine's own order, which emits the
      -- slide and the cry before the text (BattleState:enemyMonFainted).
      --
      -- A knockout is also what an EXP.ALL's *second* pass belongs to, rather
      -- than the awards that follow it: the referee sends one `exp` per paid
      -- participant now, and the engine spreads the other half once per faint
      -- (BattleState:3877-3890, outside its participant loop). Armed here and
      -- spent by the first award that follows -- see `gainExp`.
      --
      -- **A knockout on the other side only.** Nothing owes this client exp
      -- for its own monster going down, and arming on one would let the next
      -- award -- a partner's foe knockout two turns later, or the same turn's
      -- trade -- spend a credit no foe faint created, banking the EXP.ALL half
      -- a second time for a single knockout. src/MediatedBattle.lua gates its
      -- twin of this flag the same way (`sideOfSlot(msg.slot) ~= mySide`);
      -- `foeSide` is this screen's spelling of that test, and it answers false
      -- when the sides cannot be read, which leaves the flag at whatever it
      -- was -- `nil` (unmetered) for a harness that narrates no faint at all.
      if self:foeSide(event.slot) then self.expAllCredit = true end
      -- **And the number, not only the picture.** A faint used to be handled
      -- here as a drawing fact alone -- the sink was queued and no HP was
      -- written -- on the reasoning that `damage` is the only event that
      -- carries truth. That holds right up until the hp=0 `damage` is the
      -- event that goes missing, which is precisely the lossy case `medGaps`
      -- exists to count: the monster then sinks off the field with its local
      -- copy still holding pre-KO HP, and every rule that reads HP -- and
      -- `snapDisplay`, which re-derives the display flag from `sim:isDown` --
      -- goes on believing it is alive. The reported symptom was a knocked-out
      -- POKeMON standing back up on the next turn boundary with the bar it had
      -- before the killing blow.
      --
      -- So the referee's faint is authoritative about HP as well: nothing can
      -- be down and above zero. Written onto the battler's `mon`, which is the
      -- party entry itself -- `BattleState.makeBattler` keeps the monster by
      -- reference (src/battle/BattleState.lua:483) -- so `hasReserve`,
      -- `isDown` and both of round 7's `hp <= 0` send-out refusals all read the
      -- corrected number afterwards. `src/MediatedBattle.lua:1899-1900` is the
      -- same line on the sibling screen.
      --
      -- Guarded by `replaying()` for the reason every other truth-writing
      -- branch here is: a host that simulated this turn itself already applied
      -- the knockout, and its own `sim` is where the event came from.
      local fell = self.sim:slot(event.slot)
      local down = fell and fell.battler
      if down and down.mon and self:replaying() then down.mon.hp = 0 end
      local shownAt = showing(event.slot)
      if shownAt then
        shownAt.displayFainted = nil
        self.messages[#self.messages + 1] =
          { faintfx = shownAt, slot = event.slot }
      end
    elseif event.kind == "choose" then
      -- Only its owner is asked; the other three watch an empty slot until it
      -- is filled.
      -- Marked on every client, not only the one being asked: a paused field
      -- is a fact about the battle, and the other three have to know it to say
      -- who they are waiting for rather than showing an empty box.
      local waiting = self.sim:slot(event.slot)
      if waiting then waiting.awaiting = true end
      if event.slot == self.mine then
        self.replacing = true
        self.switchIndex = 1
      else
        self:say((event.trainer or "They") .. " is choosing\nwho to send out...")
      end
    elseif event.kind == "exp" then
      self:gainExp(event)
    elseif event.kind == "learn" then
      self:learnMove(event)
    elseif event.kind == "send" then
      local slot = self.sim:slot(event.slot)
      -- Who was standing there, taken before the swap lands: the rows already
      -- queued for this slot are about that monster and nothing else.
      local leaving = showing(event.slot)
      -- Sim truth, applied *now* rather than in the queue: a replayer's
      -- signature has to match the host's the moment the event is applied.
      --
      -- ...unless the row names a monster this screen has at 0 HP. No referee
      -- fields a fainted monster, so such a row is a resolution that went wrong
      -- upstream (a name that matched two of one species, a `mon` stamp counted
      -- in a shifted party) -- and fielding it anyway is what put a knocked-out
      -- POKeMON back on the field standing. The seat is left empty instead: one
      -- monster missing until the next send is a smaller lie than a dead one
      -- fighting, and the signature it protects is already broken by the time
      -- this can fire. CoopSim.sendOut refuses the same thing from the inside;
      -- this is the outer layer, and it is the one that can still name the row.
      local coming = slot and event.index and (slot.party or {})[event.index]
      if slot and self:replaying() then
        if coming and (coming.hp or 0) <= 0 then
          mod.log:warn("a refereed send-out named a fainted POKeMON (seat %s, "
            .. "party slot %s), so the seat was left empty rather than putting "
            .. "it back on the field; report this with the trainer fought if "
            .. "the field stays a POKeMON short",
            tostring(event.slot), tostring(event.index))
        else
          self.sim:sendOut(slot, event.index)
        end
      end
      -- ...and the *display* follows at its own pace. The outgoing monster is
      -- held in the shadow so it keeps being drawn -- and keeps draining and
      -- sinking -- while its rows play, and the new one is queued behind them
      -- as a swap row. Without this an NPC's monster that fell and was
      -- replaced inside the same resolved turn simply blinked out of
      -- existence: the replacement was on the field before the bar it emptied
      -- had moved a pixel.
      if slot then
        local shadow = self:displayShadow()
        shadow[event.slot] = leaving
        queuing[event.slot] = slot.battler
        -- ...with the throw that puts it there in front of it, so the arrival
        -- reads as somebody sending a monster out rather than one appearing.
        -- Queued between the departing monster's rows and the swap: everything
        -- owed to the one that left has played by the time the ball leaves the
        -- trainer's hand. See `queueSendBall` for the seats that get one.
        self:queueSendBall(event.slot)
        self.messages[#self.messages + 1] =
          { swap = event.slot, battler = slot.battler }
      end
      -- The question has been answered -- and it may not have been answered by
      -- the player who was asked. When the clock runs out the host picks the
      -- next living reserve and sends this event like any other, so the picker
      -- has to close on the *event* rather than only on the button that
      -- normally causes it. Without this the slow player was left sitting in a
      -- bench list for a slot that was already filled, unable to take their
      -- next turn, and their eventual pick was dropped as a stale duplicate.
      if event.slot == self.mine and self.replacing then
        self.replacing = nil
        self.switchIndex = 1
      end
    elseif event.kind == "over" then
      self.result = self:resultFor(event.winner)
      -- Fanfare rides the message queue as an `act`, the way BattleState
      -- actNext(playVictoryMusic) does -- after this batch's drains and faint
      -- sinks already appended above, and ahead of the parting text below.
      -- Inline play here started the jingle under Gust's still-living bar.
      self.messages[#self.messages + 1] = {
        act = function(battle) battle:playVictoryMusic() end,
      }
      -- Why the rating did not move, said once.
      --
      -- Winning a 2-on-2 against a trainer pays everything a trainer battle
      -- pays -- exp, badges, prize money -- and no ranked points, because
      -- there is no opponent rating to be measured against. A player who is
      -- never told simply sees a number that did not change and concludes the
      -- ranking is broken. Said on a win only, because that is the moment they
      -- would look, and only once per session: a rule explained is a courtesy
      -- and a rule repeated after every fight is a nag.
      -- Once per save rather than once per process: `saidUnranked` is reset
      -- when a save is loaded (see Client), because a player who loads a
      -- different game is exactly the one who has not been told yet.
      if self.result == "win" and not self.ranksPoints and not M.saidUnranked then
        M.saidUnranked = true
        self:say("No points for a\n2-on-2 vs an NPC.")
        self:say("Battle players to\nclimb the ranks!")
      end
      -- What the trainer says on the way down. Printed here rather than left
      -- to the battle we displaced: that battle never runs its own end, so its
      -- text would never be said at all.
      if self.result == "win" and self.endBattleText then
        for page in (tostring(self.endBattleText) .. "\f"):gmatch("(.-)\f") do
          if page ~= "" then self:say(page) end
        end
      end
    end
  end
  -- ------- and every open menu closes here, on the events rather than a button
  --
  -- This is the replayer's half of the auto-pick. When the host's deadline
  -- fires it files an action for whoever was still deciding, and the turn comes
  -- back as an ordinary `res` -- so the client that was idle is sitting in a
  -- move list, or a target picker, for a turn that has already been taken.
  -- Setting the phase is what closes it (every picker is drawn and driven off
  -- `self.phase`), and it is set here for *every* batch, which is the same
  -- discipline the `send` branch above closes the bench picker with.
  --
  -- `replacing` is deliberately not touched: it outranks the phase, and the
  -- `send` branch is what clears it, on the event that answers it.
  self.phase = "messages"
  self.after = self.result and "over" or "choose"
  -- ...and any run consent still standing comes down with the same batch, on
  -- both ends of it. A turn that has been decided is a turn whose ask can no
  -- longer be answered: the asker's wait and the partner's prompt both belong
  -- to it, and this is the one event every client reaches. It is also what
  -- makes the deadline's answer to an unanswered ask "no" without a rule of its
  -- own -- the auto-picked turn arrives here like any other.
  self.runAsk = nil
  -- ...and the host's *record* of the asks dies in the same breath as the
  -- prompts they put on screen. Clearing it in `tryResolve` alone was not
  -- enough: a batch that plays without resolving a turn -- `applyReplace`'s
  -- forced send-out is one -- took every prompt down and left the record
  -- standing, which is exactly the state `hostRunAnswer`'s check exists to make
  -- unreachable: an ask no client is displaying, that a forged yes could still
  -- be accepted against.
  if self.host then self.runAsks = nil end
  -- Every turn starts on FIGHT.
  --
  -- The cursor used to keep whatever row was picked last, and that is a trap:
  -- land it on ITEM, empty the bag, and the menu opens an empty list, bounces
  -- straight back and opens it again -- a visible flicker and a turn that
  -- never resolves, because nothing was ever committed. Starting on the one
  -- command that can always be actioned makes that unreachable.
  --
  -- The move and target cursors go back with it, for the same reason and for
  -- one more: a client whose picker was closed by an auto-picked turn would
  -- otherwise re-open next turn still pointing at half of a decision that was
  -- taken out of its hands.
  self.commandIndex = 1
  self.moveIndex = 1
  self.targetIndex = 1
end

function M:resultFor(winner)
  if winner == "draw" then return "draw" end
  local slot = self:mySlot()
  if slot and slot.side == winner then return "win" end
  return "loss"
end

-- ------- the bar falling, and the monster after it
--
-- Two blocking states, both of them the engine's own, both of them living
-- entirely on the display side: `mon.hp` is the sim's and is applied where it
-- always was, and `battler.shownHP` is the number the bar is drawn from. The
-- gap between the two *is* the animation.
--
-- Neither is skippable. The engine reads a button only for a text page that
-- has finished printing -- a draining bar and a sinking monster are held by
-- the queue itself -- so there is deliberately no input here to find.

-- The fall, in frames and pixels per frame: pokered's AnimationSlideMonDown,
-- which the engine's own battle screen counts down the same way.
local FAINT_FRAMES = 30
local FAINT_STEP = 2

-- A queued drain row comes up: start it, or answer it on the spot.
--
-- `makeBattler` seeds `shownHP` from the mon's HP, so it is there for every
-- battler this screen ever draws. A missing one is a battler built by
-- something that did not, and the safe answer is the true number rather than
-- an invented descent from one -- `mon.hp` has already moved by the time this
-- runs, so there is nothing left to work the starting point back out of.
--
-- The row carries the battler itself rather than a slot to look one up in, so
-- a bar that was queued for the monster that has since left still falls on
-- that monster -- see `M:shownBattlerAt`.
-- `to` is clamped, and that is a wire rule rather than a tidiness one. It
-- arrives inside a `res` from the host, `stepDrain` stops on exact equality,
-- and a drain is deliberately unskippable -- so a NaN, an infinity or a plain
-- 1e9 is a stop condition that never comes true and a message queue that never
-- moves again, for one client, from one corrupt or forged number. Held to what
-- a bar can actually show: nothing below empty, nothing above this monster's
-- maximum. NaN is refused outright, because it compares false against every
-- bound there is.
function M:startDrain(row)
  local battler = row.drain
  local to = tonumber(row.to)
  if not (type(battler) == "table" and battler.mon and to) then return false end
  if to ~= to then return false end
  local max = tonumber(battler.mon.stats and battler.mon.stats.hp) or 0
  to = math.max(0, math.min(max, to))
  if battler.shownHP == nil then
    battler.shownHP = to
    return false
  end
  if battler.shownHP == to then return false end
  -- Faint already queued / display-fainted: never animate a heal-shaped climb
  -- (multi-attacker KO race left a drain with to > shownHP).
  if self:skipHealShapedDrain(battler, to) then return false end
  -- The budget is the second half of the same guard, and it covers what a
  -- clamp cannot: the bar moves by a *rate*, so a step small enough to lose
  -- its last fraction to floating point would never reach `to` exactly. 96
  -- frames is the whole descent (see the rate below); the slack is there so an
  -- ordinary drain never meets this at all, and one that does is snapped to
  -- where it was going rather than left holding the queue.
  --
  -- The hit reads on the arena before the bar answers it: the defender flashes
  -- white, the field takes a nudge, and the drain starts a beat later with
  -- this same row (`splitHitBeat` puts it back at the head of the queue).
  -- Emitted from the row rather than when the `damage` event arrived because a
  -- resolved turn arrives as one batch -- all four seats would jolt in the
  -- same frame, ahead of any text. A climb (a heal, a drain move's restore)
  -- gets neither the fx nor the beat: nothing was struck.
  if battler.shownHP > to and self:splitHitBeat(row) then return false end
  self.hitSlot = row.slot
  self.draining = { battler = battler, slot = row.slot, to = to, frames = 120 }
  return true
end

-- A drain that would climb the bar after this mon is already owed a faint.
-- Truth HP stays instant; only the display climb is refused.
function M:skipHealShapedDrain(battler, to)
  if type(battler) ~= "table" then return true end
  local shown = battler.shownHP
  to = tonumber(to)
  if shown == nil or to == nil or to ~= to then return false end
  if to <= shown then return false end
  if battler.displayFainted then return true end
  if self.faintFx and self.faintFx.battler == battler then return true end
  for _, row in ipairs(self.messages or {}) do
    if type(row) == "table" and row.faintfx == battler then return true end
  end
  return false
end

-- One frame of it. `maxHP / 96` per frame is the engine's rate, and it is a
-- rate rather than a duration for a reason: the bar is 48 pixels and moves one
-- pixel every two frames whatever the monster's HP, so a 20 HP magikarp and a
-- 300 HP snorlax take the same second and a half to empty.
function M:stepDrain()
  local at = self.draining
  local battler = at.battler
  if not (battler and battler.mon) then
    self.draining = nil
    return
  end
  -- Out of frames: the bar has had longer than a full descent and still has
  -- not landed on `to`, so it is put there. A drain has no button to escape it
  -- by, so the only other end to this is a queue that never moves again.
  at.frames = (at.frames or 120) - 1
  if at.frames <= 0 then
    battler.shownHP = at.to
    self.draining = nil
    return
  end
  local shown = battler.shownHP or at.to
  local max = (battler.mon.stats and battler.mon.stats.hp) or 1
  local step = math.max(1, max) / 96
  if shown > at.to then
    shown = math.max(at.to, shown - step)
  else
    shown = math.min(at.to, shown + step)
  end
  battler.shownHP = shown
  if shown == at.to then self.draining = nil end
end

-- ------- the exp strip filling, which is the third display clock
--
-- Same shape as the drain above and for the same reason: `Experience.apply`
-- runs the instant the `exp` event is received and moves `mon.exp` and
-- `mon.level` in one step, so the number the plate is drawn from has to be a
-- separate clock that trails it. `battler.shownExpFrac` is the strip's fill
-- (0..1, or nil for "no strip") and `battler.shownLevel` is the number the
-- level pill prints; the gap between those two and the mon's own truth *is*
-- the animation, exactly as `shownHP` is for the bar.
--
-- Battlefield-only. The classic 160x144 readout has no exp strip and never
-- reads either clock, so nothing here is ever queued on that path (see
-- `gainExp`) and the classic exp text flow is byte-identical to what it was.

-- A whole bar in about 1.2 seconds, counted in frames because this screen's
-- update runs on the engine's fixed 60Hz step (the drain counts the same way).
-- Linear rather than the cart's accelerating three-frames-a-pixel crawl
-- (AnimateExpBar): the strip here is a fraction rather than 64 discrete
-- pixels, so there are no pixel steps to lengthen, and a constant rate reads
-- as the same deliberate crawl.
local EXP_FILL_FRAMES = 72
local EXP_FILL_STEP = 1 / EXP_FILL_FRAMES

-- Seed the two display clocks off the monster's own truth.
--
-- Lazy rather than at build time, because the battlers are built in CoopSim
-- (and, on a real boot, by the engine's `BattleState.makeBattler`) and neither
-- knows this screen has plates. Idempotent: it only ever fills a nil, so a
-- clock mid-fill is never yanked back to truth by a draw.
--
-- A seeded-nil `shownExpFrac` is not a failure to seed -- it is the honest
-- "this monster has no fraction to show" (a partner's packed mon carries no
-- exp), and it is re-asked every call precisely so a monster that gains one
-- later picks it up.
function M:seedExpClock(battler)
  if type(battler) ~= "table" or type(battler.mon) ~= "table" then return end
  if battler.shownLevel == nil then
    battler.shownLevel = tonumber(battler.mon.level) or 1
  end
  if battler.shownExpFrac == nil then
    battler.shownExpFrac = expFraction(self.game, battler.mon)
  end
end

-- A queued exp-fill row comes up. Answered on the spot (returning false) when
-- there is nothing to crawl, so the queue never stalls on one.
--
-- The row carries the battler rather than a slot, like the drain row does, so
-- a fill still lands on the monster it was queued for even if the field has
-- moved on.
--
-- **Both ends are read here, not at queue time, and each for its own reason.**
--
-- The *target* comes off `battler.mon` now because the mon is still being
-- written to after the row is queued: with an EXP.ALL held, `gainExp` runs a
-- second `Experience.apply` pass over the whole party -- and the fighter is in
-- that party, so a target frozen before that pass is short by whatever the
-- second half added (two levels' worth, in the case that found this). Reading
-- it at row-start means every apply pass has already landed, so the strip and
-- the pill agree with the "grew to level N!" lines printed beside them.
--
-- The *start* is the live display clock (`shownExpFrac`/`shownLevel`), because
-- that is where the strip visibly is. Two awards in one batch both capture
-- their `from*` before either has played, so honouring the second row's
-- capture would drag the strip back down to where the first one started.
-- `row.from*` remains as the fallback for a clock that is still nil -- the
-- capture `gainExp` takes before `Experience.apply` mutates the mon, which is
-- the one thing that genuinely cannot be worked back out later.
function M:startExpFill(row)
  local battler = row.expfill
  if type(battler) ~= "table" or type(battler.mon) ~= "table" then
    return false
  end
  local function level(value, fallback)
    local got = tonumber(value)
    if not got or got ~= got then return fallback end
    return math.max(1, math.floor(got))
  end
  local function frac(value)
    local got = tonumber(value)
    -- NaN refused rather than clamped: `stepExpFill` stops on `>=` against a
    -- target, and a NaN target is a stop condition that never comes true.
    if not got or got ~= got then return nil end
    return math.max(0, math.min(1, got))
  end
  local toLevel = level(battler.mon.level, 1)
  local toFrac = frac(expFraction(self.game, battler.mon)) or 0
  local from = frac(battler.shownExpFrac)
  if from == nil then from = frac(row.fromFrac) end
  -- No fraction to start from means this monster draws no strip at all, so
  -- there is nothing to fill. The pill is still put where the level is: it is
  -- printed from `shownLevel` and would otherwise sit a level behind forever.
  if from == nil then
    battler.shownLevel = toLevel
    return false
  end
  local fromLevel = math.min(
    level(battler.shownLevel, level(row.fromLevel, toLevel)), toLevel)
  battler.shownExpFrac = from
  battler.shownLevel = fromLevel
  -- Nothing crossed and nothing added (a rounding-sized gain, or an award
  -- that priced to zero): put the strip where it belongs and let the queue
  -- move on rather than holding it for a crawl nobody can see.
  if fromLevel == toLevel and toFrac <= from then
    battler.shownExpFrac = toFrac
    return false
  end
  -- The budget, and it is the same guarantee the drain's is: a fill is
  -- deliberately unskippable, so the only other end to a target it somehow
  -- cannot reach is a message queue that never moves again. One whole bar per
  -- level to cross plus two bars of slack, after which it is snapped to where
  -- it was going.
  self.expFilling = {
    battler = battler,
    slot = row.slot,
    toLevel = toLevel,
    toFrac = toFrac,
    frames = EXP_FILL_FRAMES * (2 + (toLevel - fromLevel)),
  }
  return true
end

-- One frame of it.
--
-- A level crossing is the cart's own (AnimateExpBar, engine/battle/core.asm):
-- the segment fills to full, the level the HUD prints ticks up, and the strip
-- restarts at empty -- which is why the pill changes as the bar tops out and
-- not a message later. Two levels in one award is that twice.
function M:stepExpFill()
  local at = self.expFilling
  local battler = at.battler
  if not (battler and battler.mon) then
    self.expFilling = nil
    return
  end
  at.frames = (at.frames or 0) - 1
  if at.frames <= 0 then
    battler.shownExpFrac = at.toFrac
    battler.shownLevel = at.toLevel
    self.expFilling = nil
    return
  end
  local shownLevel = tonumber(battler.shownLevel) or at.toLevel
  -- Every level still to cross fills the whole strip; the last one stops
  -- wherever the award actually left the monster.
  local target = (shownLevel < at.toLevel) and 1 or at.toFrac
  local shown = math.min(target, (tonumber(battler.shownExpFrac) or 0)
    + EXP_FILL_STEP)
  battler.shownExpFrac = shown
  if shown < target then return end
  if shownLevel < at.toLevel then
    battler.shownLevel = shownLevel + 1
    battler.shownExpFrac = 0
    return
  end
  self.expFilling = nil
end

-- The fall. The flag goes up *before* the text, which is the engine's order
-- (BattleState:enemyMonFainted queues the slide and the cry, then says the
-- line): the sprite is sliding out of its box while the box says why.
function M:startFaint(row)
  local battler = row.faintfx
  if type(battler) ~= "table" then return false end
  -- Display-only: CoopField may already have set adapter `fainted` during
  -- resolveTurn. Hiding the pic waits for this row so the sink still plays.
  battler.displayFainted = true
  self.hitSlot = row.slot
  self.faintFx = { battler = battler, slot = row.slot, frames = FAINT_FRAMES }
  -- The arena's half of the same fall. `faintFx` above stays the sequencer --
  -- it is what holds the message queue for its thirty frames -- and this is
  -- what the seat is actually drawn through while it does (`Battlefield.fxSeat`
  -- sinks and fades it). Held past its own clock by `stepFx` for as long as the
  -- sequencer runs, so the two cannot end at different times.
  self:emitFx("faint", row.slot)
  return true
end

function M:stepFaint()
  local fx = self.faintFx
  fx.frames = (fx.frames or 0) - 1
  if fx.frames > 0 then return end
  local idx = fx.slot
  self.faintFx = nil
  -- Seat wiped with no reserve: release focus so the strip/stage cannot keep
  -- pointing at an icon that stripShows is about to drop.
  local slot = self.sim and self.sim:slot(idx)
  if slot and self.sim:isDown(slot) and not self.sim:hasReserve(slot) then
    if self.lastFoeFocus == idx then self.lastFoeFocus = nil end
    if self.stageAlly == idx then self.stageAlly = nil end
    if self.stageFoe == idx then self.stageFoe = nil end
    if self.hitSlot == idx then self.hitSlot = nil end
  end
end

-- Is this slot the one currently sinking?
function M:sinkingAt(index)
  local fx = self.faintFx
  if fx and fx.slot == index and (fx.frames or 0) > 0 then return fx end
  return nil
end

-- ------- the monster on screen, which is not always the monster in the slot
--
-- A send-out **replaces** `slot.battler` with a different object rather than
-- editing the one that was there, and it lands as sim truth the instant the
-- `send` event is applied -- it has to, because a replayer's signature must
-- match the host's from that moment. The display cannot move that fast: the
-- monster that just left is still owed its exit, the bar draining to zero and
-- the thirty-frame sink.
--
-- The two are told apart by a shadow. `shownBattler[i]` is the battler the
-- screen is still drawing for slot `i`; the slot's own battler is what the
-- rules are being applied to. They differ for exactly as long as the queued
-- rows for the departed monster take to play, and a `swap` row -- queued
-- behind those rows by the `send` branch -- is what finally puts them back in
-- step.
--
-- This is what the earlier `dropDisplayFor` got wrong, and it is the bug this
-- whole screen's exit sequencing exists for: it *purged* the dying monster's
-- rows instead of playing them, so an NPC's monster -- whose replacement is
-- sent out inside the same resolved turn, with no player to pause for --
-- vanished mid-drain and the next one appeared in its place with no fall in
-- between. A human's replacement never showed the bug, because the `choose`
-- pause holds the turn open until the player answers and the rows have long
-- since played by then.
--
-- Lazily built, and every reader tolerates its absence: the suite builds
-- clients straight out of `setmetatable` without one.
function M:displayShadow()
  self.shownBattler = self.shownBattler or {}
  return self.shownBattler
end

-- The battler slot `index` is *drawn* from: the shadow if one is being held,
-- and otherwise the slot's own, which is the answer whenever the display and
-- the field agree -- which is nearly always.
function M:shownBattlerAt(index)
  local shadow = self.shownBattler
  local held = shadow and shadow[index]
  if held then return held end
  local slot = self.sim and self.sim:slot(index)
  return slot and slot.battler or nil
end

-- A queued swap coming up: the departed monster's rows have all played, so the
-- screen may finally show what the field has shown since the `send` landed.
function M:applySwap(row)
  self:displayShadow()[row.swap] = row.battler
  if row.battler == nil then return end
  -- The seat is let go of here and nowhere else. Whatever put the hold up --
  -- the opening hide (`enter`), or the ball row in front of this one -- this
  -- is the row that says the monster has arrived, so this is where it becomes
  -- drawable. On a refereed fight it is also the proof that the referee's
  -- opening send-outs are being played, which is what lets `snapDisplay` tell
  -- "still waiting for the batch" from "a seat nobody is coming to".
  if self.introHide then self.introHide[row.swap] = nil end
  if M.mediates(self.mode) then self.medOpened = true end
  -- The screen has just caught up with a send-out, so this is the frame the new
  -- monster appears on the arena. Same beat the intro gets (and the same beat
  -- the classic stage spends on `growIn`); a monster that blinked into
  -- existence at full size was the one arrival with no animation at all.
  self:noteBattlefieldSpawn(row.swap)
  -- ...and the classic stage's half of the same beat, with the entrance cry
  -- that goes with it. Both used to be queued by the client-side intro alone,
  -- so a refereed arrival -- which is now every arrival, the opening pair
  -- included -- had neither: the monster appeared at full size in silence. Set
  -- here rather than in the intro because this is the one row every send-out
  -- on either path passes through.
  self.growIn = { slot = row.swap, frame = 0 }
  self:playBallPoof()
  self:playEntranceCry(row.battler)
end

-- The ball bursting open, as a sound. The intro's `POOF_ANIM` row plays this
-- through `startAnim`; a refereed arrival has no such row -- it is a `swap`
-- with a burst on it -- so it says the same thing here rather than arriving in
-- silence. Same clip, same soft-fail as everywhere else this screen reaches
-- for audio (a build with no Sound simply has none).
function M:playBallPoof()
  local Sound = engine and engine.Sound
  if not (Sound and Sound.play) then return end
  pcall(Sound.play, self.game.data, Gen.sfx(self.game, "Ball_Poof"))
end

-- Hold what is on screen now, before the sim is asked to move.
--
-- Only the host needs this, and it needs it because it is the one client whose
-- `slot.battler` has already moved on by the time `playEvents` runs: it
-- simulates the turn first and shows it afterwards, so a monster that fainted
-- and was replaced inside `resolveTurn` is unreachable from the slot by then.
-- Taken before the turn resolves, the shadow still points at it -- which is
-- what lets the host queue that monster's drain and sink against the right
-- object and watch the same exit everybody else watches.
function M:holdDisplay()
  if not self.sim then return end
  local shadow = self:displayShadow()
  for _, slot in ipairs(self.sim.slots or {}) do
    if shadow[slot.index] == nil then shadow[slot.index] = slot.battler end
  end
end

-- Put every bar where its monster actually is, and stop animating.
--
-- The snap points are the three moments where an animation half-played would
-- be a lie rather than a lag: handing the turn back to a menu, being re-synced
-- by the host (the numbers just changed underneath the display), and leaving
-- the screen. Everywhere else the gap between `shownHP` and `mon.hp` is the
-- whole point.
function M:snapDisplay()
  self.draining = nil
  self.expFilling = nil
  self.faintFx = nil
  -- The arena's effects go with them, and a throw's hold goes first: an entry
  -- retained at t == 1 outlives its own clock on purpose (a held sink, a
  -- monster inside a ball), so dropping the list without ending the flow that
  -- justifies the hold would leave a seat hidden for the rest of the fight.
  self.ballFlow = nil
  self.fx = nil
  self.animHold = nil
  self.animDwell = nil
  -- ...and so does a display beat, for the sharper version of the same reason:
  -- a beat is a deliberate gap held in front of a row that the purge below may
  -- be about to delete, so leaving it standing would be the queue waiting on
  -- something that is no longer in it. `calloutSpent` goes with it -- the next
  -- attack after a snap has said nothing yet, and this is also the reset that
  -- covers the ordinary end of a queue (`update` snaps on the way back to the
  -- menu), so no attack ever inherits the previous turn's shout.
  self.beatHold = nil
  self.beatDwell = nil
  self.calloutSpent = nil
  -- ...and the shout key beside it, for exactly the same reason: it is "what
  -- the attack now playing has already had", and after a snap there is no
  -- attack playing. Reset together so a seat that opens the next turn with the
  -- same move it closed this one still gets its callout.
  self.calloutShout = nil
  -- The shadow goes with them. Nothing is owed an exit any more, so every slot
  -- draws the monster the field says is standing in it -- which is the safety
  -- net for a swap row that never arrived, and the reason a resync puts the
  -- screen right in one step.
  --
  -- Any queued *display* row goes with them -- swap, drain and sink alike --
  -- and it has to: a resync rebuilds every battler, so a swap row left in the
  -- queue would put a monster the field no longer holds back on screen some
  -- seconds after the display was told the truth, and a drain or a faint row
  -- left beside it would fire against the *new* field -- a bar walked back
  -- down to a number nobody holds any more, or a healthy monster sinking off
  -- its square. Nothing is lost by dropping them: the snap has already shown
  -- everything they were going to show.
  --
  -- Text and animation rows stay. They are bounded, they say what happened
  -- rather than change what is drawn, and cutting a player's last few lines
  -- off mid-sentence is a worse lie than reading them a moment late.
  self.shownBattler = {}
  local kept = {}
  for _, row in ipairs(self.messages or {}) do
    -- `ballsend` goes with the swap it belongs to, and it has to: the arc row
    -- *hides* its seat and the swap behind it is what shows it again, so a
    -- throw left in a queue whose arrival has just been dropped would blank a
    -- seat with nothing left to fill it.
    if not (type(row) == "table"
            and (row.swap or row.drain or row.faintfx or row.expfill
                 or row.ballsend)) then
      kept[#kept + 1] = row
    end
  end
  self.messages = kept
  if not self.sim then return end
  local data = self.game and self.game.data
  -- Only the seat that owns a strip owns clocks to weld, and the rule is the
  -- one `battlefieldSeats` draws by: this screen's own slot on the arena, and
  -- nobody at all on the classic readout. Welding wider than that both invents
  -- clocks on battlers no plate reads them off -- foes, the partner -- and
  -- spends a `Growth` walk per battler per queue drain on the classic path,
  -- which is documented as untouched by any of this.
  local owns = self:usesBattlefield() and self.mine or nil
  for _, slot in ipairs(self.sim.slots or {}) do
    local battler = slot.battler
    if battler and battler.mon then
      battler.shownHP = battler.mon.hp
      -- The exp clocks are welded the same way the bar is, and they have to
      -- be: a battle that ends mid-fill (or a resync that rebuilt the party
      -- underneath one) would otherwise leave a strip frozen part-way and a
      -- pill a level behind the monster it names. nil stays nil -- a monster
      -- with no fraction to show still shows none.
      if owns and slot.index == owns then
        battler.shownExpFrac = expFraction(self.game, battler.mon)
        battler.shownLevel = tonumber(battler.mon.level) or battler.shownLevel
      end
      -- A **one-way latch**, and the direction is the whole of it. Raising the
      -- flag for a monster the field says is down is a snap catching the
      -- display up. *Clearing* one that a played faint row put up is the
      -- display being told a monster that has already sunk off the arena is
      -- back on its feet -- and since the weld two lines up has just pulled
      -- `shownHP` to `mon.hp`, it would stand up with a full-looking bar. The
      -- only way the two can disagree in that direction is an HP number this
      -- client never received (the faint branch of `playEvents` now closes
      -- that gap at the source; this is the second lock on the same door).
      --
      -- Nothing legitimate needs the clear: a send-out replaces `slot.battler`
      -- with a different object, and a resync rebuilds every battler, so a
      -- flag never outlives the monster it was raised for.
      battler.displayFainted = self.sim:isDown(slot) or battler.displayFainted
        or nil
    end
  end
  -- ...and a seat still waiting for an arrival that is no longer coming is
  -- shown. The rows purged above are the only thing that would ever have
  -- revealed it (`applySwap`), so a hold left standing here is a seat that
  -- would stay blank for the rest of the fight. Only once the referee's
  -- opening send-outs have actually played: before that the queue is empty
  -- because the batch has not arrived yet, and revealing then would put all
  -- four monsters on the field ahead of the sentences that send them out.
  if self.introHide and self.medOpened then self.introHide = nil end
end

function M:finish()
  if self.finished then return end
  self.finished = true
  self:clearIntroFlags()
  self:snapDisplay()
  self.game.stack:pop()
end

-- The field, laid out the way the modern games lay a double battle out --
-- inside a screen a third of their width.
--
-- **The constraint first, because it decides everything else.** A Gen 1 battle
-- pic is 56x56. Four of them plus four status readouts plus a six-row message
-- box do not fit in 160x144 -- not staggered, not overlapped, not anywhere.
-- The first version of this screen pretended otherwise and the result was the
-- ally half of the field drawn underneath the command box: two garbled strips
-- where CHARIZARD and PIKACHU should have been, and their pictures invisible
-- behind it.
--
-- So the pics are drawn at half scale. That is the one lever that makes the
-- whole thing fit, and it is spent deliberately: **half is an integer scale**,
-- so a 56x56 pic lands on 28x28 with every pixel doubled down cleanly rather
-- than resampled into mush -- which is what any of 0.6, 0.75 or "fit to box"
-- would have done to art drawn for one exact size.
--
-- What that buys is the modern arrangement:
--
--   * four monsters visible at once, staggered diagonally so the pair on each
--     side reads as two things at different depths rather than one wide smear;
--   * the foes' two status readouts stacked in the top-left, away from their
--     pictures, and the allies' two stacked in the bottom-right, away from
--     theirs -- which is where Gen 3 puts them;
--   * a full-width message and command box in its usual place.
--
-- Every glyph, box and HP bar is still the engine's own (Font, HudTiles), so a
-- palette or asset mod owns the look of this exactly as it owns a wild battle.

-- Real size on the field. Foes stay 1x in the top-right quarter; the near
-- (bottom) pair draws larger and sits on the message-box lip -- there is
-- empty field under 1x backs that classic Gen 1 spent on a 2x player pic.
local PIC_SCALE = 1
local FOE_SCALE = 1
-- Target ally draw scale. picOriginFor clamps so the scaled back stays
-- between the left strip and the ally HUD (right-aligned toward the box).
local ALLY_SCALE = 1.5
-- Top of the bottom text/command box. Ally feet flush here (same rule as
-- BattleState.backPlacement), so the pair reads against the box instead of
-- floating mid-field.
local FIELD_FLOOR = 96
-- Gen 1 back sheets bake a few transparent rows under the opaque feet
-- (BattleState imagePadBottom is typically ~4). Without this inset the pic
-- sits a scaled pad above the lip and reads as mid-field.
local ALLY_FOOT_INSET = 4

-- Columns reserved on the level row for Lxx (left of the HP numbers).
-- "L100" at the ROM 8px face; the 4px meta sheet fits in less. Status no
-- longer shares this row -- it sits on the right of the HP bar (see
-- hpBarWidth) so Lxx and PSN/SLP/… can both be on screen.
local LEVEL_COLS = 3
-- Pixel gap between a shortened HP bar and a status tag on its right.
local STATUS_BAR_GAP = 2

-- Published for the suite, which cannot reach a file-local and has no graphics
-- device to measure a drawn pixel with.
M.FOE_SCALE = FOE_SCALE
M.ALLY_SCALE = ALLY_SCALE
M.FIELD_FLOOR = FIELD_FLOOR
M.ALLY_FOOT_INSET = ALLY_FOOT_INSET
M.LEVEL_COLS = LEVEL_COLS
M.STATUS_BAR_GAP = STATUS_BAR_GAP
M.BOX_COLS = BOX_COLS
M.wrapBoxLines = wrapBoxLines
M.pageBoxText = pageBoxText
-- List / move layout (pixels). Published so the suite can pin "fits the box"
-- without a graphics device: fourth row ends at LIST_TOP + 3*LIST_LINE + 8
-- = 136, which is the bottom border, not past it.
M.LIST_LINE = 8
M.LIST_TOP = 104
M.LIST_TOP_TITLED = 112
M.MOVE_NAME_Y = function(i) return 96 + i * 8 end
-- Left move pane: cursor at x=8, names at x=16, shared border with TYPE at
-- x=96. That is ten tiles -- an eleventh glyph (and any 12-char name like
-- QUICK ATTACK) painted through TYPE/. Long names scale horizontally to fit.
M.MOVE_NAME_X = 16
M.MOVE_NAME_MAX_W = 80
-- Right-pane TYPE/PP strip (same 6-tile bottom box). Last inner row is 128;
-- 136 is the bottom border -- PP used to paint through it.
M.MOVE_TYPE_LABEL_Y = 112
M.MOVE_TYPE_NAME_Y = 120
M.MOVE_PP_Y = 128
-- Left command prompt pane (tiles 1..7 inside the 9-tile box).
-- Full-width command box (tiles 0..19). Classic Gen 1 parked it at tile 8
-- beside "What will X do?"; co-op has no left prompt, so the box spans the
-- bottom strip and the 2x2 sits in two clear columns.
M.CMD_BOX_TX = 0
M.CMD_BOX_TW = 20
M.CMD_COL0_X = 24
M.CMD_COL1_X = 112
M.CMD_CUR0_X = 16
M.CMD_CUR1_X = 104
-- Name columns inside a status panel (ROM-font fallback). Borders eat 2;
-- the name keeps the full inner width (level + HP share the meta row).
M.nameBudget = function(tw, mine, status)
  return (tw or 0) - 2
end

-- HP bar width inside an `innerW`-wide content lane when a status tag of
-- `statusW` pixels sits on its right. Floor at 8 so a long tag cannot erase
-- the bar entirely; no status → full width.
function M.hpBarWidth(innerW, statusW)
  innerW = math.max(0, math.floor(tonumber(innerW) or 0))
  statusW = math.max(0, math.floor(tonumber(statusW) or 0))
  if statusW <= 0 then return innerW end
  return math.max(8, innerW - statusW - STATUS_BAR_GAP)
end

-- Truncate a label to a pixel budget via `widthOf`, or to `maxCols` glyphs
-- when no measurer is given. Pure for the suite.
function M.fitHudName(text, maxCols, widthOf)
  text = tostring(text or "")
  if type(widthOf) == "function" then
    local maxW = tonumber(maxCols) or 0
    if maxW <= 0 then return "" end
    if widthOf(text) <= maxW then return text end
    local ell = "..."
    if widthOf(ell) > maxW then
      ell = "."
      if widthOf(ell) > maxW then return "" end
    end
    local lo, hi = 0, #text
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if widthOf(text:sub(1, mid) .. ell) <= maxW then
        lo = mid
      else
        hi = mid - 1
      end
    end
    if lo <= 0 then return ell end
    return text:sub(1, lo) .. ell
  end
  maxCols = math.floor(tonumber(maxCols) or 0)
  if maxCols <= 0 then return "" end
  if #text <= maxCols then return text end
  if maxCols == 1 then return text:sub(1, 1) end
  return text:sub(1, maxCols - 1) .. "."
end

-- ImageFonts for status names (5×7) and level/HP nums (4×5). Cached;
-- `false` means load failed once. Meta is its own sheet: scaling the name
-- face by 0.75 mushing pixels on the GB canvas.
local battleHudFont
local battleHudMetaFont

local function loadHudImageFont(rel)
  if not (love and love.graphics and love.graphics.newImageFont) then
    return nil
  end
  local path
  local assets = mod and mod.assets
  if assets and assets.path then
    local ok, resolved = pcall(function() return assets:path(rel) end)
    if ok and type(resolved) == "string" and resolved ~= "" then path = resolved end
  end
  if not path then return nil end
  local glyphs = Config.BATTLE_HUD_GLYPHS
    or " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./-'?!"
  local ok, font = pcall(love.graphics.newImageFont, path, glyphs)
  if not (ok and font) then
    if mod and mod.log then
      mod.log:warn("could not load %s; co-op status readout falls back to the "
        .. "ROM font -- reinstall the mod so assets/fonts is present",
        tostring(rel))
    end
    return nil
  end
  pcall(font.setFilter, font, "nearest", "nearest")
  return font
end

local function loadBattleHudFont()
  if battleHudFont ~= nil then return battleHudFont or nil end
  battleHudFont = loadHudImageFont(
    Config.BATTLE_HUD_FONT or "assets/fonts/battle_hud.png") or false
  return battleHudFont or nil
end

local function loadBattleHudMetaFont()
  if battleHudMetaFont ~= nil then return battleHudMetaFont or nil end
  battleHudMetaFont = loadHudImageFont(
    Config.BATTLE_HUD_META_FONT or "assets/fonts/battle_hud_meta.png") or false
  return battleHudMetaFont or nil
end

-- Map a label onto the HUD sheet (uppercase; unknown → '.').
function M.hudSanitize(text)
  text = tostring(text or ""):upper()
  local glyphs = Config.BATTLE_HUD_GLYPHS
    or " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./-'?!"
  local out = {}
  for i = 1, #text do
    local c = text:sub(i, i)
    if glyphs:find(c, 1, true) then
      out[#out + 1] = c
    else
      out[#out + 1] = "."
    end
  end
  return table.concat(out)
end

-- Classic 1v1 center stage: one ally back and one foe front, with side strips
-- for the other living field seats. `y` on STAGE_ALLY is informational; ally
-- feet still anchor on FIELD_FLOOR. Foe pic sits just past FOE_HUD's right
-- edge (not under it). Ally x is the strip-clear floor; picOriginFor
-- right-aligns the scaled back against the ally HUD.
local STAGE_ALLY = { x = 16, y = 40 }
local STAGE_FOE = { x = 88, y = 0 }
local SLIDE_FRAMES = 10
-- How far a focus change travels (screen px). Must clear a ~56px pic so the
-- swap reads as a slide rather than a twitch.
local SLIDE_PX = 48
local STRIP_W = 16
local STRIP_ICON = 16
-- Single-mon HUDs: name; level + HP nums; slim bar. th=5 = border + 3
-- content + border so ~2px can sit between the three lines. The bar stays
-- flush to the bottom content edge (no empty band under it).
-- Ally HUD starts at tile 9 (x=72) so its right edge is at x=136: that leaves
-- the right strip column (144..160) and its focus arrow (136..144) clear when
-- the foe strip grows downward. picOriginFor right-aligns the back against
-- this box, so the ally sprite shifts left with it. ty=7 keeps ty+th == 12.
local FOE_HUD = { tx = 3, ty = 0, tw = 8, th = 5 }
local ALLY_HUD = { tx = 9, ty = 7, tw = 8, th = 5 }

M.STAGE_ALLY = STAGE_ALLY
M.STAGE_FOE = STAGE_FOE
M.SLIDE_FRAMES = SLIDE_FRAMES
M.SLIDE_PX = SLIDE_PX
M.STRIP_W = STRIP_W
M.STRIP_ICON = STRIP_ICON
M.FOE_HUD_TW = FOE_HUD.tw
M.ALLY_HUD_TW = ALLY_HUD.tw
M.FOE_HUD_TH = FOE_HUD.th
M.ALLY_HUD_TH = ALLY_HUD.th
M.FOE_HUD_TX = FOE_HUD.tx
M.FOE_HUD_TY = FOE_HUD.ty
M.ALLY_HUD_TX = ALLY_HUD.tx
M.ALLY_HUD_TY = ALLY_HUD.ty
M.FOE_PANEL_TW = FOE_HUD.tw
M.ALLY_PANEL_TW = ALLY_HUD.tw
M.FOE_PANEL_TH = FOE_HUD.th
M.ALLY_PANEL_TH = ALLY_HUD.th

-- The HP the *readout* shows, which trails `mon.hp` while a drain plays.
--
-- Rounded the engine's way (BattleState's own `shownHP` helper): a bar on its
-- way down rounds up and one on its way up rounds down, so the number always
-- lags the animation by less than a point rather than reaching the
-- destination before the bar does. The HUD ticks in whole HP either way.
local function displayHP(battler)
  local shown = battler.shownHP
  local truth = battler.mon.hp or 0
  if shown == nil then return truth end
  if shown > truth then return math.ceil(shown) end
  return math.floor(shown)
end

-- Whether a slot has anything to draw, which is not the same question as
-- whether it is still in the fight.
--
-- `sim:isDown` answers the rules' question and answers it the instant the HP
-- reaches zero -- which on the host is inside `resolveTurn`, before any of the
-- turn has been shown. The display's answer is the flag the faint row sets, so
-- a monster stays on the field until the queue gets round to felling it.
--
-- Asked about a battler rather than about a slot, because the two part company
-- while a departed monster is still being shown out (M:shownBattlerAt).
local function hidden(slot, battler)
  if not slot or slot.gone then return true end
  -- Display faint only -- CoopField's early `fainted` must not hide the pic
  -- before the queued sink runs.
  return battler == nil or battler.displayFainted == true
end

-- Living field seats on one side, in sim slot order (for the side strips).
--
-- A seat that has fainted with **no reserve** drops off the strip once its
-- fall finishes -- there is nobody left to put there. During the sink the
-- icon stays so the strip does not blink empty a frame early. Seats that
-- still have a bench keep their strip slot (the send-out fills it again).
function M:stripShows(slot)
  if not slot or slot.gone then return false end
  if self:sinkingAt(slot.index) then return true end
  local battler = self:shownBattlerAt(slot.index)
  if hidden(slot, battler) then return false end
  -- Truth may already be down from resolveTurn while the center pic still
  -- shows this mon: keep the strip icon until display faint / sink done.
  if battler and not battler.displayFainted then return true end
  if self.sim and self.sim:isDown(slot) and not self.sim:hasReserve(slot) then
    return false
  end
  return true
end

function M:stripSeats(theirs)
  local seats = {}
  for _, slot in ipairs((self.sim and self.sim.slots) or {}) do
    if self:foeSide(slot.index) == (theirs and true or false)
       and self:stripShows(slot) then
      seats[#seats + 1] = slot.index
    end
  end
  return seats
end

function M:desiredAllyFocus()
  local phase = self.phase
  if phase == "choose" or phase == "move" or phase == "switch"
     or phase == "target" or phase == "item" or phase == "item_party"
     or phase == "item_move" then
    return self.mine
  end
  if phase == "messages" or self.anim or self.draining or self.faintFx then
    local acting = self.acting
    if acting and not self:foeSide(acting) then return acting end
    local hit = self.hitSlot
    if hit and not self:foeSide(hit) then return hit end
    return self.mine
  end
  return self.mine
end

function M:desiredFoeFocus()
  local focus
  if self.phase == "target" then
    local mine = self:mySlot()
    local targets = mine and self.sim:targetsFor(mine) or {}
    local pick = targets[self.targetIndex or 1]
    focus = pick and pick.index
  elseif self.phase == "messages" or self.anim or self.draining or self.faintFx then
    local acting = self.acting
    if acting and self:foeSide(acting) then
      focus = acting
    elseif self.hitSlot and self:foeSide(self.hitSlot) then
      focus = self.hitSlot
    else
      focus = self.lastFoeFocus
    end
  else
    focus = self.lastFoeFocus
  end
  if not focus then
    local strip = self:stripSeats(true)
    focus = strip[1]
  end
  if focus then self.lastFoeFocus = focus end
  return focus
end

function M:allyFocus()
  return self.stageAlly or self:desiredAllyFocus()
end

function M:foeFocus()
  return self.stageFoe or self:desiredFoeFocus()
end

local function slideDx(slide, index, ally)
  if not slide then return 0 end
  local dur = slide.dur or SLIDE_FRAMES
  if dur <= 0 then return 0 end
  local t = (slide.t or 0) / dur
  local span = SLIDE_PX
  if index == slide.out then
    return ally and (-t * span) or (t * span)
  end
  if index == slide.into then
    return ally and ((1 - t) * span) or (-(1 - t) * span)
  end
  return 0
end

function M:onStage(index)
  if self:foeSide(index) then
    local focus = self:foeFocus()
    local slide = self.slideFoe
    return index == focus
      or (slide and (index == slide.out or index == slide.into))
  end
  local focus = self:allyFocus()
  local slide = self.slideAlly
  return index == focus
    or (slide and (index == slide.out or index == slide.into))
end

function M:stepFocusSlides()
  if not self.sim then return end
  local da = self:desiredAllyFocus()
  local df = self:desiredFoeFocus()
  if not self.stageAlly then self.stageAlly = da end
  if not self.stageFoe then self.stageFoe = df end
  if da ~= self.stageAlly and not self.slideAlly then
    self.slideAlly = { out = self.stageAlly, into = da, t = 0, dur = SLIDE_FRAMES }
  end
  if df ~= self.stageFoe and not self.slideFoe then
    self.slideFoe = { out = self.stageFoe, into = df, t = 0, dur = SLIDE_FRAMES }
  end
  local slide = self.slideAlly
  if slide then
    slide.t = (slide.t or 0) + 1
    if slide.t >= slide.dur then
      self.stageAlly = slide.into
      self.slideAlly = nil
    end
  end
  slide = self.slideFoe
  if slide then
    slide.t = (slide.t or 0) + 1
    if slide.t >= slide.dur then
      self.stageFoe = slide.into
      self.slideFoe = nil
    end
  end
end

-- A monster on its way off the field.
--
-- pokered's AnimationSlideMonDown, and it is a *clip* rather than a slide: the
-- pic sinks two pixels a frame and the rows that pass the baseline are cut
-- off, so it disappears behind its own square instead of walking down the
-- screen over whatever is drawn below it -- which at four slots is another
-- player's monster.
local function drawSinking(sprite, x, y, framesLeft, scale)
  scale = scale or PIC_SCALE
  local sw, sh = sprite:getDimensions()
  local offset = (FAINT_FRAMES - framesLeft) * FAINT_STEP
  -- The offset is in *screen* pixels and the quad is cut in *sprite* pixels,
  -- so the clip has to be divided back through the draw scale or the pic would
  -- be cut faster than it sinks and vanish early. The divisor is the scale this
  -- sprite is actually drawn at rather than PIC_SCALE: a foe draws at
  -- FOE_SCALE, and dividing its clip by 1 sank it through its own feet a
  -- sixth too fast -- the pic vanishing before the thirty frames were up.
  local visible = sh - math.floor(offset / scale)
  if visible <= 0 then return end
  local quad = love.graphics.newQuad(0, 0, sw, visible, sw, sh)
  love.graphics.draw(sprite, quad, x, y + offset, 0, scale, scale)
end

-- ------- the status abbreviation (group / co-op HUD only)
--
-- SLP, PAR, BRN, PSN, FRZ -- the three-letter forms the engine's own HUD prints.
-- On a 1v1 mediated screen those still replace Lxx (engine BattleState /
-- MediatedBattle). Here the panel is tight and four monsters make a lost
-- status line easy to miss, so the tag parks on the bar's right and shortens
-- the fill (hpBarWidth) — Lxx stays on the meta row.
--
-- **This is the original bug report.** A monster put to sleep loses its turn in
-- silence between two batches of messages: the line that said so scrolled past
-- some seconds ago, nothing on screen carries it, and a player watching their
-- monster do nothing for three turns running has no way to tell an enforced
-- sleep from a battle that has broken. Four monsters make it worse, not better
-- -- there is four times as much narration for the one line that mattered to
-- get lost in.
--
-- Read straight off `mon.status`, which is the id: a build that adds a status
-- gets its own id shown rather than a blank, cut to three so a long one cannot
-- erase the bar.
local function statusTag(battler)
  local mon = battler and battler.mon
  local status = mon and mon.status
  if type(status) ~= "string" or status == "" then return nil end
  return status:sub(1, 3)
end

-- Draw `text` at (x, y), scaling on X only when it would run past `maxW`.
-- Shared by move names (TYPE pane) and status readouts (level on the right).
local function drawFittedText(Font, text, x, y, maxW)
  text = tostring(text or "")
  local w = 0
  if Font.width then
    local ok, measured = pcall(Font.width, text)
    if ok and type(measured) == "number" then w = measured end
  end
  if w <= 0 then w = #text * 8 end
  if w <= maxW then
    Font.draw(text, x, y)
    return
  end
  -- Below ~3/4 width the glyphs smash into each other (CHARIZARD -> "CHRIZRI");
  -- truncate with a dot instead of an unreadable squash.
  local minScale = 0.75
  if maxW / w < minScale then
    local budget = math.max(1, math.floor(maxW / 8))
    if budget > 1 then
      Font.draw(text:sub(1, budget - 1) .. ".", x, y)
    else
      Font.draw(text:sub(1, 1), x, y)
    end
    return
  end
  local g = love and love.graphics
  if not (g and g.push and g.scale and g.translate and g.pop) then
    local budget = math.max(1, math.floor(maxW / 8))
    Font.draw(text:sub(1, budget), x, y)
    return
  end
  local s = maxW / w
  g.push()
  g.translate(x, y)
  g.scale(s, 1)
  Font.draw(text, 0, 0)
  g.pop()
end

local function drawReadout(self, battler, panel, row, mine)
  local Font, HudTiles = engine.Font, engine.HudTiles
  if not battler or not battler.mon then return end
  local tx = panel.tx + 1
  local ty = panel.ty + row
  local ox, oy = tx * 8, ty * 8
  love.graphics.setColor(0, 0, 0, 1)
  -- Name, level + cur/max, then slim HP bar. Status (when any) sits on the
  -- bar's right and shortens the fill so Lxx stays on the meta row. Bar is
  -- flush to the bottom content edge; pads open air between the lines.
  -- displayHP tracks shownHP through drains/heals the way classic BattleState does.
  local status = statusTag(battler)
  local lv = battler.mon.level
  local level = M.hudSanitize("L" .. tostring(lv ~= nil and lv or "?"))
  if status then status = M.hudSanitize(status) end
  local nameRaw = M.hudSanitize(battler.name or "?")
  local hp = displayHP(battler)
  local maxHp = (battler.mon.stats and battler.mon.stats.hp) or 0
  local hpNums = M.hudSanitize(("%d/%d"):format(hp, maxHp))
  local borderR = (panel.tx + panel.tw - 1) * 8
  local nameLeft = ox
  local g = love and love.graphics
  local hud = loadBattleHudFont()
  local meta = loadBattleHudMetaFont()
  local metaH = Config.BATTLE_HUD_META_HEIGHT or 5
  -- th=5 → 24px content. ~2px name→meta and meta→bar; bar on the bottom lip.
  local META_PAD = 2
  local BAR_GAP = 2
  local BAR_H = 3
  local CONTENT_H = 24
  if hud and g and g.print and g.setFont then
    local prev = g.getFont and g.getFont()
    local ok, err = pcall(function()
      g.setFont(hud)
      local nameMax = math.max(1, borderR - nameLeft - 2)
      local name = M.fitHudName(nameRaw, nameMax, function(s)
        return hud:getWidth(s)
      end)
      g.setColor(0, 0, 0, 1)
      g.print(name, nameLeft, oy)

      local face = meta or hud
      local faceH = meta and metaH or 7
      g.setFont(face)
      local levelW = face:getWidth(level)
      local hpW = face:getWidth(hpNums)
      local inner = math.max(0, borderR - ox)
      -- Name at top, bar flush at bottom; park meta in the middle so the
      -- two gaps stay even (not a tight name/meta pair over a tall empty).
      local nameH = 7
      local barY = oy + CONTENT_H - BAR_H
      local metaY = oy + nameH + META_PAD
      local maxMetaY = barY - BAR_GAP - faceH
      if maxMetaY > metaY then
        metaY = math.floor((metaY + maxMetaY) / 2)
      elseif maxMetaY >= oy + nameH + 1 then
        metaY = maxMetaY
      end
      g.print(level, ox, metaY)
      local numsX = math.max(ox + levelW + 2, borderR - hpW)
      g.print(hpNums, numsX, metaY)

      local statusW = 0
      if status then statusW = face:getWidth(status) end
      local barX = ox
      local barW = M.hpBarWidth(inner, statusW)
      local barH = BAR_H
      local minBarY = metaY + faceH + BAR_GAP
      if barY < minBarY then barY = minBarY end
      if barY + barH > oy + CONTENT_H then
        barY = oy + CONTENT_H - barH
      end
      if barW >= 8 then
        local fillInner = barW - 2
        local fill = 0
        if maxHp > 0 and hp > 0 then
          fill = math.max(1, math.floor(hp * fillInner / maxHp))
        end
        local fr, fg, fb = 0, 189 / 255, 0
        if fill < math.ceil(10 * fillInner / 48) then
          fr, fg, fb = 230 / 255, 0, 0
        elseif fill < math.ceil(27 * fillInner / 48) then
          fr, fg, fb = 230 / 255, 198 / 255, 0
        end
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", barX, barY, barW, 1)
        g.rectangle("fill", barX, barY + barH - 1, barW, 1)
        g.rectangle("fill", barX, barY, 1, barH)
        g.rectangle("fill", barX + barW - 1, barY, 1, barH)
        if fill > 0 then
          g.setColor(fr, fg, fb, 1)
          g.rectangle("fill", barX + 1, barY + 1, fill, math.max(1, barH - 2))
        end
        g.setColor(0, 0, 0, 1)
      end
      if status and statusW > 0 then
        -- Sit on the bar row, right of the shortened fill. Vertically nudge
        -- so a 5px meta face shares the 3px bar's vertical centre.
        local statusY = barY + math.floor((barH - faceH) / 2)
        g.print(status, barX + barW + STATUS_BAR_GAP, statusY)
      end
    end)
    if prev then pcall(g.setFont, g, prev) end
    if not ok then
      mod.log:warn("status readout failed (%s); the battle continues",
        tostring(err))
    end
  else
    -- Headless / missing sheet: ROM font, truncate by column budget.
    local budget = math.max(1, panel.tw - 2)
    Font.draw(M.fitHudName(nameRaw, budget), nameLeft, oy)
    Font.draw(level, ox, oy + 8)
    local nums = ("%d/%d"):format(hp, maxHp)
    local rightW = 0
    if Font.width then
      local measuredOk, measured = pcall(Font.width, nums)
      if measuredOk and type(measured) == "number" then rightW = measured end
    end
    if rightW <= 0 then rightW = #nums * 8 end
    Font.draw(nums, math.max(ox + LEVEL_COLS * 8, borderR - rightW), oy + 8)
    local statusCols = status and 3 or 0
    local segments = math.max(1, panel.tw - 2 - 3 - statusCols)
    local barOk = pcall(HudTiles.drawHPBar, self.game.data, tx, ty + 2,
      { hp = hp, stats = battler.mon.stats },
      nil, false, segments)
    if not barOk then
      Font.draw(("%d/%d"):format(hp, maxHp), ox, oy + 16)
    end
    if status then
      -- Cap sits at tx+2+segments; status starts one tile past that.
      Font.draw(status, (tx + 2 + segments + 1) * 8, (ty + 2) * 8)
    end
  end
end

function M:drawPanel(panel, which)
  local Font = engine.Font
  local rows = self:panelSlots(which)
  local any = false
  for _, index in ipairs(rows) do
    if not hidden(self.sim:slot(index), self:shownBattlerAt(index)) then
      any = true
    end
  end
  if not any then return end
  Font.drawBox(panel.tx, panel.ty, panel.tw, panel.th)
  for i, index in ipairs(rows) do
    local battler = self:shownBattlerAt(index)
    if not hidden(self.sim:slot(index), battler) then
      drawReadout(self, battler, panel, (i - 1) * 2 + 1, index == self.mine)
    end
  end
end

-- Whose turn it is, as a drawing question.
--
-- The two monsters in a pair overlap, so "which one is in front" is a free
-- channel, and the useful thing to spend it on is who is acting: the slot
-- being narrated is lifted to the top and everything else keeps its depth.
-- Falls back to your own monster, which is right while you are the one being
-- asked to choose.
function M:spotlight()
  return self.acting or self.mine
end

-- Whether the trainer is still standing where their monsters will be.
--
-- Theatrical intro arms `showEnemyTrainer` while the appear line is up (foes
-- stay in introHide). Outside that window, only an empty foe quarter keeps the
-- pic — co-op seats both foe mons before open, so a bare turnCount/messages
-- rule used to leave the Bug Catcher stuck over WEEDLE/CATERPIE.
function M:showingTrainer()
  if not self.trainerPic then return false end
  if (self.turnCount or 0) ~= 0 then return false end
  if self.phase ~= "messages" then return false end
  if self.showEnemyTrainer then return true end
  if self.sim then
    for _, slot in ipairs(self.sim.slots or {}) do
      if self:foeSide(slot.index) then
        local battler = self:shownBattlerAt(slot.index)
        if battler and not hidden(slot, battler) then
          return false
        end
      end
    end
  end
  return true
end

-- Is this slot on the other side of the field from mine?
--
-- Viewer-relative: the side that is not the side my own slot stands on. Labels,
-- hide-foes-during-trainer-pic, and (with `viewPos`) the whole screen layout
-- answer to this -- Gen 1 players read "bottom = me", so a seat on field slots
-- 3/4 must still see its own pair low-left or it looks like they are driving
-- the wrong team's moves.
function M:foeSide(index)
  local ours = self.sim and self.sim:slot(self.mine)
  ours = ours and ours.side
  local slot = self.sim and self.sim:slot(index)
  return (slot ~= nil and ours ~= nil and slot.side ~= ours) and true or false
end

-- Visual lane for a field slot: 1-2 = your pair (bottom-left), 3-4 = theirs
-- (top-right). Field indices stay a1,a2,b1,b2 on the wire; only drawing keys
-- off this remapping so every client still sees itself on the Gen 1 "player"
-- half of the screen.
function M:viewPos(index)
  if type(index) ~= "number" or not self.sim then return index end
  local mine = self:mySlot()
  local mySide = mine and mine.side
  if not mySide then return index end
  local ally, foe = {}, {}
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.side == mySide then
      ally[#ally + 1] = slot.index
    else
      foe[#foe + 1] = slot.index
    end
  end
  for i, id in ipairs(ally) do
    if id == index then return i end
  end
  for i, id in ipairs(foe) do
    if id == index then return i + 2 end
  end
  return index
end

-- Logical field indices that belong in a status panel, in readout order.
-- which 1 = foes (top-left panel), 2 = allies (bottom-right panel).
function M:panelSlots(which)
  local mine = self:mySlot()
  local mySide = mine and mine.side
  if not mySide then return {} end
  local rows = {}
  for _, slot in ipairs(self.sim.slots or {}) do
    local theirs = slot.side ~= mySide
    if (which == 1 and theirs) or (which == 2 and not theirs) then
      rows[#rows + 1] = slot.index
    end
  end
  return rows
end

-- How big slot `index` draws. Near pair (view lanes 1–2) uses ALLY_SCALE so
-- the backs fill the field down to the text box; far pair stays FOE_SCALE.
function M:scaleFor(index)
  local pos = self:viewPos(index)
  if not pos then return PIC_SCALE end
  if pos <= 2 then return ALLY_SCALE end
  return FOE_SCALE
end

-- ------- where slot `index` actually lands, in screen pixels
--
-- **One anchor, three callers.** The pic itself, the target picker's cursor and
-- the animation translation are all in the same space. Position comes from
-- `viewPos` → `SLOT_POS`, so a side-b seat draws its own monsters on the
-- classic player half of the screen.
--
-- Ally rows carry `feet = true`: SLOT_POS.y is the ground line (FIELD_FLOOR),
-- and the top-left is `y - height * scale` so scaling up grows toward the
-- sky instead of through the command box. Foe rows keep the old top-left
-- anchor; if they ever scale away from 1x, feet and centre are preserved the
-- FOE_SCALE way.
--
-- Returns `x, y, scale`, or nil for a slot that is not on the center stage.
function M:picOriginFor(index, sprite)
  if not self:onStage(index) then return nil end
  local ally = not self:foeSide(index)
  local anchor = ally and STAGE_ALLY or STAGE_FOE
  local scale = ally and ALLY_SCALE or FOE_SCALE
  local slide = ally and self.slideAlly or self.slideFoe
  local dx = slideDx(slide, index, ally)
  local x = anchor.x + dx
  local y = ally and FIELD_FLOOR or anchor.y
  local sw, sh
  if sprite then
    local ok, w, h = pcall(sprite.getDimensions, sprite)
    if ok then sw, sh = w, h end
  end
  if ally then
    local w = sw or 56
    local h = sh or 56
    -- Keep the back out of the left strip and out of the ally HUD: grow up
    -- to ALLY_SCALE, then right-align against the box so it reads close to
    -- the status panel without painting through it.
    local stripRight = STRIP_ICON
    local hudLeft = ALLY_HUD.tx * 8
    local lane = math.max(8, hudLeft - stripRight)
    if w > 0 then
      scale = math.min(scale, lane / w)
    end
    x = hudLeft - w * scale + dx
    if x < stripRight + dx then x = stripRight + dx end
    local inset = ALLY_FOOT_INSET
    if inset > h - 8 then inset = 0 end
    y = FIELD_FLOOR - (h - inset) * scale
  elseif scale ~= PIC_SCALE then
    if sw and sh then
      x = x + (1 - scale) * sw / 2
      y = y + (1 - scale) * sh
    else
      scale = PIC_SCALE
    end
  end
  return x, y, scale
end

-- Back to front among on-stage slots only. Whoever should read as "in front"
-- paints last: hovered foe while targeting, otherwise the spotlight slot.
function M:paintOrder()
  local top = self:spotlight()
  if self.phase == "target" and self.sim then
    local mine = self:mySlot()
    local targets = mine and self.sim:targetsFor(mine) or {}
    local hovered = targets[self.targetIndex or 1]
    if hovered then top = hovered.index end
  end
  local seen, order = {}, {}
  local function add(index)
    if not index or seen[index] then return end
    seen[index] = true
    order[#order + 1] = index
  end
  local function addSlide(slide)
    if not slide then return end
    add(slide.out)
    add(slide.into)
  end
  addSlide(self.slideAlly)
  addSlide(self.slideFoe)
  if not self.slideAlly then add(self:allyFocus()) end
  if not self.slideFoe then add(self:foeFocus()) end
  if top and seen[top] then
    for i, index in ipairs(order) do
      if index == top then
        table.remove(order, i)
        break
      end
    end
    order[#order + 1] = top
  end
  return order
end

local function drawStripIcon(self, battler, x, y)
  local Font = engine.Font
  local g = love and love.graphics
  local sprite = battler and battler.sprite
  if sprite and g and g.setScissor then
    local sw, sh = 56, 56
    local ok, w, h = pcall(sprite.getDimensions, sprite)
    if ok and type(w) == "number" and w > 0 then sw, sh = w, h end
    local scale = STRIP_ICON / math.max(sw, sh, 1)
    local dw, dh = sw * scale, sh * scale
    local ox = x + math.floor((STRIP_ICON - dw) / 2)
    local oy = y + math.floor((STRIP_ICON - dh) / 2)
    g.setColor(1, 1, 1, 1)
    g.setScissor(x, y, STRIP_ICON, STRIP_ICON)
    pcall(g.draw, sprite, ox, oy, 0, scale, scale)
    g.setScissor()
    return
  end
  if sprite then
    love.graphics.setColor(1, 1, 1, 1)
    local sw, sh = 56, 56
    local ok, w, h = pcall(sprite.getDimensions, sprite)
    if ok and type(w) == "number" and w > 0 then sw, sh = w, h end
    local scale = STRIP_ICON / math.max(sw, sh, 1)
    love.graphics.draw(sprite, x, y, 0, scale, scale)
    return
  end
  local letter = "?"
  if battler and battler.name and battler.name ~= "" then
    letter = battler.name:sub(1, 1):upper()
  end
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(letter, x + 4, y + 4)
end

local function drawSideStrip(self, seats, left, focused)
  if not seats or #seats == 0 then return end
  local Font = engine.Font
  local g = love and love.graphics
  -- Start below the foe HUD row so strip icons do not sit under the name box.
  local top = left and 48 or 8
  local x = left and 0 or (160 - STRIP_ICON)
  -- Solid white rail behind the icons so a wide stage pic cannot show
  -- through (strips draw after pics, but translucent / sparse sprites still
  -- read as muddy without a paper backing).
  local h = #seats * STRIP_ICON + math.max(0, #seats - 1) * 2
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", x, top, STRIP_ICON, h)
  for i, index in ipairs(seats) do
    local y = top + (i - 1) * (STRIP_ICON + 2)
    local battler = self:shownBattlerAt(index)
    drawStripIcon(self, battler, x, y)
    if index == focused then
      love.graphics.setColor(0, 0, 0, 1)
      local ay = y + 4
      if left then
        -- 0xED is the right-pointing cursor; mirror it so the left strip's
        -- arrow points at the icon (◀) rather than away into the field.
        local ax = x + STRIP_ICON
        if g and g.push and g.scale then
          g.push()
          g.translate(ax + 8, ay)
          g.scale(-1, 1)
          Font.drawCode(0xED, 0, 0)
          g.pop()
        else
          Font.drawCode(0xED, ax, ay)
        end
      else
        Font.drawCode(0xED, x - 8, ay)
      end
    end
  end
end

function M:drawField()
  local hideFoes = self:showingTrainer()
  local introHide = self.introHide

  for _, index in ipairs(self:paintOrder()) do
    local slot = self.sim:slot(index)
    local battler = self:shownBattlerAt(index)
    local theirs = self:foeSide(index)
    local sinking = self:sinkingAt(index)
    local sprite = (sinking and sinking.battler and sinking.battler.sprite)
      or (battler and battler.sprite)
    local x, y, scale = self:picOriginFor(index, sprite)
    local hideIntro = introHide and introHide[index]
    if sprite and x and not (hideFoes and theirs)
       and not (theirs and self.foePicHidden)
       and not hideIntro then
      if sinking then
        love.graphics.setColor(1, 1, 1, 1)
        pcall(drawSinking, sprite, x, y, sinking.frames, scale)
      elseif not hidden(slot, battler) then
        local gs = self:growInScale(index)
        if gs == 0 then
          -- Ball beat: blank until the first grow stage.
        else
          local drawScale = scale
          local dx, dy = x, y
          if gs then
            drawScale = scale * gs
            local sw, sh = 56, 56
            local ok, w, h = pcall(sprite.getDimensions, sprite)
            if ok and type(w) == "number" then sw, sh = w, h end
            -- Feet + horizontal centre pinned (BattleState AnimateSendingOutMon).
            dx = x + sw * scale * (1 - gs) / 2
            if not theirs then
              local inset = ALLY_FOOT_INSET
              if inset > sh - 8 then inset = 0 end
              dy = FIELD_FLOOR - (sh - inset) * drawScale
            else
              dy = y + sh * scale * (1 - gs)
            end
          end
          love.graphics.setColor(1, 1, 1, 1)
          love.graphics.draw(sprite, dx, dy, 0, drawScale, drawScale)
        end
      end
    end
  end
  if self:showingTrainer() and self.trainerPic then
    love.graphics.setColor(1, 1, 1, 1)
    local ok = pcall(love.graphics.draw, self.trainerPic, 100, 0)
    if not ok then self.trainerPic = nil end
  end
  -- Strips after stage pics so a wide foe/ally sprite cannot cover an icon
  -- or its focus arrow when they share the edge.
  drawSideStrip(self, self:stripSeats(false), true, self:desiredAllyFocus())
  drawSideStrip(self, self:stripSeats(true), false, self:desiredFoeFocus())
  local foe = self:desiredFoeFocus()
  local Font = engine.Font
  if foe then
    local battler = self:shownBattlerAt(foe)
    local slot = self.sim:slot(foe)
    if battler and not hidden(slot, battler)
       and not (introHide and introHide[foe]) then
      Font.drawBox(FOE_HUD.tx, FOE_HUD.ty, FOE_HUD.tw, FOE_HUD.th)
      drawReadout(self, battler, FOE_HUD, 1, foe == self.mine)
    end
  end
  local ally = self:desiredAllyFocus()
  if ally then
    local battler = self:shownBattlerAt(ally)
    local slot = self.sim:slot(ally)
    if battler and not hidden(slot, battler)
       and not (introHide and introHide[ally]) then
      Font.drawBox(ALLY_HUD.tx, ALLY_HUD.ty, ALLY_HUD.tw, ALLY_HUD.th)
      drawReadout(self, battler, ALLY_HUD, 1, ally == self.mine)
    end
  end
  self:drawIntroBalls()
end

-- Party ball chrome under the opening appear line (both humans' parties).
-- Trainer theatrical also draws the foe party row (classic top-left).
-- Positions approximate classic player row + a second row for the partner.
function M:drawIntroBalls()
  if not self.introBalls then return end
  local BS = engine and engine.BattleState
  if not (BS and BS.drawBallRow and love and love.graphics) then return end
  local mySlot = self:mySlot()
  local partner = self:partnerOf(mySlot)
  love.graphics.setColor(1, 1, 1, 1)
  if self:usesTrainerIntro() then
    local foeParty = self:foeIntroParty()
    if foeParty then
      pcall(BS.drawBallRow, BS, foeParty, 64, 16, -8)
    end
  end
  if mySlot and mySlot.party then
    pcall(BS.drawBallRow, BS, mySlot.party, 88, 80, 8)
  end
  if partner and partner.party then
    pcall(BS.drawBallRow, BS, partner.party, 88, 64, 8)
  end
end

-- This screen resolves its own colours.
--
-- Every pixel on it is already palette-correct: the pictures come out of the
-- engine's cache with their species palette applied, and the boxes and glyphs
-- are the engine's own. So the colourising display modes are told to leave the
-- surface alone rather than remap what is already right -- the same opt-out
-- WideBattle takes. Without it the same battle renders differently from one
-- instance to the next depending on which display mode each player picked,
-- which is exactly what two side-by-side clients showed.
-- **The rect is in the RECEIVING generation's space, which is not the space
-- this screen draws in.** MediatedBattle's twin of this function carries the
-- full note: Gen 1 zone rects are the widened UI canvas' own coordinates, and
-- Gold's are always 160x144 screen space whatever the state drew
-- (`Game2:blitZones` scales by `w/160, h/144` before it scissors). A 640-wide
-- rect on Gold means 4x the window, and only rendered correctly because that
-- clamps back to the window -- while still forcing every frame onto the
-- present-canvas path.
function M:zones()
  local w, h = 160, 144
  if self.uiSize and self:generation() ~= 2 then
    local ok, aw, ah = pcall(self.uiSize, self)
    if ok and type(aw) == "number" and type(ah) == "number" then
      w, h = aw, ah
    end
  end
  return { { colors = false, x = 0, y = 0, w = w, h = h } }
end

-- Gen1 hard-cut onto the top-down Battlefield theatre. Gen2 keeps the
-- guild-focus classic stage (STAGE_*/strips) entirely.
function M:usesBattlefield()
  return Battlefield.enabled(self.game) and true or false
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

-- White letterbox voids so arena edges match the surround (same habit as
-- engine BattleState) -- on the **classic** stage, which is a white 160×144
-- canvas the paper shade matches exactly. Harmless on the classic Gen2 path.
--
-- How the flag is read, because it decides how it can be answered: the
-- presenter walks the whole state stack top-down once a frame looking for any
-- state whose `letterboxWhite` is truthy, and fills the voids with
-- `PaletteFX.paperShade` when it finds one (engine
-- src/render/Renderer.lua:809-830). It is a plain field read and never a
-- call -- so a screen that wants a different answer per display mode has to
-- shadow the class default on the instance, which is what `refreshLetterbox`
-- below does.
--
-- The arena is not a white canvas. It is edge-to-edge art with its own dark
-- chrome, and in SGB mode the paper shade is an off-white pink -- so the
-- surround read as the overworld's paper bleeding into the theatre, which is
-- the leak this fixes. MediatedBattle simply never sets the flag (see the
-- `isOpaque` comment in its state table) and gets the engine default, black;
-- this screen cannot, because Gen 2 still runs the classic stage through the
-- same object.
M.letterboxWhite = true

-- Put the flag where the display mode says it belongs. One generation lookup,
-- idempotent, so it can run on the way in and on every update -- the mode can
-- move under a hot reload, and the presenter would keep reading a stale answer
-- off the instance forever otherwise.
function M:refreshLetterbox()
  local ok, wide = pcall(self.usesBattlefield, self)
  if not ok then return end
  -- `false` rather than nil: nil falls back through `__index` to the class
  -- default above and paints paper round the arena again.
  self.letterboxWhite = not wide
end

-- ------- Battlefield theatre helpers (Gen1 only)

local BATTLEFIELD_BUBBLE_LIFE = 90
-- Classic message/command chrome lives in the bottom ~48px of 160×144
-- (Font.drawBox tile row 12 → y=96). Mapped into MENU_BAND on the wide canvas.
local CLASSIC_MENU_TOP = 96
local CLASSIC_MENU_H = 48

local function battlefieldFrame(self)
  if type(self.frame) == "number" then return self.frame end
  if love and love.timer and love.timer.getTime then
    return love.timer.getTime() * 60
  end
  return 0
end

local function moveNameFromBattleText(text)
  if type(text) ~= "string" then return nil end
  local move = text:match("[Uu]sed\n([^\n!]+)")
    or text:match("[Uu]sed%s+([^\n!]+)")
  if not move then return nil end
  move = move:gsub("^%s+", ""):gsub("%s+$", "")
  if move == "" then return nil end
  return move
end

-- Soft roster / self look lookup. Never throws; missing exports just omit
-- the walk sheet (Battlefield draws a silhouette).
local function exportPlayers()
  local ok, list = pcall(function()
    if mod.exports and type(mod.exports.players) == "function" then
      return mod.exports.players()
    end
  end)
  if ok and type(list) == "table" then return list end
  return nil
end

local function selfLookId()
  local ok, id = pcall(function()
    if mod.exports and type(mod.exports.myLook) == "function" then
      return mod.exports.myLook()
    end
  end)
  if ok and type(id) == "string" and id ~= "" then return id end
  ok, id = pcall(function()
    local chosen = mod.save and mod.save.get and mod.save:get("sprite")
    if type(chosen) ~= "string" or chosen == "" then
      chosen = mod.options and mod.options.get and mod.options:get("sprite")
    end
    return chosen
  end)
  if ok and type(id) == "string" and id ~= "" then return id end
  return nil
end

local function ownerLookId(ownerId, selfId)
  if ownerId == nil then return nil end
  if selfId ~= nil and ownerId == selfId then return selfLookId() end
  local players = exportPlayers()
  if not players then return nil end
  for _, p in ipairs(players) do
    if p and p.id == ownerId and type(p.sprite) == "string" and p.sprite ~= "" then
      return p.sprite
    end
  end
  -- Roster may be a map keyed by id.
  local row = players[ownerId]
  if row and type(row.sprite) == "string" and row.sprite ~= "" then
    return row.sprite
  end
  return nil
end

-- ------- trainer class → overworld walk sheet
--
-- There is no class→sprite field anywhere in engine data. A trainer record
-- (`data.trainers`) carries the battle front pic, the parties and the prize
-- money, and says nothing about the overworld; the walk sheet is chosen per
-- **map object**, where `data.maps[*].objects[*]` pairs a `sprite` with the
-- `trainerClass` that object fights as. That is still a real mapping, just an
-- indirect one -- so it is read out of the data rather than hand-written here:
-- every object naming a class votes for the sheet it is drawn with, and the
-- class takes the sheet with the most votes.
--
-- Which is what the name transform below cannot do on its own. Red has no
-- SPRITE_LASS and no SPRITE_BUG_CATCHER -- those classes walk around as
-- SPRITE_COOLTRAINER_F and SPRITE_YOUNGSTER -- so `OPP_BUG_CATCHER` resolved to
-- nothing, `battlefieldFoeHumans` returned an empty list, and a coop_npc fight
-- announced "BUG CATCHER wants to fight!" over an empty right-hand edge.
--
-- Ties break on id order so two clients never disagree about a class, and the
-- whole walk is memoised against the maps table it was built from: one pass
-- over ~250 maps per boot, and none at all once a battle is running.
local trainerSpriteVotes = nil
local trainerSpriteVotesFrom = nil

local function trainerSpritesByClass(data)
  local maps = type(data) == "table" and data.maps or nil
  if type(maps) ~= "table" then return nil end
  if trainerSpriteVotesFrom == maps then return trainerSpriteVotes end

  local votes = {}
  local ok = pcall(function()
    for _, map in pairs(maps) do
      if type(map) == "table" and type(map.objects) == "table" then
        for _, obj in pairs(map.objects) do
          if type(obj) == "table" then
            local class, sprite = obj.trainerClass, obj.sprite
            if type(class) == "string" and class ~= ""
               and type(sprite) == "string" and sprite ~= "" then
              local bucket = votes[class]
              if not bucket then
                bucket = {}
                votes[class] = bucket
              end
              bucket[sprite] = (bucket[sprite] or 0) + 1
            end
          end
        end
      end
    end
  end)
  if not ok then return nil end

  local out = {}
  for class, bucket in pairs(votes) do
    local best, bestN = nil, -1
    for sprite, n in pairs(bucket) do
      if n > bestN or (n == bestN and (best == nil or sprite < best)) then
        best, bestN = sprite, n
      end
    end
    out[class] = best
  end
  trainerSpriteVotes = out
  trainerSpriteVotesFrom = maps
  return out
end

-- Last resort, best first: a class nobody walks around as on any map (the
-- unused ones, and anything a mod adds without an overworld object) still gets
-- a body on the field rather than an empty foe edge. Probed against the
-- catalog, so a build without one of these falls to the next.
local GENERIC_TRAINER_SPRITES = {
  "SPRITE_COOLTRAINER_M", "SPRITE_YOUNGSTER", "SPRITE_GENTLEMAN",
}

-- OPP_YOUNGSTER → SPRITE_YOUNGSTER when the catalog has a walk sheet; the
-- overworld's own answer for the classes it does not (OPP_LASS,
-- OPP_BUG_CATCHER, …); a generic trainer after that.
local function trainerWalkSpriteId(trainer, game)
  if type(trainer) ~= "table" then return nil end
  local id = trainer.id or trainer.sprite or trainer.spriteId
  if type(id) ~= "string" or id == "" then return nil end
  local spriteId = id
  if spriteId:match("^OPP_") then
    spriteId = "SPRITE_" .. spriteId:sub(5)
  elseif not spriteId:match("^SPRITE_") then
    spriteId = "SPRITE_" .. spriteId
  end
  -- `Gen.spriteCatalog`, not `data.sprites`: Gold keeps its walk sheets on
  -- `data.gen2Sprites`, and reading Gen 1's table on a Gold boot proves nothing
  -- about a sheet that is really there.
  local sprites = Gen.spriteCatalog(game)
  if type(sprites) == "table" and type(sprites[spriteId]) == "table" then
    return spriteId
  end
  -- Soft: accept the id even if we cannot prove the sheet exists here;
  -- Battlefield.resolveHumanSheet will silhouette if load fails.
  if sprites == nil then return spriteId end
  if type(sprites) ~= "table" then return nil end

  local byClass = trainerSpritesByClass(data)
  local mapped = byClass and byClass[id] or nil
  if type(mapped) == "string" and type(sprites[mapped]) == "table" then
    return mapped
  end
  for _, generic in ipairs(GENERIC_TRAINER_SPRITES) do
    if type(sprites[generic]) == "table" then return generic end
  end
  return nil
end

-- Resolve a battle FRONT pic for the field (not the bag-icon sheet — those
-- are 16×N and smash when stretched). Ally battlers hold backs in classic
-- co-op; the arena wants the front for both sides. Cached on the sim slot.
local function seatFrontFor(self, slot, battler)
  if not battler then return nil end
  local mon = battler.mon
  local species = mon and mon.species
  if slot and slot._bfFront ~= nil and slot._bfFrontSpecies == species then
    local cached = slot._bfFront
    return (cached ~= false) and cached or nil
  end
  local resolved = nil
  local eng = engine
  local data = self.game and self.game.data
  local save = self.game and self.game.save
  -- The one genuinely generation-shaped source the theatre needs. On Gen 1,
  -- makeBattler(..., isPlayer=false) loads the species front with palette; that
  -- module does not exist on Gold, which keeps the front path on the species
  -- record itself (`def.spriteFront`, what `src/ui/gen2/BattleState.lua:pic`
  -- reads). MediatedBattle's `seatFront` is the twin of this branch and carries
  -- the fuller note on what the Gold arm deliberately does not reproduce.
  if Gen.generation(self.game) == 2 then
    local def = data and type(data.pokemon) == "table" and species
      and data.pokemon[species] or nil
    local path = type(def) == "table" and def.spriteFront or nil
    if type(path) == "string" and path ~= "" then
      -- Baked, not loaded raw -- see `Battlefield.gen2FrontImage`.
      local shiny = (mon and mon.shiny) and true or false
      resolved = Battlefield.gen2FrontImage(self.game, species, path, shiny)
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
  -- Fall back to whatever the live battler already holds (may be a back).
  if not resolved then resolved = battler.sprite end
  if slot then
    slot._bfFront = resolved or false
    slot._bfFrontSpecies = species
  end
  return resolved
end

-- Resolve a party bag icon to a cached Image on the sim slot (once per
-- species). Only used as a last-resort field fallback / strip helper.
local function seatIconFor(self, slot, battler)
  if not battler then return nil end
  local mon = battler.mon
  local species = mon and mon.species
  if slot and slot._bfIcon ~= nil and slot._bfIconSpecies == species then
    local cached = slot._bfIcon
    return (cached ~= false) and cached or nil
  end
  local resolved = nil
  local eng = engine
  local Sprites = eng and eng.Sprites
  local data = self.game and self.game.data
  if Sprites and Sprites.iconPath and mon and data then
    local path = nil
    pcall(function()
      local icons = data.icons
      local def = data.pokemon and data.pokemon[mon.species]
      local entry = (icons and icons.bySpecies and icons.bySpecies[mon.species])
        or (def and def.icon)
      local name
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
      path = Sprites.iconPath(data, mon, path, { name = name })
    end)
    if type(path) == "string" and path ~= "" then
      local ok, img = pcall(function()
        if love and love.graphics and love.graphics.newImage then
          return love.graphics.newImage(path)
        end
        return nil
      end)
      if ok and img then resolved = img end
    end
  end
  if slot then
    slot._bfIcon = resolved or false
    slot._bfIconSpecies = species
  end
  return resolved
end

function M:ensureBattlefieldLoaded()
  if self.battlefieldLoaded then return end
  self.battlefieldLoaded = true
  pcall(Battlefield.reloadArena)
  pcall(Battlefield.load, mod)
end

-- Living active field seats for one side (viewer-relative), for Battlefield.
--
-- A seat that is *sinking* is still a seat. `startFaint` raises
-- `displayFainted` before the fall so the classic stage can hand the pic to
-- `drawSinking`, which means `hidden` answers yes for the whole of a sink --
-- and on the arena, where the fall is an fx entry against the seat rather than
-- a separate draw call, that took the monster off the field a beat before it
-- fell. The two paths never both draw it: `drawField` is the classic stage and
-- `Battlefield.draw` is this one, so there is no sink offset applied twice.
function M:battlefieldSeats(theirs)
  local out = {}
  if not self.sim then return out end
  local introHide = self.introHide
  for _, slot in ipairs(self.sim.slots or {}) do
    if self:foeSide(slot.index) == (theirs and true or false) then
      local battler = self:shownBattlerAt(slot.index)
      local sinking = self:sinkingAt(slot.index)
      local falling = sinking ~= nil and battler ~= nil and not slot.gone
        and sinking.battler == battler
      if (falling or not hidden(slot, battler))
         and not (introHide and introHide[slot.index]) then
        local mon = battler.mon or {}
        -- The exp strip belongs to *this client's own seat* and no other, for
        -- the plainest reason: `gainExp` returns early on any slot but
        -- `self.mine`, so it is the only seat whose clocks are ever moved. A
        -- foe never earns exp at all; a partner earns it on their own client,
        -- where it is their own seat. Seeding the partner's plate here bought
        -- a strip that then sat frozen for the whole battle -- an empty trough
        -- over a monster that had just levelled, which reads as a bug rather
        -- than as the absence of information it actually is.
        --
        -- Both other seats pass neither field, which is `plateModel`'s
        -- documented no-data state: no strip, and a level pill printed from
        -- the real level -- which for a partner is the *live* level, so their
        -- pill is right the moment their mon levels instead of trailing a
        -- clock nothing on this client advances.
        --
        -- Seeded here, on first sight, because this is where a battler is
        -- first *noted* by the display: `seedExpClock` only ever fills a nil,
        -- so a strip mid-fill is never disturbed by a draw.
        local expFrac, shownLevel
        if not theirs and slot.index == self.mine then
          self:seedExpClock(battler)
          expFrac = battler.shownExpFrac
          shownLevel = battler.shownLevel
        end
        out[#out + 1] = {
          index = slot.index,
          name = battler.name or mon.nickname or mon.species or "?",
          level = mon.level or 1,
          -- The seat HP contract (see Battlefield.cardModel): `hp` is the sim's
          -- truth and `shownHp` is the display clock the bar is drawn from. The
          -- gap between them *is* the drain, and passing the clock as both left
          -- the arena unable to tell a bar mid-fall from a monster that really
          -- had that much left.
          hp = mon.hp or 0,
          shownHp = displayHP(battler),
          -- `stats.hp` is where a co-op mon keeps its maximum (`startDrain`
          -- reads the same field); `maxHp` is the mediated sheet's spelling and
          -- is honoured first for a battler built from one. Falling through to
          -- `mon.hp` last -- the current number -- is a full bar whatever has
          -- happened, which is why the plates never moved before the display
          -- clock was split out.
          maxHp = mon.maxHp or (mon.stats and mon.stats.hp) or mon.hp or 1,
          status = mon.status,
          species = mon.species,
          -- Display clocks, not truth: the strip trails `mon.exp` and the
          -- pill trails `mon.level` for exactly as long as a queued fill
          -- takes to play (see `startExpFill`).
          expFrac = expFrac,
          shownLevel = shownLevel,
          icon = seatIconFor(self, slot, battler),
          front = seatFrontFor(self, slot, battler),
          acting = (self.acting == slot.index)
            or (self.anim and self.anim.from == slot.index) or false,
        }
      end
    end
  end
  return out
end

function M:battlefieldAllyHumans()
  local humans = {}
  local mine = self:mySlot()
  if not mine then return humans end
  local mySide = mine.side
  for _, slot in ipairs((self.sim and self.sim.slots) or {}) do
    if slot.side == mySide and slot.owner ~= nil and not slot.gone then
      -- Prefer self first, then partner, in seat order otherwise.
      humans[#humans + 1] = {
        id = slot.owner,
        name = slot.name,
        spriteId = ownerLookId(slot.owner, self.selfId),
        _mine = (slot.index == self.mine),
      }
    end
  end
  table.sort(humans, function(a, b)
    if a._mine ~= b._mine then return a._mine end
    return tostring(a.id) < tostring(b.id)
  end)
  for _, h in ipairs(humans) do h._mine = nil end
  return humans
end

function M:battlefieldFoeHumans()
  local mode = self.mode
  if mode == "coop_wild" then return {} end
  -- Host-sim NPC fights may omit mode; treat trainer + ownerless foes as npc.
  local npcShape = mode == "coop_npc"
    or (mode == nil and self.trainer and not self:partyBattle())
  if npcShape then
    -- The trainer is on the field whether or not we can name their walk sheet,
    -- so the entry is unconditional now: this used to bail on a nil spriteId,
    -- which is exactly what emptied the foe edge of every BUG CATCHER / LASS
    -- fight. `trainerWalkSpriteId` almost always answers (name transform →
    -- overworld vote → generic); on the rare nil, Battlefield draws the
    -- silhouette, which is still a trainer standing there.
    --
    -- One entry, and never a player's: this branch is the NPC shape, so the
    -- foe seats are ownerless by construction and no seat walk runs here.
    return {
      {
        id = self.trainer and self.trainer.id,
        name = (self.trainer and self.trainer.name) or self:trainerIntroName(),
        spriteId = trainerWalkSpriteId(self.trainer, self.game),
      },
    }
  end
  -- coop_pvp (and any other human-foe shape): opposing player seats.
  local humans = {}
  local mine = self:mySlot()
  local mySide = mine and mine.side
  for _, slot in ipairs((self.sim and self.sim.slots) or {}) do
    if slot.side ~= mySide and slot.owner ~= nil and not slot.gone then
      humans[#humans + 1] = {
        id = slot.owner,
        name = slot.name,
        spriteId = ownerLookId(slot.owner, self.selfId),
      }
    end
  end
  return humans
end

-- 1-based index into allyHumans / foeHumans for a field seat's bubble host.
-- Human-owned seats match by owner id. coop_npc foe seats (owner nil) map to
-- foe human 1 when a trainer human is shown. coop_wild has no foe humans, so
-- ownerless foes stay unmapped.
function M:battlefieldHumanIndex(slotIndex)
  local slot = self.sim and self.sim:slot(slotIndex)
  if not slot then return nil, nil end
  local theirs = self:foeSide(slotIndex)
  local humans = theirs and self:battlefieldFoeHumans()
    or self:battlefieldAllyHumans()
  if slot.owner then
    for i, h in ipairs(humans) do
      if h.id == slot.owner then
        return theirs and "foe" or "ally", i
      end
    end
  end
  -- NPC trainer bubble host: any foe seat without a matching owner maps to
  -- human 1 when we drew a trainer on the right.
  if theirs and #humans == 1 and slot.owner == nil then
    return "foe", 1
  end
  return nil, nil
end

-- The acting monster's display name, spelled exactly as the plates spell it
-- (`battlefieldSeats` uses the same fallback chain) so the callout and the seat
-- under it never disagree. Soft: a stale slot index is a bubble without a name
-- line, never a throw out of a message pump.
local function actingMonName(self, slotIndex)
  if type(slotIndex) ~= "number" then return nil end
  local ok, battler = pcall(self.shownBattlerAt, self, slotIndex)
  if not ok or not battler then return nil end
  local mon = battler.mon or {}
  local name = battler.name or mon.nickname or mon.species
  if type(name) == "string" and name ~= "" then return name end
  return nil
end

-- One attack, spelled two ways.
--
-- The referee narrates a move under its **id** (`_say(species .. " used " ..
-- move.id)` in BattleSim/Turn.lua and its Node twin) while the anim row beside
-- it carries the registry **name**, so "DOUBLE_KICK" and "DOUBLE KICK" reach
-- this function one after the other for a single attack. Folded to one key so
-- the shout cannot be raised twice under two spellings of the same move.
local function calloutKey(move)
  local key = tostring(move):upper():gsub("[%s_]+", " ")
  return key
end

-- Raise the trainer's shout for an attack -- **once**.
--
-- Returns `spoke, raised`:
--
--   * `spoke` -- there is a shout up for this seat now. `splitCalloutBeat`
--     reads it: a seat with nobody to shout for it (a coop_wild foe, the
--     classic stage, a ball marker) must not stall the arena on a bubble that
--     was never drawn.
--   * `raised` -- ...and it is a *new* one. Only a new shout means a new
--     attack, which is what re-arms the callout beat (see `update`'s text
--     branch).
--
-- **The two directions one attack arrives from.** A move reaches here from the
-- anim row (`splitCalloutBeat`) *and* from the "X used MOVE" line beside it
-- (`update`'s text branch), and the referee does not even agree with itself
-- about which comes first: the Node half emits `anim` before it says the
-- sentence, CoopSim says the sentence first. Whichever arrives first shouts;
-- the other refreshes it. Without that, one attack raised the bubble two and
-- three times -- and because the move animation runs between them, the second
-- raise landed after the first had begun shrinking (or expired outright on a
-- long animation), which is a trainer who shouts the same order twice.
--
-- A refresh is deliberately *not* a raise: it extends the life of the shout it
-- is part of -- which is what a multi-hit move wants, one announcement whose
-- bubble lasts the flurry -- without restarting the scale-in the renderer
-- drives off `t`.
--
-- The key is cleared with `calloutSpent`, in `snapDisplay`: both are "what the
-- attack now playing has already had", and both are reset when the queue hands
-- back to a menu.
function M:noteBattlefieldBubble(slotIndex, text, moveName)
  if not self:usesBattlefield() then return false end
  local move = moveNameFromBattleText(text)
  if type(moveName) == "string" and moveName ~= "" then move = moveName end
  if not move then return false end
  -- The engine's ball / hide / shake markers are not move callouts, and one of
  -- them reaching here is a bubble that says "used TOSS_ANIM!" over the
  -- trainer's head. The call sites filter them, and so does this: the message
  -- path below parses the name out of arbitrary battle text, so a referee
  -- sentence carrying a marker would otherwise arrive by the back door.
  if move:find("_ANIM", 1, true) then return false end
  -- Humans + coop_npc foe seats (owner nil → foe human 1). coop_wild foes
  -- have no foeHumans, so battlefieldHumanIndex returns nil.
  local side, humanIndex = self:battlefieldHumanIndex(slotIndex)
  if not side then return false end
  local key = calloutKey(move)
  local shout = self.calloutShout
  if shout and shout.slot == slotIndex and shout.key == key then
    -- Already shouted. Refresh the bubble that is up so the announcement lasts
    -- the attack it belongs to, and raise nothing.
    local live = self.battlefieldBubbles and self.battlefieldBubbles[1]
    if live then live.born = battlefieldFrame(self) end
    return true, false
  end
  self.calloutShout = { slot = slotIndex, key = key }
  self.battlefieldBubbles = {
    {
      side = side,
      humanIndex = humanIndex,
      -- R3 item 5: line one is the monster, line two the move -- "PIKACHU!"
      -- over "THUNDERBOLT!". The emitter supplies the two words and the
      -- renderer owns the shouting; `text` stays as the lead-in it always was
      -- for the case where the actor cannot be named, which is the only way
      -- the old sentence still prints.
      name = actingMonName(self, slotIndex),
      text = "used",
      moveName = move,
      born = battlefieldFrame(self),
    },
  }
  return true, true
end

function M:battlefieldBubbleCtx()
  local bubbles = self.battlefieldBubbles
  if type(bubbles) ~= "table" or #bubbles == 0 then return nil end
  local frame = battlefieldFrame(self)
  local out = {}
  local keep = {}
  for _, b in ipairs(bubbles) do
    local age = frame - (tonumber(b.born) or frame)
    if age < BATTLEFIELD_BUBBLE_LIFE then
      keep[#keep + 1] = b
      out[#out + 1] = {
        side = b.side,
        humanIndex = b.humanIndex,
        text = b.text,
        -- Optional acting-mon name: when present it takes the top line and the
        -- lead-in text is not printed at all (Battlefield.bubbleLines).
        name = b.name,
        -- Optional, and only on a move callout: the renderer gives it its own
        -- larger line under the lead-in.
        moveName = b.moveName,
        t = 1 - (age / BATTLEFIELD_BUBBLE_LIFE),
      }
    end
  end
  self.battlefieldBubbles = (#keep > 0) and keep or nil
  return out
end

-- ------- arena effects (Gen1 battlefield only)
--
-- The screen owns the clock; Battlefield owns the shape. Every entry is
-- `{ kind, side, seatIndex, t }` by the time it reaches the renderer, and each
-- shape there is a pure function of `t` -- so a frame is reproducible and the
-- suite can assert one without a graphics context.
--
-- None of this exists on the classic 160×144 stage or on Gen 2: those draw
-- through `drawField`, which has its own sink (`drawSinking`) and no renderer
-- for anything else, so every emitter below is gated on `usesBattlefield()`.
--
-- Entries are held internally against the **sim slot** rather than against a
-- seat position: the arena seat index is the slot's place in the *drawn* list,
-- which is filtered (a fainted seat leaves it), so it can only honestly be
-- decided at ctx time. `battlefieldFxCtx` does that projection.

-- Effect lifetimes in seconds. Shared with MediatedBattle's twin table --
-- these two screens draw the same arena, and a throw that took longer on one
-- of them would be the same animation at two speeds.
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
}

-- The beats between the effects, in seconds. Not effects themselves -- nothing
-- is drawn for one, and `emitFx` must never be able to take a key from here --
-- so they are their own table rather than more `FX_SPAN` entries. Shared with
-- MediatedBattle's twin for the same reason `FX_SPAN` is: the two screens play
-- the same per-attack chronology and one of them running it at a different
-- tempo would be the same fight at two speeds.
--
-- The chronology these two split apart, in order: the trainer's callout, the
-- attacker's lunge, the defender's flash + the field's nudge, the HP bar, the
-- faint sink, the "fainted!" line, the switch choice, and the replacement
-- arriving on the field. The last four were already strictly ordered -- each
-- one holds the message queue by itself. The first four were two pairs, each
-- landing in a single tick, which is what these spans undo.
local BEAT_SPAN = {
  -- 1 -> 2. The shout is a moment of its own: the bubble goes up over the
  -- trainer, and only then does the monster lean in. Comfortably inside the
  -- bubble's own life (BATTLEFIELD_BUBBLE_LIFE, 90 frames) with the lunge's
  -- 0.35s on top -- 33 + 21 of 90 -- so the shout is still on screen for the
  -- whole of the lunge it introduces, which is the point of saying it first.
  callout = 0.55,
  -- 3 -> 4. The strike reads before the bar answers it: the defender flashes
  -- and the field takes its nudge with the bar held exactly where it was, and
  -- only once that has been seen does the drain start. Deliberately shorter
  -- than the flash it opens (FX_SPAN.flash is 0.30 too, and `stepFx` keeps
  -- running through the hold) so the white is still fading off the defender as
  -- the bar begins to move -- the two are one hit, not two.
  hit = 0.30,
}

-- Put `row` back at the head of the queue and hold everything for `span`.
--
-- The one primitive both splits below are made of, and the same one
-- `startBallFx` re-queues a SHAKE row with: the row is not consumed, it is
-- *deferred*, so the sequencer stays the message queue and nothing anywhere
-- has to keep a second clock. `update`'s beat branch is the other half.
--
-- Answers false when there is no queue to put the row back into, which is the
-- only way this can fail -- and the caller then does the unsplit thing rather
-- than dropping the row on the floor.
function M:holdBeat(row, span)
  if type(self.messages) ~= "table" then return false end
  span = tonumber(span)
  if not span or span <= 0 then return false end
  table.insert(self.messages, 1, row)
  self.beatHold = span
  self.beatDwell = nil
  return true
end

-- Beats 1 -> 2: the trainer shouts, and *then* the monster leans in.
--
-- These used to land in the same tick -- `startAnim` noted the bubble and
-- emitted the lunge one line apart -- so the callout was never a beat, only
-- decoration on the lunge. Now the bubble goes up alone, the anim row goes
-- back at the head of the queue, and the lunge plays `BEAT_SPAN.callout`
-- later with its own hold untouched.
--
-- **Once per attack, not once per strike.** A multi-hit move on the coop queue
-- is one announcement and one "used X!" line followed by an anim row per
-- strike: the engine reuses the announcement's row for hit 1 and inserts a
-- fresh `{ anim = move.id }` for every hit after it, each with that strike's
-- own drain row behind it (src/battle/EffectRegistry.lua, the `for h = 1, hits`
-- loop). Every one of those rows carries the same `from`, because CoopSim's
-- `drainInto` stamps the actor onto every event an action produced -- so the
-- row alone cannot tell "the move started" from "it landed again", and a
-- naive split shouted five times through one Fury Attack. The announcement
-- line is what owes the beat (`update`'s text branch clears `calloutSpent`
-- when it raises a shout) and the first anim row behind it spends it.
--
-- Returns true when it took the row: the caller must start nothing else this
-- tick. Returning false still means a shout is up for that seat -- a repeat
-- strike refreshes the one it is part of, exactly as it did before.
function M:splitCalloutBeat(row)
  if not self:usesBattlefield() then return false end
  if type(row) ~= "table" or row.from == nil then return false end
  -- **Only on the first pass.** The beat below puts this very row back at the
  -- head of the queue, so it arrives here twice for one strike; the second
  -- arrival is the lunge, and re-noting the bubble for it restarted a scale-in
  -- the lunge is meant to be read *under*. MediatedBattle's `startAnim` has
  -- guarded its own note this way since the split was written -- this is the
  -- half of that fix the co-op twin never got.
  if row.calledOut then return false end

  local moveName = row.anim
  local def = self.game and self.game.data and self.game.data.moves
    and self.game.data.moves[row.anim]
  if def and type(def.name) == "string" and def.name ~= "" then
    moveName = def.name
  end
  -- Raised first, and whether anything was shouted at all is the gate: a seat
  -- with no human to hang a bubble on (a coop_wild foe) gets no shout, and a
  -- beat spent waiting for one nobody can see is a fight that pauses for
  -- nothing. The answer comes back from `noteBattlefieldBubble` rather than
  -- from the identity of the bubble table: a re-note for an attack already
  -- shouted refreshes that bubble in place now, so identity would read a
  -- perfectly good shout as "nobody heard it".
  local spoke = self:noteBattlefieldBubble(row.from,
    "used\n" .. tostring(moveName) .. "!", tostring(moveName))
  if not spoke then return false end

  local spent = self.calloutSpent
  if spent and spent.from == row.from and spent.anim == row.anim then
    return false
  end
  if not self:holdBeat(row, BEAT_SPAN.callout) then return false end
  -- Marked with the beat, so the pass that comes back for the lunge is the one
  -- the guard at the top turns away.
  row.calledOut = true
  self.calloutSpent = { from = row.from, anim = row.anim }
  return true
end

-- Beats 3 -> 4: the defender takes the hit, and *then* the bar answers it.
--
-- `startDrain` used to flash the defender, nudge the field and start the bar
-- falling in one call, so the strike and its consequence were a single frame
-- and the flash simply happened to be visible over a moving bar. Now the hit
-- reads on its own with the bar frozen exactly where it was, and the drain
-- starts `BEAT_SPAN.hit` later.
--
-- Once per drain row rather than once per attack -- the opposite of the
-- callout, and deliberately: each strike of a multi-hit move gets its own
-- drain row with its own stop (`drainNext(target, stopAt)`), and each of those
-- is a separate blow that has to read as one.
--
-- Only a *fall*. The caller has already decided this row moves the bar
-- downwards; a heal, a drain move's restore, a Recover keeps no fx and so
-- needs no beat in front of one.
function M:splitHitBeat(row)
  if not self:usesBattlefield() then return false end
  if type(row) ~= "table" or row.beat then return false end
  -- Marked before the hold rather than after, so a row that somehow came back
  -- round a second time cannot flash twice for one blow.
  row.beat = true
  self:emitFx("flash", row.slot)
  self:emitFx("shake", row.slot)
  return self:holdBeat(row, BEAT_SPAN.hit)
end

-- The engine's ball markers, and what each one is on the arena. Ball ids vary
-- with the ball (`_emitBallChain` in BattleSim/Turn.lua picks the toss by
-- item), so the toss is listed three times rather than pattern-matched.
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
-- faint sink is (see `stepFx`): the queue leaves a frame or two between one row
-- ending and the next starting, and a monster that flickered back into view in
-- that gap would be out of the ball and in it again twice a throw.
--
-- **`ball` is not one of them**, and that is chronology rather than an
-- oversight. The arc is a ball travelling towards a monster that is still
-- standing there -- the occupant only goes in when HIDEPIC (`recall`) plays,
-- which is the row after. Listing the arc here did two wrong things at once:
-- it claimed the seat was occupied before the ball had arrived, and -- because
-- a held kind is never retired while the flow is open -- it parked a finished
-- pokeball on top of the seat (`drawFieldFx` draws `ball` at `fxBallPoint`,
-- which at t == 1 is the seat itself) for the gap between the arc and whatever
-- came next. `Battlefield.fxSeat` makes the same call on its side of the wire.
local BALL_HIDE_FX = { recall = true, wobble = true }

-- Most wobbles one SHAKE row is allowed to spend. Gen 1 counts three; the
-- number came off the wire, and a hub claiming a thousand would otherwise
-- queue a thousand rows the player cannot skip past.
local BALL_SHAKE_MAX = 8

-- Which arena side a field slot sits on, viewer-relative.
function M:fxSideFor(index)
  if index ~= nil and self:foeSide(index) then return "foe" end
  return "ally"
end

-- Start one effect. Returns the record so a caller that needs to wait on it can
-- hold the reference rather than search the list.
--
-- `own` is read by the `ball` kind alone and marks a **send**: the seat's own
-- trainer throwing their own monster out, which leaves that side's trainer
-- column instead of the one opposite (`Battlefield.ballOrigin`). Absent is a
-- catch throw, which is what every ball on this screen was before send-outs
-- grew one. Carried as nil rather than false so the published entry keeps the
-- shape the renderer's twin publishes.
function M:emitFx(kind, index, own)
  if not self:usesBattlefield() then return nil end
  local span = FX_SPAN[kind]
  if not span then return nil end
  local fx = {
    kind = kind,
    slot = index,
    side = self:fxSideFor(index),
    own = (own == true) or nil,
    t = 0,
    elapsed = 0,
    duration = span,
  }
  local list = self.fx
  if type(list) ~= "table" then
    list = {}
    self.fx = list
  end
  list[#list + 1] = fx
  return fx
end

-- ------- the ball flow
--
-- Up to six queued rows describe one throw -- toss, burst, recall, the shakes,
-- and the pair that ends a failure -- and each one is played here as it reaches
-- the head of the message queue, never when the packet carrying it arrived.
-- `_emitBallChain` (src/BattleSim/Turn.lua:1737, mirrored in
-- server/lib/battle) is the order they come in.

-- The seat a ball row is really about.
--
-- Every row in the chain is stamped with the *thrower's* slot, and the engine's
-- own chain hides the enemy pic whoever threw -- so the arc, the recall and the
-- wobbles all belong to a seat on the side opposite the thrower. A host-sim row
-- carries no slot at all (CoopField queues `attackerIsPlayer` and nothing
-- else), so that is the fallback, and viewer-relative either way.
-- The first seat on one side of the arena worth pointing an effect at.
--
-- "Worth" is doing work: `gone` is the seat having left the field entirely, but
-- a seat can also still be there with a monster that is down and waiting to be
-- replaced -- and a ball arcing at a corpse (or a lunge from one) is the wrong
-- seat when the side has another that is standing. So a live seat wins, and
-- the first non-`gone` one is the fallback when the whole side is down: an
-- effect on the wrong seat still beats an effect on nobody, which is what the
-- caller gets for a nil (`battlefieldFxCtx` drops a slotless entry).
function M:seatOnSide(wantFoe)
  local down = nil
  for _, slot in ipairs((self.sim and self.sim.slots) or {}) do
    if not slot.gone and self:foeSide(slot.index) == wantFoe then
      local isDown = false
      if self.sim and self.sim.isDown then
        local ok, res = pcall(self.sim.isDown, self.sim, slot)
        isDown = (ok and res) and true or false
      end
      if not isDown then return slot.index end
      if down == nil then down = slot.index end
    end
  end
  return down
end

-- Which arena side a row's actor is on, viewer-relative, as a `wantFoe` flag
-- for `seatOnSide`.
--
-- `from` is the honest answer and is always viewer-true. A host-sim row has
-- none -- `CoopField` queues `attackerIsPlayer` and nothing else -- so that is
-- the fallback, and it is why this exists as its own function: every consumer
-- of an anim row's actor has to fall back the same way or it silently does
-- nothing on the host-sim modes.
function M:actorIsFoe(row)
  if type(row) ~= "table" then return nil end
  if row.from ~= nil then return self:foeSide(row.from) and true or false end
  if row.attackerIsPlayer ~= nil then return not row.attackerIsPlayer end
  return nil
end

function M:ballTargetSlot(row)
  local threwFoe = self:actorIsFoe(row)
  if threwFoe == nil then threwFoe = false end
  -- The far side from the thrower. A catch is a wild fight, where there is
  -- exactly one seat over there; a 2-on-2 that somehow produced a throw still
  -- lands it on somebody rather than nobody.
  return self:seatOnSide(not threwFoe)
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

-- The monster is out of the ball (or the seat it was on is gone): drop the hold
-- that kept it hidden.
function M:clearBallFlow()
  local flow = self.ballFlow
  if not flow then return end
  self.ballFlow = nil
  self:dropBallFx(flow.side)
end

-- A ball marker reaches the head of the queue. Returns the effect kind it
-- played, or nil for a row with nothing left to show.
--
-- Only ever called from the battlefield branch of `startAnim`: the classic
-- 160×144 path and Gen 2 run the engine's AnimPlayer over these same rows and
-- have no arena for any of this.
function M:startBallFx(row)
  if not self:usesBattlefield() then return nil end
  if type(row) ~= "table" then return nil end
  local kind = BALL_FX[row.anim]
  if not kind then return nil end

  local index = self:ballTargetSlot(row)
  if index == nil then return nil end
  local side = self:fxSideFor(index)
  local flow = self.ballFlow
  if flow and flow.side ~= side then
    -- A throw at the other seat: the old one is over whatever it was waiting
    -- for, and leaving it held would keep a monster in a ball nobody threw.
    self:clearBallFlow()
    flow = nil
  end
  local hiddenNow = (flow ~= nil) and flow.hidden == true

  if kind == "poof" then
    -- A POOF outside a throw is the intro's own send-out marker: `queueIntroSendOut`
    -- stamps it with the seat **coming out** rather than with a thrower, and
    -- that seat is still under `introHide` while this row plays. Its burst is
    -- emitted at the reveal instead (`noteBattlefieldSpawn`), where there is a
    -- monster on the arena for it to happen over.
    if flow == nil then return nil end
    -- POOF is both halves of a throw: the ball bursting open on the way in, and
    -- the monster coming back out of it when it breaks free. Which one it is is
    -- which side of HIDEPIC the row landed on. A failure ends POOF + SHOWPIC
    -- and only the first of those is the reappearance -- the second would be a
    -- burst over a monster already standing there.
    if row.anim == "SHOWPIC_ANIM" and not hiddenNow then return nil end
    self:emitFx("poof", index)
    -- Either way the ball is open, so the hold that hid the seat for the arc
    -- ends here: a throw the referee gave no shakes at all ends on this row,
    -- and leaving the flow standing would keep the monster inside a ball that
    -- had already burst. The recall behind a real catch attempt opens a fresh
    -- flow of its own (HIDEPIC is the next row).
    self:clearBallFlow()
    -- ...and if it *was* hidden, this POOF is the monster coming back out.
    if hiddenNow then self:emitFx("spawn", index) end
    self.animHold = FX_SPAN.poof
    return kind
  end

  -- SHAKE carries the whole count on a single row (`anim("SHAKE_ANIM", shakes)`
  -- in both twins -- src/BattleSim/Turn.lua:1752), and the contract is one
  -- wobble per effect, so the row plays the first rock and puts the remainder
  -- back at the head of the queue. Still queue-ordered, and still one thing at
  -- a time: nothing behind it can start until the last wobble has been here.
  if kind == "wobble" then
    local left = math.floor(tonumber(row.amount) or 1)
    if left > BALL_SHAKE_MAX then left = BALL_SHAKE_MAX end
    if left > 1 and type(self.messages) == "table" then
      table.insert(self.messages, 1, {
        anim = row.anim, from = row.from, to = row.to,
        attackerIsPlayer = row.attackerIsPlayer, amount = left - 1,
      })
      -- ...and this row is now worth exactly one wobble, so say so.
      --
      -- `startAnim` hands `row.amount` straight to the engine AnimPlayer as
      -- `opts.shakes`, and the player draws that many passes of SHAKE_ANIM by
      -- itself. Splitting the row for the arena while leaving the count alone
      -- ran both fan-outs at once: a three-shake catch played 3 + 2 + 1 = six
      -- AnimPlayer passes across the three rows -- six tinks and roughly twice
      -- the dead time -- under three arena wobbles. One pass per row is the
      -- contract the split was made for.
      row.amount = 1
    end
  end

  -- The hiding kinds. The previous one is dropped in the same call the next is
  -- emitted in, and `stepFx` holds a finished one at its last frame, so the
  -- seat stays covered from the recall to the burst that undoes it.
  self:dropBallFx(side)
  self.ballFlow = { side = side, slot = index, hidden = hiddenNow or kind == "recall" }
  self:emitFx(kind, index)
  self.animHold = FX_SPAN[kind]
  return kind
end

-- A monster is revealed on its seat: burst, then scale in.
--
-- Called at the moment the pic actually becomes drawable rather than when the
-- POOF row played -- the intro holds the seat under `introHide` until the `act`
-- row behind the marker clears it, so a burst emitted with the marker would
-- have finished before there was anything on the arena to burst over. Paired
-- with the classic stage's `growIn`, which is the same beat on the other path.
function M:noteBattlefieldSpawn(index)
  if index == nil then return end
  if not self:usesBattlefield() then return end
  self:emitFx("poof", index)
  self:emitFx("spawn", index)
end

-- ------- the throw in front of an arrival
--
-- A monster does not simply materialise on its square: somebody throws it
-- there. The chronology the owner asked for is the original's -- the sentence
-- that says who is sending what, then the ball leaving that trainer's hand,
-- and only when it lands the burst and the monster scaling out of it. Three
-- beats, in three rows: the line is queued by whoever produced the send
-- (`medRows`, the intro), this is the arc, and the `swap` row behind it is the
-- reveal (`applySwap` -> `noteBattlefieldSpawn`).
--
-- **Nobody throws a wild POKeMON.** A wild side has no trainer standing on it
-- (`battlefieldFoeHumans` is empty for `coop_wild`), so a seat with no thrower
-- to hang the arc on keeps the plain burst-and-grow it has always had --
-- `battlefieldHumanIndex` is the same question the callout bubbles ask, and
-- answering it here rather than by mode keeps the two agreeing about who is on
-- the field.
--
-- Arena only. The classic 160x144 stage has no field to throw a ball across --
-- its send-out beat is `growIn`, which `applySwap` runs on both paths.
function M:queueSendBall(index)
  if index == nil then return false end
  if not self:usesBattlefield() then return false end
  if type(self.messages) ~= "table" then return false end
  if not self:sentByTrainer(index) then return false end
  self.messages[#self.messages + 1] = { ballsend = index }
  return true
end

-- Is there somebody to have sent this seat's monster out?
--
-- One question, two answers on it: whether an arrival is thrown or simply
-- appears, and whether it is narrated as somebody's send-out at all. A wild
-- POKeMON is neither -- it walks into the fight on its own -- and it is the
-- only seat that answers false, because every other shape of this screen
-- fields either a player or an NPC trainer. `battlefieldHumanIndex` is the
-- existing spelling of "who on the field owns this seat" (the callout bubbles
-- hang off the same answer), so the two cannot drift apart.
function M:sentByTrainer(index)
  if index == nil then return false end
  local ok, side = pcall(self.battlefieldHumanIndex, self, index)
  return (ok and side ~= nil) and true or false
end

-- The arc row reaching the head of the queue.
--
-- The seat is emptied for the flight and stays empty until the reveal drops
-- the hold -- the ball is *carrying* the monster, so anything standing on the
-- square while it flies is the arrival happening twice. `introHide` is that
-- hold: it already means "this seat has nobody on it yet" on both stages, and
-- an arrival is the same fact as an intro.
--
-- Held for the arc's own span, the way every ball row on this screen is held
-- (`startBallFx` sets `animHold` from the same table). A beat rather than an
-- `animHold` because there is no engine animation under it to hold *against*:
-- `holdBeat`'s clock is the one the queue already stops for when a row is a
-- gap rather than a picture, and B skips it exactly as it skips a throw.
function M:startSendBall(row)
  local index = type(row) == "table" and row.ballsend or nil
  if index == nil then return false end
  self.introHide = self.introHide or {}
  self.introHide[index] = true
  self:emitFx("ball", index, true)
  self.beatHold = FX_SPAN.ball
  self.beatDwell = nil
  return true
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
        -- A finished sink is *held* rather than retired, and the sequencer says
        -- for how long: `faintFx` / `sinkingAt` is what the message queue is
        -- actually blocked on (thirty frames of `stepFaint`), and the end state
        -- of the effect is a monster face down and invisible. Retiring it the
        -- moment its own clock ran out popped the KO back to full opacity for
        -- the rest of the fall.
        if fx.kind == "faint" and self:sinkingAt(fx.slot) then
          kept[#kept + 1] = fx
        elseif BALL_HIDE_FX[fx.kind] and self.ballFlow
            and self.ballFlow.side == fx.side then
          -- Same hold, same reason, for a monster inside a ball: its end state
          -- is a seat with nothing standing on it, and the row that undoes that
          -- is still to come. `startBallFx` replaces it as each row plays and
          -- `clearBallFlow` drops it when the monster comes back out.
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

-- The seats that are about to exist, and where they will sit.
--
-- A seat is PENDING when it is not on the arena **and** a send arc is already
-- in the air at it. `startSendBall` is where both halves are set at once: it
-- holds the seat under `introHide` (so `battlefieldSeats` stops drawing it --
-- the ball is carrying that monster) and emits the `ball` effect in the same
-- call, and the hold lasts until the `swap` row behind the arc reveals it. So
-- "held and thrown at" is exactly "arriving now".
--
-- Both halves of that "and" matter. A held seat with no arc is NOT pending: an
-- intro holds every seat from the first frame and then reveals them one at a
-- time, so counting all of them would size the first ball's stack for monsters
-- that do not arrive until several rows later, and drop that ball a row above
-- the square its own monster actually pops on. Pending is the arc's own span,
-- one arrival at a time -- which is how the message queue plays them anyway.
--
-- Returns three things, from one walk, so they can never disagree:
--   drawn    slot -> its position in the side's drawn seat list (what
--            `Battlefield.seatOf` matches on)
--   pending  slot -> the position it will hold in the list it is *about* to
--            belong to: its place in slot order among the seats drawn now plus
--            the ones arriving with it. `battlefieldSeats` walks `sim.slots` in
--            this same order, so this is the row the newcomer really takes.
--   counts   { ally = n, foe = m } -- how many seats each side is about to
--            gain, which is what `ctx.pendingSeats` publishes.
--
-- The index and the count are one contract, not two: `Battlefield.seatAnchor`
-- reads that index into a stack the count sizes, and a stack sized from a
-- different set than the index was taken from names the wrong row. That is why
-- they are produced together here rather than each at its own call site.
function M:battlefieldPending(allySeats, foeSeats)
  local drawn = {}
  for i, seat in ipairs(allySeats or {}) do
    if seat.index ~= nil then drawn[seat.index] = i end
  end
  for i, seat in ipairs(foeSeats or {}) do
    if seat.index ~= nil then drawn[seat.index] = i end
  end
  local pending, counts = {}, { ally = 0, foe = 0 }
  local held, order = nil, {}
  for _, fx in ipairs(type(self.fx) == "table" and self.fx or {}) do
    if type(fx) == "table" and fx.kind == "ball" and fx.slot ~= nil
        and drawn[fx.slot] == nil and (held == nil or not held[fx.slot]) then
      held = held or {}
      held[fx.slot] = true
      order[#order + 1] = fx.slot
    end
  end
  if held == nil then return drawn, pending, counts end

  local seen = { ally = 0, foe = 0 }
  for _, slot in ipairs((self.sim and self.sim.slots) or {}) do
    local side = self:fxSideFor(slot.index)
    if drawn[slot.index] ~= nil or held[slot.index] then
      seen[side] = seen[side] + 1
      if held[slot.index] then
        pending[slot.index] = seen[side]
        counts[side] = counts[side] + 1
      end
    end
  end
  -- A throw at a seat the sim never listed has no place in slot order to take,
  -- and the arc is still the only picture of an arrival this screen has -- so
  -- it goes past the end of the side rather than being dropped, in fx order so
  -- two of them stay put. This is the old behaviour for every pending seat,
  -- kept here for the one case that cannot do better.
  local sideDrawn = { ally = #(allySeats or {}), foe = #(foeSeats or {}) }
  for _, slot in ipairs(order) do
    if pending[slot] == nil then
      local side = self:fxSideFor(slot)
      counts[side] = counts[side] + 1
      pending[slot] = sideDrawn[side] + counts[side]
    end
  end
  return drawn, pending, counts
end

-- Every effect, projected onto the seats actually being drawn.
--
-- `seatIndex` is the 1-based position within the side's seat list, which is the
-- only thing `Battlefield.fxSeat` / `seatOf` can match on -- and that list is
-- filtered, so the answer moves as monsters leave the field. An effect whose
-- seat is not on the arena is dropped rather than published with no seat index:
-- an entry carrying none applies to *every* seat on its side, which in a
-- 2-on-2 would flash the partner too. The field-wide jolt is the exception --
-- `fxFieldShake` ignores side and seat by design.
function M:battlefieldFxCtx(allySeats, foeSeats)
  local list = self.fx
  if type(list) ~= "table" or #list == 0 then return nil end
  local seatIndexOf, pendingIndexOf = self:battlefieldPending(allySeats, foeSeats)
  -- ...with one exception, and it is the whole of the send-out throw: a ball
  -- is aimed at a seat that is **deliberately empty** -- there is no monster on
  -- it until the burst puts one there -- so dropping it for want of a drawn
  -- seat would be dropping every arc this screen ever throws at an arrival.
  -- `Battlefield.seatAnchor` places an entry whose seat index names no drawn
  -- monster, so the arc lands where the monster is about to stand.
  --
  -- Such a seat is handed its REAL index -- its place in the list it is about
  -- to belong to (`pendingSeatIndex`) -- and `battlefieldCtx` publishes the
  -- matching `pendingSeats` count, which is the half of the contract that
  -- tells the arena the side is one row taller than it currently draws. The
  -- two travel together: an index into a two-row stack with the stack still
  -- sized at one row would name the wrong row. This replaces pushing the index
  -- past the end of the drawn list, which sized the side correctly but always
  -- landed the ball on the bottom row -- right when the arrival really was last
  -- in slot order, one row low in a 2-on-2 whose surviving partner sits behind
  -- it. See `Battlefield.seatAnchor`'s `pending` contract.
  local out = {}
  for _, fx in ipairs(list) do
    if type(fx) == "table" then
      if fx.kind == "shake" then
        out[#out + 1] = { kind = "shake", side = fx.side, t = fx.t }
      else
        local seatIndex = fx.slot ~= nil and seatIndexOf[fx.slot] or nil
        if not seatIndex and fx.kind == "ball" and fx.slot ~= nil then
          seatIndex = pendingIndexOf[fx.slot]
        end
        if seatIndex then
          out[#out + 1] = {
            kind = fx.kind, side = fx.side, seatIndex = seatIndex, t = fx.t,
            own = fx.own,
          }
        end
      end
    end
  end
  if #out == 0 then return nil end
  return out
end

function M:battlefieldCtx()
  local frame = battlefieldFrame(self)
  local allySeats = self:battlefieldSeats(false)
  local foeSeats = self:battlefieldSeats(true)
  local _, _, pendingSeats = self:battlefieldPending(allySeats, foeSeats)
  local ctx = {
    mode = self.mode,
    frame = frame,
    allyHumans = self:battlefieldAllyHumans(),
    foeHumans = self:battlefieldFoeHumans(),
    allySeats = allySeats,
    foeSeats = foeSeats,
    bubbles = self:battlefieldBubbleCtx(),
    -- The seats that are one arc away from being drawn (`battlefieldPending`).
    -- Nothing on the arena moves for this -- the placed monsters are placed --
    -- but it is what lets `Battlefield.seatAnchor` size an arriving seat's
    -- stack as the side will be once the ball lands, so the arc, the burst and
    -- the monster that scales out of it all happen on one square instead of
    -- the ball landing a row off in a 2-on-2 replacement.
    pendingSeats = pendingSeats,
    -- One direction only: this screen advances `t`, Battlefield draws whatever
    -- `t` says. Absent when nothing is playing -- the renderer tolerates that.
    fx = self:battlefieldFxCtx(allySeats, foeSeats),
    -- Arrow/card only during target pick; Battlefield honors this flag.
    showTarget = (self.phase == "target"),
  }
  if self.phase == "target" and self.sim then
    local mine = self:mySlot()
    local targets = mine and self.sim:targetsFor(mine) or {}
    ctx.targets = targets
    ctx.targetIndex = self.targetIndex or 1
  end
  return ctx
end

-- ------- the modern band (battlefield path only)
--
-- The same phases the GB chrome below draws, drawn instead as Battlefield's
-- panel widgets. **Draw-only**: every row source and every cursor is the one
-- the input handlers already read, so what a press does is untouched -- a list
-- drawn from a different set than `updateSwitch` filters would put the cursor
-- on the monster above the one the player is looking at.
--
-- Classic 160×144 and Gen 2 never reach here: `drawSafe` sends them straight to
-- `drawMenusClassic`, which is byte-identical to what it always was.

-- Right-hand column for a party row: the numbers the plates publish anyway.
local function hpRight(mon)
  if type(mon) ~= "table" then return nil end
  local hp = tonumber(mon.hp)
  local max = tonumber(mon.maxHp)
    or (type(mon.stats) == "table" and tonumber(mon.stats.hp))
  if not (hp and max) then return nil end
  return ("%d/%d"):format(hp, max)
end

-- The commands, with SWITCH under the name the player knows it by -- which is
-- the two-tile PKMN mark on the classic path and cannot be one here. The order
-- and the index are `M.COMMANDS`' own: `updateCommand` steps that grid.
function M:bandCommandItems()
  local items = {}
  for i, command in ipairs(M.COMMANDS) do
    items[i] = { label = (command == "SWITCH") and "PKMN" or command }
  end
  return items
end

-- The move list, and the strip that used to sit beside it. PP is the row's own
-- right column now; TYPE rides the title, where it belongs to the highlighted
-- move rather than to the list.
function M:bandMoveRows()
  local moves = self:liveMoves()
  local data = self.game and self.game.data
  local rows = {}
  for _, moveInst in ipairs(moves) do
    local def = (data and data.moves or {})[moveInst.id]
    local row = { label = (def and def.name) or moveInst.id or "-" }
    local pp = tonumber(moveInst.pp)
    if def and tonumber(def.pp) then
      -- The classic strip's own arithmetic: PP Ups add a fifth of the base
      -- each, rounded down, exactly as `drawMoves` computes it.
      local base = tonumber(def.pp) or 0
      local maxPP = base + (tonumber(moveInst.ppUps) or 0) * math.floor(base / 5)
      row.right = ("%d/%d"):format(pp or 0, maxPP)
    elseif pp then
      row.right = tostring(math.floor(pp))
    end
    if pp and pp <= 0 then row.dim = true end
    rows[#rows + 1] = row
  end
  return rows
end

function M:bandMoveTitle()
  local moves = self:liveMoves()
  local pick = moves[self.moveIndex or 1]
  local def = pick and (self.game and self.game.data and self.game.data.moves
    or {})[pick.id]
  if not (def and def.type) then return "MOVES" end
  local TypeChart = engine and engine.TypeChart
  local typeName = def.type
  if TypeChart and TypeChart.displayName then
    typeName = TypeChart.displayName(def.type) or def.type
  end
  return ("MOVES   TYPE/%s"):format(tostring(typeName))
end

-- The bench, as `benchOf` filters it -- alive, and not the one already out.
-- Same list `updateSwitch` / `updateReplace` index into.
function M:bandBenchRows(bench)
  local pokemon = (self.game and self.game.data and self.game.data.pokemon) or {}
  local rows = {}
  for _, entry in ipairs(bench or {}) do
    local mon = entry.mon or {}
    local def = pokemon[mon.species]
    rows[#rows + 1] = {
      label = tostring(mon.nickname or (def and def.name) or mon.species or "?"),
      right = hpRight(mon),
    }
  end
  return rows
end

-- Draw the band, and answer whether the band is now on the screen.
--
-- Wrapped by `M:drawModernBand` below, which is what callers use: the wrappers
-- here turn each widget's own verdict into one flag, and the caller reads that
-- flag alongside this function's return. A widget answers `false` when it
-- painted nothing -- no love.graphics, a box too small to label, or its own
-- internal pcall caught a throw -- and a `false` anywhere means part of the
-- band is missing, which is the case the GB chrome exists for. `nil` is not a
-- failure: an older Battlefield beside this screen returns nothing at all, and
-- those builds are the ones the type checks below already vet.
function M:drawBandWidgets()
  local drawMessage = Battlefield.drawMessagePanel
  local drawGrid = Battlefield.drawCommandGrid
  local drawList = Battlefield.drawListPanel
  -- An arena without the band widgets (an older Battlefield beside a newer
  -- screen) still gets the GB chrome rather than an empty band. Nothing to
  -- remediate: the caller falls back on a false return.
  if type(drawMessage) ~= "function" or type(drawGrid) ~= "function"
     or type(drawList) ~= "function" then
    return false
  end
  local function message(text, opts)
    if drawMessage(text, opts) == false then self.bandFailed = true end
  end
  local function grid(items, cursor, opts)
    if drawGrid(items, cursor, opts) == false then self.bandFailed = true end
  end
  local function list(rows, cursor, opts)
    if drawList(rows, cursor, opts) == false then self.bandFailed = true end
  end
  if type(Battlefield.drawBandBackdrop) == "function" then
    -- Once, here, and never inside a widget: two scrims would double-darken
    -- the band.
    Battlefield.drawBandBackdrop()
  end

  if self.replacing then
    local seat = self.sim and self.sim:slot(self.mine)
    local bench = seat and self:benchOf(seat) or {}
    if #bench == 0 then
      message("No one left!")
    else
      list(self:bandBenchRows(bench), self.switchIndex or 1,
        { title = "WHO'S NEXT?" })
    end
    return true
  end
  if self.runAsk and self.phase ~= "messages" then
    local ask = self.runAsk
    local name = ask.name
    if ask.role == "confirming" then
      list(RUN_ANSWERS, ask.index or RUN_DEFAULT, { title = "RUN AWAY?" })
    elseif ask.role == "deciding" then
      list(RUN_ANSWERS, ask.index or RUN_DEFAULT,
        { title = ((name or "They") .. ": RUN?") })
    elseif ask.role == "refused" then
      message((name or "They") .. " says NO!")
    elseif ask.role == "fleeing" or not name then
      message("Getting away...")
    else
      message("Asking " .. name .. " to RUN...")
    end
    return true
  end
  if self.phase == "choose" then
    grid(self:bandCommandItems(), self.commandIndex or 1)
    return true
  end
  if self.phase == "move" then
    -- Every move empty: Gen 1 substitutes Struggle whatever was picked, so the
    -- band says so rather than listing four moves that cannot be used.
    if not self:hasLivePP() then
      list({ { label = "STRUGGLE" } }, 1, { title = "NO MOVES LEFT!" })
    else
      list(self:bandMoveRows(), self.moveIndex or 1,
        { title = self:bandMoveTitle() })
    end
    return true
  end
  if self.phase == "target" then
    local rows = {}
    local mine = self:mySlot()
    for _, entry in ipairs((mine and self.sim:targetsFor(mine)) or {}) do
      local battler = entry.battler
      local mon = battler and battler.mon
      rows[#rows + 1] = {
        label = (battler and battler.name) or "?",
        right = hpRight(mon),
        dim = (mon and (mon.hp or 0) <= 0) or nil,
      }
    end
    list(rows, self.targetIndex or 1, { title = "ATTACK WHO?" })
    return true
  end
  if self.phase == "switch" then
    local mine = self:mySlot()
    local bench = mine and self:benchOf(mine) or {}
    if #bench == 0 then
      message("There's no one else to send out!")
    else
      list(self:bandBenchRows(bench), self.switchIndex or 1, { title = "POKeMON" })
    end
    return true
  end
  if self.phase == "item" then
    local items = self:usableItems()
    if #items == 0 then
      message("You have nothing to use.")
      return true
    end
    local rows = {}
    for _, entry in ipairs(items) do
      rows[#rows + 1] = {
        label = tostring(entry.name or entry.id),
        right = entry.count and ("x%d"):format(entry.count) or nil,
      }
    end
    list(rows, self.itemIndex or 1, { title = "ITEMS" })
    return true
  end
  if self.phase == "item_party" then
    local seat = self:mySlot()
    local party = (seat and seat.party) or {}
    local rows = {}
    for _, row in ipairs(self:itemPartyRows()) do
      rows[#rows + 1] = {
        label = row.label,
        right = hpRight(party[row.index]),
        -- Shown, not filtered: a Revive wants the fainted one, and
        -- `updateItemParty` indexes the whole party.
        dim = row.fainted or nil,
      }
    end
    list(rows, self.switchIndex or 1, { title = "POKeMON" })
    return true
  end
  if self.phase == "item_move" then
    local seat = self:mySlot()
    local party = (seat and seat.party) or {}
    local mon = party[self.itemPartyIndex or (seat and seat.active) or 1]
    local data = self.game and self.game.data
    local rows = {}
    for _, move in ipairs((mon and mon.moves) or {}) do
      local def = (data and data.moves or {})[move.id]
      rows[#rows + 1] = {
        label = tostring((def and def.name) or move.id or "-"),
        right = tonumber(move.pp) and tostring(math.floor(move.pp)) or nil,
      }
    end
    list(rows, self.moveIndex or 1, { title = "MOVES" })
    return true
  end
  message(self:boxText())
  return true
end

function M:drawModernBand()
  self.bandFailed = nil
  local drew = self:drawBandWidgets()
  if not drew then return false end
  if self.bandFailed then
    -- Warned once per battle, then quietly: this runs every frame, and a band
    -- that cannot paint cannot paint sixty times a second into the log either.
    -- The battle is not interrupted -- the caller redraws the GB chrome over
    -- the same band on this very frame.
    if not self.bandFallbackWarned then
      self.bandFallbackWarned = true
      if mod and mod.log then
        mod.log:warn("the 2-on-2 battle band could not be drawn, so the menus "
          .. "fall back to the Game Boy chrome; the fight is unaffected, but "
          .. "report this with your window size and whether it repeats")
      end
    end
    return false
  end
  return true
end

function M:drawMenuBand()
  -- The modern band first; the GB re-projection below is the fallback for a
  -- build whose Battlefield has no widgets, and for anything that throws on the
  -- way through them -- a battle must never lose its menu to a panel.
  local ok, drew = pcall(self.drawModernBand, self)
  if ok and drew then return end
  local g = love and love.graphics
  if not (g and g.push) then
    self:drawMenusClassic()
    return
  end
  local bandY = Battlefield.FIELD_BOTTOM
  local sx = Battlefield.WIDTH / 160
  local sy = Battlefield.MENU_BAND / CLASSIC_MENU_H
  g.push()
  g.translate(0, bandY)
  g.scale(sx, sy)
  g.translate(0, -CLASSIC_MENU_TOP)
  if g.setScissor then
    -- Clip to the classic menu band in pre-transform space... actually
    -- scissor is in screen/canvas pixels. Clip the menu band on the canvas.
    local prev = { g.getScissor() }
    g.setScissor(0, bandY, Battlefield.WIDTH, Battlefield.MENU_BAND)
    self:drawMenusClassic()
    if prev[1] then
      g.setScissor(prev[1], prev[2], prev[3], prev[4])
    else
      g.setScissor()
    end
  else
    self:drawMenusClassic()
  end
  g.pop()
end

function M:drawMenusClassic()
  if self.replacing then
    self:drawReplace()
  elseif self.runAsk and self.phase ~= "messages" then
    self:drawRunAsk()
  elseif self.phase == "choose" then
    self:drawCommand()
  elseif self.phase == "move" then
    self:drawMoves()
  elseif self.phase == "target" then
    -- Slim hint in the menu band; field cursor + card live on the arena.
    self:drawTarget()
  elseif self.phase == "switch" then
    self:drawSwitch()
  elseif self.phase == "item" then
    self:drawItem()
  elseif self.phase == "item_party" then
    self:drawItemParty()
  elseif self.phase == "item_move" then
    self:drawItemMove()
  else
    self:drawMessage()
  end
end

function M:drawBattlefieldSafe()
  self:ensureBattlefieldLoaded()
  -- Fill first, exactly as the classic path does before `drawField`: this
  -- screen declares itself opaque, so the stack stops drawing the overworld
  -- and clears the UI canvas transparent -- and every pixel the arena does not
  -- cover (a frame where the arena image failed to load, the seams a shake
  -- translate opens) would otherwise show whatever was in the canvas last.
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, Battlefield.WIDTH, Battlefield.HEIGHT)
  local eng = {
    Font = engine and engine.Font,
    Sprites = engine and engine.Sprites,
    SpriteRenderer = engine and engine.SpriteRenderer,
    sprites = Gen.spriteCatalog(self.game),
    game = self.game,
  }
  local ctx = self:battlefieldCtx()
  pcall(Battlefield.draw, self, ctx, eng)
  self:drawMenuBand()
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- animations
--
-- The engine authors every battle animation against the classic layout: one
-- player pic low-left, one enemy pic high-right. Four monsters means four
-- anchors, so each frame is translated by the distance between the anchor it
-- was drawn for and the slot that actually acted.
--
-- Rigid, whole-frame translation and never a scale, for the reason WideBattle
-- gives when it does the same thing: an animation is a set of OAM sprites laid
-- out relative to each other, and moving them apart individually pulls it to
-- pieces.

-- Where the classic layout puts the two pics an animation was authored around.
local CLASSIC_PLAYER = { x = STAGE_ALLY.x, y = 40 }
local CLASSIC_ENEMY = { x = STAGE_FOE.x, y = STAGE_FOE.y }

-- ------- move / catch SFX (AnimPlayer pollEffects + hit thuds)
--
-- Mirrors BattleState's anim hold: update → pollEffects → playAnimSound /
-- SFX_TINK; on completion, PlayApplyingAttackSound-style effectiveness thud.
-- Derived client-side from the following effectiveness line (no PROTOCOL).

local function hitSfxFromText(text)
  if type(text) ~= "string" then return nil end
  -- Engine / BattleSim lines may break mid-phrase ("It's super\neffective!").
  local lower = text:lower():gsub("%s+", " ")
  if lower:find("super effective", 1, true) then
    return { sound = "Super_Effective", pitch = 0xe0 }
  end
  if lower:find("not very effective", 1, true) then
    return { sound = "Not_Very_Effective", pitch = 0x50 }
  end
  return nil
end

-- Peek the message queue for the effectiveness line (or a following drain,
-- which means a damaging hit with neutral matchup → Damage thud).
function M:peekHitSfx()
  local sawDrain = false
  local function remap(sfx)
    if not sfx then return nil end
    return {
      sound = Gen.sfx(self.game, sfx.sound),
      pitch = sfx.pitch,
    }
  end
  for _, row in ipairs(self.messages or {}) do
    if type(row) == "table" then
      if row.anim then break end
      if row.text then
        local sfx = remap(hitSfxFromText(row.text))
        if sfx then return sfx end
      end
      if row.drain then sawDrain = true end
      if row.faintfx then sawDrain = true end
    elseif type(row) == "string" then
      local sfx = remap(hitSfxFromText(row))
      if sfx then return sfx end
    end
  end
  if sawDrain then
    return { sound = Gen.sfx(self.game, "Damage"), pitch = 0x20 }
  end
  return nil
end

function M:playAnimSound(soundMove)
  local Sound = engine and engine.Sound
  if not Sound then return end
  local data = self.game and self.game.data
  if not data then return end
  local animName = self.anim and self.anim.anim
  local mdef = data.moves and data.moves[soundMove]
  if animName == "GROWL" or animName == "ROAR" then
    local from = self.anim and self.anim.from
    local battler = from and self:shownBattlerAt(from)
    local species = battler and battler.mon and battler.mon.species
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

-- Soft-fail Sound for one AnimPlayer event (move sound or catch SFX_TINK).
function M:applyAnimEffect(ev)
  if type(ev) ~= "table" then return end
  if ev.sound then self:playAnimSound(ev.sound) end
  if ev.effect == "SFX_TINK" then
    local Sound = engine and engine.Sound
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

-- Effectiveness thud after the flash (BattleState:applyHitFx sfx half).
function M:applyPendingHitFx()
  local hit = self.pendingHit
  self.pendingHit = nil
  if not hit or not hit.sfx then return end
  local Sound = engine and engine.Sound
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

-- Solo's no-AnimPlayer branch: play the move's sound table entry once.
function M:playMoveAnimFallback(row)
  local data = self.game and self.game.data
  local Sound = engine and engine.Sound
  if not (data and Sound and row and row.anim) then return end
  local mdef = data.moves and data.moves[row.anim]
  local anim = mdef and mdef.anim
  if row.anim == "GROWL" or row.anim == "ROAR" then
    local from = row.from
    local battler = from and self:shownBattlerAt(from)
    local species = battler and battler.mon and battler.mon.species
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
  -- Is this a real move, or one of the engine's ball markers? Every marker ends
  -- in `_ANIM` (`TOSS_ANIM`, `SHAKE_ANIM`, `HIDEPIC_ANIM`, …), and the old
  -- filter named three of the seven by hand -- so a ball throw printed "used
  -- TOSS_ANIM!" over the thrower's head and made the thrower lurch at it.
  local moveAnim = type(row.anim) == "string" and row.anim ~= ""
    and not row.anim:find("_ANIM", 1, true)
  -- Trainer callout over the human who ordered this attack (Gen1 battlefield),
  -- and the beat behind it. `splitCalloutBeat` raises the bubble either way;
  -- when it answers true it has also put this row back at the head of the
  -- queue, so the shout gets the next half-second to itself and everything
  -- below -- the lunge, the AnimPlayer, the hit sfx -- runs when the row comes
  -- round again. Nothing here is started in the meantime: an animation held
  -- open across a beat would be drawn over a field the beat exists to leave
  -- still.
  if moveAnim and self:splitCalloutBeat(row) then return true end
  self.anim = row
  self.animHold = nil
  self.animDwell = nil
  self.pendingHit = nil
  -- The arena's half of the same row. The attacker leans in for a real move;
  -- the markers are the throw itself -- the arc, the recall, each wobble and
  -- the burst -- one per queued row, each held for as long as it plays.
  --
  -- Draw-only and battlefield-only: the classic 160×144 stage and Gen 2 run the
  -- engine's AnimPlayer over these same rows below, unchanged.
  if self:usesBattlefield() then
    if moveAnim then
      -- The defender's flash and the field's nudge ride the drain row behind
      -- this one, so a move that misses only lunges.
      --
      -- Resolved rather than read straight off `row.from`, for the same reason
      -- `ballTargetSlot` resolves: a host-sim row (`coop_wild` / `coop_npc`,
      -- queued by CoopField) carries `attackerIsPlayer` and no `from` at all.
      -- `emitFx("lunge", nil)` produced a slotless record that
      -- `battlefieldFxCtx` then dropped -- so those two modes never lunged
      -- once, and paid for a dead fx record on every move to not do it.
      local lunger = row.from
      if lunger == nil then
        local isFoe = self:actorIsFoe(row)
        if isFoe ~= nil then lunger = self:seatOnSide(isFoe) end
      end
      -- Still nobody: emit nothing. A lunge that cannot name a seat is a
      -- record the ctx projection throws away one frame later.
      if lunger ~= nil then self:emitFx("lunge", lunger) end
    else
      self:startBallFx(row)
    end
  end
  -- Ball chain: HIDEPIC / SHOWPIC gate foe stage pics (engine enemyHidden).
  if row.anim == "HIDEPIC_ANIM" then
    self.foePicHidden = true
  elseif row.anim == "SHOWPIC_ANIM" then
    self.foePicHidden = nil
  elseif row.anim == "POOF_ANIM" then
    -- Intro send-out and catch ball chain both play SFX_BALL_POOF.
    local Sound = engine and engine.Sound
    if Sound and Sound.play then
      pcall(Sound.play, self.game.data, Gen.sfx(self.game, "Ball_Poof"))
    end
  end
  local hitSfx = self:peekHitSfx()
  if hitSfx then self.pendingHit = { sfx = hitSfx } end
  if not (self.animPlayer and self.animPlayer.start) then
    -- No animation data in this build: play the move SFX once (solo's
    -- no-player branch) and the hit thud, then let the messages carry on.
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    -- ...unless the arena took the row over. There is no engine animation to
    -- wait on, but there is a throw in the air, and the dwell in `update` is
    -- what holds the queue for it.
    if self.animHold then return true end
    self.anim = nil
    return false
  end
  -- Face the flash the way *this* screen lays out the field. Host-sim rows
  -- carry the engine's absolute `attackerIsPlayer`, which is wrong for a
  -- side-b guest whose own pair sits on the player half; `from` + foeSide is
  -- always viewer-true when present.
  local isPlayer
  if row.from ~= nil then
    isPlayer = not self:foeSide(row.from)
  elseif row.attackerIsPlayer ~= nil then
    isPlayer = row.attackerIsPlayer
  else
    isPlayer = true
  end
  local ball = self.medBall
  local opts = {
    shakes = row.amount,
    ball = ball,
    ballFlicker = ball == "MASTER_BALL" or ball == "ULTRA_BALL" or nil,
  }
  local ok = pcall(self.animPlayer.start, self.animPlayer, row.anim, isPlayer, opts)
  if not ok then
    self:playMoveAnimFallback(row)
    self:applyPendingHitFx()
    -- Same as above: the arena's effect outlives the player that refused to
    -- start, and the dwell holds the row for it.
    if self.animHold then return true end
    self.anim = nil
    return false
  end
  -- Frame-0 sound/effect rows fire immediately (BattleState after start).
  self:pollAnimEffects()
  return true
end

-- How far to shift this animation so it lands on the slot that acted.
--
-- Measured to the pic's *drawn* origin rather than to its raw `SLOT_POS`, so a
-- slot that draws at FOE_SCALE has its flash land on the monster rather than
-- four to eight pixels above and left of it (M:picOriginFor). The sprite is
-- looked up for the same reason the pic does: the offsets depend on how big it
-- is, and only it can say. Classic player vs enemy anchors follow the viewer
-- (foeSide), matching `viewPos`, not raw side "a".
--
-- **Ally Y is not shifted.** Coop parks back pics near y=50 (clear of the foe
-- panel); AnimPlayer authors every player-side effect against the classic
-- back-pic anchor at y=40. Adding that delta to the flash buried it under the
-- message box -- foe attacks (anchored near y=0) kept working, player attacks
-- looked like they never played. X still tracks the 2-on-2 slot so a partner
-- at x=34 does not flash over the lead at x=2.
function M:animOffset(row)
  local index = row and row.from
  if not index then return 0, 0 end
  local battler = self:shownBattlerAt(index)
  local x, y = self:picOriginFor(index, battler and battler.sprite)
  if not x then return 0, 0 end
  local foe = self:foeSide(index)
  local from = foe and CLASSIC_ENEMY or CLASSIC_PLAYER
  if foe then
    return x - from.x, y - from.y
  end
  return x - from.x, 0
end

function M:drawAnim()
  local row = self.anim
  if not (row and self.animPlayer and self.animPlayer.draw) then return end
  local dx, dy = self:animOffset(row)
  love.graphics.push()
  love.graphics.translate(dx, dy)
  pcall(self.animPlayer.draw, self.animPlayer)
  love.graphics.pop()
end

-- ------- exp
--
-- Applied only to *your* monster, on your own client, for the reason the whole
-- co-op design keeps running into: the host resolves every slot but holds the
-- real party for only one of them. Every client sees every exp event; three of
-- them ignore each one.
--
-- The host does not send a number to add. It sends what was beaten and how
-- many shared in beating it, and each client prices that for itself through
-- the engine's own Experience.apply -- which is also what divides the stat
-- exp, raises the stats and decides whether a level was crossed. Applying a
-- host-computed number instead would skip all three.

-- The refereed modes whose losing side is a *trainer's*, and so the only ones
-- that pay the x1.5. A positive list rather than a "not wild" test, so a mode
-- added later pays the wild rate until somebody decides otherwise: paying too
-- little is a number a player never notices, paying too much is inflation that
-- cannot be taken back. Mirrors src/MediatedBattle.lua's reading of the same
-- rule from the other side of the same event.
local EXP_TRAINER_MODES = { coop_npc = true }

-- Warn once per screen rather than once per award, on the same reasoning
-- src/MediatedBattle.lua's `warnNoExp` gives: a fight that cannot resolve one
-- award usually cannot resolve the next either, and forty identical lines in
-- the log describe one fact.
function M:warnNoExp(why)
  if self.expWarned then return false end
  self.expWarned = true
  mod.log:warn("no EXP could be awarded for a knockout in this battle (%s), so "
    .. "the fight still plays out but nothing levels up -- report this with "
    .. "the game version; levelling still works in ordinary battles",
    tostring(why))
  return true
end

-- Where the monster behind an *uploaded fight sheet* sits in the party.
--
-- **The two referees count in different spaces, and this is the translation.**
-- The intermediator only ever saw `Mediated.snapshotMons(game, mine.party)`, so
-- its `mon` is an index into that -- and `snapshotMons` skips any monster it
-- cannot describe (no stats, no species, no moves), which shifts every index
-- after the skip. The sheets stamp the party position they were cut from
-- (`slot`, 0-based), so the position is read back off the sheet rather than
-- assumed to be the array index.
--
-- **The discriminator is the row, not the screen**: `medRows` stamps `med` on
-- every `exp` row it builds and CoopSim's own events carry none, so a queued
-- batch stays readable however it was assembled -- rather than depending on
-- `self.mediated`/`self.medMine` still holding whatever they held when the
-- event arrived, several seconds of message queue earlier.
--
-- No uploaded party (a harness driving the screen directly, or an event that
-- somehow arrives before the upload) leaves the index alone: that is exactly
-- the behaviour this replaces. A sheet index the upload has nothing at is a
-- referee talking about a monster this client never sent it -- `nil`, refused
-- by the caller, rather than resolved through a fallback that would quietly
-- pay whoever happened to sit at that number.
function M:medPartySlot(sheetIndex)
  local mine = self.medMine
  if type(mine) ~= "table" or #mine == 0 then return sheetIndex end
  local sheet = mine[sheetIndex]
  if type(sheet) ~= "table" then return nil end
  local slot = tonumber(sheet.slot)
  if not slot then return sheetIndex end
  slot = math.floor(slot) + 1
  if slot < 1 then return sheetIndex end
  return slot
end

function M:gainExp(event)
  if event.slot ~= self.mine then return end
  local slot = self.sim:slot(self.mine)
  local battler = slot and slot.battler

  -- EXP.ALL, the way the original splits it: the monster that fought takes
  -- half, and the other half is divided again across the whole living party.
  -- The engine expresses that as a *divisor* rather than a fraction, so
  -- holding one doubles the divisor on the first pass and the second pass
  -- divides by the party size on top.
  local save = self.game.save
  local generation = Gen.generation(self.game)
  local party = (save and save.party) or {}
  local expAll = generation ~= 2
    and save and save.inventory and (save.inventory.EXP_ALL or 0) > 0
  -- Gen 2's EXP.SHARE, which is not EXP.ALL: a HELD item found on the party by
  -- id, halving the pool once for both passes, with the second pass paying the
  -- holders only. See `src/Exp2.lua` and MediatedBattle's twin of this block.
  -- Taken before the first pass, since that pass can level a holder.
  local shareHolders = (generation == 2) and Exp2.holders(party) or nil
  local halved = shareHolders ~= nil and #shareHolders > 0

  -- **Which monster is being paid**, and it is no longer "the one standing
  -- there".
  --
  -- Vanilla pays every party member that was ever in against the fallen foe
  -- and is still alive (BattleState:3795-3801 walks `save.party` for its
  -- participant flags, not the field), so a knockout can owe a monster that
  -- has been sitting in its ball since the second turn. The referee names it:
  -- `slot` is still the seat, and gates the award to its owner; `mon` is a
  -- 0-based index into that seat's party. One event per paid participant --
  -- so this runs once per owed monster, and nothing here collapses two of
  -- them into one line.
  --
  -- The seat's party is the same table `save.party` is for our own seat
  -- (src/Coop.lua hands the live party in), and it is the one read here
  -- because the seat is what the index counts. Falling back to `save.party`
  -- costs nothing and lets a screen assembled without a sim slot still pay.
  --
  -- No `mon` at all falls back to the active monster: a PROTOCOL 21 referee
  -- that predates the field pays whoever was standing, and so does CoopSim's
  -- own divisor-0 fallback (src/CoopSim.lua:1310-1324, mirroring
  -- BattleState:3802-3804). An index that names nothing pays nobody rather
  -- than paying the active by accident -- the guard below returns.
  --
  -- **And the two referees do not count in the same space.** CoopSim emits
  -- `mon` as a position in the *seat's* party (src/CoopSim.lua:1351,
  -- `row.index - 1`), which is the roster read below. The intermediator counts
  -- in the party this client *uploaded* -- `Mediated.snapshotMons` skips a
  -- monster it cannot describe, so one skip shifts every index after it, and
  -- reading a hub index straight off the roster pays the wrong party member
  -- (and writes its Stat Exp, its level and its new moves onto them too). The
  -- mediated rows are translated sheet -> `sheet.slot` -> party position by
  -- `medPartySlot`, the same two-step src/MediatedBattle.lua's
  -- `paidSheetIndex` + `savePartyIndex` take. See `medPartySlot` for the
  -- discriminator.
  local index = tonumber(event.mon)
  local mon
  if index then
    local roster = (slot and slot.party) or party
    local at = math.floor(index) + 1
    if event.med then at = self:medPartySlot(at) end
    mon = at and roster[at]
    -- An index that resolves to nobody pays nobody -- but it says so. Silence
    -- here read in play as "this knockout was worth nothing", which is the one
    -- reading it is never allowed to have: it is a referee naming a monster
    -- this client does not hold, and the player is owed exp nobody paid.
    if not mon then
      self:warnNoExp(event.med
        and "the referee paid a party member this client never uploaded"
        or "the referee named a party member this screen does not hold")
      return
    end
  else
    mon = battler and battler.mon
  end

  local eng = engine
  local def = mon and event.species and (self.game.data.pokemon or {})[event.species]
  -- Which generation's formula prices this faint. The referee's facts are
  -- generation-free; everything downstream of them is not. See MediatedBattle's
  -- twin of this branch and `src/Exp2.lua`.
  if not (mon and def) then return end
  if generation == 2 then
    if not Exp2.available() then return end
  elseif not (eng and eng.Experience) then
    return
  end

  -- Is the paid monster the one on the plate? Everything the *display* does
  -- below hangs on this and nothing else does: a benched award is text only.
  local active = (battler ~= nil) and (battler.mon == mon)

  -- Everyone still standing on the winning side shares it, exactly as the
  -- engine divides a solo battle between its own participants -- so a co-op
  -- knockout is worth half each, not full each. Holding an EXP.ALL doubles
  -- the divisor: that is how the original expresses "half now, half spread".
  --
  -- Two spellings for one number, because two referees send it. CoopSim (the
  -- host-simulated path) has always called it `winners`; the intermediator
  -- calls it `participants` (src/BattleSim/events.lua, and the JS twin beside
  -- it). `participants` is preferred where both are present, and the fallback
  -- is *not* a default of 1: a share count that arrived under the newer name
  -- and was read under the older one would divide by one and pay every winner
  -- the whole knockout -- double exp for a 2-on-2, silently.
  local winners = math.max(1,
    tonumber(event.participants) or tonumber(event.winners) or 1)

  -- Wild or trainer, decided from the mode the screen already knows.
  --
  -- The trainer x1.5 is a real rule of the formula (experience.asm), so it is
  -- paid on a positive list rather than unconditionally: `coop_wild` is the
  -- party encounter, and paying it 1.5x would make the same monster worth more
  -- beaten in the MMO than beaten alone. The host-simulated path carries no
  -- mode at all (an invite-driven 2-on-2), and there the trainer record is the
  -- fact that decides it -- the same test `battlefieldFoeHumans` uses to tell
  -- an NPC fight from a player one. `coop_pvp` pays nothing either way: the
  -- intermediator awards no exp in it (BattleSim's EXP_MODES).
  local isTrainer = EXP_TRAINER_MODES[self.mode]
    or (self.mode == nil and self.trainer ~= nil)
    or false

  -- Gen 2 banks its exp on `mon.experience`; `mon.exp` is Gen 1's field and
  -- seeding it on a Gold save would leave a number nothing ever reads.
  mon.statExp = mon.statExp or {}
  if generation == 2 then
    mon.experience = mon.experience or 0
  else
    mon.exp = mon.exp or 0
  end

  -- Where the strip is *now*, read before the award lands.
  --
  -- `Experience.apply` mutates `mon.exp` and `mon.level` in place, so once it
  -- has run there is nothing left to work the starting fraction back out of --
  -- the same hazard the HP climb below documents, one field over. That is the
  -- whole job of this capture, and its only one: `startExpFill` starts from
  -- the *live* display clock and reaches for `from*` only when that clock is
  -- still nil, precisely so a second award in the same batch begins where the
  -- first fill stopped rather than rewinding to a fraction captured before it.
  --
  -- Battlefield only. The classic 160x144 readout has no exp strip: nothing
  -- below is computed, nothing is queued, and its exp text flow is exactly
  -- what it always was.
  --
  -- **Active only**, for the same reason: the strip on screen belongs to the
  -- monster standing there, and a benched award has no bar of its own to
  -- crawl. Seeding or capturing off the active battler for somebody else's
  -- award would move a clock that nothing is about to fill -- and a queued
  -- fill row would drag the active's strip to the *bench's* fraction.
  local wide = self:usesBattlefield()
  local fromFrac, fromLevel
  if wide and active then
    self:seedExpClock(battler)
    fromFrac = battler.shownExpFrac
    fromLevel = battler.shownLevel or mon.level or 1
  end

  -- The first pass. Both arms hand back the same two values -- the list of
  -- levels reached and the raw amount the "gained N EXP" line says -- so
  -- everything below this point is generation-free again.
  local ok, levels, gained
  if generation == 2 then
    -- `winners` is the referee's divisor unmodified: Gen 2's Share tax is the
    -- `halved` flag on the pool, not a doubling of the divisor.
    levels, gained = Exp2.apply(self.game, mon, def, {
      level = event.level or 1, participants = winners, isTrainer = isTrainer,
      halved = halved, save = save,
    })
    if levels == nil then return end
  else
    ok, levels, gained = pcall(eng.Experience.apply, self.game.data, mon,
      def, event.level or 1, isTrainer, winners * (expAll and 2 or 1), false)
    if not ok then return end
  end

  -- The plate's name is the *active's* name, so it is only a fallback for the
  -- active: a nickname-less benched monster is named by its own species, the
  -- way `levelled` names one -- and by ITS species, not `def`, which is the
  -- monster that was beaten. Reading `def.name` here printed "FOE gained 342
  -- EXP. Points!" for every benched award.
  local ownDef = (self.game.data.pokemon or {})[mon.species]
  local name = mon.nickname or (active and battler.name)
    or (ownDef and ownDef.name) or "?"
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
  -- is read, and the bar answers it. Queued ahead of `levelled` deliberately
  -- -- the pill ticks over as the strip tops out (`stepExpFill`), so "grew to
  -- level N!" is printed after the plate already says N rather than a beat
  -- before it. Guarded on the queue because every other line here goes out
  -- through `say`, and a caller that stubs `say` has neither a queue nor a
  -- battler.
  --
  -- No target rides on the row. It is read off the mon when the row comes up,
  -- because the mon is *still being written to* after this point: the EXP.ALL
  -- pass below walks `save.party`, which is the same table this fighter lives
  -- in, so a target captured here would be the first half of the award rather
  -- than the whole of it -- a pill two levels short of the "grew to level N!"
  -- lines printed right beside it.
  --
  -- Queued for the active monster and no other: `active` is the same test the
  -- capture above made, so a benched award queues no fill row at all and the
  -- strip on screen is not perturbed by one landing mid-queue.
  if wide and active and self.messages then
    self.messages[#self.messages + 1] = {
      expfill = battler,
      slot = event.slot,
      name = name,
      fromFrac = fromFrac,
      fromLevel = fromLevel,
    }
  end

  self:levelled(mon, active and battler.name or nil, levels)

  -- A level raises both HP numbers, and the bar has to be told.
  --
  -- `Experience.apply` runs the moment the event is received, so max HP and
  -- current HP move mid-queue while `shownHP` stays where the last drain left
  -- it -- and a bar drawn from an old number against a new denominator is a
  -- bar that visibly *shrinks* on the level-up, and stays wrong until the next
  -- snap. So the climb is queued like any other bar movement and animates
  -- upward, which is what the engine's own level-up does (gen1recomp #224).
  -- Queued after the level lines above, so it plays under them. Guarded on
  -- the battler and on the queue itself, because every other line here goes
  -- out through `say` and a caller that stubs `say` has neither.
  --
  -- Active only, and the engine gates its own the same way -- `if mon ==
  -- self.player.mon then self:drainNext() end` (BattleState:3855): a benched
  -- monster has no bar, and draining the *active's* bar to a bench-mate's HP
  -- is a number that was never about it.
  if active and self.messages then
    self.messages[#self.messages + 1] =
      { drain = battler, slot = event.slot, to = mon.hp }
  end

  -- ...and the other half, spread over everyone still standing -- including
  -- the monster that fought, exactly as the original's second pass does.
  -- Fainted party members are skipped, and no "gained EXP" line is printed for
  -- any of them: the original prints only what a level-up produces.
  --
  -- **Once per knockout, not once per award.** The engine's second pass sits
  -- outside its participant loop -- `vanillaExpAward` pays every alive
  -- participant and *then* walks the party once (BattleState:3873-3890) -- so
  -- one faint spreads one half however many monsters fought it. Here the
  -- participant loop lives on the referee and arrives as one event each, so
  -- without this a party that beat a foe with three of its own would bank the
  -- EXP.ALL half three times over.
  --
  -- The credit is armed by the faint itself in `playEvents` and spent by the
  -- first award that follows it, which is the same shape (and the same
  -- three-valued flag) src/MediatedBattle.lua uses. `nil` -- no knockout ever
  -- narrated on this screen -- runs the pass the way it always did: that is
  -- the direct-call path a harness drives, and metering an award nothing
  -- announced would silently stop paying it.
  if expAll and self.expAllCredit ~= false then
    if self.expAllCredit then self.expAllCredit = false end
    for _, member in ipairs(party) do
      if (member.hp or 0) > 0 then
        member.statExp = member.statExp or {}
        member.exp = member.exp or 0
        local gotOk, gotLevels = pcall(eng.Experience.apply, self.game.data,
          member, def, event.level or 1, isTrainer,
          winners * 2 * math.max(1, #party), false)
        if gotOk then self:levelled(member, nil, gotLevels) end
      end
    end
  end

  -- ...and Gen 2's own second pass: the EXP.SHARE holders, divided by how many
  -- of them there are rather than by the party size, and taxed by the same
  -- `halved` the first pass paid. A holder that fought is in both passes on
  -- purpose -- that is the item. Metered by the same one-knockout credit, and
  -- for the identical reason; only one of the two arms is ever live on a boot.
  if halved and self.expAllCredit ~= false then
    if self.expAllCredit then self.expAllCredit = false end
    local shares = math.max(1, #shareHolders)
    for _, holderIndex in ipairs(shareHolders) do
      local member = party[holderIndex]
      if type(member) == "table" and (member.hp or 0) > 0 then
        member.statExp = member.statExp or {}
        member.experience = member.experience or 0
        local gotLevels = Exp2.apply(self.game, member, def, {
          level = event.level or 1, participants = shares,
          isTrainer = isTrainer, halved = true, save = save,
        })
        if gotLevels then self:levelled(member, nil, gotLevels) end
      end
    end
  end
end

-- What a level-up costs, wherever it happened: a line, whatever moves come
-- with the level, and a note for the evolution check the displaced battle
-- runs on the way out. A party member that levelled on EXP.ALL still evolves
-- and still learns, though it never left its ball.
function M:levelled(mon, fallbackName, levels)
  if not (levels and #levels > 0) then return end
  local eng = engine
  local def = (self.game.data.pokemon or {})[mon.species]
  local name = mon.nickname or fallbackName or (def and def.name) or "?"
  -- Guarded on `def` as well as on the module: `movesLearnedAt` is asked what a
  -- *species* learns, and a mon whose species this build cannot name has no
  -- answer to give. Called with nil it threw into the pcall below, which was
  -- survivable but bought nothing.
  -- Gen 2 keeps its level-up table on `def.levelMoves` where Gen 1 uses
  -- `def.learnset`, and has no `Experience` module to ask -- so the lookup goes
  -- through `Exp2.movesLearnedAt`, which answers the same list shape off the
  -- Gold record. Everything after this line is generation-free.
  local learnedAt = def and (
    (Gen.generation(self.game) == 2) and Exp2.movesLearnedAt
    or (eng and eng.Experience and eng.Experience.movesLearnedAt))
  for _, newLevel in ipairs(levels) do
    self:say(name .. " grew to\nlevel " .. tostring(newLevel) .. "!")
    -- Levelled here, so the moves it learns are decided here too -- the host
    -- cannot know, because it is not the copy that gained the level.
    --
    -- `pcall`'s two returns are read as a pair rather than through
    -- `select(2, ...)`: on failure the second return is the *error string*, and
    -- walking a string with `ipairs` throws for real -- out of the level loop,
    -- out of the award, and out of the event that carried it. So the level-up
    -- line that had already printed would have been followed by nothing at all.
    local moves
    if learnedAt then
      local okMoves, got = pcall(learnedAt, def, newLevel)
      if okMoves and type(got) == "table" then moves = got end
    end
    for _, moveId in ipairs(moves or {}) do
      self:teach(mon, name, moveId)
    end
  end
  self.leveledUp = self.leveledUp or {}
  self.leveledUp[mon] = true
end

-- ------- learning a move
--
-- Applied only to *your* monster, on your own client, because only there is it
-- the live party entry that the save keeps. Every client sees the event; three
-- of them ignore it.
--
-- With a free slot the move is simply learned. With four already known there
-- is a choice to make, and it needs a screen -- so it is remembered and put to
-- the player once the battle is over rather than opened on top of a battle
-- three other people are still fighting.
function M:learnMove(event)
  if event.slot ~= self.mine then return end
  local slot = self.sim:slot(self.mine)
  local mon = slot and slot.battler and slot.battler.mon
  if not mon then return end
  self:teach(mon, mon.nickname or slot.battler.name, event.move)
end

function M:teach(mon, name, moveId)
  local def = (self.game.data.moves or {})[moveId]
  if not def then return end
  for _, known in ipairs(mon.moves or {}) do
    if known.id == moveId then return end
  end
  name = name or "?"

  if #(mon.moves or {}) < 4 then
    mon.moves[#mon.moves + 1] = { id = moveId, pp = def.pp }
    self:say(name .. " learned\n" .. (def.name or moveId) .. "!")
    return
  end

  self.toLearn = self.toLearn or {}
  self.toLearn[#self.toLearn + 1] = { mon = mon, move = moveId }
  self:say(name .. " is trying to\nlearn " .. (def.name or moveId) .. "!")
end

-- ------- nobody is saying anything
--
-- A disconnect is handled elsewhere (peerGone). This is the other shape of the
-- same problem and the one that used to hang forever: a client that is still
-- connected and has simply stopped answering. A wedged game, a closed laptop, a
-- network that drops packets without dropping the socket -- from the outside
-- all three look exactly like somebody taking their time.
--
-- **Three clocks live here, and they are three different questions.** Named,
-- because a clock nobody can name is a clock somebody re-uses for the wrong
-- silence -- which is exactly how the old self-forfeit came about.
--
--   * the **turn deadline** (`turnOpened`, COOP_TURN_TIMEOUT): host-only. One
--     per turn, over every player slot including the host's own. On expiry the
--     late slots are auto-picked (see `autoPickLate`) and the turn resolves.
--   * the **replacement-choice clock** (`waitClock`, COOP_CHOICE_TIMEOUT):
--     host-only, and untouched by any of this. A slot awaiting a send-out
--     freezes the whole field rather than one turn, so it gets the shorter
--     rope and a different mechanism -- a forced send-out, not an auto-pick.
--   * the **host-silence clock** (`hostClock`, COOP_STALL_TIMEOUT): on the
--     three replayers, who cannot resolve anything and can only ask. Two things
--     about what it measures, and both were wrong in their own direction: it
--     counts silence *from the host* rather than silence on the wire (see the
--     reset in `drainNet`), and it counts from the **handover** -- the moment
--     the host owes an answer -- rather than from the host's last message,
--     which would fold the whole of that message's narration into the silence
--     it is meant to be measuring.
--
-- One more thing lives here that is not a clock in that sense either: the
-- bottomed-out wait below (`wedgeAsked`). It is the promise `waitLine` printed
-- being kept -- when the number on screen runs out with nothing to show for
-- it, this asks the host for the field rather than sitting on "(0)".
--
-- `waitShown` is not a clock in that sense: it is how long the turn has been
-- open, ticked on all four purely so the line can appear and count down against
-- the deadline above. It enforces nothing.

-- ------- how much longer than the host's own deadline a wait is given
--
-- The wait below is bounded by the host's deadline, not by this client's copy
-- of the number -- and the two do not start together. Every client stamps its
-- countdown at *its own* handover, and a client that read the last batch faster
-- than the host reaches that moment first; on top of that the host's answer has
-- to travel. So asking at exactly COOP_TURN_TIMEOUT would fire on every turn
-- the host lets run to its deadline, on all three replayers at once, for a
-- battle with nothing wrong with it -- and each pointless snapshot would clear
-- `acted` (the wait line then misnaming who is late) and reset `waitShown` (the
-- countdown jumping back to 60), which is the same number lying again in a new
-- way.
--
-- Borrowed rather than invented, and from the closest analogue there is:
-- Config pairs COOP_ASK_TIMEOUT with COOP_ASK_GRACE for exactly this shape of
-- question -- "how much slack on top of a sixty-second budget before the side
-- that is waiting concludes the answer is never coming". This is that question
-- asked about a different sixty. (A constant of this mod's own would have to
-- live in Config.lua, which this change does not own.)
local WEDGE_GRACE = Config.COOP_ASK_GRACE

-- Real seconds for stall / wait clocks.
--
-- `update` is handed FixedStep's logic dt (always 1/60 per step). GameSpeed
-- multiplies how *many* steps run per real second, not the dt value -- so at
-- 10X the countdown used to burn ten display-seconds per real second while a
-- Node hub (Date.now) still had a wall minute left. Prefer love.timer wall
-- time for ordinary steps. Multi-second `dt` arguments (the suite's scripted
-- jumps) stay authoritative so headless tests can advance a clock without a
-- timer.
local STEP = 1 / 60
local function stallDelta(self, dt)
  dt = dt or 0
  if dt > STEP * 2 then return dt end
  local timer = rawget(_G, "love")
  timer = timer and timer.timer
  local getTime = timer and timer.getTime
  if type(getTime) ~= "function" then
    return dt
  end
  local ok, now = pcall(getTime)
  if not ok or type(now) ~= "number" then
    return dt
  end
  local prev = self._stallWall
  self._stallWall = now
  if prev == nil then return 0 end
  local elapsed = now - prev
  if elapsed < 0 then return 0 end
  -- Same anti-spiral ceiling FixedStep uses after a hitch / alt-tab.
  if elapsed > 0.25 then elapsed = 0.25 end
  return elapsed
end

function M:tickStalls(dt)
  if self.result or self.phase == "over" then return end
  dt = stallDelta(self, dt)
  -- ------- and none of these clocks belong to a refereed fight
  --
  -- All three of them are about a *client* that has stopped answering, and all
  -- three act over mmo.coop_relay -- the forced send-out, the resync request,
  -- the "cut short" draw. On the mediated path the relay is cut at the hub, the
  -- client that used to decide decides nothing, and the two clocks that matter
  -- (BATTLE_CHOICE_TIMEOUT and BATTLE_RECONNECT_GRACE) are the
  -- intermediator's -- which is also the only party that can see whether
  -- somebody has really gone. What is left here would be a screen declaring a
  -- battle over that the referee is still running, and then hearing the outcome.
  --
  -- The one thing kept is the number on screen: `waitShown` is what the wait
  -- line counts, and a player waiting on a refereed turn is owed it just as
  -- much.
  if self.mediated then
    self.waitShown = (self.waitShown or 0) + (dt or 0)
    return
  end

  -- ------- the clock the *screen* reads, and it starts at the handover
  --
  -- Ticked on every client rather than only the one that can act on it: the
  -- host's `waitClock` decides when to step in and a replayer has no
  -- equivalent, so without this the three people who are merely waiting are the
  -- three with nothing to look at.
  --
  -- **Ticked unconditionally, not only while `waitingOn()` answers.** It used
  -- to start when *this* client committed -- `waitingOn` is falsy for the whole
  -- of your own deliberation, and the else branch above reset it every frame of
  -- it. So a player who spent twenty seconds choosing started counting twenty
  -- seconds late and was reading "(20)" at the moment the host's deadline fired
  -- and picked for everybody. The number promised something that had already
  -- happened.
  --
  -- What it counts now is time since the turn opened, because that is what the
  -- deadline it is counting against measures. The reset lives at the
  -- messages->choose handover in `update`, beside `openTurn` -- one event, and
  -- every client reaches it from its own copy of the same batch of messages.
  -- `COOP_WAIT_HINT` still decides when any of it is *shown* (see `waitLine`),
  -- so an ordinary turn still says nothing.
  self.waitShown = (self.waitShown or 0) + (dt or 0)

  if self.host then
    if self.sim:awaitingChoice() then
      -- ------- clock two: the replacement choice, exactly as it was
      --
      -- A choice nobody answers stops the battle dead -- the field refuses to
      -- resolve while any slot is awaiting -- so it gets the *shorter* clock:
      -- a player still picking a move holds up one turn, a player who has not
      -- answered a faint holds up everything, and theirs is the easier
      -- decision of the two. Resolved by sending out whatever was next rather
      -- than waiting forever.
      self.waitClock = (self.waitClock or 0) + dt
      if self.waitClock >= Config.COOP_CHOICE_TIMEOUT then
        self.waitClock = 0
        local slot = self.sim:awaitingChoice()
        if slot then
          self:applyReplace({ slot = slot.index,
                              index = self.sim:hasReserve(slot),
                              forced = true })
        end
      end
      return
    end
    self.waitClock = 0

    -- ------- clock one: the turn deadline
    --
    -- **The old clock here ran backwards.** It only ticked while the host's own
    -- phase was "wait" -- that is, only once the host had *already committed*
    -- -- and it ended in `forfeitSilent`, which excludes the host's own slot.
    -- So the one player who had answered was the one being clocked, and the
    -- one who had not was bounded by nothing at all: an idle host held the
    -- other three forever, and a committed host wrote off whoever it was
    -- waiting for. Both halves are gone.
    --
    -- What replaces it does not care whose phase is what. The deadline belongs
    -- to the *turn*, it is stamped when the turn becomes decidable (see
    -- `openTurn`), and on expiry every slot that still owes an action is
    -- picked for -- the host's own included. Nobody is ever written off for
    -- being slow; the battle simply moves.
    --
    -- Frozen while a replacement pause is live (the early return above): that
    -- silence belongs to the other clock, and letting this one run through a
    -- 30-second pause would fire it the instant the pause cleared, on players
    -- who had not been asked anything yet.
    if self.turnOpened then
      self.turnOpened = self.turnOpened + dt
      if self.turnOpened >= Config.COOP_TURN_TIMEOUT then
        -- Disarmed before the pick, not after: `autoPickLate` resolves the
        -- turn, and the batch of messages that produces keeps `tickStalls`
        -- running -- an armed clock still past its deadline would fire again
        -- on the very next frame, and every frame after it. The turn that
        -- resolves re-arms it at the handover (see `openTurn`).
        --
        -- ...unless nothing was filed, which is now three cases rather than
        -- one: a sim with no `defaultAction` to ask, the messages phase (the
        -- previous turn is still being read -- nobody is late for a menu they
        -- have not been offered), and a slot `defaultAction` cannot answer for,
        -- which abandons the whole attempt rather than filing half a turn. All
        -- three re-arm rather than leaving the clock dead, so the wait stays
        -- bounded and the next expiry tries again on a field that has moved.
        self.turnOpened = nil
        if not self:autoPickLate() then self.turnOpened = 0 end
      end
    end
    return
  end

  -- ------- the wait that outlived the number printed on it
  --
  -- **This is the reported "(0)" freeze, and it is a lost message rather than
  -- a broken clock.** A replayer commits, goes to `wait`, and from then on the
  -- only thing that can move it is the host's next `res` -- so a message
  -- dropped in either direction wedges it: an `act` that never arrived leaves
  -- the host waiting for an answer this client believes it gave, and a `res`
  -- that never arrived leaves this client waiting for a turn the host believes
  -- it sent. Either way the countdown on screen runs to zero and sits there.
  --
  -- Neither clock below covered it. `hostClock` is reset by *any* traffic --
  -- another player's `act`, the host's answer to somebody else's resync -- so
  -- in a chatty group it never reaches COOP_STALL_TIMEOUT at all; and even at
  -- 75 seconds it is longer than the 60 this client is counting down. The only
  -- thing that unwedged the battle was the host's own turn deadline, a full
  -- minute later, which then auto-picked away the turn this player had already
  -- taken.
  --
  -- So the promise the number makes is kept by the client that made it: when
  -- the budget on screen runs out with nothing to show for it, ask the host for
  -- the field. One request per wait -- `wedgeAsked` is cleared at the handover
  -- beside `waitShown` -- so a slow turn costs one message and not a storm, and
  -- the host's answer is addressed to the asker alone (see the `resync`
  -- handler). What comes back puts this client right: see `M:unwedge`.
  --
  -- Never while spectating (that wait is permanent by design and has nothing to
  -- ask about), never mid-replacement, and never on the host -- the host is the
  -- thing being waited *for*, and its own deadline is what bounds it.
  if self.phase == "wait" and not self.replacing and not self.wedgeAsked
     and not self:spectating()
     and (self.waitShown or 0) >= Config.COOP_TURN_TIMEOUT + WEDGE_GRACE then
    self.wedgeAsked = true
    self.wedged = true
    mod.log:warn("a co-op turn has taken longer than its own deadline; asking "
      .. "the host for the field in case a message was lost")
    self:requestResync()
  end

  -- A replayer, waiting on the host.
  self.hostClock = (self.hostClock or 0) + dt
  if self.hostClock < Config.COOP_STALL_TIMEOUT then return end
  self.hostClock = 0
  if not self.stalled then
    -- First silence: assume a lost message and ask for the field. Cheap, and
    -- it repairs the ordinary case without anybody noticing.
    self.stalled = true
    mod.log:warn("the co-op battle has gone quiet; asking the host for the "
      .. "field again")
    return self:requestResync()
  end
  -- Second silence: the host is not answering at all, and nobody else can
  -- resolve a turn. Ended as a draw and said out loud, because four people
  -- sitting on a battle that will never continue is the worst outcome
  -- available.
  self.result = "draw"
  self:say("The battle was\ncut short.")
  self.phase = "messages"
  self.after = "over"
end

-- ------- the turn is now decidable: start the deadline
--
-- Stamped at **one** point, and this is it: the moment `update` hands the box
-- back from the messages phase to whatever comes next. That one point covers
-- both cases the deadline has to cover -- the first `choose` (the opening
-- "2 on 2 battle!" line drains and the first menu opens) and every later one
-- (a resolved turn's events finish applying and the next menu opens) -- and it
-- has the property `tryResolve` does not: it fires when the turn is decidable
-- *to a player*, rather than when the sim finished computing the last one and
-- everybody still had twenty seconds of messages to read.
--
-- Held as seconds elapsed rather than as a timestamp, because that is what
-- every other clock on this screen is: `tickStalls` is handed `dt` and there is
-- no wall clock in here to read. Nil means "no turn is open", which is the
-- state during a replacement pause and after the deadline has fired.
--
-- Host-only. It is the host that enforces it; the number the other three see
-- is a display of the same budget (see `waitLine`), started from their own
-- side of the same event.
--
-- Never on the mediated path: the deadline it arms is enforced by
-- `autoPickLate`, which resolves a turn, and the intermediator is already
-- holding its own BATTLE_CHOICE_TIMEOUT over the same turn. Two deadlines
-- racing decide the turn on whichever fires first.
function M:openTurn()
  if not self.host or self.result or self.mediated then return end
  -- Refereed modes wait for the hub; do not arm a host-sim choice clock.
  if M.mediates(self.mode) then return end
  self.turnOpened = 0
end

-- ------- the deadline fires: pick for whoever is late
--
-- The owner's policy, and it is deliberately not the old one: **nobody
-- forfeits for being slow.** A player who has wandered off costs the table one
-- turn's worth of their monster doing something sensible, not their place in
-- the battle -- and a battle that ends because somebody answered the door is a
-- worse outcome than one that plays itself for a turn.
--
-- Every living player slot that has not filed an action gets
-- `CoopSim:defaultAction`, **the host's own slot included** -- which is the
-- half the old clock could not do and the half the reported hang needed.
--
-- `defaultAction` is asked for through a guard rather than called outright: the
-- suite builds clients over minimal sims, and a sim without one leaves the slot
-- unfiled (the turn then simply waits, exactly as it did before) rather than
-- taking the battle down inside a clock.
function M:autoPickLate()
  if not (self.host and self.sim) then return false end
  if self.result then return false end
  -- The intermediator's clock, not ours -- see `openTurn`. Belt to that brace:
  -- `tickStalls` is the only caller and it returns before reaching here, so this
  -- is for the day something else fires the deadline.
  if self.mediated then return false end
  if M.mediates(self.mode) then return false end
  -- ------- nobody is late during the narration
  --
  -- The messages phase is not a wait for an answer: it is the turn *before*
  -- this one still being read, on a box that holds every line for at least
  -- 1.6 seconds. Nobody has been offered the menu yet, so nobody can be late
  -- for it, and firing here files a turn against players who were never asked.
  --
  -- The clock's other end is closed in `tryResolve`, which disarms it the
  -- moment it commits to resolving. This is the belt to that pair of braces:
  -- the host reaches the messages phase by paths that never touch `tryResolve`
  -- at all -- the opening "2 on 2 battle!" line, and `applyReplace` playing a
  -- forced send-out's batch.
  if self.phase == "messages" then return false end
  -- Never while a slot is still owed a send-out: that pause is the other
  -- clock's, and a turn cannot resolve through it anyway.
  if self.sim:awaitingChoice() then return false end
  self.pending = self.pending or {}

  -- ------- collected for everybody first, filed for nobody until it is
  --
  -- **A partial auto-pick is an unrecoverable hang, and it used to be one file
  -- away.** `defaultAction` returns nil for a live slot with no living target,
  -- and the old loop filed whatever it did get: `tryResolve` then found a slot
  -- still owing an action and returned, leaving `pending` half full, `acted`
  -- half set, `lateNotes` sitting there ready to blame those players on some
  -- *later* turn, the deadline disarmed by the caller, and -- for the host's
  -- own slot -- `closePickers` having parked it in "wait" with no menu to
  -- answer from. Nothing left could resolve or re-arm anything.
  --
  -- So the picks are gathered before a single one is filed, and one nil is
  -- enough to abandon the whole attempt. Returning false re-arms the clock in
  -- `tickStalls`, so the next expiry tries again -- by which time the field has
  -- almost certainly moved (the slot with no target means the other side is
  -- mid-faint) and every slot can be answered for.
  local picks = {}
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner ~= nil and not self.sim:isDown(slot)
       and not self.pending[slot.index] then
      local action = self.sim.defaultAction
        and self.sim:defaultAction(slot.index)
      if not action then return false end
      picks[#picks + 1] = { slot = slot, action = action }
    end
  end
  if #picks == 0 then return false end

  local notes = {}
  for _, pick in ipairs(picks) do
    local slot = pick.slot
    self.pending[slot.index] = pick.action
    self:markActed(slot.index)
    -- Said out loud, per slot, in the words the forced replacement already
    -- uses (see `applyReplace`): a choice a clock made looks exactly like a
    -- choice the player made, and the four people watching are owed the
    -- difference. One line, and it fits the eighteen-column box at the
    -- longest name the wire can carry (NAME_MAX 10 + "took too long!").
    notes[#notes + 1] = { kind = "msg",
      text = (slot.name or "Someone") .. "\ntook too long!" }
    -- ...and if it was *this* client that was idle, its menus close on the
    -- state change rather than on a button it is not going to press --
    -- the same discipline the forced send-out closes the bench picker with.
    if slot.index == self.mine then self:closePickers() end
  end

  -- Carried into the turn rather than said here, so all four clients hear it:
  -- `tryResolve` puts them at the head of the events it broadcasts. Ordinary
  -- `msg` rows -- nothing new on the wire, and an older client plays them like
  -- any other line.
  self.lateNotes = notes
  self:tryResolve()
  return true
end

-- Shut whatever menu this client is sitting in, because its answer has just
-- been filed for it. Only the phases that are a *question*: `replacing` is
-- untouched, since a slot awaiting a send-out is never auto-picked.
function M:closePickers()
  local open = self.runAsk ~= nil
    or self.phase == "choose" or self.phase == "move"
    or self.phase == "target" or self.phase == "switch"
    or self.phase == "item" or self.phase == "item_party"
    or self.phase == "item_move"
  if not open then return false end
  self.itemPick = nil
  self.itemPartyIndex = nil
  -- A consent ask is a question too, and the clock has just answered it: the
  -- turn this client was going to spend on running has been spent on a move
  -- instead, so neither the wait nor the prompt has anything left to resolve.
  self.runAsk = nil
  self.phase = "wait"
  -- The cursors go back where a fresh turn would put them, so the menu that
  -- opens next turn is not still pointing at half a decision from this one.
  self.commandIndex = 1
  self.moveIndex = 1
  self.targetIndex = 1
  return true
end

-- ------- one turn, as a replayer sees it
--
-- Two things can be wrong with an arriving turn, and they need telling apart.
--
--   * **A gap.** Its number is not the one after the last, so a message was
--     lost. Nothing about the events in hand can repair that -- the missing
--     turn's damage is simply unknown -- so the field is asked for instead.
--   * **A mismatch.** Every turn arrived and the two copies still disagree,
--     which means a replay diverged rather than a message vanished. Same
--     remedy, different cause, and worth logging as its own thing because it
--     points at a bug in the mod rather than at the network.
--
-- Both recover the same way and neither ends the battle: the host is the
-- authority, so being put back in step with it is always available.
function M:applyTurn(msg)
  local seq = Wire.int(msg.seq, 1, 100000)
  local expected = (self.seq or 0) + 1
  -- The turn has come back, so every answer this client was watching for was
  -- given -- the replayer's half of the reset `tryResolve` does on the host.
  self.acted = nil

  if seq and seq ~= expected then
    self.gaps = (self.gaps or 0) + 1
    mod.log:warn("a co-op battle missed turn %d (saw %d); asking the host to "
      .. "re-send the field", expected, seq)
    self.seq = seq
    self:playEvents(msg.events)
    return self:requestResync()
  end

  self.seq = seq or expected
  -- The turn this client was waiting on has come back, so whatever it spent
  -- on that turn was really spent.
  self.owed = nil
  self:playEvents(msg.events)

  if type(msg.sig) == "string" then
    local mine = self.sim:signature()
    if mine ~= msg.sig then
      self.desyncs = (self.desyncs or 0) + 1
      mod.log:warn("a co-op battle drifted from the host after turn %d "
        .. "(host %s, here %s); re-syncing", self.seq, msg.sig, mine)
      return self:requestResync()
    end
  end
end

-- Whether a message the relay fanned out to all four was meant for this one.
--
-- An older host sends no `to` at all, and a snapshot is always safe to apply
-- -- it is the host's own field -- so an unaddressed one is still taken. What
-- it must not do is silently reset the sequence of a client that was never
-- behind, which is what `to` prevents.
function M:addressedToMe(msg)
  local to = Wire.id(msg.to)
  if not to then return true end
  local slot = self.sim:slot(self.mine)
  return slot ~= nil and slot.owner == to
end

-- Did the host say this?
--
-- `res`, `state` and `gone` are the three things only the host is ever
-- entitled to send: a resolved turn, a snapshot of the field, and a player
-- written off. The relay fans every message out to all four, so without this
-- any client could post one -- rewriting everybody's HP, replacing the whole
-- field, or forfeiting a player who is still sitting there. `act` has been
-- checked against its sender all along (see `drainNet`); this is the same rule
-- pointed the other way.
--
-- It is a slightly wider fix than the display sequencing it arrived with:
-- `state` and `gone` predate all of it. The rule is the same for all three and
-- the surface was flagged as one, so it is closed as one.
--
-- Answered permissively when either side of the comparison is unknown -- an
-- older host sends no `from`, and a client that never learned who the host is
-- has nothing to compare against. Refusing there would break a battle that is
-- merely old rather than forged.
function M:fromHost(msg)
  if self.hostId == nil or msg.from == nil then return true end
  return msg.from == self.hostId
end

function M:requestResync()
  if not self.net then return false end
  self.net.send({ t = "resync" })
  return true
end

-- ------- and what the answer does to a client that was stuck
--
-- A snapshot has always put the *field* right. It never put the **screen**
-- right, and that is the other half of the "(0)" freeze: a client wedged in
-- `wait` -- because the turn it answered never came back -- had its HP numbers
-- corrected and was left sitting in the same answered-and-waiting state, with
-- no menu, for as long as the battle lasted.
--
-- So a snapshot that answers a wedged wait hands the box back. Whatever this
-- client committed to is now either resolved (the field it has just been given
-- is the proof) or was never received; both readings end the same way, with the
-- player owed a menu. Committing again costs nothing on the wire -- the host
-- keys `pending` by slot, so a second answer replaces the first rather than
-- adding to it, and nothing about the sim moves either way.
--
-- It is not free in the **bag**, though, and that is why the refund happens
-- first. `updateItem` debits the item at the moment of committing, because only
-- this client owns its inventory, and `owed` holds exactly one id -- so a
-- player who picked a POTION, was unwedged, and picked one again would be
-- debited twice and refunded once. The turn being reopened here is by
-- definition unresolved, which is precisely the condition `refundUnspent` was
-- written for.
--
-- `acted` goes with it, because it is a claim about a turn this client has just
-- been told it is not in step with: keeping it would leave the wait line naming
-- people who have answered and omitting people who have not.
--
-- Only for a wait this client actually flagged (see `tickStalls`). An ordinary
-- resync -- one asked for because a turn number had a gap in it -- must not
-- reopen a menu behind the batch of messages it is already playing.
function M:unwedge()
  if not self.wedged then return false end
  self.wedged, self.wedgeAsked = nil, nil
  self.waitShown = 0
  self.acted = nil
  if self.result or self.replacing or self:spectating() then return true end
  if self.phase == "wait" then
    -- The item paid for on the turn that is being reopened comes back before
    -- the menu that can spend another one does (see the header).
    self:refundUnspent()
    self.phase = "choose"
    self.commandIndex = 1
    self.moveIndex = 1
    self.targetIndex = 1
    -- A consent ask belongs to the turn that went missing with it.
    self.runAsk = nil
  end
  return true
end

-- ------- somebody left
--
-- Two very different cases behind one message.
--
-- If it was the **host**, there is nobody left to resolve a turn: the other
-- three are replaying events from a client that has gone. The battle ends,
-- called a draw, because nobody won it and inventing a winner from whoever
-- happened to still be connected would be worse than saying so.
--
-- If it was anybody else, their slot forfeits and the fight carries on three
-- ways. That is the case the host must handle promptly -- it stops waiting for
-- an action that will never arrive, which is the deadlock this exists for.
function M:peerGone(id)
  if not id or self.result then return false end

  local hostGone = self.hostId ~= nil and self.hostId == id
  if hostGone and not self.host then
    self.result = "draw"
    self:say("The battle was\ncut short.")
    self.phase = "messages"
    self.after = "over"
    return true
  end

  local slot = self.sim:forfeit(id)
  if not slot then return false end
  -- A consent ask whose other end has just walked out cannot be answered by
  -- anybody, so it comes down rather than sitting there waiting on a client
  -- that is gone.
  if self.runAsk and self.runAsk.slot == slot.index then self.runAsk = nil end
  self:say((slot.name or "Someone") .. "\nleft the battle!")
  self.phase = "messages"
  -- Whatever they had filed is void, and the turn may now be resolvable
  -- without them.
  self.pending[slot.index] = nil
  if self.host then
    if self.sim:checkOver({}) then
      self.result = self:resultFor(self.sim.over)
      self.after = "over"
    else
      self:tryResolve()
    end
  end
  return true
end

-- ------- the wire

function M:drainNet()
  for _, msg in ipairs(self.net.poll() or {}) do
    if type(msg) == "table" then
      -- ------- the host-silence clock hears the **host**, not the wire
      --
      -- This used to be reset by any message at all, on the reading that
      -- traffic means the battle is alive. It does not: only the host can
      -- resolve a turn, so a battle whose host has stopped answering is a
      -- battle that has stopped, however busy the other three are -- and they
      -- *are* busy, because a player who has not heard back keeps pressing
      -- buttons and every one of those `act` messages reset this clock on the
      -- other two. Three replayers therefore held each other's stall detection
      -- at zero forever, and the one recovery that exists for a departed host
      -- -- ask for the field, then call it cut short -- could never fire.
      --
      -- The three types the host alone may send are exactly the three that
      -- count as the host answering, and each is checked against `fromHost`
      -- like the handlers below, so a client cannot keep somebody else's
      -- clock alive by posting one.
      --
      -- Resetting it here is the *ceiling* on the wait, not where the wait
      -- starts: the handover restarts it too (see `update`), because the
      -- narration a `res` produces is time the host is entitled to and not
      -- silence to be counted against it.
      if (msg.t == "res" or msg.t == "state" or msg.t == "gone")
         and self:fromHost(msg) then
        self.hostClock = 0
        self.stalled = nil
      end
      if msg.t == "act" and self.host and type(msg.action) == "table" then
        local action = msg.action
        -- Only the slot that sent it may act for it. Without this a modified
        -- client could file its partner's move, or the NPC's.
        local slot = self.sim:slot(action.slot)
        if slot and slot.owner and slot.owner == msg.from then
          -- A replacement, not a turn.
          --
          -- The field is paused waiting for exactly this slot to send its next
          -- monster out, and `tryResolve` refuses to resolve anything while it
          -- is -- so filing a replacement as an ordinary action put it in a
          -- queue that could never be drained, and the pause waited on itself.
          -- Every non-host player whose monster fainted deadlocked the battle
          -- for all four until the stall timeout force-picked for them a
          -- minute later. Told apart by the field's own `awaiting`, which is
          -- the host's state and cannot be claimed by a message.
          if slot.awaiting then
            self:applyReplace({ slot = action.slot,
                                index = Wire.int(action.index, 1, 6) })
          elseif action.kind == CoopSim.REPLACE then
            -- An answer to a question that is no longer being asked: the
            -- replacement already landed and this is a duplicate, or a stale
            -- retry. Dropped rather than fed to the line below, which would
            -- not recognise the kind, fall back to "move", and file a move
            -- this player never chose -- overwriting the one they did.
            mod.log:warn("a co-op replacement arrived for a slot that is not "
              .. "waiting; ignoring it (the battle is unaffected)")
          else
            -- Re-derived rather than trusted, like anything else off the wire:
            -- this decides what somebody else's monster does.
            local kind = CoopSim.KINDS[action.kind] and action.kind or "move"
            self.pending[action.slot] = {
              slot = action.slot,
              kind = kind,
              move = Wire.int(action.move, 1, 8) or 1,
              target = Wire.int(action.target, 1, Config.COOP_FIGHTERS) or 1,
              index = Wire.int(action.index, 1, 6),
              item = kind == "item" and Wire.spriteId(action.item) or nil,
            }
            self:markActed(action.slot)
            self:tryResolve()
          end
        end
      elseif msg.t == "act" and not self.host and type(msg.action) == "table" then
        -- Watched, never acted on.
        --
        -- The relay fans every `act` out to all four, and until now the three
        -- clients that cannot resolve a turn simply dropped them -- which is
        -- why their wait line had nothing to say and fell back to a countdown
        -- nothing on this client enforces. Reading them costs nothing and
        -- answers the only question a waiting player has: who are we waiting
        -- for. Nothing is filed and nothing is simulated from it -- the host
        -- is still the only client that acts on an action, and it still checks
        -- the sender owns the slot (above) before it does.
        --
        -- Two conditions on the marking, both of them about not lying to the
        -- player reading the wait line:
        --
        --   * a **replacement is not a turn action**. The slot that sends one
        --     still owes this turn a move, so marking it acted takes it off
        --     the missing list for good -- and the case that makes that
        --     visible is a lost `res` recovered by snapshot, where the turn
        --     never resets `acted` and the slot stays silently omitted for the
        --     rest of it. The host tells the two apart by `slot.awaiting`,
        --     which is its own state; here the kind on the message is all
        --     there is, and it is enough because nothing is simulated from it.
        --
        --   * the **sender must own the slot it names**. The host has checked
        --     that all along, and the comment above claims the rule for this
        --     branch too -- so the code has to make it true rather than take
        --     any client's word for which slot has answered.
        local seen = Wire.int(msg.action.slot, 1, Config.COOP_FIGHTERS)
        local slot = seen and self.sim:slot(seen)
        if slot and slot.owner and slot.owner == msg.from
           and msg.action.kind ~= CoopSim.REPLACE then
          self:markActed(seen)
        end
      elseif msg.t == Wire.COOP_RUN_ASK then
        -- Who asked is the sender the hub stamped, resolved against this
        -- client's own copy of the field -- never a slot named in the payload,
        -- which is a slot a modified client could claim.
        local from = self:slotOwnedBy(msg.from)
        local mine = self:mySlot()
        if from and not self.result then
          -- Recorded by the host whichever side it came from: the host is what
          -- resolves a flee, and it will not resolve one it never saw asked
          -- for -- including when the host is one of the two being asked
          -- *about*, sitting on the other side of the field.
          if self.host then self:hostRunAsk(from.index) end
          -- ...and only the asker's own partner is being asked. The other two
          -- see the message and ignore it, exactly as they ignore an `act`
          -- filed for a slot they do not own.
          if mine and from.index ~= self.mine and from.side == mine.side
             and self:partyBattle() then
            local up = self.runAsk
            -- ------- the same question, asked again
            --
            -- A prompt already up for this slot is left exactly as it is, and
            -- that is a guard against the settle floor being defeated by
            -- repetition: a client that sent an ask every frame would otherwise
            -- put the cursor back on the safe answer and restart the clock
            -- every frame, leaving a prompt that can never be answered -- and,
            -- worse, one whose floor is forever about to expire under a player
            -- who is holding A. The prompt on screen *is* the ask; a second
            -- copy of it says nothing new.
            local already = up ~= nil and up.role == "deciding"
              and up.slot == from.index
            if up and up.role == "asking" then
              -- ------- both of them pressed RUN
              --
              -- Two asks crossing on the wire, and the wrong answer here is a
              -- wedge: two clients each waiting for the other to answer a
              -- question neither is being shown. The right one needs no
              -- tie-break at all, because the state itself is the answer --
              -- **a player who has just asked to leave has already consented
              -- to leaving.** So the second ask is taken as the reply to the
              -- first, from both ends; the host sees two yeses and resolves the
              -- first one it can, and the second finds the battle already
              -- decided and does nothing (see `resolveFlee`).
              self:answerRun(true)
            elseif not already then
              self.runAsk = { role = "deciding", slot = from.index,
                              name = from.name, index = RUN_DEFAULT,
                              clock = 0 }
            end
          end
        end
      elseif msg.t == Wire.COOP_RUN_ANSWER then
        local from = self:slotOwnedBy(msg.from)
        local ok = Wire.flag(msg.ok)
        if from and not self.result then
          if self.host then self:hostRunAnswer(from.index, ok) end
          -- The asker's own end of it. Everyone else has nothing to close.
          if self.runAsk and self.runAsk.role == "asking"
             and self.runAsk.slot == from.index then
            self.runAsk = ok and { role = "fleeing" }
              or { role = "refused", name = from.name, clock = 0 }
          end
        end
      elseif msg.t == "res" and not self.host and self:fromHost(msg) then
        self:applyTurn(msg)
      elseif msg.t == "resync" and self.host then
        -- Somebody fell behind. Answer with the field itself rather than with
        -- the turns they missed: a snapshot puts them right in one message
        -- whatever they lost, and cannot itself arrive out of order.
        --
        -- Addressed to whoever asked, because the relay fans every message out
        -- to all four. An unaddressed answer was applied by all three
        -- replayers, and the two who were perfectly in step had their `seq`
        -- set back to the host's -- which the next turn then read as a gap, so
        -- they asked too, which rewound everybody again. One client falling
        -- behind by a single message turned into a resync storm that never
        -- converged and a battle that never ended.
        if self.net then
          self.net.send({ t = "state", to = msg.from, seq = self.seq or 0,
                          slots = self.sim:snapshot() })
        end
      elseif msg.t == "gone" and not self.host and self:fromHost(msg) then
        -- The host has written somebody off. Applied rather than re-derived,
        -- so all four agree on who is still in the fight.
        local owner = Wire.id(msg.owner)
        if owner then
          local slot = self.sim:forfeit(owner)
          if slot then self:say((slot.name or "Someone") .. "\nstopped answering!") end
        end
      elseif msg.t == "state" and not self.host and self:fromHost(msg)
             and self:addressedToMe(msg) then
        self.sim:restore(msg.slots)
        -- The numbers have just changed underneath the screen, so whatever the
        -- bars were animating towards is no longer where they are going. The
        -- display is put where the host says the field is, in one step: an
        -- animation left running across a resync is a bar sliding towards a
        -- number nobody holds any more.
        self:snapDisplay()
        self.seq = Wire.int(msg.seq, 0, 100000) or self.seq
        self.resyncs = (self.resyncs or 0) + 1
        mod.log:warn("a co-op battle re-synchronised with the host after a "
          .. "lost message; the field on screen is correct again")
        -- ...and a client that was stuck answering a turn nobody sent back
        -- gets its menu returned with it (M:unwedge).
        self:unwedge()
      end
    end
  end
end

-- ------- the intermediator, when there is one
--
-- The third path promised in the header, and the shape of it is deliberately the
-- same three jobs src/MediatedBattle.lua does for a 1v1:
--
--   1. upload what we are bringing -- `mmo.battle_party` per seat, and on the
--      host `mmo.battle_ruleset` -- before the fight opens;
--   2. put a choice on the wire when a turn opens;
--   3. apply the ordered `mmo.battle_event` stream to a screen.
--
-- What is *not* here is a second renderer. Every event is translated into the
-- co-op event vocabulary `playEvents` already speaks and handed to it, so a
-- refereed turn drains through the same queue, the same bar animations, the same
-- faint slides and the same message dwell as a host-simulated one. That is the
-- point: a player must not be able to tell which of the two ran their battle,
-- and the way to guarantee that is for there to be one screen rather than two
-- that look alike.
--
-- The translation is the whole of the risk, so the two readings that are easy to
-- get backwards are named:
--
--   * a **field slot** on the wire is 0..3 (side a takes 0 and 1, side b takes 2
--     and 3, per src/BattleSim/events.lua) while this screen numbers its slots
--     1..4 in a1,a2,b1,b2 order. They are not the same number and the map
--     between them is built from the hub's own roster, not from the arithmetic
--     that happens to line up today -- see `medMap`.
--   * a `switch` **choice** names a party index; a `send` **event** names a field
--     slot. Same word, two numbers.
--
-- Batching matters as much as translation. Events arrive one per message, and
-- `playEvents` closes every open menu -- so applying them one at a time would
-- take the move list away from a player mid-decision every time the referee said
-- anything. They are collected instead and played when the referee closes the
-- batch (`turn`, or `over`), which makes an arriving turn look exactly like the
-- single `res` the client-simulated path sends.

-- Is this mode hub-refereed? Always for Config.MEDIATED_COOP
-- (`coop_pvp` / `coop_npc` / `coop_wild`) — not a Config toggle beyond that
-- table. Host-sim for those modes was removed (BattleSim vs engine
-- ItemEffects must not diverge). CoopSim remains for field layout / tests.
function M.mediates(mode)
  return mode == "coop_pvp" or mode == "coop_npc" or mode == "coop_wild"
end

-- ------- 1. what we are bringing

-- The NPC side's team, as one party in the order the trainer would send it out.
--
-- Re-interleaved, because that is how it was split: src/Coop.lua's `npcSide`
-- deals the trainer's party alternately into the two ownerless slots so that a
-- pair of players meets a pair of monsters. Taking one from each slot in turn
-- gives back the original order -- and order is the whole of what is at stake
-- here, because the referee sends the next living monster out in party order and
-- never asks. Concatenating instead would have a gym leader lead with the
-- monster it meant to finish on.
--
-- One party and not two, because the intermediator seats one npc: see
-- Config.MEDIATED_COOP's first reason.
--
-- **Not used for `coop_wild`.** Wild is one mon on side b; interleave would
-- invent a second trainer slot. See `uploadMediated`'s coop_wild branch.
function M:npcMons()
  if not self.sim then return nil end
  local parties = {}
  for _, slot in ipairs(self.sim.slots or {}) do
    if slot.owner == nil then parties[#parties + 1] = slot.party or {} end
  end
  if #parties == 0 then return nil end

  local flat, index = {}, 1
  while true do
    local took = false
    for _, party in ipairs(parties) do
      local mon = party[index]
      if mon then
        flat[#flat + 1] = mon
        took = true
      end
    end
    if not took then break end
    index = index + 1
  end
  return Mediated.snapshotMons(self.game, flat)
end

-- Sheets for the wild seat (coop_wild side b): prebuilt `wildParty`, else a
-- snapshot of the stashed `wildCatchMon`. Never npcMons interleave — that
-- assumes two ownerless trainer slots.
function M:wildMons()
  if type(self.wildParty) == "table" and #self.wildParty > 0 then
    return self.wildParty
  end
  if self.wildCatchMon then
    return Mediated.snapshotMons(self.game, { self.wildCatchMon })
  end
  return nil
end

-- Offer this fight to the intermediator.
--
-- Idempotent, and silent about every reason it might decline: a mode that is not
-- refereed, a screen with no hub connection, a battle the hub never named. Those
-- leave `mediated` false. When the mode *is* refereed (Config.MEDIATED_COOP) but
-- the party cannot be described, `medFailed` is set so the host-sim path is not
-- used as a silent fidelity fork (BattleSim vs engine ItemEffects).
--
-- The party uploaded is the slot's, not `game.save.party`. They are the same
-- table for our own slot (src/Coop.lua hands the live party in, so a co-op
-- battle marks the save the way any trainer battle does) -- but the slot is what
-- is actually on the field, and reading it is what lets a screen built with no
-- save upload at all.
function M:uploadMediated()
  if self.medUploaded then return false end
  if not (self.transport and self.battleId and self.sim) then return false end
  if not M.mediates(self.mode) then return false end

  local mine = self:mySlot()
  if not (mine and mine.side) then return false end

  local mons = Mediated.snapshotMons(self.game, mine.party)
  if #mons == 0 then
    -- Uploading nothing would leave the hub holding a seat open. Ending the
    -- fight is better than host-sim with a different item/effect surface.
    mod.log:warn("no POKeMON could be described for a refereed 2-on-2, so this "
      .. "battle cannot be refereed; check the party from START > POKeMON and "
      .. "report this if it is not empty")
    self.medFailed = true
    return false
  end

  self.medUploaded = true
  -- Kept, because the referee will count in *this* list and not in the party
  -- it was cut from. `snapshotMons` skips what it cannot describe, so the two
  -- are the same array only until the first skip -- and every party-addressed
  -- field the hub sends back (`exp`'s `mon`, today) has to come back through
  -- these sheets to find the save monster it means. See `medPartySlot`.
  self.medMine = mons
  local bag = Mediated.snapshotBag(self.game)
  self.bagSheet = Mediated.bagCounts(bag)
  if self.host then Mediated.sendRuleset(self.transport, self.game) end
  Mediated.sendParty(self.transport, self.battleId, mons, mine.side, bag,
    Mediated.badgesOf(self.game))

  -- ...and the trainer's team, from the host alone. `Hub:battleSeat` maps a
  -- side-"b" party from the host of a coop_npc onto the synthetic npc seat
  -- rather than displacing the host's own, which is why this can be a second
  -- mmo.battle_party on the same connection.
  if self.host and self.mode == "coop_npc" then
    local npc = self:npcMons()
    if npc and #npc > 0 then
      Mediated.sendParty(self.transport, self.battleId, npc, "b")
    else
      mod.log:warn("the trainer's party could not be described for a refereed "
        .. "2-on-2 -- report which trainer it was")
      self.medFailed = true
    end
  elseif self.host and self.mode == "coop_wild" then
    -- One wild mon on side b (not npcMons — that re-interleaves two trainer
    -- slots). Sheets from wildParty or a snapshot of wildCatchMon.
    local wild = self:wildMons()
    if wild and #wild > 0 then
      Mediated.sendParty(self.transport, self.battleId, wild, "b")
    else
      mod.log:warn("the wild POKeMON could not be described for a refereed "
        .. "party encounter -- report this with the map and the encounter")
      self.medFailed = true
    end
  end
  return not self.medFailed
end

-- Mediation was required but could not start: end as a draw rather than
-- falling through to host-sim (different item/effect fidelity).
function M:failMediation()
  if self.result or self.mediationFailedSaid then return end
  self.mediationFailedSaid = true
  self.result = "draw"
  self:say("The battle could not\nbe refereed.")
  self.phase = "messages"
  self.after = "over"
end

-- ------- 2. the field is assembled

-- Which co-op slot each field slot is, and the reverse.
--
-- Built from the roster the hub broadcast rather than from `field + 1`, even
-- though that is what it comes to for a four-player fight: the arithmetic is only
-- right while both sides list their members in the order this screen's slots were
-- built in, and neither the hub nor this file promises that -- the ids come from
-- a party roster on one side and a co-op ask on the other.
--
-- **Side b of a coop_npc is deliberately not read off the roster.** The npc seat
-- is not an id a client may address, so `tryStartSim` filters it out and
-- advertises the host instead (a side emptied by the filter is announced as the
-- connection any choice for it would arrive from). Taken literally that would
-- map the trainer's field slot onto the host's own box. So an advertised id that
-- does not own a slot *on that side* falls through to the ownerless slots on it,
-- in field order, which is exactly what the npc seat is.
function M:medMap(sides)
  local byField, byIndex = {}, {}
  if not self.sim then return byField, byIndex end
  for _, side in ipairs({ "a", "b" }) do
    local ids = (type(sides) == "table" and sides[side]) or {}
    -- Config.COOP_SIDE is the same 2 that src/BattleSim/events.lua mirrors as
    -- SIDE_SLOTS; one side's worth of field slots is what separates the bases.
    local base = (side == "b") and Config.COOP_SIDE or 0
    local spare = {}
    for _, slot in ipairs(self.sim.slots or {}) do
      if slot.side == side and slot.owner == nil then spare[#spare + 1] = slot.index end
    end
    for i = 1, #ids do
      local field = base + i - 1
      local owned = self:slotOwnedBy(ids[i])
      local index = (owned and owned.side == side) and owned.index
        or table.remove(spare, 1)
      if index then
        byField[field] = index
        byIndex[index] = field
      end
    end
  end
  return byField, byIndex
end

-- The hub has the parties and the chart; from here it decides everything.
--
-- `mySide` is **not** re-derived from the roster, unlike src/MediatedBattle.lua's
-- `onReady` -- for the coop_npc reason `medMap` gives, and because it does not
-- have to be: this screen was built from a field description that already states
-- which side every slot is on, agreed by all four clients before anybody
-- uploaded anything.
function M:onBattleReady(msg)
  if self.mediated or self.result then return false end
  if not (self.battleId and msg.battle == self.battleId) then return false end
  if not (self.sim and M.mediates(self.mode)) then return false end

  self.mediated = true
  self.medSlots, self.medFields = self:medMap(msg.sides)

  -- Everything the client-simulated path had in flight belongs to a turn that is
  -- now never going to be resolved here. Dropped rather than left: `pending`
  -- would be filed into a `resolveTurn` that no longer runs, `turnOpened` arms a
  -- deadline the referee is already holding, and a consent ask has lost the relay
  -- it was going to be answered over.
  self.pending = {}
  self.acted = nil
  self.runAsks = nil
  self.turnOpened = nil
  self.runAsk = nil
  return true
end

-- ------- 3. the event stream

-- The reasons a refereed fight ends that this screen has a sentence for. An
-- unknown token -- a newer intermediator naming something this build cannot
-- phrase -- is silent rather than printed raw: the result is the part that
-- matters and it has already landed.
local MED_REASONS = {
  timeout    = "Nobody answered\nin time.",
  disconnect = "The link was lost.",
  run        = "Someone ran away!",
  forfeit    = "Someone gave up.",
  agree      = "The battle was\ncalled off.",
  catch      = "Gotcha!",
}

-- One wire event, as rows `playEvents` understands.
function M:medRows(msg)
  local rows = {}
  local function say(text)
    if type(text) == "string" and text ~= "" then
      rows[#rows + 1] = { kind = "msg", text = text }
    end
  end

  local index = self:medSlotOf(msg)
  local slot = index and self.sim:slot(index)
  local kind = msg.t

  if kind == "msg" then
    say(msg.text)

  elseif kind == "send" then
    -- Which of that seat's party is coming out, because the row `playEvents`
    -- wants is what tells `sim:sendOut` which battler to build.
    --
    -- The referee stamps the position on the event (`mon`) and also narrates the
    -- monster by name, and `medSendIndex` reads them in that order: the stamp is
    -- the referee's own answer, the name is this screen's reconstruction of it,
    -- and a stamp that does not fit this party falls back to the name rather than
    -- fielding a number. An older referee sends no stamp at all and the name is
    -- the whole of it, which is what this did before.
    --
    -- Neither matching is a send-out this screen cannot draw; the line is still
    -- printed, so the field being one monster behind at least has an explanation
    -- on it.
    local at = slot and self:medSendIndex(index, slot, msg)
    -- Whose send-out it is decides the sentence, now that the referee's sends
    -- are the *only* ones a player sees (the client-side intro that used to
    -- narrate the opening pair is gone -- see `queueMediatedIntro`). Our own
    -- monster keeps the wording the original gives it and the intro used to;
    -- a wild POKeMON is nobody's send-out at all and keeps the "Wild X
    -- appeared!" it was introduced with, because "TRAINER sent out X!" over a
    -- monster no trainer owns is simply untrue.
    if index == self.mine then
      say(("Go! %s!"):format(tostring(msg.text)))
    elseif self:sentByTrainer(index) then
      say(("%s sent out\n%s!"):format(slot and slot.name or "Someone",
        tostring(msg.text)))
    end
    if at then rows[#rows + 1] = { kind = "send", slot = index, index = at } end

  elseif kind == "damage" or kind == "drain" then
    -- The resulting HP and never the amount, which is the rule the co-op
    -- `damage` row already follows and for the same reason: a dropped or
    -- reordered event cannot leave a bar drifting away from the referee's. A
    -- `drain` is HP that moved *onto* a slot, so it is the same row -- the
    -- number is where that slot now stands either way.
    if index and msg.hp then
      rows[#rows + 1] = { kind = "damage", slot = index, hp = msg.hp }
    end

  elseif kind == "faint" then
    if index then
      -- Nothing faints above zero, so the row that says it fell says the
      -- number too -- for **every** seat, which is what this used to get
      -- wrong. The hp-zeroing fallback below has always existed for our own
      -- seat (it is what arms the replace picker), and the other three had
      -- nothing: a referee `damage` that went missing left a partner's or a
      -- foe's bar stopped part-way down under a monster that then sank, and
      -- its local copy alive. Emitted ahead of the faint rather than folded
      -- into it because `damage` is the one row that both writes HP and
      -- queues the bar, so the empty bar is *animated* into place in front of
      -- the sink exactly as an ordinary killing blow's is.
      --
      -- Costs nothing on the ordinary path: the killing blow's own `damage`
      -- has already brought the bar to zero, and a drain row asked for the
      -- number it is already showing retires immediately (`startDrain`).
      rows[#rows + 1] = { kind = "damage", slot = index, hp = 0 }
      rows[#rows + 1] = { kind = "faint", slot = index }
    end
    -- The referee's `faint` carries the species and no sentence of its own, so
    -- the sentence is made here -- in the original's order, which prints the
    -- line over the top of the monster already sliding down.
    if msg.text then say(("%s fainted!"):format(tostring(msg.text))) end
    -- Authoritative mustReplace: amount=1 means a living bench remains.
    -- Empty bench omits amount so we never arm the replace picker. Absent
    -- amount (older stream) falls back to a local bench check.
    if index == self.mine then
      if msg.amount == 1 then
        self.medMustReplace = true
      elseif msg.amount ~= nil then
        self.medMustReplace = nil
      else
        local seat = self.sim and self.sim:slot(self.mine)
        if seat and seat.active and seat.party and seat.party[seat.active] then
          seat.party[seat.active].hp = 0
        end
        local hasBench = false
        if seat then
          for _, mon in ipairs(seat.party or {}) do
            if (mon.hp or 0) > 0 then hasBench = true; break end
          end
        end
        self.medMustReplace = hasBench or nil
      end
    end

  elseif kind == "exp" then
    -- The spoils of the faint above, as a *row* rather than an award made
    -- here.
    --
    -- Queued instead of applied for the reason every other display-mutating
    -- kind in this function is queued (`faint`, `damage`, `drain`): `medRows`
    -- runs when the event *arrives* and `playEvents` runs when the batch
    -- *closes*, and `gainExp` writes into `self.messages` -- the queue
    -- `playEvents` is filling. Paying at parse time would have put "gained N
    -- EXP. Points!" ahead of the bar that emptied and the monster that sank,
    -- on a screen whose whole chronology is that they come first. Routed
    -- through the ordinary `exp` row, the mediated award lands in
    -- `playEvents`' walk at exactly the point the host-simulated one does, and
    -- there is one exp implementation rather than two.
    --
    -- `slot` is translated the way every other row's is (`medSlotOf`): the
    -- referee counts field slots 0..3 and this screen counts CoopSim indices,
    -- and `gainExp`'s own-slot gate compares against `self.mine`, which is an
    -- index. The referee sends one of these per *paid participant* -- every
    -- monster that was in against the fallen foe and lived, benched included
    -- -- so all four clients see every share of a knockout and each pays only
    -- the ones on its own seat.
    --
    -- `species` is translated too, and it has to be: the referee narrates
    -- under the *uploaded* token (`Wire.name` of a display name), while
    -- `gainExp` -- written for CoopSim, which emits registry keys -- looks the
    -- species straight up in `data.pokemon`. Handing the label through
    -- unchanged would miss every time and pay nothing, silently.
    if index then
      -- `speciesId` first when the referee stated one (PROTOCOL 22): the
      -- narration token is the *nickname* where the fallen monster had one,
      -- and a nickname matches no pokedex row -- so a nicknamed foe fell for
      -- nothing at all. `speciesKeyFromSheet` already prefers the id and falls
      -- back to the name, which is what a pre-22 referee still gets.
      local key = speciesKeyFromSheet(self.game,
        { species = msg.species, speciesId = msg.speciesId })
      if key then
        rows[#rows + 1] = {
          kind = "exp", slot = index, species = key,
          level = msg.level, participants = msg.participants,
          -- Which of that seat's six banks it. Carried through untouched --
          -- it is a party index and needs none of the field-slot translation
          -- `slot` gets above -- but it is *not* in the same space CoopSim's
          -- is, so the row is stamped as the referee's below and `gainExp`
          -- resolves it through the uploaded sheets. Absent from an older
          -- referee's event, and absent is meaningful -- `gainExp` pays the
          -- active on a nil.
          mon = msg.mon,
          -- The referee wrote this row, so `mon` counts in the party this
          -- client uploaded rather than in the seat's. See `medPartySlot`.
          med = true,
        }
      elseif index == self.mine and not self.medExpSpeciesWarned then
        -- Only our own share is ours to pay, so only our own miss is worth a
        -- line -- and only the first, because a battle that cannot name one
        -- species usually cannot name the next either.
        self.medExpSpeciesWarned = true
        mod.log:warn("the referee named a defeated POKeMON (%s) this build "
          .. "could not match, so no EXP was awarded for it; report this with "
          .. "the species if it is a standard one",
          tostring(msg.species))
      end
    end

  elseif kind == "anim" then
    -- Play via the existing AnimPlayer path; if mapping fails `startAnim`
    -- no-ops safely. The "X used MOVE" line rides in the `msg` beside this.
    -- `amount` is shake count on SHAKE_ANIM; ball id is stashed from `item`.
    if index then
      rows[#rows + 1] = {
        kind = "anim", anim = msg.text, from = index,
        amount = msg.amount,
        -- Viewer-relative: this client's ally side faces as the player.
        attackerIsPlayer = not self:foeSide(index),
      }
    end

  elseif kind == "item" then
    -- Ball id for AnimPlayer opts on the following toss/shake chain.
    local Effects = need("BattleSim/Effects")
    local effect = msg.text and Effects.itemEffect(msg.text)
    if effect and effect.ball then
      self.medBall = msg.text
      -- ...and the same id kept past the `over` that clears medBall, for the
      -- `ball` field of the caught announcement. Our own throws only: three
      -- other people may be throwing balls at the same wild, and the catcher
      -- is the one whose ball worked.
      if self:medSlotOf(msg) == self.mine then self.caughtBall = msg.text end
    end
    say(msg.text)

  elseif kind == "switch" then
    -- Already said in the `msg` beside it, and the `send` that follows every
    -- switch -- printing `text` (a species) would say the same thing twice in
    -- worse words. Its `mon` stamp is not read here either: the referee emits
    -- the pair together and carries the same stamp on both, so the `send` above
    -- is the one place a seat's occupant changes.

  elseif kind == "turn" or kind == "over" then
    -- Neither draws anything. `turn` is the signal that the batch collected so
    -- far is complete, and `over` says the field is done -- the outcome is a
    -- separate message and is what this screen actually ends on.
    --
    -- ...except a `turn` that names a **slot**, which is not the next turn at
    -- all. It is the referee's replacement solicitation (`Battle:_openReplace`
    -- in src/BattleSim/Turn.lua): that seat fainted with a bench left and is
    -- being asked for a send-out, one event per owing seat, and nothing else
    -- resolves until every one of them has answered. So it is narrated with the
    -- **same row a host-simulated faint produces** -- `CoopSim.announceFaint`
    -- emits `choose` and this screen has always known how to draw it (see the
    -- `choose` branch in `playEvents`: the seat is marked `awaiting`, its owner
    -- gets the bench picker, and the other three get the line naming them).
    -- One replacement pause on this screen rather than two, and the wait line,
    -- the menu hold and the clear-on-send all come for free because they are
    -- the ones the co-op path already uses.
    --
    -- An older referee sends no `slot` and lands in the comment above: every
    -- `turn` is a turn, exactly as it was.
    --
    -- The trainer is read from the sim rather than the event -- the referee's
    -- solicitation carries `amount` and `slot` and no name (there is nothing on
    -- the wire for it), and the seat this screen holds is the same seat the
    -- referee is asking.
    if kind == "turn" and index then
      rows[#rows + 1] = {
        kind = "choose", slot = index, trainer = slot and slot.name,
      }
    end

  elseif kind == "chose" or kind == "unchose" or kind == "moves" then
    -- Applied in onBattleEvent (markActed / unmarkActed / medMoveList), never
    -- narrated. Reaching here is a no-op so a queued copy cannot print the
    -- trainer's name as a battle line.

  else
    -- status, stat, run, wait, reconnect: the referee's own sentence is
    -- the whole of what they contribute to a screen today. The state they
    -- describe rides on the events beside them -- a status that gated a move is
    -- followed by the `damage` that did or did not happen.
    say(msg.text)
  end
  return rows
end

function M:medSlotOf(msg)
  if msg.slot == nil then return nil end
  return (self.medSlots or {})[msg.slot]
end

function M:medFieldOf(index)
  if index == nil then return nil end
  return (self.medFields or {})[index]
end

-- Which of this slot's party the referee means by that name.
--
-- Matched through `Wire.name`, because that is what the *uploaded* species went
-- through: comparing a raw nickname against a sanitised one would miss every
-- monster whose name carries punctuation the sanitiser drops.
--
-- **A name can name two monsters, and in a coop_npc it usually does.** The
-- earlier reading of this -- "wrong only for a player who nicknamed two of their
-- team identically" -- was wrong about who hits it: an NPC trainer carrying two
-- of the same species is ordinary, and src/Coop.lua:1938 deals a trainer's team
-- alternately into the two ownerless seats, so both copies land in *one* seat and
-- every replacement send for it collides. Matching the first entry then fielded
-- the corpse the referee had just knocked down -- a monster standing up again one
-- KO later, with `slot.active` left disagreeing with the referee for the rest of
-- the fight.
--
-- So a living match wins and a fainted one is only the fallback. That is the
-- client-side mirror of the rule the referee picks by (`firstLiving`,
-- src/BattleSim/Turn.lua:405-411, and the bench search `_bestSeBench` builds on
-- it): the referee never fields a monster at 0 HP, so a living namesake is always
-- the better reading of the same word. The fallback is kept rather than returning
-- nil so a client whose HP has drifted from the referee's still draws *something*
-- for the send -- and `playEvents` refuses to field it, see the guard there.
--
-- Counting faints to track send-outs is still wrong more often and more quietly;
-- the actual cure for the residual (two *living* namesakes in one seat) is the
-- referee's own `mon` stamp, resolved ahead of this by `medSendIndex`.
function M:medPartyIndex(slot, species)
  if not (slot and type(species) == "string") then return nil end
  local data = self.game and self.game.data
  local fallback = nil
  for i, mon in ipairs(slot.party or {}) do
    local def = data and (data.pokemon or {})[mon.species]
    local name = mon.nickname
    if type(name) ~= "string" or name == "" then name = def and def.name end
    if type(name) ~= "string" or name == "" then name = mon.species end
    if Wire.name(name) == species then
      if (mon.hp or 0) > 0 then return i end
      if fallback == nil then fallback = i end
    end
  end
  return fallback
end

-- Which party position the referee *said* it fielded, when it said one.
--
-- `send` / `switch` carry `mon`: the 0-based position of the monster the referee
-- put on the field. It is the same field a mediated `exp` row already carries
-- (src/BattleSim/Turn.lua:2538, `winner.index - 1`) and it rides the wire on the
-- same sanitiser -- `Wire.battleEvent` bounds `mon` for every kind, not for `exp`
-- alone (src/Wire.lua:1706) -- so nothing on the transport had to change for it.
--
-- It is preferred over the name because it is the referee's own answer rather
-- than this screen's reconstruction of it, which closes the one case
-- `medPartyIndex` cannot read at all: two *living* monsters with the same name in
-- one seat, where the referee picked the second. A referee that predates the
-- stamp sends none, and the name is then the whole of the answer -- which is what
-- this screen did before, unchanged.
--
-- Two things it is not:
--
--   * **Not the same counting space for our own seat.** The referee counts in the
--     sheets this client uploaded, and `Mediated.snapshotMons` skips a monster it
--     cannot describe, so one skip shifts every index after it. Our own seat is
--     therefore translated sheet -> `sheet.slot` -> party position by
--     `medPartySlot`, exactly as `gainExp` translates the `mon` on a mediated
--     `exp` row. An NPC seat has no sheets on this client to translate through
--     (`npcMons` interleaves both ownerless seats into one list and the hub deals
--     it back out, src/Hub.lua:1384-1392), so its index is read straight -- and
--     the checks below are what stands in for the translation.
--   * **Not trusted blind.** Out of range, or naming a monster this screen has at
--     0 HP, means the two sides are counting differently -- an older referee, a
--     skipped sheet, a lossy stream. Either way the name is the better reading,
--     so `nil` here falls back to it rather than fielding whatever the number
--     happened to land on.
function M:medStampIndex(index, slot, mon)
  local at = tonumber(mon)
  if not (slot and at) then return nil end
  at = math.floor(at) + 1
  if at < 1 then return nil end
  if index == self.mine then at = self:medPartySlot(at) end
  local pick = at and (slot.party or {})[at]
  if not pick then return nil end
  if (pick.hp or 0) <= 0 then return nil end
  return at
end

-- The referee's stamp first, its word second.
function M:medSendIndex(index, slot, msg)
  return self:medStampIndex(index, slot, msg and msg.mon)
      or self:medPartyIndex(slot, msg and msg.text)
end

-- One thing that happened, in order.
--
-- `seq` is what makes the stream a stream, and it is read exactly as
-- src/MediatedBattle.lua reads it: a sequence already passed is a duplicate and
-- is dropped, and a jump forward is counted rather than refused. Refusing the
-- jump would leave the screen waiting on a message that is not coming; counting
-- it makes a lossy hub visible in a log while the fight -- whose state lives on
-- the referee -- carries on from what did arrive.
function M:onBattleEvent(msg)
  if not self.mediated then return false end
  if msg.battle ~= self.battleId then return false end
  if msg.seq <= self.medSeq then return false end
  if msg.seq > self.medSeq + 1 and self.medSeq > 0 then
    self.medGaps = self.medGaps + 1
  end
  self.medSeq = msg.seq

  -- A peer answered this turn. Applied now, not batched with narration: the
  -- wait line has to drop their name the moment the hub accepts the choice,
  -- and a `chose` queued until `turn` would land after the menu reopened.
  if msg.t == "chose" then
    local index = self:medSlotOf(msg)
    if index then self:markActed(index) end
    return true
  end
  if msg.t == "unchose" then
    local index = self:medSlotOf(msg)
    if index then self:unmarkActed(index) end
    if index == self.mine then
      self.pendingItem = nil
      self.pendingItemSlot = nil
    end
    return true
  end
  -- Timeout / took-too-long lines: show immediately. Batched behind `turn`, a
  -- client that left the choose menu the moment auto-pick landed (the player
  -- who stalled) never saw the explanation before the next A-mash cleared the
  -- queue -- which is exactly who the line is for.
  if msg.t == "msg" and type(msg.text) == "string"
     and (msg.text:find("ran out of time", 1, true)
          or msg.text:find("took too long", 1, true)) then
    self:say(msg.text)
    return true
  end
  if msg.t == "item" and self:medSlotOf(msg) == self.mine then
    self:confirmMediatedItem(msg.text, msg.amount)
    -- Still narrate via medRows below.
  end
  if msg.t == "moves" then
    local index = self:medSlotOf(msg)
    if index == self.mine and type(msg.moves) == "table" then
      self.medMoveList = msg.moves
    end
    return true
  end
  -- A send-out on our seat replaces the Transform/Mimic list: the new mon
  -- fights with its uploaded moves until another `moves` event lands.
  if (msg.t == "send" or msg.t == "switch") and self:medSlotOf(msg) == self.mine then
    self.medMoveList = nil
    self.medMustReplace = nil
    if self.replacing then self.replacing = nil end
  end

  for _, row in ipairs(self:medRows(msg)) do
    self.medPending[#self.medPending + 1] = row
  end
  if msg.t == "reconnect" then self.awaitingReconnect = false end
  -- The two that close a batch. Everything between them is collected, for the
  -- reason in this section's header: a menu taken away mid-decision is a turn
  -- the player cannot answer.
  if msg.t == "turn" then
    -- ------- two readings of one event, told apart by `slot`
    --
    -- WITHOUT a slot this is the ordinary choice window opening, and everything
    -- below it is what it always was. WITH one it is the referee soliciting the
    -- replacement that seat owes -- the choice window is *not* opening, and the
    -- row `medRows` just queued (`kind = "choose"`) is what asks for it.
    --
    -- `medReplaceWait` is the screen's copy of that phase, and it is set before
    -- the flush because the flush is what plays the rows: `after`, the phase the
    -- handover lands on when they run out, is decided from it (see
    -- `M:replaceHold`).
    local owed = self:medSlotOf(msg)
    self.medReplaceWait = owed
    self:medFlush()
    if owed == nil then
      -- Arm replace only after the faint/msg batch is queued: update() drains
      -- `messages` before `replacing`, so pacing is faint line → picker → send.
      if self.medMustReplace then
        local seat = self.sim and self.sim:slot(self.mine)
        local bench = seat and self:benchOf(seat) or {}
        if #bench > 0 then
          self.replacing = true
          self.switchIndex = 1
        else
          -- Empty bench: do not open a dead picker; spectating / over owns this.
          self.medMustReplace = nil
          self.replacing = nil
        end
      end
    elseif owed == self.mine then
      -- ------- and this is the arming, **once**
      --
      -- The picker is already open: the `choose` row above ran through
      -- `playEvents` inside `medFlush` and set `replacing` there, at the same
      -- point in the batch the old `medMustReplace` block armed it -- after the
      -- faint rows were queued, before `update` drains them. Re-arming here
      -- would be a second arming of the same picker off the same event, and it
      -- would reset `switchIndex` under a player who had already moved the
      -- cursor with a queued row still playing.
      --
      -- So `medMustReplace` is *retired* instead. It was the older stream's way
      -- of remembering a faint until the next turn opened, and a referee that
      -- solicits has said the same thing out loud and more precisely -- keeping
      -- both would arm the picker again on the slot-less turn that follows the
      -- send, over a seat that is no longer empty. (The `send`/`switch` clear
      -- above retires it on the ordinary path for the same reason.)
      --
      -- What is *not* delegated is the empty-bench refusal: `playEvents` arms
      -- the picker for our seat unconditionally, and a solicitation this screen
      -- cannot answer -- a party it disagrees with the referee about -- would
      -- otherwise open a picker with nothing in it and no way out.
      self.medMustReplace = nil
      local seat = self.sim and self.sim:slot(self.mine)
      local bench = seat and self:benchOf(seat) or {}
      if #bench == 0 then
        self.replacing = nil
        if seat then seat.awaiting = nil end
        self.medReplaceWait = nil
      end
    end
  elseif msg.t == "over" then
    self.medMustReplace = nil
    self.medReplaceWait = nil
    self.replacing = nil
    -- Ball opts / foe hide outlive the turn event: anims still drain from the
    -- message queue after medFlush. Cleared when the fight ends.
    self.medBall = nil
    self.foePicHidden = nil
    self:medFlush()
  end
  return true
end

-- Debit inventory + bagSheet after the hub resolved our item choice.
-- Vitamin save writeback only when amount==1 (hub applied Stat Exp).
function M:confirmMediatedItem(itemId, amount)
  local id = self.pendingItem
  if not id then return false end
  if itemId and itemId ~= id then return false end
  local seatSlot = self.pendingItemSlot
  self.pendingItem = nil
  self.pendingItemSlot = nil
  local Effects = need("BattleSim/Effects")
  local effect = Effects.itemEffect(id)
  if effect and effect.vitamin and amount == 1 then
    local partyIndex = Mediated.vitaminPartyIndex(self.game, self:mySlot(), seatSlot)
    Mediated.writebackVitamin(self.game, partyIndex, id)
  end
  if effect and effect.noConsume then
    self.itemList = nil
    return true
  end
  local inventory = self.game.save and self.game.save.inventory
  if not (inventory and (inventory[id] or 0) > 0) then return false end
  inventory[id] = inventory[id] - 1
  if inventory[id] <= 0 then inventory[id] = nil end
  if self.bagSheet and self.bagSheet[id] then
    self.bagSheet[id] = self.bagSheet[id] - 1
    if self.bagSheet[id] <= 0 then self.bagSheet[id] = nil end
  end
  -- No `owed`: hub already decremented; abandon must not refund.
  self.itemList = nil
  return true
end

function M:medFlush()
  local rows = self.medPending
  self.medPending = {}
  -- Same boundary `applyTurn` draws for a host-sim `res`: the answers that
  -- filled this batch belong to the turn that just closed. Left in place they
  -- would keep the wait line naming people who already answered, for every
  -- later turn of a refereed fight -- there is no `act` fan-out here to rewrite
  -- `acted` the way the relayed path does. Cleared even when the batch is empty
  -- so `acted` and the wait countdown do not stick across turn boundaries that
  -- carried no narration rows (damage-only turns, reconnect waits, etc.).
  self.acted = nil
  self.waitShown = 0
  -- Hub refused the pending item (never debited) or spend already landed.
  self.pendingItem = nil
  self.pendingItemSlot = nil
  if #rows == 0 then return false end
  self:playEvents(rows)
  return true
end

-- How it ended, from the only party that knows.
--
-- **No mmo.result goes out for this fight** -- see the suppression in
-- src/Coop.lua's `onBattleOver`. The four-client vote existed because no client
-- in a host-simulated battle could be believed about its own win; the referee did
-- every roll, and both hubs ignore a client's report about a battle they ran.
--
-- Read from this client's own id, because a 2-on-2 outcome names four players and
-- two of them are allies -- there is no "the other side" to reason from. Turned
-- back into a *side* so the ordinary `over` row does the rest: the victory
-- theme, the unranked note, and the trainer's parting line all hang off it, and
-- none of them should have a second implementation for a refereed fight.
function M:onBattleOutcome(msg)
  if not self.mediated then return false end
  if msg.battle ~= self.battleId then return false end
  if self.result then return false end

  local mine = self:mySlot()
  local mySide = mine and mine.side
  local result = Mediated.resultForSelf(msg, self.selfId)
  local winner = "draw"
  if result == "win" then
    winner = mySide or "draw"
  elseif result == "loss" then
    winner = (mySide == "a") and "b" or "a"
  end

  self.medPending[#self.medPending + 1] = { kind = "over", winner = winner }
  local why = MED_REASONS[msg.reason]
  if why then
    self.medPending[#self.medPending + 1] = { kind = "msg", text = why }
  end
  self:medFlush()
  -- Catcher-only grant: everyone sees Gotcha; only msg.catcher adds the mon.
  if msg.reason == "catch" then
    local catcher = msg.catcher
    if catcher ~= nil and (catcher == self.selfId
        or tostring(catcher) == tostring(self.selfId)) then
      self:grantCatch(msg)
    end
  end
  return true
end

-- Put the caught wild into this client's party (or PC). Mirrors
-- MediatedBattle:grantCatch — duplicated so CoopBattle owns the coop_wild
-- path without sharing a module with the 1v1 screen.
--
-- Host usually has wildCatchMon from the engine encounter. Partner / joiner
-- often does not; rebuild from msg.caught (Effects.caughtSheet) so a catcher
-- who never held the wild can still Party.add / Boxes.deposit.
function M:grantCatch(msg)
  local mon = self.wildCatchMon
  if not mon and msg and msg.caught then
    mon = M.monFromCaughtSheet(self.game, msg.caught)
    if not mon then
      self:say("Caught, but could not\nadd to the party.")
      return
    end
  end
  if not mon then return end
  local game = self.game
  local save = game and game.save
  if not save then return end
  -- What the naming prompt will ask about: the species record's display name,
  -- because a wild that has just been caught has no nickname yet. Same choice
  -- MediatedBattle:grantCatch makes, and the same one the engine's own catch
  -- makes (it asks about `self.enemy.name`).
  local label = M.caughtLabel(game, mon)
  -- The #DEX, the OT stamp and (on Gold) the UNOWN form, before the monster is
  -- put anywhere -- the order the engine's own capture writes them in.
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
  -- In front of the line saying where it went, which is where the engine
  -- prints it. The #DEX page that follows it there is deliberately not
  -- opened -- see MediatedBattle:grantCatch for why.
  if isNew then self:say(Gen.dexAddedText(game, label)) end
  if destination == "party" then
    self:say((mon.nickname or mon.species or "It") .. " was\nadded to the party!")
  else
    self:say((mon.nickname or mon.species or "It") .. " was\nsent to the PC!")
  end
  -- Boxed catches are named too: AddPartyMon and SendNewMonToBox both call
  -- AskName on the cart, so a full party costs the slot and not the naming.
  self:oweNickname(mon, label)
  -- The engine's own `pokemon.caught`, through MediatedBattle's announcer --
  -- shared rather than twinned, because unlike the grant itself there is
  -- nothing co-op-shaped about it, and two copies of a *published event's*
  -- payload is two ways for one contract to drift. Its header carries the
  -- reasoning for emitting an engine name at all.
  Mediated.announceCaught(self, game, mon, destination, isNew, self.caughtBall)
end

-- The species record's display name, falling back to the id.
function M.caughtLabel(game, mon)
  local data = game and game.data
  local def = type(data) == "table" and type(data.pokemon) == "table"
    and data.pokemon[mon.species] or nil
  local name = def and def.name
  if type(name) ~= "string" or name == "" then name = mon.species end
  if type(name) ~= "string" or name == "" then return "POKeMON" end
  return name
end

-- ------- the nickname the catcher is owed
--
-- MediatedBattle:oweNickname / askOwedNickname's twin, for the same reason
-- grantCatch is one: this file owns the coop_wild path outright.
--
-- Recorded on the grant and asked once the message queue has run dry, which
-- on this screen is the tick that would otherwise call `finish` and pop the
-- battle (see `update`'s "messages" branch). That gap is deliberate: the
-- grant happens while "Gotcha!" and the line saying where the monster went
-- are still queued, and a grid pushed then would have the player naming a
-- catch nobody had told them about.
function M:oweNickname(mon, label)
  if type(mon) ~= "table" then return false end
  self.owedNickname = { mon = mon, label = label }
  return true
end

-- Returns true when it took the frame, which is what holds `finish` off for
-- as long as the prompt is up. Cleared before the push, not after the answer:
-- a prompt that could not open is not owed a second try, and the fight has to
-- end either way.
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

-- ------- one turn's intent

-- A co-op action, as a mediated choice.
--
-- The three indices go from this screen's 1-based numbering to the wire's
-- zero-based one, and `target` changes meaning as well as base: a co-op action
-- names a slot 1..4 on this screen and a choice names a *field* slot. An
-- unmapped target is sent as no target at all rather than as a guess -- the
-- referee then aims at the first living foe, which is what a 1v1 does and is the
-- only honest answer for a slot the roster never described.
--
-- `move` is an index into the live move list for this seat. The referee emits
-- a `moves` event after Transform or Mimic; until then the uploaded party
-- list is the one that counts.
function M:sendMediatedChoice(action)
  if not (self.mediated and self.battleId) then return false end
  action = action or {}
  local kind = action.kind or "move"
  local fields
  if kind == "switch" or kind == CoopSim.REPLACE then
    fields = { action = "switch", slot = (action.index or 1) - 1 }
  elseif kind == "item" then
    -- `action.slot` is the co-op *field* seat (who is choosing). Party target
    -- for heals/vitamins is optional `partySlot` (0-based wire) or omitted so
    -- the referee applies to the active mon.
    fields = { action = "item", item = action.item, move = action.move }
    if action.partySlot ~= nil then fields.slot = action.partySlot end
  elseif kind == "run" then
    fields = { action = "run" }
  else
    fields = { action = "fight", move = (action.move or 1) - 1,
               target = self:medFieldOf(action.target) }
  end
  return Mediated.submitChoice(self.transport, self.battleId, fields)
end

-- The hub link came back under a mediated co-op fight that is still open.
-- Same message MediatedBattle sends for 1v1: both hubs already honour it.
function M:onTransportReady()
  if self.result or not self.mediated then return false end
  if not (self.transport and self.battleId) then return false end
  if self.reconnectSent then return false end
  self.reconnectSent = true
  self.awaitingReconnect = false
  self.transport:send(Wire.BATTLE_RECONNECT, { battle = self.battleId })
  return true
end

function M:notifyReconnect()
  return self:onTransportReady()
end

function M:onTransportLost()
  if self.result or not self.mediated then return end
  if self.awaitingReconnect then return end
  self.awaitingReconnect = true
  self.reconnectSent = false
  self:say("Connection lost.\nWaiting to reconnect...")
end

-- ------- drawing
--
-- Four monsters in 160x144, which the classic layout was never asked to hold.
-- Foes across the top, allies across the middle, and the message box in its
-- usual place at the bottom -- the two rows overlap by a few pixels, which the
-- transparent margins on a Gen 1 pic absorb.
--
-- Every glyph, box and HP bar is the engine's own (Font, HudTiles), so a
-- palette mod or an asset mod still owns the look of a co-op battle exactly as
-- it owns a wild one.

-- The field, in the 160x144 the classic layout was never asked to hold four
-- monsters in.
--
-- Foes across the top, allies across the middle, message box in its usual
-- place at the bottom. The two rows overlap by a few pixels, which the
-- transparent margins on a Gen 1 pic absorb -- and each pair is pushed to the
-- outside edges so the two monsters on a side read as two rather than as one
-- wide smear.
--
-- What the message box says right now -- one decision, drawn by drawMessage
-- and testable without a graphics device (which is why it is its own method:
-- the first version of its regression test mirrored this logic inside the
-- test and proved nothing).
--
-- An empty box is what a player stares at while three other people take their
-- turns, and it is indistinguishable from a battle that has hung -- so the box
-- says which of the two it is whenever there is no line to show. But the
-- fallback lines belong to a *finished* queue, never to the gap between two
-- lines of one that is still playing: dismissing a line leaves `shown` empty
-- for one tick before the next is popped, and a fallback drawn into that gap
-- flashed for a single frame between every pair of battle lines -- most
-- visibly the "X is choosing... (n)" countdown while a replacement pause
-- overlapped a batch, reported as "the battle kinda flickers during a moment
-- of waiting". Mid-batch, an empty frame is the original's own page gap.
function M:boxText()
  local text = self.shown
  if self.phase == "messages" then
    return text or ""
  end
  if text ~= nil and text ~= "" then return text end
  if self:spectating() then
    return "No POKeMON left!\nWatching..."
  end
  local waiting = self:waitLine()
  if waiting then return waiting end
  if self:waitingOn() then
    return "Waiting for the\nothers..."
  end
  return ""
end

function M:drawMessage()
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local text = self:boxText()
  local y = 112
  -- Cap at BOX_ROWS: say() pages longer copy, and a wait line is authored to
  -- two rows. Drawing more would paint into the border.
  local row = 0
  for line in tostring(text):gmatch("[^\n]+") do
    Font.draw(tostring(line):sub(1, BOX_COLS), 8, y)
    y = y + 16
    row = row + 1
    if row >= BOX_ROWS then break end
  end
end

-- A vertical list in the message box, cursor on `index`.
--
-- One name per row at full box width -- the old 2x2 clipped at nine glyphs and
-- put SWITCH / ITEM party picks side by side (PIKACHU | PIDGEY), which both
-- overflowed and read as a wrong choice set. Scrolls when the list is longer
-- than the visible rows.
--
-- Rows are Gen 1's own 8px tile grid (104/112/120/128). The 10px spacing that
-- shipped with the vertical rewrite put a fourth line at y=138, past the
-- bottom border at 136 -- tops of glyphs bleeding through the box edge.
function M:drawList(rows, index, title)
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  index = index or 1
  local line = 8
  local top = title and 112 or 104
  local visible = title and 3 or 4
  if title then Font.draw(tostring(title):sub(1, BOX_COLS), 8, 104) end
  local first = 1
  if index > visible then first = index - visible + 1 end
  local shown = math.min(#rows, visible)
  for i = 0, shown - 1 do
    local row = rows[first + i]
    if row then
      Font.draw(tostring(row):sub(1, BOX_COLS - 2), 16, top + i * line)
    end
  end
  if #rows > 0 then
    local cursor = index - first
    if cursor < 0 then cursor = 0 end
    if cursor >= visible then cursor = visible - 1 end
    Font.drawCode(0xED, 8, top + cursor * line)
  end
end

-- Target picker: same vertical list, titled. Kept as its own call so "Attack
-- who?" stays a distinct question from SWITCH / ITEM.
function M:drawColumn(rows, index, title)
  return self:drawList(rows, index, title)
end

-- Classic battle menu: full-width FIGHT / PKMN / ITEM / RUN. SWITCH shows
-- as the engine's two-tile PKMN mark so it does not overlap FIGHT.
function M:drawCommand()
  local Font = engine.Font
  Font.drawBox(M.CMD_BOX_TX, 12, M.CMD_BOX_TW, 6)
  love.graphics.setColor(0, 0, 0, 1)
  for i, command in ipairs(M.COMMANDS) do
    local row = math.floor((i - 1) / 2)
    local col = (i - 1) % 2
    local x = col == 0 and M.CMD_COL0_X or M.CMD_COL1_X
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
  Font.drawCode(0xED, col == 0 and M.CMD_CUR0_X or M.CMD_CUR1_X, 112 + row * 16)
end

-- The post-faint picker. Titled, because it is not the same question as the
-- SWITCH command even though it shows the same list: this one has to be
-- answered.
function M:drawReplace()
  local bench = self:benchOf(self.sim:slot(self.mine))
  if #bench == 0 then return self:drawText("No one left!") end
  local rows = {}
  for _, entry in ipairs(bench) do
    local def = (self.game.data.pokemon or {})[entry.mon.species]
    rows[#rows + 1] = (entry.mon.nickname or (def and def.name) or entry.mon.species)
  end
  self:drawList(rows, self.switchIndex or 1, "Who's next?")
end

function M:drawSwitch()
  local bench = self:benchOf(self:mySlot())
  if #bench == 0 then
    return self:drawText("There's no one\nelse to send out!")
  end
  local rows = {}
  for _, entry in ipairs(bench) do
    local def = (self.game.data.pokemon or {})[entry.mon.species]
    rows[#rows + 1] = (entry.mon.nickname or (def and def.name) or entry.mon.species)
  end
  self:drawList(rows, self.switchIndex or 1)
end

function M:drawItem()
  local items = self:usableItems()
  if #items == 0 then
    return self:drawText("You have nothing\nto use.")
  end
  local rows = {}
  for _, entry in ipairs(items) do rows[#rows + 1] = entry.name end
  self:drawList(rows, self.itemIndex or 1)
end

function M:drawItemParty()
  local rows = {}
  for _, row in ipairs(self:itemPartyRows()) do
    rows[#rows + 1] = row.label .. (row.fainted and " *" or "")
  end
  self:drawList(rows, self.switchIndex or 1)
end

function M:drawItemMove()
  local seat = self:mySlot()
  local party = (seat and seat.party) or {}
  local mon = party[self.itemPartyIndex or (seat and seat.active) or 1]
  local moves = (mon and mon.moves) or {}
  local rows = {}
  for _, move in ipairs(moves) do
    rows[#rows + 1] = tostring(move.id or "-")
  end
  self:drawList(rows, self.moveIndex or 1)
end

function M:drawText(text)
  local Font = engine.Font
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local y = 112
  local row = 0
  for _, line in ipairs(wrapBoxLines(text, BOX_COLS)) do
    Font.draw(line, 8, y)
    y = y + 16
    row = row + 1
    if row >= BOX_ROWS then break end
  end
end

-- A move name that must share the bottom strip with TYPE/PP.
--
-- Fits at native size when it can; otherwise scales on X only so a twelve-
-- glyph classic name (QUICK ATTACK) still reads inside the ten-tile pane
-- instead of painting through the TYPE column. Y stays 1:1 so row spacing
-- matches the cursor.
local function drawMoveName(Font, text, x, y, maxW)
  drawFittedText(Font, text, x, y, maxW)
end

function M:drawMoves()
  local Font = engine.Font
  local TypeChart = engine.TypeChart
  -- One bottom strip: moves on the left, TYPE/PP on the right. The classic
  -- MoveSelectionMenu's TYPE box at tile row 8 sits on top of the ally pair
  -- (y≈58) in a 2-on-2 layout and painted TYPE/NORMAL through the sprites.
  Font.drawBox(0, 12, 13, 6)
  Font.drawBox(12, 12, 8, 6)
  if Font.BORDER then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 96, 96, 8, 8)
    Font.drawCode(Font.BORDER.h, 96, 96)
  end
  love.graphics.setColor(0, 0, 0, 1)
  local moves = self:liveMoves()
  -- Nothing left anywhere: say what is actually going to happen rather than
  -- listing four moves that cannot be used. The turn still resolves -- the sim
  -- substitutes STRUGGLE whatever was chosen -- so this is the menu telling
  -- the truth about it.
  if not self:hasLivePP() then
    Font.draw("No moves left!", 16, 112)
    Font.draw("STRUGGLE", 16, 128)
    Font.drawCode(0xED, 8, 128)
    return
  end
  local index = self.moveIndex or 1
  local nameX, nameW = M.MOVE_NAME_X, M.MOVE_NAME_MAX_W
  -- Clip to the move pane so a scale quirk cannot still ink the TYPE column.
  local scx, scy, scw, sch
  local clipped = love.graphics.getScissor ~= nil
  if clipped then
    scx, scy, scw, sch = love.graphics.getScissor()
    love.graphics.setScissor(8, 104, 88, 32)
  end
  for i, moveInst in ipairs(moves) do
    local def = (self.game.data.moves or {})[moveInst.id]
    local label = (def and def.name) or moveInst.id or "-"
    drawMoveName(Font, label, nameX, M.MOVE_NAME_Y(i), nameW)
  end
  if clipped then
    if scx then love.graphics.setScissor(scx, scy, scw, sch)
    else love.graphics.setScissor() end
  end
  if #moves > 0 then
    Font.drawCode(0xED, 8, M.MOVE_NAME_Y(index))
  end
  local pick = moves[index]
  if pick then
    local def = (self.game.data.moves or {})[pick.id]
    if def then
      Font.draw("TYPE/", 104, M.MOVE_TYPE_LABEL_Y)
      local typeName = ""
      if def.type then
        if TypeChart and TypeChart.displayName then
          typeName = TypeChart.displayName(def.type) or tostring(def.type)
        else
          typeName = tostring(def.type)
        end
      end
      Font.draw(tostring(typeName):sub(1, 6), 104, M.MOVE_TYPE_NAME_Y)
      local maxPP = (def.pp or 0)
        + (pick.ppUps or 0) * math.floor((def.pp or 0) / 5)
      Font.draw(("%2d/%2d"):format(pick.pp or 0, maxPP), 104, M.MOVE_PP_Y)
    else
      Font.draw(("PP %2d"):format(pick.pp or 0), 104, M.MOVE_PP_Y)
    end
  end
end

-- "Attack who?", as a list of who.
--
-- It used to show one name at a time, under the question, with the cursor
-- nailed to it -- so the choice was invisible: nothing on screen said there was
-- a second foe. Then both, side by side through `drawList`, which showed the
-- choice but at nine glyphs a column: two foes of the same species read as one
-- truncated name printed twice.
--
-- So it is a column now (`drawColumn`), one name per row, at the full width the
-- box has. The two things being told apart are the names, and this is the
-- layout that lets them be.
function M:drawTarget()
  local targets = self.sim:targetsFor(self:mySlot())
  local rows = {}
  for _, entry in ipairs(targets) do
    rows[#rows + 1] = (entry.battler and entry.battler.name) or "?"
  end
  self:drawColumn(rows, self.targetIndex or 1, "Attack who?")
  -- Focus arrow lives on the side strip only; a second cursor on the stage
  -- pic duplicated it once the strip shipped.
end

-- Drawn behind a guard, and this is not belt-and-braces.
--
-- StateStack calls draw() directly, so an error here is not a missing frame --
-- it is the game stopping, for four people, mid-battle. The mod's own rule is
-- that a broken renderer costs a display and never the game, and a co-op
-- battle is the one screen in this mod that draws enough moving parts to earn
-- the guard. Warned once, then quietly, so a failure that repeats every frame
-- does not become the log.
function M:draw()
  local ok, err = pcall(self.drawSafe, self)
  if not ok and not self.drawFailed then
    self.drawFailed = true
    mod.log:error("the 2-on-2 screen failed to draw (%s); the battle is still "
      .. "running and can be finished blind, but report this", tostring(err))
  end
  -- Last, and outside the arena's own failure: the veil is the thing that says
  -- the battle is arriving, and a screen that could not paint its field is
  -- exactly the one that should not be revealed by a hard cut either.
  if self.entryFrame then pcall(self.drawEntry, self) end
end

-- The entry veil, painted over the finished frame.
--
-- Handed to the renderer as a whole-surface veil rather than filled into the
-- 160x144 UI canvas, which is how the engine's own palette-register effects
-- reach the screen (`Renderer.screenVeil`, set by the battle transition's
-- flash and by the fade in from white after a battle). Two reasons it has to
-- be that one: the arena is a widescreen canvas whose size is not 160x144
-- (`uiSize`), and at any zoom above 1x a veil painted into the letterbox
-- leaves the surrounding window untouched -- which reads as the fade happening
-- inside a window rather than to the screen.
--
-- The field is re-declared by its drawer every frame (the renderer clears it
-- at the top of each one), so a popped screen can never leave a sticky veil
-- behind -- which is also why this is a per-frame write and not a flag.
--
-- No renderer -- a headless run, a build drawing straight to the display --
-- falls back to a rectangle over this screen's own canvas, exactly as the
-- engine's transitions do.
function M:drawEntry()
  local a = M.entryAlpha(self.entryFrame or 0)
  if a <= 0 then return end
  local renderer = self.game and self.game.renderer
  if renderer then
    renderer.screenVeil = { 0, a }
    return
  end
  if not love then return end
  local w, h = 160, 144
  local okSize, uw, uh = pcall(self.uiSize, self)
  if okSize and type(uw) == "number" and type(uh) == "number" then
    w, h = uw, uh
  end
  love.graphics.setColor(0, 0, 0, a)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- how the arena reaches the screen, per generation
--
-- Twin of `MediatedBattle:drawWidescreen`, and that function's header carries
-- the full note. In one line: Gen 1 widens the render surface for a state that
-- asks (`uiSize` / `wantsFillScale`), Gold has no such seam and instead lets a
-- state paint the whole window in window units via `drawsWidescreen()` /
-- `drawWidescreen(w, h)` -- the same pair Gold's own battle screen uses. Same
-- theatre, one different delivery function.
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

function M:drawsWidescreen()
  if self:generation() ~= 2 then return false end
  return self:usesBattlefield()
end

function M:drawWidescreen(winW, winH)
  local G = love.graphics
  winW = tonumber(winW) or 0
  winH = tonumber(winH) or 0
  if winW <= 0 or winH <= 0 then return end

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
  -- Game2 blits next off its own grid.
  local ok, err = pcall(self.drawBattlefieldSafe, self)
  G.pop()
  G.setColor(1, 1, 1, 1)

  if not ok and not self.drawFailed then
    self.drawFailed = true
    mod.log:error("the co-op battle arena failed to draw on this generation "
      .. "(%s); the fight is still running and can be finished blind, but "
      .. "report this", tostring(err))
  end
end

function M:drawSafe()
  local eng = engine
  if not eng then return end
  -- Already painted edge to edge by `drawWidescreen`; see its header.
  if self:drawsWidescreen() then return end
  if self:usesBattlefield() then
    return self:drawBattlefieldSafe()
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  self:drawField()
  -- Trainer is painted inside drawField (under the panels) while the opening
  -- lines run; drawing it here again put the sprite over ally readouts.
  self:drawAnim()
  self:drawMenusClassic()
  love.graphics.setColor(1, 1, 1, 1)
end

return M
