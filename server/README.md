# RBY MMO hub (standalone)

**You may not need this.** A player can host from inside the game —
`START > MMO > HOST GAME` — and that is the normal way to play. Reach for
this when you want a hub that stays up when nobody is playing, one on a box
with a public address so nobody has to forward a port, or one whose passcode
comes from a real CSPRNG rather than a Lua entropy pool.

**Both halves require a passcode.** The in-game host mints one on the way in
and cannot open a port without it; this hub refuses to start without one.
There is no open-world setting on either side, and no flag that brings one
back.

It is the same protocol and the same 2–64 player bounds as the in-game host
(`src/Hub.lua`); the two are interchangeable and a joining client cannot tell
them apart.

Node 22+, no dependencies. Everything below is Node core.

---

## Quick start

Two paths to the same thing: a hub that is running, requires a passcode, and
has put that passcode somewhere exactly one person can read it.

*Passcode* and *join code* are the same six characters — the in-game row is
labelled `JOIN CODE`, the CLI mints them with `invite`, and this page uses
whichever word the surface being described uses.

### Docker

```sh
cd server/
docker compose up -d
docker compose exec hub rby-mmo-hub invite list --reveal   # your join code
```

The first `up` on an empty volume runs `rby-mmo-hub init --yes` for you, so
the hub comes up *requiring* a join code — you cannot publish an open world by
forgetting a step. Every later start re-uses the same config and the same
code.

The code is **not** in `docker compose logs`. Container stdout is the log, and
the log is a file on the host's disk plus a copy in whatever an orchestrator
collects — durable, replicated storage for a credential, outside the 0600 file
that exists to hold it. So the first run redirects `init`'s output to
`/data/join-code.txt` (mode 0600, on the same volume as `config.json`) and
leaves one line in the log saying where to look. Either of these reads it
back:

```sh
docker compose exec hub rby-mmo-hub invite list --reveal
docker compose exec hub cat /data/join-code.txt
```

### Bare Node

```sh
cd server/
node bin/rby-mmo-hub.js init      # four questions; --yes takes the defaults
node bin/rby-mmo-hub.js doctor    # what would stop friends connecting
node bin/rby-mmo-hub.js start     # run it
```

`init` writes `config.json` (mode 0600) and prints the passcode once:

```
Configuration written to /srv/hub/config.json (mode 0600, readable only by you).

  listening on   0.0.0.0:7788
  players        up to 4
  join code      required (always -- there is no open-hub setting)
  log level      info

Your join code

      +------------+
      |   RM3P02   |
      +------------+

  Give that to the friends you want in your world. They type it once,
  in game, on the screen where they enter this hub's address. …
```

**Six characters, no dashes.** The wizard's third question is *which*
passcode, not whether to have one — it used to be "require a join code?", and
a host who answered *n* got a hub anyone could walk into. Press Enter and one
is generated for you. `--code
A7K3P9` on `init` picks your own instead, which is how you make this hub
answer to the same passcode as your in-game LAN game. Dashes, spaces and
lower case are normalised away, so `a7k3-p9` is the same passcode as
`A7K3P9`.

To see it again: `rby-mmo-hub invite list --reveal`.

### Where a friend types it

In game: `START > MMO > JOIN GAME`, make a trainer, then **the address and
the passcode are both asked for before anything is dialled** — the address
first, the passcode straight after it. The passcode is filed against that
address, so a player who plays on two hubs types neither of them twice.

The address field takes 32 characters and accepts an **IP or a hostname** —
`192.168.1.125:7788` and `MYBOX.EXAMPLE.COM:7788` both reach the socket
untouched. The naming grid is uppercase-only, which costs nothing: DNS is
case-insensitive. **Leave the port off and the mod fills in 7788**
(`Config.DEFAULT_PORT`) — worth knowing, because the engine's own fallback is
7778, the pokeserver relay's, and a bare hostname dialled there would report
the relay as unreachable.

There is no separate menu row for the passcode — `JOIN GAME` is the whole
path, and typing a different one there is how a saved passcode is changed.
The other way onto the passcode screen is a mistyped one: a hub that
challenges a copy whose passcode is absent or wrong hangs up, says *"This
game needs a join code."*, and puts the player back on the entry screen,
which dials again on save. The `JOIN CODE` option row in the mod manager is
the standing fallback for a player who only ever plays on one hub.

Every character in a passcode is on the mod's own naming grid, and
**SELECT** flips it between letters and digits — the vanilla grid has no
digits at all.

---

## What it is, and what it deliberately is not

It is a **relay**. It owns who is connected, where they last said they were,
and which two players are currently paired. It forwards bytes.

It does **not** simulate anything. Trades and battles run inside the two game
clients on the engine's own link code, with the hub passing opaque payloads
between them. A hub that refereed battles would be a second, worse
implementation of Gen 1's rules that could disagree with the clients — so
`mmo.relay` payloads are never parsed here.

It is also not a public server, and not an account system. There is no
identity beyond "holds a working join code"; two friends can be online under
the same name.

Wire format is newline-delimited JSON, the same framing `src/link/Net.lua`'s
relay backend already speaks, which is why the mod can reuse the engine's
transport instead of shipping its own socket code.

---

## The CLI

`node bin/rby-mmo-hub.js <command>` — or just `rby-mmo-hub` inside the
container, where it is on `PATH`.

| Command | What it does | Its own options |
| --- | --- | --- |
| `init` | first-run wizard: writes `config.json` at mode 0600 and prints a passcode once. Refuses to overwrite an existing file. | `--yes` (ask nothing, take flags and defaults), `--force` (replace an existing config), `--code CODE` (use this passcode instead of a generated one), plus any config flag below |
| `start` | loads the config, prints who can reach this machine, runs the hub until stopped. **Refuses to run on a group- or world-readable config**, printing the `chmod 600` that fixes it. | any config flag; `--limits.maxPending 12` works as well as `--max 8`; `--insecure-config` (run on a loose config anyway, printing what is being accepted) |
| `status` | every effective setting, its value, and where that value came from (`flag` / `env` / `file` / `default`). Codes masked. | — |
| `config list` | every setting, its current value, and its clamp range | — |
| `config get <path>` | one setting, e.g. `limits.maxPending` | — |
| `config set <path> <value>` | change one setting: clamped, reported, then saved | — |
| `invite` † | mint a join code and print it once | `--label TEXT`, `--expires 30m\|24h\|7d`, `--uses N`, `--code CODE` (use this passcode rather than a generated one) |
| `invite list` | every code: id, label, created, expires, uses, status. Masked by default. | `--reveal` (print them in full) |
| `revoke <id>` † | revoke one code. Ids come from `invite list`; a unique prefix is enough. | — |
| `ban <ip>` † | refuse an address. Normalised first, so every spelling of one address is one ban — see [Addresses](#addresses-what-one-address-means). | `--reason TEXT` (printed, **not** stored — the ban list holds addresses only) |
| `unban <ip>` † | stop refusing an address | — |
| `allow [<ip>]` † | with no argument, print the allowlist; with one, add to it. **An allowlist with entries is exclusive**: only those addresses may connect. | `--clear` (empty it) |
| `doctor` | configuration sanity plus a reachability report | — |
| `upnp enable\|disable\|status` | ask the router to forward the port. Off by default; `enable` prints the full risk note before it sends a packet. | — |
| `help [command]` | this table, or one command's own text | — |
| `version` / `--version` | print the version | — |

† **These edit `config.json`; a hub that is already running does not notice
until you tell it to look.** See
[Changing things while the hub is running](#changing-things-while-the-hub-is-running).

### `--code`, and the flag that is gone

`init --code CODE` and `invite --code CODE` take a passcode you choose rather
than one that was generated. It is normalised on the way in — six characters
from `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, with dashes, spaces and lower case
dropped — so `--code a7k3-p9` and `--code A7K3P9` are one passcode. Anything
that does not leave exactly six usable characters is refused, without echoing
what was typed:

```
$ rby-mmo-hub invite --code PQZX-Q1YP-FSXV-7J31
--code: that is not a passcode this hub can use.
A passcode is 6 characters from 0123456789ABCDEFGHJKMNPQRSTVWXYZ
-- the digits and the capital letters except I, L, O and U, which are
left out so nothing is mistyped off a screenshot. Dashes, spaces and
lower case are fine; they are normalised away.
```

(That example is a 16-character code from the format this replaced. There is
no upgrade path for one: `invite --code` a new six-character passcode and
hand it out.) `invite --code` also refuses a passcode already in the config,
naming the credential that holds it, because two credentials sharing a
passcode cannot each carry their own expiry and use count.

**`--no-auth` is gone.** It used to write a hub anyone who found the port
could walk into. It is still *recognised*, by name — along with `--auth
false` and `--auth=off`, which meant the same thing — only so it can be
answered with a sentence rather than "unknown option":

```
$ rby-mmo-hub init --yes --no-auth
A passcode is required, so there is no way to turn it off.

  --no-auth (and --auth false) used to write a hub anyone who found the
  port could join. Both halves of this software now require a passcode:
  the in-game LAN host asks for one, and this hub refuses to start
  without one.

  Run `rby-mmo-hub init` without it and a passcode is generated for you,
  or `rby-mmo-hub init --code A7K3P9` to choose your own.
```

Exit code `2`, and nothing is written. `init` overrules a passcode-less
configuration wherever it arrives from — file, flag or
`RBY_MMO_AUTH_REQUIRED=false` — and says out loud that it did.

Global options, valid on every command:

- `--config <file>` — which config file to use.
- `--help` — the command's own help instead of running it.

Flags are long-form only: `--flag`, `--flag value`, `--flag=value`,
`--no-flag`, and `--` to stop parsing. There are no short options.

Short spellings for the settings a host actually types: `--host`, `--port`,
`--max` (or `--max-players`), `--auth`, `--per-ip`, `--connect-burst`,
`--connect-per-minute`, `--handshake-timeout`, `--idle-timeout`,
`--partial-line-timeout`, `--max-pending`, `--max-write-buffer`,
`--chat-interval`, `--auth-failure-grace`, `--auth-failure-window`,
`--auth-backoff-base`, `--auth-backoff-max`, `--auth-global-failures`,
`--auth-global-window`, `--auth-lockout`, `--upnp`, `--upnp-lease`,
`--log-level`. Any dotted config path is also accepted verbatim, so nothing
needs a hand-written flag.

**Exit codes:** `0` success, `1` runtime error, `2` wrong usage. `doctor`
returns `1` when something would stop players connecting, `0` when only
warnings.

Join codes are printed by exactly three things — `init`, `invite`, and
`invite list --reveal`. They never go through the logger, and never appear in
`status`, `doctor` or an error message, so any of those is safe to
screen-share or paste into a forum thread. In the container the same rule is
why `init`'s output is redirected to a 0600 file rather than left on stdout:
stdout there *is* the log.

Masked is the default, and a masked code is six stars regardless of what is
behind it — the mask is not a side channel about the length or shape of the
secret. Telling two credentials apart is the `id` column's job:

```
$ rby-mmo-hub invite list
ID        LABEL              CREATED           EXPIRES           USES  STATUS  CODE
primary   Primary join code  2026-08-03 16:47  never             0     active  ******
a5fa1246  For Ash            2026-08-03 16:47  2026-08-04 16:47  0/1   active  ******

Codes are masked. --reveal prints them in full.
```

---

## Configuration

One file, `config.json`, written at mode `0600` because it holds join codes in
plaintext (the hub needs them to compute an HMAC). It is looked for in this
order:

1. `--config <file>`
2. `$RBY_MMO_CONFIG`
3. `./config.json` next to where you ran the command
4. `/data/config.json`, when `/data` exists — the container's volume

Precedence, everywhere, without exception:

> **command-line flag > `RBY_MMO_*` env var > config file > built-in default**

`status` prints which of the four each setting came from, which is the answer
to "why is it still 4 players".

Loading never fails. A stray comma, an unknown key or an out-of-range number
costs a warning, not an outage: out-of-range values are pulled to the nearest
end and reported, never obeyed.

| Setting | Default | Range | Env var | Meaning |
| --- | --- | --- | --- | --- |
| `version` | `1` | — | — | the config file's schema version. Maintained by this software, not a setting |
| `listen.host` | `0.0.0.0` | — | `RBY_MMO_HOST` | address to bind. `0.0.0.0` accepts on every address this machine has |
| `listen.port` | `7788` | 1–65535 | `RBY_MMO_PORT` | TCP port to listen on |
| `maxPlayers` | `4` | 2–64 | `RBY_MMO_MAX` | greeted players before new ones are refused |
| `auth.required` | `true` | — | `RBY_MMO_AUTH_REQUIRED` | whether a passcode is demanded. **`false` means the hub refuses to start** — it is still settable, so a config can be scripted or a report reproduced, but `start` exits `1` and `doctor` calls it a `[fail]` |
| `auth.credentials` | `[]` | — | — | the join codes. Managed with `invite` / `revoke` |
| `limits.perIpConnections` | `4` | 1–64 | `RBY_MMO_PER_IP` | connections one address may hold at once |
| `limits.connectBurst` | `10` | 1–1000 | `RBY_MMO_CONNECT_BURST` | depth of the per-address connect-rate bucket |
| `limits.connectPerMinute` | `60` | 1–6000 | `RBY_MMO_CONNECT_PER_MINUTE` | how fast that bucket refills |
| `limits.handshakeTimeoutMs` | `10000` | 1000–120000 | `RBY_MMO_HANDSHAKE_TIMEOUT_MS` | how long a connection has to finish `hello` (and `auth`, when required) |
| `limits.idleTimeoutMs` | `45000` | 5000–600000 | `RBY_MMO_IDLE_TIMEOUT_MS` | how long a greeted player may say nothing. The client has no auto-reconnect, so do not tighten this casually |
| `limits.partialLineTimeoutMs` | `10000` | 1000–300000 | `RBY_MMO_PARTIAL_LINE_TIMEOUT_MS` | how long a peer may sit on an unfinished line — the slowloris budget |
| `limits.maxPending` | `8` | 1–256 | `RBY_MMO_MAX_PENDING` | connections that have not said `hello` yet, in total |
| `limits.maxWriteBufferBytes` | `262144` | 16384–16777216 | `RBY_MMO_MAX_WRITE_BUFFER_BYTES` | queued bytes for one peer before it is dropped for not reading |
| `limits.chatIntervalMs` | `500` | 0–60000 | `RBY_MMO_CHAT_INTERVAL_MS` | minimum gap between one sender's chat messages. `0` turns the flood gate off |
| `limits.authFailureGrace` | `3` | 0–100 | `RBY_MMO_AUTH_FAILURE_GRACE` | wrong passcodes one address gets free before it starts backing off. `0` backs off from the first |
| `limits.authFailureWindowMs` | `600000` | 1000–86400000 | `RBY_MMO_AUTH_FAILURE_WINDOW_MS` | how long one address's failures are remembered. A day is the ceiling: a longer grudge is a ban, and `ban` is its own verb |
| `limits.authBackoffBaseMs` | `2000` | 100–3600000 | `RBY_MMO_AUTH_BACKOFF_BASE_MS` | the first wait imposed past the grace |
| `limits.authBackoffMaxMs` | `300000` | 1000–86400000 | `RBY_MMO_AUTH_BACKOFF_MAX_MS` | the ceiling that wait doubles to — reached on the twelfth wrong passcode at the defaults |
| `limits.authGlobalFailures` | `100` | 1–1000000 | `RBY_MMO_AUTH_GLOBAL_FAILURES` | wrong passcodes **hub-wide** in one window before the ceiling trips. The one limit that does not improve for an attacker who rents more addresses |
| `limits.authGlobalWindowMs` | `60000` | 1000–3600000 | `RBY_MMO_AUTH_GLOBAL_WINDOW_MS` | the window those are counted over |
| `limits.authLockoutMs` | `60000` | 1000–3600000 | `RBY_MMO_AUTH_LOCKOUT_MS` | how long a tripped ceiling refuses new join attempts. Players already in the world are untouched |
| `bans` | `[]` | — | — | addresses refused outright. Managed with `ban` / `unban` |
| `allowlist` | `[]` | — | — | when non-empty, the **only** addresses that may connect. Managed with `allow` |
| `network.upnp.enabled` | `false` | — | `RBY_MMO_UPNP` | whether `start` asks the router to forward the port |
| `network.upnp.leaseSeconds` | `3600` | 60–604800 | `RBY_MMO_UPNP_LEASE_SECONDS` | how long that mapping lasts before it expires on its own |
| `log.level` | `info` | `debug` `info` `warn` `error` `silent` | `RBY_MMO_LOG_LEVEL` | how much the hub says |

`RBY_MMO_CONFIG` is the odd one out: it names *where the file is*, not a value
inside it.

The seven `auth*` limits are the wrong-passcode throttle, and they are the
reason a six-character passcode is defensible online at all — the arithmetic
is under [Security posture](#security-posture). `status`, `start` and
`doctor` all print them in words rather than leaving them in the table:

```
Wrong-passcode throttle (configured here; the live counts belong to the
running hub and show up in its log, not in this command):
  per address   3 free attempt(s) per 10m, then a wait from 2s doubling to 5m
  hub-wide      100 failures in 1m shuts new joins for 1m
```

Those are the **configured** numbers, not a live reading. How many wrong
passcodes have actually arrived is known only to the running hub, which says
so in its own log; `status` and `doctor` are short-lived processes that read
a file, and there is no admin socket for them to ask through. `doctor` also
warns about settings that would bite the host rather than an attacker — a
`authGlobalFailures` no higher than `maxPlayers`, for instance, means a full
house mistyping the passcode once each can shut new joins.

**`config set` reaches every setting in that table but two.**

- `auth.credentials` — join codes are not edited as text. A mistyped one locks
  everybody out silently, so `invite` mints them and `revoke` withdraws them,
  both normalising properly on the way in.
- `version` — the file's schema version, maintained so older files keep
  loading. It is not a knob.

Nothing else needs the file opened by hand. If you do open it, that should be
curiosity rather than necessity.

### Changing things while the hub is running

`invite`, `revoke`, `ban`, `unban`, `allow` and `config set` all edit
`config.json`. **A hub that is already running holds its own copy**, so none of
them changes anything for the friends currently connected until the running
process is told to look again. That is one signal:

```sh
kill -HUP $(pgrep -f 'rby-mmo-hub.js start')   # bare node
docker compose kill -s SIGHUP hub              # docker
```

The hub logs `SIGHUP: re-reading the config`, then a line counting what it
found:

```
INFO SIGHUP: re-reading the config
INFO reloaded "/data/config.json": 2 join code(s), 2 usable; 1 ban(s); 0 allowlist entr(y/ies)
```

**Exactly three things are re-applied:** `auth.credentials`, `bans`,
`allowlist` — the decisions about *who may be here*. Everything else in the
file is a bind-time parameter and needs a restart:

| Change | Reload is enough | Needs a restart |
| --- | --- | --- |
| `invite` / `revoke` | ✓ the next handshake is judged against the new list | |
| `ban` / `unban` / `allow` | ✓ the next connection is admitted or refused by the new list | |
| `listen.port`, `listen.host` | | ✓ cannot change under a live listener |
| `maxPlayers` | | ✓ |
| `auth.required` (code demanded at all) | | ✓ the relay is handed a challenge port, or not, once at bind |
| `limits.*`, `log.level`, `network.upnp.*` | | ✓ |

For the four a host is most likely to have edited by mistake — `listen.host`,
`listen.port`, `maxPlayers` and `auth.required` — a reload that finds them
changed **says so** rather than pretending, so "why is it still on the old
port" is answered on screen rather than inferred:

```
WARN reload: listen.host, listen.port and maxPlayers were not re-applied -- they
     cannot change under a live listener. This hub is still 0.0.0.0:7788 for 4
     players until it is restarted.
```

The rest of the file — `limits.*`, `log.level`, `network.upnp.*` — is not
re-applied and not remarked on either. Restart for those.

Two things a reload does **not** do, both worth knowing before you rely on it:

- **It does not disconnect anybody.** Bans and the allowlist are checked when a
  connection is *admitted*. Someone already in the world stays there; a
  revoked code does not eject the player who already answered a challenge with
  it. To remove someone who is currently connected you still restart the hub —
  after which the new list keeps them out.
- **A file it cannot read changes nothing.** Config files get edited in place,
  so half a file is a normal thing to meet at an arbitrary instant. Bad JSON
  is logged and the credentials, bans and allowlist already in force are kept;
  it does not empty its own ban list because someone was mid-save.

A hub started without a config file — `node hub.js`, or an embedding caller —
has nothing to re-read, and says so.

---

## Security posture

Be clear-eyed about this before you expose a port.

### The passcode: exactly 30 bits

The hub sends a fresh random nonce; the client answers
`HMAC-SHA256(passcode, nonce)`. **The passcode itself never crosses the
wire.** A passcode is six characters from a 32-symbol alphabet with `I L O U`
removed, so 32⁶ = **2³⁰ — thirty bits, exactly**, down from the eighty a
sixteen-character code carried.

That is a deliberate trade, made because sixteen characters on a d-pad was
unusable, and it is worth stating what it costs rather than what it sounds
like.

**Online guessing.** At the default `limits.connectPerMinute` of 60, walking
all 2³⁰ passcodes past this hub from one address takes about **34 years** —
even odds at about 17 — with the attacker holding a connection budget open
the whole time, in full view of the host's log. **34 years, not 34,000**;
that figure is easy to overstate by a factor of a thousand and this page will
not. Raising `connectPerMinute` shrinks it in proportion: at its ceiling of
6000, even odds arrive in about two months.

**But that bucket is per address**, which is the whole problem. Divide the
number by however many addresses an attacker can rent: a thousand of them
brings even odds inside a fortnight, and the difference between decades and a
fortnight is a hosting invoice.

**That is why the throttle exists,** and why half of it is global. Wrong
passcodes are limited twice:

- **Per address** — `limits.authFailureGrace` (3) free failures per
  `authFailureWindowMs` (10m), then an escalating wait from
  `authBackoffBaseMs` (2s), doubling to `authBackoffMaxMs` (5m), which the
  twelfth wrong passcode reaches. From there one address gets twelve guesses
  an hour. This half is shaped for humans: a friend who fat-fingers the code
  a fourth time waits two seconds and never notices.
- **Hub-wide** — `limits.authGlobalFailures` (100) failures inside
  `authGlobalWindowMs` (60s) trips a ceiling that refuses new join attempts
  for `authLockoutMs` (60s). **This is the number that does not improve when
  an attacker rents more hosts**, and it is the only reason a 30-bit passcode
  is defensible online. A hundred wrong passcodes hub-wide in a minute is not
  something a friend group produces; a four-seat hub sees a handful across an
  evening. Held to ~100 guesses a minute, even odds on 2³⁰ sit at roughly a
  decade, with the log saying so the whole time.

**What a tripped ceiling does, exactly** — this matters, because it is the
part that sounds worse than it is. It stops the hub issuing challenges. That
is the entire blast radius: it does not touch the admission check, so
connections are still accepted; it does not appear in the idle/handshake
sweep, so nobody is disconnected for it; it reads no connection record at
all. **Every already-authenticated player keeps playing, undisturbed and
unthrottled, for the whole lockout.** A hub under attack goes temporarily
closed to newcomers, not down. The accepted cost is that a player holding the
*correct* passcode who arrives mid-attack is turned away until the cooling
period ends — a minute by default — and the hub says so in the log:

```
WARN too many wrong join codes across this hub (100 within 60s): new join
attempts are refused for the next 60 seconds. Players already connected are
not affected and stay in the game.
```

(One line in the log; wrapped here to fit.)

**Offline grinding, where none of that reaches.** There is no TLS on the game
port. Anyone who can capture a single challenge/response pair off the wire —
a shared LAN, a hostile router, a VPS neighbour — holds everything needed to
test passcodes locally, at their hardware's speed, with **no limit of any
kind applying**. 2³⁰ HMAC-SHA256 evaluations is seconds of work on commodity
hardware. **A captured pair should be assumed to yield the passcode.**

So, plainly: **a six-character passcode keeps strangers out, not
eavesdroppers.** It stops internet scanners, anyone who merely finds the
port, and anyone guessing from outside. It does not survive somebody who can
read your traffic. If the traffic can be captured, put everyone on an overlay
network (WireGuard, Tailscale, ZeroTier) and share the overlay address —
that, and nothing on this page, is what closes that gap.

### Where the passcode comes from

Thirty bits is the ceiling either way, but only one of the two hosting paths
reaches it from a real CSPRNG:

| Minted by | Source | What it is worth |
| --- | --- | --- |
| `rby-mmo-hub init` / `invite` (this server) | `crypto.randomBytes`, rejection-sampled so the alphabet stays uniform | the full **30 bits** the format allows |
| the in-game host (`START > MMO > HOST GAME`, `src/Client.lua`) | a Lua entropy pool — frame timings, `os.clock()` deltas, heap size, button-press timing, a burst of scheduling jitter at draw time, ratcheted through SHA-256 | **64 bits claimed** from a game that has been running more than a moment, which is every game that has reached that screen; **~35–45 bits** if something contrived to draw before a single frame had run. At six characters the passcode's own 30 bits are the binding constraint on the first path, and the pool is on the second. |

The in-game path is not a CSPRNG and does not pretend to be: a mod that
declares only `network` can reach nothing better — LÖVE ships no `randomBytes`,
`love.math.random` is a seeded xorshift, and `/dev/urandom` would mean a
filesystem permission this mod does not have. The same pool feeds `src/Hub.lua`'s
challenge nonces.

**So: a hub exposed to the open internet should be this one**, with passcodes
from `invite`. The in-game host is right for a LAN, a VPN, or people in the
same room. A player who wants a passcode this server minted can type it on
the `HOST GAME > JOIN CODE` screen, and `invite --code` points this hub at
one the game generated — the two are interchangeable.

- A passive eavesdropper cannot recover the code (HMAC is one-way) and cannot
  replay a captured answer: the nonce is per-connection and single-use, spent
  the moment it is consumed, pass or fail.
- Digests are compared in constant time (`crypto.timingSafeEqual` here, an
  accumulate-then-compare in the Lua client).
- Every credential is tried, with no early exit, so the refusal does not leak
  which code matched or how many the hub holds. A wrong code, an expired
  invite and a revoked one are one sentence: *"That join code was not
  accepted."*
- Credentials are a list. Each can carry an expiry (`--expires`), a use budget
  (`--uses`) and a revocation, so withdrawing one friend's invite does not
  rotate everybody's code. **A running hub re-reads that list on `SIGHUP`**,
  and only then; a revoke that is never followed by a reload or a restart has
  changed a file and nothing else. It also does not eject the friend who is
  connected right now — see
  [Changing things while the hub is running](#changing-things-while-the-hub-is-running).
- `config.json` holds the codes in plaintext, at mode 0600. **`start` refuses
  to run on a group- or world-readable file**, prints the `chmod 600` that
  fixes it, and exits `1`; `doctor` calls the same thing a `[fail]`. Warning
  and starting anyway would have left the exposure in place for exactly as
  long as the hub was running, which is the whole time it matters.
  `--insecure-config` starts on one anyway, for a host with a genuinely
  unusual setup, and prints what is being accepted. **It does not waive the
  passcode — nothing does.**
- **Two configurations refuse to start**, both with exit `1` and both naming
  the command that fixes them: `auth.required` false, and `auth.required` on
  with no credential that still works. The first admits anyone who finds the
  port; the second admits nobody, and *looks* configured. `doctor` marks
  each `[fail]` and exits `1` on them too, so the two commands never
  disagree.

### The link is still not encrypted

Everything above is about who gets in. Nothing above is about who can read
what happens next.

**Gameplay traffic — names, chat, positions, trade and battle payloads — is
readable by anyone on the path**, and an active man-in-the-middle can proxy
the entire session. There is no TLS on the game port because the client
cannot speak it: LÖVE ships luasocket, not luasec, and the engine opens a
plain `socket.tcp()`. That is also what makes the offline attack on the
passcode possible at all. Putting everyone on an encrypted overlay network
(WireGuard, Tailscale, ZeroTier) and sharing the overlay address is the only
thing that closes either gap.

### Connection hardening

All of it is on by default under `rby-mmo-hub`, and all of it is tunable.

- **Seats are charged at `hello`, not at accept.** A connection that has not
  identified itself does not hold a player seat. Ungreeted sockets are bounded
  separately by `limits.maxPending` (8) and reaped by
  `limits.handshakeTimeoutMs` (10 s). *This was not true before: the old hub
  registered a socket in its client table on accept, so four silent sockets
  could lock everyone out of a four-player hub for 45 seconds at a time.*
- **Per-address connection cap** (`limits.perIpConnections`, 4) and a
  **token-bucket connect-rate limit** (`limits.connectBurst` 10,
  `limits.connectPerMinute` 60). A rejected attempt still spends a token, so
  being over the cap does not buy a flooder free retries. Both count per
  address for IPv4 and **per `/64` for IPv6** — see
  [Addresses](#addresses-what-one-address-means).
- **A handshake budget separate from the idle timeout**, which the old single
  `socket.setTimeout(45000)` conflated.
- **Slowloris sweep**: a peer that starts a line and never finishes one is
  closed after `limits.partialLineTimeoutMs`, under both the 64 KiB line cap
  and the idle timeout.
- **Write backpressure**: a peer whose queued bytes pass
  `limits.maxWriteBufferBytes` is dropped. A client that connects and never
  reads used to grow the hub's memory without bound while looking healthy.
- **Bans and an allowlist.** Both match an **exact** address, normalised first
  so a dual-stack client cannot slip past a ban written in the other spelling
  and an IPv6 host cannot slip past one by respelling itself. An allowlist with
  entries is exclusive. Neither takes effect on a running hub until it is
  reloaded or restarted.
- **A wrong-passcode throttle, per address and hub-wide** (the seven
  `limits.auth*` settings, and
  [The passcode: exactly 30 bits](#the-passcode-exactly-30-bits) for why).
  Two limiters, two budgets: a refused passcode does **not** spend a connect
  token, so one roommate's typo cannot drain a shared household's connection
  budget, and `connectPerMinute` keeps meaning what it says. A refusal handed
  down by the throttle itself is not recorded as a failure either — retrying
  into a closed door must not extend an honest player's own backoff.
- A rejection that is a flood signal (banned, rate-limited) costs the sender
  nothing but the SYN; one an honest player could plausibly hit gets a
  sentence, because the game renders it.

### Addresses: what one address means

Two different questions, deliberately answered with two different keys.

**Bans and the allowlist match an exact address.** Everything is normalised
first, so the many legal spellings of one host are one entry: brackets and
`%zone` suffixes are stripped, hex is lowercased, IPv4-mapped and
IPv4-compatible forms fold to the dotted quad, and every IPv6 address is
re-emitted in canonical RFC 5952 form — leading zeros dropped, the longest run
of zero groups compressed to `::` (leftmost wins a tie, a single zero group is
never compressed).

```
2001:0db8:0000:0000:0000:0000:0000:0001  ->  2001:db8::1
2001:DB8::1                              ->  2001:db8::1
[2001:db8::1]                            ->  2001:db8::1
fe80::1%en0                              ->  fe80::1
::ffff:203.0.113.7                       ->  203.0.113.7
::ffff:cb00:7107                         ->  203.0.113.7
```

That is a fix, not decoration: a host bans the address they read out of a log,
and a ban stored in a spelling the kernel never emits reports success and then
never fires. Anything that does not parse as an address is stored exactly as it
arrived — nothing on the accept path throws.

**The connection cap, the connect-rate bucket and the per-address passcode
backoff all count per `/64` for IPv6**, and per exact address for IPv4.
`limits.perIpConnections` exists to bound one
household, and a household is a `/64` — the smallest block a residential IPv6
assignment hands out. Keyed by the full address it would not be a cap at all: a
client with a normal `/64` has 2^64 source addresses to open one connection
from each. The key is visible wherever the counts are — the running hub's
`stats().perIp` names it in full, so an IPv6 household appears there as
`2001:db8::/64` rather than as one of its addresses.

Not the other way round, in either direction: a `/64` **ban** would ban a
friend's whole ISP-assigned block on the strength of one address, and a `/64`
allowlist entry would admit every address in a block the host meant to name one
member of. Exact for policy, per-block for counting.

### Everything else that is still true

- Every inbound field is re-derived through a sanitiser; nothing arrives
  trusted, and a malformed line is dropped rather than being fatal.
- Every untrusted value in a log line is escaped, bounded and quoted, so a
  trainer name cannot forge a log line or repaint the host's terminal with
  ANSI escapes.
- Relay payloads are forwarded unread, but their *shape* is bounded — the
  decoder tolerates input deeper than the encoder can re-emit, and a deeply
  nested payload used to throw while being forwarded and take the hub with it.
- A message that will not serialise costs its own connection and nothing else.
  An uncaught error is logged and the hub carries on: a crash costs everybody
  a trade, a battle, and a reconnect the client cannot do for them.
- **Position is self-reported**, so a modified client can claim to be
  anywhere. That is unavoidable in a relay design and harmless for presence,
  but it does mean the `local` chat radius is not an enforceable boundary.

### The in-game host is not the hardened one

`src/Hub.lua` requires a passcode too — `HostServer:start` refuses to open the
port without one, the `HOST GAME` screen mints one on arrival and shows it in
the `JOIN CODE` row, and there is no longer any way to host an open game. The
exchange is byte-compatible with this one, so a joining client cannot tell the
two apart.

What differs is everything around it. Both its challenge nonces and the
passcode the `HOST GAME` screen offers come from the Lua entropy pool
described above rather than a CSPRNG — ~35–45 bits cold, 64 bits claimed once
the game has been running more than a moment. It also has none of the
hardening listed above: no per-address cap, no connect-rate bucket, no
wrong-passcode throttle, no ban list, no allowlist. Nothing slows a guesser
down there but the handshake itself.

That is fine for a LAN game among people in the same room, and it is the normal
way to play. A host who wants a passcode with a CSPRNG behind it can type one
this server minted into `HOST GAME > JOIN CODE`.

**A hub exposed to the open internet should be this one.**

Run one for people you know. It is not built to be a public server.

---

## Getting friends connected

`start` and `doctor` classify every address this machine holds — loopback,
private, CGNAT/overlay (`100.64.0.0/10`), public — and print the one to hand
out. There is **no phone-home**: every fact comes from this machine describing
itself, or, when you have turned UPnP on, from your own router. No STUN, no
"what is my IP" service, no port check, no telemetry.

The cost of that is honest, and `doctor` says it rather than guessing: local
interfaces cannot tell you whether a router in front of the machine forwards
the port. **"This machine has no public IPv4 address, so friends outside this
network will NOT reach this port"** means exactly that — nothing checked the
path, because checking it would mean asking a stranger. Conversely, an address
reported as public means it is publicly *routable*; a firewall on this machine
or in front of it can still block the port.

Three ways to be reachable, which is what `doctor` prints:

1. **Forward TCP 7788** on the router to this machine. By hand in the router's
   admin page, or with `upnp enable` below.
2. **Run the hub on a machine that already has a public address.** Any small
   VPS will do; it relays JSON lines and need not be powerful.
3. **Put everyone on an overlay network** (Tailscale, WireGuard, ZeroTier) and
   share the overlay address. This is also the only option that encrypts the
   traffic.

A public IPv6 address is reported too, but it needs a friend whose own network
has IPv6, and most routers firewall inbound IPv6 by default, so it usually
still wants a pinhole.

### On a VPS, end to end

Option 2 in full, on a fresh Ubuntu box — DigitalOcean, Hetzner, Linode, they
are the same five commands. Run them as `root`:

```sh
# 1. Docker, if the image you booted has none
curl -fsSL https://get.docker.com | sh

# 2. The code
git clone --depth 1 --branch v0.2.2 https://github.com/alamops/RBYMMOMod.git
cd RBYMMOMod/server

# 3. Build and run
docker compose up -d --build

# 4. The passcode (see below -- it is deliberately not in `docker compose logs`)
docker compose exec hub rby-mmo-hub invite list --reveal

# 5. What the hub thinks of itself
docker compose exec hub rby-mmo-hub doctor
```

#### Reading the passcode out of a container

The first run mints one and **does not print it to the log**, because a
container's stdout is the log: the json-file driver writes it to the host's
disk and an orchestrator ships it onward to wherever logs are collected. That
is durable, replicated storage for a credential, which is the one place it
should never be. So the log gets a signpost instead, and this is what you will
find in `docker compose logs hub` on a first boot:

```
first run: a join code was generated, and is deliberately not in this log.
  read it:  docker compose exec hub rby-mmo-hub invite list --reveal
  or:       docker compose exec hub cat /data/join-code.txt
```

The verb is the way to do it, at any time, not just the first boot:

```console
$ docker compose exec hub rby-mmo-hub invite list --reveal
ID       LABEL              CREATED           EXPIRES  USES  STATUS  CODE
primary  Primary join code  2026-08-03 22:11  never    0     active  AGNMVC

Codes are shown in full because --reveal was given. Anything that
records this terminal now holds them.
```

Without `--reveal` the `CODE` column is `******`, which is what makes
`invite list` safe to leave on screen while somebody is watching.

`/data/join-code.txt` is the other one the signpost names: the passcode the
hub was created with, at mode `0600` on the volume beside `config.json`, under
two comment lines. It is a convenience for the first boot and nothing reads it
back — deleting it costs you nothing, and is tidy if you would rather one fewer
copy existed.

It holds the code **and nothing else**, deliberately. It used to hold the whole
of `init`'s output, settings summary included, and since nothing ever rewrites
it, the first `config set maxPlayers 16` turned it into a stale file claiming
`players up to 4` — in the file this README tells you to read. If you are
looking at a hub whose settings you have changed, `status` is the answer and
this file is not; the only thing here that can still go stale is the code
itself, if you rotate it, which is what its comment lines say.

The passcode is also in `/data/config.json` in plaintext, because the hub has
to compute an HMAC with it. That file is `0600` in a `0700` directory owned by
the container's non-root user, and `start` refuses to run if its mode is
looser. Copying that volume copies a live credential.

Then open the port. A new droplet does not have one open for you:

```sh
ufw allow OpenSSH && ufw allow 7788/tcp && ufw --force enable
```

Friends use `<public-ip>:7788` and the passcode. That is the whole deployment.

**Build on the box; do not push an image to it.** Almost every VPS is x86_64
and most laptops worth developing on are now arm64, so an image built at home
and pushed will refuse to run with an exec-format error. Building on the
target costs nothing here — the app has no dependencies, so the build is a
copy, not a compile — and it gets the architecture right by construction.
The image is about 165 MB on top of the base layers, which is a disk
consideration, never a memory one.

**Two settings worth changing before you hand out the address.** `doctor` will
say `perIpConnections (4) is not below maxPlayers (4)`, which on a public
address means one address could take every seat:

```sh
docker compose exec hub rby-mmo-hub config set maxPlayers 8
docker compose exec hub rby-mmo-hub config set limits.perIpConnections 2
docker compose restart hub
```

**Check it from outside before you tell anyone.** `doctor` reads the machine's
own interfaces, so it cannot know whether anything in front of the box drops
the port — that is the honesty described above, not a gap. From your own
laptop:

```sh
nc -vz <public-ip> 7788
```

Connects, and the game will too. Hangs, and it is a firewall — and on most
providers there are **two** of them: `ufw` on the machine, and a cloud
firewall in the provider's control panel that `ufw` knows nothing about.
Both have to allow 7788. This is the single most common way a hub that is
running perfectly looks broken.

**Afterwards.** `restart: unless-stopped` is already in `compose.yml`, so the
hub comes back on reboot with no systemd unit to write. The passcode lives on
the named volume, so it survives restarts and rebuilds — `git pull &&
docker compose up -d --build` upgrades in place without your friends needing
a new code. `docker compose down -v` destroys that volume, which is also how
you deliberately rotate a code that has leaked.

**And the part that a public address changes.** Nothing here is encrypted
(see [The link is still not encrypted](#the-link-is-still-not-encrypted)). On
a LAN that is a small exposure; on a VPS your traffic crosses the open
internet, where anyone on the path can read chat and, from one captured
handshake, recover the passcode offline at their leisure. The throttle does
not apply to that — it cannot, it never sees the attempt. For a friends-only
world that is a normal trade. If it is not the trade you want, put the VPS on
an overlay network (option 3) and share the overlay address instead: same
hub, encrypted transport, and the `7788` firewall rule can then go away
entirely.

### UPnP

```sh
rby-mmo-hub upnp enable    # prints the full warning first, then asks the router
rby-mmo-hub upnp status    # what the router says is mapped right now
rby-mmo-hub upnp disable   # removes the mapping
```

Off by default, and only ever turned on by that verb. Read the warning it
prints, because it is the real risk:

> Most home routers accept these requests from **any** device on the network,
> with no authentication at all. That is not a flaw in this software — it is
> how UPnP works on most consumer hardware. The same door that lets this hub
> open a port lets a smart plug, a games console or a guest laptop open one,
> without asking you.

What it does: asks the router to forward one TCP port to this machine, on a
lease (`network.upnp.leaseSeconds`, default an hour) so a mapping outlives a
`kill -9` by at most that long, and removes it on clean shutdown and on `upnp
disable`. It contacts nothing except your own router, discovered by multicast
on the local link. Some routers refuse leases and only accept permanent
mappings; when that happens it is said out loud, and `upnp disable` is the way
back.

The removal on shutdown is **awaited before the process exits**, which is what
makes it real rather than a promise: removing a mapping needs an SSDP discovery
*and* a SOAP POST, and firing that from a signal handler alongside an immediate
`process.exit` used to tear it down mid-flight, leaving the port forwarded on
the router after every Ctrl-C and every `docker stop`. It is now a shutdown
hook the hub waits on, run at most once, and bounded — two seconds, after which
the hub says the router did not answer and stops anyway. A router that has gone
quiet must not be able to wedge Ctrl-C; when that happens a leased mapping
still expires on its own, and `upnp disable` removes a permanent one.

With UPnP on, `doctor` also asks the router for its own external address —
still local, still no third party.

---

## Docker

```sh
cd server/
docker compose up -d                              # build and start
docker compose exec hub rby-mmo-hub invite list --reveal   # the join code
docker compose exec hub rby-mmo-hub invite        # another code, for a friend
docker compose exec hub rby-mmo-hub doctor        # what can reach you
docker compose exec hub rby-mmo-hub config set maxPlayers 8
docker compose kill -s SIGHUP hub                 # apply codes/bans/allowlist
docker compose down                               # stop; volume and code remain
```

`docker compose exec` bypasses the entrypoint, which is why every other verb
is reachable that way — `rby-mmo-hub` is on `PATH` in the image. The verbs that
edit `config.json` change a file, not the running process; `kill -s SIGHUP` is
what makes the running hub re-read it (see
[Changing things while the hub is running](#changing-things-while-the-hub-is-running)).

What compose sets up:

- **`node:24-alpine`, non-root UID/GID `10001`**, fixed so a rebuild does not
  find `/data` owned by a different number. Alpine rather than distroless on
  purpose: the host who needs to shell in and read a code back out is exactly
  the audience.
- **A named volume at `/data`**, holding `config.json` — the join code, the
  bans, the allowlist. Losing the volume loses the code your friends saved.
- **A first run that keeps the code out of the log.** When `config.json` is
  absent the entrypoint runs `init --yes` with its output redirected into
  `/data/join-code.txt`, created under `umask 077` so it is 0600 before a byte
  of it exists, inside a 0700 `/data`. The log gets one line naming the file
  and the `invite list --reveal` command. If `init` fails, *that* output is
  printed — to stderr — and the file is removed, so a first run that cannot
  write its config still says why. Anything that copies this volume off the
  machine is copying a credential.
- **`read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`,
  `tmpfs: [/tmp]`.** The hub binds 7788, above 1024, so it needs no capability
  at all.
  **`read_only: true` works only because `/data` is a volume** — volume mounts
  stay writable through a read-only rootfs. Delete the `volumes:` block and
  keep `read_only`, and the first run dies with `EROFS` writing
  `/data/config.json`, which reads like a bug in the hub and is not.
- **`init: true` and tini in the image.** Without a real PID 1, SIGTERM does
  not reliably reach the hub and the goodbye it sends to connected players
  never goes out. `stop_grace_period: 15s` leaves room for the drain.
- **A TCP healthcheck written against Node's own `net`** — connect to
  `127.0.0.1:$RBY_MMO_PORT`, close, exit. No `curl` or `nc` is added to the
  image just to look at it. Two honest limits: it reads `RBY_MMO_PORT`
  (default 7788), so a port set only in `config.json` needs that variable set
  to match; and it dials loopback, so a `listen.host` bound to one specific
  non-loopback address reads as unhealthy.

`ports: - "7788:7788"` is the most-edited line in `compose.yml`; the left
number is the one on this machine and the one friends type.
`127.0.0.1:7788:7788` keeps it local while you test.

---

## `node hub.js` — the old front door, still open

```sh
node hub.js              # port 7788, 4 players
node hub.js 9000         # or pick a port
RBY_MMO_MAX=8 node hub.js
```

Unchanged, on purpose: no config file, no join code, no arguments but a port,
and the same three environment variables (`RBY_MMO_PORT`, `RBY_MMO_HOST`,
`RBY_MMO_MAX`, the last clamped to 2–64). Every command that ever worked here
still works.

**This is the one exception to "a passcode is required", and it is a
deliberate one.** There is no config file here to keep a passcode in, so this
shim is the single caller allowed past the refusal — it asks for that in as
many words (`allowUnauthenticated: true`), rather than reaching it by
accident, and `lib/server.js` refuses every other caller that would admit
anybody. It is **unauthenticated and has no per-address or connection-rate
limits**, and it says so at startup:

```
2026-08-03T03:02:39.208Z INFO RBY MMO hub listening on 0.0.0.0:7992 (protocol 2)
2026-08-03T03:02:39.209Z WARN This entry point is unauthenticated and has no per-address or connection-rate limits; run bin/rby-mmo-hub.js for a hub with a join code and the limits turned on.
```

Right for a LAN game, a quick test, or a hub only reachable over a VPN. Wrong
for anything with a port published to the internet — that wants
`bin/rby-mmo-hub.js`.

---

## Protocol

Every type is prefixed `mmo.` so it can never collide with the four control
types (`hosted`, `paired`, `join_error`, `peer_gone`) that `Net.lua` intercepts
on a relay connection.

**Client → hub**

| Type | Payload |
| --- | --- |
| `mmo.hello` | `proto, name, sprite, profile, map, x, y, facing` |
| `mmo.auth` | `response` — 64 lowercase hex chars, `HMAC-SHA256(joinCode, nonce)` |
| `mmo.move` | `map, x, y, facing, busy` — an absent cell means "not in the world" |
| `mmo.chat` | `scope, to, text` |
| `mmo.request` | `to, kind` (`trade` \| `battle`) |
| `mmo.respond` | `to, kind, accept` |
| `mmo.relay` | `to, payload` — opaque |
| `mmo.session_leave` | — |
| `mmo.ping` | — |

**Hub → client**

| Type | Payload |
| --- | --- |
| `mmo.challenge` | `nonce` — 32 lowercase hex chars, per-connection, single-use. Sent by every hub that requires a passcode, which is every hub but the `node hub.js` shim |
| `mmo.welcome` | `id, players[]` |
| `mmo.join` / `mmo.part` | `player` / `id` |
| `mmo.move` | a presence record |
| `mmo.chat` | `from, name, scope, text` |
| `mmo.request` / `mmo.decline` | `from, name, kind` / `name, kind` |
| `mmo.session` | `peer, peerName, kind, role, id` — the asker hosts |
| `mmo.relay` | `from, payload` |
| `mmo.session_end` | `reason` |
| `mmo.party_invite` | `from, name` — inbound; outbound it carries `to` |
| `mmo.party` | `id, members[]` — the whole membership, never a delta |
| `mmo.party_decline` | `name, reason` — `no`, or `in_party` |
| `mmo.party_end` | `reason` — `left` to the member who left, `peer_left` to the other |
| `mmo.error` | `message` — always fatal to the connection |
| `mmo.pong` | — |

Parties are two players and no more. The hub forms one only when *both* sides
are unattached, re-checks that at the moment of forming (either of them could
have joined somebody else's while the prompt sat on screen), and ends it for
both when either leaves or disconnects. A presence carries `party: true|false`
and never the party id — that flag is what gates the other players' `INVITE`
row, and an id on every presence would let any client map out who is
travelling with whom. `chat` gains a `party` scope, delivered to the party
alone with no radius; from a client with no party it is dropped, never
widened.

The handshake, in full:

```
client → hub    mmo.hello      { proto: 3, name, sprite, profile, map, x, y, facing }
hub    → client mmo.challenge  { nonce }        ← only when a passcode is required
client → hub    mmo.auth       { response }     ← HMAC-SHA256(passcode, nonce), 64 hex
hub    → client mmo.welcome    { id, players[] }   ← or mmo.error, which the game shows
```

The whole exchange has one ten-second budget, measured from when the socket
landed and **not** extended for the challenge leg — `limits.handshakeTimeoutMs`
here, `Config.HANDSHAKE_TIMEOUT` in the mod, deliberately the same number so
one client dialling the two hosting paths meets one deadline. A client with no
passcode to answer with hangs up rather than holding the socket open behind a
screen someone is still typing on.

On the one path where no passcode is required — the `node hub.js` shim — the
exchange is byte-identical to what it has always been: `hello`, then
`welcome`.

**`PROTOCOL` is 3**, and it lives in **`lib/relay.js`** (not `hub.js` any
more) and in **`src/Config.lua`**. Bump both together on any incompatible
change. The hub refuses a mismatched client by name and version — *"This hub
speaks protocol 3; your mod speaks 2."* — rather than letting two dialects
talk past each other, and the game renders that sentence.

3 is where parties landed, and it is worth saying why a purely *additive*
change moved the number. Nothing was removed, so an old client's messages all
still parse — but a **new** client on an **old** hub is the case that
matters: an invite and a party chat line are a message type and a scope that
hub has never heard of, and its handler table answers an unknown type with
silence. The player presses `INVITE` and watches nothing happen, forever,
with nothing on screen to act on. A refusal that names both versions is the
better sentence. **Update the hub and the mod together.**

---

## Tests

```sh
node hub.test.js     # from this folder
npm test             # the same file, through node --test
```

Starts the hub on a scratch port and drives it over real sockets: framing, the
protocol gate, scope routing, the flood gate, session pairing, relay isolation
between non-paired players, and teardown on a dropped socket.

The mod's own Lua suite runs from the engine checkout:

```sh
luajit mods/rby_mmo/tests/rby_mmo_test.lua
```
