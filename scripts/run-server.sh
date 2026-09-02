#!/usr/bin/env bash
#
# Install, set up, and run the RBY MMO hub in Docker.
#
# This is the whole VPS story in one file: Docker if the box has none, the
# hub sources at a GitHub *release* (not main — see below), `compose up`,
# wait until healthy, then print the join code on *this* terminal. The code
# is deliberately kept out of `docker compose logs`; that is a credential.
#
# Why a release, not the default branch. A hub and the mods dialling it have
# to agree on PROTOCOL. Players install the zip from Releases; a clone of
# main can be ahead of that zip (or, historically, a hand-copied tag sat
# twenty-nine releases behind it). Either mismatch refuses every join in a
# sentence nobody can act on from inside the game. Resolving
# /releases/latest at run time is what keeps the two in lockstep without
# stamping a version into this file.
#
# One-shot on a fresh Ubuntu box, as root:
#
#   curl -fsSL https://raw.githubusercontent.com/alamops/RBYMMOMod/main/scripts/run-server.sh | bash
#
# Arguments still work through the pipe:
#
#   curl -fsSL .../scripts/run-server.sh | bash -s -- --port 25565
#   curl -fsSL .../scripts/run-server.sh | bash -s -- --generation 2
#   curl -fsSL .../scripts/run-server.sh | bash -s -- --version vX.Y.Z
#
# From a checkout (uses this tree, does not fetch):
#
#   bash scripts/run-server.sh
#
# Re-running is safe: an existing install is started, not rebuilt, and the
# named volume — the join code, the bans, the allowlist — is never touched.
# Moving an already-running hub onto a newer release is upgrade-server.sh.
#
# Does not: open a firewall, destroy volumes, print the join code into the
# container log, or pin a version inside this script.

set -euo pipefail

REPO_SLUG="${RBY_MMO_REPO:-alamops/RBYMMOMod}"
REPO_URL="${RBY_MMO_GIT_URL:-https://github.com/${REPO_SLUG}.git}"
API_URL="https://api.github.com/repos/${REPO_SLUG}"
COMPOSE_SERVICE="hub"
CONTAINER_NAME="rby-mmo-hub"
DEFAULT_PORT="7788"
CLONE_NAME="RBYMMOMod"

VERSION="latest"          # "latest" or a vX.Y.Z tag
DIR=""                    # empty → infer
EXPLICIT_DIR=0
PORT="$DEFAULT_PORT"
EXPLICIT_PORT=0
GENERATION="1"
EXPLICIT_GEN=0
WANT_START=1
DRY_RUN=0
OPEN_FIREWALL=0

fail() { printf '%s\n' "!! $*" >&2; exit 2; }
note() { printf '%s\n' "-> $*"; }
warn() { printf '%s\n' "** $*" >&2; }

usage() {
  cat <<'EOF'
Install, set up, and run the RBY MMO hub with Docker.

Usage:
  bash scripts/run-server.sh [options]
  curl -fsSL .../scripts/run-server.sh | bash -s -- [options]

Options:
  --version, -v <tag>   GitHub release to clone (vX.Y.Z or X.Y.Z).
                        Default: the newest GitHub release, looked up live.
                        Ignored when this script is run from a checkout and
                        --dir is not given: that tree is what gets started.
  --dir <path>          Where the repo lives / will be cloned.
                        Default: this checkout, or $RBY_MMO_DIR, or ./RBYMMOMod.
  --port <n>            Host port friends type (default 7788). Container
                        port stays 7788; this only remaps the left side of
                        compose.yml's ports: line.
  --generation, -g <1|2>
                        Hub lock: 1 = Red/Blue/Yellow (default), 2 = Gold.
                        Written into server/.env as RBY_MMO_GENERATION so
                        first-boot init and every later start see it.
  --open-firewall       If ufw is on PATH, allow 7788/tcp (and OpenSSH).
                        Off by default — opening a port is a choice.
  --no-start            Fetch / install Docker and write server/.env,
                        but do not compose up.
  --dry-run             Print the plan; change nothing.
  --self-test           Run helper assertions; no Docker, no network fetch
                        of the hub itself.
  -h, --help            This text.

Environment:
  RBY_MMO_REPO          GitHub slug (default alamops/RBYMMOMod)
  RBY_MMO_DIR           Default --dir when not in a checkout
  RBY_MMO_HOST_PORT     Same as --port, if --port is omitted and
                        neither server/.env nor the running hub names a port
  RBY_MMO_GENERATION    Same as --generation, if --generation is omitted
                        and neither server/.env nor the volume names a gen.
                        --generation is how you switch.
  GH_TOKEN / GITHUB_TOKEN   Optional; raises the GitHub API rate limit

The join code is printed on this terminal after a first boot. It is not in
`docker compose logs`. Read it again later with:

  docker compose exec -T hub rby-mmo-hub invite list --reveal
EOF
}

# ---------------------------------------------------------------------------
# Helpers shared with the operator-facing verbs below.
# ---------------------------------------------------------------------------

# stdin is the script itself when this is `curl | bash`. Never `read` from
# it; a prompt would consume the rest of the file. Prompts, if we ever add
# one, go through /dev/tty.

normalize_tag() {
  local raw="${1:-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  case "$raw" in
    ''|latest|LATEST) printf 'latest\n'; return 0 ;;
  esac
  raw="${raw#v}"
  raw="${raw#V}"
  case "$raw" in
    [0-9]*.[0-9]*.[0-9]*)
      case "$raw" in
        *[!0-9.]*) fail "--version: expected X.Y.Z, got $1" ;;
      esac
      printf 'v%s\n' "$raw"
      ;;
    *) fail "--version: expected X.Y.Z or vX.Y.Z, got $1" ;;
  esac
}

normalize_generation() {
  case "${1:-}" in
    1) printf '1\n' ;;
    2) printf '2\n' ;;
    *) fail "--generation: expected 1 (RBY) or 2 (Gold), got $1" ;;
  esac
}

# Portable newest vX.Y.Z from a list of tags, no GNU sort -V, no python.
pick_latest_tag() {
  awk -F'[v.]' '
    $0 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
      printf "%03d.%03d.%03d %s\n", $2+0, $3+0, $4+0, $0
    }
  ' | sort | tail -n 1 | awk '{ print $2 }'
}

# curl that never talks to a TTY, fails on HTTP errors, and does not hang.
# --proto keeps a redirect from leaving HTTPS.
curl_get() {
  curl -fsSL --connect-timeout 10 --max-time 60 \
    --proto '=https' --proto-redir '=https' "$@"
}

git_http() {
  git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 "$@"
}

http_get() {
  local url="$1"
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -n "$token" ]; then
    curl_get -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: rby-mmo-hub-run-server" \
      "$url"
  else
    curl_get \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: rby-mmo-hub-run-server" \
      "$url"
  fi
}

latest_release_tag() {
  local json tag
  json="$(http_get "${API_URL}/releases/latest" 2>/dev/null)" || json=""
  tag="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  if [ -n "$tag" ]; then
    normalize_tag "$tag"
    return 0
  fi
  warn "GitHub releases API did not answer; falling back to git tags on ${REPO_SLUG}."
  command -v git >/dev/null 2>&1 || fail "git is not on PATH, and the GitHub API returned no latest release"
  tag="$(git_http ls-remote --tags --refs "$REPO_URL" | awk -F/ '{ print $NF }' | pick_latest_tag || true)"
  [ -n "$tag" ] || fail "no vX.Y.Z tags on ${REPO_URL}"
  printf '%s\n' "$tag"
}

tag_exists() {
  local tag="$1"
  git_http ls-remote --tags --refs "$REPO_URL" "refs/tags/${tag}" | grep -q .
}

resolve_tag() {
  local want="$1"
  if [ "$want" = latest ]; then
    latest_release_tag
    return 0
  fi
  command -v git >/dev/null 2>&1 || fail "git is not on PATH (needed to verify --version ${want})"
  tag_exists "$want" || fail "no GitHub tag ${want} on ${REPO_SLUG} — check github.com/${REPO_SLUG}/releases"
  printf '%s\n' "$want"
}

script_checkout_root() {
  local src="${BASH_SOURCE[0]:-}"
  [ -n "$src" ] && [ -f "$src" ] || return 1
  local here
  here="$(cd "$(dirname "$src")" && pwd)"
  [ -f "${here}/../server/compose.yml" ] || return 1
  cd "${here}/.." && pwd
}

protocol_of() {
  local root="$1"
  local file="${root}/src/Config.lua"
  [ -f "$file" ] || { printf 'unknown\n'; return 0; }
  awk '/^M\.PROTOCOL = / { print $3; exit }' "$file"
}

package_version_of() {
  local root="$1"
  local file="${root}/server/package.json"
  [ -f "$file" ] || { printf 'unknown\n'; return 0; }
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

DOCKER=(docker)

docker_talks() {
  "${DOCKER[@]}" info >/dev/null 2>&1
}

use_sudo_docker() {
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1
}

compose() {
  "${DOCKER[@]}" compose "$@"
}

have_compose() {
  compose version >/dev/null 2>&1
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    printf '%s\n' "!! need root or sudo to run: $*" >&2
    return 1
  fi
}

install_pkgs() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null 2>&1; then
    note "installing packages: ${pkgs[*]}"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      || fail "could not install packages (need root or sudo)"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" \
      || fail "could not install packages (need root or sudo)"
  elif command -v dnf >/dev/null 2>&1; then
    note "installing packages: ${pkgs[*]}"
    as_root dnf install -y "${pkgs[@]}" \
      || fail "could not install packages (need root or sudo)"
  elif command -v yum >/dev/null 2>&1; then
    note "installing packages: ${pkgs[*]}"
    as_root yum install -y "${pkgs[@]}" \
      || fail "could not install packages (need root or sudo)"
  else
    fail "need ${pkgs[*]} on PATH. Install them and re-run."
  fi
}

need_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  case "$cmd" in
    git|curl) install_pkgs "$cmd" ;;
    *) fail "$cmd is not on PATH" ;;
  esac
  command -v "$cmd" >/dev/null 2>&1 || fail "installed $cmd but it is still not on PATH"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    # Engine is already on PATH: never re-run get.docker.com. A missing
    # compose plugin or a stopped daemon is a different problem.
    if docker_talks; then
      DOCKER=(docker)
    elif use_sudo_docker; then
      DOCKER=(sudo docker)
    else
      fail "Docker is installed but this user cannot talk to the daemon. Start it, re-run as root, or add this user to the docker group. If sudo needs a password, run from a TTY (not curl|bash)."
    fi
    have_compose || fail "Docker Compose v2 is missing (need \`docker compose\`, not the old docker-compose). Install the docker-compose-plugin package and re-run."
    return 0
  fi

  case "$(uname -s)" in
    Darwin)
      fail "Docker Desktop is not running (or not installed). Install it from https://docs.docker.com/desktop/setup/install/mac-install/ then re-run."
      ;;
  esac

  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    fail "Docker is not installed, and this user can neither run it nor sudo. Re-run as root, or install Docker first: https://docs.docker.com/engine/install/"
  fi

  note "installing Docker Engine via get.docker.com"
  need_cmd curl
  if [ "$(id -u)" -eq 0 ]; then
    curl_get https://get.docker.com | sh
  elif command -v sudo >/dev/null 2>&1; then
    curl_get https://get.docker.com | sudo sh
  else
    fail "Docker is not installed, and this user cannot sudo. Re-run as root, or install Docker first: https://docs.docker.com/engine/install/"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    as_root service docker start >/dev/null 2>&1 || true
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif use_sudo_docker; then
    DOCKER=(sudo docker)
  else
    fail "Docker installed, but this user cannot talk to the daemon yet. Log out and back in (or run as root) so the docker group applies, then re-run."
  fi
  have_compose || fail "Docker installed, but Compose v2 is missing. Install the docker-compose-plugin package and re-run."
}

# ---------------------------------------------------------------------------
# Compose project
# ---------------------------------------------------------------------------

write_env_key() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rby-mmo-env.XXXXXX")"
  if [ -f "$env_file" ]; then
    grep -v "^${key}=" "$env_file" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$env_file"
}

env_key() {
  local file="$1"
  local key="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=\(.*\)$/\1/p" "$file" | tail -n 1
}

env_host_port() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n 's/^RBY_MMO_HOST_PORT=\([0-9][0-9]*\)$/\1/p' "$file" | tail -n 1
}

# Host port currently published on the running container (left side of
# host:container). Empty if the hub is not running or publishes nothing.
published_host_port() {
  local line port
  line="$("${DOCKER[@]}" port "$CONTAINER_NAME" 2>/dev/null | head -n 1 || true)"
  [ -n "$line" ] || return 0
  port="${line##*:}"
  case "$port" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$port"
}

generation_from_config_json() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n 's/.*"generation"[[:space:]]*:[[:space:]]*\([12]\).*/\1/p' "$file" | head -n 1
}

# Generation locked on the volume. Empty if unknown.
# Prefer config.json on the volume over `config get`: the latter is the
# effective config (env already applied), so a compose-injected 1 would
# hide a Gold lock still sitting in the file.
container_generation() {
  local g tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/rby-mmo-cfg.XXXXXX")"
  if "${DOCKER[@]}" cp "$CONTAINER_NAME:/data/config.json" "$tmp" 2>/dev/null; then
    g="$(generation_from_config_json "$tmp" || true)"
    rm -f "$tmp"
    case "$g" in
      1|2) printf '%s\n' "$g"; return 0 ;;
    esac
  else
    rm -f "$tmp"
  fi
  g="$("${DOCKER[@]}" exec "$CONTAINER_NAME" rby-mmo-hub config get generation 2>/dev/null || true)"
  g="$(printf '%s' "$g" | tr -d '[:space:]')"
  case "$g" in
    1|2) printf '%s\n' "$g"; return 0 ;;
  esac
}

wait_healthy() {
  local tries=36
  local i=0
  local status
  note "waiting for ${CONTAINER_NAME} to become healthy"
  while [ "$i" -lt "$tries" ]; do
    i=$((i + 1))
    status="$("${DOCKER[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    case "$status" in
      healthy)
        note "hub is healthy"
        return 0
        ;;
      unhealthy)
        warn "healthcheck reported unhealthy. Last log lines:"
        compose logs --tail 40 "$COMPOSE_SERVICE" >&2 || true
        fail "hub came up unhealthy — see the log above"
        ;;
      running)
        # image without a health field, or still inside start_period
        if [ "$i" -ge 8 ]; then
          note "hub is running (no health signal yet); continuing"
          return 0
        fi
        ;;
    esac
    sleep 2
  done
  warn "timed out waiting for healthy. Last log lines:"
  compose logs --tail 40 "$COMPOSE_SERVICE" >&2 || true
  fail "hub did not become healthy within 72s"
}

reveal_join_code() {
  # Operator stdout, never the container log. -T: no TTY, so curl|bash works.
  compose exec -T "$COMPOSE_SERVICE" rby-mmo-hub invite list --reveal
}

run_doctor() {
  compose exec -T "$COMPOSE_SERVICE" rby-mmo-hub doctor || true
}

open_firewall_if_asked() {
  [ "$OPEN_FIREWALL" -eq 1 ] || return 0
  command -v ufw >/dev/null 2>&1 || {
    warn "ufw is not on PATH; not opening a port. Allow TCP ${PORT} on this machine and in the cloud firewall."
    return 0
  }
  note "allowing OpenSSH and ${PORT}/tcp through ufw"
  if as_root ufw allow OpenSSH \
    && as_root ufw allow "${PORT}/tcp" \
    && as_root ufw --force enable; then
    note "ufw is allowing ${PORT}/tcp (and OpenSSH)"
  else
    warn "could not configure ufw; allow TCP ${PORT} on this machine and in the cloud firewall by hand"
  fi
}

print_next_steps() {
  local root="$1"
  local tag="$2"
  local proto="$3"
  cat <<EOF

Hub is up.

  version    ${tag}
  protocol   ${proto}
  directory  ${root}
  port       ${PORT}   (friends type <this-machine>:${PORT})
  generation ${GENERATION}   (1 = RBY, 2 = Gold)

Join code (this terminal only — it is not in docker compose logs):

EOF
  reveal_join_code || warn "could not read the join code yet; try: docker compose exec -T hub rby-mmo-hub invite list --reveal"

  cat <<EOF

Reachability:
EOF
  run_doctor

  cat <<EOF

Friends: <public-ip>:${PORT} and the passcode above.
A new VPS usually has two firewalls — ufw on the box, and one in the
provider panel. Both have to allow TCP ${PORT}. Check from your laptop:

  nc -vz <public-ip> ${PORT}

Day-to-day, from ${root}/server :

  docker compose exec hub rby-mmo-hub watch
  docker compose exec hub rby-mmo-hub invite          # another code
  docker compose exec hub rby-mmo-hub doctor

Upgrade to the newest GitHub release later (keeps the join code):

  bash ${root}/scripts/upgrade-server.sh

Pin a specific release with --version vX.Y.Z on that script.
EOF
}

# ---------------------------------------------------------------------------
# Self-test (no daemon, no clone)
# ---------------------------------------------------------------------------

self_test() {
  local got
  got="$(normalize_tag 1.1.9)"
  [ "$got" = v1.1.9 ] || fail "normalize_tag 1.1.9 -> $got"
  got="$(normalize_tag v2.0.0)"
  [ "$got" = v2.0.0 ] || fail "normalize_tag v2.0.0 -> $got"
  got="$(normalize_tag latest)"
  [ "$got" = latest ] || fail "normalize_tag latest -> $got"
  got="$(printf '%s\n' v0.8.0 v0.9.12 v1.1.9 v1.0.15 | pick_latest_tag)"
  [ "$got" = v1.1.9 ] || fail "pick_latest_tag -> $got (want v1.1.9)"
  got="$(printf '%s\n' v1.0.99 v1.1.0 | pick_latest_tag)"
  [ "$got" = v1.1.0 ] || fail "pick_latest_tag 1.0.99 vs 1.1.0 -> $got"
  got="$(normalize_generation 1)"
  [ "$got" = 1 ] || fail "normalize_generation 1 -> $got"
  got="$(normalize_generation 2)"
  [ "$got" = 2 ] || fail "normalize_generation 2 -> $got"
  if got="$(normalize_generation 3 2>/dev/null)"; then
    fail "normalize_generation 3 should fail, got $got"
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/rby-mmo-self.XXXXXX")"
  printf 'FOO=1\nRBY_MMO_HOST_PORT=7788\n' > "$tmp"
  write_env_key "$tmp" RBY_MMO_HOST_PORT 25565
  write_env_key "$tmp" RBY_MMO_GENERATION 2
  got="$(env_key "$tmp" RBY_MMO_HOST_PORT)"
  [ "$got" = 25565 ] || fail "write_env_key host port -> $got"
  got="$(env_key "$tmp" RBY_MMO_GENERATION)"
  [ "$got" = 2 ] || fail "write_env_key generation -> $got"
  got="$(env_key "$tmp" FOO)"
  [ "$got" = 1 ] || fail "write_env_key preserved FOO -> $got"
  printf 'RBY_MMO_HOST_PORT=25565\n' > "$tmp"
  got="$(env_host_port "$tmp")"
  [ "$got" = 25565 ] || fail "env_host_port -> $got"
  printf '{"listen":{"port":7788},"generation":2}\n' > "$tmp"
  got="$(generation_from_config_json "$tmp")"
  [ "$got" = 2 ] || fail "generation_from_config_json -> $got"
  rm -f "$tmp"
  printf 'self-test ok\n'
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --self-test) self_test; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-start) WANT_START=0; shift ;;
    --open-firewall) OPEN_FIREWALL=1; shift ;;
    --version|-v)
      [ $# -ge 2 ] || fail "$1 needs a value"
      VERSION="$(normalize_tag "$2")"
      shift 2
      ;;
    --dir)
      [ $# -ge 2 ] || fail "$1 needs a value"
      DIR="$2"
      EXPLICIT_DIR=1
      shift 2
      ;;
    --port)
      [ $# -ge 2 ] || fail "$1 needs a value"
      PORT="$2"
      EXPLICIT_PORT=1
      shift 2
      ;;
    --generation|-g)
      [ $# -ge 2 ] || fail "$1 needs a value"
      GENERATION="$(normalize_generation "$2")"
      EXPLICIT_GEN=1
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      fail "unknown option: $1  (see --help)"
      ;;
    *)
      fail "unexpected argument: $1  (see --help)"
      ;;
  esac
done

if [ "$EXPLICIT_PORT" -eq 0 ] && [ -n "${RBY_MMO_HOST_PORT:-}" ]; then
  PORT="$RBY_MMO_HOST_PORT"
fi

case "$PORT" in
  ''|*[!0-9]*) fail "--port must be a number, got ${PORT}" ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  fail "--port out of range: ${PORT}"
fi

if [ "$EXPLICIT_GEN" -eq 0 ] && [ -n "${RBY_MMO_GENERATION:-}" ]; then
  GENERATION="$(normalize_generation "$RBY_MMO_GENERATION")"
fi

CHECKOUT="$(script_checkout_root || true)"

# From a checkout, with no --version and no --dir: start *this* tree. A
# developer on a branch, or a VPS that already cloned, should not be yanked
# onto a tag just because they re-ran the run script. --version is how you
# ask for a release, and that path clones (or you want upgrade-server.sh).
USE_LOCAL=0
if [ -n "$CHECKOUT" ] && [ -z "$DIR" ] && [ "$VERSION" = latest ]; then
  USE_LOCAL=1
  DIR="$CHECKOUT"
fi

if [ -z "$DIR" ]; then
  DIR="${RBY_MMO_DIR:-${PWD}/${CLONE_NAME}}"
fi

# Re-run / dry-run should show the gen and port already locked on this
# checkout, not the defaults, unless the operator passed the flag.
if [ "$EXPLICIT_GEN" -eq 0 ]; then
  preserved="$(env_key "${DIR}/server/.env" RBY_MMO_GENERATION)"
  case "$preserved" in
    1|2) GENERATION="$preserved" ;;
  esac
fi
if [ "$EXPLICIT_PORT" -eq 0 ]; then
  preserved="$(env_host_port "${DIR}/server/.env")"
  if [ -n "$preserved" ]; then
    PORT="$preserved"
    if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
      fail "server/.env RBY_MMO_HOST_PORT out of range: ${PORT}"
    fi
  fi
fi

# --version from inside a checkout, with no --dir, would either move HEAD
# (destroying a worktree) or nest a clone at ./RBYMMOMod. Neither is this
# script's job: in-place is upgrade-server.sh; a second tree needs --dir.
if [ -n "$CHECKOUT" ] && [ "$VERSION" != latest ]; then
  resolved="$(cd "$DIR" 2>/dev/null && pwd || printf '%s' "$DIR")"
  if [ "$EXPLICIT_DIR" -eq 0 ] || [ "$resolved" = "$CHECKOUT" ]; then
    fail "this is a git checkout (${CHECKOUT}). Checking out ${VERSION} in place is upgrade-server.sh, not this script. Run: bash scripts/upgrade-server.sh --version ${VERSION}   (or pass --dir to clone that release somewhere else)"
  fi
fi

EXISTING=0
if [ -f "${DIR}/server/compose.yml" ]; then
  EXISTING=1
fi

# Clone only when there is no tree yet. An existing tree with --version is
# upgrade-server.sh (it keeps the volume). Re-running this script against a
# clone just starts it.
NEED_CLONE=0
if [ "$USE_LOCAL" -eq 0 ] && [ "$EXISTING" -eq 0 ]; then
  NEED_CLONE=1
fi

TAG="(this checkout)"
if [ "$NEED_CLONE" -eq 1 ]; then
  if command -v curl >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    TAG="$(resolve_tag "$VERSION")"
  else
    TAG="${VERSION} (resolved after git/curl are installed)"
  fi
elif [ "$EXISTING" -eq 1 ]; then
  TAG="(already cloned)"
fi

SOURCE_LINE="$TAG"
if [ "$USE_LOCAL" -eq 1 ]; then
  SOURCE_LINE="this checkout"
fi
START_LINE="no"
if [ "$WANT_START" -eq 1 ]; then
  START_LINE="yes"
fi

cat <<EOF
RBY MMO hub — install and run

  repo       ${REPO_SLUG}
  source     ${SOURCE_LINE}
  directory  ${DIR}
  port       ${PORT}
  generation ${GENERATION}
  start      ${START_LINE}
EOF

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry-run: stopping before Docker, git, or compose."
  exit 0
fi

if [ "$NEED_CLONE" -eq 1 ]; then
  need_cmd curl
  need_cmd git
  TAG="$(resolve_tag "$VERSION")"
fi
install_docker

if [ "$NEED_CLONE" -eq 1 ]; then
  if [ -e "$DIR" ]; then
    fail "${DIR} already exists but has no server/compose.yml. Pick a different --dir, or point --dir at an RBYMMOMod checkout."
  fi
  note "cloning ${REPO_SLUG} at ${TAG} into ${DIR}"
  mkdir -p "$(dirname "$DIR")"
  git_http clone --depth 1 --branch "$TAG" "$REPO_URL" "$DIR"
elif [ "$USE_LOCAL" -eq 0 ] && [ "$EXISTING" -eq 1 ] && [ "$VERSION" != latest ]; then
  fail "${DIR} already exists. To move it onto ${VERSION} without losing the join code, run: bash scripts/upgrade-server.sh --dir ${DIR} --version ${VERSION}"
elif [ "$EXISTING" -eq 1 ]; then
  note "using existing checkout at ${DIR}"
fi

[ -f "${DIR}/server/compose.yml" ] || fail "no server/compose.yml under ${DIR} — that is not an RBYMMOMod checkout"
[ -f "${DIR}/server/Dockerfile" ] || fail "no server/Dockerfile under ${DIR}"

cd "${DIR}/server"

# Preserve port and generation on re-run / leftover container unless the
# operator passed the flag. Default 1 / 7788 is only for a genuine first
# boot. Compose interpolates empty generation as unset, but writing 1
# here on a Gold volume would still lock it back to RBY.
if [ "$EXPLICIT_PORT" -eq 0 ]; then
  prev_port="$(env_host_port "${DIR}/server/.env")"
  if [ -z "$prev_port" ]; then
    prev_port="$(published_host_port || true)"
  fi
  case "$prev_port" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$prev_port" -ge 1 ] && [ "$prev_port" -le 65535 ]; then
        PORT="$prev_port"
      fi
      ;;
  esac
fi

prev="$(env_key "${DIR}/server/.env" RBY_MMO_GENERATION)"
case "$prev" in
  1|2) ;;
  *) prev="$(container_generation || true)" ;;
esac
if [ "$EXPLICIT_GEN" -eq 0 ]; then
  case "$prev" in
    1|2) GENERATION="$prev" ;;
  esac
elif [ -n "$prev" ] && [ "$prev" != "$GENERATION" ]; then
  warn "generation changing ${prev} → ${GENERATION}."
  warn "Clients of gen ${prev} will be refused. This hub only admits the generation it is locked to."
fi

write_env_key "${DIR}/server/.env" RBY_MMO_HOST_PORT "$PORT"
write_env_key "${DIR}/server/.env" RBY_MMO_GENERATION "$GENERATION"
export RBY_MMO_HOST_PORT="$PORT"
export RBY_MMO_GENERATION="$GENERATION"

if [ "$WANT_START" -eq 0 ]; then
  note "--no-start: checkout is at ${DIR}; wrote server/.env (port ${PORT}, generation ${GENERATION}). cd there/server && docker compose up -d --build"
  exit 0
fi

# Rebuild when we just cloned (a leftover container from an old tree must
# not keep serving its image) or when no container exists yet. Re-running
# against an already-running install of this same tree just starts it.
if [ "$NEED_CLONE" -eq 1 ] || ! "${DOCKER[@]}" container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  note "building and starting the hub (first run mints a join code onto the volume)"
  compose up -d --build
else
  note "container ${CONTAINER_NAME} already exists; starting it (volume, and join code, unchanged)"
  compose up -d
fi

wait_healthy
open_firewall_if_asked

PROTO="$(protocol_of "$DIR")"
SHOWN_TAG="$TAG"
if [ "$USE_LOCAL" -eq 1 ] || [ "$TAG" = "(already cloned)" ]; then
  SHOWN_TAG="$(package_version_of "$DIR")"
fi
print_next_steps "$DIR" "$SHOWN_TAG" "$PROTO"
