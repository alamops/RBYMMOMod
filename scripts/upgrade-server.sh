#!/usr/bin/env bash
#
# Move a running RBY MMO hub onto a newer (or specific) GitHub release.
#
# Rebuilds the image from the release, restarts the container, and leaves
# the named volume alone. The join code, bans, allowlist, ranking and
# history stay. `docker compose down -v` is how you *destroy* that volume;
# this script will not run it.
#
# Default target is the newest GitHub *release*, looked up live — the same
# channel players install the mod zip from. That is what keeps PROTOCOL in
# lockstep. `--version` pins a specific tag when a group of friends is
# still on an older zip.
#
#   bash scripts/upgrade-server.sh
#   bash scripts/upgrade-server.sh --version vX.Y.Z
#   bash scripts/upgrade-server.sh --generation 2
#   curl -fsSL .../scripts/upgrade-server.sh | bash -s -- --dir /opt/RBYMMOMod
#
# Finds the checkout from, in order: --dir, this script's repo, $RBY_MMO_DIR,
# the running container's compose working_dir, then ./RBYMMOMod.
#
# Does not: wipe /data, rotate the join code, open a firewall, or hand-pin a
# version inside this file.

set -euo pipefail

REPO_SLUG="${RBY_MMO_REPO:-alamops/RBYMMOMod}"
REPO_URL="${RBY_MMO_GIT_URL:-https://github.com/${REPO_SLUG}.git}"
API_URL="https://api.github.com/repos/${REPO_SLUG}"
COMPOSE_SERVICE="hub"
CONTAINER_NAME="rby-mmo-hub"
CLONE_NAME="RBYMMOMod"

VERSION="latest"
DIR=""
GENERATION=""
EXPLICIT_GEN=0
DRY_RUN=0
REVEAL=0

fail() { printf '%s\n' "!! $*" >&2; exit 2; }
note() { printf '%s\n' "-> $*"; }
warn() { printf '%s\n' "** $*" >&2; }

usage() {
  cat <<'EOF'
Upgrade a running RBY MMO hub to a GitHub release.

Usage:
  bash scripts/upgrade-server.sh [options]
  curl -fsSL .../scripts/upgrade-server.sh | bash -s -- [options]

Options:
  --version, -v <tag>   Target release (vX.Y.Z or X.Y.Z).
                        Default: the newest GitHub release, looked up live.
  --dir <path>          Existing checkout to update.
  --generation, -g <1|2>
                        Hub lock: 1 = RBY, 2 = Gold. Default: keep
                        whatever this checkout / container already
                        runs. Written into server/.env as
                        RBY_MMO_GENERATION. Compose leaves the var empty
                        when unset so config.json wins; this file is how
                        the operator lock survives a tag checkout.
  --reveal              Print join codes after the restart (same as
                        `invite list --reveal`). Off by default so an
                        upgrade log is safe to keep.
  --dry-run             Print from → to; change nothing.
  --self-test           Run helper assertions; no Docker, no fetch.
  -h, --help            This text.

Environment:
  RBY_MMO_REPO          GitHub slug (default alamops/RBYMMOMod)
  RBY_MMO_DIR           Fallback checkout path
  RBY_MMO_GENERATION    Same as --generation, if --generation is omitted
                        and neither .env nor the volume names a gen.
                        --generation is how you switch.
  GH_TOKEN / GITHUB_TOKEN   Optional; raises the GitHub API rate limit

The named volume is never removed. Friends keep the passcode they already
have. If PROTOCOL changed between the two releases, they also need the
matching mod zip from the same GitHub release.
EOF
}

# stdin is the script itself when this is `curl | bash`. Never `read` from it.

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

pick_latest_tag() {
  awk -F'[v.]' '
    $0 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {
      printf "%03d.%03d.%03d %s\n", $2+0, $3+0, $4+0, $0
    }
  ' | sort | tail -n 1 | awk '{ print $2 }'
}

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
      -H "User-Agent: rby-mmo-hub-upgrade-server" \
      "$url"
  else
    curl_get \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: rby-mmo-hub-upgrade-server" \
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

current_git_ref() {
  local root="$1"
  (
    cd "$root"
    git describe --tags --exact-match HEAD 2>/dev/null \
      || git rev-parse --abbrev-ref HEAD 2>/dev/null \
      || git rev-parse --short HEAD
  )
}

DOCKER=(docker)

docker_talks() {
  "${DOCKER[@]}" info >/dev/null 2>&1
}

use_sudo_docker() {
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n docker info >/dev/null 2>&1 || sudo docker info >/dev/null 2>&1
}

try_bind_docker() {
  if command -v docker >/dev/null 2>&1 && docker_talks; then
    DOCKER=(docker)
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && use_sudo_docker; then
    DOCKER=(sudo docker)
    return 0
  fi
  return 1
}

bind_docker() {
  try_bind_docker || fail "Docker is not installed, or this user cannot talk to the daemon. Re-run as root, start the daemon, or add this user to the docker group."
}

compose() {
  "${DOCKER[@]}" compose "$@"
}

have_compose() {
  compose version >/dev/null 2>&1
}

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

env_host_port() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n 's/^RBY_MMO_HOST_PORT=\([0-9][0-9]*\)$/\1/p' "$file" | tail -n 1
}

persist_lock_env() {
  if [ -n "$SAVED_PORT" ]; then
    write_env_key "${ROOT}/server/.env" RBY_MMO_HOST_PORT "$SAVED_PORT"
    export RBY_MMO_HOST_PORT="$SAVED_PORT"
    note "keeping host port ${SAVED_PORT} (wrote server/.env so checkout cannot revert it)"
  fi
  write_env_key "${ROOT}/server/.env" RBY_MMO_GENERATION "$GENERATION"
  export RBY_MMO_GENERATION="$GENERATION"
  note "hub generation ${GENERATION} (1 = RBY, 2 = Gold)"
}

container_working_dir() {
  "${DOCKER[@]}" inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$CONTAINER_NAME" 2>/dev/null || true
}

find_checkout() {
  local candidate parent labelled
  if [ -n "$DIR" ]; then
    printf '%s\n' "$DIR"
    return 0
  fi
  candidate="$(script_checkout_root || true)"
  if [ -n "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ -n "${RBY_MMO_DIR:-}" ]; then
    printf '%s\n' "$RBY_MMO_DIR"
    return 0
  fi
  labelled="$(container_working_dir || true)"
  if [ -n "$labelled" ] && [ -f "${labelled}/compose.yml" ]; then
    parent="$(cd "${labelled}/.." && pwd)"
    printf '%s\n' "$parent"
    return 0
  fi
  if [ -f "${PWD}/${CLONE_NAME}/server/compose.yml" ]; then
    printf '%s\n' "${PWD}/${CLONE_NAME}"
    return 0
  fi
  if [ -f "${PWD}/server/compose.yml" ]; then
    pwd
    return 0
  fi
  fail "no hub checkout found. Pass --dir /path/to/RBYMMOMod (the folder that contains server/compose.yml)."
}

checkout_tag() {
  local root="$1"
  local tag="$2"
  (
    cd "$root"
    git remote get-url origin >/dev/null 2>&1 || fail "${root} is not a git checkout"
    # Depth-1 clones cannot see other tags until we fetch this one by name.
    # --force updates a local tag left by a previous fetch of the same name.
    git_http fetch --force --depth 1 origin "refs/tags/${tag}:refs/tags/${tag}"
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
      fail "${root} has uncommitted changes in tracked files. Commit, stash, or discard them before upgrading. (Untracked files such as server/.env are left alone.)"
    fi
    git checkout --detach "$tag"
  )
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
        fail "hub came up unhealthy after the upgrade — see the log above. The volume was not removed; the previous join code is still on it."
        ;;
      running)
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
  fail "hub did not become healthy within 72s. The volume was not removed."
}

self_test() {
  local got
  got="$(normalize_tag 1.1.9)"
  [ "$got" = v1.1.9 ] || fail "normalize_tag 1.1.9 -> $got"
  got="$(normalize_tag v2.0.0)"
  [ "$got" = v2.0.0 ] || fail "normalize_tag v2.0.0 -> $got"
  got="$(printf '%s\n' v0.8.0 v1.1.9 v1.0.15 | pick_latest_tag)"
  [ "$got" = v1.1.9 ] || fail "pick_latest_tag -> $got"
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
  printf 'FOO=1\nRBY_MMO_HOST_PORT=25565\n' > "$tmp"
  got="$(env_host_port "$tmp")"
  [ "$got" = 25565 ] || fail "env_host_port -> $got"
  write_env_key "$tmp" RBY_MMO_GENERATION 2
  got="$(env_key "$tmp" RBY_MMO_GENERATION)"
  [ "$got" = 2 ] || fail "env_key generation -> $got"
  got="$(env_key "$tmp" FOO)"
  [ "$got" = 1 ] || fail "write_env_key preserved FOO -> $got"
  printf '{"listen":{"port":7788},"generation":2}\n' > "$tmp"
  got="$(generation_from_config_json "$tmp")"
  [ "$got" = 2 ] || fail "generation_from_config_json -> $got"
  rm -f "$tmp"
  printf 'self-test ok\n'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --self-test) self_test; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reveal) REVEAL=1; shift ;;
    --version|-v)
      [ $# -ge 2 ] || fail "$1 needs a value"
      VERSION="$(normalize_tag "$2")"
      shift 2
      ;;
    --dir)
      [ $# -ge 2 ] || fail "$1 needs a value"
      DIR="$2"
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

command -v curl >/dev/null 2>&1 || fail "curl is not on PATH"
command -v git >/dev/null 2>&1 || fail "git is not on PATH"

# Bind Docker before find_checkout so the compose-label fallback works for
# operators who need `sudo docker`, and so we can read the published host
# port before checkout resets compose.yml.
try_bind_docker || true

ROOT="$(find_checkout)"
ROOT="$(cd "$ROOT" && pwd)" || fail "${ROOT} does not exist"
[ -f "${ROOT}/server/compose.yml" ] || fail "${ROOT} has no server/compose.yml — that is not an RBYMMOMod checkout"
if [ -f "${ROOT}/.git" ]; then
  fail "${ROOT} is a git worktree. upgrade-server.sh checks out a release tag in place, which would move this working tree. Use a deploy clone (the one run-server.sh created), not a worktree."
fi
[ -d "${ROOT}/.git" ] || fail "${ROOT} is not a git checkout; this script fetches a release tag into an existing clone. Re-run scripts/run-server.sh to install."

FROM_REF="$(current_git_ref "$ROOT")"
FROM_PROTO="$(protocol_of "$ROOT")"
FROM_PKG="$(package_version_of "$ROOT")"
TO_TAG="$(resolve_tag "$VERSION")"
TO_PROTO="(after fetch)"
SAVED_PORT="$(env_host_port "${ROOT}/server/.env")"
if [ -z "$SAVED_PORT" ]; then
  SAVED_PORT="$(published_host_port || true)"
fi

# Keep the gen this hub already runs unless --generation was passed.
# Compose interpolates RBY_MMO_GENERATION with an empty default, and the
# hub skips empty env, so config.json wins unless .env names a gen. Still
# write .env so a later compose up with a leftover shell 1 cannot stick.
FROM_GEN="$(env_key "${ROOT}/server/.env" RBY_MMO_GENERATION)"
case "$FROM_GEN" in
  1|2) ;;
  *) FROM_GEN="$(container_generation || true)" ;;
esac
if [ "$EXPLICIT_GEN" -eq 0 ]; then
  case "$FROM_GEN" in
    1|2) GENERATION="$FROM_GEN" ;;
    *)
      if [ -n "${RBY_MMO_GENERATION:-}" ]; then
        GENERATION="$(normalize_generation "$RBY_MMO_GENERATION")"
      else
        GENERATION="1"
      fi
      ;;
  esac
fi

cat <<EOF
RBY MMO hub — upgrade

  directory  ${ROOT}
  from       ${FROM_REF}  (package ${FROM_PKG}, protocol ${FROM_PROTO})
  to         ${TO_TAG}
  generation ${GENERATION}   (1 = RBY, 2 = Gold)
  volume     kept (join code, bans, ranking, history)
EOF

if [ "$FROM_REF" = "$TO_TAG" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    note "already on ${TO_TAG}. Nothing to fetch."
    note "dry-run: not writing server/.env."
    exit 0
  fi
  try_bind_docker || true
  if [ -z "$FROM_GEN" ]; then
    FROM_GEN="$(container_generation || true)"
  fi
  if [ "$EXPLICIT_GEN" -eq 0 ]; then
    case "$FROM_GEN" in
      1|2) GENERATION="$FROM_GEN" ;;
    esac
  fi
  persist_lock_env
  note "already on ${TO_TAG}. Nothing to fetch. Use --version to pick a different release, or \`docker compose up -d --build\` in server/ to rebuild this tag."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry-run: stopping before git fetch or compose."
  exit 0
fi

bind_docker
have_compose || fail "Docker Compose v2 is missing (need \`docker compose\`)."

# Docker may not have been bound at sniff time (sudo docker). Try again.
if [ -z "$FROM_GEN" ]; then
  FROM_GEN="$(container_generation || true)"
fi
if [ "$EXPLICIT_GEN" -eq 0 ]; then
  case "$FROM_GEN" in
    1|2) GENERATION="$FROM_GEN" ;;
  esac
fi

if [ -n "$FROM_GEN" ] && [ "$FROM_GEN" != "$GENERATION" ]; then
  warn "generation changing ${FROM_GEN} → ${GENERATION}."
  warn "Clients of gen ${FROM_GEN} will be refused. Pass --generation ${FROM_GEN} to keep this hub on that gen."
fi

checkout_tag "$ROOT" "$TO_TAG"
TO_PROTO="$(protocol_of "$ROOT")"
TO_PKG="$(package_version_of "$ROOT")"

cd "${ROOT}/server"

persist_lock_env

# Recreate the container from the new image. `up --build` is additive: the
# named volume is listed in compose.yml and is not passed `-v`, so /data
# survives. `compose down` without `-v` would also keep it; we never pass `-v`.
note "rebuilding and restarting (volume ${ROOT##*/}'s data stays)"
compose up -d --build
wait_healthy

note "now running ${TO_TAG}  (package ${TO_PKG}, protocol ${TO_PROTO})"

if [ "$FROM_PROTO" != "$TO_PROTO" ] && [ "$FROM_PROTO" != unknown ] && [ "$TO_PROTO" != unknown ]; then
  warn "PROTOCOL changed ${FROM_PROTO} → ${TO_PROTO}."
  warn "Friends still on the old mod zip will be refused. They need rby_mmo from GitHub release ${TO_TAG} (MODS → Import mod .zip)."
fi

if [ "$REVEAL" -eq 1 ]; then
  note "join codes (--reveal):"
  compose exec -T "$COMPOSE_SERVICE" rby-mmo-hub invite list --reveal
else
  note "join codes unchanged. To read them: docker compose exec -T hub rby-mmo-hub invite list --reveal"
fi

cat <<EOF

Upgrade complete. From ${ROOT}/server :

  docker compose exec hub rby-mmo-hub doctor
  docker compose exec hub rby-mmo-hub watch
EOF
