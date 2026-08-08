# Changelog

All notable changes to this mod are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version
here must match `manifest.version`.

## [0.10.0] - 2026-08-07

### Added

- **Waiting / cancel on a PVP battle request.** Asking somebody to battle
  holds `Waiting for <name>...` until they answer. **B** (or CANCEL) opens a
  yes/no confirm; No drops back onto the wait, Yes withdraws the ask and
  tells them `<name> cancelled the invite.` A refuse comes back as
  `<name> refused to battle.` rather than leaving the asker busy with
  nothing on screen. New wire type `mmo.request_cancel`; **`PROTOCOL` 8 → 9**
  in `src/Config.lua` and `server/lib/relay.js` together — a protocol-8 hub
  would clear the local wait while still holding `pendingTo`, so a late
  accept could pull the asker into a session they thought they had left.
- **Notifications in the corner, for the things that happen while you are
  doing something else.** Somebody says something, somebody arrives, your
  party member wins a fight — none of it is worth taking the screen for, and
  all of it used to be findable only by opening a menu and going to look. A
  toast is the whole answer: a low-opacity black plate in the **top-left**,
  white text, stacked downward, gone on its own after **five seconds** and
  **five lines at most** with the oldest dropped first — the newest line is
  the one nobody has read yet, so it is never the one evicted. Drawn from
  `render.hud` over the finished frame, menus and text boxes included, so a
  line arriving while you are three levels into the START menu is still read
  where you already are.
- **Drawn in window space, in a small smooth face that has the letters chat
  needs.** The plates are laid out against the letterbox rather than the
  game's 160x144 — a nameplate belongs to a character on a tile; a toast
  belongs to nobody on the map. Window space is also what lets **Rajdhani**
  (bundled, SIL OFL 1.1, original — no ROM bytes) stay antialiased at ~12px
  instead of scaling with the letterbox the way a pixel face had to. It
  carries the lowercase and punctuation the ROM font does not. A font that
  fails to load costs the toasts their look and never the message — LÖVE's
  own face is used, and the warning names the folder to reinstall. **A line
  too long for one row is wrapped between words onto the next**, up to three
  rows for one notification; the plate is budgeted against the window to the
  right of it rather than against the letterbox, capped at half again the
  playfield so nothing runs across a maximised desktop.
- **Chat toasts, every scope, your own lines included.** `EVERYONE`,
  `NEARBY`, `PARTY` and — the one a bubble could never carry — `WHISPER`,
  because a toast is drawn in the receiving player's own corner rather than
  over the sender's head in a world other people are standing in. No scope tag
  on it, unlike the scrollback's own line: a log is read deliberately and a
  toast is read in passing, where the only two questions it has room for are
  who spoke and what they said. Your own outbound line toasts too, under your
  own name, because the scrollback is behind a menu and a message that appears
  nowhere until somebody answers reads as one that was never sent.
- **Arrivals and departures, to everybody on the hub.** `<name> joined the
  server` and `<name> left the server`, off the roster updates that already
  crossed the wire — no new message for it. The whole population is told
  rather than the map, which is what makes *server* the right word in the
  sentence.
- **What the person you are travelling with just did — `mmo.party_event`.**
  A solo wild or trainer fight produced no peer traffic at all, so a party was
  two people who could see where each other were standing and nothing about
  what either was doing. Five kinds now cross: `defeat_wild`,
  `defeated_by_wild`, `capture`, `defeat_trainer` and `defeated_by_trainer`,
  fanned out by the hub to the party and to nobody else. **The wire carries
  what happened — a kind, a species, a level, a trainer — and never the prose
  for it**, which is what keeps the sentence out of two hubs that would drift
  apart writing it twice, and keeps a stranger's process from choosing the
  words on this player's screen. The required fields are part of the kind
  rather than a check beside it, so a half-filled event draws nothing instead
  of stopping a sentence mid-way. **The fighter is not told what they just
  watched** — both hubs leave the sender out of the fan-out — and a link,
  ranked or co-op battle sends nothing, since both sides were already there.
  Gated on the same half-second window chat is, in both hubs: honest traffic
  is at most one per battle, and this is prose appearing unasked-for in the
  corner of somebody else's screen.
- **`mod.exports.toasts()`** hands a driver the queue as a copy, plus what the
  last draw decided. A toast is not a screen anything can be pushed onto and
  it is gone five seconds later, so without this the only way to assert one
  ever appeared was OCR on a screenshot.

### Changed

- **`PROTOCOL` 7 → 8**, in `src/Config.lua` and `server/lib/relay.js`
  together, for `mmo.party_event`. The rule that moved every number before it
  moves this one: a protocol-7 hub has never heard the type and its handler
  table answers an unknown one with silence, so a player would watch their
  partner fight all evening and never be told a thing — and neither end could
  tell that from an ordinary quiet route. A refusal naming both versions is
  the better sentence. **The mod and its hub have to be updated together.**
- **Speech bubbles over heads are gone, and the `BUBBLES` option with them.**
  The toasts replace them and do it better in the two places a bubble was
  weakest: a whisper could never float over a head without being readable by
  whoever was standing there, and a bubble drawn in the world is behind
  whatever menu the player has open at the time. Nameplates stay and are no
  longer behind an option either — a plate only appears when another player is
  in front of you and a toast only when something happened, so the switch that
  used to gate them was a switch for turning off the only evidence that anyone
  else is in the game.

### Fixed

- **Battle handshake refusal names the mods that differ**, via the engine's
  `Handshake.describe` report (and a clear line when the lists match but one
  side still claims a modified link surface).
- **MMO battles are only blocked when a side has touched lockstep rules.**
  A fingerprint mismatch with `linkModified` false on both hellos — Red vs
  Blue, two ROM dumps, this mod alone — is allowed, the way cable club was.
  An `affects_link` mod (or a link-registry write) on either side still
  refuses, and the refusal names the mods. Covered by synthetic hellos in
  `tests/rby_mmo_test.lua`, and by a real Red/Yellow extract when
  `SECONDARY_ROM_PATH` is set (`tests/drivers/run-red-yellow-battle-compat.sh`).
- **Battle invites no longer open over a live fight.** A 1v1 request or a
  PARTY BATTLE ask that arrives during a wild, trainer, link, or co-op
  battle is auto-refused instead of putting a yes/no on top of the fight
  (including when a menu sits above the battle screen).

## [0.9.0] - 2026-08-07

### Added

- **Dedicated-hub operator tools.** `rby-mmo-hub players`, `ranking`,
  `watch`, `history`, `stats`, `kick` and `broadcast` expose live roster,
  ranking, history and operator actions without a game client. The hub writes
  an atomic `status.json`, keeps a bounded battle ledger, and exposes live
  in-memory counters over `admin.sock`.
- **Admin join codes.** `rby-mmo-hub invite --admin` marks the connection
  opened by that code as an operator connection. The flag is derived
  server-side from the credential, shown only to operator surfaces, and kept
  out of ordinary presence broadcasts.
- **Hub message of the day.** A dedicated hub can greet joining players with a
  `HUB` chat-log line, and the `HUB` name is reserved so players cannot
  impersonate hub-originated messages.
- **Server-side location/ranking views.** The in-game `PLAYERS` list and CLI
  player views show where each trainer is when the hub has a current cell, and
  ranking views include the persisted season state.

### Changed

- **The web dashboard is removed.** The operator surface is the CLI/admin
  socket, so tests and docs now exercise that path directly.

## [Unreleased]

### Fixed

- **A JOIN address with no port on it lands on 7788, however it was left
  off.** A bare `MYBOX.LAN` was already completed, but the check was "does
  this end in `:<digits>`" — so `MYBOX.LAN:`, typed by anyone who reached for
  the colon and then remembered they were never told a port, became
  `MYBOX.LAN::7788` and was dialled at host `MYBOX.LAN:`. That resolves to
  nothing, and it fails the way a hub that is switched off fails, so the
  player goes and asks the host to check their end. The port slot after the
  last colon is now read rather than merely spotted: empty, not a number, or
  a number no socket can bind, and `Config.DEFAULT_PORT` fills it in. A port
  that was actually typed is still dialled exactly as typed.
- **Spaces in a JOIN address are removed, wherever they are.** The naming
  grid carries a space glyph and no address has any use for one — neither a
  hostname nor an IP may contain a space — so `MYBOX.LAN ` and `MYBOX . LAN`
  are both just what the grid made easy to type, and both used to be dialled
  with the spaces still in the hostname. They also disagreed with the
  passcode key, which strips whitespace: the code was filed under one string
  and the connection made to another, so a saved passcode stopped being
  found. Both now see the same string. It also means a port held off its
  colon — `MYBOX.LAN: 7788` — keeps the value it plainly means instead of
  reading as a port that was never given. An address that is only a port
  (`:7788`) is refused rather than dialled at an empty host, which is the
  answer an empty address already got.

## [0.8.0] - 2026-08-06

### Added

- **`SERVERS` remembers where you've been.** The disconnected MMO menu grows
  a `SERVERS` row the first time you've connected anywhere, at the top, above
  `HOST GAME` — the next hub you visit can be a menu, not a retyped address
  and passcode. It stays off the menu until there is a first entry to show
  it, and it disappears again the moment you're hosting or connected, the
  same rule `ADDRESS` and `PLAYERS` already follow.
- **Favorites pinned on top, marked `▶`; everyone else by address,
  descending.** A favorited entry carries a `▶` in the row's right-hand
  column — the game's own cursor glyph, the same mark the `PLAYERS` and
  `CHAT` rows already use — and sorts above every plain one no matter when it
  was last used; within each group, entries sort by their normalised
  `host:port` string, Z before A. Recency decides nothing about where an
  entry sits on the list — only whether a non-favorite survives the next
  eviction.
- **Picking an entry opens a submenu of its own.** `CONNECT` dials it the
  same way `JOIN GAME` does — the same CHARSET naming step first, then the
  same challenge if the stored passcode turns out to be wrong.
  `FAVORITE` / `UNFAVORITE` flips the pin, the label swapping with the state
  the way `END GAME` and `LEAVE` already do elsewhere on this menu.
  `EDIT HOST` and `EDIT CODE` reopen the address and the passcode on the
  naming grid without touching the entry's name. `RENAME` is the only row
  that does. `DELETE` is last on purpose — the one row here that can't be
  undone by pressing it again — and asks first: a yes/no confirm names the
  entry before anything happens, defaults to "no", and a "yes" drops the
  row for good and returns you to the list.
- **A new connection writes its own entry, and only once it's real.** The
  recording happens at `WELCOME` — not on every dial — so a wrong passcode or
  a refused connection never litters the list with a hub you never actually
  reached. The entry is named after the address you dialled, with the
  standard port left off — `192.168.1.20:7788` lists as `192.168.1.20`, since
  that port is the one every hub here uses and sixteen characters is all a
  row has. A hub on any other port keeps it in the name, because there it is
  the difference between an address that dials and one that doesn't. Either
  way the entry still holds the whole address, which is what `CONNECT` dials.
  Hosting your own game records nothing, because there's no address you
  dialled to remember.
- **Renamed like anything else typed on this mod's grids: sixteen
  characters, same sanitiser.** A rename that would leave the name empty is
  refused rather than accepted blank — the same rule `Wire.text` already
  enforces everywhere else a name crosses the save or the wire.
- **The list outlives the save.** Entries are dual-written to
  `rby_mmo_servers.json`, beside the claim-ticket file, and mirrored into
  `mod.save` for whichever copy only ever needs to read them back — the file
  wins on a mismatch, so quitting to the title, pressing `CONTINUE` without
  having saved, or switching save slots entirely still finds the same list
  of hubs. The same shape the rank-token file already proved.
- **Capacity sixteen, oldest non-favorite first.** Past sixteen entries, the
  one that's gone longest without being reconnected to is the one evicted to
  make room — favorites don't count against the cap and are never the one
  removed.
- **`CHARACTER` on the MMO menu — before a game, and in one.** Until now the
  character list was a step on the way into a game and nowhere else: the only
  door to it was hosting or joining, so a player who simply wanted to look
  like somebody else had to open a connection to do it, and there was no way
  at all to change your mind between sessions without starting one. There are
  two doors to it now and they open the same list, the one the character
  creator opens: under `HOST GAME` and `JOIN GAME` while you are on your own,
  and under `RANK` — above `LEAVE` and `END GAME` — while you are in a game.
  Either way the choice applies the moment you make it and hands you back to
  the menu you came from, and it writes the same save field the creator always
  wrote, so the character you are wearing is part of the game you save and
  comes back with it.
- **Changing character mid-game changes you for everybody, immediately.** The
  in-game row would have been a lie without this: the hub used to learn which
  character you were wearing when you said hello and there was no message that
  changed it afterwards, so swapping mid-session would have re-dressed you on
  your own screen and nobody else's. Your copy now tells the hub, the hub
  relearns your face and passes it on to everyone in the game — including you,
  so there is one path rather than two that have to agree — and each of their
  copies rebuilds its walking view of you on the spot rather than waiting for
  you to leave the map and come back. A trainer card of yours that somebody
  has open at that moment turns over with it, because the change is written
  into the roster entry the card is holding rather than into a replacement for
  it. From then on every ordinary movement update carries the new character
  too, so a player who joined a second later, or missed the message, is
  corrected without anybody doing anything. The one screen that does not
  follow live is a leaderboard already open on somebody's screen: it keeps the
  portrait it was drawn with until it is next asked to refresh — exactly the
  staleness the points on it already have.
- **The character list shows you what you are picking.** Every row now
  carries that character's 16x16 front-facing frame to the left of its name —
  the same picture the trainer card and the leaderboard already draw, read
  out of the same walking sheet, so nothing new is decoded and nothing new
  ships. Thirty-eight names is a lot of names, and `MIDDLE AGED WOMAN` tells
  you nothing about who that is; scrolling a list of labels to find the one
  you meant was guesswork against a cast most players have only ever seen in
  passing. The labels move right by one tile to open the gutter the pictures
  sit in, and the `▷` that marks the two characters this mod ships is
  untouched in the cursor's own column, so the row still says which is which.
  A character with no art to show — nothing has been decoded yet — leaves its
  gutter empty and lists as before, rather than being an error on a screen
  whose whole job is to be looked at.

### Changed

- **`PROTOCOL` 6 → 7**, in `src/Config.lua` and `server/lib/relay.js`
  together, for the one new message a character change sends. Nothing already
  on the wire changed shape, so an old client still parses everything a new
  hub sends — the breaking direction is the other one, as it has been every
  time: a protocol-6 hub has never heard of that message and answers an
  unknown type with silence, so a player would pick a character on the
  connected menu, watch themselves change, and be the only person in the game
  who could see it, forever, with nothing on screen saying why. A refusal
  naming both versions beats that quietly. So a 0.7.x hub and a 0.8.0 client
  turn each other away at the door, as do a 0.8.0 hub and a 0.7.x client:
  **the mod and its hub have to be updated together.** The same call parties,
  ranked PVP and the running pace each made, one version apart.
- **Leaving a game no longer takes your character off.** The chosen look was
  worn between connecting and disconnecting and at no other time, so quitting
  a game — deliberately, or because the hub hung up, or because you loaded a
  different save — put the vanilla trainer straight back on, in the overworld,
  in your battle pics and on your own trainer card. That made sense while
  choosing a character was something you did *to* join a game. Now that it is
  a thing you can do on your own, it reads as the game undressing you, so it
  stopped: once you have picked a character you keep wearing it, offline and
  online, until you pick a different one. What has not changed is the save
  that never chose: a player who has never touched the character list, and
  never moved the `MY SPRITE` option off its default, is rendered by exactly
  the same code as before and sees exactly what vanilla draws. Wearing a
  character is now something you opt into and can undo — picking `RED` puts
  you back — rather than something the end of a session does for you.

## [0.7.4] - 2026-08-06

### Fixed

- **The player who *joined* a co-op trainer battle no longer has to fight that
  trainer a second time, alone.** Both players walk into the trainer, so the
  engine builds a real battle on both machines; the co-op battle stands in for
  it and hands it the result afterwards. That handoff only ever worked for the
  player who pressed WAIT. Their battle rides across as `waiting.engine` and
  `startBattle` takes it off the stack before the 2-on-2 goes on — the comment
  there says why in one line: *"Left there it would resume the moment the co-op
  battle popped, and the player would fight the same trainer twice."* The
  player who pressed yes arrives through a different door (`onBattle`, the
  message the hub sends the joiner) and that door built its plan with no engine
  battle in it at all, so the unwind was skipped and their own battle spent the
  whole fight buried under the co-op screen. It came back the instant that
  screen popped: the trainer they had just beaten alongside a friend, standing
  in front of them again, with the friend gone. The reference is client-local
  and could never have crossed the wire — it was sitting in `self.encounter`
  the entire time, unread. It is picked up now, keyed on the battle the hub
  named so that the two ways into a co-op battle that never walked into
  anything — a party-versus-party fight, and a join from the ACTIONS menu —
  keep answering nil, which for them is correct.
- **A joined trainer now shows the joiner their entrance and their parting
  line.** Three things hang off that same reference: the trainer's picture, the
  text they say on the way down, and the AI allowance the engine had already
  computed. The joining player got none of them, which read as a small
  graphical inconsistency and was really the same missing reference. Both
  players walked into this trainer; both see them.
- **A trainer somebody was standing in front of is no longer marked beaten by a
  battle they were not in.** A player can be at a trainer, prompt up, when a
  party-versus-party ask arrives and is answered. A party battle displaces
  nothing, so nothing cleared the encounter that trainer was held in — and when
  the 2-on-2 ended, the trainer was handed the *party* battle's result: marked
  beaten by a fight they never took part in, with their prize money paid out
  for it. Their own battle was still on the stack underneath, so it came back
  anyway. The encounter slot is emptied when a co-op battle starts whatever is
  in it now; a trainer this battle did not fight is simply left to be fought.
- **Unwinding the screen stack no longer goes looking for something that is not
  there.** `unwindTo` pops by identity, and its only other stopping condition
  is a guard of sixteen — so a target that had already left the stack did not
  fail to find it, it took sixteen screens down hunting for it, which mid-battle
  is the battle and the world underneath. A held reference outliving its state
  is ordinary (a battle that finishes itself pops itself), so it is checked now
  rather than assumed, and a stale target does nothing at all. The same check
  is what stops a co-op battle adopting an encounter whose battle has already
  ended — reachable when a join is dropped by the hub, the player fights that
  trainer alone, and a later fight against the same class on the same map with
  the same lead produces the same key.

## [0.7.3] - 2026-08-06

### Fixed

- **The `CHAT` row no longer looks like it has the cursor on it.** The unread
  marker on that row has had two lives and neither worked: as a trailing `*`
  it drew nothing at all (the extracted font has no glyph for it, and
  `Font.width` advanced 8px anyway, so the row read as `CHAT` plus a blank
  column), and as a leading `▶` it drew the menu's own cursor glyph — so a
  row with unread messages looked like a second selection sitting on a row
  the cursor was not on. The label is plain `CHAT` now. Unread lines are
  still counted on the chat model; the count simply no longer decorates the
  menu.

## [0.7.2] - 2026-08-06

### Fixed

- **The distributed archive no longer carries the co-op end-to-end drivers.**
  `tests/drivers/mmo_quad.lua` and `tests/drivers/run-quad-e2e.sh` arrived with
  co-op battles and never reached `.modkitignore`, so `pack` duly put both in
  the v0.7.1 zip — two files that reach engine test infrastructure and mean
  nothing to somebody who has just unpacked a mod. Nothing mechanical was going
  to catch it: `lint` has no opinion about a driver script, and the file count
  only looks wrong to a reader who already knows what it should be. That is the
  trap `my-profile.png` and `rank.png` each fell into one release apart, and the
  fix is the same one — name the files. Both drivers are listed now, along with
  the seven screenshots taken since the block was last touched
  (`coop-battle.png`, `coop-item.png`, `coop-switch.png`, `party-ask.png`,
  `party-battle.png`, `party-spectating.png`, `two-parties.png`), so
  `modkit pack` leaves all nine behind — the release workflow already dropped
  `docs/` wholesale, so only the two drivers ever reached a published zip.
  Seven plan files join them on the same footing as every other plan entry —
  `submit-to-mod-index.md` plus the six that had accumulated without a line
  (`coop-battle-hp-sequencing.md`, `coop-battle-status-and-timeout.md`,
  `coop-battle-ux-findings.md`, `coop-run-consent-and-blackout.md`,
  `nire-back-sprite-pixel-ratio.md`, `non-blocking-avatars.md`): working notes
  for whoever picks this up next, not mod content.

### Changed

- **Two version numbers in the docs caught up with the mod.** `README.md`'s
  known-jank section still opened by calling this `0.5.0`, and
  `server/README.md`'s VPS walkthrough still cloned `--branch v0.2.2` — a tag
  from before the hub that walkthrough then tells you to build existed at all.
  Both now name the current release.

## [0.7.1] - 2026-08-05

### Fixed

- **NIRE and NIRE HOOD's back pic draws with square pixels again.** The back
  pics are 48x48, and they were registered at 64/48 so they would take up the
  same 64 screen pixels vanilla's 32x32 back pics get from their default 2x —
  which is the right footprint drawn the wrong way. The plain battle view
  hands that number to the draw call as it stands, onto a nearest-neighbour
  canvas, so two source pixels out of every three came out one pixel wide and
  the third came out two: the sprite read as subtly smeared rather than
  crisply pixelated. The back pic now draws at 1x — 48 pixels, which is
  exactly what the alternate 3D view has been showing all along, since it
  rounds every battle scale to a whole number before drawing. The two views
  finally agree. And a future character that asks for a fractional scale is
  snapped to the nearest whole number with a warning naming it, so the
  artifact cannot come back in through a new character sheet.

## [0.7.0] - 2026-08-05

### Added

- **Co-op battles: two of you against one trainer, and two parties against
  each other.** Walk into a trainer while you are in a party and you are asked
  first: wait for your friend, or go in alone. Waiting tells them where you
  are standing; reaching the same fight, or walking up to the person standing
  at it, offers to join. When both agree, four monsters go on the field.
- **A no that costs nothing.** Declining to join writes no flag, sends no
  message and clears no offer. The friend who is waiting goes on waiting and
  is not even told, and walking back into that same fight asks again — because
  there is no record of the refusal for anything to consult. A refusal that
  persisted would need something to expire it, and that something is what
  would eventually be wrong.
- **A fight you cannot dodge.** Every exit from every prompt ends in a battle.
  B on the wait/alone choice is BATTLE ALONE rather than "never mind", and B
  while waiting reopens that same choice rather than releasing you. The engine
  has committed to the encounter by the time the mod is asked, so a prompt with
  a working cancel would be a prompt that skipped a trainer.
- **A door that shuts.** Nobody joins a battle that has already started, and an
  offer is taken exactly once — a second join, or one racing the first, finds
  nothing left to accept.
- **PARTY BATTLE**, directly under BATTLE on the menu you get by walking up to
  someone. Two parties, four trainers, and all four have to say yes; one no
  ends it for everyone. It refuses, by name and before anything reaches the
  wire, an opponent who is not in a party and a partner of yours who is not on
  this map — then the hub refuses the same things again, because a client's
  word is not a rule.
- **`PROTOCOL` 5 → 6**, in `src/Config.lua` and `server/lib/relay.js`
  together (and `server/package.json`'s version with them). Two branches
  that had never met each claimed 5 — one for the `fast` pace flag, one for
  the co-op vocabulary — so a client and hub could both say "5" and still
  be talking past each other. 6 is the first number that means both.

### Added — the battle itself

- **A real four-monster field.** `src/CoopSim.lua` is the 2-on-2 the engine
  does not have: four battlers out at once, an ordering over all four (not two
  independent pairs), a target chosen per action, and a side that loses only
  when **both** its trainers are out of mons. A speed tie breaks stably on slot
  index rather than a coin flip, because four clients have to agree and a
  per-pair roll gives four answers.
- **A target that falls mid-turn redirects.** Ordinary in a four-way field and
  near-impossible in a 1v1: if your partner knocks your target over before you
  swing, your move goes to whoever is still standing instead of fizzling.
- **The damage is the engine's, not a second copy.** Type effectiveness, STAB,
  the critical-hit shift chain, badge boosts, burn's attack cut, screens and
  the 217..255 random factor all come from `src/battle/Damage.lua`, so a mon
  hits for the same number in a co-op battle as in a wild one. Status,
  accuracy and turn speed likewise come from the engine's own modules.
- **Host-authoritative sync.** One client simulates and the other three replay
  the events it produces, fanned out by a new `mmo.coop_relay`. Four-way
  lockstep would need all four to consume the same RNG draws in the same order
  across four resolutions; the trade is stated plainly rather than hidden.
- **An NPC pair that plays.** A trainer's party is split across two slots, and
  each picks its strongest available move against whichever opponent is
  closest to falling.
- **Every move effect the game has, because none of them are reimplemented.**
  `src/CoopField.lua` is a `BattleState`-shaped object over the four slots
  whose `__index` chain ends at the engine's own `BattleState` — so the move
  that runs *is* `BattleState.performMove`, driving the real `move_effects`
  registry. Charge moves charge, Substitute absorbs, Hyper Beam recharges,
  Metronome calls, multi-hit hits, recoil recoils, Bide stores, stat stages
  move. The discovery that made it possible: `EffectRegistry`, `MoveEffects`
  and `StatusRegistry` never read `battle.player` or `battle.enemy` — they
  take `user` and `target` as arguments and ask the battle for the rest
  through about fourteen methods. Only the bookkeeping is pair-shaped, and
  only the bookkeeping is replaced.
- **All four battle commands.** FIGHT, ITEM, SWITCH and RUN, in the original's
  2×2 box. ITEM goes through the engine's own `ItemEffects.use`, so a potion
  heals what a potion heals and an item that refuses mid-battle refuses in the
  engine's words. SWITCH costs the turn, as it does in the original.
- **Exp, split between both winners, and priced on each player's own machine.**
  The host resolves the knockout but holds nobody's party except its own, so
  what crosses the wire is a *description* of the kill — what fell, at what
  level, and how many shared it — and every client runs the engine's own
  `Experience.apply` over its own live monster. That is what makes a shared
  knockout genuinely worth half each rather than full each, and it divides the
  stat exp the same way. Sending a finished number instead would have skipped
  all of it. Level-ups are announced like any other.
- **EXP.ALL works.** Holding one halves what the monster that fought takes and
  spreads the other half across everyone still standing, exactly as the
  original's second pass does — including the level-ups, the moves that come
  with them, and the evolutions they trigger for a party member that never left
  its ball. A fainted one shares nothing.
- **The trainer's picture, their music and their parting line.** The picture
  holds the field through the opening lines and steps aside before the first
  menu, rather than lingering over the monsters. Their battle theme plays
  through the engine's own picker, so a gym leader still gets a gym leader's
  music, and the victory theme answers it. What they say on the way down is
  said here, because the battle it was written for is the one this displaced
  and it would otherwise never be heard. Which theme it is comes from the
  engine's own `computeMusicKind`, not from a guess — so a gym leader keeps the
  gym leader's music and the rival's last fight keeps its own, off a badge
  table this mod has no business duplicating. The fanfare starts when the win
  is *decided*, so the defeat line and the parting line are read over it rather
  than after it, and it starts once however often the result is reached. The
  map theme is restored on the way out **win or lose** — a victory theme ends
  in a `sound_loop 0` and would otherwise follow the players into the overworld
  and play there forever. The rival's last fight is folded to the gym leader's
  jingle, because no build ships a `finalWin` song.

  *Unverified by ear:* this checkout ships no `data/generated/audio.lua`, so
  nothing plays here and the engine's own battles are silent too. What is
  asserted is the boundary — which song is asked for, and when.
- **`CoopSim.REPLACE` names the one action that is not a turn action.** A
  replacement travels down the same wire as a move, with `kind = "replace"`,
  and nothing in the vocabulary said so -- a bare string in one caller and an
  implicit default in another, next to a `KINDS` table that read as though it
  were exhaustive.

  It is named separately rather than added to `KINDS`, and that is the whole
  of the care needed: `KINDS` is what `resolveTurn` dispatches, so a "replace"
  reaching it would be handed to `runOther`, which has no branch for it -- the
  slot would silently do nothing for a turn instead of falling back to a move.
  Adding it would have been the regression, not the fix. A test pins that, and
  another pins that everything `KINDS` *does* claim is really dispatched: a
  kind in the allow-list with nowhere to go is the same bug from the other
  side.

  Naming it turned up a real one it had been hiding. A **duplicate**
  replacement -- a retry, or one that raced the first -- arrives for a slot
  that has already answered. Its kind was not in `KINDS`, so the fallback
  turned it into a *move* and filed it for that slot, overwriting whatever the
  player had actually chosen for the turn. It is now recognised and dropped.
- **Statuses are enforced, not just inflicted.** SING put a monster to sleep
  with full ceremony -- and it attacked straight through it, because the co-op
  sim called the engine's `performMove` without the per-turn gauntlet the 1v1
  wraps around it. The sim now runs the engine's own `statusInterrupt` through
  the field adapter before every move, and the whole original ritual falls out
  for free: "is fast asleep!" with the sleep counter ticking to "woke up!",
  the 63/256 "fully paralyzed!" roll, freeze that holds until a Fire-type hit,
  confusion's 50% "It hurt itself in its confusion!" with the authentic
  opponent's-screens glitch, flinch eating a second mover's turn (and
  surviving the turn-top clear for a recharging battler -- the Hyper Beam
  glitch), Disable's tick, and full paralysis preserving Fly/Dig
  invulnerability. Exact wording, Enemy-prefixes and onomatopoeia animations
  on all four clients, with no new string tables.
- **Three more real bugs fell out of that work.** Hyper Beam had been firing
  **every turn, free** -- the engine set `mustRecharge` and nothing read it; a
  recharge turn now recharges, keeps the flag on sleep/freeze/flinch per the
  original's asm, and spends no PP. Wrap/Bind/Fire Spin never held their
  victim -- the gate reads a mirror field the engine refreshes from the
  trapper just before checking, and the sim never refreshed it. And a
  Leech-Seeded battler's whole residual tick was being swallowed by a pcall
  (the seed heal indexed a nil opponent), silently dropping poison/burn
  damage that had already landed -- a desync vector; seed now drains to a
  recorded seeder, and the residual is structured so the throw is impossible.
- **A turn has a deadline, and it is the same honest number on every screen.**
  One idle player could lock the battle forever ("Waiting for ALPHA..." with
  nothing enforcing anything) -- and the only clock that existed made the
  *host* forfeit itself after waiting on somebody else. Now the host enforces
  one 60-second deadline per turn for every player slot including its own:
  at expiry every late slot has its first usable move auto-filed at the first
  living target (the owner's chosen policy -- the battle flows on, nobody is
  forfeited), everyone is told who "took too long!", and the wait line shows
  the missing player's name AND a countdown that all four clients start from
  the same event. The auto-pick is all-or-nothing so a slot with no legal
  action can never strand a half-filed turn, the clock stops while a turn is
  narrated or a replacement is being chosen, and the replayers' silence clock
  was raised above the deadline so a legitimately quiet minute no longer
  triggers resync noise.
- **The target picker is a vertical list** -- one opponent per row under
  "Attack who?", no more names clipped at the box edge -- and the field
  answers it: the hovered opponent draws on top of its partner, foe sprites
  draw at 0.85 (keyed to the layout's fixed foe slots, so a party-battle
  client never sees its own pair shrunk), and the hover cursor and animations
  share one anchor with the shrink so they still point at the monster.
- **The readout shows the status.** An enforced sleep used to be invisible
  between messages -- three lost turns with the only evidence long scrolled
  away, indistinguishable from a broken battle. The panel now carries the
  original's three-letter badge (SLP/PAR/BRN/PSN/FRZ) beside the name.
- **Five paper cuts from the first hands-on session, fixed together.**
  - **The "You have nothing to use!" flicker was worse than a flicker.** The
    last line of *every* message batch was wiped by the queue-empty
    fall-through after exactly one frame, input or none -- a one-line batch
    was never readable at all. The shown line now outlives the queue, a
    quarter-second dwell floor stops the same press that opened a menu from
    eating the message it produced, and the 1.6 s auto-advance is unchanged.
  - **Self-only moves skip "Attack who?".** The engine's own marker decides:
    a zero-power primary effect that never rolls accuracy against an enemy is
    self-targeting by construction, so Swords Dance, Rest, Recover, Light
    Screen, Reflect, Mist, Substitute and Focus Energy commit straight from
    the move menu. Growl-class status moves keep the picker (they aim at an
    enemy), and so do Haze, Conversion and Transform -- proven to read the
    chosen target even though the simple rule calls them self-only. Out of
    PP, the picker always opens: the sim substitutes Struggle, which hits.
  - **"Attack who?" lists both opponents** side by side with a cursor, like
    every other picker, instead of one name at a time.
  - **Every battle picker navigates as the grid it is drawn as**, with the
    engine's own semantics: UP/DOWN move vertically, LEFT/RIGHT horizontally,
    clamped at the edges, and the move grid holds position when an arrow
    points past the last move. Down from FIGHT now lands on SWITCH, right on
    ITEM -- the drivers were updated with it.
  - **The wait line never freezes at "(0)".** The countdown was the host's
    forfeit clock displayed on windows where nothing enforces it; when the
    missing player was the host itself -- deliberately unclocked at its own
    menu -- the counter died at zero and read as a hang. A countdown now
    appears only where a clock really enforces one; everywhere else the line
    names who has not acted yet ("Waiting for ALPHA..."), which was always on
    the wire -- every client hears every act, only the host used to listen.
    The host now broadcasts its own choice too, so the other three know it
    acted; a replacement answer is not counted as a turn action; and an act
    claimed for a slot its sender does not own marks nothing.
  - **The wait line no longer flashes between battle lines.** Dismissing a
    line leaves the box empty for one tick before the next is popped, and the
    reassurance fallback used to run in that gap -- so with a replacement
    pause overlapping a playing batch, "X is choosing... (n)" flashed for a
    single frame between every pair of lines. The box's text is now one
    testable decision (`boxText`): mid-batch, the gap draws the original's own
    empty page gap; the wait and spectator lines belong to a finished queue.
- **The battle now waits for its own effects.** The HP bar used to empty and
  the beaten monster used to vanish the moment a resolved turn arrived, with
  the attack animation and its text replaying over an already-dead field. The
  battle keeps two clocks and only one of them was ever allowed to exist on
  screen: sim truth (`mon.hp`, `sendOut`) still applies the instant a turn
  lands — signatures, the desync check and the host's resolution depend on it
  — but the *display* now advances only through the message queue, the way the
  engine's own battle does. Concretely:
  - the engine's HP-drain rows are no longer discarded by the adapter but
    emitted as `drain` events, in the engine's own order (after the hit's
    animation, before "It's not very effective...") and one per strike of a
    multi-hit move with the engine's own pinned stops;
  - the bar drains at the original's exact rate — `maxHP/96` per frame, one
    bar pixel every two frames — blocking the queue while it moves, floor/ceil
    rounding per the engine's own display helper, and deliberately **not**
    skippable, because the original's isn't;
  - a beaten monster stays on the field until its faint row plays, then sinks
    over 30 frames exactly like the original's slide-down, and only then does
    "X fainted!" print;
  - a monster replaced *in the same resolved turn* (an NPC KO — the sim sends
    the replacement out inside `resolveTurn`) still gets its full exit: display
    rows bind to the battler *object* rather than the slot, and a display
    shadow shows the outgoing monster until its `swap` row plays;
  - the last text line stays on screen while effects run, instead of the box
    going blank mid-exchange;
  - display and truth are re-aligned at every safe point (entering the command
    menu, after a resync, at the end), so a lost message can never wedge the
    screen — and a drain carries a frame budget and clamps its wire-sourced
    target into `[0, maxHP]`, so a malformed or hostile value cannot freeze
    the one animation that has no input escape. While closing that, the
    host-authoritative message kinds (`res`, `state`, `gone`) were gated on
    actually coming from the host.
  Old and new clients interoperate: unknown event kinds are ignored, so an
  unmodified client simply keeps today's instant display.
- **The assembled field is sanitised like everything else on the wire.** It
  was the one inbound payload that skipped `Wire`, and the least defensible one
  to skip it: the sender is another player's client, and that table decides how
  many monsters are on the field, whose they are, and what is drawn over them.
  `Wire.coopField` now checks the slot **count** (`buildField` only ever
  checked it on the sending side, so a modified host could send fifty), the
  **side** (an arbitrary third value makes "who may I attack" incoherent), the
  **name** (drawn on screen and put into the events other mods read), and the
  **party length** (unbounded, every faint is answered by another monster and
  the battle never ends). The host reads its own field back through the same
  door, so the shape it plays is provably the shape it sent.
- **The client no longer gives up on a four-way ask before the hub does.** Both
  used `COOP_ASK_TIMEOUT` with no margin, and the asker's clock starts when it
  sends while the hub's starts a round trip later -- so the client expired
  first, cleared its own ask and said "nobody answered", while the hub still
  held one. The player could then pick PARTY BATTLE again, have it dropped as a
  duplicate, and be left pressing a button that did nothing. The client now
  waits `COOP_ASK_GRACE` longer *and* tells the hub when it does give up.
- **A stale offer expires on the hub, not only on the client.** The partner's
  client forgot a received offer after `COOP_OFFER_TIMEOUT`; the hub held the
  waiting player's until they disconnected, so the two ends disagreed about
  whether the fight was still joinable and the player who was waiting waited
  on, told nothing. Both hubs now sweep it.
- **`CoopField.build` keys its cache on the engine it was built against.** It
  only asked whether a metatable had been built, so `F5` in dev mode -- which
  re-requires the engine's modules -- kept handing back one whose `__index`
  pointed at the previous `BattleState`. A hot reload was silently ignored
  inside co-op battles while every other path picked it up.
- **An item paid for on a turn that never resolved is given back.** The bag is
  debited at commit because only that client owns it, but a battle that ends
  before the turn resolves -- the host drops, the stall clock fires -- used to
  take the potion with it, having healed nobody.
- **"Once per session" for the unranked explanation now means once per save**,
  reset on `save.loaded`. It was process-scoped, so a player who loaded a
  different game was never told why a co-op trainer win paid nothing -- which
  is exactly the player who has not heard it.
- **The `battle` field in the co-op events is documented read-only**, in the
  README beside the snippet. It is the running battle rather than a copy, and a
  listener that writes to it desyncs all four clients.
- **Five message lines were running off the right edge of the box**, two of
  them added this release. The box is eighteen characters wide; a trainer name
  is up to ten, and `"<NAME> is choosing... (30)"` on one line was thirty. That
  is how a clipped line ships -- it looks fine for every short name anybody
  tests with. Found by looking at a screenshot from the run above, which caught
  *"trainer to send on"* with the last letter cut off. All five now fit, the
  wait line is split across two rows so a full-length name still does, and the
  suite measures them against the longest name the wire will carry rather than
  a convenient one.
- **A wait now says what it is waiting for, and the pause that blocks
  everything is on a shorter clock.** A player who has not answered a faint
  stops the whole field -- nothing resolves while any slot is awaiting -- so
  the other three sat in front of an empty message box for a full minute, which
  is indistinguishable from a battle that has hung. That ambiguity is exactly
  how the first wedged co-op battle got reported.

  Two changes. The replacement pause gets `COOP_CHOICE_TIMEOUT`, half the turn
  clock: a player still picking a move holds up one turn, a player who has not
  answered a faint holds up everything, and theirs is the easier decision of
  the two -- a short list and one button. And every client now names the person
  it is waiting for and counts down: *"CAL is choosing... (12)"*. Nothing is
  drawn for the first few seconds, because an ordinary turn has all four
  deciding at once and a clock flashing up every turn would be noise.

  When the clock does run out, the host sends out the next living reserve and
  the battle moves again -- and now the picker closes and everybody is told it
  was the clock: *"CAL took too long!"*. Closing it was previously left to the
  button the player never pressed, so the one who ran out of time was parked in
  a bench list for a slot that had already been filled, could not take their
  next turn, and had their eventual pick dropped as a stale duplicate. It
  closes on the *event* now, which is also what a client watching somebody
  else's timeout needs.

  **The four-client run now lets the clock actually expire.** DELTA is asked
  to send one out and simply does not answer; the run then asserts that the
  other three see the countdown naming DELTA, that DELTA's picker closes on its
  own, and that DELTA is told it was the clock. It waits for the *event* rather
  than sleeping a fixed number of seconds, so there is no copy of
  COOP_CHOICE_TIMEOUT out in the driver to drift. Writing it needed one
  correction worth recording: driving the stall from inside `drivePrompts`'
  `onStep` did nothing at all -- the loop answers the prompt regardless of what
  onStep returns -- so the picker was closed by the driver's own keypress a
  second later and the clock never ran. The run now asserts the close took at
  least ten seconds, which is what catches that.

  Making that possible needed the pause to be a fact the *whole table* knows:
  the `choose` event now marks the awaiting slot on every client rather than
  only on the host that set it, and sending a monster out clears it everywhere.
  Before, the three clients who did not resolve the turn had no way to tell a
  paused field from a running one, and so nothing to put on screen.
- **The LAN scenario now fights a co-op battle too** (`run-mmo-e2e.sh`). Every
  2-on-2 ever fought had been relayed by `server/lib/relay.js`; `src/Hub.lua` --
  the hub that runs *inside* the game when a player hosts -- has co-op handlers
  with unit tests and had never carried one turn of a real battle between two
  real clients. The two hubs are written to mirror each other, which is exactly
  the reason to run both: a mirror is a claim. The leg forms a party (the LAN
  scenario had never formed one at all), stages the same trainer on both sides,
  waits, joins, fights to a decision and asserts the field never drifted --
  `gaps=0 desyncs=0 resyncs=0` over the Lua hub, same as over the Node one.

  Writing it turned up that **the LAN run had been broken for a while**: it was
  changed to pick the host's port per run so two runs on one machine stop
  joining each other, and the guest was left dialling the old fixed
  `127.0.0.1:7788`. Every run failed three assertions that all read like a bad
  join code and none of which mention an address. The dial address is now
  derived from the port the host binds, and a pinned `MMO_JOIN_ADDRESS` naming
  a different port is corrected with a note rather than obeyed -- `.env.example`
  says so too, since the stale line came from there.

  One race also had to go: the guest comes off the RANK screen, and
  `closeToOverworld` gets out of a screen by pressing B -- so an invite landing
  mid-close was answered "no" by the button that was closing something else,
  and the party never formed with nothing on screen to say why. The host now
  waits for the guest to say it is standing still.
- **A co-op battle announces itself, and the announcement is worth hearing.**
  The engine's own `battle.started` / `battle.ended` never fire for one and
  cannot be made to: `battle.started` is emitted from `BattleState:enter`, and
  the trainer battle a co-op one displaces is taken off the stack before it
  ever enters; `battle.ended` is emitted from that battle's `finish`, which the
  co-op flow never calls. A mod may only emit `mod.<id>.*` -- that is what
  stops any mod forging an engine event -- so the pair is the mod's own,
  `mod.rby_mmo.coop_battle_started` and `…_ended`, and both are now documented
  in the README.

  The payload was the part that needed fixing. `kind` held the *slot count* --
  a number, under a name that reads like a category -- so a listener asking
  "is this a party battle?" got `4` and could only be wrong. It now says
  `"npc"` or `"party"`, alongside how many of the four are people, which slot
  this client is sitting in and which side that puts them on, whether this
  client is the host, the trainer being fought, and whether a win is worth
  points. Both fire on every client, each with its own seat.

  The four-client run now asserts it by *subscribing*, the way another mod
  would -- which turned up a second thing: the run had been watching
  `Runtime.emit` and reporting `started=0 ended=0`, because a mod's own events
  travel on the loader's bus and not the engine's. The events were firing all
  along; the test was deaf. The suite had the same hole from the other end --
  its mod stub had no `events` at all, so every announcement the mod has ever
  made was thrown inside the pcall that guards it and swallowed in silence.
- **A 2-on-2 against a trainer pays no ranked points, and now says so.** It
  never did -- `coopMatches` is only created on the four-human path -- but that
  was a decision nobody made: it fell out of the code shape, lived as an inline
  condition in two places, was asserted nowhere, and, worst, was never told to
  the player. Winning a battle and watching your rating not move reads as a
  broken leaderboard.

  It stays unranked, deliberately. Elo rates you against an opponent's rating
  and a trainer has none, so there is nothing for the curve to say. Inventing
  one from the trainer's party would be worse than silence: NPCs are an
  infinite, respawning supply, and the rematch discount -- the one thing that
  stops a rating being farmed -- is keyed on pairs of *players* and would never
  fire against a trainer. Two friends could grind gym leaders to the top of the
  board without ever meeting anybody.

  So the rule now lives in one place (`Coop.ranksPoints`), is read by both the
  code that files a result and the code that decides whether badges count --
  the same question, asked once -- and the battle **says why** on a win: *"No
  points for a 2-on-2 vs a trainer. Battle other people to climb the ranks!"*
  Once per session, because a rule explained is a courtesy and a rule repeated
  after every fight is a nag. The battle is still worth everything a trainer
  battle is worth: exp, badges, prize money, the defeated flag.
- **Badges reach the co-op battle they were earned for.** Gen 1 gives the
  player x9/8 on a stat per badge, and the engine fills a battler's badge set
  only when `makeBattler` is handed a save. A co-op battle is built by the
  host, and the host holds one save out of four -- so every battler was built
  with `nil` and **nobody's badges counted**: two players beating a trainer
  together hit weaker than either of them would have done alone, and nothing
  said so. The same shape as the item, move-learning and exp bugs before it.

  The badge set now travels with the party it belongs to -- read off the badge
  *rows* rather than a list written down here, so a mod that adds a badge is
  covered -- is sanitised on the way in like anything else off the wire, and is
  attached to the slot it came from. Every copy of the field is built from the
  same description, so all four clients still agree about how hard all four
  monsters hit.

  **Against another party, nobody gets them, and that is deliberate.**
  `BattleState.makeBattler` says so in its own comment -- "LinkBattle builds
  clamped copies with save=nil (no badge boosts)" -- so the engine's own
  human-versus-human battle gives neither side theirs. Handing them out would
  make a party battle a different game from a link battle, and would do it
  *asymmetrically*: the engine gates badges on `isPlayer`, which on a shared
  four-slot field is a fact about which side you stand on, so side A would get
  boosts and side B could not. Two parties meet on even terms, as two players
  already do.

  A critical hit still ignores badge boosts, exactly as it ignores stat stages
  -- `critIgnoresStages` is the faithful rule and a crit recomputes from
  unmodified stats. That is asserted too, so the next person to measure a badge
  through a forced crit and find it worth nothing has something to read.
- **A ranked 2-on-2 is rated as a team battle, not as two 1v1s paired by slot.**
  The old scheme matched first against first and second against second. It
  reused the whole rating machinery unchanged, which is why it was written that
  way, and it was arbitrary in the way that matters: nothing about a four-way
  says who fought whom. Both players attack both opponents, a move redirects
  across the pair when its target falls, and the side loses together. Slot one
  beating slot one was a fact about the order the hub happened to list them in
  -- and it produced answers nobody could defend. Listing the same two
  opponents the other way round, with the same four people, the same battle and
  the same result, moved three of the four ratings: 43/16/10 became 42/17/11.

  Each player is now rated against the **opposing pair's combined strength**
  -- the mean, which is what "the strength of the pair you beat" means and the
  standard answer wherever team ratings are kept. A strong player carrying a
  weak one is worth about the average of the two, and beating them pays
  accordingly, because that is who was on the field. One rated result each, the
  same Elo curve and the same K as a 1v1, so a co-op win is worth about what a
  win is worth.

  The rematch discount is per player and takes the **fewest** meetings they
  have had with anyone they just beat, noted on every cross pair. Four people
  running the same 2-on-2 all afternoon meet on all four pairs, so it bites
  exactly as it does in a 1v1 -- and two parties taking turns to win is the
  same meeting, discounted the same way. Bringing in somebody genuinely new
  means at least one opponent with no history, and that fight is worth its full
  value to everyone in it.

  Settlement is now unanimous **within** a side before it is read across
  sides -- two team-mates who cannot agree whether they won have not won
  anything -- and one unclaimed name anywhere in the four scores the whole
  battle nothing, because paying out the half that is claimed would rate a team
  against opponents whose ratings are not moving. All four new numbers are
  published, not just the winners'.
- **A player whose last POKeMON falls is a spectator, and the screen says so.**
  The field already knew: the host stops waiting on a slot that is down and
  files nothing for it. The *client* did not -- it kept offering the command
  menu, so that player picked a move, was dropped into a wait, and was asked
  again next turn, for the rest of a battle they were no longer in. A menu that
  answers nothing, offered over and over, reads exactly like a battle that has
  hung, which is how it was reported. Their side is still alive while their
  partner stands, so the right state is watching, not leaving.
- **The message box no longer sits blank.** With nothing to show it now says
  which of the two silences it is -- "waiting for the other trainers" or "you
  have no POKeMON left". An empty box is indistinguishable from a wedged
  battle, and that ambiguity cost a real investigation.
- **The pause after a faint is enforced by the field, not only by its caller.**
  A slot whose monster fell is empty until its owner says what follows, and
  `resolveTurn` now refuses to resolve while any slot is awaiting -- so a
  second caller cannot spend three people's moves on a field that is about to
  change, or hand the side that is one monster down a free turn.
- **The whole faint lifecycle is now covered, headless and with four real
  clients**: a monster that falls with team-mates left stops the battle and its
  owner is asked at once; nothing else resolves while that question is open;
  answering it releases the field; a monster that falls with nothing left stops
  nothing and its trainer simply watches; a side is beaten only when **both**
  its trainers are; and a fainted POKeMON is never put back on the field --
  including when the index naming it arrives off the wire, where `replace`
  substitutes a living one rather than reviving the dead one.
- **The four-client run gives every slot and every bench a different species.**
  Each player's second POKeMON used to be their partner's first, so a bench
  monster coming out after a faint looked exactly like the monster that had
  just died coming back. That cost an investigation and was never a fault. With
  eight distinct species the run now watches every slot and fails if a species
  ever stands again after being seen at zero health.
- **`mmo.coop_relay` fan-out is tested on the node side** (`server/hub.test.js`,
  now 98 checks). The whole of a 2-on-2 rides this one message, and the hub
  never reads a byte of it -- so routing is the entire contract, and every way
  of getting it wrong is quiet. Forward to too few and one player's screen
  silently stops matching the battle; to too many and somebody outside the
  fight is fed turns for a battle they are not in; echo it back to the sender
  and every client applies its own turn twice. None of those close a socket or
  log an error. Driven the long way round over real TCP -- two real parties, a
  real four-way ask, real agreement -- because the group being fanned out to is
  built by that flow. It asserts that a turn reaches all three others and
  nobody else, that the payload is forwarded byte for byte, that the fan-out is
  symmetric in both directions across the party line, that a player in no
  battle cannot inject a turn into one, that an over-deep payload is dropped
  without dropping the player, that one goodbye closes the group for all four,
  and that a two-player NPC pairing routes through the same rule. Verified by
  sabotage: echoing to the sender, fanning out to the whole hub, skipping the
  shape check, and never closing the group each fail it.
- **The replay contract is now asserted, turn by turn.** The most important
  invariant in a host-authoritative design -- one client resolves, the other
  three apply what it says happened -- had nothing checking it, which is why
  every protocol-level fault this feature has had survived so long. The suite
  now runs a second field beside the host's and puts the host's own events
  through **`CoopBattle.playEvents` itself**, comparing `signature()` after
  every single turn. Driving the real replay path matters: a hand-written copy
  of "what a replayer does" would agree with itself forever while the shipped
  code drifted out from under it. Covered: four humans trading blows, the same
  battle seen from a seat on the other side, a switch, a status move that moves
  no HP at all, a two-turn charge move, Struggle's recoil landing on the
  attacker, an NPC pair whose moves only the host ever chooses, a faint and the
  replacement that ends the pause, a forfeit mid-battle, and a battle run all
  the way to its verdict. The wire either side of it is checked too -- that the
  host applies a non-host's replacement instead of queueing it, that it refuses
  one sent for somebody else's slot, and that a re-sent field is addressed to
  whoever asked. And the harness is checked for teeth: one damage event dropped
  on the floor must be caught, or every green run above means nothing.
- **Four real clients now play a party-versus-party battle end to end**
  (`tests/drivers/run-quad-e2e.sh` + `mmo_quad.lua`): a real Node hub and four
  real LOVE instances form two parties, refuse a 2-on-2 once, agree to one, and
  fight it to a scored decision. Everything four-handed had lived only in
  headless tests, where the four "clients" are four tables in one process. It
  found three real faults on its first three runs, none of which two clients
  could reach:
  - **Replayers never saw damage.** The engine's move pipeline, reached
    through `CoopField`, writes HP straight onto the monster and drains only
    text and animations, so a turn announced nothing about what it had done.
    The other three clients' HP bars only moved when the desync check hauled
    them into line once a turn -- a repair mechanism doing the protocol's job,
    which looked right from two clients while every replayer sat a whole turn
    behind. A turn now announces the HP of every slot it changed, whatever
    changed it.
  - **A non-host's replacement deadlocked the battle.** When a monster faints
    its slot is *awaiting*, and nothing resolves until it has sent the next one
    out. The choice arrived down the ordinary action wire, so the host queued
    it as a turn action and asked itself to resolve -- which it refuses to do
    while anything is awaiting. The pause waited on itself, and every non-host
    player whose monster fainted froze the battle for all four until a stall
    timeout picked for them a minute later.
  - **An empty target picker had no way out.** While a slot is awaiting a
    replacement it counts as down, so when both opponents faint in the same
    turn there is a real window with no legal target. FIGHT opened the picker
    on an empty list, and the early return that guarded it swallowed B as well
    -- a cursor pointing at nothing that no key escaped. The picker is now
    refused with a sentence, and backs out on its own if the list empties while
    it is open.
  - Plus a **resync storm**: the host's snapshot was fanned out to all four, so
    one client falling a message behind rewound everybody's sequence, which
    read as a gap, which made them ask too. The answer is now addressed to
    whoever asked.
- **The trainer's id travels with the assembled field.** Only the player who
  walked into them holds the record; anyone who joined by answering an
  invitation has never seen it, and was fighting a nameless trainer — the plain
  trainer theme where the host heard the gym leader's, and an AI with no class
  to reason from. The field now names the trainer and every client resolves the
  record against its own data, through the same sanitiser a player id passes:
  an id that is not id-shaped is refused rather than used as a key, and one
  this build has no record for leaves the battle faceless rather than guessing.
- **RUN and a thrown ball are refused — which is the complete behaviour, not a
  missing one.** A co-op battle is always a trainer battle, and Gen 1 lets you
  do neither in one. Both are refused in the game's own words, read from its
  text table. A ball is recognised from the item record's own `ball` field and
  the `balls` registry rather than a hardcoded list of the five vanilla ones,
  so a modded ball is blocked too.

### Added — the whole battle, and the whole encounter

- **The prompt now appears in front of *every* trainer.** The mod stopped
  trying to intercept the battle and started watching for it: both ways a
  trainer battle begins end in `game.stack:push(battle)`, so the prompt goes
  **on top of** the battle that just arrived. A `StateStack` only updates its
  top, so the engine's battle sits underneath completely untouched — which is
  why BATTLE ALONE costs nothing but closing a menu.
- **The full post-battle flow, because the engine's own battle runs it.** The
  co-op path holds the battle object it displaced and hands it the result, so
  `onFinish` does everything it always did: the defeated-trainer flag, the
  victory rewards and badges, **the whiteout when your party is wiped**, and
  the script that has been waiting in front of the trainer. None of it is
  reimplemented.
- **Battle animations**, through the engine's own `AnimPlayer`, translated
  onto the slot that actually acted — the trick `WideBattle` uses to move an
  animation between anchors it was not authored for.
- **A readable four-monster field**: pairs pushed to the outside edges, a
  status strip per battler, a cursor on your own monster, and the target
  cursor landing on the monster it means rather than only on a name.
- **`mod.rby_mmo.coop_battle_started` / `coop_battle_ended`**, so other mods
  can see a co-op battle. Deliberately *not* `battle.started`/`battle.ended`:
  the loader namespaces `mod.events:emit` to `mod.<id>.*`, and that rule is
  what stops any installed mod forging an engine event.
- **Ranked co-op.** A party battle is reported by all four players and scored
  only when all four agree, as two ordinary matches paired by slot — so the
  Elo curve, the rematch discount and the claimed-name check all apply
  unchanged, and every player gets exactly one rated result.

### Added — running away, and coming back from a loss

- **RUN asks your partner first.** In a party-vs-party battle, picking RUN
  commits nothing: your partner gets a yes/no box in the battle itself. Yes,
  and the whole party flees — the battle ends for all four, the runners take
  the loss and the opponents the win, scored like any other result so running
  at match point buys nothing. No, and you are back at the command menu with
  the turn still yours. Against an NPC trainer the answer is still Gen 1's:
  *"No! There's no running from a trainer battle!"*
- **The box opens on NO, behind a settle floor.** It appears at the exact
  moment everyone is holding A through the turn's messages, so the first
  press cannot confirm it and the cursor starts on the harmless row. The one
  irreversible confirmation in the battle is the one you have to aim at.
- **An unanswered partner never hangs the battle.** The prompt lives under
  the same 60-second turn deadline as everything else; when the clock fires,
  silence counts as a no on every screen at once. A partner who has left the
  battle is not asked at all — a party of one flees on its own say-so.
- **Losing blacks you out, the way the game always did.** Every player whose
  party lost — or who walked out of any co-op battle with nothing left able
  to fight — gets the whole vanilla ritual: party healed, money halved, and
  the warp to *their own* last POKéMON CENTER. Against an NPC the engine's
  own `afterBattle` runs it (the co-op result said `"loss"` where the engine
  listens for `"lose"`, so the ritual had never once fired — found because a
  freshly beaten party was still walking around at 0 HP). A party-vs-party
  battle has no engine battle to hand the result to, so the mod performs the
  same ritual itself — and holds the warp until the last menu (a move to
  forget, an evolution) is off the screen, because a POKéMON CENTER arriving
  under an open question would take the question with it.
- **A win is still a win, even carried out.** A player whose side won while
  their own two monsters fell gets the heal and the trip to the CENTER, but
  the trainer is still marked beaten and the victory script still runs — one
  player's world was quietly diverging from their partner's otherwise.
- **A party with nothing able to fight cannot be battled.** The host checks
  the four parties at the moment it builds the field — the first moment the
  truth exists on any machine — and calls the battle off for everyone
  instead of starting it. Only the host's word can do that: an abort (or a
  field) claimed by anybody else is dropped, because a battle-wide
  declaration from a peer is a forgery by definition.
- **You cannot challenge your own partner.** The PARTY BATTLE row is simply
  not offered on your own teammate — there is nothing to fix, so there is no
  sentence to read — and the client refuses it besides. Asking used to
  soft-lock the asker for seventy silent seconds, because the hub dropped
  the request without answering.
- **The "Asked … for a 2-on-2 battle." box dies with the ask.** It used to
  get buried under the battle screen and resurface when the battle ended,
  announcing an invitation everyone had already answered. It is now taken
  down the moment the ask resolves — and only ever itself, never a prompt
  that arrived on top of it.
- **A lost message no longer freezes a battle at "(0)".** The freeze the
  countdown work left behind: a client that missed one packet — in either
  direction — sat in "waiting" forever, its own recovery clock reset by
  every keypress anyone else made. A stuck client now asks the host for the
  field once, past a grace the host's own deadline gets first; the answer
  hands back the menu, returns any ITEM already paid for, and the silence
  clock listens only to the host it is supposed to be timing.

### Known

- **Prize money and evolution, both of which needed carrying across.** The
  engine pays a trainer's prize from inside its own battle screen, so a battle
  it did not run pays nothing — the co-op path pays it on the way out, at the
  engine's own rate (`baseMoney` × level), for the strongest monster the
  trainer had. And `afterBattle` offers evolutions to whichever mons *the
  battle* recorded as having levelled, so the co-op battle's list is handed to
  the displaced one before its result is.
- **No move learning on a co-op level-up.** A mon that levels gains the level,
  the stats and its evolution check, but the "wants to learn" prompt lives
  inside the engine's own battle screen and a mod-owned battle does not run it.
  The move is not lost — it can still be learned from an item or by levelling
  again in an ordinary battle.
- **No prize text, trainer pic, intro or battle music in a co-op battle.**
  The screen is the mod's, and it draws the field, the menus and the messages
  rather than the whole theatrical frame the engine puts around a 1v1.
- **The host decides.** A modified host could resolve a turn wrongly. That is
  the same trust the engine's own host-authoritative link branch already
  takes, one player wider.
- **Ranked co-op scores a party battle as two matches paired by slot.** Every
  player gets exactly one rated result, but which opponent you are paired
  against is decided by slot order — nothing about a four-way says who fought
  whom. A 2-on-2 against an NPC scores nothing, since there is nobody to rate.

## [0.6.3] - 2026-08-05

### Fixed

- **Your name is no longer "taken" by a ticket you never got to keep.** The
  claim ticket lived only inside the game save, and the save is written when
  the player saves — so quitting to the title and pressing CONTINUE without
  having saved threw the ticket away, and the next connection was told its own
  name was taken, permanently. Two repairs, one per side of the wire. The
  client now banks tickets in a small file of its own
  (`rby_mmo_rank_tokens.json`, one entry per hub and name), written the moment
  a ticket is granted, so it survives CONTINUE, a relaunch, and a save that
  never happened; the copy in the save file is still honoured. And the hub now
  treats a claim as *provisional until proven*: a name whose ticket has never
  been shown back and has never scored a battle is re-issued to whoever is
  actually connecting under it, instead of locking out its own owner after a
  lost welcome or a hub restart. A name that has scored — or whose owner has
  returned even once — is protected exactly as before; the anti-theft rule
  gives nothing away, because an unproven, unscored claim protects nothing
  worth stealing. A claim is also written into `ranking.json` the first time
  it is *proven*, not only when a battle settles, so a restart no longer
  silently reopens a name whose owner has been back since the last scored
  match. (An unproven one is deliberately not written: it is a claim the hub
  hands to whoever connects next by design, so a row for it would be a file
  rewritten once per hello and worth nothing on the way back in.)
- **…and a name somebody is standing in cannot be taken.** The rule above
  reads board state, which cannot see that the holder is *connected right
  now* — so a second player typing a name already in ranked use (two copies
  that never changed the default trainer name is enough) would have taken the
  claim, and the first player's next win would have landed on it. A live,
  ranked holder now refuses the transfer exactly as a proven or scored claim
  does. A battle is likewise scored into the claims it started against or not
  at all: a claim that changed hands between the first turn and the last
  report drops the settlement rather than paying somebody else's name.
- **The two claim implementations agree on what a ticket hash is.** The
  Lua-hosted hub accepted a stored hash of any length where the dedicated hub
  required exactly 64 hex characters; both now require 64.

### Changed

- **`filesystem` joined the declared permissions**, for the ticket file above.
## [0.6.2] - 2026-08-04

### Fixed

- **Other players cannot stand in your way any more.** An avatar was an
  ordinary runtime NPC, and the engine counts every one of those as solid, so
  a friend idling on a doorway, a staircase or a cave mouth sealed it — you
  pressed into them and the step was simply refused, which also meant the
  warp on that tile never fired. The same refusal was quietly costing ledge
  hops and boulder pushes their landing tile. Avatars are now marked
  `passable`, the flag the engine already uses to keep the Pikachu follower
  out of the player's path, so every occupancy check skips them and you walk
  straight through whoever is standing there. Genuine NPCs still block you as
  they always did, and the crowd cuts both ways: the town's own wanderers now
  walk through remote players rather than being penned in by them.
- **You are always the one in front.** When two characters share a tile the
  overworld had no answer for which draws on top — it sorts by pixel depth,
  the two are equal, and the winner changed from frame to frame, so your own
  trainer flickered in and out from behind someone else's. Avatars now sort a
  hundredth of a pixel further back, which decides the tie every time: your
  character draws over theirs, deterministically. That hundredth is invisible
  because it never leaves the sort — the renderer and the nameplates are
  handed the true pixel back, so nobody moves so much as a pixel for it. The
  offset is applied only on whole-pixel frames, so a player standing still
  does not creep up the screen, and everything it wrote is taken off the NPC
  when the avatar despawns, from the table this mod kept rather than one the
  engine will not hand back once you have left the map — the engine reuses
  those tables, and residue would come back as a vanilla character you could
  walk through.

## [0.6.0] - 2026-08-04

### Added

- **Two characters of the mod's own: `NIRE` and `NIRE HOOD`**, drawn by
  [Mirasein](https://www.mirasein.me). Until now
  every character this mod offered was one the ROM already carried — it read
  the sprite catalog and never wrote to it. These are the first entries it
  puts there itself, as original art shipped with the mod, and they are
  registered in the engine's own record shape (`image`, `frames`, `walker`)
  so nothing downstream had to be taught about them: the CHARACTER screen
  lists them because it walks the catalog, a peer wearing one draws because
  the avatar layer looks the id up in the catalog, and the trainer card
  portrait falls out of the same walking sheet as everyone else's.
- **They go further than a borrowed character can.** A ROM character is a
  16x96 walking sheet and nothing else, which is why wearing `COOLTRAINER`
  has never changed what you look like in a battle. These ship the other two
  pics as well, so while you are wearing one the game draws *you* as them:
  the battle back pic, the trainer card, Oak's intro and the Hall of Fame.
  That rides on the engine's `player.sprite` hook — the one seam over
  `field.playerPics` — rather than on anything reaching past the mod API.
- **A mark on the two rows that are the mod's own.** The CHARACTER list is
  36 names the ROM carries and two it does not, and nothing on the row said
  which was which. They now carry `▷` in the cursor's own column — the
  engine's own hollow arrow, one glyph, nothing shifted, so
  `MIDDLE AGED WOMAN` still starts where every other label starts. The mark
  yields on the row the cursor is actually on, because they share that cell
  and two triangles stacked in it would read worse than one.
- **Worn, not merely chosen.** The pics follow the same rule the walking
  sprite already followed: they apply between joining a game and leaving it,
  and a single-player game you never connected in draws exactly what vanilla
  draws. `mod.exports.wornLook()` is the new answer to "what is actually
  being worn right now", next to the existing `myLook()` for "what was
  picked".

### Notes

- `affects_link` stays `false`. `sprites` and `battle_sprite_scales` are not
  link registries, and the suite still asserts the link surface is
  byte-identical with the mod installed — two players, one with these
  characters and one without, still link.
- The back pic is 48x48 against the 32x32 the engine sizes a trainer back
  for, so it ships a `battle_sprite_scales` entry of 64/48. Without it the
  pic would draw half again too tall and stand in the text box.
- Shade 0 of an overworld sheet is transparent on real hardware and in this
  engine, so the handful of white pixels inside these walking frames read as
  transparent rather than white — the same rule every ROM sprite is drawn
  under.

## [0.5.0] - 2026-08-04

### Added

- **Hold B to run.** Hold the B button on foot and you move at bike speed —
  half the frames per tile, the same 2× the Running Shoes gave Gen 3 — with
  no bike and no menu. It hooks `movement.speed` and halves whatever `frames`
  the engine hands it rather than hardcoding a number, so a data pack that
  changes walk or bike speed keeps its own numbers, just halved. It turns
  itself off the instant you're on the bike or surfing — Cycling Road's own
  held-B brake already means something there, and running only ever checks
  "not those two" before it does anything at all.
- **Remote players run too.** A running player's avatar steps at the same
  8-frames-a-tile the bike already gives NPCs on everyone else's screen —
  one more field on the per-step write that already moves `x`, `y` and
  `facing`, set the same way the Pikachu follower speeds itself up. `fast`
  rides `mmo.move` and every presence snapshot, taken strictly (only a
  literal `true` counts, so both hubs read the same bytes the same way) and
  threaded straight through `Roster:move` itself rather than living beside
  it — the exact shape of bug parties shipped with, not repeated here.
- **And bikes finally ride like bikes on other people's screens.** The flag
  says *fast*, not *running*, so a step earns it by being sprinted **or** by
  being taken on the bike — both cost 8 frames a tile, so one boolean carries
  both. Cycling has been on the wire as walking since the first version of
  this mod: a remote cyclist's avatar plodded at 16 while their real player
  covered tiles at 8, shed roughly four tiles a second, and got yanked
  forward by the resync teleport every couple of seconds for the whole ride.
  Cycling Road is watchable now.
- **`B TO RUN`, on by default**, next to `BUBBLES` in the options list. Cheap
  and reversible: turn it off and B goes back to meaning nothing everywhere
  running would apply, since the one place held B already meant something —
  the bike's own brake — is precisely where running has no effect anyway.

### Changed

- **`PROTOCOL` 4 → 5**, in `src/Config.lua` and `server/lib/relay.js`
  together. Nothing already on the wire changed shape, so an old client still
  parses everything a new hub sends — but both hubs rebuild their broadcast
  from a fixed field list, and a protocol-4 hub has never heard of `fast` on
  `mmo.move`: it would drop the flag silently rather than error on it, and
  every remote sprinter and cyclist would look like they were walking,
  forever, with nothing on screen saying why. A refusal naming both versions
  beats that quietly — the same call ranked PVP made one version ago.

## [0.4.0] - 2026-08-04

### Added

- **Ranked PVP.** Every link battle is scored, on the hub, for both players.
  A win adds points and a loss takes them away, never below `0` — and how
  many depends on who you beat: Elo's own curve, so turning over somebody 300
  points above you is worth 27 and beating somebody 300 below is worth 5.
  Hunting the weakest player in the room pays almost nothing, which is the
  anti-farm rule stated the way Elo already states it.
- **A rematch discount, because Elo alone does not close the loop.** Two
  friends can trade wins forever and each collect the fair price of an even
  match, so a pairing already played inside the hour is worth half, then a
  quarter, then nothing — counted in *both* directions, so alternating wins
  does not reset it. Nobody is stopped from playing their friend; the sixth
  rematch of the hour simply is not worth points.
- **A result needs two voices.** Both games report how the battle ended and
  the hub scores it only when the two reports agree. One side claiming a win
  is worth exactly nothing, a retraction cannot manufacture agreement (the
  first answer from each player stands), and a bystander cannot vote on
  somebody else's battle. What that leaves open is written down rather than
  papered over: a dropped link is a draw for the side still standing — the
  engine's own `LinkBattle` ends one that way — and a draw scores nothing, so
  quitting mid-battle avoids the loss. Believing one side alone would be the
  larger hole, since anyone could then mint wins against a player who never
  connected.
- **`RANK` on the MMO menu**, under `MY PROFILE`: the top ten, best first, as
  `[place] [character] [name] [points]`. The character is the player's
  portrait rather than their character *label*, because a label runs to
  seventeen glyphs (`MIDDLE AGED WOMAN`) — the whole row on its own — so the
  row shows the art the trainer card already draws. That costs the row its
  height, so six rows are on screen at once and the list scrolls with up and
  down, with a `1-6 OF 10` footer saying which part of it you are looking at.
  Players on `0` are not listed: everybody starts unranked, and the board is
  something you get onto by winning.
- **A `RANK` row on the trainer card**, on both cards at the same height, so
  what you check before showing yourself off is what everybody else is
  reading. It shares the badge row, right-aligned against the border: the
  card holds seven rows at this spacing and all seven were spoken for, and
  `BADGES/8` is the one that leaves most of its row empty. Points ride with
  presence rather than with the card, so the number is live rather than a
  snapshot of whoever joined an hour ago.
- **`ranking.json`, beside the dedicated hub's `config.json`.** A hub that
  forgot every rating when it restarted would not be a ranking. A file of its
  own and not a section of the config: that file is the host's to edit and
  the CLI rewrites it whole, so a hub writing scores into it would race their
  edits — and a season is state, not configuration. Written whole and renamed
  over, debounced the way credential counts already are, so a player is never
  waiting on a filesystem. A corrupt file is named and then treated as a
  fresh season; a leaderboard is not a reason to take a hub off the air.
- **A claim ticket, so a rating belongs to a player and not to a nickname.**
  Ratings have to be keyed by trainer name — keying on the connection id
  would reset everybody's on every reconnect — and a name is typed, not
  proved, so on its own it meant anyone who knew yours could put your rating
  on and spend it. The first time a hub sees a name it now mints a 16-byte
  token, sends it once in the welcome, and keeps only its SHA-256; the client
  stores it per-hub in `mod.save` and presents it on every later hello.
  Somebody typing a claimed name without the ticket is admitted and plays
  normally, scores nothing, and cannot move the holder's rating — the `RANK`
  screen says so outright rather than leaving them to infer it from a zero.
  Not thrown out, deliberately: a friend who lost their save should not lose
  the hub. It is a claim ticket and not an account — it lives in a save file
  and crosses the same unencrypted link the join code does — and the README
  says exactly that.
- **`mod.exports.points`, `.ranking`, `.requestRanking` and `.isRanked`**, so
  a mod that wants a leaderboard of its own reads this one instead of
  inventing a second scoring system.

### Fixed

- **The character on a trainer card no longer stands on the row beneath it.**
  The portrait is 16px drawn at 2x from y=56, so its last row was y=87 and
  the badge row began at y=88: no overlap, and no gap either, which read as a
  rendering fault once that row grew a `RANK` value on the right. It moved up
  four pixels, which also centres it better against the two rows it belongs
  to. The leaderboard rows had the same crowding — four columns wanting
  exactly the eighteen glyphs a row has — so they now spend the slack on
  gaps and trim a name only when a four-figure rating leaves no room, which
  `Ui.nameRoom` decides and the suite pins.

### Changed

- **`PROTOCOL` 3 → 4**, in `src/Config.lua` and `server/lib/relay.js`
  together. Nothing was removed and an old client still parses everything a
  new hub sends, so the breaking direction is the other one: a protocol-3 hub
  has never heard of a battle result or a leaderboard request, so a newer
  client would report every match into silence and open a `RANK` screen that
  never fills, forever, with nothing on screen to act on. A refusal naming
  both versions is the better failure — the same reasoning parties moved the
  number for one version earlier.
- **`server/package.json` is 0.4.0**, which is also the version
  `manifest.json` carries — `server/config.test.js` asserts they match.
- **The end-to-end run now leaves and comes back.** The claim ticket is four
  files deep — the client stores it under the address it dialled, reads it
  back for that same address, puts it on the next hello, and the hub matches
  it against a digest it loaded rather than the token it minted — and none of
  those links fails loudly: the player is simply not scored any more, quietly,
  under their own name. So the guest now LEAVEs, rejoins through the real
  menus, and asserts it is recognised on that *second* connection, where the
  name is already claimed and only a ticket that survived the whole round trip
  can produce a yes. `guest_left_game`'s patience grew to match the extra leg.
- **Screenshots recaptured out of the end-to-end runs**, the way the rest of
  them are: `mmo-menu.png` (there is a `RANK` row now), `trainer-card.png`
  and `my-profile.png` (both carry the score), plus `rank.png`, which is new.

## [0.3.0] - 2026-08-03

#### Added
- **Parties.** You and one friend, agreed to explicitly and visible from
  everywhere: on the **TOWN MAP** their character stands at the city they are
  actually in with their nickname over it, in the world their nameplate
  carries a leading `▶` so you can pick them out of a crowd, the `PLAYERS`
  list marks them `PARTY`, and a new `PARTY` row on the MMO menu
  holds the members list, a chat scope that reaches them wherever they are,
  and the way out. Two members is the whole design rather than a first step
  towards six — the rules that make it feel solid all follow from the pair,
  and `Config.PARTY_MAX` argues that out where the number is.
- **`INVITE`, on the menu you already get by walking up to somebody and
  pressing A** (and from `PLAYERS`, which opens the same menu). The row is
  present only when a party could actually be formed — neither of you
  already in one — because the hub would refuse it otherwise, and a button
  whose usual answer is "no" is worse than no button.
- **Your party member on the TOWN MAP.** Open the full Kanto map and their
  character is standing at the city they are in, nickname above it, moving as
  they travel. The overworld can only ever show the room you are in; this is
  the screen that answers *where are they*, and it already existed — the mod
  reads the screen's own `mapId → cell` index, so a member indoors shows at
  the town the building is in and a map with no square on the map places
  nobody rather than guessing. Party members only: every player on a busy hub
  drawn at once would bury Kanto under characters. The Pokédex `AREA` view is
  the same screen class and is deliberately left alone — it is asking a
  different question — while the `FLY` picker is not, because knowing where
  your friend is while choosing where to go is the point.
- **A `party` chat scope.** No radius and no name to type: it reaches the
  other member wherever they are in the world, is tagged `[P]` in the log,
  and bubbles over their head the way `NEARBY` does. That is the same rule
  and not an exception to it — a bubble is only drawn in the game of
  somebody who received the line, and a party line goes to the party alone.
- **The members list opens a trainer card, including your own.** The roster
  is deliberately every player *but* you, so `Client.ownCard` builds yours
  from the save rather than looking it up.
- **`Overlay:state()` now reports the nameplate text each frame committed**,
  not just which drawing path it took, so the two-instance driver can assert
  what a plate actually says instead of inferring it from a screenshot — and
  can check every glyph of it against the real extracted charmap.
  That check earned itself immediately. The party marker started life as a
  `*`, and **the font has no asterisk**: `Font.draw` draws nothing for an
  unmapped character while `Font.width` still advances eight pixels for it,
  so it rendered as a plate one glyph too wide with a blank hole at the
  front, and passed a full end-to-end run before anyone looked at the
  pixels. It is `▶` now — the game's own cursor glyph, which the extracted
  font genuinely carries, and which costs one glyph of plate where brackets
  cost two. The guard stays: the trap belongs to anything that ever reaches
  a plate. It is also three bytes of UTF-8, which turned up a byte-counting
  width cap in the corner-list fallback that had been quietly wrong for as
  long as every name was ASCII; it cuts on glyph boundaries now.

### Changed

- **`PROTOCOL` is 3.** Nothing was removed, so an older client's messages
  would all still parse — but the failure that mattered runs the other way:
  against a protocol-2 hub an invite and a party chat line are a type and a
  scope that hub has never heard of, and its handler table answers an unknown
  type with silence. A player pressing `INVITE` and watching nothing happen,
  forever, is a worse sentence than a refusal that names both versions. Hub
  and mod must be updated together.
- **Presence carries whether a player is in a party**, never which one. It is
  the only part anyone outside that party needs — it is what gates their
  `INVITE` row — and a party id on every presence would let any client in the
  game map out who is travelling with whom.
- **Either member leaving ends the party for both.** At two people there is
  no party left to continue, and a party of one that still offered a members
  list and a chat scope with nowhere to send would be worse than none. The
  same is true of a member who disconnects.

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
