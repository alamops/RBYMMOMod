# RBY MMO hub -- container image.
#
#   docker build -t rby-mmo-hub server/
#   docker run --rm -p 7788:7788 -v rby-mmo-data:/data rby-mmo-hub
#
# or, the path this is really written for, `docker compose up` in this
# directory. compose.yml adds the sandboxing (read-only rootfs, dropped
# capabilities, no-new-privileges) that a bare `docker run` cannot express in
# a Dockerfile.
#
# ---------------------------------------------------------------------------
# Why node:24-alpine, and please do not "improve" this to distroless.
#
# Node 24 is Active LTS; the app declares engines >= 22, so 24 is the tested
# ceiling of a supported range rather than a bleeding edge.
#
# Alpine, not distroless, is a deliberate choice about *who hosts this*. The
# audience is a person running a game world for their friends, and the first
# thing they will need to do when something looks wrong is
# `docker compose exec hub sh`, look at /data/config.json, and read a join
# code back out. Distroless would take that away to save a few megabytes and
# remove a shell that is already unreachable behind a non-root user, a
# read-only rootfs and `cap_drop: ALL`. The usual counter-argument to Alpine
# -- musl breaking native modules -- does not apply: this package has zero
# dependencies (see hub.js:22, server/README.md:12, CLAUDE.md), so there is no
# native code to miscompile.
# ---------------------------------------------------------------------------

# --- stage 1: assemble ------------------------------------------------------
# There is nothing to compile. The stage still earns its keep: it is where the
# runtime payload is *defined*, by pruning everything that is not it. The final
# image then copies one already-correct tree, so what lands in it does not
# depend on .dockerignore having been kept up to date -- a test file added next
# year cannot sneak into a shipped image because someone forgot a line.
FROM node:24-alpine AS assemble

WORKDIR /src
COPY . .

RUN set -eux; \
    # Belt and braces with .dockerignore: tests, packaging and VCS state are
    # host-side or CI-side, never runtime. README.md is kept on purpose -- it
    # is the file a host who shelled in came to read.
    rm -rf ./*.test.js ./Dockerfile ./compose.yml ./.dockerignore \
           ./.git ./node_modules ./config.json; \
    # Fail the build rather than ship an image missing its entry points.
    test -f ./package.json; \
    test -f ./hub.js; \
    test -f ./bin/rby-mmo-hub.js; \
    test -f ./lib/server.js; \
    test -f ./lib/cli.js

# --- stage 2: runtime -------------------------------------------------------
FROM node:24-alpine AS runtime

# tini as PID 1. Not decoration: lib/server.js installs SIGTERM/SIGINT
# handlers that stop accepting, tell the players still connected that the hub
# is going away, and drain. Node as PID 1 gets no default signal disposition,
# and `docker stop` on a process that ignores SIGTERM is a ten-second wait
# followed by SIGKILL -- the goodbye never arrives. tini forwards signals and
# reaps, so shutdown is the graceful one the code already implements.
# (compose.yml also sets `init: true`; the two are compatible and either alone
# is sufficient, which is the point -- `docker run` users get it too.)
RUN apk add --no-cache tini

# Fixed UID/GID 10001. Fixed, because /data outlives the image: a host who
# rebuilds must not find their config owned by a different number. 10001 is
# above the ranges Alpine and the node image hand out (the base image's own
# `node` user is 1000), so it collides with nothing.
RUN addgroup -g 10001 -S rbymmo \
 && adduser -u 10001 -S -G rbymmo -h /app -s /sbin/nologin rbymmo

WORKDIR /app
COPY --from=assemble --chown=10001:10001 /src /app

# So that `docker compose exec hub rby-mmo-hub invite` is the command the docs
# can print, rather than a path into /app that a host has to memorise. `exec`
# bypasses ENTRYPOINT, and this is the only reason the name needs to be on
# PATH; the container's own start-up calls the file directly.
RUN ln -s /app/bin/rby-mmo-hub.js /usr/local/bin/rby-mmo-hub

# /data is the only writable path the hub needs, and the only one it is given:
# compose.yml runs the whole rootfs read-only. 0700 because the CLI writes
# config.json at 0600 and refuses to start on a group- or world-readable file;
# a 0755 directory would make that check the only thing standing between a
# join code and every other user in the container.
RUN mkdir -p /data \
 && chown 10001:10001 /data \
 && chmod 0700 /data

# Declared so that a `docker run` without -v still writes its config to a
# volume instead of the container layer. compose.yml names the volume, which
# is what anyone keeping a world for more than one session wants: an anonymous
# volume survives a restart but not a `docker rm`, and a new one starts with a
# new join code.
VOLUME ["/data"]

ENV RBY_MMO_CONFIG=/data/config.json \
    NODE_ENV=production

EXPOSE 7788

USER 10001:10001

# A raw TCP service has no HTTP endpoint to poll, so the check is a connect
# and an immediate close, written against Node's own `net` -- no curl, no nc,
# nothing added to the image just to look at it. lib/server.js logs an
# ungreeted connection at debug only, so this is silent at the default level.
#
# Two honest limits: it reads RBY_MMO_PORT (default 7788), so a port set only
# in config.json needs RBY_MMO_PORT set to match; and it dials 127.0.0.1, so a
# listen.host bound to one specific non-loopback address will read as
# unhealthy. Both are the uncommon case, and both are visible in `docker logs`.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["node", "-e", "const net=require('node:net');const port=Number(process.env.RBY_MMO_PORT)||7788;const s=net.connect({host:'127.0.0.1',port});const bye=(c)=>{s.destroy();process.exit(c)};s.setTimeout(4000);s.on('connect',()=>bye(0));s.on('error',()=>bye(1));s.on('timeout',()=>bye(1))"]

# ---------------------------------------------------------------------------
# What a bare `docker run` does when /data/config.json does not exist yet.
#
# This is the most consequential line in the file, because it decides what a
# careless run exposes. Three options were on the table:
#
#  1. Start the bare shim (`node hub.js`). Rejected outright. That path has no
#     config file, so it hard-codes auth off and the limits wide open
#     (hub.js:54-64) -- correct for a LAN, catastrophic as the default for an
#     image whose whole purpose is to be published to the internet with
#     `-p 7788:7788`. An unauthenticated shared world would be one typo away.
#
#  2. Refuse to start and print `rby-mmo-hub init`. Safe, and rejected anyway:
#     `start` on a missing config does not fall back to something open, it
#     falls back to the *defaults*, which are auth.required = true with zero
#     credentials -- a hub nobody, including the host, can join. Refusing would
#     trade a working first run for an error message, and the person reading it
#     is exactly the person least equipped to act on it.
#
#  3. Run `init --yes` first when, and only when, the config is absent -- what
#     this does. `init` honours RBY_MMO_* (lib/config.js:140-156), so a
#     compose file's port and player cap end up in the file it writes; its
#     default is auth.required = true, so it mints a join code. The result is
#     that `docker compose up` on an empty volume produces an authenticated
#     hub and hands the host a way to read the code they give their friends --
#     and it is not possible for it to produce an open one by accident. If the
#     host wants an open LAN hub they must ask for it
#     (RBY_MMO_AUTH_REQUIRED=false), which is a choice they made rather than a
#     default they inherited.
#
#     `init` refuses to overwrite an existing config without --force, so the
#     guard is belt and braces: a restart re-uses the same file and the same
#     join code.
#
# Where the code goes, and why not here.
#
# `init` prints the code to stdout, and stdout in a container is the log --
# the json-file driver writes it to the host's disk, and an orchestrator ships
# it onward to wherever it collects logs. That is durable, replicated storage
# for a credential, sitting outside the 0600 config file that exists to hold
# it, and it is exactly what lib/cli.js:29-34 refuses to do when it keeps join
# codes away from the logger. So the code goes to /data/join-code.txt (created
# under `umask 077`, so 0600 before a byte of it exists, on the 0700 volume
# beside config.json), and the log gets one line saying a code was made and how
# to read it back.
#
# **The code, and nothing else.** This file used to hold `init`'s whole output,
# which included its summary of the settings -- port, player cap, log level --
# as they were at first boot. Nothing ever rewrites the file, so the moment
# somebody ran `config set maxPlayers 16` that summary became a lie sitting on
# disk, in the file the README tells people to read. It was read, it said 4,
# and a working hub looked broken. A snapshot of settings has no reader; the
# passcode does. So only the passcode is written, under two comment lines
# saying what would make even that stale (a rotation) and what is authoritative
# when it is (`invite list --reveal`, which reads the live config).
#
# On failure the captured output *is* printed, to stderr, and the file is
# removed -- a first run that cannot write its config must say why, and the
# thing it failed to write holds no secret. That capture goes to /tmp rather
# than /data now: it exists only to be shown on the failure path, and /tmp is
# a tmpfs under compose, so it cannot outlive the boot that produced it.
#
# CMD stays overridable, so every other verb still works:
#   docker compose exec hub rby-mmo-hub invite
#   docker run --rm -v rby-mmo-data:/data rby-mmo-hub doctor
# ---------------------------------------------------------------------------
ENTRYPOINT ["/sbin/tini", "--", "/bin/sh", "-c", "if [ ! -f \"$RBY_MMO_CONFIG\" ]; then code=\"$(dirname \"$RBY_MMO_CONFIG\")/join-code.txt\"; out=\"/tmp/rby-init.$$\"; (umask 077; : > \"$code\") || { echo \"cannot write $code -- is /data writable?\" >&2; exit 1; }; if node /app/bin/rby-mmo-hub.js init --yes > \"$out\" 2>&1; then { echo '# The join code this hub was created with, and nothing else -- the'; echo '# settings that used to be in this file went stale the first time one'; echo '# of them was changed. Nothing rewrites this, so if the code has been'; echo '# rotated since, the live one is: rby-mmo-hub invite list --reveal'; node /app/bin/rby-mmo-hub.js invite list --reveal | awk '$NF ~ /^[0-9A-HJKMNP-TV-Z]{6}$/ { print $NF; exit }'; } > \"$code\"; chmod 0600 \"$code\"; rm -f \"$out\"; echo \"first run: a join code was generated, and is deliberately not in this log.\"; echo \"  read it:  docker compose exec hub rby-mmo-hub invite list --reveal\"; echo \"  or:       docker compose exec hub cat $code\"; else cat \"$out\" >&2; rm -f \"$out\" \"$code\"; exit 1; fi; fi; exec node /app/bin/rby-mmo-hub.js \"$@\"", "rby-mmo-hub"]
CMD ["start"]
