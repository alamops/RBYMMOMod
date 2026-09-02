#!/usr/bin/env bash
#
# End-to-end test for 3-on-3 party PvP: a real Node hub and SIX real LOVE
# instances. Two parties of three, all JOIN, no in-game host.
#
#   bash mods/rby_mmo/tests/drivers/run-hex-e2e.sh
#
# Requires a ROM imported (scripts/setup.sh --rom ...). Six windows drive
# themselves -- do not click into them.

set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 1

MOD_DIR="mods/rby_mmo"
ENV_FILE="$MOD_DIR/.env"
# shellcheck source=/dev/null
. "$MOD_DIR/tools/env.sh"
load_env "$ENV_FILE"
load_canon_env
DRIVERS="$MOD_DIR/tests/drivers"
HUB_CLI="$MOD_DIR/server/bin/rby-mmo-hub.js"

ROLES=(a b c d e f)
MAX="${MMO_HUB_MAX:-8}"
RUN_ID="${MMO_RUN_ID:-$$}"
HUB_LOG="/tmp/rby_mmo_hex_server_$$.log"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_hex_shots-$RUN_ID}"
SYNC_OWNED=$([ -n "${MMO_SYNC_DIR:-}" ] && echo 0 || echo 1)
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_hex_sync-$RUN_ID}"
TIMEOUT="${MMO_TIMEOUT:-5400}"

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
command -v node >/dev/null 2>&1 || fail "node is not on PATH"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
[ -d "$MOD_DIR" ] || fail "$MOD_DIR is missing -- symlink the mod into mods/"
[ -f "$HUB_CLI" ] || fail "$HUB_CLI is missing"
[ -d data/generated ] || fail "no data/generated -- import a ROM first
     scripts/setup.sh --rom \"/path/to/rom.gb\", or set ROM_PATH in $ENV_FILE"

check_rom_config || exit 2

for role in "${ROLES[@]}"; do rm -f "/tmp/rby_mmo_hex_${role}_$$.log"; done
rm -f "$HUB_LOG"
rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

HUB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/rby_mmo_hex_cfg.XXXXXX")" \
  || fail "could not make a scratch directory for the hub's config"
HUB_CONFIG="$HUB_HOME/config.json"

stop_hub() {
  [ -n "${HUB_PID:-}" ] || return 0
  kill "$HUB_PID" 2>/dev/null
  for _ in 1 2 3 4 5; do
    kill -0 "$HUB_PID" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$HUB_PID" 2>/dev/null
}

cleanup() {
  if [ "${SYNC_OWNED:-0}" = "1" ] && [ -n "${SYNC_DIR:-}" ]; then
    rm -rf "$SYNC_DIR" 2>/dev/null
  fi
  for role in "${ROLES[@]}"; do
    local_pid="PID_${role}"
    [ -n "${!local_pid:-}" ] && kill "${!local_pid}" 2>/dev/null
    local_save="SAVE_${role}"
    [ -n "${!local_save:-}" ] && rm -rf "${!local_save}"
  done
  stop_hub
  [ -n "${HUB_HOME:-}" ] && rm -rf "$HUB_HOME"
}
trap cleanup EXIT

hub_cli() { node "$HUB_CLI" --config "$HUB_CONFIG" "$@"; }

port_free() {
  node -e '
    const net = require("node:net");
    const server = net.createServer();
    server.once("error", () => process.exit(1));
    server.listen(Number(process.argv[1]), "127.0.0.1",
      () => server.close(() => process.exit(0)));
  ' "$1" 2>/dev/null
}

PORT="${MMO_HUB_PORT:-}"
if [ -z "$PORT" ]; then
  base=$(( 8060 + ($$ % 150) ))
  for offset in $(seq 0 60); do
    candidate=$(( base + offset ))
    if port_free "$candidate"; then PORT="$candidate"; break; fi
  done
  [ -n "$PORT" ] || fail "could not find a free port in $base..$(( base + 60 ))"
elif ! port_free "$PORT"; then
  fail "MMO_HUB_PORT=$PORT is already in use"
fi
HUB_ADDRESS="127.0.0.1:$PORT"

# Loopback e2e: every LOVE shares 127.0.0.1, so the per-address cap must
# cover all six guests (default 4 refuses the 5th).
if ! hub_cli init --yes --host 127.0.0.1 --port "$PORT" --max "$MAX" \
     --per-ip "$MAX" --log-level info >"$HUB_LOG" 2>&1; then
  echo "  !! rby-mmo-hub init failed:" >&2
  tail -20 "$HUB_LOG" >&2
  exit 1
fi

JOIN_CODE="$(hub_cli invite list --reveal 2>/dev/null \
  | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }')"
[ ${#JOIN_CODE} -eq 6 ] || fail "could not read a join code back out of $HUB_CONFIG"

node "$HUB_CLI" --config "$HUB_CONFIG" start >>"$HUB_LOG" 2>&1 &
HUB_PID=$!

READY='RBY MMO hub listening on'
for _ in $(seq 1 60); do
  grep -q "$READY" "$HUB_LOG" 2>/dev/null && break
  kill -0 "$HUB_PID" 2>/dev/null || break
  sleep 1
done
grep -q "$READY" "$HUB_LOG" 2>/dev/null || {
  echo "  !! the hub never started listening. Its log:" >&2
  tail -30 "$HUB_LOG" >&2
  exit 1
}

EXTRA_MODS=""
for id in ${MMO_WITH_MODS:-}; do EXTRA_MODS="$EXTRA_MODS, $id = true"; done
for id in ${MMO_WITHOUT_MODS:-}; do EXTRA_MODS="$EXTRA_MODS, $id = false"; done

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

save_dir_for() {
  POKEPORT_IDENTITY="$1" love "$PROBE" 2>/dev/null \
    | sed -n 's/^SAVEDIR=//p' | head -1
}

enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true%s }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$EXTRA_MODS" "$HUB_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}

SPRITE_a="${MMO_A_SPRITE:-SPRITE_RED}"
SPRITE_b="${MMO_B_SPRITE:-SPRITE_COOLTRAINER_M}"
SPRITE_c="${MMO_C_SPRITE:-SPRITE_COOLTRAINER_F}"
SPRITE_d="${MMO_D_SPRITE:-SPRITE_BUG_CATCHER}"
SPRITE_e="${MMO_E_SPRITE:-SPRITE_YOUNGSTER}"
SPRITE_f="${MMO_F_SPRITE:-SPRITE_LASS}"

for role in "${ROLES[@]}"; do
  sprite_var="SPRITE_${role}"
  id="mmohex-${role}-$RUN_ID"
  printf -v "ID_${role}" '%s' "$id"
  dir="$(enable_mod_for "$id" "${!sprite_var}")"
  printf -v "SAVE_${role}" '%s' "$dir"
done
rm -rf "$PROBE"

if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$ROM_PATH"
  export POKEPORT_VERSION="${ROM_VERSION:-red}"
fi

echo "  launching 6 LOVE guests on $HUB_ADDRESS"
for role in "${ROLES[@]}"; do
  id_var="ID_${role}"
  log="/tmp/rby_mmo_hex_${role}_$$.log"
  printf -v "LOG_${role}" '%s' "$log"
  echo "  starting guest $role..."
  if command -v stdbuf >/dev/null 2>&1; then
    MMO_ROLE="$role" MMO_JOIN_ADDRESS="$HUB_ADDRESS" MMO_HUB_CODE="$JOIN_CODE" \
      SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" \
      POKEPORT_IDENTITY="${!id_var}" POKEPORT_DRIVER="$DRIVERS/mmo_hex.lua" \
      stdbuf -oL -eL love . >"$log" 2>&1 &
  else
    MMO_ROLE="$role" MMO_JOIN_ADDRESS="$HUB_ADDRESS" MMO_HUB_CODE="$JOIN_CODE" \
      SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" \
      POKEPORT_IDENTITY="${!id_var}" POKEPORT_DRIVER="$DRIVERS/mmo_hex.lua" \
      love . >"$log" 2>&1 &
  fi
  printf -v "PID_${role}" '%s' "$!"
  pid_var="PID_${role}"
  booted=0
  for _ in $(seq 1 60); do
    grep -q "game loaded" "$log" 2>/dev/null && { booted=1; break; }
    kill -0 "${!pid_var}" 2>/dev/null || fail "guest $role exited before boot (see $log)"
    sleep 1
  done
  [ "$booted" = "1" ] || fail "guest $role never printed game loaded (see $log)"
done

for _ in $(seq 1 "$TIMEOUT"); do
  all_done=1
  any_alive=0
  for role in "${ROLES[@]}"; do
    log_var="LOG_${role}"; pid_var="PID_${role}"
    grep -q "DONE" "${!log_var}" 2>/dev/null || all_done=0
    kill -0 "${!pid_var}" 2>/dev/null && any_alive=1
  done
  [ "$all_done" = "1" ] && break
  [ "$any_alive" = "0" ] && break
  sleep 1
done

for role in "${ROLES[@]}"; do
  pid_var="PID_${role}"
  kill "${!pid_var}" 2>/dev/null
  wait "${!pid_var}" 2>/dev/null
done
stop_hub
wait "$HUB_PID" 2>/dev/null

count() { grep -c "$1" "$2" 2>/dev/null | head -1 || true; }

total_fail=0
total_incomplete=0
for role in "${ROLES[@]}"; do
  log_var="LOG_${role}"
  upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  echo
  echo "  ---- guest $role ----"
  grep -E "MMO_HEX_${upper}:|TIMEOUT" "${!log_var}" | sed 's/^/  /'
  f=$(count "MMO_HEX_${upper}:.*FAIL" "${!log_var}"); f=${f:-0}
  d=$(count "MMO_HEX_${upper}:.*DONE" "${!log_var}"); d=${d:-0}
  total_fail=$(( total_fail + f ))
  [ "$d" -ne 1 ] && total_incomplete=$(( total_incomplete + 1 ))
done

hub_fail=0
hub_drops=$(count 'refused a relayed message' "$HUB_LOG"); hub_drops=${hub_drops:-0}
hub_errors=$(count ' ERROR ' "$HUB_LOG"); hub_errors=${hub_errors:-0}

echo
echo "  ---- hub ----"
echo "  relay drops: $hub_drops   errors: $hub_errors"
[ "$hub_drops" -ne 0 ] && hub_fail=$((hub_fail + 1))
[ "$hub_errors" -ne 0 ] && hub_fail=$((hub_fail + 1))

if [ "$total_incomplete" -ne 0 ]; then
  echo "  RESULT: incomplete -- $total_incomplete of 6 never reached DONE."
  exit 1
fi
if [ "$total_fail" -ne 0 ] || [ "$hub_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $total_fail guest + $hub_fail hub failure(s)."
  exit 1
fi
echo "  RESULT: six-client 3-on-3 party PvP passed. Screenshots in $SHOT_DIR"
exit 0
