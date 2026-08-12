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
