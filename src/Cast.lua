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
-- Every failure here is a warning and a character that is simply not
-- offered. A sprite that would not register must not take the multiplayer
-- down with it, and Chars.resolve already turns a character this copy does
-- not carry into RED -- so a broken install degrades to the vanilla cast
-- rather than to a game that will not start.

local need, mod = ...
local Config = need("Config")

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

  local content = mod.content
  local sprites = content and content.sprites
  if not (sprites and sprites.register) then
    mod.log:warn("no sprite catalog to add characters to; NIRE will not be "
      .. "offered -- update the game to a build whose mod API carries the "
      .. "sprites registry")
    return false
  end

  for _, char in ipairs(Config.OWN_CHARS) do
    local walk = assetPath(char, "walk.png")
    if not walk then
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
  return assetPath(char, side == "back" and "back.png" or "front.png")
end

-- Is this one of ours?  Chars.available answers the catalog question; this
-- answers the narrower "did *this* file put it there", which is what decides
-- whether the pics above apply.
function M.owns(id)
  return registered[id] ~= nil
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
