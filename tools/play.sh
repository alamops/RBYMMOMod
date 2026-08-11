#!/usr/bin/env bash
#
# Launch the game with this mod on, and no manual step.
#
#   bash mods/rby_mmo/tools/play.sh            # normal play
#   bash mods/rby_mmo/tools/play.sh guest      # a second, separate save
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
# ROM_PATH and ROM_VERSION come from mods/rby_mmo/.env -- see .env.example.

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
check_rom_config || exit 2

IDENTITY="${1:-${POKEPORT_IDENTITY:-rby-mmo}}"
VERSION="${ROM_VERSION:-red}"

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
if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
  echo "  importing/booting with $(basename "$ROM_PATH") -- no launcher"
  exec env POKEPORT_IDENTITY="$IDENTITY" POKEPORT_VERSION="$VERSION" \
    POKEPORT_IMPORT_ROM="$ROM_PATH" love .
fi

echo "  no usable ROM_PATH; the launcher will ask for a ROM"
exec env POKEPORT_IDENTITY="$IDENTITY" POKEPORT_VERSION="$VERSION" love .
