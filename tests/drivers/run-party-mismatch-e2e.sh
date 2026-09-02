#!/usr/bin/env bash
#
# Party-size mismatch e2e: five LOVE instances + Node hub.
# Party of 3 vs party of 2 → spoken mismatch, ask cleared, no battle.
#
#   bash mods/rby_mmo/tests/drivers/run-party-mismatch-e2e.sh

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

ROLES=(a b c d e)
MAX="${MMO_HUB_MAX:-8}"
RUN_ID="${MMO_RUN_ID:-$$}"
HUB_LOG="/tmp/rby_mmo_mismatch_server_$$.log"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_mismatch_shots-$RUN_ID}"
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_mismatch_sync-$RUN_ID}"
TIMEOUT="${MMO_TIMEOUT:-900}"

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH"
command -v node >/dev/null 2>&1 || fail "node is not on PATH"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
[ -d "$MOD_DIR" ] || fail "$MOD_DIR is missing"
[ -f "$HUB_CLI" ] || fail "$HUB_CLI is missing"
[ -d data/generated ] || fail "no data/generated -- import a ROM first"

check_rom_config || exit 2

rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

HUB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/rby_mmo_mismatch_cfg.XXXXXX")"
HUB_CONFIG="$HUB_HOME/config.json"

stop_hub() { [ -n "${HUB_PID:-}" ] && kill "$HUB_PID" 2>/dev/null; }

cleanup() {
  rm -rf "$SYNC_DIR" 2>/dev/null
  for role in "${ROLES[@]}"; do
    local_pid="PID_${role}"; [ -n "${!local_pid:-}" ] && kill "${!local_pid}" 2>/dev/null
    local_save="SAVE_${role}"; [ -n "${!local_save:-}" ] && rm -rf "${!local_save}"
  done
  stop_hub; rm -rf "$HUB_HOME"
}
trap cleanup EXIT

hub_cli() { node "$HUB_CLI" --config "$HUB_CONFIG" "$@"; }

port_free() {
  node -e '
    const net = require("node:net");
    const s = net.createServer();
    s.once("error", () => process.exit(1));
    s.listen(Number(process.argv[1]), "127.0.0.1", () => s.close(() => process.exit(0)));
  ' "$1" 2>/dev/null
}

PORT="${MMO_HUB_PORT:-}"
if [ -z "$PORT" ]; then
  base=$(( 8260 + ($$ % 150) ))
  for offset in $(seq 0 60); do
    candidate=$(( base + offset ))
    port_free "$candidate" && PORT="$candidate" && break
  done
  [ -n "$PORT" ] || fail "could not find a free port"
fi
HUB_ADDRESS="127.0.0.1:$PORT"

# Loopback e2e: every LOVE shares 127.0.0.1, so the per-address cap must
# cover the whole party (default 4 refuses the 5th guest).
hub_cli init --yes --host 127.0.0.1 --port "$PORT" --max "$MAX" \
  --per-ip "$MAX" --log-level info >"$HUB_LOG" 2>&1 || exit 1
JOIN_CODE="$(hub_cli invite list --reveal 2>/dev/null \
  | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }')"
[ ${#JOIN_CODE} -eq 6 ] || fail "could not read join code"

node "$HUB_CLI" --config "$HUB_CONFIG" start >>"$HUB_LOG" 2>&1 &
HUB_PID=$!
for _ in $(seq 1 60); do
  grep -q 'RBY MMO hub listening on' "$HUB_LOG" 2>/dev/null && break
  sleep 1
done

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
  local dir="$(save_dir_for "$1")"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$HUB_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}

SPRITE_a="${MMO_A_SPRITE:-SPRITE_RED}"
SPRITE_b="${MMO_B_SPRITE:-SPRITE_COOLTRAINER_M}"
SPRITE_c="${MMO_C_SPRITE:-SPRITE_COOLTRAINER_F}"
SPRITE_d="${MMO_D_SPRITE:-SPRITE_BUG_CATCHER}"
SPRITE_e="${MMO_E_SPRITE:-SPRITE_YOUNGSTER}"

for role in "${ROLES[@]}"; do
  sprite_var="SPRITE_${role}"
  id="mmomismatch-${role}-$RUN_ID"
  printf -v "ID_${role}" '%s' "$id"
  printf -v "SAVE_${role}" '%s' "$(enable_mod_for "$id" "${!sprite_var}")"
done
rm -rf "$PROBE"

[ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ] && export POKEPORT_IMPORT_ROM="$ROM_PATH"

# Five LOVE.app windows racing one GPU context on macOS leave four of them
# with empty logs and the fifth hanging on a rendezvous that never comes.
# Boot each until it prints "game loaded", then start the next.
echo "  launching 5 LOVE guests on $HUB_ADDRESS"
for role in "${ROLES[@]}"; do
  id_var="ID_${role}"
  log="/tmp/rby_mmo_mismatch_${role}_$$.log"
  printf -v "LOG_${role}" '%s' "$log"
  echo "  starting guest $role..."
  if command -v stdbuf >/dev/null 2>&1; then
    MMO_ROLE="$role" MMO_HUB_CODE="$JOIN_CODE" SHOT_DIR="$SHOT_DIR" \
      MMO_SYNC_DIR="$SYNC_DIR" POKEPORT_IDENTITY="${!id_var}" \
      POKEPORT_DRIVER="$DRIVERS/mmo_mismatch.lua" \
      stdbuf -oL -eL love . >"$log" 2>&1 &
  else
    MMO_ROLE="$role" MMO_HUB_CODE="$JOIN_CODE" SHOT_DIR="$SHOT_DIR" \
      MMO_SYNC_DIR="$SYNC_DIR" POKEPORT_IDENTITY="${!id_var}" \
      POKEPORT_DRIVER="$DRIVERS/mmo_mismatch.lua" love . >"$log" 2>&1 &
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
  pid_var="PID_${role}"; kill "${!pid_var}" 2>/dev/null; wait "${!pid_var}" 2>/dev/null
done
stop_hub

total_incomplete=0
total_fail=0
for role in "${ROLES[@]}"; do
  log_var="LOG_${role}"
  upper=$(echo "$role" | tr '[:lower:]' '[:upper:]')
  echo "  ---- guest $role ----"
  grep -E "MMO_MISMATCH_${upper}:|TIMEOUT" "${!log_var}" | sed 's/^/  /'
  f=$(grep -c "MMO_MISMATCH_${upper}:.*FAIL" "${!log_var}" 2>/dev/null || true); f=${f:-0}
  d=$(grep -c "MMO_MISMATCH_${upper}:.*DONE" "${!log_var}" 2>/dev/null || true); d=${d:-0}
  total_fail=$(( total_fail + f ))
  [ "$d" -ne 1 ] && total_incomplete=$(( total_incomplete + 1 ))
done

if [ "$total_incomplete" -ne 0 ]; then
  echo "  RESULT: incomplete -- $total_incomplete of 5 never reached DONE."
  exit 1
fi
if [ "$total_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $total_fail guest failure(s)."
  exit 1
fi
echo "  RESULT: party-size mismatch e2e passed. Screenshots in $SHOT_DIR"
exit 0
