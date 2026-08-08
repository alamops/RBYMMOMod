#!/usr/bin/env bash
# Build Red + Yellow link-surface extracts and assert MMO battle compat.
#
# Reads ROM_PATH / ROM_VERSION / SECONDARY_ROM_PATH / SECONDARY_ROM_VERSION
# from mods/rby_mmo/.env (or the environment). Skips cleanly when either
# ROM is missing -- CI has no cartridges.
#
# Run from the engine checkout root:
#   bash mods/rby_mmo/tests/drivers/run-red-yellow-battle-compat.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Prefer the engine root we were invoked from; fall back to walking up from
# the mod when this script is called by absolute path.
if [ -f "./tools/build_data.py" ]; then
  REPO="$(pwd)"
elif [ -f "$MOD_DIR/../../tools/build_data.py" ]; then
  REPO="$(cd "$MOD_DIR/../.." && pwd)"
else
  echo "run from the gen1recomp checkout root (tools/build_data.py not found)" >&2
  exit 2
fi

# shellcheck source=../../tools/env.sh
. "$MOD_DIR/tools/env.sh"
load_env "$MOD_DIR/.env"
if type check_rom_config >/dev/null 2>&1; then
  check_rom_config || true
fi

RED_ROM="${ROM_PATH:-}"
RED_VER="${ROM_VERSION:-red}"
YEL_ROM="${SECONDARY_ROM_PATH:-}"
YEL_VER="${SECONDARY_ROM_VERSION:-yellow}"

if [ -z "$RED_ROM" ] || [ ! -f "$RED_ROM" ]; then
  echo "skip: ROM_PATH missing or not a file -- no Red cartridge to extract"
  exit 0
fi
if [ -z "$YEL_ROM" ] || [ ! -f "$YEL_ROM" ]; then
  echo "skip: SECONDARY_ROM_PATH missing or not a file -- no Yellow cartridge"
  exit 0
fi

PY="${PYTHON:-python3}"
CACHE_ROOT="${TMPDIR:-/tmp}/rby-mmo-link-surface"
mkdir -p "$CACHE_ROOT"

# Cache key: version + ROM sha so a replaced file rebuilds.
slice_dir() {
  local ver="$1" rom="$2"
  local sha
  sha="$(shasum -a 1 "$rom" | cut -d' ' -f1)"
  echo "$CACHE_ROOT/${ver}-${sha:0:12}"
}

build_slice() {
  local ver="$1" rom="$2" out="$3"
  if [ -f "$out/pokemon.lua" ] && [ -f "$out/moves.lua" ] \
      && [ -f "$out/type_chart.lua" ] && [ -f "$out/constants.lua" ]; then
    echo "  reusing $out"
    return 0
  fi
  echo "  extracting $ver link surface from $(basename "$rom")"
  mkdir -p "$out"
  "$PY" "$REPO/tools/build_data.py" \
    --rom "$rom" --version "$ver" --out "$out" \
    --only pokemon --only moves --only type_chart --only constants
}

RED_OUT="$(slice_dir "$RED_VER" "$RED_ROM")"
YEL_OUT="$(slice_dir "$YEL_VER" "$YEL_ROM")"

echo "== red/yellow battle compat =="
echo "  repo: $REPO"
echo "  mod:  $MOD_DIR"
build_slice "$RED_VER" "$RED_ROM" "$RED_OUT"
build_slice "$YEL_VER" "$YEL_ROM" "$YEL_OUT"

cd "$REPO"
luajit "$MOD_DIR/tests/red_yellow_battle_compat.lua" \
  "$RED_OUT" "$YEL_OUT" "$MOD_DIR"
