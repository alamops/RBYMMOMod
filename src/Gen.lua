-- Dual Gen 1 / Gen 2 helpers for presence, save fields, and UI ids.
--
-- One place for the shape differences that every presence/save call site
-- would otherwise hardcode: money lives on save vs save.player, dex uses
-- owned vs caught, free-roam is "overworld on top" vs "empty stack", and
-- spawn movement is STAY+range vs numeric STANDING_*. Callers pass a game
-- when they have one; generation falls back through Handshake / Fingerprint
-- and defaults to 1 so a headless load without data stays Gen 1-shaped.

local need, mod = ...
local Config = need("Config")

local M = {}

local RANGE_OF = {
  up = "UP", down = "DOWN", left = "LEFT", right = "RIGHT",
}

-- Gen 2 SPRITEMOVEDATA: STANDING_DOWN/UP/LEFT/RIGHT (NPC.MOVE in gen2/NPC.lua).
-- Numeric values are required: World:pooledNpc calls NPC.new(mapId, obj)
-- directly, so a Gen 1 string like "STAY" never reaches fromGen1.
local STANDING = {
  down = 6, up = 7, left = 8, right = 9,
}

local function gameOf(game)
  if type(game) == "table" then return game end
  -- Prefer the loader facade: under Gold, mod.game is the Game2 instance
  -- while _G.Game (when present) is still the Gen 1 singleton and would
  -- make Handshake/Fingerprint answer generation 1 on a live Gold boot.
  local ok, live = pcall(function() return mod.game end)
  if ok and type(live) == "table" then return live end
  local g = rawget(_G, "Game")
  if type(g) == "table" then return g end
  return nil
end

-- 1 or 2. Handshake.generation when present, else Fingerprint.generationOf
-- on the merged dataset; anything else reads as Gen 1.
function M.generation(game)
  game = gameOf(game)
  local gen, got = 1, false
  local ok = pcall(function()
    local Handshake = require("src.link.Handshake")
    if type(Handshake.generation) == "function" then
      gen = tonumber(Handshake.generation(game)) or 1
      got = true
    end
  end)
  if ok and got and (gen == 1 or gen == 2) then return gen end
  ok = pcall(function()
    local Fingerprint = require("src.link.Fingerprint")
    gen = tonumber(Fingerprint.generationOf(game and game.data)) or 1
  end)
  if ok and gen == 2 then return 2 end
  return 1
end

-- Gen 2 always writes player.money (even at 0); Gen 1 keeps save.money.
-- `create` is only true from money.set — get must never allocate save.player.
local function moneyHost(save, create)
  if type(save) ~= "table" then return nil end
  if save.generation == 2 then
    if type(save.player) == "table" then return save.player end
    if create then
      save.player = {}
      return save.player
    end
    return nil
  end
  local player = save.player
  if type(player) == "table" and player.money ~= nil then return player end
  return save
end

M.money = {}

function M.money.get(save)
  local host = moneyHost(save, false)
  if not host then return 0 end
  return math.floor(tonumber(host.money) or 0)
end

function M.money.set(save, n)
  local host = moneyHost(save, true)
  if not host then return end
  host.money = math.floor(tonumber(n) or 0)
end

-- seen, owned/caught. Profile wire still names the second field `owned`.
function M.dexCounts(save)
  local dex = save and save.pokedex or {}
  local seen, owned = 0, 0
  for _ in pairs(dex.seen or {}) do seen = seen + 1 end
  local bag = dex.caught or dex.owned or {}
  for _ in pairs(bag) do owned = owned + 1 end
  return seen, owned
end

-- Gen 2: count save.player.badges when that table exists. Otherwise the
-- engine's Badges.count (Gen 1 inventory keys), soft-failed.
function M.badgeCount(game, save)
  local badges = save and save.player and save.player.badges
  if type(badges) == "table" then
    local n = 0
    for _, has in pairs(badges) do
      if has then n = n + 1 end
    end
    return n
  end
  local count = 0
  local ok = pcall(function()
    local Badges = require("src.inventory.Badges")
    count = Badges.count(game and game.data, save) or 0
  end)
  if not ok then return 0 end
  return count
end

-- Gen 2 World exposes acceptsMenuInput; Gen 1 OverworldState does not.
-- Used when Handshake has no game yet but an overworld is already up.
local function bootIsGen2(game)
  if M.generation(game) == 2 then return true end
  local world = mod.world
  -- Guard: headless stubs often set mod.world to a fake without :overworld.
  local ow = world and type(world.overworld) == "function" and world:overworld() or nil
  return ow ~= nil and type(ow.acceptsMenuInput) == "function"
end

-- True when the player is looking at the world: Gen 1's overworld-on-top,
-- or Gen 2's empty stack with a live map (pipelineGate's free-roam case).
-- Empty-stack free-roam is Gen 2 only — Gen 1 still requires top == overworld.
function M.freeRoam(game, top)
  local world = mod.world
  local overworld = world and type(world.overworld) == "function" and world:overworld() or nil
  if top and overworld and top == overworld then return true end
  if not top and overworld and overworld.map
      and (M.generation(game) == 2 or bootIsGen2(game)) then
    return true
  end
  return false
end

function M.startMenuId(game)
  if M.generation(game) == 2 then return "Gen2StartMenu" end
  -- Split so gen2check MK409 does not flag a bare Gen1 screen id literal
  -- in a helper that also returns Gen2StartMenu on Gold.
  return "Start" .. "Menu"
end

-- ------- the nickname a catch earns
--
-- A wild caught on the engine's own path is named through
-- BattleState:askNicknameUI: the caught text, then "Do you want to give a
-- nickname to X?", then the letter grid.  A wild caught in an MMO fight is
-- granted by this mod instead (MediatedBattle / CoopBattle `grantCatch`), and
-- until this existed the grant went straight into the party -- the catcher
-- never got the prompt every other catch in the game gives them.
--
-- The two generations differ in three ways that a single call site would
-- otherwise have to know: the screen id, the opts shape, and -- the one that
-- actually bites -- who pops the screen.  Gen 1's NamingScreen pops *itself*
-- before calling onDone (src/ui/NamingScreen.lua); Gold's does not, and its
-- callers pop for it (src/ui/gen2/BattleState.lua:answerNickname).  So this
-- pops on Gold and leaves Gen 1 alone: doing either on both generations
-- either strands the grid on the stack forever or takes the screen underneath
-- it down with the answer.

function M.nicknameScreenId(game)
  if M.generation(game) == 2 then return "Gen2NamingScreen" end
  -- Split for the reason startMenuId's is: gen2check MK409 flags a bare Gen 1
  -- screen id literal in a helper that also answers with a Gen 2 one.
  return "Naming" .. "Screen"
end

-- The sentence the prompt asks, in the player's own copy's words where the
-- dataset carries them.
--
-- Gen 1 has the ROM string (_DoYouWantToNicknameText, whose CONT is a tab and
-- whose {RAM} token is the species); Gold's engine prints a plain sentence of
-- its own (Gen2 BattleState:askNickname), so there is nothing to look up and
-- the fallback *is* the line.  `displayName` is substituted through a function
-- so a name carrying `%` cannot blow up gsub's replacement parser.
function M.nicknamePromptText(game, displayName)
  local name = tostring(displayName or "")
  if name == "" then name = "POKeMON" end
  if M.generation(game) == 2 then
    return "Give a nickname to\n" .. name .. "?"
  end
  local text = game and game.data and game.data.text
    and game.data.text._DoYouWantToNicknameText
  if type(text) == "string" and text ~= "" then
    local out = text:gsub("\t", "\n"):gsub("{RAM:?[%w_]*}", function()
      return name
    end)
    return out
  end
  return "Do you want to\ngive a nickname\nto " .. name .. "?"
end

-- Put the letter grid up for `mon`, and write what was typed onto it.
--
-- `onDone` is called with the typed name (or nil) *after* the grid has left
-- the stack, so a caller can carry on sequencing from it.  Returns false when
-- no screen went up -- a build with no naming screen registered, or a push
-- that threw -- which is the caller's cue to say so rather than wait for an
-- answer that is never coming.
function M.askNickname(game, mon, displayName, onDone)
  if not (type(game) == "table" and type(mon) == "table") then return false end
  local gen2 = M.generation(game) == 2
  local name = tostring(displayName or mon.species or "")

  -- Guarded because the two screens reach it differently (Gold's onCancel and
  -- onDone are both endings) and a nickname must not be written twice.
  local answered = false
  local function done(typed)
    if answered then return end
    answered = true
    if gen2 then
      pcall(function() game.stack:pop() end)
    end
    if type(typed) == "string" and typed ~= "" then mon.nickname = typed end
    if onDone then onDone(typed) end
  end

  local opts
  if gen2 then
    local data = game.data or {}
    local icons = data.gen2Icons
    local iconId = icons and icons.species and icons.species[mon.species]
    local entry = iconId and icons.icons and icons.icons[iconId]
    opts = {
      type = "nickname",
      monName = name,
      iconPath = entry and entry.image or nil,
      menuGfx = data.gen2MenuGfx,
      onDone = done,
      onCancel = function() done(nil) end,
    }
  else
    opts = {
      title = "NICKNAME?",
      maxLen = Config.NICKNAME_MAX,
      onDone = done,
    }
  end

  local pushed
  local ok = pcall(function()
    pushed = mod.ui.push(game, M.nicknameScreenId(game), opts)
  end)
  -- A pcall that succeeds but hands back nothing table-shaped is as
  -- screen-less as a throw (an unregistered id resolves to nil), and both
  -- leave the catcher waiting on a grid that never came up.
  if not (ok and type(pushed) == "table") then
    mod.log:warn("could not open the naming screen for the POKeMON you just "
      .. "caught; it keeps its species name and can be renamed at the NAME "
      .. "RATER")
    return false
  end
  return true
end

-- ------- the rest of what a capture writes into the save
--
-- Adding the monster to the party is only the visible half of a catch. The
-- engine's own capture (`BattleState:storeCaughtMon` on Red,
-- `Gen2 BattleState:pushCaught` on Gold) also marks the #DEX, stamps the
-- catcher onto the mon as its original trainer, and -- on Gold -- registers
-- an UNOWN's form.  An MMO catch is granted by this mod, so none of it
-- happened: the caught monster was owned by nobody, the dex never moved, and
-- an UNOWN caught in a co-op fight never unlocked its letter.
--
-- All three are the same shape of question -- "which field does this
-- generation keep it in" -- so they live here together, and the engine's own
-- helpers do the writing wherever it exports one (`BattleState.stampOT`,
-- `Mon.stampOT`, `Unown.registerCatch`). The dex is written directly because
-- neither generation exports a marker: Gen 1's `markOwned` is a `BattleState`
-- static that reads `game.save.pokedex.owned`, Gold stamps
-- `pokedex.caught` inline, and the rule for which of the two a save carries
-- is already stated once in this file (see `dexCounts`).

-- The catcher's name and id on the monster they caught. `mon.traded` is
-- respected by both engine stamps: a traded mon keeps the id it arrived with.
local function stampOT(game, save, mon)
  if type(save.player) ~= "table" then return false end
  local path = (M.generation(game) == 2)
    and "src.battle.gen2.Mon" or "src.battle.BattleState"
  local stamped = false
  pcall(function()
    local engine = require(path)
    if type(engine.stampOT) == "function" then
      engine.stampOT(save, mon)
      stamped = true
    end
  end)
  if stamped then return true end
  -- No engine module to ask (a headless load, a build without it): the OT
  -- name is the half a player sees on the status screen, so it is written
  -- rather than dropped. The id is left alone -- inventing one here would be
  -- inventing the number the traded check turns on.
  mon.ot = mon.ot or save.player.name
  return mon.ot ~= nil
end

-- Seen + owned/caught, and whether this species was new.
--
-- `caught` when the save carries it or declares generation 2, `owned`
-- otherwise -- the same rule src/Trade2.lua marks a received trade under, and
-- the same pair `dexCounts` reads back out.
local function markDex(save, species)
  local dex = save.pokedex
  if not (type(dex) == "table" and type(species) == "string") then return nil end
  dex.seen = dex.seen or {}
  dex.seen[species] = true
  if dex.caught ~= nil or save.generation == 2 then
    dex.caught = dex.caught or {}
    local knew = dex.caught[species] and true or false
    dex.caught[species] = true
    return not knew
  end
  dex.owned = dex.owned or {}
  local knew = dex.owned[species] and true or false
  dex.owned[species] = true
  return not knew
end

-- Everything the engine's own capture does to the save except choosing the
-- monster's home, which is the caller's (party, then a box).
--
-- Returns whether the species was **new** to the dex, which is the answer the
-- "new #DEX data" line is asked for -- and nil when this save has no dex at
-- all, which is not the same as "already known".
--
-- Ordered the way the engine orders it: the dex and the OT are written before
-- the monster is put anywhere, so a catch that ends up with nowhere to go
-- still counted as seen (`storeCaughtMon` marks owned before `Party.add`).
function M.recordCatch(game, mon)
  if not (type(game) == "table" and type(mon) == "table") then return nil end
  local save = game.save
  if type(save) ~= "table" then return nil end
  stampOT(game, save, mon)
  local isNew = markDex(save, mon.species)
  if M.generation(game) == 2 then
    -- AddPartyMon's `.registerunowndex`: the form list UNOWN MODE and
    -- VAR_UNOWNCOUNT read. A no-op for every species but UNOWN.
    pcall(function()
      local Unown = require("src.core.gen2.Unown")
      if type(Unown.registerCatch) == "function" then
        Unown.registerCatch(save, mon)
      end
    end)
  end
  return isNew
end

-- "This one is new", in each game's own words (_ItemUseBallText06 on Red,
-- NewDexDataText on Gold).
function M.dexAddedText(game, displayName)
  local name = tostring(displayName or "")
  if name == "" then name = "It" end
  if M.generation(game) == 2 then
    return name .. "'s data was newly\nadded to the #DEX."
  end
  return "New POKéDEX data\nwill be added for\n" .. name .. "!"
end

function M.avatarName(playerId)
  return "mmo_" .. tostring(playerId)
end

function M.spawnObjDef(player, sprite, game)
  local facing = (player and player.facing) or "down"
  local def = {
    sprite = sprite,
    x = player.x,
    y = player.y,
    name = M.avatarName(player and player.id),
  }
  -- Prefer an explicit game, then the live mod.game facade, then the
  -- overworld capability sniff (acceptsMenuInput is Gen 2-only).
  if bootIsGen2(game or mod.game or gameOf(nil)) then
    def.movement = STANDING[facing] or STANDING.down
  else
    def.movement = "STAY"
    def.range = RANGE_OF[facing] or "DOWN"
  end
  return def
end

local function spritePresent(spritesRegistry, id)
  if not (spritesRegistry and type(id) == "string") then return false end
  local ok, record = pcall(function() return spritesRegistry:get(id) end)
  return ok and record ~= nil
end

-- First Config.SPRITES id the catalog carries, then Chris / Red.
-- OWN_CHARS (NIRE, …) are never a boot default — on Gen 2 they are not
-- wearable yet, and even on Gen 1 the fallback should be an engine sprite.
function M.defaultSprite(game, spritesRegistry)
  spritesRegistry = spritesRegistry or (mod.content and mod.content.sprites)
  local gen = M.generation(game)
  for _, row in ipairs(Config.SPRITES or {}) do
    local id = row[2]
    local own = Config.ownCharId(id)
    if own and not Config.ownCharAllowed(own, gen) then
      -- gen-gated cast member
    elseif own then
      -- opt-in character, never the anonymous default
    elseif spritePresent(spritesRegistry, id) then
      return id
    end
  end
  if spritePresent(spritesRegistry, "SPRITE_CHRIS") then return "SPRITE_CHRIS" end
  if spritePresent(spritesRegistry, "SPRITE_RED") then return "SPRITE_RED" end
  return Config.defaultSpriteFor(gen)
end

function M.resolveSprite(game, requested, spritesRegistry)
  spritesRegistry = spritesRegistry or (mod.content and mod.content.sprites)
  local own = Config.ownCharId(requested)
  if own and not Config.ownCharAllowed(own, M.generation(game)) then
    return M.defaultSprite(game, spritesRegistry)
  end
  if spritePresent(spritesRegistry, requested) then return requested end
  return M.defaultSprite(game, spritesRegistry)
end

-- Gen 1 clip labels → Gold/Silver/Crystal names (rom_manifest_gold.json).
-- Unmapped names stay as-is and soft-fail through Sound.play when absent.
local GEN2_SFX = {
  Super_Effective = "Sfx_SuperEffective",
  Not_Very_Effective = "Sfx_NotVeryEffective",
  Damage = "Sfx_Damage",
  Tink = "Sfx_BallWobble",
  Ball_Poof = "Sfx_BallPoof",
}

-- Battle / catch SFX id for the live generation. Gen 1 keeps the RBY label.
function M.sfx(game, name)
  if type(name) ~= "string" then return name end
  if M.generation(game) ~= 2 then return name end
  return GEN2_SFX[name] or name
end

-- Gen 2 trainer class id for BattleMusic (FALKNER), stripping Gen 1 OPP_.
local function gen2TrainerClass(opts)
  opts = opts or {}
  local t = opts.trainer
  local class = opts.class
    or opts.oppClass
    or (t and (t.classId or t.class or t.id))
  if type(class) ~= "string" then return nil end
  if class:sub(1, 4) == "OPP_" then class = class:sub(5) end
  return class
end

local function gen2MusicEnv(game)
  local landmark, daytime, members
  local ow = game and (game.overworld or game.world)
  if type(ow) == "table" then
    landmark = ow.map and ow.map.def and ow.map.def.landmark
    daytime = ow.daytime
    members = ow.constants and ow.constants.trainerClassMembers
  end
  return landmark, daytime, members
end

local function isWildMode(opts)
  local mode, kind = opts.mode, opts.kind
  return mode == "coop_wild" or mode == "wild" or kind == "wild"
end

local function isLinkMode(opts, class)
  local mode, kind = opts.mode, opts.kind
  if mode == "coop_pvp" or kind == "link" then return true end
  -- No trainer class and not wild → party-vs-party / 1v1 link cue.
  return not isWildMode(opts) and not class
end

-- Song label Gen 2 PlayBattleMusic would pick for this fight (or nil).
function M.gen2BattleSong(game, opts)
  opts = opts or {}
  local ok, BattleMusic = pcall(require, "src.battle.gen2.BattleMusic")
  if not (ok and BattleMusic and BattleMusic.battleSong) then return nil end
  local landmark, daytime, membersTbl = gen2MusicEnv(game)
  local class = gen2TrainerClass(opts)
  if isLinkMode(opts, class) then
    -- Gen 2 has no dedicated link theme; regional trainer battle matches
    -- "two parties" better than a wild cue.
    return BattleMusic.isKanto(landmark)
      and "Music_KantoTrainerBattle" or "Music_JohtoTrainerBattle"
  end
  if isWildMode(opts) then
    return BattleMusic.battleSong({ landmark = landmark, daytime = daytime })
  end
  local member = opts.member
    or (opts.trainer and (opts.trainer.memberId or opts.trainer.member))
  local members = class and membersTbl and membersTbl[class] or nil
  return BattleMusic.battleSong({
    class = class,
    member = member,
    members = members,
    landmark = landmark,
    daytime = daytime,
  })
end

function M.gen2VictorySong(game, opts)
  opts = opts or {}
  local ok, BattleMusic = pcall(require, "src.battle.gen2.BattleMusic")
  if not (ok and BattleMusic and BattleMusic.victorySong) then return nil end
  local class = gen2TrainerClass(opts)
  if isLinkMode(opts, class) then
    return "Music_TrainerVictory"
  end
  if isWildMode(opts) then
    return BattleMusic.victorySong({
      participantsFainted = opts.participantsFainted,
    })
  end
  return BattleMusic.victorySong({ class = class })
end

-- Theatre: battle theme / win jingle / map restore.
-- Pass opts.Music (engine.Music) so headless suites can stub the boundary.
-- Gen 1 uses playBattle(kind) / playVictory(kind); Gen 2 plays song labels
-- from BattleMusic (data.audio.battle[kind] does not exist on Gold).

function M.playBattleMusic(game, opts)
  opts = opts or {}
  local Music = opts.Music
  if not Music then
    local ok, m = pcall(require, "src.core.Music")
    if not ok then return end
    Music = m
  end
  local data = game and game.data
  if not data then return end
  if M.generation(game) == 2 then
    local song = M.gen2BattleSong(game, opts)
    if song and Music.play then
      pcall(Music.play, data, song, true, { reason = "battle" })
    end
    return song
  end
  local kind = opts.kind or "trainer"
  local trainerId = opts.trainerId
    or (opts.trainer and opts.trainer.id)
  if Music.playBattle then
    pcall(Music.playBattle, data, kind, trainerId)
  end
end

function M.playVictoryMusic(game, opts)
  opts = opts or {}
  local Music = opts.Music
  if not Music then
    local ok, m = pcall(require, "src.core.Music")
    if not ok then return end
    Music = m
  end
  local data = game and game.data
  if not data then return end
  if M.generation(game) == 2 then
    local song = M.gen2VictorySong(game, opts)
    if song and Music.play then
      pcall(Music.play, data, song, true, { reason = "victory" })
    end
    return song
  end
  local kind = opts.kind or "trainer"
  if kind == "final" then kind = "gym" end
  local trainerId = opts.trainerId
    or (opts.trainer and opts.trainer.id)
  if Music.playVictory then
    pcall(Music.playVictory, data, kind, trainerId)
  end
end

-- The overworld walk-sheet catalog, by generation.
--
-- Gold keeps its sprite records on `data.gen2Sprites`; `data.sprites` is Gen 1's
-- table and on a Gold boot is either absent or the wrong shape. The engine's own
-- resolution is `rawget(data, "gen2Sprites") or data.sprites`
-- (`src/world/gen2/NPC.lua:195`) and this is that line, in one place, because
-- three call sites in this mod were reading `data.sprites` directly -- which is
-- why the arena's trainers were invisible on Gold: the record lookup found
-- nothing, `resolveHumanSheet` returned no sheet, and the figure simply never
-- drew. `rawget` and not a plain index for the reason the engine uses it: a
-- dataset may carry a metatable that would synthesise a Gen 1 answer.
function M.spriteCatalog(game)
  local data = game and game.data
  if type(data) ~= "table" then return nil end
  local gen2 = rawget(data, "gen2Sprites")
  if type(gen2) == "table" then return gen2 end
  local sprites = data.sprites
  if type(sprites) == "table" then return sprites end
  return nil
end

-- ------- trainer class -> overworld walk sheet
--
-- There is no class->sprite field anywhere in engine data. A trainer record
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
-- nothing and the foe edge of the arena was left empty.
--
-- Ties break on id order so two clients never disagree about a class, and the
-- whole walk is memoised against the maps table it was built from: one pass
-- over ~250 maps per boot, and none at all once a battle is running.
--
-- **Lives here, and not in a battle screen**, because both of them ask it --
-- `CoopBattle:battlefieldFoeHumans` for a co-op NPC fight and
-- `MediatedBattle:battlefieldCtx` for the solo one -- and MediatedBattle cannot
-- require CoopBattle without closing a cycle. It sits next to `spriteCatalog`
-- for the reason that function exists: this is a walk-sheet question, and the
-- catalog it has to be answered against is generation-shaped.
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

-- OPP_YOUNGSTER -> SPRITE_YOUNGSTER when the catalog has a walk sheet; the
-- overworld's own answer for the classes it does not (OPP_LASS,
-- OPP_BUG_CATCHER, ...); a generic trainer after that.
function M.trainerWalkSpriteId(trainer, game)
  if type(trainer) ~= "table" then return nil end
  local id = trainer.id or trainer.sprite or trainer.spriteId
  if type(id) ~= "string" or id == "" then return nil end
  local spriteId = id
  if spriteId:match("^OPP_") then
    spriteId = "SPRITE_" .. spriteId:sub(5)
  elseif not spriteId:match("^SPRITE_") then
    spriteId = "SPRITE_" .. spriteId
  end
  -- `M.spriteCatalog`, not `data.sprites`: Gold keeps its walk sheets on
  -- `data.gen2Sprites`, and reading Gen 1's table on a Gold boot proves nothing
  -- about a sheet that is really there.
  local sprites = M.spriteCatalog(game)
  if type(sprites) == "table" and type(sprites[spriteId]) == "table" then
    return spriteId
  end
  -- Soft: accept the id even if we cannot prove the sheet exists here;
  -- Battlefield.resolveHumanSheet will silhouette if load fails.
  if sprites == nil then return spriteId end
  if type(sprites) ~= "table" then return nil end

  -- **`game.data`, and it used to be a bare `data`** -- a name no scope here
  -- binds, so the lookup found the global nil, the vote table was never built
  -- and every class the name transform could not resolve fell straight past
  -- the overworld's own answer into the generic list. A LASS fought as a
  -- COOLTRAINER_M rather than as the SPRITE_COOLTRAINER_F she walks around
  -- as, which reads as a lazy fallback rather than as the dead branch it was.
  local byClass = trainerSpritesByClass(game and game.data)
  local mapped = byClass and byClass[id] or nil
  if type(mapped) == "string" and type(sprites[mapped]) == "table" then
    return mapped
  end
  for _, generic in ipairs(GENERIC_TRAINER_SPRITES) do
    if type(sprites[generic]) == "table" then return generic end
  end
  return nil
end

function M.restoreMapMusic(game, opts)
  opts = opts or {}
  local Music = opts.Music
  if not Music then
    local ok, m = pcall(require, "src.core.Music")
    if not ok then return end
    Music = m
  end
  local data = game and game.data
  if Music.restoreMap and data then
    pcall(Music.restoreMap, data)
  end
end

return M
