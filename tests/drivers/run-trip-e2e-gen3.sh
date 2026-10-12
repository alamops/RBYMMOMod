#!/usr/bin/env bash
#
# Gen 3 trip e2e: one Node hub locked to generation 3 and three LOVE
# instances on it -- FireRed ALPHA (a), FireRed BETA (b) and Emerald CHARLIE
# (c) -- all joining through the real menus. Asserts region-scoped presence
# (ALPHA and BETA see each other in Pallet Town; CHARLIE in Littleroot is on
# everybody's roster and nobody's map), PLAYERS naming each place in its own
# region, chat across carts, a FireRed <-> Emerald trade (dex updated on
# both sides), and a cross-cart 1v1 (ALPHA's FireRed CHARMANDER asks
# CHARLIE's Emerald PIKACHU through PLAYERS > ACTIONS > BATTLE; the Node hub's
# BattleSim3 referees; the arena on both screens, mirrored results, both
# parties as they were). Screenshots: g3-<game>-<role>-<NN>-<leg>.png +
# index.html.
#
#   bash mods/rby_mmo/tests/drivers/run-trip-e2e-gen3.sh
#
# Needs a FireRed and an Emerald import (or FIRE_RED_ROM_PATH /
# EMERALD_ROM_PATH in .env); skips cleanly with neither. Env: SHOT_DIR,
# MMO_TIMEOUT (s), MMO_HUB_PORT, MMO_RUN_ID, GEN3_TRIP_GAMES ("firered
# firered emerald" -- the carts of a, b and c), GEN3_LEGS (comma list narrowing
# the run: chat, trade, battle; default all).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_ROOT=""
probe="$SCRIPT_DIR"
for _ in 1 2 3 4 5 6 7 8; do
  if [ -f "$probe/main.lua" ] && [ -d "$probe/mods" ]; then ENGINE_ROOT="$probe"; break; fi
  probe="$(dirname "$probe")"
done
[ -n "$ENGINE_ROOT" ] || ENGINE_ROOT="$HOME/Projects/alamops/gen1recomp"
cd "$ENGINE_ROOT" || exit 1

MOD_DIR="mods/rby_mmo"
MOD_REAL="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE=""
for candidate in \
    "$MOD_DIR/.env" "$MOD_REAL/.env" \
    "${RBY_MMO_ENV:-$HOME/Projects/alamops/RBYMMOMod/.env}"; do
  if [ -f "$candidate" ]; then ENV_FILE="$candidate"; break; fi
done
: "${ENV_FILE:=$MOD_DIR/.env}"

fail() { echo "  !! $*" >&2; exit 2; }
ENV_SH=""
if [ -f "$MOD_DIR/tools/env.sh" ]; then ENV_SH="$MOD_DIR/tools/env.sh"
elif [ -f "$MOD_REAL/tools/env.sh" ]; then ENV_SH="$MOD_REAL/tools/env.sh"; fi
[ -n "$ENV_SH" ] || fail "tools/env.sh is missing from $MOD_REAL"
# shellcheck source=/dev/null
. "$ENV_SH"
load_env "$ENV_FILE" 2>/dev/null || true
load_canon_env 2>/dev/null || true

DRIVERS="$MOD_DIR/tests/drivers"
[ -f "$DRIVERS/mmo_trip_gen3.lua" ] || DRIVERS="$MOD_REAL/tests/drivers"
HUB_CLI="$MOD_DIR/server/bin/rby-mmo-hub.js"
[ -f "$HUB_CLI" ] || HUB_CLI="$MOD_REAL/server/bin/rby-mmo-hub.js"

command -v love >/dev/null 2>&1 || fail "love is not on PATH"
command -v node >/dev/null 2>&1 || fail "node is not on PATH (the hub is server/bin/rby-mmo-hub.js)"
[ -f "$DRIVERS/mmo_trip_gen3.lua" ] || fail "missing mmo_trip_gen3.lua"

ROLES=(a b c)
read -r -a TRIP_GAMES <<< "${GEN3_TRIP_GAMES:-firered firered emerald}"
[ "${#TRIP_GAMES[@]}" -eq 3 ] || fail "GEN3_TRIP_GAMES needs three carts (got '${GEN3_TRIP_GAMES:-}')"
GAME_a="${TRIP_GAMES[0]}"; GAME_b="${TRIP_GAMES[1]}"; GAME_c="${TRIP_GAMES[2]}"

# Each distinct cart: a cache somewhere, or an import now, or a clean SKIP.
for game in $(printf '%s\n' "${TRIP_GAMES[@]}" | sort -u); do
  case "$game" in firered|leafgreen|emerald) ;; *) fail "unknown Gen 3 cart '$game'" ;; esac
  check_gen3_rom_config "$game" || fail "fix $(gen3_rom_key "$game") in $ENV_FILE"
  if ! have_gen3_cache "$game" "$ENGINE_ROOT"; then
    rom="$(gen3_rom_path "$game")"
    if [ -n "$rom" ] && [ -f "$rom" ]; then
      echo "  no $game cache yet; importing $(basename "$rom")"
      POKEPORT_IDENTITY="rby-mmo-g3-import-$game-$$" POKEPORT_VERSION="$game" \
        POKEPORT_IMPORT_ROM="$rom" POKEPORT_IMPORT_ONLY=1 love . \
        || fail "$game import failed -- expected SHA-1 $(gen3_rom_sha "$game")"
      have_gen3_cache "$game" "$ENGINE_ROOT" || fail "the $game import left no rom-cache.complete"
    else
      echo "  SKIP: no $game cache and no usable $(gen3_rom_key "$game")."
      echo "        In $ENV_FILE set $(gen3_rom_key "$game")=/path/to/the/cart.gba"
      exit 0
    fi
  fi
  echo "  $game cache: $(gen3_cache_dir "$game" "$ENGINE_ROOT")"
done

MAX="${MMO_HUB_MAX:-6}"
RUN_ID="${MMO_RUN_ID:-$$}"
HUB_LOG="/tmp/rby_mmo_trip_gen3_server_$$.log"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_trip_gen3_shots-$RUN_ID}"
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_trip_gen3_sync-$RUN_ID}"
TIMEOUT="${MMO_TIMEOUT:-1500}"
export GEN3_LEGS="${GEN3_LEGS:-all}"

rm -rf "${SYNC_DIR:?}"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

HUB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/rby_mmo_trip_gen3_cfg.XXXXXX")"
HUB_CONFIG="$HUB_HOME/config.json"

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  for role in "${ROLES[@]}"; do
    local_pid="PID_${role}"; [ -n "${!local_pid:-}" ] && kill "${!local_pid}" 2>/dev/null
  done
  [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null
  for role in "${ROLES[@]}"; do
    local_save="SAVE_${role}"; [ -n "${!local_save:-}" ] && rm -rf "${!local_save:?}"
  done
  rm -rf "${SYNC_DIR:?}" 2>/dev/null
  [ -n "${HUB_HOME:-}" ] && rm -rf "${HUB_HOME:?}"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

hub_cli() { node "$HUB_CLI" --config "$HUB_CONFIG" "$@"; }

PORT="${MMO_HUB_PORT:-}"
if [ -z "$PORT" ]; then
  base=$(( 8660 + ($$ % 150) ))
  for offset in $(seq 0 60); do
    candidate=$(( base + offset ))
    node -e "const n=require('node:net').createServer();n.once('error',()=>process.exit(1));n.listen($candidate,'127.0.0.1',()=>n.close(()=>process.exit(0)))" \
      2>/dev/null && PORT="$candidate" && break
  done
  [ -n "$PORT" ] || fail "could not find a free port"
fi
HUB_ADDRESS="127.0.0.1:$PORT"

hub_cli init --yes --host 127.0.0.1 --port "$PORT" --max "$MAX" \
  --generation 3 --per-ip "$MAX" --log-level info >"$HUB_LOG" 2>&1 \
  || { cat "$HUB_LOG" >&2; fail "hub init --generation 3 failed"; }
JOIN_CODE="$(hub_cli invite list --reveal 2>/dev/null \
  | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }')"
[ -n "$JOIN_CODE" ] || fail "the hub minted no join code"

node "$HUB_CLI" --config "$HUB_CONFIG" start >>"$HUB_LOG" 2>&1 &
HUB_PID=$!
up=0
for _ in $(seq 1 60); do
  grep -q 'RBY MMO hub listening on' "$HUB_LOG" 2>/dev/null && { up=1; break; }
  kill -0 "$HUB_PID" 2>/dev/null || break
  sleep 1
done
[ "$up" = "1" ] || { tail -20 "$HUB_LOG" >&2; fail "the hub never listened"; }
echo "  hub up at $HUB_ADDRESS (generation 3): $(grep -m1 -i 'generation' "$HUB_LOG" | tr -s ' ')"

PROBE="$(mktemp -d)"
cat > "$PROBE/conf.lua" <<'EOF'
function love.conf(t)
  t.identity = os.getenv("POKEPORT_IDENTITY") or "pokemon-love2d"
  t.window = false
end
EOF
cat > "$PROBE/main.lua" <<'EOF'
function love.load()
  print("SAVEDIR=" .. tostring(love.filesystem.getSaveDirectory()))
  love.event.quit()
end
EOF
save_dir_for() {
  POKEPORT_IDENTITY="$1" love "$PROBE" 2>/dev/null | sed -n 's/^SAVEDIR=//p' | head -1
}
enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$HUB_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}

SPRITE_a="${MMO_A_SPRITE:-OBJ_EVENT_GFX_RED_NORMAL}"
SPRITE_b="${MMO_B_SPRITE:-OBJ_EVENT_GFX_BLUE}"
SPRITE_c="${MMO_C_SPRITE:-OBJ_EVENT_GFX_MAY_NORMAL}"

for role in "${ROLES[@]}"; do
  game_var="GAME_${role}"; sprite_var="SPRITE_${role}"
  id="mmotrip-g3-${role}-$RUN_ID"
  printf -v "ID_${role}" '%s' "$id"
  dir="$(enable_mod_for "$id" "${!sprite_var}")"
  printf -v "SAVE_${role}" '%s' "$dir"
  seed_gen3_cache "$dir" "${!game_var}" "$ENGINE_ROOT" || fail "could not seed the ${!game_var} cache for $role"
done
rm -rf "$PROBE"

export POKEPORT_TOUCH=0
run_love() {
  if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL love . "$@"; else love . "$@"; fi
}

echo "  shots: $SHOT_DIR"
echo "  launching 3 LOVE guests on $HUB_ADDRESS (a=$GAME_a b=$GAME_b c=$GAME_c)"
for role in "${ROLES[@]}"; do
  id_var="ID_${role}"; game_var="GAME_${role}"
  log="/tmp/rby_mmo_trip_gen3_${role}_$$.log"
  printf -v "LOG_${role}" '%s' "$log"
  echo "  starting $role (${!game_var})..."
  MMO_ROLE="$role" MMO_HUB_CODE="$JOIN_CODE" SHOT_DIR="$SHOT_DIR" \
    MMO_SYNC_DIR="$SYNC_DIR" POKEPORT_IDENTITY="${!id_var}" POKEPORT_VERSION="${!game_var}" \
    POKEPORT_DRIVER="$DRIVERS/mmo_trip_gen3.lua" \
    run_love >"$log" 2>&1 &
  printf -v "PID_${role}" '%s' "$!"
  pid_var="PID_${role}"
  booted=0
  for _ in $(seq 1 90); do
    grep -qE "game loaded|loaded mod rby_mmo" "$log" 2>/dev/null && { booted=1; break; }
    kill -0 "${!pid_var}" 2>/dev/null || fail "$role exited before boot (see $log)"
    sleep 1
  done
  [ "$booted" = "1" ] || fail "$role never booted (see $log)"
done

for _ in $(seq 1 "$TIMEOUT"); do
  all_done=1
  any_alive=0
  for role in "${ROLES[@]}"; do
    log_var="LOG_${role}"; pid_var="PID_${role}"
    grep -q "MMO_TRIP_.*DONE" "${!log_var}" 2>/dev/null || all_done=0
    kill -0 "${!pid_var}" 2>/dev/null && any_alive=1
  done
  [ "$all_done" = "1" ] && break
  [ "$any_alive" = "0" ] && break
  sleep 1
done

for role in "${ROLES[@]}"; do
  pid_var="PID_${role}"; kill "${!pid_var}" 2>/dev/null; wait "${!pid_var}" 2>/dev/null
done
kill "$HUB_PID" 2>/dev/null

total_incomplete=0
total_fail=0
for role in "${ROLES[@]}"; do
  log_var="LOG_${role}"
  upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  echo "  ---- $role ----"
  grep -E "MMO_TRIP_${upper}:|TIMEOUT|driver error" "${!log_var}" | sed 's/^/  /'
  f=$(grep -c "MMO_TRIP_${upper}:.*FAIL" "${!log_var}" 2>/dev/null || true); f=${f:-0}
  o=$(grep -c "MMO_TRIP_${upper}:[[:space:]]ok " "${!log_var}" 2>/dev/null || true); o=${o:-0}
  d=$(grep -c "MMO_TRIP_${upper}:.*DONE" "${!log_var}" 2>/dev/null || true); d=${d:-0}
  echo "  checks $role: $o ok / $f FAIL"
  total_fail=$(( total_fail + f ))
  [ "$d" -ne 1 ] && total_incomplete=$(( total_incomplete + 1 ))
done

INDEXER="$DRIVERS/shots_index.py"
[ -f "$INDEXER" ] || INDEXER="$MOD_REAL/tests/drivers/shots_index.py"
if [ -f "$INDEXER" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$INDEXER" "$SHOT_DIR" | sed 's/^/  /'
fi

keep_logs() {
  echo "  logs kept: $LOG_a $LOG_b $LOG_c $HUB_LOG"
}
if [ "$total_incomplete" -ne 0 ]; then
  echo "  RESULT: incomplete -- $total_incomplete of 3 never reached DONE."
  keep_logs
  exit 1
fi
if [ "$total_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $total_fail failure(s)."
  keep_logs
  exit 1
fi
echo "  RESULT: Gen 3 three-client FireRed + Emerald run passed. Screenshots in $SHOT_DIR"
rm -f "$LOG_a" "$LOG_b" "$LOG_c" "$HUB_LOG"
exit 0
