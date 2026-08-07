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
the relay as unreachable. "Left the port off" is judged on the slot after the
last colon rather than on the colon itself, so `MYBOX.EXAMPLE.COM:` and
`MYBOX.EXAMPLE.COM:HUB` fill in 7788 the same way the bare name does. A port
that *was* typed is always the one dialled. Spaces are removed wherever they
appear — no address may contain one — which also keeps the dialled string
identical to the key the passcode is filed under.

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
| `players` | who is connected **right now**, and where they are: name, place name, `BUSY` / `PARTY`, ranked points. Reads the snapshot a running hub keeps (`status.json`) and prints how old it is. | `--json` (one object per player, the ten contract fields only — the nine the table is drawn from plus `admin`, which it does not draw) |
| `ranking` | the ranked season out of `ranking.json`: place, name, points, and how many battles each player has won and lost. Top ten, best first. | `--json`, `--all` (every player who has scored, not just the top ten) |
| `watch` | the `players` frame, repainted until Ctrl-C. Clears the screen between frames only when stdout is a terminal. | `--interval <s>` (seconds between frames, default 2, clamped 1–60), `--once` (one frame, then exit), `--json` |
| `history` | settled ranked battles out of `history.jsonl` and the rotated `history.jsonl.1`, newest first: when, who beat whom, and what it moved. | `-n N` (how many, default 20), `--json` (the same cut as one JSON array, projected records, newest first) |
| `stats` ‡ | the running hub's **live** counters: where it is bound, how long it has been up, seats taken, and the door — connections, handshakes in flight, wrong passcodes against the ceiling that trips, lockdown, and how many addresses are backing off. Counted from the hub's memory, which is the only place they exist. | `--json` (the hub's own answer, minus the per-address map) |
| `kick <name>` ‡ | remove a connected player. Matches the name case-insensitively and may hit nobody or several people; says which. | `--reason TEXT` (what the player is shown; defaults to *"An operator removed you from this hub."*) |
| `broadcast <text>` ‡ | say one line to everybody connected. It arrives in their chat log as `HUB`. | — |
| `config list` | every setting, its current value, and its clamp range | — |
| `config get <path>` | one setting, e.g. `limits.maxPending` | — |
| `config set <path> <value>` | change one setting: clamped, reported, then saved | — |
| `invite` † | mint a join code and print it once | `--label TEXT`, `--expires 30m\|24h\|7d`, `--uses N`, `--code CODE` (use this passcode rather than a generated one), `--admin` (mark the connections this code opens as an operator's — see [Admin codes](#admin-codes)) |
| `invite list` | every code: id, label, created, expires, uses, status, and **`KIND`** — `ADMIN` or `player`. Masked by default; `KIND` is shown either way. | `--reveal` (print the codes in full) |
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

‡ **These three are the opposite: they talk to the running hub and touch no
file at all.** They dial `admin.sock` beside the config, so they work only
while the hub is up — see [Talking to a hub that is
running](#talking-to-a-hub-that-is-running).

### Who is on it, and who is winning

Two read-only verbs, neither of which needs a game client and neither of which
changes anything:

```console
$ docker compose exec hub rby-mmo-hub players
3 player(s) online of 8 on 0.0.0.0:7788, snapshot 2s old.

NAME   LOCATION         STATUS  POINTS
HOSTY  PALLET TOWN              1012
ALPHA  VIRIDIAN FOREST  PARTY   1004
BETA   -                BUSY    996

A dash for LOCATION is a player in a battle or a menu: the hub is not
sent a position while they are there, so it does not have one to show.
STATUS is BUSY in a trade or battle, PARTY in a two-player party.
POINTS is the ranked score, blank for a player who is not ranked --
`rby-mmo-hub ranking` prints the whole board, including the players
who are not online now.
```

```console
$ docker compose exec hub rby-mmo-hub ranking
PLACE  NAME   POINTS  W   L
1      HOSTY  1012    14  3
2      ALPHA  1004    11  6
3      BETA   996     8   9

3 ranked player(s) -- the whole board.
```

`W` and `L` are wins and losses, and they are not new bookkeeping: the season
file has recorded how many battles each name has *played* and *won* since
ranked play shipped, and the two columns are that pair, projected. A player's
losses are `played - won`, which is why a draw — a battle that scored
nothing — appears in neither column. `--json` carries `played` and `won` as they are
stored, as it always has.

Bare Node is the same line without the `docker compose exec hub` in front of
it, and both take `--config <file>` like every other command — the two files
they read sit beside it.

**A dash in `LOCATION` is not a bug.** A player in a battle, a trade or a menu
is not standing anywhere the hub can name — `mmo.move` sends no cell while
they are there, deliberately, so a menu does not pin somebody to the tile they
opened it on. They stay on the roster and stay listed; only the place is
unknown, and the dash says exactly that.

Place names are the map id with its underscores taken out — `PALLET_TOWN`
becomes `PALLET TOWN`. That is a hub-side formatting of what the client
reported and nothing more; the names Kanto itself uses are decoded from the
player's own ROM, which is a thing only the game has, which is why the
in-game `PLAYERS` list reads better than this one does.

**`players` reads a snapshot, and is honest about it.** The CLI is a
short-lived process with no channel into the running hub (the same reason
`status` prints configured numbers rather than live counts), so the hub leaves
one behind: `status.json`, next to `config.json`, rewritten whenever the
roster changes and beaten every ten seconds regardless. Four things can come
back:

- **live** — a heartbeat inside the last 2.5 beats (twenty-five seconds, at the
  default ten-second beat; the file carries its own `heartbeatMs` and the CLI
  measures against that). The header says how old the reading is, because two
  seconds of lag is worth knowing about and worth not hiding.
- **stopped** — the hub shut down cleanly and stamped the file on its way out.
  *"The hub stopped 12m ago (0.0.0.0:7788), so nobody is online."* No roster,
  because it left none.
- **apparently down** — the file is there and the heartbeat is stale (older
  than 2.5 beats). The hub was killed, is wedged, or cannot write to `/data`.
  The last roster it wrote is still printed, under a heading that says in as
  many words that it is *not* who is online now — deleting the evidence would
  be less useful than labelling it.
- **no snapshot** — no `status.json` at all: this hub has not run since the
  feature shipped, keeps its files elsewhere, or has never run. Said in a
  sentence, in `doctor`'s tone, naming all three possibilities and the
  `docker compose exec` line that catches the commonest one.

All four **exit `0`**. "Nobody is home" is an answer, not a failure.

`ranking` has no such problem: `ranking.json` is written within a second of
any rating moving and does not go stale when the hub stops, because a finished
season is still the season. An absent or empty file is reported the same
gentle way — nobody has scored here yet.

### Watching it happen

`watch` is `players` and a loop: the same frame, repainted every couple of
seconds, until Ctrl-C.

```console
$ docker compose exec hub rby-mmo-hub watch
3 player(s) online of 8 on 0.0.0.0:7788, snapshot 1s old.

NAME   LOCATION         STATUS  POINTS
HOSTY  PALLET TOWN              1012
ALPHA  VIRIDIAN FOREST  PARTY   1004
BETA   -                BUSY    996

Read at 21:14:03, again in 2s. Ctrl-C stops.
```

- `--interval <s>` changes the two seconds, between **1 and 60**; anything
  outside that is pulled to the nearest end and reported rather than refused.
  There is little point below the hub's own heartbeat for an idle world — the
  snapshot is rewritten within a second of anybody joining, leaving or
  crossing a map, and every ten seconds regardless, so a faster repaint mostly
  redraws the same numbers with a larger age on them.
- `--once` prints exactly one frame and exits with **that frame's own exit
  code**, exactly as `players` would. That is the form a script, a cron line
  or a test wants.
- `--json` prints one JSON document per frame instead of the table, for
  something that is watching this rather than someone.
- Ctrl-C is a success, not an interruption: the verb stops, says that nothing
  it did ever spoke to the hub, and exits `0`.
- **The screen is only cleared when stdout is a terminal.** Redirected to a
  file or piped into something, `watch` writes plain frames one after another
  with no escape sequences in them — the difference between a log you can read
  later and a log full of `\x1b[2J`.
- Every state `players` can report, `watch` reports the same way, on every
  frame: a hub that stops mid-watch starts saying so rather than freezing on
  its last good roster, and a hub that comes back is picked up on the next
  repaint. Nothing here holds a connection to the hub; it is the file, read
  again.

### What has been played

`ranking.json` says who is on 1012 points. `history.jsonl` says how they got
there — one line per settled ranked battle, appended as it settles.

```console
$ docker compose exec hub rby-mmo-hub history -n 3
The last 3 of 412 settled ranked battle(s), newest first.

WHEN  WINNER  LOSER  POINTS   REMATCH
4m    HOSTY   BETA   +16/-16
21m   ALPHA   BETA   +8/-8    x2
50m   HOSTY   ALPHA  +16/-16

WHEN is how long ago the battle settled. POINTS is what the winner
gained and the loser lost; `rby-mmo-hub ranking` has the totals.
REMATCH marks a pair who had met before -- x2 is their second settled
battle, which the hub scores lower than the first.
```

- **Default is the last 20**, newest first; `-n N` asks for more or fewer, and
  a number larger than the file simply prints everything there is.
- **`REMATCH` appears only when one is in view.** It is why a result scored
  what it did: the hub pays a pairing that has already met inside the hour
  half, then a quarter, then nothing.
- Newest first is the ledger read backwards, not a sort on the timestamps: the
  hub appends in the order it settles battles, and sorting would let one
  hand-edited `at` reorder the lot.
- **Both generations are read**, older first, so a rotation is invisible from
  here: `history.jsonl.1` is opened before `history.jsonl`, the two are treated
  as one append-only stream, and `-n` and the count in the header span the
  pair. Either being absent is ordinary — there is no `.1` before the first
  rotation — and only both missing is "no match history".
- `--json` prints the same cut as **one JSON array**, newest first, carrying
  the projected records rather than the stored lines verbatim: a field a newer
  hub added, or a hand-edit slipped in, is not republished as part of this
  output.
- **A battle both players did not agree about is not history.** The hub scores
  a match only when the two reports match, so a draw, a disagreement, a
  dropped link and a battle played under a name whose claim was not proven all
  score nothing — and what scores nothing is not written here. This file is
  the ledger of the season, not of every battle that was started.
- **Missing or empty is an answer, not an error.** No file names all three
  things it can mean — no ranked battle has settled here yet, this hub
  predates the ledger, or it keeps its files somewhere else — and a file with
  no results in it says what does and does not get written. Both exit `0`,
  the way `ranking` treats an empty board, and `--json` still prints `[]`.
- **A line the reader cannot parse is skipped, and counted out loud** on
  stderr: a torn last line is normal after a hub was killed (the file is
  appended to — see [`history.jsonl`](#configuration) below), and more than
  one per generation means somebody has been editing it. A rotation freezes
  whatever torn line it moved aside, so the count covers both files. A reader
  that silently dropped lines would be a reader nobody could trust about the
  ones it kept.

### Talking to a hub that is running

`players`, `watch`, `history` and `ranking` all read files, which is why they
work on a hub that is switched off. **`stats`, `kick` and `broadcast` are the
other kind**: they need the hub to be up, and they reach it through a Unix
socket the running hub opens beside its config — `admin.sock`. `kick` and
`broadcast` are instructions, and no file can carry one; `stats` is a
question, but about counters that live in the hub's memory and are written
nowhere.

```console
$ docker compose exec hub rby-mmo-hub broadcast Server restart in 5 minutes.
Delivered to 3 player(s).

$ docker compose exec hub rby-mmo-hub kick BETA --reason Take the evening off
Kicked 1 player(s): BETA.
They were shown: Take the evening off
A kick is not a ban: the same passcode gets them back in. `ban <ip>`
or `revoke <id>`, then a reload, is what keeps somebody out.
```

- **Quotes are optional on both.** Everything after `broadcast` is the
  message, and everything after `--reason` is the reason, joined with spaces —
  the same rule `config set` already follows for a multi-word value.
- **The kicked player is told why.** The reason is delivered as the same
  fatal error the game already renders for a refused join, so it appears on
  their screen rather than only in your log; with no `--reason` it is *"An
  operator removed you from this hub."* They are then disconnected and taken
  off everybody's roster, and any trade or battle they were in ends the way it
  does for any player who drops.
- **A kick is not a ban.** They can reconnect immediately with the same
  passcode, which is what the verb says as it reports. To keep somebody out,
  `ban` their address or `revoke` the code they used, reload, *then* kick.
- **A name can match nobody, or several people.** Trainer names are unique
  only among *ranked* players — two friends who never changed the default can
  both be `RED` — so the match is case-insensitive, hits every connected
  player wearing that name, and the verb reports the count and the names. A
  kick that matched nobody says *"Nobody by that name is connected. Nothing
  was done."* and exits `0`: the hub was reachable and the instruction was
  carried out, there was simply nobody to carry it out on.
- **A broadcast is an ordinary chat line named `HUB`.** It lands in the chat
  log of everybody connected, with no bubble over anybody's head, and it is
  held to the same length and the same characters as any other chat message.
  A delivery count of zero says the two things it can mean: nobody is in the
  world, or nothing survived that cleaning.
- **`HUB` is a reserved trainer name.** A hub-originated line carries no sender
  id, so the name is the only thing telling a player the hub said it — which
  is why a player connecting as `HUB`, in any spelling, is refused and asked
  to pick another name.

**`rby-mmo-hub stats` is the reading no file holds.** `status` prints what the
limits are *configured* to be, off `config.json`; the counters below are what
they *are* right now, and they exist only in the running process:

```console
$ docker compose exec hub rby-mmo-hub stats
The hub
  address   0.0.0.0:7788
  uptime    14s
  protocol  5
  players   3 of 8
  pending   1 connection(s) not in the world yet

The door
  connections  4 open, from 1 address(es)
  handshakes   1 connection(s) still to be greeted
  wrong codes  1 of 100 in the last 1m
  lockdown     no
  throttled    0 address(es) backing off now
  tracked      1 address(es) with failures remembered

Live counters, read from the hub itself: they are kept in its memory,
written to no file, and gone when it stops. `rby-mmo-hub status` prints
what the same limits are *configured* to be, which is the other half of
the reading. Two pendings, because they are counted either side of the
handshake and a connection in flight is briefly in one and not the other.

Addresses are counted and never printed. Who is connected, by name, is
`rby-mmo-hub players`.
```

- **`wrong codes` is a windowed estimate, not a tally.** The hub-wide counter
  decays across its window rather than resetting on a boundary, so it is
  rounded on the way out and reads a little under a burst that is already
  ageing. The `of 100` beside it is `limits.authGlobalFailures`, so the
  reading always carries its own scale; `lockdown` says whether that ceiling
  is tripped this second, and for how much longer.
- **Two pendings, and they are different counters.** The hub's is connections
  that have not become players; the door's is connections the limiter has
  accepted and not yet seen greeted. They are the same event counted either
  side of the handshake, so a connection in flight is briefly in one and not
  the other.
- **No address is ever printed, in either form.** The socket's answer carries
  a `perIp` map keyed by the address each connection came from; this verb
  counts its keys and drops the map — `--json` drops it too, replacing it
  with an `addresses` count at each level it appeared on. Who is connected by
  name is `players`; an address is `ban`'s business, not a report's.

```console
$ rby-mmo-hub stats --json
{
  "host": "0.0.0.0",
  "port": 7788,
  "protocol": 5,
  "maxPlayers": 8,
  "players": 3,
  "pending": 1,
  "connections": 4,
  "authRequired": true,
  "startedAt": 1786061988945,
  "uptimeMs": 14374,
  "limits": {
    "connections": 4,
    "pending": 1,
    "auth": {
      "recentFailures": 1,
      "failureThreshold": 100,
      "windowMs": 60000,
      "lockdown": false,
      "lockdownMs": 0,
      "throttledAddresses": 0,
      "trackedAddresses": 1
    },
    "addresses": 1
  },
  "addresses": 1
}
```

**When the socket is not there**, all three verbs say the two things that can
mean, and exit `0` — an absent hub is an answer, the same way `players` treats
a missing snapshot:

```
$ rby-mmo-hub broadcast hello
No admin socket at /data/admin.sock.

  The hub opens that socket while it runs and removes it on the way
  out, so there being none means one of two things: no hub is running
  against this config file, or the hub that is running predates the
  admin channel and has to be restarted before it will open one.

  It sits beside the config file, so `--config <path>` moves both. If
  the hub runs in Docker, the socket is inside the container:
      docker compose exec hub rby-mmo-hub broadcast hello
```

Two neighbouring cases are told apart rather than folded in: a socket file
with nothing listening on it is a hub that was **killed** — Unix sockets
outlive the process that made them, and starting the hub again clears it — and
a socket this user may not open is a real failure with a real fix (run as the
user the hub runs as; `docker compose exec hub` already does), which exits
`1`.

The socket is documented with the rest of the hub's files under
[Configuration](#configuration), including the one thing worth knowing before
you rely on it: **there is no password on it, and the data directory's own
permissions are the whole boundary.**

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
`--no-flag`, and `--` to stop parsing. There are no short options, with one
exception: `history -n <count>`, which is the spelling every other tool that
prints the last N of something already uses.

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
ID        LABEL              CREATED           EXPIRES           USES  STATUS  KIND    CODE
primary   Primary join code  2026-08-03 16:47  never             0     active  player  ******
a5fa1246  For Ash            2026-08-03 16:47  2026-08-04 16:47  0/1   active  player  ******

KIND: none of these is an admin code. `rby-mmo-hub invite --admin` mints
one; the hub marks that connection and shows it as ADMIN.

Codes are masked. --reveal prints them in full.
```

### Admin codes

`invite --admin` mints a join code that **marks the connection it opens**. It
is an ordinary join code in every respect that matters to the game — six
characters from the same alphabet, typed on the same screen, answering the same
challenge, admitted the same way — and it carries one extra flag, which the hub
records against the connection that answered with it:

```console
$ rby-mmo-hub invite --admin --label Me
New admin join code (id 32d04096, Me)

      +------------+
      |   JMYD60   |
      +------------+

  That is an admin code. It joins the world exactly like any other
  code -- typed once, in game, on the screen where this hub's address
  goes -- and what it adds is a mark on the connection:

    - whatever operator features arrive in game later. Nothing uses
      it there yet; the hub already marks the connection, so when
      those exist this code is what they will look for.
    - today the mark is visible where you watch from: ADMIN in the
      KIND column of `rby-mmo-hub invite list`, and on the connection
      in the rosters -- status.json, `players --json`, and the
      `who` answer on the admin socket.

  Give it only to someone you would hand the hub itself to.

  It has no expiry. An admin code is worth more to a thief than a
  player's one is, so if this is for one evening or one person,
  mint it with `--expires 24h` and let it stop working on its own.

  This is the only time it is printed in full. To see it again:
      rby-mmo-hub invite list --reveal

A running hub picks this code up on a reload; a restart works too:
    kill -HUP $(pgrep -f 'rby-mmo-hub.js start')   # bare node
    docker compose kill -s SIGHUP hub              # docker
That is all an admin code needs: the mark is read off the credential
when somebody joins with it, so there is nothing further to start.
```

The paragraph about expiry is printed **only when there is no `--expires`**,
because an end date is the one protection that does not depend on somebody
noticing a code went missing. Pair `--admin` with `--expires 24h` for an evening or a
guest operator, and mint a fresh one when you need it — nothing about this is
precious, and `revoke <id>` takes one back exactly as it does a player's.

- **It is not a second kind of credential**, and there is no admin verb family:
  one flag on one list, minted with `invite`, listed with `invite list`,
  withdrawn with `revoke`. `--label` defaults to `Admin` rather than `Invite`
  when the flag is given, so the row is legible a month later.
- **`--admin` takes no value.** `--admin=true` and `--admin=off` are read
  rather than quietly discarded, and anything that is neither a yes nor a no
  refuses and mints nothing: a host who typed `--admin=true`, got a player's
  code and read past the word *admin* has been misled in a way that is very
  easy to miss. This flag never guesses in favour of privilege.
- **`--uses` counts game joins, exactly as it does on a player's code.** The
  flag changes what the hub records about a connection, not how one is
  admitted, so nothing about the budget is special here: `--uses 1` means one
  join to the world, and a spent code is a spent credential that opens nothing
  at all.
- **The `KIND` column marks it either way**, with or without `--reveal`. What a
  code marks is not a secret; the code itself is:

```console
$ rby-mmo-hub invite list
ID        LABEL              CREATED           EXPIRES  USES  STATUS  KIND    CODE
primary   Primary join code  2026-08-06 17:56  never    0     active  player  ******
32d04096  Me                 2026-08-06 17:56  never    0     active  ADMIN   ******

KIND ADMIN: joins the game like any code, but the hub marks the
connection for the operator features arriving in game later. Here that
mark is the word ADMIN in this column; in the rosters -- status.json,
`players --json`, and the `who` answer on the admin socket -- it is an
`admin` flag on the connection. `rby-mmo-hub revoke <id>` takes one back.

Codes are masked. --reveal prints them in full.
```

- **In game it does nothing yet.** There is no operator menu, no command and no
  button; the hub marks the connection an admin code opened — the client is
  told about itself on the welcome, and operator views (`status.json`, the
  admin socket's `who`, `players --json`) carry the flag — so the in-game
  operator features that want one have something to check when they are built.
  Other players are never told: the flag is deliberately absent from the
  presence record broadcast to everybody.
- **A hub with no credentials has no admins.** The flag rides a credential, so
  `auth.required` false and the `node hub.js` shim have nobody privileged on
  them by construction.

---

## Looking at the hub from somewhere else

**The operator surface is the CLI, and there is nothing else to reach.** This
hub opens exactly one port, the game port; there is no web page, no second
listener and no second credential. To operate a hub that is not on the machine
in front of you, **SSH to the box** and run the same verbs there — inside the
container with `docker compose exec hub rby-mmo-hub …`, or straight against the
config with `--config` on bare Node. Everything a page could have drawn is
already a verb: [`watch`](#watching-it-happen) for the live frame,
[`players`](#who-is-on-it-and-who-is-winning) for one reading of it,
[`ranking`](#who-is-on-it-and-who-is-winning) for the season,
[`history`](#what-has-been-played) for the battles behind it, and
[`stats`](#talking-to-a-hub-that-is-running) for the live door counters —
connections, handshakes in flight, wrong passcodes and lockdown — which are
kept in the hub's memory and reach no file at all. Reached that way
it is **encrypted and authenticated by SSH itself**, with the host's own keys
and the host's own account — which is a better answer than this program could
have written for itself, since it carries no TLS anywhere and never will while
it is Node core and zero dependencies.

---

## Configuration

One file, `config.json`, written at mode `0600` because it holds join codes in
plaintext (the hub needs them to compute an HMAC). It is looked for in this
order:

1. `--config <file>`
2. `$RBY_MMO_CONFIG`
3. `./config.json` next to where you ran the command
4. `/data/config.json`, when `/data` exists — the container's volume

Next to it, the hub keeps three files it writes itself and opens one socket.
None of them is a setting and none of them is yours to edit; each can be
deleted without consequence beyond what it holds.

The first is **`ranking.json`**, the
ranked-PVP season. It holds a line per trainer name — points, character, and
how many battles they have played and won — and it is written (debounced)
whenever a battle moves somebody's rating. Nothing reads it but this hub, no
setting points at it, and deleting it starts a fresh season and changes
nothing else. It is deliberately *not* a section of `config.json`: that file
is yours to edit and the CLI rewrites it whole, and a hub writing scores into
it would race your own edits.

If the file is corrupt the hub says so and starts from an empty ranking
rather than refusing to run — a leaderboard is not a reason to take a hub off
the air.

Ratings are keyed by **trainer name**, and a name is *claimed* by whoever
first used it here. The hub mints a 16-byte token on that first visit
(`crypto.randomBytes`), sends it once in the welcome, and stores only its
SHA-256 — so this file lists who is ranked, which is public anyway, and gives
nobody a way to be them. A player returning with the token is that player; a
player typing the same name without it is admitted, plays normally and scores
nothing, and their battles cannot move the real holder's rating. It is a
claim ticket, not an account: it sits in a save file and crosses the same
unencrypted link the passcode does, with the same consequence if either is
captured. Deleting `ranking.json` releases every name along with every score.

The second is **`history.jsonl`**, the match ledger
[`history`](#what-has-been-played) reads: one JSON object per line, appended
as each ranked battle settles, oldest line first.

```json
{ "at": 1754300012345, "startedAt": 1754300000000, "repeats": 0,
  "winner": { "name": "RED", "points": 27, "gained": 16 },
  "loser":  { "name": "BLUE", "points": 3, "lost": 16 } }
```

- `at` and `startedAt` are when the battle settled and when it began;
  `points` on each side is the rating **after** the match, and
  `gained`/`lost` is what moved. `repeats` is how many times that pairing had
  already met inside the rematch window, which is why the swing on the third
  meeting of an evening is smaller than the first.
- **Only settled ranked battles are here.** A draw, two players who reported
  different outcomes, and a match under a claim the hub would not honour all
  score nothing, and what scores nothing is not written.
- **This is the one file the hub appends to** rather than writing whole and
  renaming over, and deliberately: a history is only ever the old lines plus
  one more, so rewriting it to add a line would mean reading back every battle
  ever played on the path of the one that just finished, and putting all of
  them at risk on every write. Created at mode 0600 like everything else here.
- **The cost of appending is a torn last line**, if the hub is killed
  mid-write. There is no way to append and be atomic at once; the reader skips
  a line it cannot parse and carries on, which bounds the damage to at most
  one line per crash.
- **It is bounded at roughly a megabyte, in two generations.** Before an
  append that would take it past **512 KiB**, the file is renamed to
  `history.jsonl.1` — replacing any previous `.1` — and a fresh ledger is
  started. A rename is atomic and cannot lose the file it is moving. Half a
  megabyte is somewhere around three thousand battles, so a hub holds between
  three and six thousand of them and the older half falls off the end. If you
  want to keep a season forever, copy the file; nothing here will do it for
  you, and nothing here will grow without bound either.
- **`history` reads both generations**, `.1` first, so a rotation does not
  hide half the ledger from the verb that exists to print it. The `.1` is a
  plain file of the same lines in the same format — `cat` it, feed it to
  anything that reads the current one, or move it somewhere else to keep it.
- **It holds no secrets** — trainer names and numbers, the same things
  `ranking.json` already holds in public. Safe to `cat`, safe to hand to
  somebody writing a stats page.
- Deleting it loses the record and nothing else: the ratings live in
  `ranking.json` and are not recomputed from here.

The third is **`status.json`**, the snapshot [`players`](#who-is-on-it-and-who-is-winning)
reads. It is the running hub's answer to a question a short-lived CLI process
cannot otherwise ask it — who is connected, and where:

```json
{
  "version": 1,
  "startedAt": 1754300000000,
  "updatedAt": 1754300012345,
  "heartbeatMs": 10000,
  "stoppedAt": null,
  "host": "0.0.0.0", "port": 7788, "protocol": 5, "maxPlayers": 8,
  "players": [
    { "name": "RED", "sprite": "SPRITE_RED", "map": "PALLET_TOWN",
      "x": 5, "y": 6, "busy": false, "party": false,
      "points": 12, "ranked": true, "admin": false }
  ]
}
```

- **Written whole and renamed over the old file, at mode 0600**, exactly the
  way `ranking.json` is: a hub killed mid-write leaves the previous snapshot
  intact rather than half a document nothing can parse.
- **Written on four occasions**: at startup, on a roster change (debounced a
  second), on a heartbeat every **10 seconds** whether or not anything
  changed, and once more on a clean shutdown — that last one sets `stoppedAt`
  and empties `players`, which is what lets a reader distinguish "stopped"
  from "died". A reader treats a gap of more than 2.5 heartbeats as a hub that
  is no longer running.
- **The file says how often it is written.** `heartbeatMs` is the interval the
  writing hub is actually keeping, and `players` measures staleness against
  *that* rather than against a number of its own — so a hub on a slower beat is
  not called down for keeping it. 10 seconds is only the assumption for a file
  written before the field existed.
- **A step is not a roster change.** Joining, leaving, starting or finishing a
  trade or battle, teaming up, being scored, and *crossing into another map*
  all mark it dirty; walking around inside one map does not, because the
  snapshot is a list of places and the place did not change. `x`/`y` therefore
  catch up on the next heartbeat rather than on the next step, which is the
  difference between a file and a file the disk is asked about eight times a
  second per player.
- **It holds no secrets.** Names, characters, map cells and points — the same
  things every other player in the world can already see. No join codes, no
  claim-ticket hashes, no session or party ids, no player addresses — the
  hub's own bound `host`/`port` are in there, but those are already in
  `config.json`. It is safe to `cat` on a shared screen, which `config.json`
  is not.
- `map` stays the raw engine id (`PALLET_TOWN`); turning that into
  `PALLET TOWN` is the reader's job, not the file's.
- Deleting it costs one heartbeat. It is state about *this instant*, not
  history, and nothing reads it but the CLI.
- **A hub with no config file writes none.** The snapshot's home is "beside
  `config.json`", so `node hub.js` and an embedding caller — neither of which
  has one — keep their roster in memory and nowhere else. `players` on such a
  hub reports no snapshot, which is the truth.
- A write that fails — full disk, read-only mount, a volume that went away —
  is a `WARN` in the log and nothing more. A hub that stopped relaying because
  it could not write a status file would have failed at the job the file only
  reports on.

And the socket: **`admin.sock`**, opened by the running hub beside its config
and removed when it stops. It is what [`stats`, `kick` and
`broadcast`](#talking-to-a-hub-that-is-running) dial. It answers four
commands: `stats`, `kick` and `broadcast` each have a verb of their own, and
`who` — the live roster — is the one with no verb yet, because
[`players`](#who-is-on-it-and-who-is-winning) already answers that question
off the snapshot without needing the hub to be up.

```console
$ printf '{"cmd":"who"}\n' | nc -U /data/admin.sock
{"ok":true,"players":[…],"count":3,"maxPlayers":8,"uptimeMs":4210233}
```

- **One JSON object in, one JSON object out, per connection.** No sessions,
  nothing server-initiated, a request line capped at 4 KiB. A line that is not
  JSON, not an object, or not one of the four commands comes back as
  `{"ok":false,"error":"…"}` — always a sentence, never a stack trace, and
  never an exception into the hub.
- **The trust model is the filesystem, and there is deliberately no in-band
  auth.** The socket sits inside the data directory, which is 0700, beside the
  `config.json` that holds every join code in plaintext. A process that can
  open this socket can already read those codes: a password here would guard
  nothing that is not already lost, and would put a second secret in the same
  directory as the first. **Anything that grants another user access to this
  directory grants them the hub**, which was already true of `config.json` and
  is now true of a live kick as well.
- **It is in `/data` and not `/tmp` on purpose.** The data volume is what
  `docker compose exec` shares with the container; the container's `/tmp` is a
  private tmpfs, so a socket there would be unreachable from the command a
  host actually types.
- **A hub with no config file opens none**, for the same reason it writes no
  snapshot: `node hub.js` and an embedding caller have no data directory to
  put one in.
- A stale socket file left by a hub that was killed does not block the next
  start: the hub checks that the path really is a socket, unlinks it, and
  binds once more. It refuses to unlink anything that is not one.
- Nothing that crosses it is a secret, but everything that crosses it is an
  instruction. It is not `cat`-safe in the way `status.json` is — not because
  of what it says, but because of what it can be told.

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
| `motd` | `""` | ≤120 chars | — | the message of the day, shown to everyone who connects. Empty means no greeting. Re-applied on `SIGHUP` |
| `auth.required` | `true` | — | `RBY_MMO_AUTH_REQUIRED` | whether a passcode is demanded. **`false` means the hub refuses to start** — it is still settable, so a config can be scripted or a report reproduced, but `start` exits `1` and `doctor` calls it a `[fail]` |
| `auth.credentials` | `[]` | — | — | the join codes, each optionally marked `admin` (see [Admin codes](#admin-codes)). Managed with `invite` / `revoke` |
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

`motd` has **no environment variable**. It is a config-file setting, set with
`config set` like everything else — a greeting the hub says in its own voice is
not something a stray variable in a shell profile or a compose file should be
able to write.

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
passcodes have actually arrived is known to the running hub, which says so in
its own log; `status` and `doctor` are short-lived processes that read a file
and do not ask it. The live counts have their own verb —
[`rby-mmo-hub stats`](#talking-to-a-hub-that-is-running), which asks the
running process over `admin.sock` rather than reading a file. `doctor` also
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

### The message of the day

`motd` is the one sentence the hub gets to say for itself. Set it, tell the
hub to re-read the config, and everybody who connects from then on is greeted
with it:

```sh
rby-mmo-hub config set motd "Tournament Saturday 8pm. Bring a full party."
docker compose kill -s SIGHUP hub          # or: kill -HUP $(pgrep -f 'rby-mmo-hub.js start')
```

It arrives on the welcome and the game shows it as a **`HUB` line at the top
of the chat log** — no box to dismiss, no bubble over anybody's head, nothing
to press. A player who joined before you set it does not see it; this is a
greeting, not a broadcast, and [`broadcast`](#talking-to-a-hub-that-is-running)
is what reaches the people already in the world.

- **120 characters, one line.** Twice chat's 60, because a host writes this
  once and a player types chat mid-game, but the same one-line budget and the
  same characters chat allows — it is delivered through the field the client
  already knows how to render. Anything longer is truncated and anything
  outside the charset is dropped, quietly and on the way in, so
  `config get motd` shows you exactly what players will see.
- `config set` re-joins its arguments, so quoting is a courtesy rather than a
  requirement: `config set motd Tournament Saturday 8pm` stores the same
  string.
- **Empty is the default and means no greeting** — the field is simply not
  sent, and a hub with no MOTD looks to a client exactly like a hub from
  before the feature existed.
- **A hub older than the MOTD, or a client older than it, both cope.** The
  field rides on a message that already existed and nothing on either side
  rejects an unknown key, which is why this cost no protocol bump.

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
INFO reloaded "/data/config.json": 2 join code(s), 2 usable; 1 ban(s); 0 allowlist entr(y/ies); a MOTD
```

The last field is `a MOTD` or `no MOTD` — the sentence itself is not logged,
because the count is what a host is checking and the greeting is already in
`config get motd`.

**Exactly four things are re-applied:** `auth.credentials`, `bans`,
`allowlist` — the decisions about *who may be here* — and `motd`, which is a
sentence the relay holds rather than anything bound to a socket. Everything
else in the file is a bind-time parameter and needs a restart:

| Change | Reload is enough | Needs a restart |
| --- | --- | --- |
| `invite` / `revoke` | ✓ the next handshake is judged against the new list, `admin` flags and all | |
| `ban` / `unban` / `allow` | ✓ the next connection is admitted or refused by the new list | |
| `motd` | ✓ the next player to connect is greeted with the new one | |
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

Three things about a reload worth knowing before you rely on it — one it does
not do, one it does, and one that happens when the file will not read:

- **It does not disconnect anybody.** Bans and the allowlist are checked when a
  connection is *admitted*. Someone already in the world stays there; a
  revoked code does not eject the player who already answered a challenge with
  it. Removing somebody who is connected right now is
  [`kick`](#talking-to-a-hub-that-is-running), which reaches the running hub
  directly — `ban` then `SIGHUP` is what keeps them from coming back, and the
  two are worth doing in that order.
- **It does re-apply which codes are admin codes.** `auth.credentials` is one
  of the four and the `admin` flag rides on it, so `invite --admin` followed by
  a `SIGHUP` means the next connection answering with that code is marked, and
  `revoke <id>` followed by one means the code stops being accepted at all — the
  mark and the admission move together, because they are the same credential.
  It reaches the *next* join and not the current ones: a connection that is
  already up keeps whatever mark it joined with until it ends, the same way a
  revoked code does not eject the player holding it. `kick` is what ends one
  now.
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

**An [admin code](#admin-codes) is worth more to a thief than a player's one
is** — it is the same thirty bits and buys the same seat in the world, but the
connection it opens is marked as an operator's, and it is the credential the
in-game operator features arriving later will be looking for. Nothing about the
sniffing problem changes; what changes is the prize. So prefer `invite --admin
--expires 24h` over an admin code that never ends, and rotate freely: minting a
new one and revoking the old is two commands and a `SIGHUP`, and no player's
code is disturbed by it.

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

**The game port is the only port this hub opens**, which keeps the gap to one.
The operator surface is the CLI, and reaching it from another machine means
SSH — a transport that is already encrypted and already authenticated, by keys
this program never sees. See [Looking at the hub from somewhere
else](#looking-at-the-hub-from-somewhere-else).

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
git clone --depth 1 --branch v0.8.0 https://github.com/alamops/RBYMMOMod.git
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
  bans, the allowlist — along with `ranking.json`, `status.json`,
  `history.jsonl` and the `admin.sock` the running hub opens. Losing the
  volume loses the code your friends saved. **The socket is in `/data` for a
  reason**: the volume is what `docker compose exec` shares, while the
  container's `/tmp` is a private tmpfs, so
  `docker compose exec hub rby-mmo-hub kick BETA` works and would not if the
  socket lived there.
- **One published port, the game port.** There is nothing else to map:
  operating this hub is `docker compose exec hub rby-mmo-hub …`, over SSH when
  the box is elsewhere — see [Looking at the hub from somewhere
  else](#looking-at-the-hub-from-somewhere-else).
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
2026-08-03T03:02:39.208Z INFO RBY MMO hub listening on 0.0.0.0:7992 (protocol 5)
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
| `mmo.hello` | `proto, name, sprite, profile, map, x, y, facing, rankToken` — the ticket is absent on a first visit and on a copy that lost it |
| `mmo.auth` | `response` — 64 lowercase hex chars, `HMAC-SHA256(joinCode, nonce)` |
| `mmo.move` | `map, x, y, facing, fast` — an absent cell means "not in the world"; `fast` is `true` only when literally `true`, and means the step covered a tile at the doubled clock (a sprint or a bike, and the hub is not told which) |
| `mmo.chat` | `scope, to, text` |
| `mmo.request` | `to, kind` (`trade` \| `battle`) |
| `mmo.respond` | `to, kind, accept` |
| `mmo.relay` | `to, payload` — opaque |
| `mmo.session_leave` | — |
| `mmo.party_invite` | `to` — outbound; the same type arrives carrying `from` |
| `mmo.party_respond` | `to, accept` |
| `mmo.party_leave` | — |
| `mmo.result` | `session, outcome` (`win` \| `loss` \| `draw`) — how the sender saw a link battle end. One on its own scores nothing: the hub waits for both sides to say the same thing |
| `mmo.ranks` | — "send me the leaderboard". Rate-gated like chat |
| `mmo.ping` | — |

**Hub → client**

| Type | Payload |
| --- | --- |
| `mmo.challenge` | `nonce` — 32 lowercase hex chars, per-connection, single-use. Sent by every hub that requires a passcode, which is every hub but the `node hub.js` shim |
| `mmo.welcome` | `id, players[], points, ranked` — plus `rankToken` on the one visit that claimed the name, and only that visit; `motd` when this hub has one configured (absent when it does not); and `admin: true` when the join code this connection answered with is an [admin code](#admin-codes), absent otherwise. All three optional fields ride hub→client on a message that already existed, which is why none of them moved the protocol number. `admin` is derived from the credential server-side and told to that client about itself only — it is deliberately not in the presence record other players receive |
| `mmo.join` / `mmo.part` | `player` / `id` |
| `mmo.move` | a presence record |
| `mmo.chat` | `from, name, scope, text` — **or, when the hub itself is speaking, `name: "HUB"`, `scope: "global"` and no `from` at all**: an operator's `broadcast`. A line with no sender is a line no player sent |
| `mmo.request` / `mmo.decline` | `from, name, kind` / `name, kind` |
| `mmo.session` | `peer, peerName, kind, role, id` — the asker hosts |
| `mmo.relay` | `from, payload` |
| `mmo.session_end` | `reason` |
| `mmo.party_invite` | `from, name` — inbound; outbound it carries `to` |
| `mmo.party` | `id, members[]` — the whole membership, never a delta |
| `mmo.party_decline` | `name, reason` — `no`, or `in_party` |
| `mmo.party_end` | `reason` — `left` to the member who left, `peer_left` to the other |
| `mmo.rank` | `id, points` — one player's rating moved. Broadcast to everybody including the player it is about, so a roster row, a trainer card and their own menu all change at the same moment |
| `mmo.ranking` | `entries[]` of `name, sprite, points` — the answer to `mmo.ranks`, already sorted and already cut to the top ten by the hub |
| `mmo.error` | `message` — always fatal to the connection |
| `mmo.pong` | — |

**A presence record** — what `mmo.welcome`, `mmo.join` and `mmo.move` all
carry — is `id, name, sprite, map, x, y, facing, busy, party, fast, profile,
points`. `map`/`x`/`y` are null while that player is in a battle or a menu.
`busy` and `party` are booleans and never a session or party id: the flags are
all anyone outside needs to decide whether to offer `TRADE` or `INVITE`, and
ids on every presence would let any client map out who is with whom. `points`
rides here rather than on the trainer card because a rating moves mid-session
and a card built at `hello` would show a stale one.

Parties are two players and no more. The hub forms one only when *both* sides
are unattached, re-checks that at the moment of forming (either of them could
have joined somebody else's while the prompt sat on screen), and ends it for
both when either leaves or disconnects. A presence carries `party: true|false`
and never the party id — that flag is what gates the other players' `INVITE`
row, and an id on every presence would let any client map out who is
travelling with whom. `chat` gains a `party` scope, delivered to the party
alone with no radius; from a client with no party it is dropped, never
widened.

**The hub speaks as `HUB`, and no player may.** Two things it says arrive as
ordinary hub→client traffic with that name on them: the MOTD, carried on the
welcome and rendered by the client as a chat line, and an operator's
`broadcast`, which *is* a chat line. Neither carries a `from`, because neither
came from a player — so the name is the only thing on the receiving side that
tells the two apart, which is why `mmo.hello` refuses it:

```
client → hub    mmo.hello   { proto: 5, name: "HUB", … }
hub    → client mmo.error   { message: "That name belongs to the hub itself;
                              pick another trainer name and connect again." }
```

The match is the board's own key rule — case-folded and trimmed — so `HUB`,
`hub` and ` Hub ` are one name.

**Neither addition moved the protocol number**, and the rule is what says so:
a bump is owed when a *client* can send something an older *hub* would ignore.
`motd` is a field on a message that already existed, travelling hub→client,
which an older client never reads and is no worse for; a hub-originated chat
line is a message type that already existed, and an older client renders it as
a chat line with an unknown sender — the log line appears, and the bubble that
would have been drawn over a player who does not exist is stored, never drawn,
and expires. Nothing new travels client→hub at all.

The handshake, in full:

```
client → hub    mmo.hello      { proto: 5, name, sprite, profile, map, x, y, facing, rankToken? }
hub    → client mmo.challenge  { nonce }        ← only when a passcode is required
client → hub    mmo.auth       { response }     ← HMAC-SHA256(passcode, nonce), 64 hex
hub    → client mmo.welcome    { id, players[], points, ranked, rankToken?, motd? }
                                                ← or mmo.error, which the game shows
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

**`PROTOCOL` is 5**, and it lives in **`lib/relay.js`** (not `hub.js` any
more) and in **`src/Config.lua`**. Bump both together on any incompatible
change. The hub refuses a mismatched client by name and version — *"This hub
speaks protocol 5; your mod speaks 4."* — rather than letting two dialects
talk past each other, and the game renders that sentence.

Every bump so far has been *additive*, and it is worth saying why an additive
change moves the number at all. Nothing has ever been removed, so an old
client's messages all still parse — but a **new** client on an **old** hub is
the case that matters, because a handler table answers a type it has never
heard of with silence, and silence is the one failure a player cannot act on.
So the rule is: **bump whenever a client can send something an older hub would
ignore.**

| | What landed | What an older hub would have swallowed |
| --- | --- | --- |
| **3** | parties | `INVITE` pressed, nothing happens, forever |
| **4** | ranked PVP | every battle result and every leaderboard request reported into silence |
| **5** | pace | the `fast` flag dropped from every rebroadcast, so two players who both installed running would watch each other walk for the whole session |

**Update the hub and the mod together.**

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
