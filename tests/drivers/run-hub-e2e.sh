#!/usr/bin/env bash
#
# End-to-end test for the dedicated hub: a real Node server, two real LOVE
# instances, two real windows, real sockets between all three.
#
# This is the row the coverage table was missing. server/*.test.js drives the
# hub with synthetic Node clients; tests/rby_mmo_test.lua drives src/Hub.lua
# with fake peers; run-mmo-e2e.sh drives a real client against the *in-game*
# host. Until this file, **no real game client had ever connected to
# server/bin/rby-mmo-hub.js.**
#
# The sharpest thing it buys is the join code. src/Sha256.lua is pinned
# against fixtures generated from Node; server/lib/auth.js is pinned against
# node:crypto. Both agree on the arithmetic. Neither proves the two ends agree
# on the *wiring* -- which field carries the nonce, whether the client
# normalises before hashing, whether the hub's nonce shape is what Wire.hex
# accepts. Get any of that wrong and every player on a dedicated hub sees
# "wrong join code" while every assertion in the suite stays green. So one
# instance types a wrong code first, is refused by Node, and then types the
# right one.
#
#   Run from the Gen1Recomp checkout root, with this mod linked into mods/:
#
#     bash mods/rby_mmo/tests/drivers/run-hub-e2e.sh
#
# Requires a ROM to have been imported already (scripts/setup.sh --rom ...);
# the engine cannot boot without data/generated/.
#
# Two windows will open and drive themselves. Leave them alone until it
# finishes -- clicking into them steals the input the drivers are queueing.
#
# NEITHER window hosts. Both take the JOIN path. That is the whole point:
# run-mmo-e2e.sh is the LAN scenario and stays exactly as it is.

set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 1

MOD_DIR="mods/rby_mmo"

# ---------------------------------------------------------------- .env
#
# Everything machine-specific lives in mods/rby_mmo/.env (gitignored; see
# .env.example): the ROM to import, which other mods to pin on or off. Loaded
# through the shared helper so this, run-mmo-e2e.sh and tools/play.sh cannot
# drift apart on how the file is read.
ENV_FILE="$MOD_DIR/.env"
# shellcheck source=/dev/null
. "$MOD_DIR/tools/env.sh"
load_env "$ENV_FILE"
DRIVERS="$MOD_DIR/tests/drivers"
HUB_CLI="$MOD_DIR/server/bin/rby-mmo-hub.js"

# Deliberately NOT 7788. The mod's default hub port is what an in-game host
# binds, so a leftover run-mmo-e2e.sh window would otherwise be silently
# joined instead of the Node hub -- and the run would pass while testing the
# wrong thing entirely. A non-default port also means this run exercises the
# `--port` config path rather than a default that happens to match.
PORT="${MMO_HUB_PORT:-7799}"
HUB_ADDRESS="127.0.0.1:$PORT"
# 4 is the hub's own default and is deliberately not trimmed to 2: role a
# dials twice (a wrong code, then the right one), and a cap that exactly fits
# the run would turn a seat released a moment late into "this hub is full" --
# a flake with nothing to do with what is being tested.
MAX="${MMO_HUB_MAX:-4}"

A_ID="mmohub-a-$$"
B_ID="mmohub-b-$$"
A_LOG="/tmp/rby_mmo_hub_a_$$.log"
B_LOG="/tmp/rby_mmo_hub_b_$$.log"
HUB_LOG="/tmp/rby_mmo_hub_server_$$.log"
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_hub_shots}"
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_hub_sync}"

# Wall-clock budget per phase (the hub coming up, then both sides reaching
# DONE).
#
# A backstop, not an expectation: the loop below exits the moment both sides
# print DONE, so a larger number costs a good run nothing. It has to clear the
# longest barrier in mmo_util's PHASE table for this scenario (hub_a_ready /
# hub_b_ready, 600s) with room, or the harness kills a run that was about to
# report properly and replaces a real verdict with "incomplete".
TIMEOUT="${MMO_TIMEOUT:-1200}"

# ------------------------------------------------------------------ preflight

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
command -v node >/dev/null 2>&1 || fail "node is not on PATH -- the hub is a node program"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
[ -d "$MOD_DIR" ] || fail "$MOD_DIR is missing -- symlink the mod into mods/"
[ -f "$HUB_CLI" ] || fail "$HUB_CLI is missing -- this test needs the server half"
if [ ! -d data/generated ]; then
  # No cache yet. With a ROM configured this is recoverable without anyone
  # touching the game: import it and carry on. The extractor is called
  # directly rather than through scripts/setup.sh, which never passes
  # --version and so always checks the ROM against Red's hash.
  if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
    echo "  no game data yet; importing $(basename "$ROM_PATH") as ${ROM_VERSION:-red}"
    PY=.venv/bin/python3
    [ -x "$PY" ] || PY=python3
    if ! "$PY" tools/build_data.py --rom "$ROM_PATH" \
        --version "${ROM_VERSION:-red}" --clean; then
      fail "importing $ROM_PATH failed -- check ROM_VERSION matches the ROM"
    fi
  else
    fail "no data/generated, and no usable ROM_PATH.
     Set ROM_PATH (and ROM_VERSION) in $MOD_DIR/.env -- see .env.example --
     or import once with: scripts/setup.sh --rom \"/path/to/rom.gb\""
  fi
fi

# Check the ROM config before anything long-running rather than at the moment
# it is needed: a path left at the example value looks configured and is not,
# and a ROM_VERSION that disagrees with the file fails a SHA-1 check partway
# through an import.
check_rom_config || exit 2

rm -f "$A_LOG" "$B_LOG" "$HUB_LOG"
# stale phase markers would let a rerun skip straight past every barrier
rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

# ------------------------------------------------------------- the hub's home
#
# A scratch directory, never the repo and never $HOME. `init` writes a
# plaintext join code into this file at mode 0600 and `start` refuses to run
# on anything looser, so it has to be somewhere this script owns outright and
# removes on the way out.
HUB_HOME="$(mktemp -d "${TMPDIR:-/tmp}/rby_mmo_hub_cfg.XXXXXX")" \
  || fail "could not make a scratch directory for the hub's config"
HUB_CONFIG="$HUB_HOME/config.json"

# Stopping the hub is worth its own function, and worth being sure about.
#
# It is the only participant that outlives a failed run holding a *listening
# socket*, and a leftover one binds the port the next run needs -- where it
# then answers that run's clients with the previous run's join code, so every
# instance is refused and the report blames the handshake. That happened on
# the first run of this file, and the diagnosis cost more than this function.
# SIGTERM first (server.js has a handler and shuts down cleanly), SIGKILL only
# if it is still there.
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
  [ -n "${A_PID:-}" ] && kill "$A_PID" 2>/dev/null
  [ -n "${B_PID:-}" ] && kill "$B_PID" 2>/dev/null
  stop_hub
  # the throwaway identities, resolved by the probe below
  [ -n "${A_SAVE:-}" ] && rm -rf "$A_SAVE"
  [ -n "${B_SAVE:-}" ] && rm -rf "$B_SAVE"
  # the config file holds a live join code in plaintext; it does not outlive
  # the run that minted it
  [ -n "${HUB_HOME:-}" ] && rm -rf "$HUB_HOME"
}
trap cleanup EXIT

hub_cli() { node "$HUB_CLI" --config "$HUB_CONFIG" "$@"; }

# ------------------------------------------------- an already-running hub
#
# Normally this script provisions and runs its own hub, which is what makes it
# a self-contained test. Set both of these to point the same two clients at a
# hub that is already up somewhere else:
#
#   MMO_HUB_EXTERNAL=192.168.1.20:7788 MMO_HUB_CODE=A7K3P9 \
#     bash mods/rby_mmo/tests/drivers/run-hub-e2e.sh
#
# That is how you smoke-test a *deployment* rather than a build -- a container,
# a VPS, a box a friend runs -- with real game clients rather than a socket
# script. The clients cannot tell the difference, which is the whole premise of
# the protocol, so everything below this point is unchanged: same drivers, same
# assertions, same verdict.
#
# What is skipped, necessarily: provisioning, the local-bind preflight, and the
# hub-side log checks in the verdict (credential refusals, sessions brokered,
# relay drops) -- this script cannot read the log of a process it did not
# start, and on a container that log belongs to `docker compose logs`. The
# client-side assertions are untouched and they are the substance.
EXTERNAL_HUB="${MMO_HUB_EXTERNAL:-}"
if [ -n "$EXTERNAL_HUB" ]; then
  [ -n "${MMO_HUB_CODE:-}" ] || fail "MMO_HUB_EXTERNAL needs MMO_HUB_CODE too --
     an external hub requires a passcode and this script cannot mint one for it.
     Read it from the hub you are pointing at, e.g.
       docker compose exec hub rby-mmo-hub invite list --reveal"
  HUB_ADDRESS="$EXTERNAL_HUB"
  JOIN_CODE="$MMO_HUB_CODE"
  HUB_PID=""
  echo "  using an EXTERNAL hub at $HUB_ADDRESS (nothing is started or torn down here)"
  echo "  join code: ****** (6 chars, supplied)"
fi

if [ -z "$EXTERNAL_HUB" ]; then
echo "  hub config: $HUB_CONFIG"
if ! hub_cli init --yes --host 127.0.0.1 --port "$PORT" --max "$MAX" \
     --log-level info >"$HUB_LOG" 2>&1; then
  echo "  !! rby-mmo-hub init failed:" >&2
  tail -20 "$HUB_LOG" >&2
  exit 1
fi

# The passcode, read the way a host reads their own back.
#
# NOT scraped from the hub's log: the CLI deliberately never logs a code
# (server/lib/cli.js's "secrets discipline" note), so a run that found one
# there would be reporting a leak rather than a join code. `invite list
# --reveal` is the documented way to see it again, and what it prints is
# exactly what a host would read out.
#
# The last field of the row, not a match anywhere in the output. A passcode is
# six ungrouped characters now, and the dashes that used to make one
# unmistakable are gone -- so a bare six-character pattern would also be
# willing to match something in the table's own furniture. Anchoring on the
# column keeps that from ever being a question; the shape test is still there
# to skip the header (whose CODE column reads "CODE") and to fail loudly on a
# CLI that changed what it prints.
JOIN_CODE="$(hub_cli invite list --reveal 2>/dev/null \
  | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }')"
[ ${#JOIN_CODE} -eq 6 ] || fail "could not read a join code back out of $HUB_CONFIG
     \`rby-mmo-hub invite list --reveal\` printed nothing shaped like one."
# Never echoed, not even in part: this output routinely ends up in a
# scrollback, a CI log or a screen share, and the code is a live credential
# for as long as the run lasts. At 30 bits there is nothing to spare for a
# readable prefix -- four of six characters was a third of the secret when a
# code was sixteen, and is two thirds of it now.
echo "  join code: ****** (6 chars, required)"

# Say so now, in one sentence, rather than letting a busy port surface as two
# clients that mysteriously cannot authenticate. Node is already a hard
# requirement here, so a five-line bind test costs nothing and needs no `nc`,
# `lsof` or `ss` to exist on the machine.
if ! node -e '
  const net = require("node:net");
  const server = net.createServer();
  server.once("error", () => process.exit(1));
  server.listen(Number(process.argv[1]), "127.0.0.1",
    () => server.close(() => process.exit(0)));
' "$PORT" 2>/dev/null; then
  fail "something is already listening on $HUB_ADDRESS.
     A hub left behind by an earlier run will answer this one's clients with
     the *previous* run's join code, and every instance is refused.
       lsof -ti tcp:$PORT | xargs kill
     or point this run somewhere else with MMO_HUB_PORT."
fi

echo "  starting the hub on $HUB_ADDRESS (max $MAX)..."
# `node` directly rather than the hub_cli function: backgrounding a shell
# function puts a subshell between this script and the server, `$!` names the
# subshell, and the kill in cleanup then leaves the real hub running -- with
# the port still bound. That is exactly how the stale listener above got
# there in the first place.
node "$HUB_CLI" --config "$HUB_CONFIG" start >>"$HUB_LOG" 2>&1 &
HUB_PID=$!

# Wait for the listener rather than sleeping a guessed interval -- the same
# shape as run-mmo-e2e.sh waiting for the host's address file, with the
# server's own log line standing in for it.
#
# The full sentence, not a substring of it: `start` prints a reachability
# summary *before* it binds, and that summary contains the words "listening
# on" too. Matching those alone declares the hub up while it is still on its
# way to EADDRINUSE, and the clients then fail against nothing at all.
READY='RBY MMO hub listening on'
for _ in $(seq 1 60); do
  grep -q "$READY" "$HUB_LOG" 2>/dev/null && break
  kill -0 "$HUB_PID" 2>/dev/null || break
  sleep 1
done
if ! grep -q "$READY" "$HUB_LOG" 2>/dev/null; then
  echo "  !! the hub never started listening. Its log:" >&2
  tail -30 "$HUB_LOG" >&2
  exit 1
fi
grep -m1 "$READY" "$HUB_LOG" | sed 's/^/  /'
fi   # end of the provision-and-start block skipped for an external hub

# ------------------------------------------------------------ the two clients

# Pin which other mods are on for this run, as space-separated ids. Both
# spellings are needed and for different reasons -- see run-mmo-e2e.sh, which
# explains it at length; the mechanism is shared, so the explanation is not
# repeated here.
EXTRA_MODS=""
for id in ${MMO_WITH_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = true"
done
for id in ${MMO_WITHOUT_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = false"
done
echo "  other mods: on=[${MMO_WITH_MODS:-none}] off=[${MMO_WITHOUT_MODS:-none}]"

# The mod ships experimental, so the loader leaves it disabled unless
# options.mods has an entry for it. Each instance gets its own LOVE identity
# (so the two do not fight over one save file), which means each needs its own
# options.lua -- and options are read at boot, before a driver can run.
#
# The save directory is asked of LOVE rather than assumed: it is
# ~/Library/Application Support/LOVE/<identity> on macOS but
# ~/.local/share/love/<identity> on Linux, and guessing it wrong fails in the
# most confusing way available -- the game boots fine, the mod is simply
# absent, and every later assertion blames the wrong thing.
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

# $2 is the avatar sprite this side picks, written through modOptions -- the
# same bucket the mod manager writes, so the run exercises the real option
# rather than anything test-only. Giving the two sides different sprites is
# what makes "pick your look" checkable across the hub: each side asserts the
# other arrives wearing the one that other side chose.
#
# `hub` is the address the JOIN screen opens prefilled with, and it is how
# both instances are pointed at the Node hub instead of the mod's default --
# the same mechanism run-mmo-e2e.sh uses for MMO_JOIN_ADDRESS. Deliberately no
# `code` row: a standing join code in options is what Client.joinCode falls
# back to when no code was typed for this hub's address, so leaving one here
# would let a run pass on a credential nobody entered -- and typing the
# passcode on the grid is precisely the leg this whole test exists to drive.
enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true%s }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$EXTRA_MODS" "$HUB_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}
A_SPRITE="${MMO_A_SPRITE:-SPRITE_RED}"
B_SPRITE="${MMO_B_SPRITE:-SPRITE_COOLTRAINER_M}"
A_SAVE="$(enable_mod_for "$A_ID" "$A_SPRITE")"
B_SAVE="$(enable_mod_for "$B_ID" "$B_SPRITE")"
rm -rf "$PROBE"
echo "  sprites: a=$A_SPRITE b=$B_SPRITE"
echo "  enabled the mod in $(dirname "$A_SAVE")/{$A_ID,$B_ID}"
echo "  shots: $SHOT_DIR"

# Each instance runs under its own throwaway save identity, and a fresh one
# can land on the ROM importer and sit there forever, silent -- which reads as
# "the client never connected". Handing it the ROM is what makes a scripted
# run import and boot instead of waiting for a human to pick a file.
#
# Exported rather than built into a string: an expanded "VAR=x love ." is not
# treated as an assignment by the shell -- the first word becomes the command
# name -- and a ROM path with spaces would word-split anyway.
if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$ROM_PATH"
  export POKEPORT_VERSION="${ROM_VERSION:-red}"
else
  echo "  note: no usable ROM_PATH; a fresh save identity may stall on the"
  echo "        importer. Set ROM_PATH in $ENV_FILE to make this reliable."
fi

# Both at once, and neither first. There is no host to wait for: the hub is
# already up, so the two clients are peers from the moment they boot, and
# staggering them would only make one of them the de-facto first arrival.
echo "  starting guest a..."
MMO_ROLE=a MMO_JOIN_ADDRESS="$HUB_ADDRESS" MMO_HUB_CODE="$JOIN_CODE" \
  MMO_PEER_SPRITE="$B_SPRITE" SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" \
  POKEPORT_IDENTITY="$A_ID" POKEPORT_DRIVER="$DRIVERS/mmo_guest.lua" \
  love . >"$A_LOG" 2>&1 &
A_PID=$!

echo "  starting guest b..."
MMO_ROLE=b MMO_JOIN_ADDRESS="$HUB_ADDRESS" MMO_HUB_CODE="$JOIN_CODE" \
  MMO_PEER_SPRITE="$A_SPRITE" SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" \
  POKEPORT_IDENTITY="$B_ID" POKEPORT_DRIVER="$DRIVERS/mmo_guest.lua" \
  love . >"$B_LOG" 2>&1 &
B_PID=$!

# Wait for BOTH sides to print DONE. One instance finishing says nothing about
# the other: role a leaves first by design, so its exit is a step in the
# script rather than the end of the run.
for _ in $(seq 1 "$TIMEOUT"); do
  if grep -q "DONE" "$A_LOG" 2>/dev/null && grep -q "DONE" "$B_LOG" 2>/dev/null; then
    break
  fi
  # only give up early if neither side is still alive to make progress
  if ! kill -0 "$A_PID" 2>/dev/null && ! kill -0 "$B_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

kill "$A_PID" "$B_PID" 2>/dev/null
wait "$A_PID" "$B_PID" 2>/dev/null
stop_hub
wait "$HUB_PID" 2>/dev/null

# ------------------------------------------------------------------- verdict

echo
echo "  ---- guest a ----"
grep -E 'MMO_GUEST_A:|TIMEOUT' "$A_LOG" | sed 's/^/  /'
echo "  ---- guest b ----"
grep -E 'MMO_GUEST_B:|TIMEOUT' "$B_LOG" | sed 's/^/  /'

# `grep -c` exits 1 on zero matches, so a `|| echo 0` appends a SECOND zero
# and the variable becomes "0\n0" -- which makes every [ -gt ] below fail as a
# non-integer and silently fall through to the success line. A harness that
# reports a false pass is worse than no harness, so count this way.
count() { grep -c "$1" "$2" 2>/dev/null | head -1 || true; }

# `.*` between the tag and the word on purpose: U.log prints its arguments
# TAB-separated, so a pattern written with a space matches nothing at all.
# Never assume the separator.
a_fail=$(count 'MMO_GUEST_A:.*FAIL' "$A_LOG"); a_fail=${a_fail:-0}
b_fail=$(count 'MMO_GUEST_B:.*FAIL' "$B_LOG"); b_fail=${b_fail:-0}
a_done=$(count 'MMO_GUEST_A:.*DONE' "$A_LOG"); a_done=${a_done:-0}
b_done=$(count 'MMO_GUEST_B:.*DONE' "$B_LOG"); b_done=${b_done:-0}

# A green run that logs WARN barrier lines is not green -- it is a run that
# got lucky. mmo_util's await() emits one whenever the patience it was given
# is thinner than 1.5x the work the other side actually did, whether or not
# the barrier was tested this time, so this is a standing check on the PHASE
# table rather than a report on today's timing.
warns=$( (grep -h "WARN barrier" "$A_LOG" "$B_LOG" 2>/dev/null || true) | sed 's/^/  /')

# What the HUB saw, which is the half no assertion inside the game can reach.
#
# The credential refusal in particular is the Node side of the wrong-code leg,
# and the only evidence anywhere that verify() ran and said no rather than the
# client giving up before it ever asked. Matched on `refused <id> from`, with
# the numeric client id: the reachability summary `start` prints has the word
# "refused" in its prose, and `refused a relayed message` is a different event
# entirely -- one that is counted separately below because it must be zero.
hub_fail=0
if [ -n "$EXTERNAL_HUB" ]; then
  # The hub belongs to somebody else -- a container, a VPS -- and its log is
  # theirs to read. Saying so is better than counting zeroes out of an empty
  # file and calling the silence a pass; a verdict that cannot fail is not one.
  echo "  ---- hub ----"
  echo "  external hub at $HUB_ADDRESS: its log is not readable from here, so the"
  echo "  hub-side checks (refusals, sessions, relay drops, errors) are SKIPPED."
  echo "  Read them where it runs, e.g. \`docker compose logs hub\`."
else
hub_refusals=$(count 'WARN refused [0-9]' "$HUB_LOG"); hub_refusals=${hub_refusals:-0}
hub_drops=$(count 'refused a relayed message' "$HUB_LOG"); hub_drops=${hub_drops:-0}
hub_sessions=$(count 'session [0-9]*:' "$HUB_LOG"); hub_sessions=${hub_sessions:-0}
hub_errors=$(count ' ERROR ' "$HUB_LOG"); hub_errors=${hub_errors:-0}

echo "  ---- hub ----"
echo "  credential refusals: $hub_refusals   sessions brokered: $hub_sessions" \
     "  relay drops: $hub_drops   errors: $hub_errors"
grep -E 'WARN|ERROR' "$HUB_LOG" | head -10 | sed 's/^/  /'

if [ "$hub_refusals" -lt 1 ]; then
  echo "  !! the hub refused nobody -- the wrong-code leg never reached verify()"
  hub_fail=$((hub_fail + 1))
fi
if [ "$hub_sessions" -lt 2 ]; then
  echo "  !! the hub brokered $hub_sessions session(s); the trade and the battle are two"
  hub_fail=$((hub_fail + 1))
fi
if [ "$hub_drops" -ne 0 ]; then
  # Nothing but trade and battle rides the relay path, so a dropped payload is
  # a trade or a battle that half-happened. It can pass every in-game
  # assertion and still be a real fault.
  echo "  !! the hub refused $hub_drops relayed payload(s) -- a session lost traffic"
  hub_fail=$((hub_fail + 1))
fi
if [ "$hub_errors" -ne 0 ]; then
  echo "  !! the hub logged $hub_errors error(s)"
  hub_fail=$((hub_fail + 1))
fi
fi   # end of the hub-side checks, skipped for an external hub

dump_logs() {
  echo
  echo "  ---- guest a log (tail) ----"
  tail -25 "$A_LOG" | sed 's/^/  /'
  echo "  ---- guest b log (tail) ----"
  tail -25 "$B_LOG" | sed 's/^/  /'
  echo "  ---- hub log (tail) ----"
  tail -25 "$HUB_LOG" | sed 's/^/  /'
  echo
  echo "  full logs kept: $A_LOG  $B_LOG  $HUB_LOG"
}

echo
if [ -n "$warns" ]; then
  echo "  BARRIER WARNINGS -- the PHASE table is thinner than the work it covers:"
  echo "$warns"
  echo
fi
if [ "$a_done" -ne 1 ] || [ "$b_done" -ne 1 ]; then
  echo "  RESULT: incomplete -- one side never reached DONE."
  dump_logs
  exit 1
fi
if [ "$a_fail" -ne 0 ] || [ "$b_fail" -ne 0 ] || [ "$hub_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $a_fail guest-a + $b_fail guest-b + $hub_fail hub failure(s)."
  dump_logs
  exit 1
fi
if [ -n "$warns" ]; then
  echo "  RESULT: assertions passed, but a barrier warned. Raise it in"
  echo "          $DRIVERS/mmo_util.lua's PHASE table before trusting this."
  exit 1
fi
echo "  RESULT: dedicated-hub end-to-end passed. Screenshots in $SHOT_DIR"
rm -f "$A_LOG" "$B_LOG" "$HUB_LOG"
