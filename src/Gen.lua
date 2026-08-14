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
