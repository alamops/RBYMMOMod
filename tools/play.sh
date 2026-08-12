#!/usr/bin/env bash
#
# Launch the game with this mod on, and no manual step.
#
#   bash mods/rby_mmo/tools/play.sh            # Gen 1 (ROM_PATH)
#   bash mods/rby_mmo/tools/play.sh gold       # Gen 2 Gold (GOLD_ROM_PATH)
#   bash mods/rby_mmo/tools/play.sh guest      # a second Gen 1 save identity
#   bash mods/rby_mmo/tools/play.sh gold-guest # a second Gold save identity
#
# What this exists to skip:
#
#   * The launcher's ROM screen. An interactive `love .` always shows it
#     (main.lua only bypasses it for a scripted run), so every launch means
#     clicking Import ROM. Setting POKEPORT_IMPORT_ROM makes the engine
#     import and boot straight in -- that env var is the engine's own
#     supported route, not a trick.
#   * Enabling the mod when options pin it off. From 1.0.0 it is not
#     experimental (on by default when present); drivers and this script still
#     write options.lua so a fresh LOVE identity is explicit.
#
# Gen 1: ROM_PATH + ROM_VERSION from mods/rby_mmo/.env
# Gen 2: GOLD_ROM_PATH (+ GOLD_ROM_VERSION=gold) — see .env.example.
#
# Gold is imported by the engine (RomExtractorGen2), not tools/build_data.py.
# The first Gold boot writes gold/data/generated/ under the LOVE identity.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOD_DIR="mods/rby_mmo"
cd "$HERE/../../.." || exit 1

# shellcheck source=/dev/null
. "$HERE/env.sh"

fail() { echo "  !! $*" >&2; exit 2; }

[ -f main.lua ] || fail "run this from a Gen1Recomp checkout with the mod linked in"
command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"

load_env "$MOD_DIR/.env"

MODE="${1:-}"
case "$MODE" in
  gold|gold-guest)
    check_gold_rom_config || exit 2
    VERSION=gold
    ROM_FILE="${GOLD_ROM_PATH:-}"
    if [ "$MODE" = gold-guest ]; then
      IDENTITY="${POKEPORT_IDENTITY:-rby-mmo-gold-guest}"
    else
      IDENTITY="${POKEPORT_IDENTITY:-rby-mmo-gold}"
    fi
    ;;
  guest)
    check_rom_config || exit 2
    VERSION="${ROM_VERSION:-red}"
    ROM_FILE="${ROM_PATH:-}"
    IDENTITY="${POKEPORT_IDENTITY:-rby-mmo-guest}"
    ;;
  ""|host)
    check_rom_config || exit 2
    VERSION="${ROM_VERSION:-red}"
    ROM_FILE="${ROM_PATH:-}"
    IDENTITY="${POKEPORT_IDENTITY:-rby-mmo}"
    ;;
  *)
    # Treat an unknown first arg as a custom LOVE identity (legacy).
    check_rom_config || exit 2
    VERSION="${ROM_VERSION:-red}"
    ROM_FILE="${ROM_PATH:-}"
    IDENTITY="$MODE"
    ;;
esac

# Enable the mod for this identity. options.lua is the same file the mod
# manager writes, so this is the switch the player would flip by hand.
PROBE="$(mktemp -d)"
cat > "$PROBE/conf.lua" <<'PROBE_CONF'
function love.conf(t)
  t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
  t.window = false
end
PROBE_CONF
cat > "$PROBE/main.lua" <<'PROBE_MAIN'
function love.load()
  print("SAVEDIR=" .. tostring(love.filesystem.getSaveDirectory()))
  love.event.quit()
end
PROBE_MAIN
SAVE_DIR="$(POKEPORT_IDENTITY="$IDENTITY" love "$PROBE" 2>/dev/null \
  | sed -n 's/^SAVEDIR=//p' | head -1)"
rm -rf "$PROBE"
[ -n "$SAVE_DIR" ] || fail "could not work out LOVE's save directory"

mkdir -p "$SAVE_DIR"
if [ -f "$SAVE_DIR/options.lua" ]; then
  # Never clobber a real save's options -- that would throw away settings and
  # any other mod's enable state. Only write the file when creating it.
  grep -q 'rby_mmo' "$SAVE_DIR/options.lua" \
    || echo "  note: $SAVE_DIR/options.lua exists; enable RBY MMO in the mod manager (F10) if it is off"
else
  printf 'return { mods = { rby_mmo = true } }\n' > "$SAVE_DIR/options.lua"
  echo "  enabled the mod for identity '$IDENTITY'"
fi

echo "  identity: $IDENTITY   version: $VERSION"
if [ -n "$ROM_FILE" ] && [ -f "$ROM_FILE" ]; then
  echo "  importing/booting with $(basename "$ROM_FILE") -- no launcher"
  exec env POKEPORT_IDENTITY="$IDENTITY" POKEPORT_VERSION="$VERSION" \
    POKEPORT_IMPORT_ROM="$ROM_FILE" love .
fi

if [ "$VERSION" = gold ]; then
  echo "  no usable GOLD_ROM_PATH; the launcher will ask for a Gold ROM"
else
  echo "  no usable ROM_PATH; the launcher will ask for a ROM"
fi
exec env POKEPORT_IDENTITY="$IDENTITY" POKEPORT_VERSION="$VERSION" love .
