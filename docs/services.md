# Services: progression, chat, voice, moderation, the vote, the browser, private matches

`FcModule` bridges the game to a server. `FcServices` is the second and last file that names dot-server: it bridges a server to the addons that are not about the game at all.

## Progression

`FcStats` declares the numbers, `FcAwards` is a document of rules over them, `FcBoards` orders them, and `FcProgress` joins all three to the game. The ids are the contract and there is one copy of them.

The tracker is registered as `dot_stats_tracker` (what dot-game's `DotGameStatsFeed` looks up); kills, deaths and damage carry min/max/max_rate. Reporting to the backbone is dot-game's family cvar `stats_report` (`fc_stats_report` is its alias), off by default, and needs a registered backbone client holding STATS_WRITE (the token stays in the client; nothing here reads or logs it).

- **dot-stats to dot-achievements is `DotAchievementStatsLink`, never `stats.recorded.connect(...)`.** `recorded` carries the session total; an achievement is about a lifetime. Wired straight through, the running total is added to the lifetime total on every kill (5,050 after a hundred). `headless_match` asserts lifetime kills equal session kills, the smallest check that tells the two wirings apart.
- **A board is written when a player leaves, not when they score.** A submission reads, compares, writes and re-sorts; a session is when a player's totals stop moving.
- **Medals are the server's.** `FcAwards.MedalBook` (one per game, reset when a round goes live, `forget` on leave) judges each player-on-player kill from `FcAwards.KillFacts`, all read off the simulation: First Blood, Headshot, Double/Triple/Multi Kill (4 s chain, ended by dying), Revenge (your last killer, once), Shutdown (a streak of 5+), Point Blank (< 3 m eye to eye) and Long Shot (30 m+), neither for a knife or anything thrown or explosive, No Scope (a `scoped` weapon without the aim held), Nemesis (the third kill of one player without them killing you back). Team kills, suicides and the world earn nothing. A kill is worth `KILL_POINTS` (100) plus each medal's points; the points are shown, not filed as a stat. Distances are from the simulated states, never `DotDamage.distance`, which a detonation pins to the blast.
- **Accuracy and kill/death are derived, never stored.** A stored quotient is a third number that can disagree with the two it came from.

## Chat

**One chat path.** The `player_chat` event is hooked and cancelled, the text goes to `DotChatRouter`, and the router's `send_fn` hands each recipient's line back to dot-server's manager to put on the wire. That buys a radius channel, whispers, markup and invisible-character stripping, per-channel history, a backlog for a joiner, and `!` commands the game can claim.

**`FcServices` hooks `player_command` as well.** dot-server's chat manager checks for a command prefix before it fires `player_chat`, so a `!` line never reached `DotChatRouter` and the game's own chat commands could not fire. `player_command` fires before the console lookup and is cancellable: the game claims what it knows, and the rest carries on to the console (which keeps `!kick` working). A dead handler behind a name something else answers (`!rtv`, `!vote`) is the hardest kind to find.

## Moderation

**Moderation is built first, and the order is load-bearing.** It publishes `dot_mute_source` on `_ready`, and both routers look that name up when they start; a chat router started first finds nothing, warns once, and enforces no gag for the life of the server.

## Voice

Voice has its own channel on the link. A talk spurt is fifty frames a second per speaker; on the state channel it would sit in the snapshots' ordered queue and add latency to everybody's movement. **The speaker id is stamped from the transport's sender, never read from the payload**, or a client could put words in anybody's mouth. The two voice calls are `unreliable`: ENet honours that as UDP, and a browser's WebSocket delivers it reliably over TCP whatever is asked, so the platform rule falls out rather than being written.

## The website chat relay

`FcServices` builds a `DotChatRelay` when `relay_config.enabled` is set:

- the backbone client is `FcIdentity`'s, and the module assigns `services.backbone` **before** `setup`; a client handed over afterwards is one the relay has already decided it does not have;
- the permission answer is `DotAdminManager.uid_has_permission`;
- the command runner is `DotServer.run_command_as_uid`, with that uid's own flags rather than root.

Relayed commands are off by default and audited either way: a line typed on a web page by somebody not in the game is a privilege path, classified `Source.CHAT`, the least trusted. `DotChatRelayConfig.command_source` is the operator's switch.

## App points and customisation (Gamespice)

`game/fc_app_wiring.gd`, built by the module after the services (`_build_app`), on the dedicated server only. Each part is off until its operator configures it; off is one log line, never a crash, and nothing is sent or granted.

| Part | Addon class | Turned on by |
|---|---|---|
| Earn events | dot-achievements `DotPointsReporter` | `user://app_points.json`, `DOT_POINTS_*` env or `--points-*` argv: `app_id`, `server_id`, `private_key_path` (the key by path; never commit one) |
| Avatars settings | dot-loadout `DotLoadoutSiteSettings` | the identity layer's backbone client |
| Points on the HUD, store items | dot-loadout `DotLoadoutSiteSource` | `user://app_loadout.json`, `DOT_LOADOUT_*` or `--loadout-*`: `site_public_key_path`, `site_audience` |

Earn events are reported by the server only, one per player per moment (count 1), with `meta` `{humans, vsBot}`. The game sends no amounts: the app's points rules price each key, cap it and decide whether play against bots counts. The keys (append, never rename):

| Key | When |
|---|---|
| `kill` | a player killed an opponent (not themself, not a team mate); `vsBot` when the victim is a bot |
| `headshot` | that kill was a headshot (sent beside `kill`) |
| `round_win` | the player was on the winning side (the leader, in a free-for-all) when a round ended |
| `match_win` | the same when the match ended |

Bots and bare seats (no platform key) earn nothing. The avatars section's `appOnly` forces `team_avatars` on (put back when it goes off); its `team:<name>:a` / `team:<name>:b` slots bind an avatar from `team_bodies` to the first and second side through the `team_body_a` / `team_body_b` rules. The balance is replicated to its owner only (`net_app_points_on`, `net_app_points`) and the HUD shows it top left only while the app has points on and the grant verified. FC has no per-player store slots yet, so equipped store items are logged once and ignored.

The new classes are reached through `fc_newer_api.gd`, because the addon tags dot-server-deploy's `addons.lock` pins do not have them yet; a build on those pins leaves every part off.

## An administrator's live tools

`FcModTools` is what dot-moderation's handler table means here, and every verb is somebody else's seam: noclip, freeze, speed and gravity are `DotFpsAdminModifiers`; god and buddha are `DotHealth.invulnerable` and `cannot_die`; slay and slap are ordinary `DotDamage` through the combat manager, so the kill feed, scoreboard and stats hear them; respawn is `FcGame.respawn_player`; burn is `FcEffects.BURNING`. The commands are `DotModToolCommands`, installed on the module so they go when it does. Ids are the session userid as a string ([architecture](architecture.md#one-id-space-for-players)).

- **`admin_abilities` is on for every `FcPlayer`, server and client alike.** The admin modifiers register after the game's own and their indices travel on the wire, so a client without them would read a forced noclip as another modifier and predict the player falling.
- **A slay turns god, buddha and spawn protection off for exactly one damage event** and puts the flags back, and carries `FcEffects.ADMIN_KILL` so the protection hook lets it through.
- **A respawn clears freeze and noclip and keeps god, blind and beacon** (`FcModTools.PERSIST_ON_RESPAWN`): those are about the person, and a death must not end a punishment.
- **Blind and beacon are replicated state, not events**, so a joiner, a lost snapshot and a map change are all corrected by the next snapshot. `net_blind` is owner-only (an opponent who could read it would know when somebody cannot see); `net_beacon` goes to everybody, and a beaconed player's entity is `always_relevant`. The client draws `FcHud.blind_overlay` and `DotFxBeacon` from dot-fx (a ring and a column through walls, not drawn on your own; each pulse plays `FcPresentation.BEACON_SOUND`).

## The map vote

- **dot-vote's commands are installed** (`FcVote.install_commands`, `DotVoteCommands` on the module), and the chat handler claims none of the vote commands unless the vote failed to load: one path. `resolve_fn` turns a typed `dm_atrium` into the ballot's `map:dm_atrium`; `voter_fn` keys a voter as the bare session id, which is what `voters_fn` lists and what a disconnect forgets (dot-vote's default `u<userid>` would let one player vote twice). `vote` keeps its name rather than dot-vote's `votefor`.
- **One clock.** With a vote, only the vote's `DotVoteClock` is advanced; the map director's `DotMapTimeLimit` is the fallback for a server whose vote did not load. Two clocks opened a second ballot over a chosen winner. `dedicated` asserts one moves and the other does not.
- **The vote is told the score.** `FcVote` polls the leading score each tick (best player's frags, or the leading team's total) and follows dot-match's `round_ended`, rebinding on every map change. A score is per match, because dot-match zeroes the scoreboard every round. An extend that raises the vote's score limit raises the match's.
- **Cues reach the client**: `FcVote.cue_due` → `VOTE` event → `FcPresentation`'s catalogue (`FcVote.CUE_*`, synthesised stand-ins) and the HUD's notice line.
- **The ballot is drawn by the client shell.** The vote owns a `DotVoteBallotFeed`; the module points its `ballot_fn` at `server.send_notice`, one copy per playing session with that session's voter id, topic `map_ballot`. dot-server-deploy's shell draws it as a `DotBallotPanel`; a click goes back as the same command a player could type. Standalone, chat still carries the ballot.
- **The M map menu on a server lists this ballot's ids**, and its list is what can run now: a mode row only where the current map can host it (team modes need team spawns, so none on dm_pit), a map row only where the current mode can run. A row from a list opened before a change is refused with the reason (`FcVoteSource.unavailable_reason`, which dot-vote's `DotVoteMapMenu` asks for from API 6), never "There is no map called 'mode:tdm'", which is what a list fetched once on dm_box and walked across a change to dm_pit got. `dedicated` chooses a mode row, chooses it back, and chooses a stale one.
- Defaults follow dot-vote's: a 45-minute map clock (`duration_sec` 2700, and the director's fallback `map_seconds`), the ballot 150 s before it, `round_based` on.
- **`time_up: finish_round` waits only for a live round.** `FcVote.round_in_progress` (the match is live; no match is "cannot tell") is handed to dot-vote's `round_in_progress_fn`, so a limit that runs out in warmup or between rounds changes at once instead of holding for `finish_round_max_sec`. Set by name behind `"round_in_progress_fn" in director`, because a delivered pack runs on the shell's dot-vote and one before API 3 has no such field; there it holds as before. `dedicated` checks warmup, a live round and the round's end on a director of its own.

## The server browser

`FcModule` contributes a query provider (mode, map, round, state, monster and prop counts) and `FcBrowser` reads it.

- **The map is not `entry.map`**, which is dot-server's content id of the loaded game. dot-browser nests a game's own section under `rules["game"]` so a game's `map` field cannot overwrite it.
- **The query port is a separate argument.** `DotBrowserTarget.parse` takes `host:port`; a three-part string fails as a malformed IPv6 address several layers down.
- **Filtering is local, as a rule**: a filter the server applied would be one the server could lie about.

## A private match files nothing

`FcParty` is dot-peer-to-peer at `Trust.SANDBOXED`. This game reports to dot-stats, dot-achievements and dot-leaderboard, and a peer-to-peer host is a player's own machine that can lie about all of it: a host who can cheat and a leaderboard are one exploit. `reporting_allowed()` is asked in one place rather than by four reporters, because the one forgotten is the one that files a host's score to a real board. **Migration is off**: the host holds the match clock, the score and every hitbox, and a private match whose host left has ended.

`headless_presentation` meets over a real HTTP rendezvous (`RendezvousStub`, on ports 38800-38860 so it can run beside game-playlot's), awaited end to end, because the loopback signaller answers inside the call and a missing `await` would pass against it.

## Configuration and the workbench

`FcConfig` (horde pacing, player health/armour/regen/fall-out depth, respawn delay, spawn protection and friendly fire overrides, medal thresholds, the default bot quota) runs through `DotGameConfigBinder`: four grouped files `cfg/game/game-arena/config_horde|players|match|awards/game.yml` (every key commented out at its default; `addons/dot_game/qa/dot_game_cfg_templates.gd` regenerates them from `FcConfig.CFG_FILES`, `headless_config` fails when they drift; a key in the wrong file is refused), `cfg/server/...`, `ARENA_*` env, `--arena-*` argv, `arena_<field>` cvars and one workbench kind per file (`config_<file>`) plus an `ambience` set for the `fc_ambient*` cvars (started by `FcModule` once they exist); a dedicated server refuses an unknown key or bad value. A solo client loads the same layers (lenient) and opens the panel with F9. The block rules (`mp_teamblock`, `mp_enemyblock`, `!block`) are dot-game's `DotGameNoblock` with their own `noblock` kind and `cfg/game/game-arena/noblock/noblock.yml`; the module is not a `DotGameModule`, so `FcGame.make_noblock` and `FcModule` do what that module would. Edits to player numbers apply to the next player seated; the rest apply at once. Not yet in `FcConfig`: monster stats (`fc_npcs.gd`), the movement numbers (`fc_player.gd`) and the surf ride limits.
