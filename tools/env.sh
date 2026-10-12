# Shared .env loading for this mod's scripts. Sourced, not executed.
#
# The file is parsed line by line rather than sourced, deliberately: a ROM
# path routinely contains spaces, and `. .env` would split it (and would
# execute anything else in there). Nothing in .env is ever run as shell.
#
# Real environment variables win, so a one-off override on the command line
# beats the file.

load_env() {
  local file="$1"
  [ -f "$file" ] || return 0
  echo "  reading $file"
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    # only well-formed shell names; a malformed line is skipped rather than
    # eval'd, since these values reach the environment
    case "$key" in
      [A-Za-z_]*) ;;
      *) continue ;;
    esac
    case "$key" in
      *[!A-Za-z0-9_]*) continue ;;
    esac
    # strip surrounding quotes if the user added them
    value=${value%\"}; value=${value#\"}
    value=${value%\'}; value=${value#\'}
    if [ -z "$(eval "printf '%s' \"\${$key:-}\"" 2>/dev/null)" ]; then
      export "$key=$value"
    fi
  done < "$file"
}

# Worktrees ship no .env (gitignored). Fill empty keys from the main clone
# so ROM_PATH / GOLD_ROM_PATH autopick the same way they do on main.
# `load_env` never overwrites a key that is already set.
load_canon_env() {
  local canon="${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"
  [ -f "$canon" ] || return 0
  load_env "$canon"
}

# Which game a ROM actually is, by SHA-1. Empty when it cannot be told.
rom_version_of() {
  local path="$1"
  [ -f "$path" ] || return 0
  command -v shasum >/dev/null 2>&1 || return 0
  case "$(shasum -a 1 "$path" | cut -d' ' -f1)" in
    ea9bcae617fdf159b045185467ae58b2e4a48b9a) echo red ;;
    d7037c83e1ae5b39bde3c30787637ba1d4c48ce2) echo blue ;;
    cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1) echo yellow ;;
    # Canonical US Pokemon Gold (GameVersion.lua / docs/gold-phase1.md).
    d8b8a3600a465308c9953dfa04f0081c05bdcb94) echo gold ;;
    # Gen 3 (engine src/core/GameVersion.lua): US FireRed / LeafGreen 1.0 and
    # 1.1, US Emerald. Both revisions of a cart are the same game here.
    41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc|dd5945db9b930750cb39d00c84da8571feebf417) echo firered ;;
    574fa542ffebb14be69902d1d36f1ec0a4afd71e|7862c67bdecbe21d1d69ce082ce34327e1c6ed5e) echo leafgreen ;;
    f3ae088181bf583e55daf962a92bb46f4f1d07b7) echo emerald ;;
    *) echo unknown ;;
  esac
}

# Report on ROM_PATH / ROM_VERSION. Returns non-zero only when they disagree,
# which is the case worth stopping for -- the importer would reject the file
# partway through with a bare SHA-1 mismatch.
check_rom_config() {
  [ -n "${ROM_PATH:-}" ] || return 0
  if [ ! -f "$ROM_PATH" ]; then
    echo "  note: ROM_PATH does not exist ($ROM_PATH)"
    return 0
  fi
  local actual
  actual="$(rom_version_of "$ROM_PATH")"
  case "$actual" in
    '') return 0 ;;
    unknown)
      echo "  note: ROM_PATH is not a canonical US Red/Blue/Yellow ROM"
      return 0 ;;
    gold)
      echo "  !! ROM_PATH points at Gold -- put that in GOLD_ROM_PATH instead" >&2
      return 1 ;;
    firered|leafgreen|emerald)
      echo "  !! ROM_PATH points at $actual -- put that in $(gen3_rom_key "$actual") instead" >&2
      return 1 ;;
  esac
  if [ "$actual" != "${ROM_VERSION:-red}" ]; then
    echo "  !! ROM_VERSION says ${ROM_VERSION:-red} but that file is $actual" >&2
    return 1
  fi
  echo "  rom: $actual (verified)"
  return 0
}

# Parallel check for GOLD_ROM_PATH / GOLD_ROM_VERSION.
check_gold_rom_config() {
  [ -n "${GOLD_ROM_PATH:-}" ] || return 0
  if [ ! -f "$GOLD_ROM_PATH" ]; then
    echo "  note: GOLD_ROM_PATH does not exist ($GOLD_ROM_PATH)"
    return 0
  fi
  local actual
  actual="$(rom_version_of "$GOLD_ROM_PATH")"
  case "$actual" in
    '') return 0 ;;
    unknown)
      echo "  note: GOLD_ROM_PATH is not the canonical US Gold ROM"
      echo "        (expected SHA-1 d8b8a3600a465308c9953dfa04f0081c05bdcb94)"
      return 0 ;;
    gold) ;;
    *)
      echo "  !! GOLD_ROM_PATH is $actual, not gold" >&2
      return 1 ;;
  esac
  local expect="${GOLD_ROM_VERSION:-gold}"
  if [ "$actual" != "$expect" ]; then
    echo "  !! GOLD_ROM_VERSION says $expect but that file is $actual" >&2
    return 1
  fi
  echo "  gold rom: verified"
  return 0
}

# True when the Gold extract cache is present (landmarks.lua is Gen2-only).
have_gold_cache() {
  local root="${1:-.}"
  [ -f "$root/gold/data/generated/landmarks.lua" ] \
    || [ -f "$root/data/generated/gold/landmarks.lua" ] \
    && return 0
  # LOVE save identities (play.sh gold / import) often hold the cache.
  local love_home="${HOME}/Library/Application Support/LOVE"
  if [ -d "$love_home" ]; then
    local f
    for f in "$love_home"/rby-mmo-gold*/gold/data/generated/landmarks.lua \
             "$love_home"/rby-mmo-gold/gold/data/generated/landmarks.lua; do
      [ -f "$f" ] && return 0
    done
  fi
  return 1
}

# ------- Gen 3 (FireRed / LeafGreen / Emerald)
#
# One .env key per cart, parallel to ROM_PATH / GOLD_ROM_PATH:
#
#     FIRE_RED_ROM_PATH=/path/to/Pokemon FireRed.gba     FIRE_RED_ROM_VERSION=firered
#     LEAF_GREEN_ROM_PATH=/path/to/Pokemon LeafGreen.gba LEAF_GREEN_ROM_VERSION=leafgreen
#     EMERALD_ROM_PATH=/path/to/Pokemon Emerald.gba      EMERALD_ROM_VERSION=emerald
#
# The engine imports a Gen 3 cart at boot (POKEPORT_IMPORT_ROM +
# POKEPORT_VERSION=<game>) into the LOVE identity's <game>/ prefix; the e2e
# runners copy an existing import into each throwaway identity instead of
# re-importing (seed_gen3_cache).
: "${FIRE_RED_ROM_VERSION:=firered}"
: "${LEAF_GREEN_ROM_VERSION:=leafgreen}"
: "${EMERALD_ROM_VERSION:=emerald}"

# The .env key naming a game's ROM.
gen3_rom_key() {
  case "$1" in
    firered) echo FIRE_RED_ROM_PATH ;;
    leafgreen) echo LEAF_GREEN_ROM_PATH ;;
    emerald) echo EMERALD_ROM_PATH ;;
    *) echo "" ;;
  esac
}

# The ROM path configured for a Gen 3 game (empty when unset).
gen3_rom_path() {
  local key
  key="$(gen3_rom_key "$1")"
  [ -n "$key" ] || return 0
  eval "printf '%s' \"\${$key:-}\""
}

# The canonical SHA-1 line a failure message quotes.
gen3_rom_sha() {
  case "$1" in
    firered) echo "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc (1.0) or dd5945db9b930750cb39d00c84da8571feebf417 (1.1)" ;;
    leafgreen) echo "574fa542ffebb14be69902d1d36f1ec0a4afd71e (1.0) or 7862c67bdecbe21d1d69ce082ce34327e1c6ed5e (1.1)" ;;
    emerald) echo "f3ae088181bf583e55daf962a92bb46f4f1d07b7" ;;
  esac
}

# Parallel check for a Gen 3 game's <GAME>_ROM_PATH / <GAME>_ROM_VERSION.
# Non-zero only when the file is a different known cart than the key says.
check_gen3_rom_config() {
  local game="${1:-firered}" key path actual expect
  key="$(gen3_rom_key "$game")"
  [ -n "$key" ] || { echo "  !! unknown Gen 3 game '$game' (firered|leafgreen|emerald)" >&2; return 1; }
  path="$(gen3_rom_path "$game")"
  [ -n "$path" ] || return 0
  if [ ! -f "$path" ]; then
    echo "  note: $key does not exist ($path)"
    return 0
  fi
  actual="$(rom_version_of "$path")"
  case "$actual" in
    '') return 0 ;;
    unknown)
      echo "  note: $key is not a canonical US $game ROM"
      echo "        (expected SHA-1 $(gen3_rom_sha "$game"))"
      return 0 ;;
  esac
  case "$game" in
    firered) expect="${FIRE_RED_ROM_VERSION:-firered}" ;;
    leafgreen) expect="${LEAF_GREEN_ROM_VERSION:-leafgreen}" ;;
    emerald) expect="${EMERALD_ROM_VERSION:-emerald}" ;;
  esac
  if [ "$actual" != "$game" ] || [ "$actual" != "$expect" ]; then
    echo "  !! $key is $actual, not $game" >&2
    return 1
  fi
  echo "  $game rom: verified"
  return 0
}

# Where an imported cache for a Gen 3 game lives, printed (the <game>/ dir
# holding rom-cache.complete and data/generated/gba/). Looks in the engine
# tree first, then in LOVE save identities (the engine's own import runs and
# earlier e2e imports leave one there). Empty + non-zero when there is none.
gen3_cache_dir() {
  local game="${1:-firered}" root="${2:-.}"
  local d
  for d in "$root/$game"; do
    if [ -f "$d/rom-cache.complete" ] && [ -d "$d/data/generated/gba" ]; then
      echo "$d"; return 0
    fi
  done
  local love_home="${HOME}/Library/Application Support/LOVE"
  [ -d "$love_home" ] || return 1
  local short
  case "$game" in
    firered) short=fr ;;
    leafgreen) short=lg ;;
    emerald) short=em ;;
  esac
  for d in "$love_home/rby-mmo-g3-import-$short/$game" \
           "$love_home"/rby-mmo-g3-import*/"$game" \
           "$love_home"/rby-mmo-g3*/"$game"; do
    if [ -f "$d/rom-cache.complete" ] && [ -d "$d/data/generated/gba" ]; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# True when an imported cache for the game is present somewhere findable.
have_gen3_cache() {
  gen3_cache_dir "$@" >/dev/null 2>&1
}

# Copy an imported cache into a (throwaway) save directory, so LOVE boots
# straight into the game instead of the importer. APFS clones (cp -c) make a
# 250 MB cache instant; a plain copy is the fallback.
seed_gen3_cache() {
  local save_dir="$1" game="${2:-firered}" root="${3:-.}"
  local dest="$save_dir/$game" src
  [ -f "$dest/rom-cache.complete" ] && return 0
  src="$(gen3_cache_dir "$game" "$root")" || return 1
  mkdir -p "$save_dir"
  rm -rf "$dest"
  cp -cR "$src" "$dest" 2>/dev/null || cp -R "$src" "$dest" || return 1
  echo "  seeded the $game cache into $(basename "$save_dir") from $src"
  return 0
}
