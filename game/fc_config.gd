extends DotConfig

## Fatal Contact's server tunables for [DotGameConfigBinder]: `fc_<field>` cvars, a `config` profile at
## `cfg/server/game/game-arena/config/game.yml`, `ARENA_*` env and `--arena-*` argv.

## `@export_group` -> the cfg file it lives in: `cfg/game/game-arena/config_<file>/game.yml`.
const FcContent := preload("fc_content.gd")
const CFG_FILES := {
	"Horde": "horde", "Players": "players", "Kill rewards": "players", "Stomp": "players", "Match": "match", "Bots": "match", "Awards": "awards", "Surf": "surf", "Simulation": "match",
}


## The binder every entry point uses: [param config] layered, one cfg file per [constant CFG_FILES] entry.
static func make_binder(config: DotConfig, json_path := "") -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(config, "game-arena", "fc", json_path)
	b.grouped = true
	b.group_files = CFG_FILES
	return b


func env_prefix() -> String:
	return "ARENA_"


func cli_prefix() -> String:
	return "--arena-"


@export_group("Horde")
## Horde monsters per player at the most intense moment.
@export_range(0.0, 40.0, 0.5) var horde_peak_per_player: float = 8.0

## Horde monsters per player while the pressure builds.
@export_range(0.0, 40.0, 0.5) var horde_build_up_per_player: float = 3.5

## Horde monsters per player in a lull.
@export_range(0.0, 40.0, 0.5) var horde_relax_per_player: float = 1.0

## Most horde monsters alive at once, whatever the player count.
@export_range(1, 200, 1) var horde_cap: int = 36

## Nearest metres from a player the horde spawns a monster.
@export_range(1.0, 100.0, 1.0) var horde_spawn_min_distance: float = 12.0

## Farthest metres from a player the horde spawns a monster.
@export_range(2.0, 200.0, 1.0) var horde_spawn_max_distance: float = 34.0

## Monsters spawned per burst.
@export_range(1, 20, 1) var horde_spawn_burst: int = 3

## Seconds between spawn bursts.
@export_range(0.1, 30.0, 0.1) var horde_spawn_interval: float = 0.6


func validate() -> DotResult:
	if horde_spawn_max_distance <= horde_spawn_min_distance:
		return DotResult.fail(DotError.CODE_INVALID, "horde_spawn_max_distance must exceed horde_spawn_min_distance")
	if max_health_cap > 0.0 and max_health_cap < player_health:
		return DotResult.fail(DotError.CODE_INVALID, "max_health_cap must be 0 (unlimited) or at least player_health")
	return DotResult.success(null)


@export_group("Players")
## Health a player spawns with and heals up to.
@export_range(1.0, 1000.0, 1.0) var player_health: float = 100.0

## Armour a player can carry.
@export_range(0.0, 1000.0, 1.0) var player_armour: float = 100.0

## Health regained per second; 0 keeps health a pickup.
@export_range(0.0, 100.0, 0.5) var player_regen: float = 0.0

## How far under an imported map's bounds a player is counted as out of it, metres.
@export_range(1.0, 200.0, 1.0) var fall_out_depth: float = 10.0

## Standing height of every avatar and its collision hull, in map units (the classic shooter's player is 72). The visible figure is scaled to it, so all avatars stand the same; the eye is 8 units (half the radius) under the top, 64.
@export_range(16.0, 400.0, 1.0) var avatar_height_units: float = 72.0

## Crouched height in map units: the crouched hull, the crouched eye (8 under it) and the height the hit zones squeeze to, so all three agree. 54, three quarters of standing as in the later classic shooters, is where the drawn figure crouches with its knees near square; the original's 36 squeezed the zones under the drawn head.
@export_range(8.0, 400.0, 1.0) var avatar_crouch_units: float = 54.0

## Half the hull's width in map units (16, a 32 wide hull).
@export_range(2.0, 100.0, 0.5) var avatar_radius_units: float = 16.0

## Metres in a map unit. 0.01905 is the scale imported maps are drawn at, so a 72 unit player is 1.37 m beside a 2.13 m door; 0.0254 makes the player 1.83 m but 96 map units tall.
@export_range(0.005, 0.1, 0.00005) var avatar_unit_metres: float = 0.01905

## Team avatars: the body each side wears in a team mode, in team order (comma list; an empty entry leaves that side its own looks). Each is <id>.glb in team_body_dirs; a missing one falls back to the player's own look. The server's fc_team_avatars turns them on or off.
@export var team_bodies: String = "fc_swat,fc_military"

## Directories searched in order for the team bodies' <id>.glb (comma list). The files are not in this repository.
@export var team_body_dirs: String = "user://team_bodies,res://private/team_bodies"

@export_group("Kill rewards")
## Health a headshot kill gives its killer (default 5). 0 gives none.
@export_range(0.0, 1000.0, 1.0) var headshot_heal: float = 5.0

## Most health a headshot's reward may lift a player to; a player spawns on [member player_health]. 0 is unlimited. Other healing still stops at [member player_health].
@export_range(0.0, 10000.0, 1.0) var max_health_cap: float = 110.0

## Health every kill gives its killer, on top of a headshot's (default off).
@export_range(0.0, 1000.0, 1.0) var kill_reward_heal: float = 0.0

## Armour every kill gives its killer (default off).
@export_range(0.0, 1000.0, 1.0) var kill_reward_armour: float = 0.0

## Every kill gives its killer haste (a speed boost for a while; default off).
@export var kill_reward_haste: bool = false

## Every kill gives its killer empowered (more damage for a while; default off).
@export var kill_reward_empowered: bool = false

@export_group("Stomp")
## Landing on a player's head hurts them.
@export var stomp_enabled: bool = true

## Health a stomp takes; 0 kills outright.
@export_range(0.0, 1000.0, 1.0) var stomp_damage: float = 0.0

## Downward speed in m/s needed for a stomp.
@export_range(0.0, 100.0, 0.5) var stomp_min_speed: float = 4.0

## Metres the feet may be above or below the top of the head.
@export_range(0.0, 2.0, 0.05) var stomp_head_tolerance: float = 0.35

## Whether teammates can be stomped (ignores friendly fire).
@export var stomp_same_team: bool = false

## Upward speed in m/s the stomper bounces with.
@export_range(0.0, 50.0, 0.5) var stomp_bounce: float = 8.0

## Seconds before the same player can stomp again.
@export_range(0.0, 30.0, 0.1) var stomp_cooldown_sec: float = 0.5

## Sound id played on a stomp (a dot-audio id).
@export var stomp_sound: String = "stomp"

## Effect id spawned on a stomp (a dot-fx id).
@export var stomp_effect: String = "stomp_puff"

@export_group("Match")
## Seconds before a dead player respawns; -1 keeps each mode's own.
@export_range(-1.0, 60.0, 0.5) var respawn_delay_sec: float = -1.0

## Seconds of protection after a spawn (0.5 works); -1 keeps each mode's own. Default 3.
@export_range(-1.0, 60.0, 0.1) var spawn_protection_sec: float = 3.0

## What ends spawn protection early: 0 nothing (it runs its seconds out), 1 the first shot (default: a player
## cannot clear a room while invulnerable), 2 the first move or jump, 3 either. Ends all three records at once.
@export_range(0, 3, 1) var spawn_protection_break: int = 1

## Feet of travel from the spawn point, in any direction, that end spawn protection. Default 2; 0 turns
## the distance check off. Independent of [member spawn_protection_break].
@export_range(0.0, 100.0, 0.5) var spawn_protection_move_feet: float = 2.0

## Whether a protected player is drawn inside a translucent bubble (everyone else sees it; you do not see
## your own). Default on.
@export var spawn_protection_bubble: bool = true

## Friendly fire: -1 keeps each mode's own, 0 off, 1 on.
@export_range(-1, 1, 1) var friendly_fire: int = -1

@export_group("Awards")
## Points a kill is worth before its medals.
@export_range(0, 1000, 1) var award_kill_points: int = 100

## Kills by one player this close together (seconds) chain into a double, a triple, a multi kill.
@export_range(0.5, 30.0, 0.5) var award_multi_window_sec: float = 4.0

## Ending a streak at least this long is a shutdown.
@export_range(2, 50, 1) var award_shutdown_at: int = 5

## Kills closer than this (metres) are point blank.
@export_range(0.5, 50.0, 0.5) var award_point_blank_m: float = 3.0

## Kills from at least this far (metres) are long shots.
@export_range(5.0, 500.0, 1.0) var award_long_shot_m: float = 30.0

## Kills of one victim without being killed back that make you their nemesis.
@export_range(2, 20, 1) var award_nemesis_at: int = 3

@export_group("Bots")
## Players a server fills to with bots when nothing else sets bot_quota.
@export_range(0, 1, 1, "or_greater") var bot_quota: int = 4

@export_group("Surf")
## Whether surfing plays a quiet glide.
@export var surf_sounds: bool = true

## Surf glide level: 0 off, 1 stock level.
@export_range(0.0, 2.0, 0.05) var surf_volume: float = 0.6

## Speed in m/s under which the surf glide is silent.
@export_range(0.0, 60.0, 0.5) var surf_quiet_speed: float = 4.0

## Speed in m/s at which the surf glide is loudest and highest.
@export_range(1.0, 200.0, 0.5) var surf_full_speed: float = 22.0

## Surf glide pitch at the quiet speed.
@export_range(0.25, 2.0, 0.01) var surf_pitch_low: float = 0.75

## Surf glide pitch at the full speed.
@export_range(0.25, 3.0, 0.01) var surf_pitch_high: float = 1.35

## Whether footsteps and landings stop while surfing.
@export var surf_mute_steps: bool = true


@export_group("Simulation")
## Ticks a second for solo and a listen host (project.godot's physics rate is the same default); a dedicated server runs the host's sv_tickrate instead. Above 66 costs CPU in proportion; not yet measured with 32 bots.
@export_range(20, 128, 1) var tick_rate: int = FcContent.TICK_RATE

## Solo on its own server process (FcSimHost): the tick rate by player count (bots and you) in dot-server's `sv_tickrate_tiers` grammar (DotTickTiers), read once as the solo server starts; it overrides [member tick_rate]. A tick dearer than its length cannot keep real time, and then the whole game, gravity included, runs slower than the clock: on PH 64 players cost about 32 ms a tick and held 20-30 ticks a second of 66. Empty keeps [member tick_rate] at every count.
@export var solo_tick_tiers: String = "players<=32:66,<=64:33,else:22"

## Solo on its own server process: seconds between repeats of the in-game "server behind" line while the server stays under its tick rate. It is said as the server falls behind and again after it caught up; 0 says it on every 5 s report that is behind.
@export_range(0.0, 3600.0, 1.0, "or_greater") var behind_notice_sec: float = 60.0

## The surf fields as [method DotAudioSurfRules.apply_values] takes them.
func surf_values() -> Dictionary:
	return {
		"sounds": surf_sounds, "volume": surf_volume, "quiet_speed": surf_quiet_speed,
		"full_speed": surf_full_speed, "pitch_low": surf_pitch_low, "pitch_high": surf_pitch_high,
		"mute_steps": surf_mute_steps,
	}
