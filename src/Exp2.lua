-- Gen 2 experience apply: the client half of a refereed faint.
--
-- The hub holds no species table -- it never has and, by the legal floor this
-- whole server is built under, never will -- so a mediated `exp` event states
-- facts and nothing else: which monster fell, what level it was, and how many
-- shares split it (`src/BattleSim2/Turn.lua:_awardExp`).  Pricing those facts
-- is the owner's job, on the owner's save, with the owner's generation's
-- formula.  On Gen 1 that formula is `src/battle/Experience.lua` and
-- `MediatedBattle:gainExp` calls it directly.  Gen 2 has no such module: its
-- award lives inside `src/battle/gen2/Battle.lua` as `awardExperience` /
-- `giveExperiencePass`, methods on a live `Battle` a mediated fight does not
-- have and must not fake.
--
-- So this file is to Gen 2 exp what `src/Trade2.lua` is to Gen 2 trade: the mod
-- owns the *orchestration*, the engine keeps the *arithmetic*.  Every number
-- below comes out of `src/battle/gen2/Mon.lua` -- `experienceGain`,
-- `gainStatExp`, `gainExperience` -- so a Gold fight in the MMO pays exactly
-- what the same fight pays offline, and a future engine change to the curve
-- moves both together.
--
-- What Gen 2 does differently from Gen 1, and therefore what this file exists
-- to get right rather than approximate:
--
--   * **the exp field is `mon.experience`**, not Gen 1's `mon.exp`, and the
--     level list comes out of a `from`/`to` pair rather than being accumulated.
--   * **stat exp is its own five-key block** with a `special` key that draws
--     from the loser's `specialAttack` (`Mon.STAT_EXP_ORDER`), not Gen 1's
--     shared Special.
--   * **EXP.SHARE replaces EXP.ALL**, and it is not the same shape.  Gen 1
--     halves the pool and pays the whole party a second time; Gen 2 halves the
--     pool when *any* living party member holds the item and pays a second pass
--     to the **holders only** -- so a holder that also fought collects twice.
--     `M.holders` finds them the way `IsAnyMonHoldingExpShare` does, by item id.
--   * **two more x1.5 multipliers**: a traded mon (its OT id against the
--     player's) and a LUCKY_EGG holder, both floored on the running amount.
--   * **Pokerus doubles stat exp**, including for a mon that has been cured and
--     keeps the immune marker.
--
-- Nothing here reads the wire and nothing here draws: callers hand over one
-- already-validated fact set and one party monster.  Every engine reach is a
-- `pcall(require, ...)`, so a build that cannot load the Gen 2 battle modules
-- fights on exp-less instead of failing to open a battle at all -- the same
-- soft-load posture `MediatedBattle.loadEngine` takes for Gen 1.

local need, mod = ...

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- ------------------------------------------------------------------
-- the engine, softly
-- ------------------------------------------------------------------

local engine, engineTried

local function loadEngine()
  if engineTried then return engine end
  engineTried = true
  local function grab(path)
    local ok, value = pcall(require, path)
    if ok then return value end
    return nil
  end
  local Mon = grab("src.battle.gen2.Mon")
  if type(Mon) ~= "table" or type(Mon.gainExperience) ~= "function" then
    engine = false
    return engine
  end
  engine = {
    Mon = Mon,
    -- Both optional.  Pokerus only doubles stat exp and Happiness only moves a
    -- number the battle never shows, so a build missing either still pays the
    -- right experience -- which is the part a player would notice.
    Pokerus = grab("src.core.gen2.Pokerus"),
    Happiness = grab("src.core.gen2.Happiness"),
  }
  return engine
end

M.loadEngine = loadEngine

-- Is the Gen 2 award path usable at all?  Callers warn once and skip rather
-- than retry, so this is deliberately cheap to ask repeatedly.
function M.available()
  local eng = loadEngine()
  return (eng and eng.Mon) and true or false
end

-- ------------------------------------------------------------------
-- the party facts a pass needs
-- ------------------------------------------------------------------

-- Living, non-egg party indices holding EXP_SHARE, in party order.
--
-- By ITEM ID, the way the cart's `cp EXP_SHARE` does it -- not by held-item
-- *effect*, which is a different table and would sweep in anything that
-- happened to share a behaviour byte.  A fainted holder gets nothing (the pass
-- loop skips fainted mons), so it is not a holder for this purpose either, and
-- an egg is not a recipient of anything.
function M.holders(party)
  local out = {}
  if type(party) ~= "table" then return out end
  for index = 1, #party do
    local mon = party[index]
    if type(mon) == "table" and (tonumber(mon.hp) or 0) > 0
       and not mon.isEgg and mon.item == "EXP_SHARE" then
      out[#out + 1] = index
    end
  end
  return out
end

-- GiveExperiencePoints' traded check: the mon's OT id against the player's.
-- A mon with no recorded OT (the port's own catches and gifts) is the player's.
function M.traded(save, mon)
  local playerId = save and save.player and save.player.id
  if mon == nil or mon.otId == nil or playerId == nil then return false end
  return mon.otId ~= playerId
end

-- ------------------------------------------------------------------
-- one pass over one monster
-- ------------------------------------------------------------------

-- `opts`:
--   level        the fallen monster's level  (referee fact)
--   participants this pass's own divisor     (referee fact, or #holders)
--   isTrainer    whether the other side had a trainer behind it
--   halved       the EXP.SHARE tax on the whole pool
--   save         the save the mon belongs to, for the traded check
--
-- Returns `levels` (the LIST of levels reached, so a caller can print one line
-- each exactly as Gen 1's `Experience.apply` lets it), `gained` (the raw amount,
-- which is what the "gained N EXP" line says), and `learned` (the move ids the
-- levels brought, in the order the engine offers them).
--
-- `learned` is a convenience both current callers ignore: they walk the levels
-- and ask `M.movesLearnedAt` per level, which is the shape the Gen 1 path
-- already had. It is returned rather than dropped because it is the engine's
-- own answer and costs nothing extra to pass on -- but nothing depends on it,
-- so a caller may safely take two values.
--
-- Returns nil plus a reason when the pass cannot honestly run.  A reason and
-- not a raise: the caller is an event handler, and an event handler that throws
-- takes the whole stream with it.
--
-- **The mon is mutated in place and that is the point** -- this is where the
-- award persists, because the save is the only place it can.  Stat exp lands
-- *before* the exp points, exactly as `GiveExperiencePoints` orders it, so a
-- mon that levels on this kill recalculates its stats with the effort it just
-- earned already counted.
function M.apply(game, mon, loserDef, opts)
  opts = opts or {}
  local eng = loadEngine()
  if not (eng and eng.Mon) then
    return nil, "the engine's Gen 2 Mon module is unavailable"
  end
  if type(mon) ~= "table" then return nil, "no monster to pay" end
  -- The other two recipient guards `giveExperiencePass` applies, and they
  -- belong here rather than at the call sites for the reason `M.holders` has
  -- them too: this function claims to mirror that pass, and a mirror missing
  -- two of its three conditions is a mirror that will drift.
  --
  -- The fainted check is not redundant with the referee's. `_awardExp` filters
  -- on the SIM's copy of the party, and the save's copy is a different table
  -- that `savePartyIndex` exists precisely because it can disagree with -- so
  -- "the referee said this one is alive" is not the same claim as "the monster
  -- about to be written to is alive".
  if (tonumber(mon.hp) or 0) <= 0 then
    return nil, "the party monster being paid has fainted"
  end
  if mon.isEgg then
    return nil, "an egg earns no experience"
  end
  if type(loserDef) ~= "table" then
    return nil, "no species record for the monster that fell"
  end
  local data = game and game.data
  if type(data) ~= "table" then return nil, "no dataset to price the award with" end

  local level = max(1, floor(tonumber(opts.level) or 0))
  local participants = max(1, floor(tonumber(opts.participants) or 1))
  local halved = opts.halved and true or false
  local traded = M.traded(opts.save or (game and game.save), mon)
  -- `cp LUCKY_EGG` on the mon's item byte: by id, not held effect.
  local luckyEgg = mon.item == "LUCKY_EGG"

  local amount
  local ok = pcall(function()
    amount = eng.Mon.experienceGain(loserDef, level, participants,
      opts.isTrainer and true or false,
      { halved = halved, traded = traded, luckyEgg = luckyEgg })
  end)
  if not ok or type(amount) ~= "number" then
    return nil, "the engine refused to price the award"
  end

  -- Pokerus (or the immune marker a cured mon keeps) doubles stat exp.  Absent
  -- module means no doubling, which is the vanilla case for every mon that
  -- never caught it.
  local doubled = false
  if eng.Pokerus and type(eng.Pokerus.doublesStatExp) == "function" then
    local got, value = pcall(eng.Pokerus.doublesStatExp, mon)
    doubled = (got and value) and true or false
  end
  pcall(eng.Mon.gainStatExp, mon, loserDef, participants, doubled, halved)

  local result
  local applied = pcall(function()
    result = eng.Mon.gainExperience(mon, amount, data)
  end)
  if not applied or type(result) ~= "table" then
    return nil, "the engine refused the award for this monster"
  end

  -- The cart's "level up happiness mod" sits right after the stat recalc and
  -- before the "grew to level" text, and fires ONCE per award however many
  -- levels the mon jumped -- ChangeHappiness is outside the level loop.
  if (result.levels or 0) > 0 and eng.Happiness
     and type(eng.Happiness.change) == "function" then
    pcall(eng.Happiness.change, mon, "GAINLEVEL")
  end

  -- `from`/`to` into the list shape Gen 1 hands back, so both screens' level
  -- printers stay one function.  `gainExperience` omits the pair entirely when
  -- nothing levelled, which reads here as an empty list.
  local levels = {}
  local from = tonumber(result.from)
  local to = tonumber(result.to)
  if from and to then
    for value = from + 1, to do levels[#levels + 1] = value end
  end

  local learned = {}
  for _, moveId in ipairs(result.learned or {}) do learned[#learned + 1] = moveId end

  return levels, amount, learned, traded
end

-- ------------------------------------------------------------------
-- display
-- ------------------------------------------------------------------

-- Moves this species learns at exactly `level`.
--
-- Gen 2 keeps them on `def.levelMoves`, where Gen 1 uses `def.learnset` and
-- `Experience.movesLearnedAt`; the callers want one answer either way, so the
-- generation difference stops here rather than at each `levelled` site.
function M.movesLearnedAt(speciesDef, level)
  local out = {}
  if type(speciesDef) ~= "table" then return out end
  level = tonumber(level)
  if not level then return out end
  for _, entry in ipairs(speciesDef.levelMoves or {}) do
    if entry and tonumber(entry.level) == level and entry.move then
      out[#out + 1] = entry.move
    end
  end
  return out
end

-- How far along its level a monster is, 0..1, for the plate's exp strip.
--
-- The Gen 2 twin of `MediatedBattle.expFraction`: the exp a mon carries is
-- `mon.experience` and the curve resolves through `Mon.growthFor` /
-- `Mon.experienceForLevel` -- the same pair `gainExperience` levels by, so the
-- strip and the level can never disagree about where a level ends.
--
-- nil rather than 0 when it cannot be computed: the plate's contract is that
-- nil means "this caller has no exp data" and draws no strip at all, where 0
-- would draw an empty one and read as a monster that just levelled.
function M.fraction(game, mon)
  local eng = loadEngine()
  if not (eng and eng.Mon) or type(mon) ~= "table" then return nil end
  local data = game and game.data
  local def = data and data.pokemon and data.pokemon[mon.species]
  if type(def) ~= "table" then return nil end

  local level = floor(tonumber(mon.level) or 0)
  if level < 1 then return nil end
  local maxLevel = tonumber(eng.Mon.MAX_LEVEL) or 100
  if level >= maxLevel then return 1 end

  local growth, here, next_
  local ok = pcall(function()
    growth = eng.Mon.growthFor(data, def.growthRate)
    here = eng.Mon.experienceForLevel(growth, level)
    next_ = eng.Mon.experienceForLevel(growth, level + 1)
  end)
  if not ok then return nil end
  here, next_ = tonumber(here), tonumber(next_)
  if not (here and next_) or next_ <= here then return nil end

  local have = tonumber(mon.experience) or here
  return min(1, max(0, (have - here) / (next_ - here)))
end

return M
