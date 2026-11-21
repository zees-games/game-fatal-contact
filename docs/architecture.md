# Architecture: the joins, the id space and the tick

## Why this project exists

Every addon passes its own suite, and every one of those suites runs one addon with the others absent. A code path only one deployment shape reaches is a code path nothing has run. game-fatal-contact is the shape where most of the family is present at once: it is a game, and it is also the only test of the joins between the addons.

```
the fight        gs-player-controller  gs-combat  gs-weapon  gs-loadout  gs-match
                 fc-weapons (the weapons, and everything about them anybody sees)
what you keep    gs-stats  gs-achievements  gs-leaderboard
the world        gs-map  gs-props  gs-npc  gs-npc-ai  gs-npc-ai-director  gs-entity
what plays next  gs-vote
who you are      gs-auth  gs-user  gs-user-avatar  gs-platform  gs-cloud
the server       gs-server  gs-net  gs-chat  gs-voice  gs-moderation
                 gs-browser (its query half)  gs-server-query
the round        gs-objective  gs-effects  gs-spectate  gs-spawn  gs-team
the screen       gs-ui  gs-menu (the Tab board only)  gs-settings  gs-audio  gs-fx  gs-console
everything       gs-core
```

The full list of links is the `/addons/...` lines in `.gitignore`, which is what gs-bootstrap and gs-ci read.

## The seams

Every join between two addons is a few lines, and each is a few lines because the addons refuse to know about each other.

| Join | What it is |
| --- | --- |
| loadout → combat | `FcPlayer.give_loadout`, item ids that are the pack's weapon ids |
| weapons → player | `FcPlayer._build_rig`, a `AwWeaponRig` handed the player's own arsenal by `arsenal_ref` |
| weapons → wire | `FcPlayerNet`: `AwWeaponNet.all_specs()`, `net_weapon` for everybody, `net_carry` for the owner |
| projectiles → clients | `FcProjectiles.launched` → `FcEvents.Kind.LAUNCH` → a copy flown by `client_tick` |
| combat → match | `FcGame._on_entity_killed`, `entity_killed` → `report_kill` |
| match → loadout | `FcGame._on_respawn_due` → `_apply_loadout_deferred` |
| movement → combat | `arsenal.movement/airborne/crouched` pushed from `GSFpsState` |
| match → ui | `FcHud._on_kill`, a `GSKillFeed.Entry` → coloured fragments |
| game → server | `FcModule` and `FcServices`, the two files that name gs-server |
| combat → stats | `FcProgress._on_shot_resolved` / `_on_killed` |
| stats → achievements | `GSAchievementStatsLink`, which differences rather than connecting ([services](services.md#progression)) |
| stats → leaderboard | `FcBoards.submit_session`, once per session rather than per kill |
| map → game | `FcMapSession.change_to_map` → `FcGame.change_map` |
| map → clients | `GSMapSyncHost.send_fn` → `FcNetLink.send_map` |
| vote → map | `FcVoteSource.apply`, routed on a `map:` / `mode:` prefix |
| match → vote | `FcVote.leading_score` polled each tick; gs-match's `round_ended` → `note_round_end` |
| vote → clients | `FcVote.cue_due` → `FcEvents.Kind.VOTE` → `FcPresentation.on_vote_cue` and the HUD's notice line |
| vote → console | `FcVote.install_commands`, gs-vote's `GSVoteCommands` on the module |
| npc → combat | `FcHorde._register_combat`, hitboxes and health under one entity id |
| npc → game | the brain reaches `FcHorde` through `GSRegistry`, never by name |
| chat → server | `FcServices._on_player_chat`, which cancels gs-server's own |
| voice → wire | `FcNetLink.send_voice`, on a channel of its own |
| moderation → everything | two registry names nobody imports: `gs_mute_source`, `gs_ban_source` |
| moderation → the world | `FcModTools.handlers`, one callable per admin ability; `GSModToolCommands` on the module |

Three small decisions in those joins:

- `_on_entity_killed` passes `""` for a world death rather than `"0"`. gs-match reads an empty killer key as "the world"; `"0"` would create a scoreboard record for a player who does not exist.
- `_apply_loadout_deferred` does not await inside the respawn handler. A loadout comes from a store, which may be slow; a respawn may not be. The player is in the world with what they had and the loadout arrives a frame later.
- `apply_loadout` falls back to the default on any failure. An unreachable loadout store is a reason to give somebody a rifle, not a reason to leave them watching.

## One id space for players

`FcPlayer.player_id` is the scoreboard key, the combat entity id, the damage attribution and the loadout key, and gs-server's `session.userid` feeds it.

- **Use the session id, never the peer id.** A peer id is reassigned the moment somebody reconnects, and everything downstream would be handed to the next player to join. `FcModule._add` says so at the point it matters.
- The loadout key is `"arena-player-%08d"`, not `str(id)`. `GSLoadoutKey.is_usable` has a minimum length so a malformed key can never reach a filesystem path, and a bare `"7"` is refused. Padding is right; loosening the check is not.
- Monsters are in a different id space, allocated by `GSEntityTable` ([horde](horde.md#a-monsters-entity-id)). The player half is deliberately not converted; the reason is there.
- Server bots are players with session ids from `FcNetBridge.BOT_SESSION_BASE` (900,000,000 + n), above any userid and below the entity table's ids ([netcode](netcode.md#bots)).

## Order inside a tick

`FcGame.tick()` and `FcPlayer.simulate_tick()` both have an order that is not arbitrary:

1. **Movement, then the shot.** Half a tick of movement at Fatal Contact speeds is fifteen centimetres, which at range is a miss.
2. **Spread inputs are pushed from the simulated state**, never read from a rendered one. An interpolated position differs between client and server by design.
3. **Aim comes from the movement command**, not a second sample. Sampling the mouse twice gives a shot that leaves at a different angle than the player was looking along.
4. **All shots are resolved after everyone has moved**, so a shot is traced against the world as it ends the tick.
5. **Map hurt volumes, then the match.** `_hurt_from_map` runs after the shots; the match ticks last, so a kill scored this tick can end the round this tick.

Inside a player's tick, the map's own mechanics run after the controller's move and before the pits ([imported maps](imported-maps.md#the-maps-own-mechanics)), and drops are swept after the player stack and before the match ([modes](modes.md#points-out-of-a-body)).

## Nobody is harmed behind a loading cover

A client behind its `GSLoadGate` cover froze itself and cannot see. `FcModule` is not on `GSGameModule`, so it borrows gs-game's `GSGameRoster` for the bookkeeping alone (`FcModule.loading`): a seat is loading from the spawn event until the client's `game.cover` report says the cover lifted, and again from every map change (`mark_reloading`). `FcGame.loading_fn` asks it by player id, and `FcEffects.adjust_damage`, the one hook every damage path runs through (weapons, monsters, map hurt volumes, falls), refuses a hit on a loading seat, after the administrator's slay, which is never vetoed. Nobody dies behind a cover, so no round loses a player who never saw it begin. Bots and offline play have no `loading_fn` and are never loading. `headless_lossy` checks it over a real socket.

## One description, three representations

`FcMap` holds a list of `AABB`s. `to_scene()` makes meshes and static bodies, `to_fps_body()` makes a `GSFpsFlatBody`, `to_trace()` makes a `GSTraceFlat`. Building those independently is the obvious approach and it is wrong in a way nothing reports: the server's idea of a wall moves a metre and shots start passing through something clients can see. The self-test asserts all three have the same box count and that a shot at the perimeter stops at it.

It is also why a dev-textured game is easy to reason about: the geometry is the gameplay, and there is no separate art pass that could disagree with it. The texture is Kenney's prototype grid tinted per zone ([maps](maps.md#colour-and-light)) and triplanar-mapped, because a `BoxMesh` UV-maps every face to the same 0..1 square; without triplanar a two-metre box and a forty-metre wall show the same number of grid squares and the texture stops telling you about scale, which is its only job.

An imported combat surf map has no box list and is the one exception; it keeps the same rule by other means ([imported maps](imported-maps.md#the-solid-is-the-games-on-every-machine)).

## Where it runs

`game.yml` (`content_id: gamemann/game-fatal-contact`, `kind: pack`) is the descriptor that travels in the signed gs-cloud pack: `scenes/fc_server.tscn` on the server, `game/fc.tscn` on the client, `game/fc_module.gd` as the module. gs-server-deploy publishes it and runs it as one of its demo servers (`demo.sh`, server 5, at 64 ticks). Because it is delivered as a pack, nothing here declares a `class_name` ([family rule](../../../CLAUDE.md)): scripts preload each other by relative path and `res://` strings go through `FcPaths.rebase`.

## Where the code is

Everything is flat under `game/` and `maps/`, grouped here by what it is for.

| Path | What |
| --- | --- |
| `game/fc_game.gd`, `fc_player.gd`, `fc_player_stack.gd` | the simulation: the game and its tick, the player (movement, weapons, health, hitboxes), the roster and spawning |
| `game/fc_mode.gd`, `fc_modes.gd`, `fc_objectives.gd`, `fc_effects.gd`, `fc_spectate.gd`, `fc_drops.gd` | modes as data and the round's layers |
| `game/fc_horde.gd`, `fc_npcs.gd`, `fc_npc_brain.gd`, `fc_props.gd`, `fc_projectiles.gd`, `fc_content.gd` | monsters, props, projectiles, weapons and the damage table |
| `game/fc_module.gd`, `fc_services.gd`, `fc_mod_tools.gd`, `fc_vote*.gd`, `fc_map_director.gd`, `fc_map_session.gd`, `fc_maps.gd`, `fc_bots.gd`, `fc_server.gd` | the server: the gs-server module and its cvars, chat/voice/moderation, admin tools, the vote, maps, bots |
| `game/fc_net_*.gd`, `fc_player_net.gd`, `fc_npc_net.gd`, `fc_events.gd`, `fc_event.gd`, `fc_request.gd` | the gs-net bridge, link, commands, per-entity net state, events and requests |
| `game/fc_client.gd`, `fc_client_extras.gd`, `fc_hud.gd`, `fc_menus.gd`, `fc_bindings.gd`, `fc_hud_glance.gd`, `fc_presentation.gd`, `fc_browser.gd`, `fc_party.gd`, `fc_avatars.gd`, `fc_projectile_view.gd`, `fc.tscn` | the client: never loaded by a dedicated server |
| `game/fc_stats.gd`, `fc_awards.gd`, `fc_boards.gd`, `fc_progress.gd`, `fc_identity.gd` | progression and identity |
| `fc_award_store.gd` | the achievement files written once per save, off the frame (the addon's file store writes per player in the saving frame; `FcProgress._exit_tree` calls `finish()`). The stats file is gs-stats' own `GSStatsStoreFile` (write-behind, one write per flush) |
| `game/fc_paths.gd` | `rebase` for every `res://` path (pack delivery) |
| `game/fc_content_groups.gd`, `groups.json` | each map's own files are the download group `map-<id>`; a client fetches the group of the map it plays and tops up on a map change |
| `assets/surfaces/*/*.jpg.import` | `compress/mode=1` (lossy WebP), not 2 (VRAM): the headless import behind a publish writes only the desktop `bptc` variant, 1.4 MiB a texture, 25 MB of the 38 MB pack and unusable where a browser lacks BPTC; lossy is 0.26 MiB each and the pack is 15 MiB |
| `maps/fc_map.gd`, `fc_map_survey.gd`, `fc_map_paint.gd`, `fc_map_lighting.gd` | the built-in maps as box lists, the survey, their colours, their lighting |
| `maps/fc_bsp_map.gd`, `fc_imported_maps.gd`, `fc_map_mechanics.gd`, `fc_ladder_mode.gd`, `*.gdshader` | the combat surf maps (copies of Airdrift's loader); `maps/imported` is the fc-surf-dm-maps link |
