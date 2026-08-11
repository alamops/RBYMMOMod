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
local function moneyHost(save)
  if type(save) ~= "table" then return nil end
  if save.generation == 2 then
    save.player = save.player or {}
    return save.player
  end
  local player = save.player
  if type(player) == "table" and player.money ~= nil then return player end
  return save
end

M.money = {}

function M.money.get(save)
  local host = moneyHost(save)
  if not host then return 0 end
  return math.floor(tonumber(host.money) or 0)
end

function M.money.set(save, n)
  local host = moneyHost(save)
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

-- True when the player is looking at the world: Gen 1's overworld-on-top,
-- or Gen 2's empty stack with a live map (pipelineGate's free-roam case).
function M.freeRoam(game, top)
  local overworld = mod.world and mod.world:overworld()
  if top and overworld and top == overworld then return true end
  if not top and overworld and overworld.map then return true end
  return false
end

function M.startMenuId(game)
  if M.generation(game) == 2 then return "Gen2StartMenu" end
  return "StartMenu"
end

function M.avatarName(playerId)
  return "mmo_" .. tostring(playerId)
end

-- Gen 2 World exposes acceptsMenuInput; Gen 1 OverworldState does not.
-- Used when Handshake has no game yet but an overworld is already up.
local function bootIsGen2(game)
  if M.generation(game) == 2 then return true end
  local ow = mod.world and mod.world:overworld()
  return ow ~= nil and type(ow.acceptsMenuInput) == "function"
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
function M.defaultSprite(game, spritesRegistry)
  spritesRegistry = spritesRegistry or (mod.content and mod.content.sprites)
  for _, row in ipairs(Config.SPRITES or {}) do
    local id = row[2]
    if spritePresent(spritesRegistry, id) then return id end
  end
  if spritePresent(spritesRegistry, "SPRITE_CHRIS") then return "SPRITE_CHRIS" end
  if spritePresent(spritesRegistry, "SPRITE_RED") then return "SPRITE_RED" end
  return Config.DEFAULT_SPRITE
end

function M.resolveSprite(game, requested, spritesRegistry)
  spritesRegistry = spritesRegistry or (mod.content and mod.content.sprites)
  if spritePresent(spritesRegistry, requested) then return requested end
  return M.defaultSprite(game, spritesRegistry)
end

return M
