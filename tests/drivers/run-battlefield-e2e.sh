#!/usr/bin/env bash
#
# Battlefield theatre e2e (Gen1 top-down arena).
#
# Captures co-op NPC / mediated frames once LOVE drivers can screenshot the
# 640×360 fill surface. Until that hook lands, this script:
#   1. Confirms the arena asset packs with the mod
#   2. Points at the live playtest checklist in docs/plans/coop-battlefield-layout.md
#   3. Optionally forwards to run-hub-e2e.sh when --play is passed
#
# From the Gen1Recomp checkout root (mods/rby_mmo → this repo):
#
#   bash mods/rby_mmo/tests/drivers/run-battlefield-e2e.sh
#   bash mods/rby_mmo/tests/drivers/run-battlefield-e2e.sh --play
#
set -euo pipefail
cd "$(dirname "$0")/../../../.." || exit 1
MOD_DIR="mods/rby_mmo"
ARENA="$MOD_DIR/assets/battle/outdoor_grass_arena.png"
OUT="mods/rby_mmo/tmp/e2e-battlefield"
mkdir -p "$OUT"

if [[ ! -f "$ARENA" ]]; then
  echo "missing arena asset: $ARENA" >&2
  exit 1
fi

# Asset sanity (packed with the mod; not under docs/screenshots).
bytes=$(wc -c < "$ARENA" | tr -d ' ')
echo "arena: $ARENA ($bytes bytes)"
if [[ "$bytes" -gt 2000000 ]]; then
  echo "warn: arena PNG is large (>2MB); consider re-encoding before pack" >&2
fi

# Headless layout smoke via the mod suite subset is the automated bar today.
echo "running battlefield-related Lua suite…"
luajit "$MOD_DIR/tests/rby_mmo_test.lua" | tee "$OUT/suite.tail.txt" | tail -5

echo
echo "Live playtest checklist (owner):"
echo "  docs/plans/coop-battlefield-layout.md §5"
echo "Screenshot drop dir: $OUT/"
echo

if [[ "${1:-}" == "--play" ]]; then
  echo "forwarding to hub e2e for a live two-client fight…"
  exec bash "$MOD_DIR/tests/drivers/run-hub-e2e.sh"
fi

echo "OK — asset present; suite green. Pass --play to launch hub e2e."
exit 0
