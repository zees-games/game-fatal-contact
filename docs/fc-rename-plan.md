# FC rename: what is left (fc-rename-1, phase 2)

Phase 1 is done: classes are `Fc*`, files are `fc_*`, the 16v16 suite is `headless_fc16`, and docs, comments and log text say Fatal Contact. `tools/fc_rename_apply.sh` re-applies that map to a branch that predates it (`--check` lists what it would change). The names below still carry the old FC name, because something outside this repository stores or sends them. Each one changes only in the order given, with its compat alias in place first.

Identifiers are quoted exactly so they can be searched for; in prose they are "the old FC name".

## Entry-point shims (remove last)

| Name | Where | What changes | Order and alias | Owner step |
|---|---|---|---|---|
| `game/arena_module.gd` | shim, `extends "fc_module.gd"` | gs-server-deploy `content/fatalcontact/game.yml:56` `module:` names `game/fc_module.gd` | 1. this repo ships both paths (done). 2. gs-server-deploy points at the new path. 3. delete the shim after that is deployed | none (agent change in gs-server-deploy) |
| `game/arena.tscn` | inherited scene of `game/fc.tscn`, root `ArenaClient` | same file, line 55 `client_scene:` | same | none |
| `scenes/arena_server.tscn` | inherited scene of `scenes/fc_server.tscn`, root `ArenaServer` | same file, line 54 `scene:` | same | none |

## Ids other systems store or send

| Name | Where | What changes | Order and alias | Owner step |
|---|---|---|---|---|
| content id `gamemann/game-fatal-contact` | `game.yml:17`, `game.yml:49` (`former_ids`), `deployment/game-listing.json:13` | pack id | 1. gs-cloud and website-city accept a former id (game.yml already lists `former_ids`). 2. publish under the new id. 3. drop the old one after every shell has updated | owner publishes under the new id |
| cfg game id `game-fatal-contact` | `game/fc_content.gd:7`, `game/fc_flashlight.gd:5`, `game/fc_map_config.gd:7`, `game/fc_module.gd:16`, `game/fc_config.gd:15`, `game/fc_game.gd:278`, `game/fc_bot_loadouts.gd:73`, `game/fc_bots_world.gd:243`, `game/fc_game_vars.gd:123`, `game/fc_map_director.gd:216`, `game/fc_client_session_events.gd:230`, `examples/headless_config.gd:18`, `examples/published_net_host.gd:65`, `examples/dedicated_module_and_bots.gd:394`; dir `cfg/game/game-fatal-contact/` | the `cfg/game/<id>/` dir and every loader call | 1. gs-game `GSGameConfigBinder` and gs-profile `GSProfileSet` (the copies in gs-server-deploy as well) read a second, former game id dir as a fallback. This repo cannot add that: the dir is resolved inside those addons. 2. rename the dir and the constant together. 3. operators move `cfg/server/game/<id>/` | owner moves the server cfg dir on each deployed box |
| user dir `game-fatal-contact` | `game/fc_user_dir.gd:8`, `:14` (marker `user://.migrated_from_game_fatal_contact`), `:26` | nothing: it names the old folder the migration copies from | keep for good | none |
| settings file `user://arena_settings` and namespace `game_fatal_contact` | `game/fc_presentation_setup.gd:14`, `:233` | player settings and the local JSON | 1. read the new name, else the old one, and write the new one. 2. drop the read after a release | none |
| input actions `arena_fire`, `arena_aim`, `arena_reload`, `arena_inspect`, `arena_slot_1`..`5`, `arena_chat`, `arena_chat_team`, `arena_scoreboard`, `arena_view`, `arena_use`, `arena_roam`, `arena_launch`, `arena_launch_props`, `arena_punt`, `arena_bash`, `arena_weapon_next`/`previous`/`last`/`drop`, `arena_fire_mode` | `game/fc_bindings.gd` (the `&"arena_*"` consts) | saved key bindings | 1. gs-ui bindings table maps an old action to the new one on load. 2. rename | none |
| stat, award and leaderboard keys `arena.*` | `deployment/*.json`, `game/fc_stats.gd`, `game/fc_awards.gd`, `game/fc_boards.gd` | site-stored player progress | website-city migration of stored keys first, then rename here | owner runs the website-city migration |
| player key `arena-player-%08d` | `game/fc_client_hud_and_camera.gd:363`, `game/fc_hud_glance.gd:750`, `examples/headless_app_points.gd:26` | avatar seed and app-points key | rename with a site-side key migration | owner runs it with the stat migration |
| avatar schema `arena_stock` | `game/fc_avatars.gd:25` | stored avatar documents name the schema id | with the next schema version; the part ids are done (`fc_body_*`, `fc_head_*`, `fc_crest_*`: `FcAvatars.migrated` reads old ids, and the schema lists them as hidden legacy parts; drop both after one release) | none |
| prop and NPC ids `arena_crate`, `arena_barrel`, `arena_ball`, `arena_pallet`, `arena_grunt`, `arena_brute`, `arena_stalker`, `arena_gunner` | `game/fc_props.gd:40-43`, `game/fc_npcs.gd:31-34`, `game/fc_npc_brain.gd:432-454` | sent in snapshots and named in map docs | rename with a protocol bump; map docs read both | none |
| effect ids `arena_burning`, `arena_haste`, `arena_slowed`, `arena_protected`, `arena_empowered`, `arena_suppressed`, `arena_admin_kill`; loadout `arena_standard`; dresser `arena_skins` | `game/fc_effects.gd`, `game/fc_player_stack.gd:9`, `game/fc_weapon_skins.gd:13` | wire and saved loadouts | with the protocol bump above | none |
| node names `Arena`, `ArenaServer`, `ArenaClient`, `ArenaSimServer` | `game/fc_net_link.gd:30`, `game/fc_sim_host.gd:16`, `game/fc.tscn`, `scenes/fc_server.tscn`, `scenes/fc_sim_server.tscn` | RPCs address nodes by path | rename only with a protocol bump that every client and server takes at once | none |
| addon cfg `game_fatal_contact_weapons`, source prefix `arenapack:` | `game/fc_weapon_roles.gd:12`, `:14` | operator cfg dir `cfg/addons/game_fatal_contact_weapons/` | read both dirs, then rename | owner moves the dir on deployed boxes |
| page keys `arena_load`, `arena_gate_open`, `arena_after_open` | `game/fc_load_timeline.gd:299`, `:306`, `game/fc_client_warm_rest.gd:106` | read by the web shell and Playwright checks | publish both names, move website-city, drop the old | none (agent change in website-city) |
| map pack prefix `fc-surf-dm-maps-`, `fc-dm-maps` map ids | `game/fc_maps.gd:107` | published map pack ids | with the fc-surf-dm-maps / fc-dm-maps republish | owner publishes the renamed packs |
| env `ARENA_*` (config prefix), `ARENA_TICK_RATE`, `ARENA_SNAPSHOT_RATE`, `ARENA_SNAPSHOT_WORKERS`, `ARENA_PLAYER_HEALTH`; argv `--arena-*` | `game/fc_config.gd:22`, `examples/tick_rate_arg.gd:9-18`, `examples/lossy_watch.gd:18`, `examples/headless_config.gd:189`, `examples/headless_mapdrop.gd:48-60` | deploy scripts and operator shells set them | 1. read `FC_*` / `--fc-*` first, the old name with a WRN. 2. move gs-server-deploy and the fleet scripts. 3. drop the old | none |
| profiler zones and the `mod.arena` log channel | zone names in `game/` | external profile readers group by name | rename together with the perf tools that read them | none |
| console names `arena_*` | `game/fc_renamed_names.gd` | already shims that log an ERR naming the `fc_*` name | keep until the shim is retired | none |
| site app slug, gs-server-deploy former id | website-city, gs-server-deploy | outside this repo | as in CLAUDE.md | owner runs website-city's slug migration |

## Text in other repositories

gs-server-deploy `content/fatalcontact/game.yml` names the old entry paths (see the shims). gs-ci tests and some addon docs name the old file names in prose; they still resolve through the shims or are text only.
