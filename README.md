# RBY MMO

### Kanto, but your friends are in it.

Other trainers walk the same routes you do — real sprites, names over their
heads, a line in the corner when they talk. Bump into someone outside Viridian
and trade on the spot. Or throw down, right there on the grass.

A multiplayer mod for [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp).

![LÖVE 11.x](https://img.shields.io/badge/L%C3%96VE-11.x-e64998?style=for-the-badge)
![Players 2–64](https://img.shields.io/badge/players-2--64-3aa757?style=for-the-badge)
![No server needed](https://img.shields.io/badge/dedicated%20server-optional-4c8fd6?style=for-the-badge)
![Experimental](https://img.shields.io/badge/status-experimental-d9822b?style=for-the-badge)
![MIT](https://img.shields.io/badge/licence-MIT-666?style=for-the-badge)

**No server to rent. No accounts. No signup.** One of you hosts from inside
the game — you're a player, your copy is just also the relay.

---

## 🎮 Get in

**1. Install it.** Grab `rby_mmo-<version>.zip` from
[Releases](https://github.com/alamops/RBYMMOMod/releases), then in the game:
**MODS → Import mod .zip**. That's the whole install — the archive carries
`manifest.json` at its root, which is the shape the importer expects, so it
also unzips into your `mods/` folder by hand if you'd rather.

Every release ships a `sha256sums.txt` beside the zip if you want to check
what you downloaded.

**2. Turn it on.** Launch the game, press **F10**, enable **RBY MMO**, and
let it restart when it asks. It ships flagged `experimental`, so it stays off
until you say otherwise — installing it is never what opens a socket.

**3. One of you hosts.** `START → MMO → HOST GAME`.

Character creation comes first: pick a **NAME** (your save file keeps its
own) and a **LOOK** from the 36 walking characters in the game — plus
**special characters from talented artists**, marked `▷` in the list. Each
row shows that character's face beside their name, so you're picking a person
rather than reading a label. Confirm, pick a room size, and you're live.

You don't have to be here to choose, either: **`CHARACTER` on the MMO menu**
opens the same list whenever you like — before you connect to anything, and
in the middle of a game, where everyone else sees you change as you do it.
See [Be somebody else](#-be-somebody-else).

The HOST screen mints a **six-character passcode** on the way in and shows it
in the `JOIN CODE` row — `A7K3P9`, letters and digits, no dashes. There's
nothing to type and no way to host without one: every game has a door on it.
Change it from that row if you'd rather pick your own.

<p align="center">
  <img src="docs/screenshots/character-creation.png" width="270" alt="Character creation: NAME, LOOK and HOST rows">
  <img src="docs/screenshots/character-picker.png" width="270" alt="The character list, scrolled to NIRE">
  <img src="docs/screenshots/room-size.png" width="270" alt="Room size picker">
</p>

The menu's **ADDRESS** row then shows something like `192.168.1.125:7788`
with `CODE: A7K3P9` on the line under it — they're read out in the same
breath, so they're shown in the same box.

**4. Everyone else joins.** `START → MMO → JOIN GAME`, make their own
trainer, then **the address and the passcode**, in that order, before
anything is dialled. (**SELECT** flips the keyboard to digits — the vanilla
one has none.)

An IP or a hostname both work — `192.168.1.125:7788` or
`MYBOX.EXAMPLE.COM:7788` — and leaving the port off fills in **7788**. So does
typing the colon and stopping there, or typing something behind it that is not
a port a socket could dial. A port you did type is always the one dialled, and
spaces are removed wherever they are, so nothing is lost to one. Case
doesn't matter for a hostname; DNS doesn't care either. Dashes, spaces and
lower case in a passcode are normalised away, so one copied out of a chat
message works as typed.

**Staying current.** The manifest points at this repo, so the launcher's
mod list checks Releases for you and offers the newer build under **Other
versions** — you don't have to come back here to find out something shipped.
It only ever asks; nothing updates itself behind you.

Everyone on the same Wi-Fi or LAN can join straight away — no configuration,
just the address and the passcode. Across the internet the host has to
forward port **7788** — or nobody forwards anything and you all join a
standalone hub on a box that already has a public address instead
([server/README.md](server/README.md)).

That's the five-minute version. **[Setting a game up — both ways](#-setting-a-game-up--both-ways)**
walks the full configuration of each path, screen by screen.

---

## ⚡ Features

```
╔════════════════════════════════════════════════════════════╗
║  SHARED KANTO      up to 64 trainers, one live overworld   ║
║  ZERO SETUP        one of you hosts from inside the game   ║
║  FULL LINK SUITE   trade + battle, anywhere on the map     ║
╚════════════════════════════════════════════════════════════╝
```

### 👥 THEY'RE REALLY THERE
Every other player on your map is a **genuine overworld NPC** — right sprite,
right depth sorting, right palette — walking tile to tile on the engine's own
16-frame step clock. Not a sprite bolted on top. Nameplates ride over their
heads; what they say lands in the corner.

Hold **B** on foot and you run — bike speed, no bike, off the moment you're
biking or surfing — and everyone else sees it too: your avatar steps at that
same doubled clock on their screen, not just yours. The wire carries the
*pace*, not the reason for it, so a player on a bicycle rides at bicycle
speed on your screen as well.

<p align="center">
  <img src="docs/screenshots/overworld-presence.png" width="300" alt="Another player standing in the room with a nameplate">
  <img src="docs/screenshots/chat-log.png" width="300" alt="The chat log showing two global messages">
</p>

**And `PLAYERS` says where they all are.** Every row on the list carries the
place that trainer is standing in — `VIRIDIAN FOREST`, `CELADON CITY` — so
"where is everyone" is one menu away rather than a lap of Kanto. That column
used to read `HERE`, which the place name says better: your own map's name
against somebody's row reads as *here* without being told, and it answers the
question `HERE` couldn't, which is where the rest of them went. The names come
out of the town-map data your own game decodes from your own ROM, so they read
the way the game reads. `PARTY` and `BUSY` still win the column when they
apply, and a player in a battle or a menu isn't standing anywhere nameable, so
theirs stays as it was.

### 🤝 TEAM UP
Walk up to a friend, press **A**, pick `INVITE`. They get asked; if they say
yes you're a **party** — you and one other trainer, and that's the whole
design, not a first step towards six.

<p align="center">
  <img src="docs/screenshots/party-townmap.png" width="300" alt="The Kanto TOWN MAP with your party member's character standing at Pallet Town, their nickname above it">
  <img src="docs/screenshots/party-map.png" width="300" alt="Your party member in the overworld, their nameplate drawn as ▶ALPHA">
</p>
<p align="center">
  <img src="docs/screenshots/party-members.png" width="300" alt="The PARTY members list: ALPHA HERE, BETA YOU">
  <img src="docs/screenshots/interact-menu.png" width="300" alt="PROFILE / INVITE / TRADE / BATTLE / WHISPER menu">
</p>

What a party buys you:

- **open the TOWN MAP and they're on it** — their character standing at the
  city they're actually in, right now, with their nickname over it. Kanto
  already had a screen for "where is that", and this is that question with a
  person as the answer. It updates as they walk;
- **them in the world too**, when you're on the same map — their character
  with a `▶` in front of their nickname over its head, so you can pick your
  friend out of a crowd at a glance. `PARTY` next to their name on the
  `PLAYERS` list says the same thing in menu form;
- a chat scope that reaches them **wherever they are** — no radius, no name
  to type;
- a `PARTY` row on the MMO menu holding the members list (their card is one
  press away, and so is yours), and the way out.

The `INVITE` row only appears when a party could actually be formed — neither
of you already in one — because a button whose usual answer is *no* is worse
than no button. Either of you leaving ends it for both; at two people there
is no party left to continue. So does either of you disconnecting.

### 💬 TALK TRASH ON A GAME BOY KEYBOARD
Four scopes, composed on the vanilla naming grid:

| Scope | Who hears it |
| --- | --- |
| `EVERYONE` | the whole hub |
| `NEARBY` | same map, 12 tiles |
| `PARTY` | the friend you teamed up with, anywhere |
| `WHISPER` | one player |

Every one of them pops up in your corner as it arrives — the whisper
included, because a notification is drawn in *your* game and nowhere else.
Your own lines do too, under your own name, so a conversation reads as one
without opening anything.

Unread messages flag the menu with `CHAT*`. And because the vanilla grid has
**no digits at all**, this mod adds a number page to its own screens —
**SELECT** flips `ABC` ⇄ `123`.

**A fifth voice you can't type as: `HUB`.** A dedicated hub can carry a
message of the day, and it lands as a `HUB` line at the top of your chat log
the moment you connect — no box to dismiss, nothing to press. The host can say
something mid-evening the same way (`rby-mmo-hub broadcast "back in 5"`) and
it arrives as another `HUB` line. Which is why nobody is allowed to *be*
`HUB`: a hub's line carries no sender, so the name is the only thing telling
you the hub said it, and connecting under it is refused with a sentence asking
you to pick another.

### 🔔 THE CORNER TELLS YOU
Things happen while you're doing something else. Somebody talks, somebody
arrives, your party member wins a fight two routes away — none of it is worth
taking the screen for, and none of it should need a menu to go and find.

So it lands in the **top-left corner** instead: a dark plate, a line of white
text, gone by itself after **five seconds**, five lines at most and the oldest
one drops when a sixth arrives. It draws over the finished frame, menus and
text boxes included, so a line that arrives while you're three levels into
START is still read where you already are.

What shows up there:

| | Reads as |
| --- | --- |
| Anything said to you, in any scope — and your own lines | `[ALPHA]: on my way` |
| Anyone joining or leaving the hub | `ALPHA joined the server` |
| Your party member winning, losing, or catching something | `ALPHA captured MEWTWO lv 70` |

That last row is the one a party never used to have. A fight you're not in
produced nothing anybody else could see, so travelling together meant knowing
where your friend was standing and nothing about what they were doing. Now
their wins, their losses and their catches reach **you and nobody else** —
the hub sends them to the party alone, and the fighter isn't told what they
just watched happen.

The font is **Rajdhani**, bundled with the mod under the SIL Open Font
Licence — small, smooth, and with the lowercase and punctuation a chat line
needs that the game's own font does not carry.

### 🔁 TRADE — ANYWHERE
No Cable Club. No Pokémon Center. Walk up, press **A**, pick `TRADE`. It runs
the engine's *own* `TradeSession`, untouched — so your Kadabra still evolves,
and the mon still gets stamped as traded with the original OT.

### ⚔️ BATTLE — ANYWHERE
Same deal, on the grass where you're standing. The real lockstep simulation a
link cable runs, carried over the wire. **Zero desyncs** across the full
end-to-end suite.

<p align="center">
  <img src="docs/screenshots/interact-menu.png" width="300" alt="PROFILE / INVITE / TRADE / BATTLE / WHISPER menu">
  <img src="docs/screenshots/link-battle.png" width="300" alt="GUESTY wants to battle!">
</p>

### 🤜 CO-OP — WAIT FOR YOUR FRIEND
Walk into a trainer while you're in a party and the game asks you first:
**wait for your friend, or go in alone.** Waiting tells them exactly where
you're standing. When they reach the same fight — or just walk up to you —
they're offered the chance to join.

Four rules make it feel solid rather than fiddly:

- **No costs nothing.** Turn down a join and *nothing* is remembered. Your
  friend keeps waiting and isn't even told, and walking back into that fight
  asks you again. There's no record of the refusal for anything to consult.
- **You can't dodge the fight.** The engine has already committed to the
  encounter by the time the mod gets asked, so every way out of every prompt
  ends in a battle. **B is BATTLE ALONE**, not "never mind" — and B while
  waiting reopens that same choice rather than releasing you.
- **The door shuts.** Nobody joins a battle that's already started, and an
  offer is taken exactly once.
- **PARTY BATTLE** sits right under BATTLE on the walk-up menu: two parties,
  four trainers, and **all four have to say yes**. It tells you plainly if
  they aren't in a party, or if your own partner has wandered off this map.

**And it's a real four-monster field.** Not two 1v1s side by side — one turn
order over all four, a target picked per attack, and your move redirecting if
your partner drops your target before you swing. A side only loses when *both*
its trainers are out of mons.

The engine has no double battles, so the mod brings its own field
(`src/CoopSim.lua`). What sits underneath it is still the engine's: damage,
crits, type effectiveness, STAB, badge boosts, burn, screens, the random
factor, status and turn speed all come from `src/battle/*`, so a POKéMON hits
for exactly the same number here as it does in the grass.

**Every move effect the game has works**, because none of them are
reimplemented. `src/CoopField.lua` is a `BattleState`-shaped object over the
four slots whose lookup chain ends at the engine's own `BattleState` — so the
move that runs *is* `BattleState.performMove`, driving the real `move_effects`
registry. Charge moves charge, SUBSTITUTE absorbs, HYPER BEAM recharges,
METRONOME calls, multi-hit hits, recoil recoils, BIDE stores.

<p align="center">
  <img src="docs/screenshots/coop-battle.png" width="300" alt="Four monsters on one field: WEEDLE and CATERPIE reading out top-left, CHARIZARD and PIKACHU bottom-right, FIGHT / ITEM / SWITCH / RUN below">
  <img src="docs/screenshots/coop-item.png" width="300" alt="The same field from the other player's screen, their own PIKACHU marked with the cursor">
</p>

All four commands are there — **FIGHT, ITEM, SWITCH, RUN** — with items going
through the engine's own item effects. Against a trainer, RUN and a thrown
ball are *refused*, in the game's own words, because Gen 1 lets you do
neither in a trainer battle. Against another party, **RUN asks your partner
first**: they get a yes/no box in the battle itself (it opens on NO, so a
button held through the messages can't answer it), a no costs you nothing but
the asking, and a yes ends the battle for all four — as the runners' loss and
the opponents' win, so fleeing at match point buys nothing.

**Exp is priced on each player's own machine.** The host resolves the knockout
but holds nobody's party except its own, so what crosses the wire is a
*description* of the kill — what fell, at what level, and how many shared it —
and every client runs the engine's own `Experience` over its own live monster.
That is what makes a shared knockout genuinely worth half each rather than full
each, divides the stat exp the same way Gen 1 does, and lets an **EXP.ALL** in
your bag do exactly what it does anywhere else: halve what the fighter takes
and spread the other half over everyone still standing, level-ups, new moves
and evolutions included.

And it's dressed like a trainer battle, because it is one: the **trainer's
picture** holds the field through the opening lines and steps aside before the
first menu, their **battle theme** plays — the gym leader's, if they're a gym
leader — the **victory theme** answers it, and their **parting line** is said
before the world comes back.

The prompt appears in front of **every** trainer — walked into or scripted —
and the engine's own battle runs the whole post-battle flow afterwards: the
defeated flag, badges and prizes, the whiteout if you're wiped, and whatever
script was waiting. Animations play, through the engine's own player, moved
onto whichever of the four monsters acted.

<p align="center">
  <img src="docs/screenshots/party-battle.png" width="300" alt="Four humans on one field: BLASTOISE and VENUSAUR against CHARIZARD and PIKACHU">
  <img src="docs/screenshots/party-ask.png" width="300" alt="ALPHA wants a 2-on-2 battle! -- the four-way ask, as it reaches one of the other three">
</p>

**A faint is four different things depending on who you are.** Lose one with
POKeMON left and the battle *stops* and asks you which follows -- nobody else
takes a turn until you answer. Lose your last one and nothing stops: your
partner fights on, your side is still alive, and you watch the rest of it
rather than being handed a menu that answers nothing. A side only falls when
**both** its trainers have.

<p align="center">
  <img src="docs/screenshots/party-spectating.png" width="300" alt="GAMMA's screen after their last POKeMON fell: their slot gone from the readout, their partner VENUSAUR still fighting">
</p>

**And losing sends you home, the way the game always did.** Every player
whose party lost — or who walked out of any co-op battle with nothing left
able to fight, even on the winning side — gets the whole vanilla ritual:
party healed, money halved, and the warp to *their own* last POKéMON CENTER.
Nobody is left standing in the tall grass at 0 HP, which also means a party
with nothing able to fight is never wandering around to be challenged — and
if one ever were, the battle refuses to start rather than starting broken.

**And nobody can hold four people hostage.** Every turn has one 60-second
clock, the same honest number on every screen, the host's own turn included.
When it runs out the late player's first usable move is played for them —
everyone is told who took too long — and the battle flows on.

> One client simulates and the other three replay its events, so the host is
> trusted the same way the engine's own link host already is.
>
> The wait-or-alone prompt appears in front of *script-driven* trainers.
> Walking into one in the overworld starts a battle through a path that only
> emits an event, and an event can't cancel —
> [`docs/rfcs/0001-double-battles.md`](docs/rfcs/0001-double-battles.md)
> proposes the upstream seam that would close it.

**Beating a trainer together is not worth points, and the game tells you so.**
Elo rates you against an opponent's rating and a trainer hasn't got one — and
trainers are an infinite supply the anti-farming discount can't touch, so two
friends could grind gym leaders to the top of the board without ever meeting
anybody. A co-op trainer battle pays what a trainer battle pays — exp, badges,
prize money — and no points, and says as much the first time you win one.

**A party battle is scored as a team battle.** Each of the four is rated
against the *other pair's* combined strength — which is the match they actually
played, since both of you attack both of them and you lose together. Not two
1v1s paired off by slot: who the hub happened to list first is not a fact about
who fought whom, and rating it that way meant the same battle between the same
four people paid differently depending on the seating.

### 🏆 RANKED — AND YOU CAN'T FARM IT
Every link battle is scored, on the hub, for both players. Win and you gain
points; lose and you lose them, never past **0**. How many depends on who you
beat: turn over somebody 300 points above you and it's worth **27**, beat
somebody 300 below and it's worth **5**. Elo, in other words — so hunting the
weakest player in the room pays almost nothing.

And it pays less every time. Beating the *same person* again inside an hour
is worth half, then a quarter, then nothing — counted in both directions, so
you and your friend can't take turns either. Play them all you like; the
sixth rematch of the hour just isn't worth points.

**Neither of you can lie about it.** Both games report how the battle ended
and the hub scores it only when the two reports agree — one side claiming a
win is worth exactly nothing. A dropped link is a draw for the player still
standing, and a draw scores nothing, so nobody loses points to somebody
pulling the cable out (and nobody can farm by pulling it either).

`RANK` on the MMO menu is the top ten, best first: place, the character
they're wearing, name, points. Players who've never won aren't on it — 0
points means unranked, which is where everybody starts.

<p align="center">
  <img src="docs/screenshots/rank.png" width="330" alt="The RANK screen: place, portrait, name and points">
</p>

Your own points are on your trainer card, on the badge row, and so are
everybody else's on theirs. A dedicated hub keeps the season in
`ranking.json` between restarts; a game hosted from inside somebody's copy
scores a fresh one each time it opens.

**And the name is yours — once you've proved it is.** The first time a hub
sees your trainer name it mints a secret, hands it to your copy once, and
remembers only its hash; your game presents it every time you come back, and
that is what says *same player*.

A claim starts out **provisional**, because a minted ticket only means one was
posted — the welcome carrying it can be lost, the hub can restart before it
writes anything down, a save can go without it. So until a name is *proven*
(your game came back and presented the ticket) or *scored* (a ranked battle
settled under it), the claim simply follows whoever is actually connecting,
and they get a fresh ticket of their own. Nothing is stolen by that: an
unproven, unscored name holds no rating, and if you lost the race you take it
back the same way. Two exceptions, both obvious once said: a name somebody is
*already connected and ranked under* isn't up for grabs while they're standing
there, and neither is one that has ever scored.

Once the name is proven or has scored, it's locked. Somebody typing it without
the ticket plays normally — walks, chats, trades, battles — and simply doesn't
score, which the `RANK` screen tells them in as many words. Nobody is thrown
out for it: a friend who lost their save shouldn't lose the hub.

Be clear about what that is worth. It's a **claim ticket, not an account**: it
lives in your save file *and* in `rby_mmo_rank_tokens.json` in the game's save
folder — the file is what carries it through a CONTINUE you never saved — and
it crosses the same unencrypted link the join code does, so anyone who can
read either can take the name. What it buys is that *typing* someone's
nickname is no longer enough — which, until it existed, was the whole story.

### 🏠 YOU ARE THE SERVER
`HOST GAME`, pick a room size (**2–64**), done. You're a normal player who
happens to be the relay — you walk, chat, trade and fight like everyone else.

The catch is in that sentence: the relay is running inside *your* copy, so
when you quit, everyone's game ends. Fine for an evening on the sofa. If you'd
rather nobody's exit could do that — including yours — run the standalone hub
instead: same protocol, joiners can't tell the difference, and it has no host
to lose.

### 🔑 EVERY GAME HAS A DOOR ON IT
**A six-character passcode is required, both ways.** Hosting from the game
mints one and shows it on the HOST screen; the standalone hub refuses to
start without one. There is no open-world setting on either side. Six
characters (`A7K3P9`) from an alphabet with `I L O U` left out, so nothing is
misread off a screenshot or misheard over voice, and every character is on
the mod's own naming grid.

Where the standalone hub goes further is everything *around* the passcode: it
mints codes from a real CSPRNG, throttles wrong ones per address *and*
hub-wide, and adds per-address connection limits, bans, an allowlist, a
`doctor` that tells you who can actually reach your machine, and a hub that
stays up when you're not playing. Configure the lot from one command —
`docker compose up`, or `node server/bin/rby-mmo-hub.js init`.

**Six characters is 30 bits, and that is not much.** It keeps strangers out;
it does not survive somebody who can capture your traffic, because none of
this is encrypted. [server/README.md](server/README.md) does the arithmetic
in full and does not soften it.

### 🚪 DROP OUT, KEEP PLAYING
`LEAVE` disconnects and hands you straight back to single-player. Save,
world, party — untouched, and so is the character you're wearing: you walk
out of the game looking exactly like you did in it. No "returning to title
screen".

### 🗂️ SERVERS REMEMBERS WHERE YOU'VE BEEN
The first time you connect anywhere, `SERVERS` shows up at the top of the
disconnected menu, above `HOST GAME` — every hub you've reached before, so
getting back onto one is a menu instead of a retyped address and passcode. It's gone
again the moment you're hosting or connected, same as `ADDRESS` and
`PLAYERS`.

**Favorites sit on top, marked `▶`; everyone else sorts by address,
descending.** Pin one and it stays above the rest no matter how long ago you
played there — recency only decides which *non*-favorite gets dropped when
the list is full.

Pick an entry and a submenu opens: **`CONNECT`** dials it exactly the way
`JOIN GAME` does, **`FAVORITE`/`UNFAVORITE`** flips the pin, **`EDIT HOST`**
and **`EDIT CODE`** reopen the address or passcode on the naming grid, and
**`RENAME`** is the only one that touches the label — entries are named after
the address you dialled with the standard port left off (`192.168.1.20:7788`
lists as `192.168.1.20`; a hub on any other port keeps it, because there the
port is part of dialling it), and a rename can run up to 16 characters. The
whole address is still on the entry either way — that's what `CONNECT` dials.
Last on the submenu, **`DELETE`** forgets the entry for good — it asks first,
naming the entry in a yes/no confirm that defaults to "no", so a mis-press
costs nothing.

A hub is only added once you actually reach it — a wrong passcode never
earns an entry — and the list survives quitting, `CONTINUE`, and switching
save slots, because it's kept in its own file rather than the save. It holds
16 entries; past that, the one you haven't reconnected to in the longest
time is dropped first, and a favorite is never the one that goes.

<p align="center">
  <img src="docs/screenshots/servers-list.png" width="300" alt="The SERVERS list: a favorited hub, marked with an arrow in the right-hand column">
  <img src="docs/screenshots/servers-submenu.png" width="300" alt="The per-server submenu: CONNECT, UNFAVORITE, EDIT HOST, EDIT CODE, RENAME, DELETE">
  <img src="docs/screenshots/servers-confirm.png" width="300" alt="The DELETE confirmation asking to forget the server, with the cursor starting on NO">
</p>

### 🎭 BE SOMEBODY ELSE
Before you host or join, character creation asks who you are: a name of your
own (your save file keeps its own), and **any walking character in the
game** — 36 of them. Be Lance. Be Giovanni. Be a Rocket grunt, a Biker, a
Swimmer, Oak. You see it too, not just everyone else.

**Or just pick one, whenever you like.** `CHARACTER` sits on the MMO menu
under `HOST GAME` and `JOIN GAME` when you're on your own, and under `RANK`
when you're in a game — same row, same list, both doors. Choose, and you're
wearing it before the menu has closed. The choice goes in your save file, so
it's still on you next time you load that game.

**And if you're in a game, so does everyone else.** Change character
mid-session and the whole hub is told: your walking character switches on
their screens as you walk, not the next time you leave the map,
and a trainer card of yours somebody has open turns over while they're
looking at it. Anyone who joins a moment later gets the new one too. (One
exception: a `RANK` screen that's already open keeps the portrait it was
drawn with until it next refreshes — the same lag the points on it have.)

Every row shows the character's face to the left of their name — the same
portrait your trainer card draws — because `MIDDLE AGED WOMAN` and
`COOLTRAINER` don't actually tell you what you're about to look like:

<p align="center">
  <img src="docs/screenshots/character-picker.png" width="300" alt="The character list, each row showing a portrait beside the name, scrolled to NIRE">
  <img src="docs/screenshots/mmo-menu.png" width="300" alt="The MMO menu">
</p>

**And you keep it.** Leaving a game, losing the connection, quitting to the
title and pressing CONTINUE — none of them undress you any more. You wear the
character you picked until you pick a different one, and picking `RED` is how
you put yourself back. (A save that has never chosen one is left completely
alone: never opened this list, never moved `MY SPRITE` off its default, and
the game draws exactly what it always drew.)

**And some of them are special characters from talented artists**, drawn for
this mod rather than lifted out of your ROM — `NIRE` and `NIRE HOOD` so far,
by [Mirasein](https://www.mirasein.me):

<p align="center">
  <img src="docs/screenshots/nire-overworld.png" width="300" alt="NIRE standing in the overworld, facing the camera">
  <img src="docs/screenshots/nire-hood-overworld.png" width="300" alt="NIRE HOOD standing in the same spot">
</p>
 They sit in the same list as everyone
else, marked with a **`▷`** in the cursor's column so you can tell which is
which, and work the same way — worn on the map, sent over the wire, drawn on
your trainer card — but they go one step further than a borrowed ROM
character can. Wear one and it's you in **battle** too: the back pic over
your shoulder when a battle starts, the pic on your trainer card, and the one
Oak shrinks into if you start a new game. That follows the walking sprite
exactly: it's you for as long as you're wearing them, in a game or on your
own, until you pick somebody else.

<p align="center">
  <img src="docs/screenshots/nire-battle.png" width="330" alt="A link battle starting, with NIRE's back pic where Red's would be">
</p>

Same card, same badges, a different trainer on it — `NIRE` on the left,
`NIRE HOOD` on the right:

<p align="center">
  <img src="docs/screenshots/nire-card.png" width="300" alt="The game's trainer card with NIRE's pic where Red's would be">
  <img src="docs/screenshots/nire-hood-card.png" width="300" alt="The same card wearing NIRE HOOD">
</p>

If someone picks a character your ROM doesn't have, they show up as RED on
your screen rather than not at all. That covers the artists' characters too,
for anyone playing with an older copy of the mod — though only one new enough
to still speak the same protocol. The wire has moved twice since: the mid-game
character change took it to 7 at `0.8.0`, and the party notifications took it
to 8 at `0.10.0`. Copies from either side of one of those refuse each other at
the door and say which version each of them is. **Update the hub and the mod
together.**

### 🪪 CHECK THEIR CARD
Walk up, press **A**, and **PROFILE** sits at the top of the menu — their
trainer card, laid out like your own:

<p align="center">
  <img src="docs/screenshots/trainer-card.png" width="330" alt="Another player's trainer card, with their portrait">
</p>

Their name, the character they're wearing on the line beneath it, their
portrait, trainer ID, hours played, badges earned, and how much of the dex
they've seen and caught. Not their money — that's nobody else's business, so
it isn't shown and isn't sent.

The character gets a whole row to itself because the longest name in the
game, `MIDDLE AGED WOMAN`, is exactly as wide as one. The portrait sits
beside `IDNo` and `TIME` instead — the two rows whose width can't vary.

**`MY PROFILE`** on the MMO menu opens the same card for you — the same
rows in the same places, so what you check before showing off is exactly
what everyone else is reading:

<p align="center">
  <img src="docs/screenshots/my-profile.png" width="330" alt="Your own trainer card: the same rows, plus MONEY">
</p>

Yours adds one row nobody else's has: `MONEY`. It's drawn from your own
save and never goes on the wire — `Wire.profile` refuses to carry it, so a
card with money on it can only be your own.

Both cards carry `RANK` on the badge row, right-aligned — the live number the
hub holds, not a snapshot of whoever joined an hour ago. It shares that row
because the card has seven rows at this spacing and all seven were already
spoken for, and `BADGES/8` is the one that leaves most of its row empty.

### 🧩 STACKS WITH OTHER MODS
Spawning real NPCs means whoever owns the world pass draws your friends too.
Run it with a voxel renderer and they show up **as voxel characters**, no
work required.

---

## 🕹️ The menu

`START → MMO` is a bordered box in the corner like any other START submenu.
B goes back. The cursor remembers where you left it. The world stays visible
behind it.

<p align="center">
  <img src="docs/screenshots/mmo-menu.png" width="300" alt="The MMO menu">
</p>

| Row | Shows up when | What it does |
| --- | --- | --- |
| `SERVERS` | not in a game, and you've connected somewhere before | pick a hub you've reached before, and reconnect, rename, favorite or edit it |
| `HOST GAME` | not in a game | make a trainer, then the room size and the passcode |
| `JOIN GAME` | not in a game | make a trainer, then the address and the passcode |
| `CHARACTER` | not in a game, or connected | change who you look like, right now — in a game it sits under `RANK` and everyone sees it |
| `ADDRESS` | hosting | your address again — for when someone asks *again* |
| `PLAYERS` | connected | who's on and **where** — `n/limit` if you're hosting |
| `CHAT` / `SAY` | connected | the log and sending |
| `PARTY` | connected | your party: members, party chat, and leaving it |
| `MY PROFILE` | connected | your own trainer card, as everyone else sees it |
| `RANK` | connected | the hub's top ten: place, character, name, points |
| `LEAVE` | you joined | drop out and **keep playing single-player** |
| `END GAME` | hosting | asks first — this one ends it for everybody |

Three rows before you're in a game, and none of them is for the passcode:
`JOIN GAME` asks for it on the way in, so typing a different one there is how
a saved passcode gets changed. `CHARACTER` is the one row that's on the menu
in both states — offline it changes who you look like when you aren't playing
with anybody, and in a game it changes who *everybody* sees you as, on the
spot. Either way what it changes stays changed. (A shot of this menu only
ever shows one of the two states; the rows for the other one aren't hidden,
they just don't apply yet.)

Leaving isn't quitting. Your save, your world, your party: untouched. The
game just carries on without the other people in it.

Pressing **A** at another trainer opens a second, smaller box —
`PROFILE` / `INVITE` / `TRADE` / `BATTLE` / `WHISPER` — about that player.
`INVITE` is there only while a party could be formed: it disappears once
either of you is in one, and comes back when that party ends.

`PARTY` leads to a menu of its own once you're in one:

| Row | What it does |
| --- | --- |
| `MEMBERS` | both of you, with `HERE` / `AWAY` / `BUSY` next to them — and either card |
| `SAY` | a line to your party, wherever they are |
| `LEAVE` | asks first, then ends the party for **both** of you |

Before you're in one, the row explains how a party starts and drops you on
the `PLAYERS` list to start one from.

---

## ⚙️ Options

`MMO` in the mod manager (`F10`):

| Option | Default | Does |
| --- | --- | --- |
| `MAX PLAYERS` | 4 | room size for games you host (2–64, you count) |
| `JOIN` | `127.0.0.1:7788` | where JOIN GAME starts from |
| `JOIN CODE` | *(empty)* | the passcode used for a hub you haven't typed one for |
| `MY SPRITE` | RED | who you look like, to everyone including you — the `CHARACTER` row is the in-game way to the same thing, on your own or mid-game, and its choice sticks to your save |
| `B TO RUN` | on | hold B on foot to move at bike speed |

These are just the *defaults* — HOST GAME asks the room size every time and
JOIN GAME lets you type an address and a passcode, and those in-game choices
stick with your save. (Mods can read their options but not write them, so the
in-game values live in the save file instead of overwriting the rows above.)

A passcode typed for a particular hub is stored **against that hub's
address**, so playing on two of them means typing neither twice. The `JOIN
CODE` row above is the fallback for a player who only ever plays on one.

Typing an address uses the number page described above — **SELECT** flips
`ABC` ⇄ `123`. Every other naming screen in the game is left untouched.

---

## 📡 Setting a game up — both ways

There are two ways to put a world on the network, and **a joining player
cannot tell them apart**: same protocol, same handshake, same passcode rules.
Pick by how long you want the world to outlive the session.

| | Hosting from the game | A dedicated hub |
| --- | --- | --- |
| Configured with | the HOST screen | `rby-mmo-hub`, or `docker compose` |
| Needs a terminal | no | yes, once |
| Who is the host | one of the players | **nobody** |
| **If the host quits** | **the game ends for everyone** | n/a — there isn't one |
| **If any other player quits** | everyone else carries on | everyone else carries on |
| World survives an empty room | no — it ends with the host | yes, it just sits there |
| Ranked points | kept while the game is open | kept in `ranking.json`, across restarts |
| Passcode | minted on the HOST screen | minted by `init`, or you pick it |
| Passcode entropy | the game's own pool, **not** a CSPRNG | `crypto.randomBytes` |
| Bans, allowlist, per-address limits | — | yes |
| Who's online, from a terminal | — | `rby-mmo-hub players`, or `watch` for a live one |
| Every ranked battle, on the record | — | `history.jsonl`, read with `rby-mmo-hub history` |
| Throwing somebody out mid-game | — | `rby-mmo-hub kick <name> --reason "…"` |
| Saying something to everyone | — | a message of the day, and `rby-mmo-hub broadcast` |
| Operating it from another machine | — | SSH to the box and run the same verbs |
| Good for | the same Wi-Fi, an evening | friends across the internet, 24/7 |

The two bold rows are the whole difference. Hosting from the game puts the
relay **inside one player's copy**, so that player is a single point of
failure for everybody: their phone rings, they quit, and the world goes with
them. A dedicated hub has no such player — every seat is equal, anyone can
come and go, and the world is still there tomorrow. Nothing else in this
table is worth switching for; that is.

Everything below is *configuration*. For the five-minute version, see
[Get in](#-get-in).

### 🏠 Local LAN — configured entirely in-game

No files and no terminal. `START → MMO → HOST GAME`, make a trainer, and
every setting a hosted game has is on one screen:

<p align="center">
  <img src="docs/screenshots/host-setup.png" width="270" alt="The HOST screen: PLAYERS 4, JOIN CODE ZY2GX1, START">
  <img src="docs/screenshots/host-passcode-menu.png" width="270" alt="The passcode menu: NEW CODE and TYPE ONE">
  <img src="docs/screenshots/host-passcode-shown.png" width="270" alt="A text box reading: Players will need: JSDZRM">
</p>

- **`PLAYERS`** — the room size, **2–64**, you included. Change it as often as
  you like before starting; it is fixed for the life of the game once you do.
- **`JOIN CODE`** — already filled in. The screen mints one on the way in, so
  the common case is that you read it out and never touch this row.
  **`NEW CODE`** rerolls it — that is why the code above changes from `ZY2GX1`
  to `JSDZRM` between the first screenshot and the third. **`TYPE ONE`** lets
  you choose your own on the naming grid.
- **`START`** — opens the port. There is no way past this screen without a
  passcode; if you clear one, `START` sends you back here rather than opening
  an unprotected world.

Once you're live, the menu's **`ADDRESS`** row is what you read out. The
address and the passcode are shown in one box because they're always said in
one breath:

<p align="center">
  <img src="docs/screenshots/host-address.png" width="320" alt="A text box reading 192.168.1.125:7788 with CODE: JSDZRM underneath">
</p>

Everyone on the same Wi-Fi can use that address as-is. From outside your
network, someone has to forward port **7788** to your machine — or you skip
that entirely and use a dedicated hub on a box that already has a public
address.

> **A passcode minted in-game is not from a CSPRNG.** LÖVE ships no such
> source, so the game stirs its own entropy pool from frame and input timings.
> It claims 64 bits of pool, which is well past the 30 bits a six-character
> code can carry — fine for a LAN game. A hub facing the open internet should
> be the dedicated one below, whose codes come from `crypto.randomBytes`.

### 🖥️ A dedicated hub — configured entirely through one command

Lives in [`server/`](server/README.md). Node 22+, **zero dependencies**, or a
container. Every setting is reachable from the CLI — nothing requires editing
a file by hand.

**First run** writes a config at mode `0600` and prints the passcode once:

```console
$ node server/bin/rby-mmo-hub.js init --yes --port 7788 --max 8
Configuration written to /srv/rby-mmo/config.json (mode 0600, readable only by you).

  listening on   0.0.0.0:7788
  players        up to 8
  join code      required (always -- there is no open-hub setting)
  log level      info

Your join code

      +------------+
      |   214FYC   |
      +------------+

  Give that to the friends you want in your world. They type it once,
  in game, on the screen where they enter this hub's address. Anyone
  without it is refused, in one sentence, and cannot get in.

  This is the only time it is printed in full. To see it again:
      rby-mmo-hub invite list --reveal
```

**Or choose the passcode yourself** — including the same one you use for your
in-game LAN games, so friends only ever learn one:

```console
$ node server/bin/rby-mmo-hub.js init --yes --code gengar
  join code      required (always -- there is no open-hub setting)

Your join code, the one you chose

      +------------+
      |   GENGAR   |
      +------------+
```

Mind the alphabet — `I`, `L`, `O` and `U` are not in it, so plenty of words
don't survive. `--code kanto1` is refused, because `KANTO1` without the `O` is
five characters, and it tells you so:

```console
$ node server/bin/rby-mmo-hub.js init --yes --code kanto1
--code: that is not a passcode this hub can use.
A passcode is 6 characters from 0123456789ABCDEFGHJKMNPQRSTVWXYZ
-- the digits and the capital letters except I, L, O and U, which are
left out so nothing is mistyped off a screenshot. Dashes, spaces and
lower case are fine; they are normalised away.
```

**Everything else** is a verb. Codes are masked unless you ask, so the listing
is safe to screen-share:

```console
$ rby-mmo-hub invite list
ID       LABEL              CREATED           EXPIRES  USES  STATUS  KIND    CODE
primary  Primary join code  2026-08-03 17:48  never    0     active  player  ******

KIND: none of these is an admin code. `rby-mmo-hub invite --admin` mints
one; the hub marks that connection and shows it as ADMIN.

Codes are masked. --reveal prints them in full.
```

| Want to | Run |
| --- | --- |
| run it | `rby-mmo-hub start`, or `docker compose up -d` |
| hand out a second code | `rby-mmo-hub invite --label ash --expires 24h --uses 1` |
| mint a code that marks its connection as an operator's | `rby-mmo-hub invite --admin --expires 24h` |
| take one back | `rby-mmo-hub revoke <id>` |
| change any setting | `rby-mmo-hub config set maxPlayers 8` |
| see where a value came from | `rby-mmo-hub status` |
| see who's online, and where | `rby-mmo-hub players` |
| watch that, live | `rby-mmo-hub watch` (`--interval 5`, `--once`) |
| read the leaderboard | `rby-mmo-hub ranking` — now with W/L |
| see what's actually been played | `rby-mmo-hub history -n 20` |
| greet everyone who connects | `rby-mmo-hub config set motd "…"`, then `SIGHUP` |
| say something to everyone, now | `rby-mmo-hub broadcast "back in 5"` |
| remove somebody who is on right now | `rby-mmo-hub kick BETA --reason "…"` |
| keep them from coming back | `rby-mmo-hub ban 203.0.113.7` |
| check it's actually reachable | `rby-mmo-hub doctor` |

`doctor` is the one to run before you tell anyone the address — it checks the
configuration, then says plainly whether friends outside your network will
reach the port at all:

```console
$ rby-mmo-hub doctor
Configuration
  [ ok ] a join code is required; 1 usable of 1
  [ ok ] wrong passcodes are throttled: 3 free per address per 10m, backing
         off from 2s to 5m; 100 hub-wide in 1m shuts new joins for 1m
  [ ok ] port 7788 is in the unprivileged range
  [warn] limits.perIpConnections (4) is not below maxPlayers (4), so one
         address could take every seat

Reachability
  Addresses on this machine:
    en0     198.51.100.24    public address
    en0     192.168.1.125    private network
    lo0     127.0.0.1        loopback (this machine only)
```

And **`players` answers "who's in my world right now"** without launching the
game to find out — with where each of them is standing:

```console
$ rby-mmo-hub players
2 player(s) online of 8 on 0.0.0.0:7788, snapshot 3s old.

NAME   LOCATION         STATUS  POINTS
HOSTY  PALLET TOWN              1012
ALPHA  VIRIDIAN FOREST  PARTY   1004
```

`rby-mmo-hub ranking` prints the season the same way — with **W and L**
columns — and `rby-mmo-hub history` prints the battles behind it, newest
first, out of a `history.jsonl` ledger the hub appends to as each ranked match
settles and rotates at half a megabyte so it can never run away with the disk.
All of those read files the hub keeps beside its config, so when the hub isn't
running they say so plainly rather than reporting a room that emptied hours
ago. **`rby-mmo-hub watch`** is `players` on a loop for the evenings you'd
rather leave it up.

Three verbs are the other kind — they talk to the hub while it's up, over a
socket in the same directory, so filesystem permissions are the whole
authorisation:

```console
$ rby-mmo-hub broadcast Restarting in 5 for a config change.
Delivered to 3 player(s).

$ rby-mmo-hub kick BETA --reason Take the evening off
Kicked 1 player(s): BETA.
They were shown: Take the evening off
```

The kicked player sees the reason on their own screen — and a kick is not a
ban, so `ban` or `revoke` first if you want it to stick.

**`rby-mmo-hub stats`** is the third, and the only reading no file holds: the
door as it stands this second — connections open, handshakes in flight, wrong
passcodes against the ceiling that trips, whether it *is* tripped, and how
many addresses are backing off. Those counters live in the hub's memory and
are written nowhere, so `status` can only print what they are configured to
be. Addresses are counted, never printed, `--json` included.

```console
$ rby-mmo-hub stats
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
```

**The operator surface is the CLI, and there is no web page.** To run it from
somewhere other than the hub's own machine, SSH to the box and type the same
verbs (`docker compose exec hub rby-mmo-hub …` once you are on it). Everything
a page could have shown you is `watch`, `players`, `ranking`, `history` and
`stats` — that last one for the live door counters, which no file holds — and
reached that way it is already encrypted and authenticated, by SSH itself,
which is more than a login form on a plaintext port would have managed.

**Admin join codes mark a connection.** `rby-mmo-hub invite --admin` mints
one: it joins the game exactly like any other code — same six characters, same
screen — and the hub *marks* the connection it opened. The client is told
about itself, and operator views carry the mark: `invite list`'s `KIND`
column reads `ADMIN`, and the JSON rosters — `players --json`, `status.json`,
the admin socket's `who` — carry an `admin` flag on the connection. Other
players are never shown it. `revoke <id>` takes one back like any other, and
it's worth pairing with `--expires`, because an admin code is worth more to a
thief than a player's one is. It is groundwork: **there is no in-game operator
feature yet**, just the flag the ones that come later will check.

Credentials, bans, the allowlist and the message of the day reload on
`SIGHUP`, so revoking a leaked passcode doesn't interrupt the people already
playing. The full config table —
every key, default and bound, including the seven that tune the wrong-passcode
throttle — is in [server/README.md](server/README.md).

### 🚪 Joining — identical either way

Address first, then passcode, both **before anything is dialled**. An IP or a
hostname both work, and leaving the port off fills in `7788`:

<p align="center">
  <img src="docs/screenshots/join-address.png" width="300" alt="The JOIN grid with MYPC.LAN:7788 typed, on the digits page">
  <img src="docs/screenshots/join-passcode.png" width="300" alt="The JOIN CODE grid mid-entry, showing B ERASES">
</p>

**SELECT** flips the keyboard between letters and digits — the vanilla one has
no numbers at all, which is why this mod ships its own. Dashes, spaces and
lower case are normalised away, so a passcode pasted out of a chat message
works exactly as typed. **`B` erases, and on an empty line it backs out** —
the screen says which, depending on what you've typed, because there's
otherwise no way to tell.

Then you're standing in their world:

<p align="center">
  <img src="docs/screenshots/join-connected.png" width="560" alt="The overworld with another trainer standing there, HOSTY on a nameplate above them">
</p>

Get the passcode wrong and the hub says so in one sentence and leaves you
outside — the grid comes back with what you typed still on it, so a single
wrong character costs one press to fix rather than six.

Both the address and the passcode are stored **per hub**, so playing on two of
them means typing neither of them twice.

---

## 🧩 Plays nice with other mods

Tested against
[DramaticShapeVoxelMod](https://github.com/DramaticShape/DramaticShapeVoxelMod):
both load clean, and everything — presence, chat, trade, battle — works with
the voxel diorama running.

Your friends show up as **voxel characters**, free of charge. That's the
payoff for spawning real NPCs instead of drawing avatars: whoever owns the
world pass draws them too.

Nameplates stay over their characters in Voxel mode too. RBY MMO uses Voxel's
own companion camera projection, including the terrain height under each
avatar, so a nickname follows the 3D character rather than a flat tile
offset. If a different world-rendering mod does not expose a projector, the
overlay safely falls back to the nearby-player corner list.

It's entirely optional, and that's a *checked* claim — the test suite runs
both ways and pins which:

```sh
MMO_WITHOUT_MODS="DRAMATIC_SHAPE" bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
MMO_WITH_MODS="DRAMATIC_SHAPE"    bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
```

---

## 🔬 Prove it

> Everything below is for working *on* the mod, not for playing it. Players
> need none of it — install, enable, host. The scripts here assume a
> Gen1Recomp source checkout with this folder linked in at `mods/rby_mmo`.

**Running it from source.** Copy `.env.example` to `.env`, point `ROM_PATH`
at your own ROM, and:

```sh
bash mods/rby_mmo/tools/play.sh          # boots past the ROM screen, mod on
bash mods/rby_mmo/tools/play.sh guest    # a second window, separate save
```

Two windows on one machine is the quickest way to exercise host↔join while
developing — host in the first, then join `127.0.0.1:7788` from the second
with the passcode the HOST screen is showing. It is not how anyone should
actually play; that's the LAN flow above.

**The suites.**

```sh
luajit mods/rby_mmo/tests/rby_mmo_test.lua   # from the engine root
node server/hub.test.js                      # from this folder
node server/rank.test.js                     # and the ranked half of it
```

The first drives the real headless loader — same `Loader`, same merge the
game uses — and hammers the protocol logic with fake peers. The second boots
the Node hub as a child process and drives it over real sockets. The third is
ranked PVP on the Node side, and it exists as a pair: the same table of
numbers is asserted in `rby_mmo_test.lua`, because two hubs that price a win
differently are two rankings, and the only thing keeping them together is two
suites checking the same answers.

But neither of those ever binds a socket, renders a menu, or spawns an
avatar. **This does:**

```sh
bash mods/rby_mmo/tests/drivers/run-mmo-e2e.sh
```

Two real LÖVE instances. Separate saves. A real socket between them. One
hosts, one joins, and both sides assert:

- ✅ the listener comes up and publishes an address you can re-read later
- ✅ each player lands on the other's roster
- ✅ avatars **walk** to where the network says they are — not teleport
- ✅ leaving a map despawns the avatar but keeps the player listed
- ✅ chat crosses both ways
- ✅ pressing A on someone opens TRADE / BATTLE
- 🔁 **a trade completes** — each side ends holding the other's Pokémon
- ⚔️ **a link battle runs to a decision**, zero `link.desync` on either side
- 🏆 **and it is scored** — both sides report it, the hub settles it, and the
  winner is on the leaderboard when `RANK` is opened
- ✅ a guest LEAVEs and keeps playing
- 🎫 **and can come back as themselves** — the guest rejoins through the real
  menus, is recognised by the claim ticket its save kept, and finds its
  rating where it left it

The dedicated-hub run — `run-hub-e2e.sh`, two guests and a real Node hub, no
in-game host anywhere — adds the party leg on top of all of that:

- 🤝 `INVITE` is on the menu, the other side is asked, and **a party forms**
- ✅ **your party member is in the world** — their character spawned as a real
  NPC at the cell the network says, with their marked nickname drawn over its
  head, read back off a live frame via `overlayState().names`. Every glyph
  the overlay drew is then checked against the real extracted charmap, which
  is not paranoia: the first version of that marker was a `*`, which drew a
  blank hole because the font has no asterisk, and passed every string-level
  assertion that existed at the time
- 🗺️ **and on the TOWN MAP** — a real `src.ui.TownMap` is opened and the
  overlay is asked what it drew on it: their character placed at the city
  their current map resolves to, named
- ✅ the party flag reaches the *other* player's roster (this is the one that
  caught a real bug: the flag rode on a presence update the client was
  throwing away, so `INVITE` went on being offered against somebody who could
  no longer accept it)
- ✅ the members list opens and lists both of you
- ✅ a party line crosses the hub, tagged `party`
- ✅ the party survives a trade *and* a link battle
- ✅ one member pressing `LEAVE` ends it for **both**, and frees them in
  everyone else's presence

Screenshots land in `/tmp/rby_mmo_shots` so you can see it, not just read a
pass count.

> Two windows open and drive themselves. Don't click into them — you'll
> steal the input the drivers are queueing.

---

## 📦 Cutting a release

Pushing to `main` builds the installable zip and publishes it. There is no
manual step and no local build — the artifact players download is always one
GitHub Actions run away from a commit, so it can't quietly drift from the
source.

**To ship a version:** bump `version` in `manifest.json`, add the matching
`CHANGELOG.md` heading, push. The workflow takes the manifest's version when
it's ahead of every existing tag, which makes bumping the manifest the normal
way to cut a release. Failing that it falls back, in order, to a
`workflow_dispatch` input, a `[release X.Y.Z]` tag in the commit message, or
a patch bump on the newest `vX.Y.Z`. Whichever wins is written into the
manifest *inside the archive*, so an installed copy never reports a version
the release it came from doesn't have. An existing tag or release is refused
rather than overwritten.

Each run publishes `rby_mmo-<version>.zip` plus `sha256sums.txt`. The
filename matters: the launcher's update check looks for `<id>-<version>.zip`
first, and `manifest.json` sits at the archive root because that is one of
the two layouts **Import mod .zip** accepts.

**What the archive contains** is decided by `.modkitignore` — the release job
reads that same file rather than keeping a second list that could disagree
with it, so what a release hands a player is what `modkit pack` produces.
Tests, drivers, dev tooling and `docs/` stay out. `docs/` in particular holds
screenshots of a running game, which are composited from tiles, sprites and
font glyphs decoded out of the player's own ROM — fine on a page nobody
installs, not something to put in an archive that gets handed around.

---

## 🧑‍💻 Hooking in from your own mod

```lua
local mmo = mod.find("rby_mmo")
if mmo and mmo.exports.isConnected() then
  -- isHosting() tells you whether this copy is also the relay
  for _, player in ipairs(mmo.exports.players()) do
    print(player.name, player.map, player.x, player.y)
  end
  mmo.exports.say("global", "hello from my mod")
end
```

**Co-op battles announce themselves**, because the engine's own `battle.started`
and `battle.ended` never fire for one and cannot be made to — `battle.started`
comes from `BattleState:enter` and the trainer battle a co-op one displaces is
taken off the stack before it ever enters; `battle.ended` comes from that
battle's `finish`, which the co-op flow never calls. A mod may only emit
`mod.<id>.*` events, so these are the mod's own:

```lua
mod.events:on("mod.rby_mmo.coop_battle_started", function(e)
  -- e.kind      "npc" | "party"      -- a word, not a slot count
  -- e.fighters  4                    -- how many are on the field
  -- e.humans    2 or 4               -- how many of them are people
  -- e.mine      1..4                 -- which slot *this* client is sitting in
  -- e.side      "a" | "b"            -- and which side that puts them on
  -- e.host      true on the one client that simulates the battle
  -- e.trainerId the NPC being fought, or nil against another party
  -- e.ranked    whether a win moves anybody's rating
  -- e.slots     { side, owner, name, species } per slot
  -- e.battle    the live screen, for anything the fields above missed --
  --             READ ONLY. It is the running battle, not a copy: writing to
  --             its sim, pending or result desyncs all four clients, and a
  --             listener that throws is logged and skipped, not rolled back.
end)

mod.events:on("mod.rby_mmo.coop_battle_ended", function(e)
  -- everything above, plus e.result: "win" | "loss" | "draw"
end)
```

Both fire on **every** client in the battle, each with its own `mine` and
`side` — so four clients see four different payloads describing the same
fight.

---

## 🚧 Known jank — read this bit

It's `0.10.0` and it ships flagged `experimental` on purpose. The full list
lives in `mod.card` under `differences.known`. The ones that'll actually bite
you:

- **No NAT traversal.** Hosting from the game means your friends have to
  reach *you*. LAN is effortless; over the internet somebody forwards 7788,
  or you all use a standalone hub on a box with a public address.
- **No host migration — when a player is the host.** Hosting from the game
  means the relay is running *inside* that copy of the game, so if the host
  quits, the game ends for everyone. They get told, rather than left staring
  at a frozen world. Nobody else can pick it up.
  **This does not apply to a dedicated hub**, where nobody is the host: a
  player leaving is just a player leaving, and everyone else carries on. If
  that matters to your group, that alone is a reason to run one.
- **The address field shows only thirteen characters.** You can type up to 32
  and the whole thing is used — but the engine's naming screen draws a fixed
  thirteen cells, so `127.0.0.1:7788` renders as `127.0.0.1:778` with the last
  character off the right edge. The value is correct; you just can't see the
  tail of it while you type. Hostnames of thirteen characters or fewer
  (`MYPC.LAN:7788`) fit exactly. The fix is in the engine's `NamingScreen`,
  which is upstream of this mod.
- **Only ever tested over loopback**, two instances on one desk. Real latency
  and packet loss are still an unknown.
- **No accounts, and no encryption anywhere.** A passcode is required both
  ways, so nobody walks in off the port — but there's no identity beyond
  "holds a working passcode", and two friends can be online under the same
  name. More to the point, the traffic is **not encrypted**: anyone on the
  path can read it, and anyone who captures one handshake can grind the
  six-character passcode offline in seconds, where no rate limit reaches
  them. Host for people you know, or put everyone on WireGuard/Tailscale —
  see the security posture in [server/README.md](server/README.md), which
  spells out exactly what 30 bits buys.

---

## 🙌 Credits

- **[Mirasein](https://www.mirasein.me)** — original character art:
  [`NIRE` and `NIRE HOOD`](#-be-somebody-else).
- **[bryanthaboi](https://github.com/bryanthaboi/gen1recomp)** — Gen1Recomp,
  and the link stack this mod's trade and battle run on unmodified.

---

## Licence

MIT, matching the engine. Bring your own ROM — this repo ships no game data
and never will.

Art credited above belongs to its author; it ships with this mod, not under
its own separate terms.
