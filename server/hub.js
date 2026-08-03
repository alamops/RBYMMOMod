#!/usr/bin/env node
'use strict';

/*
 * RBY MMO hub.
 *
 * A relay, not a game server. It never simulates anything: it owns who is
 * connected, where they said they are, and which two players are currently
 * paired for a trade or a battle. Everything else -- the trade state
 * machine, the lockstep battle -- runs inside the two game clients, exactly
 * as it does over a direct link, with this process forwarding the bytes.
 *
 * That split is deliberate. The engine's link code is the authority on Gen
 * 1 behaviour and it already works; a hub that tried to referee battles
 * would be a second, worse implementation of it that could disagree with
 * the clients.
 *
 * Wire format is newline-delimited JSON, which is what src/link/Net.lua's
 * relay backend already speaks, so the client reuses the engine's framing
 * instead of shipping its own.
 *
 * No dependencies: node hub.js [port]
 *
 * ----------------------------------------------------------------------
 *
 * The hub itself now lives in lib/ -- relay.js, limits.js, auth.js,
 * config.js, server.js -- and this file is the front door it has always
 * had: no config file, no join code, no arguments but a port. It is here so
 * that every command in server/README.md and every existing deployment keeps
 * working unchanged.
 *
 * **For anything configurable, use `node server/bin/rby-mmo-hub.js`.** That
 * is where join codes, bans, allowlists, per-IP caps and UPnP live. This
 * entry point deliberately exposes none of them: it starts an open hub on a
 * LAN the way it always did.
 */

const { validate } = require('./lib/config.js');
const { createLog } = require('./lib/log.js');
const { start } = require('./lib/server.js');

// The same three environment variables, read in the same order: an argv port
// beats RBY_MMO_PORT, and the player cap is still clamped to 2..64 rather
// than obeyed -- via config.js, which owns those bounds now, so there is one
// definition of them instead of two that can drift.
const { config, warnings } = validate({
  listen: {
    host: process.env.RBY_MMO_HOST || '0.0.0.0',
    port: process.argv[2] || process.env.RBY_MMO_PORT || 7788,
  },
  maxPlayers: process.env.RBY_MMO_MAX || undefined,
  // No join code, because there is no file to keep one in. A hub reachable
  // from the internet wants `rby-mmo-hub init`; this one is for a LAN.
  auth: { required: false, credentials: [] },
  // Wide open, on purpose: this front door has only ever had one limit, the
  // player cap, and quietly growing a per-IP cap here would break the hosts
  // and the suites that already rely on it. The hardening is real and on by
  // default -- through the CLI, where a host can see and tune it.
  limits: {
    perIpConnections: 64,
    connectBurst: 1000,
    connectPerMinute: 6000,
    maxPending: 256,
  },
});

const log = createLog({ level: config.log.level });
for (const warning of warnings) log.warn(warning);

start({
  config,
  log,
  // This front door is the one deprecated caller that is *supposed* to bring
  // up a hub with no join code (see the header above): a LAN game, no config
  // file, and the startup warning below said out loud. Named here in as many
  // words rather than inferred, so lib/server.js never has to guess which
  // process is asking. See lib/server.js's start() for the option's contract.
  allowUnauthenticated: true,
}).then(() => {
  // Said out loud, once, because it is not visible from anywhere else: this
  // front door is open by design, and a host who put it on a public box
  // deserves to learn that from the hub rather than from a stranger.
  log.warn('This entry point is unauthenticated and has no per-address or ' +
    'connection-rate limits; run bin/rby-mmo-hub.js for a hub with a join ' +
    'code and the limits turned on.');
}).catch((err) => {
  log.error(`hub failed to start: ${err.message}`);
  process.exit(1);
});
