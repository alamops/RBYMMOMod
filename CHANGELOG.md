# Changelog

All notable changes to this mod are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version
here must match `manifest.version`.

## [0.2.5] - 2026-08-03

Not 0.2.3, which this branch originally claimed: `v0.2.3` and `v0.2.4` were
already tagged on `main` for the two fixes at the end of `Fixed` below, and
neither bumped `manifest.version` — which stood at 0.2.2 while two releases
went out on top of it. The first of them left no entry here at all and the
second left its notes under `Unreleased`. Both are written up below, under
the first version number nobody has used, which is what makes the heading
and the manifest agree again. Same slip as 0.2.1, recorded the same way.

### Added

- **`MY PROFILE` on the MMO menu.** Every other trainer's card was one A
  press away and your own was nowhere, so the one card you could not check
  was the one being read about you. It opens the same screen the `PROFILE`
  row opens for a peer, with the same rows at the same heights — what you
  look at here is literally what they see. It sits under `SAY`, so the rows
  people already reach for by muscle memory have not moved.
- **A `MONEY` row, on your own card only.** It is on the vanilla trainer
  card, and the reason it is absent from a peer's — somebody else's wallet
  is not this card's business — does not apply to your own. `Wire.profile`
  still refuses to carry money, so it cannot arrive from the network: a card
  holding a money value is necessarily the local one, which is what the
  screen keys off.

### Changed

- **`docs/screenshots/mmo-menu.png` recaptured, and `my-profile.png` added.**
  Both out of the end-to-end run, the way the rest of them are, so they are
  the build rather than a drawing of it. The menu shot had gone stale the
  moment the row landed — and it shows the box growing to fit `MY PROFILE`
  and nudging itself back on-screen, which is `Menu` sizing itself, not a
  layout that was hand-placed.

### Fixed

- **The trainer card drew names straight through the portrait.** `LOOK/` plus
  a character name was rendered at the same height as the art, where only 12
  characters fit, so anyone wearing one of the six longer characters was
  shown as `LOOK/COOLTRAI` with the rest under their own picture. `NAME/`
  had the same fault and needed a 9-character name to show it. Both rows are
  ones the *player* fills in, so neither can sit beside the art: the portrait
  now sits beside `IDNo` and `TIME`, the only two rows whose width their
  format strings bound. The character moved to a full-width row of its own
  and lost the `LOOK/` prefix — at 17 characters the longest name in the
  catalog *is* the whole row, so no prefix fits every case, and one that
  appeared only on short names would change the card's shape per character.
  Under the trainer's own name it reads the way the original prints a class
  before one. Both cards change together, so they still match row for row.
- **`TIME` on a trainer card always read `0:00`.** The card was built from
  `save.playtime`, and the engine's field is `save.playTime` — so the value
  was never there to send, and every peer's card claimed a brand-new file no
  matter how long they had played. The camelCase key is now read, with the
  old spelling still consulted so nothing that wrote it is discarded.
- **`client:playerName(game)` and `client:profile(game)` lost their
  argument.** Both were declared to take `game` directly while the menus call
  them with a colon, which puts the module table in that slot. `playerName`
  degraded to `PLAYER` for anyone who never opened the character creator,
  instead of falling back to the save's trainer name. Both now use the same
  `arg1` shim the rest of the module's entry points do.
- **The unread-chat marker drew nothing at all.** The row read `CHAT*`, and
  the font extracted from the ROM has no glyph for `*` — `Font.draw` draws
  nothing for a character it cannot map while `Font.width` still advances
  8px for it, so the row rendered as `CHAT` followed by a blank column that
  looked like a layout bug rather than a marker. It is now a leading `▶`,
  the same glyph the menu cursor is drawn with and one that is certainly on
  the sheet. The driver's label matcher accepts a marker on either side of
  a row name, since `▶` is three UTF-8 bytes and a leading one made every
  `selectLabel("CHAT")` compare against the marker's own bytes; the old
  trailing form still matches, so the util keeps working on older builds.
  The menu rows are now checked glyph by glyph against the live font in the
  end-to-end run — the one bug class an assertion on the label string is
  structurally blind to, and only answerable on a real dataset.
- **The typed line ran off the right of the screen.** `NamingScreen` lays its
  line out as `maxLen` slots of 8px from a fixed x=56, a layout sized for the
  vanilla seven-character name; every grid this mod opens is longer, so an
  address ran out to 312 and the port — the half most worth checking —
  disappeared off the edge. `Ui.fieldLayout` is a pure centred-and-windowed
  layout the mod repaints that one row with, on its own screens only. Shipped
  as tag `v0.2.3` with no entry here; written up now.
- **Leaving a game left you wearing the character you picked for it.** The
  chosen look is re-worn whenever the world may have rebuilt the player, and
  that path used to throw away the stashed trainer sheet first — but the
  overworld hands back the *same* player object across an ordinary map
  change, so what got stashed the second time was this mod's own renderer.
  One doorway was enough: leaving then "restored" you to the hub character,
  in your own single-player game, permanently. The original is now pinned to
  the entity it was taken from, so re-wearing cannot overwrite it and a
  player the engine genuinely rebuilt is left with its own sheet.
- **A dropped connection never gave the trainer back at all.** A timeout, a
  socket error or a hub hanging up tore down the roster and the avatars but
  nothing else, so a player who was disconnected rather than leaving stayed
  dressed as their hub character — and any trade session stayed open on a
  socket that was gone. An unasked-for leave now runs the same teardown a
  deliberate one does. Shipped as tag `v0.2.4`, under `Unreleased` until now.

## [0.2.2] - 2026-08-03

### Removed

- **The `JOIN CODE` row on the MMO menu.** It sat directly under `JOIN GAME`,
  which asks for the address and then the passcode on the way in, so two rows
  read as two halves of joining when only one of them joins anything — and
  the screen behind both is the same grid with the same title. Every road to
  a passcode that a player actually walks is unchanged: `JOIN GAME` asks for
  one before dialling and typing a different one there is how a saved
  passcode is changed, a hub that refuses one puts the player straight back
  on the grid, and `HOST GAME > JOIN CODE` still chooses the passcode this
  copy asks *for*. The `JOIN CODE` option row remains the standing fallback
  for a player who only ever plays on one hub.

## [0.2.1] - 2026-08-03

Hub-side only — nothing in the mod itself changed, and 0.2.0 and 0.2.1 speak
the same protocol. Written down after the fact: this shipped as tag `v0.2.1`
without a version bump or an entry here, so a copy of the mod reporting
`0.2.0` may be running either.

### Fixed

- **`/data/join-code.txt` no longer goes stale.** It held the whole of
  `init`'s first-boot output — the settings summary included — and nothing
  ever rewrote it, so a host who changed `maxPlayers` and read that file back
  saw the old number and a healthy hub looked broken. It now holds the
  passcode and nothing else, under comment lines naming the one thing that
  can still date it (a rotation) and what is authoritative when it does. The
  full `init` transcript survives for the failure path in `/tmp`, where it
  cannot outlive the boot that produced it.
- **The CLI stopped opening with "run `init` first".** Running a verb against
  a config it cannot see almost never means there is no hub — it means the
  wrong directory, or the host rather than the container. Taking the old
  advice minted a second config with a new passcode while the real hub
  carried on unchanged. It now says where it looked, names any config it can
  actually see, raises the container case first, and mentions `init` last,
  with what that costs.

### Added

- **A VPS deployment guide in `server/README.md`** — five commands on a fresh
  Ubuntu box, plus the four things that go wrong. Builds the image *on* the
  box, because a laptop is arm64 and a VPS is x86_64 and there is nothing to
  compile either way. Documents where the passcode actually lives and why it
  is deliberately kept out of `docker compose logs`, and the failure everyone
  hits once: two firewalls, `ufw` and the provider's own, both of which have
  to allow the port before a perfectly healthy hub stops looking broken.

## [0.2.0] - 2026-08-03

Hosting software for the standalone hub, and a **six-character passcode**,
required on both hosting paths, that keeps strangers out of either.
**The protocol moved from 1 to 2, so this mod and its hub have to ship
together** — an older copy of the mod cannot join a 0.2.0 hub, and is told so
in a sentence the game already renders rather than failing silently.

### Added

- **`--code CODE` on `init` and `invite`**, so a host can supply a passcode
  instead of taking a generated one — the way to make the hub answer to the
  same passcode as an in-game LAN game, or to pick something friends can
  remember. Normalised on the way in (`a7k3-p9` is `A7K3P9`), refused without
  echoing what was typed when it is not six usable characters, and refused
  outright when another credential already holds it.
- **A hosting CLI, `server/bin/rby-mmo-hub.js`** — the one place a host
  configures anything. `init` is a four-question wizard that writes
  `config.json` at mode 0600 and prints a passcode once; `start`, `status`,
  `config list|get|set`, `invite`, `invite list`, `revoke`, `ban`, `unban`,
  `allow`, `doctor` and `upnp enable|disable|status` cover the rest. Every
  setting is reachable from a verb — nothing requires hand-editing JSON —
  and the two that are not (`auth.credentials`, `version`) have verbs of
  their own for a reason. Exit codes: 0 success, 1 error, 2 usage.
- **A passcode, and the handshake that proves one.** The hub sends a
  per-connection nonce; the client answers `HMAC-SHA256(passcode, nonce)`, so
  the passcode never crosses the wire and a captured answer cannot be
  replayed. A passcode is **6 characters of a 32-symbol alphabet — 32⁶ = 2³⁰,
  exactly 30 bits** — with `I L O U` dropped so nothing is misread off a
  screenshot or misheard over voice, and every character on the mod's own
  naming grid. No grouping and no dashes: `A7K3P9` is the whole of it.
  Passcodes are a list, not a single secret: invites carry an optional
  expiry, a use budget and a revocation, so withdrawing one does not rotate
  everybody's.
- **A wrong-passcode throttle**, without which 30 bits would not be
  defensible online at all. Seven new settings
  (`limits.authFailureGrace` 3, `authFailureWindowMs` 10m,
  `authBackoffBaseMs` 2s, `authBackoffMaxMs` 5m, `authGlobalFailures` 100,
  `authGlobalWindowMs` 60s, `authLockoutMs` 60s) limit failures **per address
  and hub-wide**. The per-address half is an escalating backoff past a small
  grace, shaped so a friend who fat-fingers the code never notices it; the
  hub-wide ceiling is the half that does not improve when an attacker rents
  more addresses. A tripped ceiling stops the hub issuing challenges and
  nothing else — **players already in the world keep playing, undisturbed and
  unthrottled**, for the whole cooling period. `status`, `start` and `doctor`
  print the configured throttle in words.
- **Passcode entry in game, asked before anything is dialled.** `JOIN GAME`
  now asks for the address and then the passcode, in one straight line,
  rather than dialling and letting the hub's challenge interrupt a handshake
  that is already spending its ten-second budget. The address field takes 32
  characters and accepts an IP or a hostname, filling in port 7788 when none
  is given. `START > MMO > JOIN CODE` remains for changing a saved passcode,
  and is where a refused one lands. Stored per hub address, with a `JOIN
  CODE` option row as the fallback for a player who only plays on one hub.
- **`src/Sha256.lua`**, a pure-Lua SHA-256 / HMAC-SHA256 with a constant-time
  compare, written because `love.data.hash` is not available to the headless
  suite — so the game and the suite run byte-identical code. It uses LuaJIT's
  `bit` library when present and arithmetic peeling when it is not.
- **The in-game host requires a passcode too.** `src/Hub.lua` issues the same
  challenge, byte-compatible with the standalone hub, and `HostServer:start`
  refuses to open the port without a passcode. The `HOST GAME` screen mints
  one on arrival and shows it in the `JOIN CODE` row, so the common path is
  zero typing; the screen behind that row is for choosing your own. **There
  is no way to host an open game.** Those bytes come from a session entropy
  pool — frame timings, clock deltas, heap size, the player's own button
  presses, ratcheted through SHA-256 — which is **not a CSPRNG** and does not
  claim to be: ~35–45 bits drawn cold, 64 bits claimed from a game that has
  been running more than a moment. A hub facing the open internet should be
  the dedicated one, whose codes come from `crypto.randomBytes`.
- **Docker as a first-class path.** `docker compose up` in `server/` builds a
  `node:24-alpine` image running as UID 10001 on a read-only rootfs with all
  capabilities dropped, persists `config.json` on a named volume at `/data`,
  and mints a join code on the first run so an open world cannot be published
  by forgetting a step. TCP healthcheck written against Node's own `net`; no
  `curl` or `nc` added to the image.
- **Configuration with one precedence order**, honoured everywhere: CLI flag >
  `RBY_MMO_*` env var > config file > built-in default. `status` prints which
  of the four each setting came from.
- **Reachability reporting** in `start` and `doctor`: every interface
  classified (loopback, private, CGNAT/overlay, public), the address to hand
  out, or a flat statement that friends outside the network will not reach the
  port and the three ways to fix it. No third-party network calls, ever — no
  STUN, no "what is my IP", no port-check service.
- **Opt-in UPnP** (`upnp enable`), off by default, leased, removed on clean
  shutdown, and printing its full warning before a single packet: most home
  routers accept these requests with no authentication at all.

### Changed

- **Protocol 1 → 2** (`server/lib/relay.js`, `src/Config.lua`), for the two
  new message types `mmo.challenge` and `mmo.auth`. The hub's existing
  exact-match refusal is unchanged, so a mismatched client is told which
  version each side speaks.
- **`PROTOCOL` moved out of `server/hub.js` into `server/lib/relay.js`**,
  along with the whole protocol core — `hub.js` is now a thin shim over
  `lib/server.js`. `node hub.js`, `node hub.js 9000` and
  `RBY_MMO_MAX=8 node hub.js` behave exactly as before.
- **`node hub.js` warns at startup** that it is unauthenticated and has no
  per-address or connection-rate limits, and names the CLI that has both. It
  is still the right thing for a LAN game or a quick test.
- **A hub that would admit anybody does not start.** `auth.required: false`
  now means *the hub refuses to run*, not "anyone who reaches the port can
  join": `start` exits `1` naming the command that fixes it, `doctor` marks
  it `[fail]`, and `config set auth.required false` warns as it writes. Same
  refusal for `auth.required` on with every credential revoked, expired or
  used up — the configuration that *looks* configured and admits nobody. The
  one deliberate exception is the legacy `node hub.js` shim, which has no
  config file to keep a passcode in and asks for the exemption by name.
- **`--no-auth` is gone**, along with the wizard question that could decline
  a passcode. The flag is still recognised — as are `--auth false` and
  `--auth=off` — only so it can be answered with a sentence pointing at
  `--code` instead of falling through to "unknown option" and quietly writing
  an open hub. `init` overrules a passcode-less configuration from any
  source, including `RBY_MMO_AUTH_REQUIRED=false`, and says that it did.
- **Connection hardening, on by default under the CLI**: per-address
  connection caps, a token-bucket connect-rate limit, a handshake timeout
  separate from the idle timeout, a slowloris sweep for a peer that never
  finishes a line, a write-backpressure ceiling, bans and an exclusive
  allowlist. Every one of them is tunable, and the defaults are deliberately
  generous because the client has no auto-reconnect.
- **Log lines cannot be forged by a peer.** Every untrusted value is escaped,
  bounded and quoted, so a trainer name carrying a newline or an ANSI escape
  can no longer write into the host's terminal.
- `server/README.md` rewritten around the host who is not a developer: quick
  start, CLI reference, the full configuration table, the security posture
  including what the passcode does *not* protect, connectivity, and Docker.
  The security section states the 30-bit arithmetic outright rather than
  implying a number the format does not carry.

### Fixed

- **The address you type ran off the right of the screen.** `NamingScreen`
  lays its typed line out as `maxLen` slots of 8px from a fixed x=56, which
  fits the vanilla seven-character name and nothing longer. Every grid this
  mod opens is longer: at 32 the line ran to 312 on a 160-wide screen, so
  `192.168.1.20:7788` lost its port off the edge — the half a player most
  needs to check — and what was left sat hard against the right side instead
  of centred. Chat (16) overflowed too and a join code (12) stopped exactly on
  the edge. The mod now repaints that one row on its own grids: as many slots
  as fit between the margins, centred, showing the end of the line once it is
  longer than the window. No other screen is touched.
- **Silent sockets could lock everyone out of the hub.** `hub.js` registered a
  connection in its client table on accept, so the player cap counted peers
  that had never said `hello` — four of them held a four-player hub shut for
  45 seconds at a time. Seats are charged at `hello` now; ungreeted sockets are
  bounded separately by `limits.maxPending` and reaped by
  `limits.handshakeTimeoutMs`. `server/README.md` had claimed this was already
  true; it is true now.
- **A peer that never read grew the hub's memory without bound.** `send()`
  discarded `socket.write()`'s backpressure signal; the queue is now judged
  against `limits.maxWriteBufferBytes` and a peer past it is dropped.
- **One address could take every seat.** The player cap was the only limit
  there was.

### Notes

- **What 30 bits buys, stated plainly.** Online it is not the weak link: at
  the default `connectPerMinute` of 60, exhausting 2³⁰ from one address takes
  about 34 years — even odds around 17 — and that bucket is per address, so a
  distributed attacker divides it; a thousand addresses brings even odds
  inside a fortnight. The hub-wide failure ceiling is what answers that, and
  it does not improve when the attacker rents more hosts. **Offline it is the
  weak link.** There is no TLS on the game port, so anyone who can capture one
  challenge/response pair grinds it locally where no limit applies at all, and
  2³⁰ HMAC-SHA256 evaluations is seconds on commodity hardware. A captured
  pair should be assumed to yield the passcode. A six-character passcode keeps
  *strangers* out, not *eavesdroppers* — a deliberate trade for a code a
  person can read aloud once.
- Gameplay traffic is readable on the path and an active man-in-the-middle can
  proxy a whole session. There is no TLS because the client cannot speak it —
  LÖVE ships luasocket, not luasec. An encrypted overlay network is the only
  thing that closes that gap, and `server/README.md` says so in those words.
- `affects_link` stays `false`; no link registry is touched, so two players
  running this mod still fingerprint as vanilla.

## [0.1.0] - 2026-07-31

First working version. Ships disabled (`experimental: true`) — installing it
must not be what starts a network connection.

### Added

- **Shared overworld presence.** Other players on your map appear as real
  overworld NPCs, spawned through `mod.world`, walking tile to tile with the
  engine's own scripted-step timing.
- **Nicknames and speech bubbles** drawn over remote players from the
  `render.hud` hook.
- **Chat** in three scopes — global, nearby (same map, within 12 tiles) and
  private — composed on the engine's naming grid, with a scrollback screen.
- **Trade and battle requests** from anywhere in the world, reachable from
  the START > MMO menu or by facing another player and pressing A. Both run
  on the engine's own `Protocol.TradeSession` and `LinkBattle` over a
  `SessionNet` shim, so trade evolutions, OT bookkeeping and lockstep battle
  behave exactly as they do over a direct link.
- **Hosting from inside the game.** `START > MMO > HOST GAME` picks a player
  limit (2–64, host included) and starts a listener; `JOIN GAME` connects to
  someone else's. No separate process to install. The host's own client
  attaches over loopback, so from the client's perspective hosting and
  joining are the same thing.
  - `src/Hub.lua` is the relay as pure logic — no sockets — so the cap,
    chat scope routing and session pairing are testable headlessly.
  - `src/HostServer.lua` is the luasocket binding: non-blocking accept,
    newline-JSON framing, pumped from `input.step`.
- **A number page on this mod's naming screens.** The vanilla Game Boy grid
  carries no digits, so an address was literally untypeable. SELECT flips
  `ABC`/`123`; scoped by title, so every other naming screen is untouched.
- **A hub server** (`server/hub.js`) for a dedicated always-on relay: Node,
  no dependencies, same protocol and same 2–64 bounds. It relays; it never
  simulates.
- Mod options for the hub address, your avatar sprite, and whether bubbles
  draw.
- Inter-mod exports: `isConnected()`, `players()`, `say(scope, text, to)`.

### Fixed during end-to-end bring-up

Found by running two real LÖVE instances against each other; none of these
were visible to the headless suites.

- **Remote avatars never moved.** They were driven with `scriptMove`, the
  engine's cutscene primitive — which also gates the *local* player's input
  on the queue being empty, so it would have frozen your controls every time
  anyone else took a step. Avatars now start a step directly on the NPC
  (facing, target, moving, progress), which `NPC:update` animates over its
  own 16 frames: the full walk cycle, none of the input lock.
- **`SPRITE_RED` arrived as `SPRITERED`**: sprite ids were sanitised with the
  chat-text sanitiser, which strips underscores, so every remote player
  silently fell back to the default sprite.
- **A modal "Connected." box** sat over the world for the whole session. Routine
  status is a log line now; only things worth interrupting for get a box.
- **Wrapped chat lines had a ragged left edge.** The wrapper took its indent
  as the seed for the first line, so the opening row joined indent and first
  word with a space and sat one column right of every row beneath it. Only
  messages long enough to wrap showed it, which is why it took rendering the
  screen at size to notice.

### Distribution

- **Releases are built by CI, not by hand.** A push to `main` resolves the
  version, packs `rby_mmo-<version>.zip` with `manifest.json` at the archive
  root, and publishes it with `sha256sums.txt`. The version that wins is
  written into the packed manifest, so an installed copy cannot report a
  version its release does not have; an existing tag is refused rather than
  overwritten.
- **`manifest.github` points at this repo**, which is what turns on the
  launcher's update check — absent, it never looks. The archive is named
  `<id>-<version>.zip` because that is the name the check prefers.
- **The archive's contents come from `.modkitignore`**, read by the release
  job rather than duplicated in it, so a published release and `modkit pack`
  hand over the same files. Tests, drivers, dev tooling and `docs/` are
  excluded — `docs/` holds screenshots composited from ROM-decoded tiles,
  sprites and glyphs, which this project does not put in an archive it
  distributes.

### Proven end to end

Two real LÖVE instances, a real socket, driven through the game's own menus
(`tests/drivers/run-mmo-e2e.sh`):

- **A trade completes.** Host `CHARIZARD` → `PIKACHU`, guest `PIKACHU` →
  `CHARIZARD`. That is the engine's own `Protocol.TradeSession` running over
  this mod's hub, including `apply()` filing the received mon.
- **A link battle runs to a decision** with `battle.started`,
  `battle.ended` and **zero `link.desync`** on both sides — the lockstep
  simulation stayed in agreement across two processes.
- Map transitions, host↔guest movement, chat both ways, and the interact
  menu offering TRADE and BATTLE.

### Notes

- `affects_link` is `false` and the suite asserts the link surface is
  byte-identical with the mod installed, so two players running this mod
  still fingerprint the same as vanilla and can link normally.
