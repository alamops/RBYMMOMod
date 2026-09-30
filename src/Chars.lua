-- Which overworld sprites a player may wear.
--
-- Derived from the live sprite catalog rather than hardcoded, so a ROM or a
-- mod that adds characters offers them without this file changing. What is
-- hardcoded is only what to *leave out*: the catalog carries boulders,
-- Poke Balls, a fossil and a sleeping gambler alongside the people.
--
-- Non-people are excluded for a practical reason as well as a cosmetic one.
-- A walking avatar plays a two-frame step cycle; an object sheet has no
-- such frames, so wearing a boulder would animate wrongly on every other
-- player's screen, not just look odd.
--
-- ------- Gen 3
--
-- FireRed, LeafGreen and Emerald have no sprite catalog to walk: the sprites
-- registry is gated on a Gen 3 boot, and an overworld figure there is an
-- OBJ_EVENT_GFX_* graphic the engine draws by number from the player's own
-- cache.  So on Gen 3 the wearable list is a curated one (LOOKS, below) and
-- a character id is a graphic *name* on the running cart -- the same string
-- that rides the wire as `sprite` (contract C3).  Only names are written
-- here, never pixels: the art is the player's, decoded by the engine.
--
-- The two Gen 3 families name their graphics differently, and a hub mixes
-- them: FireRed's hero is OBJ_EVENT_GFX_RED_NORMAL, Emerald draws the same
-- boy as OBJ_EVENT_GFX_RED; Emerald's Brendan is BRENDAN_NORMAL, FireRed only
-- has the R/S one (RS_BRENDAN).  A look row names both, so a player wearing
-- RED on Emerald is RED on a FireRed screen too, and a global option picked
-- on one cart resolves to the same look on the other.

local need, mod = ...
local Config = need("Config")
local Gen = need("Gen")
local Gen3 = need("Gen3")

local M = {}

-- Catalog-aware default (SPRITE_RED on Gen 1, SPRITE_CHRIS when that is what
-- the boot actually carries).  Same helper Client / Avatars already use.
local function fallbackSprite(game)
  return Gen.defaultSprite(game, mod.content and mod.content.sprites)
end


-- Things in the sprite catalog that are not a person.
local NOT_PEOPLE = {
  SPRITE_BIRD = true, SPRITE_BOULDER = true, SPRITE_CLIPBOARD = true,
  SPRITE_FAIRY = true, SPRITE_FOSSIL = true, SPRITE_MONSTER = true,
  SPRITE_OLD_AMBER = true, SPRITE_PAPER = true, SPRITE_POKEDEX = true,
  SPRITE_POKE_BALL = true, SPRITE_SEEL = true, SPRITE_SNORLAX = true,
}

-- Poses that are a person but not a usable avatar: the UNUSED_ entries are
-- leftovers the game never places, and an asleep sprite has no walk cycle.
-- OWN_CHARS with a `gens` allow-list (NIRE today) are also out when this
-- boot's generation is not on that list.
local function excluded(id, game)
  if NOT_PEOPLE[id] then return true end
  if id:match("^SPRITE_UNUSED_") then return true end
  if id:match("_ASLEEP$") then return true end
  local own = Config.ownCharId(id)
  if own and not Config.ownCharAllowed(own, Gen.generation(game)) then
    return true
  end
  return false
end

-- A sprite record's own `walker` flag says whether it has a walk cycle.
--
-- This matters more than it sounds: over half the *people* in the catalog
-- are stationary NPCs -- NURSE, MOM, GRAMPS, the clerks and guards -- drawn
-- from a sheet with no walking frames. Worn as an avatar they would draw,
-- then break the moment the character took a step. So "any human character"
-- means any that can actually walk.
local function walks(record)
  return type(record) == "table" and record.walker == true
end

M.excluded = excluded

-- ------- Gen 3 looks
--
-- One row per look a player may wear on a Gen 3 cart: the label the
-- CHARACTER screen shows, the graphic's name on each family (`frlg` for
-- FireRed / LeafGreen, `rse` for Emerald, `both` when pret spells it the same
-- on the two), and the gender the cart's link rule should fall back to when
-- a viewer's family has no such look at all (a FireRed screen showing an
-- Emerald player dressed as ROXANNE draws the R/S girl, as a Cable Club
-- would).
--
-- Chosen, not generated, and chosen for one property: every one is a
-- *walking* person on its cart.  An event-object graphic can be a sitting
-- child, a doll, a berry tree or a boat, and a remote player worn as one of
-- those would slide from tile to tile without a step cycle.  Where the cache
-- is up, M.walks3 checks the frame count as well, so a build whose sheet
-- turned out to be stationary drops the row instead of drawing it wrong.
--
-- Order is the order the CHARACTER screen lists them in: the four heroes
-- first, then the rivals and professors, the trainer classes, and the gym
-- leaders and Elite Four at the end.
local LOOKS = {
  { label = "RED", frlg = "OBJ_EVENT_GFX_RED_NORMAL", rse = "OBJ_EVENT_GFX_RED", gender = 0 },
  { label = "LEAF", frlg = "OBJ_EVENT_GFX_GREEN_NORMAL", rse = "OBJ_EVENT_GFX_LEAF", gender = 1 },
  { label = "BRENDAN", frlg = "OBJ_EVENT_GFX_RS_BRENDAN", rse = "OBJ_EVENT_GFX_BRENDAN_NORMAL", gender = 0 },
  { label = "MAY", frlg = "OBJ_EVENT_GFX_RS_MAY", rse = "OBJ_EVENT_GFX_MAY_NORMAL", gender = 1 },
  { label = "BLUE", frlg = "OBJ_EVENT_GFX_BLUE", gender = 0 },
  { label = "WALLY", rse = "OBJ_EVENT_GFX_WALLY", gender = 0 },
  { label = "PROF. OAK", frlg = "OBJ_EVENT_GFX_PROF_OAK", gender = 0 },
  { label = "PROF. BIRCH", rse = "OBJ_EVENT_GFX_PROF_BIRCH", gender = 0 },
  { label = "BILL", frlg = "OBJ_EVENT_GFX_BILL", gender = 0 },
  { label = "STEVEN", rse = "OBJ_EVENT_GFX_STEVEN", gender = 0 },
  { label = "YOUNGSTER", both = "OBJ_EVENT_GFX_YOUNGSTER", gender = 0 },
  { label = "BUG CATCHER", both = "OBJ_EVENT_GFX_BUG_CATCHER", gender = 0 },
  { label = "LASS", both = "OBJ_EVENT_GFX_LASS", gender = 1 },
  { label = "CAMPER", both = "OBJ_EVENT_GFX_CAMPER", gender = 0 },
  { label = "PICNICKER", both = "OBJ_EVENT_GFX_PICNICKER", gender = 1 },
  { label = "BEAUTY", both = "OBJ_EVENT_GFX_BEAUTY", gender = 1 },
  { label = "BLACK BELT", both = "OBJ_EVENT_GFX_BLACK_BELT", gender = 0 },
  { label = "HIKER", both = "OBJ_EVENT_GFX_HIKER", gender = 0 },
  { label = "SAILOR", both = "OBJ_EVENT_GFX_SAILOR", gender = 0 },
  { label = "GENTLEMAN", both = "OBJ_EVENT_GFX_GENTLEMAN", gender = 0 },
  { label = "SCIENTIST", frlg = "OBJ_EVENT_GFX_SCIENTIST", rse = "OBJ_EVENT_GFX_SCIENTIST_1", gender = 0 },
  { label = "FISHERMAN", frlg = "OBJ_EVENT_GFX_FISHER", rse = "OBJ_EVENT_GFX_FISHERMAN", gender = 0 },
  { label = "COOLTRAINER M", frlg = "OBJ_EVENT_GFX_COOLTRAINER_M", gender = 0 },
  { label = "COOLTRAINER F", frlg = "OBJ_EVENT_GFX_COOLTRAINER_F", gender = 1 },
  { label = "BIKER", frlg = "OBJ_EVENT_GFX_BIKER", gender = 0 },
  { label = "ROCKER", frlg = "OBJ_EVENT_GFX_ROCKER", gender = 0 },
  { label = "POKEMANIAC", frlg = "OBJ_EVENT_GFX_POKE_MANIAC", rse = "OBJ_EVENT_GFX_MANIAC", gender = 0 },
  { label = "CHANNELER", frlg = "OBJ_EVENT_GFX_CHANNELER", gender = 1 },
  { label = "ROCKET M", frlg = "OBJ_EVENT_GFX_ROCKET_M", gender = 0 },
  { label = "ROCKET F", frlg = "OBJ_EVENT_GFX_ROCKET_F", gender = 1 },
  { label = "EXPERT M", rse = "OBJ_EVENT_GFX_EXPERT_M", gender = 0 },
  { label = "EXPERT F", rse = "OBJ_EVENT_GFX_EXPERT_F", gender = 1 },
  { label = "PSYCHIC", rse = "OBJ_EVENT_GFX_PSYCHIC_M", gender = 0 },
  { label = "HEX MANIAC", rse = "OBJ_EVENT_GFX_HEX_MANIAC", gender = 1 },
  { label = "NINJA BOY", rse = "OBJ_EVENT_GFX_NINJA_BOY", gender = 0 },
  { label = "RICH BOY", rse = "OBJ_EVENT_GFX_RICH_BOY", gender = 0 },
  { label = "SCHOOL KID", rse = "OBJ_EVENT_GFX_SCHOOL_KID_M", gender = 0 },
  { label = "AQUA M", rse = "OBJ_EVENT_GFX_AQUA_MEMBER_M", gender = 0 },
  { label = "AQUA F", rse = "OBJ_EVENT_GFX_AQUA_MEMBER_F", gender = 1 },
  { label = "MAGMA M", rse = "OBJ_EVENT_GFX_MAGMA_MEMBER_M", gender = 0 },
  { label = "MAGMA F", rse = "OBJ_EVENT_GFX_MAGMA_MEMBER_F", gender = 1 },
  { label = "ARCHIE", rse = "OBJ_EVENT_GFX_ARCHIE", gender = 0 },
  { label = "MAXIE", rse = "OBJ_EVENT_GFX_MAXIE", gender = 0 },
  { label = "GIOVANNI", frlg = "OBJ_EVENT_GFX_GIOVANNI", gender = 0 },
  { label = "BROCK", frlg = "OBJ_EVENT_GFX_BROCK", gender = 0 },
  { label = "MISTY", frlg = "OBJ_EVENT_GFX_MISTY", gender = 1 },
  { label = "LT. SURGE", frlg = "OBJ_EVENT_GFX_LT_SURGE", gender = 0 },
  { label = "ERIKA", frlg = "OBJ_EVENT_GFX_ERIKA", gender = 1 },
  { label = "KOGA", frlg = "OBJ_EVENT_GFX_KOGA", gender = 0 },
  { label = "SABRINA", frlg = "OBJ_EVENT_GFX_SABRINA", gender = 1 },
  { label = "BLAINE", frlg = "OBJ_EVENT_GFX_BLAINE", gender = 0 },
  { label = "LORELEI", frlg = "OBJ_EVENT_GFX_LORELEI", gender = 1 },
  { label = "BRUNO", frlg = "OBJ_EVENT_GFX_BRUNO", gender = 0 },
  { label = "AGATHA", frlg = "OBJ_EVENT_GFX_AGATHA", gender = 1 },
  { label = "LANCE", frlg = "OBJ_EVENT_GFX_LANCE", gender = 0 },
  { label = "ROXANNE", rse = "OBJ_EVENT_GFX_ROXANNE", gender = 1 },
  { label = "BRAWLY", rse = "OBJ_EVENT_GFX_BRAWLY", gender = 0 },
  { label = "WATTSON", rse = "OBJ_EVENT_GFX_WATTSON", gender = 0 },
  { label = "FLANNERY", rse = "OBJ_EVENT_GFX_FLANNERY", gender = 1 },
  { label = "NORMAN", rse = "OBJ_EVENT_GFX_NORMAN", gender = 0 },
  { label = "WINONA", rse = "OBJ_EVENT_GFX_WINONA", gender = 1 },
  { label = "TATE", rse = "OBJ_EVENT_GFX_TATE", gender = 0 },
  { label = "LIZA", rse = "OBJ_EVENT_GFX_LIZA", gender = 1 },
  { label = "JUAN", rse = "OBJ_EVENT_GFX_JUAN", gender = 0 },
  { label = "SIDNEY", rse = "OBJ_EVENT_GFX_SIDNEY", gender = 0 },
  { label = "PHOEBE", rse = "OBJ_EVENT_GFX_PHOEBE", gender = 1 },
  { label = "GLACIA", rse = "OBJ_EVENT_GFX_GLACIA", gender = 1 },
  { label = "DRAKE", rse = "OBJ_EVENT_GFX_DRAKE", gender = 0 },
  { label = "WALLACE", rse = "OBJ_EVENT_GFX_WALLACE", gender = 0 },
}
M.LOOKS = LOOKS

-- name -> row, for every spelling a row carries (either family's).  Built
-- once: the table above is static, and this is asked from a draw path.
local lookByName = {}
for _, row in ipairs(LOOKS) do
  for _, key in ipairs({ "both", "frlg", "rse" }) do
    local name = row[key]
    if name then lookByName[name] = row end
  end
end

-- The row a graphic name belongs to, whichever family spelled it; nil for a
-- name no row carries.
function M.look(name)
  if type(name) ~= "string" then return nil end
  return lookByName[name]
end

-- The spelling of a row on one family ("frlg" | "rse"), or nil when that
-- family has no such look.
local function nameOn(row, family)
  if type(row) ~= "table" then return nil end
  return row.both or row[family]
end
M.lookNameOn = nameOn

local function gen3(game)
  return Gen.generation(game) == 3
end

-- The running cart's family, as Gen.family says it ("frlg" | "rse").
local function family3(game)
  local family = Gen.family(game)
  if family == "rse" then return "rse" end
  return "frlg"
end

-- Does this graphic have a step cycle on this cart?  Asked of the engine's
-- own sprite loader (src/core/game3/ow_sprites.lua: a walking sheet is nine
-- frames -- stand and two steps, three ways), and only once the overworld
-- cache is up: before that (a headless load, the title screen) nothing can
-- be known, and the curated table is trusted.  Remembered either way, so the
-- CHARACTER screen does not reload a sheet per row per open.
local walkKnown = {}
function M.walks3(gfxId)
  local id = tonumber(gfxId)
  if not id then return false end
  local known = walkKnown[id]
  if known ~= nil then return known end
  local OwSprites = Gen3.engine("src.core.game3.ow_sprites")
  if not (OwSprites and type(OwSprites.ready) == "function"
          and type(OwSprites.get) == "function") then
    return true
  end
  local okReady, ready = pcall(OwSprites.ready)
  if not (okReady and ready) then return true end
  local ok, spr = pcall(OwSprites.get, id)
  if not ok or type(spr) ~= "table" then
    -- a sheet that would not load is not wearable, but a failed load is not
    -- a verdict about the look either -- the next open may find it
    return false
  end
  local walking = (tonumber(spr.frameCount) or 0) >= 9
  walkKnown[id] = walking
  return walking
end

-- Can this cart draw `name` as a walking person?  The player's own look is
-- always wearable (it is what everybody on this cart is drawn as by default,
-- whatever the table says), and anything else has to be a row of LOOKS in
-- this family's spelling.
local function wearable3(name, game)
  if type(name) ~= "string" then return false end
  if name == fallbackSprite(game) then return true end
  local row = lookByName[name]
  if not row or nameOn(row, family3(game)) ~= name then return false end
  local id = Gen3.gfxId(name)
  if not id then return false end
  return M.walks3(id)
end

-- "OBJ_EVENT_GFX_COOLTRAINER_M" -> "COOLTRAINER M", unless the row has a
-- label of its own ("OBJ_EVENT_GFX_GREEN_NORMAL" is LEAF, not GREEN NORMAL).
local function label3(id)
  local row = lookByName[id]
  if row then return row.label end
  local s = tostring(id):gsub("^OBJ_EVENT_GFX_", ""):gsub("_NORMAL$", "")
  return (s:gsub("_", " "))
end

-- A graphic name another player sent, as the graphic *this* cart draws them
-- with: (numeric id, name), or nil off Gen 3.
--
-- The look table first, because it is the only thing that knows a FireRed
-- RED_NORMAL and an Emerald RED are one boy: a name this cart spells the same
-- way is drawn as itself, a row the other family spelled is drawn in this
-- family's spelling.  Everything else -- the hub's sprite-less token, a look
-- this family has no graphic for, a name no row carries -- goes to
-- Gen3.viewerGfxFor, which applies the carts' own Cable Club rule by the
-- sender's version and gender.  The row's gender is the better guess there
-- than none: a FireRed viewer with an Emerald ROXANNE draws a girl.
function M.gfxForViewer(sprite, partnerVersion, gender)
  if not Gen3.active() then return nil end
  local family = family3()
  if type(sprite) == "string" then
    local row = lookByName[sprite]
    local mine = row and nameOn(row, family)
    if mine then
      local id = Gen3.gfxId(mine)
      if id then return id, mine end
    end
    if row and gender == nil then gender = row.gender end
  end
  return Gen3.viewerGfxFor(sprite, partnerVersion, gender)
end

-- "SPRITE_COOLTRAINER_M" -> "COOLTRAINER M"
function M.label(id)
  if type(id) == "string" and id:find("^OBJ_EVENT_GFX_") then return label3(id) end
  return (tostring(id):gsub("^SPRITE_", ""):gsub("_", " "))
end

-- The Gen 3 list: the player's own look first (the fallback everyone on the
-- cart is guaranteed to have), then every row this family can draw, in the
-- table's order.
local function list3(game)
  local fallback = fallbackSprite(game)
  local out, seen = { fallback }, { [fallback] = true }
  local family = family3(game)
  for _, row in ipairs(LOOKS) do
    local name = nameOn(row, family)
    if name and not seen[name] and wearable3(name, game) then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

-- Every wearable character, sorted, with the gen-aware default first because
-- it is the fallback everyone on this boot is guaranteed to have.
function M.list(game)
  if gen3(game) then return list3(game) end
  local registry = mod.content and mod.content.sprites
  local fallback = fallbackSprite(game)
  if not registry then return { fallback } end

  local out = {}
  local ok = pcall(function()
    for id, record in registry:each() do
      if type(id) == "string" and id:match("^SPRITE_")
         and not excluded(id, game) and walks(record) then
        out[#out + 1] = id
      end
    end
  end)
  if not ok or #out == 0 then return { fallback } end

  table.sort(out, function(a, b)
    if a == fallback then return true end
    if b == fallback then return false end
    return a < b
  end)
  return out
end

-- Is this character present in *this* game's catalog?
--
-- The answer can differ between players: a modded catalog, or a different
-- ROM, may not carry what someone else picked. Everyone falls back to the
-- gen-aware default rather than failing to draw. `game` is optional; when
-- omitted, Gen.generation reads the live boot (so Gold hides Gen1-only OWN
-- chars without every caller threading a game handle).
function M.available(id, game)
  if gen3(game) then return wearable3(id, game) end
  local registry = mod.content and mod.content.sprites
  if not (registry and type(id) == "string") then return false end
  local ok, record = pcall(function() return registry:get(id) end)
  return ok and walks(record) and not excluded(id, game)
end

-- On Gen 3 a look spelled in the *other* family's words is still that look:
-- the option row is global to every boot, so a MAY picked on Emerald comes
-- back through here on FireRed as RS_MAY rather than as the default.
function M.resolve(id, game)
  if M.available(id, game) then return id end
  if gen3(game) then
    local mine = nameOn(lookByName[id], family3(game))
    if mine and wearable3(mine, game) then return mine end
  end
  return fallbackSprite(game)
end


-- ------- the character's front-facing pose, as a drawable
--
-- Not a battle pic: those exist only for trainer *classes*, so most of the
-- 36 characters have none.  Every character has an overworld sheet --
-- 16x96, six 16x16 frames, the first being stand-down
-- (src/render/SpriteRenderer.lua) -- which is the front-facing pose and the
-- one everybody has.
--
-- Lives here rather than beside either of its callers because there are now
-- two: the trainer card draws it as a portrait, and the town map draws it at
-- a party member's city.  Two copies of a cache would mean two copies of the
-- image, and the second caller is a per-frame draw.
--
-- Cached per sprite id, including the failures: a missing sheet is remembered
-- as `false` so a broken path is not retried on every frame. The key is the
-- id rather than the sheet path because SpriteRenderer's palette bake depends
-- on the record (paletteSource, trueColor, ...) and the seed together --
-- blitting the raw PNG is what turned skin into lime green on the trainer
-- card and the ranking list.
local FRONT_FRAME = { 0, 0, 16, 16 }
local portraits = {}

local function portraitQuad(img)
  local iw, ih = img:getDimensions()
  return love.graphics.newQuad(FRONT_FRAME[1], FRONT_FRAME[2],
                              FRONT_FRAME[3], FRONT_FRAME[4],
                              iw, ih)
end

-- Gen 3: the look's stand-down frame straight off the engine's own sheet
-- (OwSprites.getDraw, so a palette override the cart applied is honoured).
-- Frame 0 is pret's ANIM_STD face-south pose.  A Gen 3 figure is 16x32 --
-- taller than the 16x16 a Gen 1 caller lays out for -- so `w` / `h` ride
-- along for a caller that places it.  The engine keeps the sheet; this keeps
-- only the small entry around it, per graphic, and rebuilds it when the
-- engine hands back a different image (a palette override applied or
-- lifted since).
local portraits3 = {}

local function portrait3(spriteId)
  local id = Gen3.gfxId(spriteId)
  if not id then return nil end
  local OwSprites = Gen3.engine("src.core.game3.ow_sprites")
  if not (OwSprites and type(OwSprites.getDraw) == "function") then return nil end
  local ok, spr = pcall(OwSprites.getDraw, id)
  if not (ok and type(spr) == "table" and spr.image and type(spr.quads) == "table") then
    return nil
  end
  local entry = portraits3[id]
  if not (entry and entry.image == spr.image) then
    entry = {
      image = spr.image, quad = spr.quads[0],
      w = tonumber(spr.width) or 16, h = tonumber(spr.height) or 32,
    }
    portraits3[id] = entry
  end
  if not entry.quad then return nil end
  return entry
end

function M.portrait(spriteId)
  if gen3() then return portrait3(spriteId) end
  local registry = mod.content and mod.content.sprites
  local ok, record = pcall(function() return registry and registry:get(spriteId) end)
  if not (ok and type(record) == "table" and type(record.image) == "string") then
    return nil
  end

  local entry = portraits[spriteId]
  if entry == nil then
    local img
    local built = pcall(function()
      local SpriteRenderer = require("src.render.SpriteRenderer")
      local renderer = SpriteRenderer.new(record, spriteId)
      -- Gen 2 sheets are grayscale + PAL_OW_*; the overworld calls
      -- setObjPalette before draw. Menus (character picker, trainer card,
      -- town-map marks) only go through resolveImage — without the same
      -- bake they stay DMG black-and-white on Gold.
      if type(renderer.setObjPalette) == "function"
          and (record.palette ~= nil or record.paletteId ~= nil) then
        local game = nil
        local gotGame = pcall(function() game = mod.game end)
        local pals = gotGame and game and game.data and game.data.gen2Palettes
        -- Never on a Gen 3 boot, whatever the dataset carries: the loader
        -- throws on a src.*.gen2.* require there (cross-generation
        -- denial).  The Gen 3 arm returned above anyway; this keeps the
        -- require unreachable even if a caller reaches here some other way.
        if type(pals) == "table" and not Gen3.active() then
          local Palettes = require("src.world.gen2.Palettes")
          local colors = Palettes.spritePalette(pals, "DAY", record)
          if colors then
            local id = tonumber(record.paletteId) or 0
            renderer:setObjPalette(colors, ("gen2:DAY:%d"):format(id))
          end
        end
      end
      if type(renderer.resolveImage) == "function" then
        img = renderer:resolveImage()
      else
        img = renderer.image
      end
    end)
    if not (built and img) then
      local loaded
      loaded, img = pcall(love.graphics.newImage, record.image)
      if not (loaded and img) then img = nil end
    end
    if img then
      entry = { image = img, quad = portraitQuad(img) }
    else
      entry = false
    end
    portraits[spriteId] = entry
  end
  return entry or nil
end

M.FRONT_FRAME = FRONT_FRAME

return M
