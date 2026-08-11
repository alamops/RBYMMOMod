#!/usr/bin/env bash
#
# Gen 2 end-to-end smoke (TT5 stub): Gold boot + Gen 2 hub.
#
# Peer to tests/drivers/run-mmo-e2e.sh (Gen 1). This variant locks the hub at
# `--generation 2` and boots Gold. Full presence / chat / mediated battle /
# trade-with-mail / co-op coverage is the same driver family once a Gold
# cache exists; until then this script exits 0 with a clear skip so CI and
# ROM-less checkouts stay green.
#
#   Run from the Gen1Recomp checkout root, with this mod linked into mods/:
#
#     bash mods/rby_mmo/tests/drivers/run-mmo-e2e-gen2.sh
#
# Hub (equal peer to Gen 1):
#
#     node mods/rby_mmo/server/hub.js --generation 2
#
# Requires a Gold ROM import (landmarks.lua is the cheap cache probe — Gen 1
# extracts do not write it). Import once, then rerun:
#
#     scripts/setup.sh --rom "/path/to/Pokemon Gold.gbc"   # or build_data
#     # .env: ROM_PATH=...  ROM_VERSION=gold
#
# When the Gold cache is present this currently documents the recipe and
# exits 0 with "pending" — wire the LOVE host/guest drivers here the same
# way run-mmo-e2e.sh does once the Gen 2 e2e legs are ready. Do not fail a
# machine that only has Red imported.

set -uo pipefail

# Prefer the engine checkout (main.lua + mods/) whether invoked via the
# mods/rby_mmo symlink or as an absolute path into an agetor worktree.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT=""
probe="$SCRIPT_DIR"
for _ in 1 2 3 4 5 6 7 8; do
  if [ -f "$probe/main.lua" ] && [ -d "$probe/mods" ]; then
    ENGINE_ROOT="$probe"
    break
  fi
  probe="$(dirname "$probe")"
done
if [ -z "$ENGINE_ROOT" ] && [ -f "$HOME/Projects/alamops/gen1recomp/main.lua" ]; then
  ENGINE_ROOT="$HOME/Projects/alamops/gen1recomp"
fi
if [ -z "$ENGINE_ROOT" ]; then
  echo "  !! could not find Gen1Recomp checkout (main.lua + mods/)" >&2
  exit 2
fi
cd "$ENGINE_ROOT" || exit 1

MOD_DIR="mods/rby_mmo"
# When the symlink points elsewhere, still find this stub's mod tree for docs.
MOD_REAL="$SCRIPT_DIR/../.."
ENV_FILE="$MOD_DIR/.env"
if [ ! -f "$ENV_FILE" ] && [ -f "$MOD_REAL/.env" ]; then
  ENV_FILE="$MOD_REAL/.env"
fi

if [ -f "$MOD_DIR/tools/env.sh" ]; then
  # shellcheck source=/dev/null
  . "$MOD_DIR/tools/env.sh"
  load_env "$ENV_FILE" 2>/dev/null || true
elif [ -f "$MOD_REAL/tools/env.sh" ]; then
  # shellcheck source=/dev/null
  . "$MOD_REAL/tools/env.sh"
  load_env "$ENV_FILE" 2>/dev/null || true
fi

echo "  rby_mmo Gen 2 e2e (hub --generation 2, Gold boot)"
echo "  engine: $ENGINE_ROOT"

fail() { echo "  !! $*" >&2; exit 2; }

[ -f main.lua ] || fail "engine root missing main.lua"
if [ ! -d "$MOD_DIR" ] && [ ! -d "$MOD_REAL/src" ]; then
  fail "$MOD_DIR is missing -- symlink the mod into mods/"
fi

# Gold cache probe: landmarks.lua is written by the Gen 2 extractor only.
GOLD_MARKERS=(
  "data/generated/landmarks.lua"
  "data/generated/gold/landmarks.lua"
)
have_gold=0
for marker in "${GOLD_MARKERS[@]}"; do
  if [ -f "$marker" ]; then
    have_gold=1
    echo "  gold cache: found $marker"
    break
  fi
done

HUB_HINT="node ${MOD_DIR}/server/hub.js --generation 2"
if [ ! -f "$MOD_DIR/server/hub.js" ] && [ -f "$MOD_REAL/server/hub.js" ]; then
  HUB_HINT="node $MOD_REAL/server/hub.js --generation 2"
fi

if [ "$have_gold" -ne 1 ]; then
  echo "  SKIP: no Gold cache (no landmarks.lua under data/generated/)."
  echo "        Import Gold, set ROM_PATH + ROM_VERSION=gold in $ENV_FILE,"
  echo "        then rerun. Gen 1 e2e remains: bash $MOD_DIR/tests/drivers/run-mmo-e2e.sh"
  echo "  hub recipe when ready: $HUB_HINT"
  exit 0
fi

# Cache present: live LOVE dual-instance Gen 2 legs are not wired in this
# stub yet (docs/plans/gen2-compatibility.md TT5). Exit 0 so the skip/pending
# contract stays honest — do not claim a green e2e that did not run.
echo "  PENDING: Gold cache present, but Gen 2 LOVE host/guest drivers are"
echo "           not hooked here yet. Hub: $HUB_HINT"
echo "           Identity tip: POKEPORT_IDENTITY=... POKEPORT_VERSION=gold love ."
echo "  RESULT: skipped pending Gen 2 e2e wiring (exit 0)"
exit 0
