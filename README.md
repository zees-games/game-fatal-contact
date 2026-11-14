# Zee's Fatal Contact

A fast first-person shooter for [Godot 4](https://godotengine.org/), built on the [Dot collection](https://moddingcommunity.com/co/4-dot-assets) and [TMC's gaming platform](https://moddingcommunity.com/play). It is also the reference game for Dot: new games are started from a copy of it.

![Preview](https://github.com/zees-games/game-fatal-contact/blob/main/images/preview.gif?raw=true)

*Play on the test server [here](https://moddingcommunity.com/arena/s/arena01/play).*

The project and its assets are open source under the MIT license. Only the back-end web infrastructure is not; if you use your own authentication back end instead of TMC, you build that part yourself.

**Please treat this as partially tested.** It was built with Claude Code and has a headless test suite that passes, but little of it has been in front of real players. Please report anything you run into.

## How it plays

You fight on three built-in dev-textured maps (`dm_atrium`, `dm_pit`, `dm_box`), plus optional map packs:

- **Combat surf maps** from [fc-surf-dm-maps](https://github.com/zees-games/fc-surf-dm-maps), imported through [game-g2gfast](https://github.com/zees-games/game-g2gfast)'s map format.
- **Deathmatch and gun game maps** from [fc-dm-maps](https://github.com/zees-games/fc-dm-maps).

The game does not ship these maps. A server names them in its content configuration and each one is fetched as its own pack. On a surf map you get surf air control, so you can ride the ramps; on the built-in maps the normal air control applies.

### Modes

The goals below are defaults. Set `arena_scorelimit` and `arena_timelimit` to change them (0 means the mode's own value).

| Mode | What you do | Default goal |
| --- | --- | --- |
| Free-For-All | Everybody for themselves | 25 kills |
| Team Deathmatch | Red against Blue | 75 kills for a side |
| Siege | Everybody for themselves, against a horde of monsters, with props to throw | mode default |
| King of the Hill | Hold the one point in the middle | 90 seconds of holding |
| Capture the Flag | Take their flag to yours | 3 captures |
| Gun Game | Every kill gives you a different gun | first through the list |
| Only Snipers | A random sniper on every spawn | 25 kills |

A match starts in warmup, counts down, then goes live. Nobody spawns until it is live (about 13 seconds on the default rules), so an empty room at the start is normal.

### Weapons and feedback

The weapons come from [fc-weapons](https://github.com/zees-games/fc-weapons): melee, sidearms, rifles, heavies and grenades, each with a view model, world model, sounds and recoil. A loadout is a melee weapon, a sidearm, a primary, a grenade and armour. All are free by default; a server can price weapons (`params.loadout_cost` in the weapon profile) and set a total with `mp_loadout_budget`. "Every spawn" next to Random rolls a new loadout at each spawn (`mp_loadout_random_on_spawn`).

The server confirms every hit and kill. You see a hit marker, damage numbers, medals (First Blood, Headshot, Double, Triple and Multi Kill, Revenge, Shutdown, Point Blank, No Scope, Long Shot, Nemesis), a killstreak meter and the points for each kill. A headshot drops points and a health pack. Kill streaks earn rewards.

**Stomp.** Landing on another player's head kills them and bounces you up. The server decides it, so it works under prediction. Cvars: `sv_stomp`, `sv_stomp_damage` (0 is a kill), `sv_stomp_min_speed`, `sv_stomp_head_tolerance`, `sv_stomp_same_team` (off by default), `sv_stomp_bounce`, `sv_stomp_cooldown`.

## Controls

Every key except Esc can be rebound under Menu, Controls. Changes apply at once and are saved.

| Key | Action |
| --- | --- |
| **WASD** | Move |
| **Space** | Jump (hold to keep hopping) |
| **Ctrl** | Crouch |
| **Alt** | Walk |
| **C** | Slide (Ctrl at a run does too) |
| **Shift** | Dash |
| **E** | Launch yourself forward |
| **Mouse 1** | Fire (hold to cook a grenade, release to throw) |
| **Mouse 2** | Aim down the sights |
| **F** | Flashlight (everyone sees your beam) |
| **X** | Bash with whatever is in your hand |
| **R** | Reload |
| **N** | Fire mode: semi, burst, auto (on guns that have more than one) |
| **1**-**5** / wheel | Weapon slot: melee, sidearm, primary, heavy, grenade |
| **Q** | Last weapon |
| **V** | Push to talk |
| **Y** / **U** | Chat / team chat |
| **Tab** (hold) | Scoreboard |
| **H** | Help: modes and your key bindings |
| **Esc** | Menu and release the mouse; Leave is at the bottom |

In Siege, **E** picks up and drops a prop, **X** freezes it, **G** punts it, and launch moves to **P**.

## Getting started

You need [Godot 4.7](https://godotengine.org/download). The game is built from Dot addons, each in its own repository. The easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which clones every project and links the addons in:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/game-arena
./game.sh
```

On Windows, run `bootstrap.ps1` and open the project in Godot.

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots, in a window |
| `./game.sh online` | Start a local server and the browser client, and print the link |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/` |
| `./game.sh help` | All options |

Without the map packs the game plays its three own maps. With bootstrap, fc-surf-dm-maps is linked at `maps/imported` and fc-dm-maps at `maps/imported_dm`. To play one map offline: `./game.sh -- --offline --map surf_10x_reloaded_fixed` or `--map gg-woods`.

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this project. Run its `./setup.sh` once first.

## Running a server

Settings are cvars. Set them in the server config, on the command line, or live from the console. `cvarlist arena_` lists every one with its description. (The `arena_` prefix is only the cvar naming.)

| Cvar | Default | What it does |
| --- | --- | --- |
| `arena_mode` | `free_for_all` | `free_for_all`, `team_deathmatch`, `siege`, `king_of_the_hill`, `capture_the_flag`, `gun_game`, `only_snipers` |
| `arena_scorelimit` | mode's own | Kills to win (a side's, in team modes); 0 is the mode's own; gun game ends at its last gun |
| `arena_timelimit` | mode's own | Seconds a match lasts; 0 is the mode's own |
| `arena_warmup` | mode's own | Seconds of warmup; -1 is the mode's own |
| `arena_minplayers` | 1 | Players needed before a round starts |
| `arena_spawn_mode` | `avoid` | `avoid`, `weighted`, `furthest` or `random` |
| `arena_team_spawn_split` | 1 | Team mode on a map with no team spawns: cut the spawns into two halves, one per team (0 is one shared pool) |
| `arena_streak_rewards` | empty | Kill streak rewards as `streak:reward` pairs (heal, armour, haste, empowered) |
| `arena_loadout_roll_text` | 0 | Print "Random loadout: ..." when a loadout rolls at spawn |
| `cl_respawn_jump_gate` | 1 | Client: a Space that skipped the kill view does not jump on respawn until released |
| `arena_imported_rotation` | `all` | Combat surf maps in the rotation: `all`, `none`, or ids |
| `arena_surf` | 1 | Surf air control on surf maps (0 uses the normal one) |
| `arena_surf_airaccelerate` | 150 | Air acceleration on a surf map |
| `mp_teammate_passthrough` | 1 | Team modes: 0 team-mates are hit and block, 1 shots pass one at the muzzle, 2 every team-mate in the line |

Wall movement: `arena_wall_run` (1 on, 0 off); `arena_wall_jump` and `arena_wall_slide` work the same way. Fine tuning is in the `arena_wall_run_*` and `arena_wall_jump_*` cvars (minimum speed, duration, gravity, angle, push, body roll). `cvarlist arena_wall` lists them with their defaults and ranges.

`mp_teammate_passthrough` is shared with dot-combat, takes effect from the next shot and also covers rockets and grenades in flight. At 2 a team-mate never stops a shot, but a blast still reaches them.

### Ragdolls

Dead bodies fall as ragdolls from [dot-player-char](https://github.com/modcommunity/dot-player-char). The server picks how each one falls and every player sees the same fall.

| Cvar | Default | What it does |
| --- | --- | --- |
| `sv_ragdoll` | 1 | 1 a physical body, 0 a quick fall with no physics |
| `sv_ragdoll_style` | `ragdoll` | `ragdoll`, `stiff` (one piece), `topple` (no physics), `hide` (vanishes) |
| `sv_ragdoll_time` | 10 | Seconds a body lies there before it fades |
| `sv_ragdoll_max` | 8 | Most bodies at once (default 8, 0 = unlimited); the oldest fades to make room |
| `sv_ragdoll_force` | 1 | How hard kills throw bodies; 0 drops them where they stood |
| `sv_ragdoll_reactions` | empty | Weights such as `headshot_launch=6,face_plant=1.5`; 0 turns one off |

### Bots

Bots come from [dot-bot](https://github.com/modcommunity/dot-bot) and play the same solo and on a server.

| Cvar | Default | What it does |
| --- | --- | --- |
| `bot_quota` | 4 | Players to fill the server to; people take a bot's place |
| `bot_quota_mode` | `fill` | `fill`, `fixed`, `per_player` or `off` |
| `bot_difficulty` | `medium` | `easy`, `medium`, `hard` or `nightmare` |
| `bot_reaction` | 0.3 | Any single preset value, e.g. seconds before a bot fires on somebody new |
| `bot_personas` | empty | Deal each bot a character by weight (`warden:2,raider:1`); `off` uses one shared preset |

Each bot gets a character from `cfg/game/game-arena/bot/*.yml` (warden, raider, escort, marksman, runner, balanced). A character leans a bot toward defending, attacking or supporting in CTF, scales the server's `bot_*` values, and gives each bot its own aim spread.

`bot_difficulty` sets about thirty `bot_*` values at once. Change one after choosing a preset and it stays changed; `bot_settings` lists them and `bot_settings_reset` goes back to the preset. dot-bot's README has the full table. Solo, the same names work in the console (the key under Escape), and `./game.sh -- --bot_difficulty hard --bots 5` sets both at launch.

### Console commands

| Command | What it does |
| --- | --- |
| `arena_status`, `arena_score` | Match state and scoreboard |
| `arena_map <id>`, `arena_maps`, `arena_nextmap` | Change the map, list maps, see what is next |
| `arena_modes` | List the modes |
| `arena_vote` | Open a map vote now |
| `arena_restart` | Restart the match |
| `arena_horde [clear]` | Show or clear the monsters |

### Admin commands

These come from [dot-moderation](https://github.com/modcommunity/dot-moderation). Type them in the console, or in chat with a `!` in front.

| Command | Needs | Notes |
| --- | --- | --- |
| `noclip`, `god`, `buddha` `[player] [on\|off]` | `cheats` | With no player, they act on you |
| `hp <player> <n>`, `speed <player> <x>`, `gravity <player> <x>` | `cheats` | Speed and gravity go from 0.25x to 3x |
| `give <player> <weapon>`, `strip <player>` | `cheats` | |
| `freeze <player> [seconds]`, `unfreeze`, `slay`, `slap <player> [damage]`, `respawn`, `rename`, `burn` | `slay` | |
| `blind <player> [on\|off\|seconds]` | `slay` | Blacks out that player's screen |
| `beacon <player> [on\|off]` | `slay` | A ring and a ping on that player |
| `bring`, `goto`, `send <player> <to>`, `return` | `teleport` | |
| `modtools [player]` | `generic` | What is on a player, or what this game supports |

A player can be a name, `@me`, `@all`, `@others`, `@alive`, `@dead` or `@team:<n>`.

### The map vote

The next-map vote is [dot-vote](https://github.com/modcommunity/dot-vote). The defaults (shown below) are in `game/arena_vote.gd`. To change them, create `user://cfg/arena_vote.json`, or use `DOT_VOTE_*` environment variables or `--vote-*` arguments:

```json
{ "end_vote": true, "vote_lead_sec": 120, "include_extend": true, "extend_seconds": 600, "max_extends": 3 }
```

`end_vote: false` turns the end-of-map vote off and `include_extend: false` removes "extend" from the ballot. dot-vote's README lists every setting.

## Testing

```bash
./game.sh test                    # every script parses, then every suite runs
./game.sh test headless_match     # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_match` | A whole match with four bots, then the HUD, menus and weapons |
| `headless_bots` | A bot at each difficulty against a reference player |
| `headless_net` | A server and a client over a connection that drops packets |
| `headless_presentation` | What a client draws and plays |
| `headless_stack` | The whole addon stack together |
| `headless_admin` | The admin commands on a real server |
| `headless_imported` | A deathmatch on a combat surf map (skipped without fc-surf-dm-maps) |
| `dedicated` | A real server: boots, loads the game, runs its commands, unloads it |

## Code layout

| Path | What it does |
| --- | --- |
| `maps/arena_map.gd` | Builds each built-in map from a list of boxes: meshes, collision, and what a headless server checks shots against |
| `maps/arena_bsp_map.gd`, `maps/arena_imported_maps.gd` | Find the combat surf maps and build them |
| `game/arena_player.gd` | Movement, weapons, health and hitboxes on one body |
| `game/arena_game.gd` | Joins the addons together, e.g. turns a kill into a point |
| `game/arena_module.gd` | The dedicated-server side: cvars and console commands |

[`CLAUDE.md`](CLAUDE.md) has the reasoning behind each of these.

## Credits

| Asset | Author / source | License | Where |
| --- | --- | --- | --- |
| Players and bots | Quaternius, [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html) | CC0 1.0 | [dot-player-char](https://github.com/modcommunity/dot-player-char) |
| Avatar parts and horde monsters | Kenney, character kit skins | CC0 | generated from dot-player-char |
| Built-in map grid | Kenney, [Prototype Textures](https://kenney.nl/assets/prototype-textures) | CC0 | `assets/prototype/` |
| Medal icons | Kenney, [Board Game Icons](https://kenney.nl/assets/board-game-icons), [Game Icons](https://kenney.nl/assets/game-icons) | CC0 | `assets/medals/` |
| HUD ability icons | Kenney, [Game Icons](https://kenney.nl/assets/game-icons), [Mobile Controls](https://kenney.nl/assets/mobile-controls) | CC0 | `assets/hud_icons/` |
| Weapon icons | Jestan, [The Ultimate Weapons Pack](https://jestan.itch.io/weapons-pack) | CC0 1.0 (per the itch.io page; the licence file in the zip is outdated) | dot-ui, `addons/dot_ui/icons/jestan/CREDITS.md` |
| Older weapon silhouettes | Rendered from Kenney weapon models by `tools/build_weapon_icons.sh` | CC0 | `assets/weapon_icons/` |
| Weapons (models, sounds, art) | [fc-weapons](https://github.com/zees-games/fc-weapons), which credits its own sources | see fc-weapons | fc-weapons |
| Built-in map surfaces (Bricks097, Concrete047A, PaintedPlaster017, Concrete034, Metal063, Planks039) | [ambientCG](https://ambientcg.com), Lennart Demes and contributors | CC0 1.0 | `assets/surfaces/`, details in `assets/surfaces/CREDITS.md` |
| Footsteps | Kenney, Impact Sounds | CC0 | dot-audio, `addons/dot_audio/stock/CREDITS.md` |
| Ambience beds | Generated by dot-audio | none (synthesized) | dot-audio |
| Mood ambience under each map | OpenGameArt recordings, each author listed in [dot-audio's moods credits](https://github.com/modcommunity/dot-audio/blob/main/addons/dot_audio/stock/moods/CREDITS.md) | CC0 | dot-audio |
| Map toys | Meshes made in code by dot-props; sounds by Kenney | CC0 | `addons/dot_props/toys/sounds/CREDITS.md` |
| Stomp sound | Synthesized at run time by dot-audio's `DotAudioSynth` | none (no recording) | dot-audio |
| Combat surf and deathmatch maps | Other people's work, shared with credit. Each map's author, original page and licence as stated there (often none) are in `maps.json` / `licence.json` | as stated by each author | [fc-surf-dm-maps](https://github.com/zees-games/fc-surf-dm-maps), [fc-dm-maps](https://github.com/zees-games/fc-dm-maps) |

The maps are published under the CDN's credited-community-map exception, not as our own work. This repository carries none of them; each map is its own pack. `arena_maps` names the author beside each map.

**If you made one of these maps and want it removed, open an issue on the repository that holds it and it is taken down.**

## License

MIT. See [LICENSE](LICENSE).
