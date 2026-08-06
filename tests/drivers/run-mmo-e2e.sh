#!/usr/bin/env bash
#
# End-to-end test for in-game hosting: two real LOVE instances, two real
# windows, a real socket between them.
#
# This is the half of the mod the headless suites structurally cannot reach.
# tests/rby_mmo_test.lua pins the protocol logic with fake peers; nothing in
# it ever binds a socket, renders a menu, or spawns an avatar. This does.
#
#   Run from the Gen1Recomp checkout root, with this mod linked into mods/:
#
#     bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
#
# Requires a ROM to have been imported already (scripts/setup.sh --rom ...);
# the engine cannot boot without data/generated/.
#
# Two windows will open and drive themselves. Leave them alone until it
# finishes -- clicking into them steals the input the drivers are queueing.
#
# The host locks the game with a six-character passcode -- it cannot do
# otherwise; HostServer refuses to bind a port without one -- and the guest
# types it on the real naming grid before anything is dialled, wrong once and
# then right. There is no switch to skip it: MMO_JOIN_CODE=0 used to select a
# game with no code, which is now a game that cannot start.

set -uo pipefail
cd "$(dirname "$0")/../../../.." || exit 1

MOD_DIR="mods/rby_mmo"

# ---------------------------------------------------------------- .env
#
# Everything machine-specific lives in mods/rby_mmo/.env (gitignored; see
# .env.example): the ROM to import, the address to dial, which other mods to
# pin on or off. Loaded through the shared helper so this and tools/play.sh
# cannot drift apart on how the file is read.
ENV_FILE="$MOD_DIR/.env"
# shellcheck source=/dev/null
. "$MOD_DIR/tools/env.sh"
load_env "$ENV_FILE"
DRIVERS="$MOD_DIR/tests/drivers"
ADDR_FILE="${MMO_ADDR_FILE:-/tmp/rby_mmo_addr.txt}"
# Namespaced by run, so two of these can run at once -- two agents, two
# worktrees -- without overwriting each other's screenshots.
RUN_ID="${MMO_RUN_ID:-$$}"
# The port the in-game host binds. Derived from the pid unless pinned, so two
# runs on one machine host two separate games instead of the second silently
# joining the first -- which is what a fixed 7788 did, and it looked like a
# roster bug rather than a harness one.
MMO_GAME_PORT="${RBY_MMO_PORT:-$(( 7500 + ($$ % 200) ))}"
export RBY_MMO_PORT="$MMO_GAME_PORT"

# ...and the guest has to dial *that* port.
#
# The address the JOIN screen opens prefilled with is written into the guest's
# options below. It used to be the mod's built-in 127.0.0.1:7788, because 7788
# is what the host always bound -- and .env.example told people to pin exactly
# that. The moment the host started picking a port per run, so two runs on one
# machine stop joining each other, every pinned copy of that line went stale
# and pointed at nothing. Every run then failed three assertions that all read
# like a broken join code and none of which mention an address.
#
# So a stored address whose port is not the one the host is about to bind is
# corrected here rather than obeyed, and said out loud. A pinned RBY_MMO_PORT
# keeps working, because then the two agree by construction; what cannot
# happen any more is the guest quietly dialling a port nobody is listening on.
if [ -n "${MMO_JOIN_ADDRESS:-}" ]    && [ "${MMO_JOIN_ADDRESS##*:}" != "$MMO_GAME_PORT" ]; then
  echo "  note: MMO_JOIN_ADDRESS=$MMO_JOIN_ADDRESS names a port this host is"
  echo "        not binding; dialling 127.0.0.1:$MMO_GAME_PORT instead."
  echo "        (drop the line from $MOD_DIR/.env -- it is derived now.)"
  MMO_JOIN_ADDRESS=""
fi
: "${MMO_JOIN_ADDRESS:=127.0.0.1:$MMO_GAME_PORT}"
export MMO_JOIN_ADDRESS
SHOT_DIR="${SHOT_DIR:-/tmp/rby_mmo_shots-$RUN_ID}"
LIMIT="${MMO_LIMIT:-2}"
HOST_ID="mmohost-$RUN_ID"
GUEST_ID="mmoguest-$RUN_ID"
HOST_LOG="/tmp/rby_mmo_host_$$.log"
GUEST_LOG="/tmp/rby_mmo_guest_$$.log"
# Wall-clock budget per phase (host coming up, then both sides reaching DONE).
#
# This is a backstop, not an expectation: a healthy run finishes in about
# seven minutes and the loop below exits the moment both sides print DONE, so
# a larger number costs a good run nothing. It has to clear the longest
# barrier in mmo_util's PHASE table (host_battle_done, 540s) with room, or the
# harness kills a run that was about to report properly and replaces a real
# verdict with "incomplete" -- which is how the frame-budget bug stayed
# invisible for as long as it did.
#
# Raised 900 -> 1800 when the co-op leg landed. That leg forms a party, stages
# a real trainer battle on both sides and fights a whole 2-on-2 through its
# real menus, which is minutes of wall clock on top of everything that was
# here before. Since a good run exits early, the only thing the larger number
# costs is how long a genuinely stuck run takes to admit it.
TIMEOUT="${MMO_TIMEOUT:-1800}"

# ------------------------------------------------------------------ preflight

fail() { echo "  !! $*" >&2; exit 2; }

command -v love >/dev/null 2>&1 || fail "love is not on PATH (brew install --cask love)"
[ -f main.lua ] || fail "run this from the Gen1Recomp checkout root"
[ -d "$MOD_DIR" ] || fail "$MOD_DIR is missing -- symlink the mod into mods/"
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

# **Per run, and this one is not a nicety.** The barrier files are how the two
# instances agree on where they are in the scenario; shared between runs, one
# run's signal satisfies another's await and both sides end up somewhere the
# other is not -- reported as "one side never reached DONE", which looks
# exactly like a bug in the mod and is not one. A file left by a *previous*
# run does the same to the next one.
SYNC_OWNED=$([ -n "${MMO_SYNC_DIR:-}" ] && echo 0 || echo 1)
SYNC_DIR="${MMO_SYNC_DIR:-/tmp/rby_mmo_sync-$RUN_ID}"
# Check the ROM config before anything long-running rather than at the moment
# it is needed: a path left at the example value looks configured and is not,
# and a ROM_VERSION that disagrees with the file fails a SHA-1 check partway
# through an import.
check_rom_config || exit 2

rm -f "$ADDR_FILE" "$ADDR_FILE.tmp" "$HOST_LOG" "$GUEST_LOG"
# stale phase markers would let a rerun skip straight past every barrier
rm -rf "$SYNC_DIR"
mkdir -p "$SHOT_DIR" "$SYNC_DIR"

# The mod ships experimental, so the loader leaves it disabled unless
# options.mods has an entry for it. Each instance gets its own LOVE identity
# (so the two do not fight over one save file), which means each needs its
# own options.lua -- and options are read at boot, before a driver can run.
#
# The save directory is asked of LOVE rather than assumed. It is
# ~/Library/Application Support/LOVE/<identity> on macOS but
# ~/.local/share/love/<identity> on Linux, and guessing it wrong fails in
# the most confusing way available: the game boots fine, the mod is simply
# absent, and every later assertion blames the wrong thing.
# Pin which other mods are on for this run, as space-separated ids:
#
#   MMO_WITH_MODS="DRAMATIC_SHAPE"     bash .../run-mmo-e2e.sh
#   MMO_WITHOUT_MODS="DRAMATIC_SHAPE"  bash .../run-mmo-e2e.sh
#
# Both are needed, and for different reasons. An *experimental* mod is off
# unless something enables it, so coexistence needs MMO_WITH_MODS. An
# ordinary one is on merely by being in mods/ -- a missing options entry
# means enabled -- so proving this mod still works on the vanilla renderer
# needs MMO_WITHOUT_MODS. Relying on what happens to be installed is how a
# run that was supposed to be "without" quietly became "with": every
# earlier voxel run had the pipeline on, including the ones meant to be
# the control.
EXTRA_MODS=""
for id in ${MMO_WITH_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = true"
done
for id in ${MMO_WITHOUT_MODS:-}; do
  EXTRA_MODS="$EXTRA_MODS, $id = false"
done
echo "  other mods: on=[${MMO_WITH_MODS:-none}] off=[${MMO_WITHOUT_MODS:-none}]"

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
# what makes "pick your look" checkable: the host asserts the guest arrives
# wearing the one the guest chose, not the default.
enable_mod_for() {
  local dir
  dir="$(save_dir_for "$1")"
  [ -n "$dir" ] || fail "could not determine LOVE's save directory for $1"
  mkdir -p "$dir"
  printf 'return { mods = { rby_mmo = true%s }, modOptions = { rby_mmo = { hub = "%s", sprite = "%s" } } }\n' \
    "$EXTRA_MODS" "$MMO_JOIN_ADDRESS" "$2" > "$dir/options.lua"
  echo "$dir"
}
HOST_SPRITE="${MMO_HOST_SPRITE:-SPRITE_RED}"
GUEST_SPRITE="${MMO_GUEST_SPRITE:-SPRITE_COOLTRAINER_M}"
HOST_SAVE="$(enable_mod_for "$HOST_ID" "$HOST_SPRITE")"
GUEST_SAVE="$(enable_mod_for "$GUEST_ID" "$GUEST_SPRITE")"
echo "  sprites: host=$HOST_SPRITE guest=$GUEST_SPRITE"
# Said out loud, because when it is wrong the run fails three assertions that
# all read like a broken join code and none of which mention an address.
echo "  guest dials: $MMO_JOIN_ADDRESS   (host binds :$MMO_GAME_PORT)"
export MMO_EXPECT_GUEST_SPRITE="$GUEST_SPRITE"
rm -rf "$PROBE"
echo "  enabled the mod in $(dirname "$HOST_SAVE")/{$HOST_ID,$GUEST_ID}"

cleanup() {
  # The barrier files go with the run that made them. A dir left behind is a
  # dir the next run can read a signal out of -- which is exactly how a stale
  # /tmp/rby_mmo_hub_sync made every await resolve instantly and reported it
  # as "one side never reached DONE".
  if [ "${SYNC_OWNED:-0}" = "1" ] && [ -n "${SYNC_DIR:-}" ]; then
    rm -rf "$SYNC_DIR" 2>/dev/null
  fi

  [ -n "${HOST_PID:-}" ] && kill "$HOST_PID" 2>/dev/null
  [ -n "${GUEST_PID:-}" ] && kill "$GUEST_PID" 2>/dev/null
  # the throwaway identities, resolved by the probe above
  [ -n "${HOST_SAVE:-}" ] && rm -rf "$HOST_SAVE"
  [ -n "${GUEST_SAVE:-}" ] && rm -rf "$GUEST_SAVE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------- run

# Each instance runs under its own throwaway save identity, and readiness is
# decided per identity -- so a fresh one can land on the importer and sit
# there forever, silent, which reads as "the host never started listening".
# Handing it the ROM is what makes a scripted run import and boot instead of
# waiting for a human to pick a file.
# Exported rather than built into a string: an expanded "VAR=x love ." is
# not treated as an assignment by the shell -- the first word becomes the
# command name -- and a ROM path with spaces would word-split anyway.
if [ -n "${ROM_PATH:-}" ] && [ -f "$ROM_PATH" ]; then
  export POKEPORT_IMPORT_ROM="$ROM_PATH"
  export POKEPORT_VERSION="${ROM_VERSION:-red}"
else
  echo "  note: no usable ROM_PATH; a fresh save identity may stall on the"
  echo "        importer. Set ROM_PATH in $ENV_FILE to make this reliable."
fi

echo "  host limit: $LIMIT   join code: required (6 chars, minted in game)"
echo "  shots: $SHOT_DIR"
echo "  starting host..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" MMO_LIMIT="$LIMIT" MMO_SYNC_DIR="$SYNC_DIR" \
  POKEPORT_IDENTITY="$HOST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_host.lua" \
  love . >"$HOST_LOG" 2>&1 &
HOST_PID=$!

# wait for the listener rather than sleeping a guessed interval
for _ in $(seq 1 "$TIMEOUT"); do
  [ -f "$ADDR_FILE" ] && break
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 1
done
[ -f "$ADDR_FILE" ] || {
  echo "  !! the host never started listening. Its log:" >&2
  tail -30 "$HOST_LOG" >&2
  exit 1
}
# first line only: the second is the join code, and it is not for a log
echo "  host is up at $(head -1 "$ADDR_FILE")"

echo "  starting guest..."
MMO_ADDR_FILE="$ADDR_FILE" SHOT_DIR="$SHOT_DIR" MMO_SYNC_DIR="$SYNC_DIR" \
  POKEPORT_IDENTITY="$GUEST_ID" POKEPORT_DRIVER="$DRIVERS/mmo_join.lua" \
  love . >"$GUEST_LOG" 2>&1 &
GUEST_PID=$!

# Wait for BOTH sides to print DONE. Breaking as soon as the guest process
# ended killed the host mid-run: the guest finishes its script first by
# design, so its exit says nothing about whether the host is done.
for _ in $(seq 1 "$TIMEOUT"); do
  if grep -q "DONE" "$HOST_LOG" 2>/dev/null \
     && grep -q "DONE" "$GUEST_LOG" 2>/dev/null; then
    break
  fi
  # only give up early if neither side is still alive to make progress
  if ! kill -0 "$HOST_PID" 2>/dev/null && ! kill -0 "$GUEST_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

kill "$HOST_PID" "$GUEST_PID" 2>/dev/null
wait 2>/dev/null

# ------------------------------------------------------------------- verdict

echo
echo "  ---- host ----"
grep -E 'MMO_HOST:|TIMEOUT' "$HOST_LOG" | sed 's/^/  /'
echo "  ---- guest ----"
grep -E 'MMO_JOIN:|TIMEOUT' "$GUEST_LOG" | sed 's/^/  /'

# `grep -c` exits 1 on zero matches, so a `|| echo 0` appends a SECOND zero
# and the variable becomes "0\n0" -- which makes every [ -gt ] below fail as
# a non-integer and silently fall through to the success line. A harness
# that reports a false pass is worse than no harness, so count this way.
count() { grep -c "$1" "$2" 2>/dev/null | head -1 || true; }

# `.*` between the tag and the word on purpose: U.log prints its arguments
# TAB-separated, so a pattern written with a space matches nothing at all --
# which is how run 1 reported a false pass (FAIL lines uncounted) and run 2
# a false incomplete (DONE uncounted). Never assume the separator.
host_fail=$(count 'MMO_HOST:.*FAIL' "$HOST_LOG"); host_fail=${host_fail:-0}
guest_fail=$(count 'MMO_JOIN:.*FAIL' "$GUEST_LOG"); guest_fail=${guest_fail:-0}
host_done=$(count 'MMO_HOST:.*DONE' "$HOST_LOG"); host_done=${host_done:-0}
guest_done=$(count 'MMO_JOIN:.*DONE' "$GUEST_LOG"); guest_done=${guest_done:-0}

dump_logs() {
  echo
  echo "  ---- host log (tail) ----"
  tail -25 "$HOST_LOG" | sed 's/^/  /'
  echo "  ---- guest log (tail) ----"
  tail -25 "$GUEST_LOG" | sed 's/^/  /'
  echo
  echo "  full logs kept: $HOST_LOG  $GUEST_LOG"
}

echo
if [ "$host_done" -ne 1 ] || [ "$guest_done" -ne 1 ]; then
  echo "  RESULT: incomplete -- one side never reached DONE."
  dump_logs
  exit 1
fi
if [ "$host_fail" -ne 0 ] || [ "$guest_fail" -ne 0 ]; then
  echo "  RESULT: FAILED -- $host_fail host + $guest_fail guest failure(s)."
  dump_logs
  exit 1
fi
echo "  RESULT: end-to-end passed. Screenshots in $SHOT_DIR"
rm -f "$HOST_LOG" "$GUEST_LOG"
