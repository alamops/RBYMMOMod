-- The characters this mod brings of its own.
--
-- Everywhere else this mod treats the sprite catalog as read-only: Chars
-- derives the wearable list from whatever the ROM and other mods put there,
-- and Avatars falls back to RED for anything a player's copy does not carry.
-- This file is the one place that writes into it, and it writes the same
-- shape the engine's own records have -- `image`, `frames`, `walker` -- so
-- everything downstream picks the new characters up without knowing they
-- came from here. The CHARACTER screen lists them because Chars.list walks
-- the catalog; a remote player wears one because Avatars looks the id up in
-- the catalog; the trainer card draws one because Chars.portrait crops
-- frame 0 out of `image`. Nothing had to be taught about them.
--
-- What could not come for free is the rest of the character. The overworld
-- sheet is who *other* players see, and it is the whole of a wearable
-- character as far as the catalog is concerned -- but the game also draws
-- you from three pics the catalog knows nothing about: the battle back pic,
-- the trainer card, and Oak's intro. Those come from field.playerPics, and
-- the engine offers exactly one seam over them, the `player.sprite` hook, so
-- that is what Client wraps and this file answers.
--
-- The bicycle is a fourth of those, and the one with no seam at all: the
-- ride is a whole second overworld sheet (field.playerSprites.bike), built
-- into the player object at Player.new and never asked about again. So it
-- is not registered and not hooked -- M.bikeDef hands out the record and
-- Client.applyLook puts a renderer for it on the live player, next to the
-- walking one it already swaps there.
--
-- Every failure here is a warning and a character that is simply not
-- offered. A sprite that would not register must not take the multiplayer
-- down with it, and Chars.resolve already turns a character this copy does
-- not carry into RED -- so a broken install degrades to the vanilla cast
-- rather than to a game that will not start.
--
-- ------- Gen 3
--
-- Two things change on FireRed, LeafGreen and Emerald.
--
-- The cast is not registered at all.  The sprites and battle_sprite_scales
-- registries have no Gen 3 target (the loader drops every write to them with
-- a warning), and NIRE is a Gen 1-only character anyway (Config.OWN_CHARS
-- `gens`), so a row this boot may not wear is skipped before it is written --
-- which is also what keeps a Gen 3 load free of those two warnings.
--
-- And wearing a character is a different operation.  Nothing on a Gen 3
-- boot is a SpriteRenderer on a player entity (Client.applyLook's lever), and
-- the player.sprite hook never fires there.  The player is drawn from one
-- number a frame -- src/core/game3/ow_sprites.lua OwSprites.playerGraphicsId,
-- which picks the walking, bike, surf, fishing or field-move graphic for the
-- avatar's state -- so M.installLook3 wraps that one function: the engine's
-- answer is kept whenever it is anything but the plain walking graphic, and
-- the walking graphic is swapped for the chosen look.  Bike, surf and fishing
-- stay the cart's own, because the looks this mod offers have no such sheets.
-- It is an engine_internals reach-around (docs/upstream/gen3-spawn-npc.md
-- asks upstream for a player.sprite seam on game3), so the original is kept
-- on the module and put back by M.restoreLook3.

local need, mod = ...
local Config = need("Config")
local Gen = need("Gen")
local Gen3 = need("Gen3")
local Chars = need("Chars")

local M = {}

-- id -> the Config.OWN_CHARS row, populated only by a registration that
-- actually landed. Anything not in here is not a character this copy has,
-- which is the same thing M.pic and Chars.available both need to know.
local registered = {}
local done = false

local function assetPath(char, file)
  local assets = mod.assets
  if not (assets and assets.path) then return nil end
  local ok, path = pcall(function()
    return assets:path(char.dir .. "/" .. file)
  end)
  if not (ok and type(path) == "string" and path ~= "") then return nil end
  return path
end

-- "SPRITE_NIRE_HOOD" -> "rby_mmo_nire_hood_back", the id its back pic's
-- scale is filed under. battle_sprite_scales is a flat namespace shared with
-- every other mod, so the mod id leads -- two mods that both rescale a back
-- pic must not be able to collide on a name like "nire_back".
local function scaleId(char)
  return ("%s_%s_back"):format(Config.MOD_ID,
    char.id:gsub("^SPRITE_", ""):lower())
end

-- ------- installation

-- Registers each character, and the one number its back pic needs.
--
-- Runs before anything reads the catalog, and is idempotent: a second call
-- would be a duplicate registration, which the loader is entitled to refuse.
function M.install()
  if done then return true end
  done = true

  -- Gen 3 wears through the engine's own player graphic, not the catalog;
  -- see the header.  Installed before the catalog question is asked, because
  -- a Gen 3 boot has no catalog to ask it of.
  local gen = Gen.generation()
  if gen == 3 then M.installLook3() end

  local content = mod.content
  local sprites = content and content.sprites
  if not (sprites and sprites.register) then
    mod.log:warn("no sprite catalog to add characters to; NIRE will not be "
      .. "offered -- update the game to a build whose mod API carries the "
      .. "sprites registry")
    return false
  end

  for _, char in ipairs(Config.OWN_CHARS) do
    -- Only Gen 3 is asked: a Gen 1 and a Gen 2 boot have always registered
    -- the whole cast (Gold then hides what it may not wear), and nothing
    -- about that moves.  A Gen 3 boot has no catalog target at all, so a row
    -- it may not wear is never written -- see the header.
    local skip = gen == 3 and not Config.ownCharAllowed(char, gen)
    local walk = not skip and assetPath(char, "walk.png") or nil
    if skip then
      -- gen-gated: not a failure, and nothing to say about it
    elseif not walk then
      mod.log:warn("could not resolve %s's art; that character will not be "
        .. "offered -- reinstall the mod folder so %s is present",
        char.label, char.dir)
    else
      local ok, err = pcall(function()
        sprites:register(char.id, {
          image = walk,
          frames = Config.CHAR_FRAMES,
          walker = true,
          paletteSource = Config.CHAR_PALETTE_SOURCE,
        })
      end)
      if ok then
        registered[char.id] = char
      else
        mod.log:warn("could not add %s to the character catalog (%s); the "
          .. "other characters are unaffected", char.label, tostring(err))
      end
    end
  end

  M.installScales(content)
  return next(registered) ~= nil
end

-- The back pic is the one pic whose *size* the engine has an opinion about:
-- it draws a trainer back at 2x, which is 64 screen pixels for the 32x32 the
-- ROM carries. These are 48x48, so without this they would draw 96 pixels
-- tall -- feet on the text-box top, growing upward over the whole field,
-- enemy pic and status boxes included. An image-level battle_sprite_scales
-- entry is the only lever that reaches a trainer back -- the species-level
-- one needs a species, and a trainer pic has none.
--
-- The number registered here is always an integer, and this is where that is
-- enforced. The plain battle view uses the registered scale raw, on a
-- nearest-neighbour canvas, so a fraction spreads some source pixels over one
-- destination pixel and others over two -- the sprite draws uneven. (The
-- alternate 3D view already rounds every battle scale to the nearest integer
-- before drawing, for the same reason; this only extends that precedent to
-- the view that never had it.) A character row that asks for a fraction is
-- snapped to the nearest whole number and warned about rather than refused:
-- a slightly wrong size is a cosmetic bug, and dropping the character over
-- it would be the larger one. The floor of 1 is deliberate, not a rounding
-- artifact -- this mod's art is authored at the size it draws at, so a
-- sub-1 scale here could only be a mistake.
--
-- Split out from install so it can be read (and tested) as its own step: a
-- missing scale is a cosmetic bug, not a missing character, so it is warned
-- about separately and never stops a registration that already landed.
function M.installScales(content)
  local scales = content and content.battle_sprite_scales
  if not (scales and scales.register) then
    mod.log:warn("no battle_sprite_scales registry; NIRE's back pic will "
      .. "draw oversized in battle -- update the game to a build that "
      .. "carries it")
    return false
  end

  local all = true
  for id, char in pairs(registered) do
    local back = assetPath(char, "back.png")
    local want = tonumber(char.backScale)
    local scale = math.max(1, math.floor((want or 1) + 0.5))
    if char.backScale ~= nil and want ~= scale then
      mod.log:warn("%s asked for a back-pic scale of %s and was given %d; "
        .. "give %s a whole-number backScale in Config.OWN_CHARS -- a "
        .. "fractional scale draws uneven pixels in battle",
        char.label, tostring(char.backScale), scale, char.label)
    end
    local ok = back ~= nil
    if ok then
      ok = pcall(function()
        scales:register(scaleId(char), { path = back, scale = scale })
      end)
    end
    if not ok then
      all = false
      mod.log:warn("could not size %s's back pic; it will draw oversized in "
        .. "battle -- the rest of the character is unaffected", tostring(id))
    end
  end
  return all
end

-- ------- the pics the catalog does not cover

-- The pic the engine should draw the player with, or nil to leave whatever
-- it already chose alone.
--
-- `side` is the engine's own word for which pic it is asking for: "back" is
-- the battle back pic, "front" covers the trainer card, Oak's intro and the
-- Hall of Fame -- three screens, one 56x56 pic, exactly as vanilla shares
-- RedPicFront between them.
--
-- nil for a character this mod did not register, which includes every
-- vanilla one: wearing COOLTRAINER on the map has never changed your battle
-- pic and this must not be what starts.
function M.pic(id, side)
  local char = registered[id]
  if not char then return nil end
  -- Gen 2 is not ready for OWN_CHARS battle / card pics yet — leave the
  -- engine on Chris (or whoever the boot already chose).
  if not Config.ownCharAllowed(char, Gen.generation()) then return nil end
  return assetPath(char, side == "back" and "back.png" or "front.png")
end

-- The sheet the player should be drawn from while on the bicycle, as a
-- sprite record, or nil to leave the engine's own bike sheet alone.
--
-- A record and not a path because the bike sheet is not in the catalog and
-- never should be: `field.playerSprites.bike` names exactly one id, read
-- once in Player.new, so a second one would be a character in the CHARACTER
-- picker that nobody can be -- pick it and the game would still put RED on
-- the bicycle underneath you. What the mount needs is what SpriteRenderer
-- needs, which is the record itself; Client.applyLook builds the renderer
-- from it and hangs it on the live player beside the walking one.
--
-- Same shape install() registers, and deliberately so: frames and palette
-- decided in one place means a bike sheet cannot drift from the walking
-- sheet it belongs to. Gen-gated like M.pic -- Gold puts CHRIS on the
-- bicycle and this mod's characters are not ready for that boot yet.
function M.bikeDef(id)
  local char = registered[id]
  if not char then return nil end
  if not Config.ownCharAllowed(char, Gen.generation()) then return nil end
  local image = assetPath(char, "bike.png")
  if not image then return nil end
  return {
    image = image,
    frames = Config.CHAR_FRAMES,
    walker = true,
    paletteSource = Config.CHAR_PALETTE_SOURCE,
  }
end

-- Is this one of ours?  Chars.available answers the catalog question; this
-- answers the narrower "did *this* file put it there", which is what decides
-- whether the pics above apply.
function M.owns(id)
  return registered[id] ~= nil
end

-- ------- Gen 3: wearing the look
--
-- The engine's own function is kept on its module under this key, and the
-- wrap itself is Gen3.wrapFn's: a second install (a hot reload re-running
-- this file) peels this mod's previous wrapper off the slot instead of
-- stacking a wrapper on a wrapper -- but wraps *another* mod's wrapper when
-- one sits on top of ours, rather than the pristine original, so that mod's
-- change stays in the chain.
local LOOK3_ORIGINAL = "__rby_mmo_playerGraphicsId"

local look3 = {
  handle = nil,     -- Gen3.wrapFn's handle for the wrapper this file put in
  module = nil,     -- the OwSprites table the wrapper is installed on
  wrapper = nil,    -- the function this file put there
  retired = false,  -- restoreLook3 ran; a wrapper somebody else stacked on
                    -- top of ours stays in place but ours answers vanilla
  raw = nil,        -- the choice string the memo below was computed for
  gender = nil,
  worn = false,     -- that choice as a graphic id on this cart, or false
  walk = false,     -- the plain walking graphic for that gender, or false
}

-- Is this mod still the loaded one?  mod.find answers nil for a mod the
-- loader rolled back or that is not active, and a hot reload hands the new
-- instance a new exports table -- either way a wrapper left behind by that
-- instance must go back to answering what the engine would.
--
-- The wrapper asks this on every call, and the engine calls playerGraphicsId
-- three to five times a frame; mod.find builds a handle table each time it
-- answers.  So the answer is kept for ALIVE_RECHECK calls and asked again
-- after that (and on the first call after every install).  A hot reload does
-- not wait for the recheck: the new instance's install takes the slot's live
-- mark (Gen3.wrapLive), which is one rawget and is asked every call.
local ALIVE_RECHECK = 120
local aliveAnswer, aliveCountdown = false, 0
local function alive()
  aliveCountdown = aliveCountdown - 1
  if aliveCountdown > 0 then return aliveAnswer end
  aliveCountdown = ALIVE_RECHECK
  local ok, handle = pcall(mod.find, Config.MOD_ID)
  aliveAnswer = ok and type(handle) == "table" and handle.exports == mod.exports
  return aliveAnswer
end

-- The player's choice, read without a closure: asked every drawn frame.
local function stored(store, key)
  if type(store) ~= "table" or type(store.get) ~= "function" then return nil end
  local ok, value = pcall(store.get, store, key)
  if ok and type(value) == "string" and value ~= "" then return value end
  return nil
end

local function choiceString()
  return stored(mod.save, "sprite") or stored(mod.options, "sprite")
end

-- The same rule Client.explicitChoice states for Gen 1 and Gen 2: a look is
-- worn only when the player asked for one, and asking for the look the cart
-- already draws them as is a restore, not a wear.  Memoised on the choice and
-- the gender, because this is asked every drawn frame and both change only
-- when the player does something.
local function wornLook3(game)
  local chosen = choiceString()
  if not chosen then return nil, nil end
  local session = (type(game) == "table" and type(game.session) == "table"
    and game.session) or Gen3.session()
  local gender = Gen3.genderOf(session and session.gender)
  if look3.raw ~= chosen or look3.gender ~= gender then
    local id = Chars.resolve(chosen, game)
    local walkName = Gen3.playerGfxName(gender)
    local walk = walkName and Gen3.gfxId(walkName) or nil
    local worn = nil
    if id ~= walkName and id ~= Gen.defaultSprite(game) then worn = Gen3.gfxId(id) end
    look3.raw, look3.gender = chosen, gender
    look3.worn, look3.walk = worn or false, walk or false
  end
  return look3.worn or nil, look3.walk or nil
end

-- What the wrapper answers instead of `base`, or nil to keep it.  Only the
-- plain walking graphic is ever replaced: the bike, surf, fishing, field-move
-- and VS Seeker graphics are other numbers, and a worn look has none of them.
-- Cheapest test first: retired and superseded are field reads, alive is a
-- countdown between its rechecks.
local function swap3(base, game)
  if look3.retired or not Gen3.wrapLive(look3.handle) or not alive() then
    return nil
  end
  local worn, walk = wornLook3(game)
  if not (worn and walk) or base ~= walk then return nil end
  return worn
end

-- The graphic the local player is drawn with right now, and whether it is a
-- worn look -- for the suite, the drivers and the overlay's own label.
function M.lookGfx3(game)
  local OwSprites = look3.module
  local fn = OwSprites and OwSprites.playerGraphicsId
  if type(fn) ~= "function" then return nil, false end
  local ok, id = pcall(fn, game or mod.game)
  if not ok then return nil, false end
  local worn = wornLook3(game)
  return id, worn ~= nil and id == worn
end

function M.installLook3()
  if look3.handle then
    -- Installed already, or retired in place under somebody else's wrapper
    -- (see restoreLook3): waking it keeps that wrapper where it is.
    look3.retired = false
    aliveCountdown = 0
    return true
  end
  local OwSprites = Gen3.engine("src.core.game3.ow_sprites")
  if not (OwSprites and type(OwSprites.playerGraphicsId) == "function") then
    mod.log:warn("this build has no overworld player-graphic seam; your "
      .. "chosen character will show to other players but not on your own "
      .. "screen -- update the game, or pick your cart's own trainer")
    return false
  end
  local handle = Gen3.wrapFn(OwSprites, "playerGraphicsId", LOOK3_ORIGINAL,
    function(inner)
      return function(game, player)
        local base = inner(game, player)
        local ok, swapped = pcall(swap3, base, game)
        if ok and swapped then return swapped end
        return base
      end
    end)
  if not handle then return false end
  look3.handle, look3.module, look3.wrapper = handle, OwSprites, handle.wrapper
  look3.retired = false
  look3.raw = nil
  aliveCountdown = 0
  return true
end

-- Put back what the wrapper wrapped.  Only when the slot still holds this
-- file's wrapper: another mod that wrapped on top of it owns the slot now,
-- and restoring underneath it would take their change away too -- so ours
-- is retired in place instead and answers what the engine would.
function M.restoreLook3()
  if not look3.handle then return false end
  look3.retired = true
  if Gen3.unwrapFn(look3.handle) then
    look3.handle, look3.module, look3.wrapper = nil, nil, nil
  end
  return true
end

-- Every character this copy actually registered, sorted, for the suite and
-- for anyone who wants to list them without walking the whole catalog.
function M.ids()
  local out = {}
  for id in pairs(registered) do out[#out + 1] = id end
  table.sort(out)
  return out
end

M.scaleId = scaleId

return M
