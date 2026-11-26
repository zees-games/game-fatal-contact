extends "fc_nameplate_cvars.gd"

const FcPlayer := preload("fc_player.gd")
const FcNetAoi := preload("fc_net_aoi.gd")
const FcPlayerNet := preload("fc_player_net.gd")
const FcBots := preload("fc_bots.gd")
const FcBotLoadouts := preload("fc_bot_loadouts.gd")
const FcBotBrain := preload("fc_bot_brain.gd")
const FcBotThreads := preload("fc_bot_threads.gd")
const FcPlayerStack := preload("fc_player_stack.gd")
const FcHullGrid := preload("fc_hull_grid.gd")
const FcBotPvs := preload("fc_bot_pvs.gd")
const FcBotRows := preload("fc_bot_rows.gd")
const FcTickBudget := preload("fc_tick_budget.gd")
const FcFlagCarry := preload("fc_flag_carry.gd")
const FcAvatarLibrary := preload("fc_avatar_library.gd")

## Base of [FcModule]: the operator-facing cvars that map onto a rule table, so the module itself
## holds the lifecycle. Split out for the size gate; the state they read lives here too.
## The netcode. Owned here rather than by the game, because a headless match and a
## dedicated server are different deployments of the same game and only one replicates.
var net: GSNetManager = null
var _cv_maxrate: GSConVar = null
var _cv_snapshot_rate: GSConVar = null
## The most snapshot workers [method default_snapshot_workers] picks: 4 was the measured win (fc-snapshot-workers-1).
const SNAPSHOT_WORKERS_MAX := 4
## Relevance rings for a big room (sv_net_aoi_players and friends); see fc_net_aoi.gd.
var net_aoi: FcNetAoi = null
## The team menu server and its team layout cvars (fc_team_menu.gd).
var team_menu: RefCounted = null


## cvar -> the movement tunable it sets, with what it means. Each defaults to what `FcPlayer.fc_tunables()`
## already says, so a server that sets none of them plays exactly as before; a change reaches every player now
## and later and, through RULES, every client, so a client never predicts a slide the server does not make.
const _OTHER_MOVEMENT_CVARS := {
	"fc_speed_scale": ["speed_scale", "Multiplier on every ground speed, 1 as set (a server-wide slowdown or speed-up)"],
	"fc_run_speed": ["max_speed", "Running speed, m/s"],
	"fc_walk_scale": ["walk_speed_scale", "Walk speed as a fraction of run"],
	"fc_sprint_scale": ["sprint_speed_scale", "Sprint speed as a fraction of run"],
	"fc_crouch_scale": ["crouch_speed_scale", "Crouch speed as a fraction of run"],
	"sv_ads_speed_mult": ["aim_speed_scale", "Ground speed while aiming down the sights, as a fraction (1 for no slowdown)"],
	"fc_launch": ["launch_enabled", "E throws the player into the air (1) or does nothing (0, the default)"],
	"fc_launch_velocity": ["launch_velocity", "Upward speed of a launch, m/s"],
	"fc_launch_forward": ["launch_forward", "Forward speed a launch adds, m/s"],
	"fc_launch_cooldown": ["launch_cooldown", "Seconds between launches"],
	"fc_dash": ["dash_enabled", "Shift dashes along the way you steer (1) or does nothing (0, the default)"],
	"fc_dash_speed": ["dash_speed", "Speed of a dash, m/s"],
	"fc_dash_lift": ["dash_lift", "Upward speed a dash adds, m/s"],
	"fc_dash_cooldown": ["dash_cooldown", "Seconds between dashes"],
	"fc_wall_run": ["wall_run_enabled", "A fast jump along a wall runs on it (1) or falls past it (0)"],
	"fc_wall_run_min_speed": ["wall_run_min_speed", "Speed along a wall needed to run on it, m/s"],
	"fc_wall_run_time": ["wall_run_max_time", "Longest a wall run lasts, seconds (at most 1.9)"],
	"fc_wall_run_gravity": ["wall_run_gravity_scale", "Share of gravity felt while wall running, 0 to 1"],
	"fc_wall_jump": ["wall_jump_enabled", "Jump in the air beside a wall jumps off it (1) or does nothing (0)"],
	"fc_wall_jump_push": ["wall_jump_push_speed", "Speed a wall jump pushes away from the wall, m/s"],
	"fc_wall_jump_up": ["wall_jump_up_speed", "Upward speed a wall jump sets, m/s"],
	"fc_wall_jumps": ["wall_jump_max_per_air", "Wall jumps before landing again, off any walls (0 for no limit)"],
	"fc_wall_slide": ["wall_slide_speed", "Fastest fall while pressed against a wall, m/s (0 for no wall slide)"],
	"fc_wall_run_end_speed": ["wall_run_end_speed", "A run ends when the speed along the wall falls under this, m/s"],
	"fc_wall_run_damping": ["wall_run_vertical_damping", "How fast a run eases the vertical speed away, per second (higher holds you up harder)"],
	"fc_wall_run_max_fall": ["wall_run_max_fall_speed", "Fastest fall a run can still catch, m/s"],
	"fc_wall_run_angle": ["wall_run_max_approach_angle", "Widest angle off the wall's plane a run can start at, degrees (running head-on is no run)"],
	"fc_wall_jump_look": ["wall_jump_look_blend", "How far a wall jump leans from the wall's normal toward the view, 0 to 1"],
	"fc_wall_jumps_per_wall": ["wall_jump_max_per_wall", "Wall jumps off the same wall before landing again"],
	"fc_wall_run_body_roll": ["wall_run_body_roll", "Degrees a drawn body rolls (feet to the wall) while wall running"],
	"fc_wall_run_body_yaw": ["wall_run_body_yaw", "Degrees a drawn body turns toward the wall while wall running"],
	"fc_wall_run_auto": ["wall_run_auto", "Touching a wall in the air starts a run with no press, and a press wall-jumps (1) or the press starts it (0, with fc_wall_run_on_jump)"],
	"fc_wall_run_on_jump": ["wall_run_on_jump", "A jump press beside a wall starts a run and turns the heading along it (1) or only jumps off (0)"],
	"fc_wall_run_turn_view": ["wall_run_turn_view", "The view turns along the wall when a jump starts a run (1) or only the heading does (0)"],
	"fc_wall_run_jump_speed": ["wall_run_jump_min_speed", "Horizontal speed a jump-started wall run needs, m/s"],
	"fc_wall_run_jump_angle": ["wall_run_jump_max_angle", "Widest angle off the wall's plane a jump-started run accepts, degrees"],
	"fc_wall_run_cooldown": ["wall_run_cooldown", "Seconds after a wall run ends before another may start"],
	"fc_wall_run_min_height": ["wall_run_min_height", "Height a wall face must have around the contact for a run to start, m (0 for any face)"],
	"fc_wall_run_min_length": ["wall_run_min_length", "Length a wall must continue ahead for a run to start, m (0 for any face)"],
	"fc_wall_angle": ["wall_max_angle_from_vertical", "Steepest lean from vertical a wall may have and still be run on, degrees"],
	"fc_break": ["break_mode", "On a death the body: 0 stays whole, 1 loses limbs, 2 explodes"],
	"fc_break_limbs": ["break_limbs", "How many limbs come off when fc_break is 1"],
	"fc_break_criticals": ["break_criticals_only", "Only a critical (a headshot) breaks a body (1), or any kill (0)"],
	"fc_fp_body": ["fp_body", "Players see their own body when they look down (1)"],
	"fc_fp_arms": ["fp_arms", "First-person arms everybody sees, own and the killer's in a kill view: 0 each player's own look, N one stock arm set"],
	"fc_team_avatars": ["team_avatars", "Team modes draw every player on a side as the side's body (fc_team_bodies), tinted its colour (1), or each player's own look (0)"],
	"fc_team_tint": ["team_tint", "How far a team body's clothes turn toward the side's colour, 0 (its own texture) to 1"],
	"fc_surf": ["surf", "A combat surf map plays with the genre's air control (1) or Fatal Contact's own (0)"],
	"fc_surf_airaccelerate": ["surf_air_accelerate", "Air acceleration on a combat surf map (the genre's sv_airaccelerate)"],
	"mp_killcam_time": ["killcam", "Seconds the final killcam plays at a match's end, added to the end's wait (0 for none)"],
	"fc_crit_scale": ["", "Extra damage multiplier on a critical hit (1 for none)"],
	"fc_crit_chance": ["", "Chance any hit is a critical, 0 to 1 (headshots always are)"],
}

## [constant _OTHER_MOVEMENT_CVARS] plus the slide's, whose names and words gs-player-controller writes once.
static var MOVEMENT_CVARS: Dictionary = _OTHER_MOVEMENT_CVARS.merged(GSFpsSlidePreset.cvar_table("fc_slide"))


func _add_movement_cvars() -> void:
	var defaults := FcPlayer.fc_tunables()

	for cvar in MOVEMENT_CVARS:
		var key: String = MOVEMENT_CVARS[cvar][0]

		# The two critical cvars set gs-combat's rules on the server, not a rule a client
		# draws: a critical is judged where the damage is.
		if key == "":
			_add_critical_cvar(cvar, MOVEMENT_CVARS[cvar][1])
			continue

		var value: Variant = (
			defaults.get(key) if not FcGame.SHOW_DEFAULTS.has(key)
			else FcGame.SHOW_DEFAULTS[key]
		)
		if value == null:
			value = FcPlayer.BODY_RULES.get(key)
		var text := ("1" if value else "0") if value is bool else str(value)

		add_cvar(
			cvar, text, MOVEMENT_CVARS[cvar][1],
			GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				game.set_movement_rules({key: new_value.to_float()})
				log_info("movement rule changed", {"rule": key, "value": new_value})
		)
	_add_hit_group_cvars()


## fc_head_mult, _neck_mult, _stomach_mult and _leg_mult: gs-combat's `GSHitGroup.bind_cvars` on the resolver's table (defaults are gs-combat's).
func _add_hit_group_cvars() -> void:
	var groups: GSHitGroup = game.combat.resolver.hit_groups if game.combat != null and game.combat.resolver != null else null
	if groups == null:
		return
	groups.bind_cvars(add_cvar, "fc", GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY)


## cvar -> the key in `FcGame.jail_rules` it sets, and what it means.
const JAIL_CVARS := {
	"fc_jail": ["enabled", "A fall on a map with a jail lands in it, and its gate works (1), or the map's volumes run as shipped (0)"],
	"fc_jail_open": ["open", "Seconds the jail's gate stays open after its button is pressed"],
	"fc_jail_cooldown": ["cooldown", "Seconds the gate then stays shut before the button works again"],
}


## cvar -> the key in `FcGame.drop_rules` it sets, and what it means.
const DROP_CVARS := {
	"fc_drop_points": ["points", "Points a critical kill drops (0 for none)"],
	"fc_drop_point_value": ["point_value", "What one point adds to its taker's count"],
	"fc_drop_health": ["health", "Health in the pack a critical kill drops (0 for none)"],
	"fc_drop_any_kill": ["any_kill", "Every kill drops (1), or only a critical one (0)"],
	"fc_drop_life": ["life", "Seconds a drop lies there before it goes"],
	"fc_packs": ["packs", "The map's health and ammo packs are out (1) or not (0)"],
	"fc_pack_health": ["pack_health", "Health in a map's health pack"],
	"fc_pack_ammo": ["pack_ammo", "Percent of each weapon's reserve an ammo pack refills"],
	"fc_pack_respawn": ["pack_respawn", "Seconds a taken pack takes to come back"],
}


## cvar -> the key in `FcPlayerStack.spawn_settings` it sets, and what it means.
const CTF_CVARS := {
	"fc_ctf_capturelimit": ["capture_limit", "Captures that win a capture-the-flag match (0 for none)"],
	"fc_ctf_timelimit": ["time_limit_sec", "Seconds a capture-the-flag match lasts, most captures wins (0, the default, for no time limit)"],
	"fc_ctf_return": ["return_sec", "Seconds a dropped flag waits before it goes home"],
	"fc_ctf_drop": ["drop_sec", "Seconds after a drop before the dropper may take the flag again"],
	"fc_ctf_carrier_speed": ["carrier_speed", "A flag carrier's speed as a fraction of normal, at least 0.1 (no ceiling)"],
	"fc_ctf_friendly_return": ["friendly_return", "The flag's own team returns a dropped flag by touching it (1) or only the timer does (0)"],
	"fc_ctf_require_home": ["require_home", "A carrier scores only while their own flag is at home (1) or at any time (0)"],
	"fc_ctf_teams": ["team_count", "Teams in capture the flag, 2 to 8 (from the next map); 8 is structural (team menu palette, FcMode sides), out of range is refused"],
}

## cvar -> the [code]fc_flag_carry.gd[/code] setting it sets, and what it means.
const FLAG_CARRY_CVARS := {
	"fc_ctf_one_hand": ["one_hand", "A flag carrier holds only one-handed items: melee, sidearm, thrown (1, the default) or anything (0)"],
	"fc_ctf_drop_key": ["drop_key", "The drop key drops a carried flag ahead of the aim (1, the default) or the weapon as usual (0)"],
	"fc_ctf_drop_speed": ["drop_speed", "Metres a second a dropped flag leaves the hand at, on top of the carrier's speed (4 is the default)"],
	"fc_ctf_flag_physics": ["physics", "A dropped flag falls, slides and bounces upright (1, the default) or lies on the floor at once (0)"],
}

const SPAWN_CVARS := {
	"fc_spawn_mode": ["mode", "How a respawn picks its site: scatter (default: random across the whole map), avoid, weighted, furthest or random"],
	"fc_spawn_min_enemy": ["min_enemy", "In avoid mode, the nearest an enemy may be to a site, in metres"],
	"fc_spawn_sight_penalty": ["sight_penalty", "What an enemy being able to see a site costs it"],
	"fc_spawn_enemy_weight": ["enemy_weight", "What each metre from the nearest enemy is worth"],
	"fc_spawn_one_per_spawn": ["one_per_spawn", "Spawns are shared by default (0), so a map with 19 spawns holds more than 19 players; 1 is strictly one player per spawn, and once every spawn is taken the next player shares one anyway"],
}


## `fc_max_unlag_ms`: how far back a shot is judged, for a shooter's latency. See
## [member FcGame.max_unlag_ms]; 0 turns lag compensation off.
func _add_unlag_cvar() -> void:
	add_cvar("fc_max_unlag_ms", str(game.max_unlag_ms),
		"How far back lag compensation rewinds the other players for a shot, in ms (0 off)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.max_unlag_ms = new_value.to_float()
			log_info("lag compensation limit changed", {"ms": game.max_unlag_ms}))


## The hitscan rewind's knobs: `sv_shot_bracket_max_span`, `sv_shot_ease_max` and `sv_shot_rewind_log_sec` (server), `cl_shot_view_cone_deg` (client); see [member FcGame.shot_bracket_max_span].
func _add_shot_rewind_cvars() -> void:
	add_cvar("sv_shot_bracket_max_span", str(game.shot_bracket_max_span),
		"Widest snapshot pair, in ticks, a hitscan shot is rewound across as the shooter drew it; wider is refused to the ring (0 no limit)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.shot_bracket_max_span = new_value.to_int()
			log_info("shot bracket span limit changed", {"ticks": game.shot_bracket_max_span}))
	add_cvar("sv_shot_ease_max", str(game.shot_ease_max),
		"Largest resume ease, in metres, a shot may say it drew a target off its samples by; larger is refused (0 no limit)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.shot_ease_max = new_value.to_float()
			log_info("shot ease limit changed", {"m": game.shot_ease_max}))
	add_cvar("sv_shot_rewind_log_sec", str(game.shot_rewind_log_sec),
		"Seconds between log lines of how hitscan rewinds stood their targets, when a fallback grew (0 never)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.shot_rewind_log_sec = new_value.to_float()
			log_info("shot rewind log period changed", {"sec": game.shot_rewind_log_sec}))
	add_cvar("cl_shot_view_cone_deg", str(game.shot_view_cone_deg),
		"Degrees off the aim within which a shot names a target's own snapshot pair to the server (0 every target)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.shot_view_cone_deg = new_value.to_float()
			log_info("shot view cone changed", {"deg": game.shot_view_cone_deg}))


## `stats_report` (gs-game's family cvar): 1 files the players' stats with the backbone. Off by default. The old `arena_stats_report` is a loud renamed shim (fc_renamed_names.gd).
func _add_stats_report_cvar() -> void:
	var _cv := GSGameStatsReport.bind(self,
		func(on: bool) -> GSResult:
			if game.progress == null:
				return GSResult.fail(GSError.CODE_STATE, "No progress yet.")
			return game.progress.set_reporting(on))


## `fc_rank`: "weighted", "elo", or "weighted:arena.kills=1,arena.deaths=-0.5" (gs-stats' GSStatsRank.apply_cvar).
func _add_rank_cvar() -> void:
	add_cvar("fc_rank", "weighted",
		"Skill rank formula: weighted, elo, or weighted:<stat>=<weight>,...",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			if game.progress == null or not game.progress.rank.apply_cvar(new_value):
				log_info("fc_rank refused", {"value": new_value}))


## `sv_fire_buffer`: seconds a semi-auto press during the cooldown stays queued. See [member FcGame.fire_buffer_seconds].
func _add_fire_buffer_cvar() -> void:
	add_cvar("sv_fire_buffer", str(game.fire_buffer_seconds),
		"Seconds a semi-auto press during the cooldown stays queued; 0 drops it, -1 keeps it until the cooldown ends",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.fire_buffer_seconds = new_value.to_float()
			log_info("fire buffer changed", {"seconds": game.fire_buffer_seconds}))


## `sv_avatar_app_id`: this game's app id on Gamespice, sent on every avatar library call (0 = not set, calls refused).
## `sv_avatar_loadout_max_entries` / `sv_avatar_loadout_max_per_kind`: how many entries one loadout message carries and
## how many equipped actions of a kind the server accepts; 0 = unlimited, over it is refused, never trimmed.
func _add_avatar_library_cvars() -> void:
	add_cvar("sv_avatar_app_id", str(FcAvatarLibrary.app_id),
		"Fatal Contact's app id on Gamespice, sent on every avatar library call (0 = not set)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcAvatarLibrary.app_id = int(new_value.to_float()))
	add_cvar("sv_avatar_loadout_max_entries", "0",
		"Most entries one avatar loadout message carries (0 = unlimited); over it the loadout is refused, never trimmed",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			var _r := FcAvatarLibrary.apply_loadout_limits(int(new_value.to_float()), GSGameAvatarLoadouts.max_per_kind))
	add_cvar("sv_avatar_loadout_max_per_kind", "0",
		"Most equipped emotes, poses or gestures of one kind the server accepts (0 = unlimited); over it the read is refused",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			var _r := FcAvatarLibrary.apply_loadout_limits(GSGameAvatarLoadoutMessage.max_entries, int(new_value.to_float())))


## `bot_think_every`, `bot_think_near`: bot think-rate staggering (see [member FcBots.think_every]); `bot_native`: gs-sim's sight scan; `bot_native_brain`: gs-bot's native mind (on); `bot_native_think`: the contact table handed to the native sight scan (on); `motor_native`: gs-sim's movement collision queries and collide-and-slide; `motor_native_tick`: a plain ground or air tick's start and end in gs-sim; `motor_native_full`: the whole tick there; `ragdoll_native`: gs-sim's ragdoll bone pose.
func _add_bot_think_cvars() -> void:
	add_cvar("bot_think_every", str(FcBots.think_every),
		"A bot far from every enemy runs its brain one tick in this many (1 = every tick, 0 = 2 above 16 players)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.think_every = maxi(0, int(new_value.to_float())))
	add_cvar("bot_brains_per_tick", str(FcBots.brains_per_tick),
		"Bot brains built on one tick at most (a full server's bots join together); a bot past it stands still a tick or two. 0 = no limit",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.brains_per_tick = maxi(0, int(new_value.to_float())))
	add_cvar("bot_personas", FcBots.personas_mode,
		"Bot characters (cfg/game/game-fatal-contact/bot/*.yml): empty deals every persona by its weight, 'id:weight,...' only those, 'off' one shared bot_difficulty",
		GSConVar.FLAG_ARCHIVE).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.personas_mode = new_value.strip_edges())
	add_cvar("sv_bot_loadouts", FcBotLoadouts.mode,
		"Kits bots draw at each spawn (cfg/game/game-fatal-contact/bot_loadout/*.yml): 'all' every enabled one by its weight, 'id[:weight],...' only those",
		GSConVar.FLAG_ARCHIVE).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotLoadouts.mode = new_value.strip_edges())
	add_cvar("sv_bot_regive", "1" if FcBotLoadouts.regive else "0",
		"1: a bot's spawn re-give reuses its last life's weapon behaviours (same state as a fresh give, less work); 0: builds every one",
		GSConVar.FLAG_ARCHIVE).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotLoadouts.regive = new_value.strip_edges() not in ["0", "false", "off", ""])
	add_cvar("bot_think_near", str(FcBots.think_near),
		"Metres: a bot with an enemy closer than this thinks every tick",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.think_near = maxf(0.0, new_value.to_float()))
	add_cvar("bot_sight_far", str(FcBots.sight_far),
		"Metres: a body farther than this that a bot did not see is not traced again for bot_sight_far_reuse seconds (never its target; 0: off)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.sight_far = maxf(0.0, new_value.to_float()))
	add_cvar("bot_sight_far_reuse", str(FcBots.sight_far_reuse),
		"Seconds a far, unseen body stays unseen before a bot traces it again (see bot_sight_far)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.sight_far_reuse = new_value.to_float())
	_add_bot_tier_cvar("bot_tier_above", "tiers.above", "Players above which bot think-rate tiers apply (-1: never); see bot_tier_*", -1.0)
	_add_bot_tier_cvar("bot_tier_every_near", "tiers.near_every", "Ticks between thinks of a bot no person fights, sees or is near, within bot_tier_range of one", 1.0)
	_add_bot_tier_cvar("bot_tier_every_far", "tiers.far_every", "Ticks between thinks of such a bot beyond bot_tier_range of every person", 1.0)
	_add_bot_tier_cvar("bot_tier_range", "tiers.far_range", "Metres: the near/far line of bot_tier_every_near and bot_tier_every_far", 0.0)
	_add_bot_tier_cvar("bot_tier_close", "tiers.close_range", "Metres: a bot this close to a person thinks every tick whatever the person faces", 0.0)
	_add_bot_tier_cvar("bot_tier_nearest", "tiers.nearest", "This many bots nearest each person think every tick", 0.0)
	_add_bot_tier_cvar("bot_tier_every_engaged", "tiers.engaged_far_every", "Ticks between thinks of a bot fighting a person beyond bot_tier_engaged_range and out of view (1: every tick)", 1.0)
	_add_bot_tier_cvar("bot_tier_every_idle_seen", "tiers.idle_view_every", "Ticks between thinks of a bot with no target (or dead) inside a person's view cone but not close or nearest (1: every tick)", 1.0)
	_add_bot_tier_cvar("bot_tier_engaged_range", "tiers.engaged_range", "Metres: a bot fighting a person this close thinks every tick", 0.0)
	_add_bot_tier_cvar("bot_tier_view", "tiers.view_range", "Metres: a bot inside a person's view cone within this thinks every tick", 0.0)
	_add_bot_tier_cvar("bot_tier_body_every_near", "tiers.body_near_every", "Ticks between motor ticks of a coasting bot no person fights, sees or is near, within bot_tier_range (1: every tick); it moves in steps nobody sees", 1.0)
	_add_bot_tier_cvar("bot_tier_body_every_far", "tiers.body_far_every", "Ticks between motor ticks of such a bot beyond bot_tier_range of every person (1: every tick)", 1.0)
	_add_bot_tier_cvar("bot_tier_body_above", "tiers.body_above", "Players above which bot_tier_body_every_near/far apply (-1: never); the body tiers' own threshold on top of bot_tier_above", -1.0)
	add_cvar("bot_tier_floor", str(FcBots.think_floor),
		"Fewest ticks between thinks of a bot while the tiers apply, whatever its tier (1: every tick); it coasts between",
		GSConVar.FLAG_ARCHIVE).with_min(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.think_floor = maxi(1, int(new_value.to_float())))
	add_cvar("bot_tier_floor_engaged", str(FcBots.think_floor_engaged),
		"bot_tier_floor for a bot fighting a person",
		GSConVar.FLAG_ARCHIVE).with_min(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.think_floor_engaged = maxi(1, int(new_value.to_float())))
	add_cvar("bot_recoil_control", str(FcBots.recoil_control),
		"Share of the recoil bots pull their aim back against, 0..1 (a share cannot pass 1; out of range is refused); -1 (default) by difficulty: easy .3, medium .55, hard .75, nightmare .9",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(-1.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBots.recoil_control = new_value.to_float())
	_add_bot_engine_cvars()
	_add_hull_and_pvs_cvars()
	_add_tick_budget_cvars()


## The native/threaded switches of the bot and motor engines.
func _add_bot_engine_cvars() -> void:
	add_cvar("bot_fast_sense", "1" if FcBotBrain.fast_sense else "0",
		"1: bots scan candidates by squared distance and cone cosine (same result, cheaper); 0: gs-bot's stock scan",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotBrain.fast_sense = new_value.to_float() >= 0.5)
	add_cvar("bot_threads", str(FcBotThreads.threads),
		"Threads that run the bots' brains in parallel (the main thread is one); 0 thinks one bot after another on the main thread",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(64.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotThreads.threads = maxi(0, int(new_value.to_float())))
	add_cvar("bot_native", "1" if GSBotWorld.native_enabled else "0",
		"1: the bots' sight scan runs in gs-sim when its library is installed (same result, cheaper); 0: in script. Without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSBotWorld.native_enabled = new_value.to_float() >= 0.5)
	# On by default (FcPlayerStack._static_init): with a gs-sim whose mind is worker_safe, native brains
	# stay native on bot_threads workers (gs-bot API 34 par_ready), and a 64-player sim host on staging02 spends
	# ~0.25 ms/tick less on bot_brain (nightly simhost-bot-native-glue-1). An older library thinks in script there.
	add_cvar("bot_native_brain", "1",
		"1: the bots' aim, fight step and perception run in gs-sim when its library has the bot mind (the same decisions to the bit, cheaper; on bot_threads workers too with a worker-safe library); 0: in script. Takes effect for bots added after the change",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcPlayerStack.set_brain_native(new_value.to_float() >= 0.5))
	add_cvar("bot_native_think", "1",
		"1: the bots' world hands gs-sim's sight scan its contact table, filled while the contacts are built (gs-bot 37; the same answers, one walk of the contacts fewer per tick), and every bot hands out one pair of commands of its own, overwritten every tick; 0: gs-bot packs the contacts itself and every tick makes new commands",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotRows.enabled = new_value.to_float() >= 0.5
			FcBots.reuse_commands = FcBotRows.enabled)
	add_cvar("motor_native", "1" if GSFpsPhysicsBody.native_enabled else "0",
		"1: the players' movement collision queries (sweep, rest contact, overlap) run in gs-sim when its library is installed (bit-identical to the script, so web and native clients still agree; cheaper); 0: in script. Without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSFpsPhysicsBody.native_enabled = new_value.to_float() >= 0.5)
	# By name: a no-op against a gs-player-char older than the switch.
	add_cvar("ragdoll_native", "0" if (GSPlayerRagdoll as Script).get(&"native_pose") == false else "1",
		"1: a skinned ragdoll's bones follow its parts in gs-sim when its library is installed (the same bone poses as the script, to the bit; cheaper); 0: in script. Client-side looks only; without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(GSPlayerRagdoll as Script).set(&"native_pose", new_value.to_float() >= 0.5))
	# On by default (FcPlayerStack._static_init); Fatal Contact suites run it against the script's bits.
	add_cvar("motor_native_tick", "1",
		"1: a plain ground or air tick's start and end (ground check, friction, acceleration, gravity, collide-and-slide) run in gs-sim as one call each when its library has the motor tick (bit-identical to the script); 0: in script. Needs motor_native; without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSFpsMotor.native_tick = new_value.to_float() >= 0.5)
	add_cvar("motor_native_full", "1" if GSFpsMotor.native_full else "0",
		"1: with motor_native_tick, the whole tick (jumps, slides, launches, dashes, wall runs and wall jumps too) runs in gs-sim as one call when its library has it (bit-identical to the script); 0: only the start and end",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSFpsMotor.native_full = new_value.to_float() >= 0.5)


## The players' hull grid (its fast, native and batched gathers) and the bots' PVS sight pre-cull.
func _add_hull_and_pvs_cvars() -> void:
	add_cvar("fc_hull_grid", "1" if FcHullGrid.enabled else "0",
		"1: players' standing hulls are found through a grid filed once per tick (same hulls, cheaper above 12 players); 0: scan the whole roster per bot",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.enabled = new_value.to_float() >= 0.5)
	add_cvar("fc_demo_flush_gate", "1" if FcHullGrid.demo_flush_gate else "0",
		"1: the batched loop keeps idle weapon ticks waiting for one gs-sim call past the demo statistics' turn when they read nothing of that player (bots, or not recording); 0: flush before every turn",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.demo_flush_gate = new_value.to_float() >= 0.5)
	add_cvar("fc_hull_fast", "1" if FcHullGrid.fast else "0",
		"1: the hull gather tests the grid's candidates in one hoisted loop (same hulls); 0: one call per candidate",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.fast = new_value.to_float() >= 0.5)
	add_cvar("fc_hull_native", "1" if FcHullGrid.native else "0",
		"1: with fc_hull_fast, a mover that is not lag-compensated gathers its hulls in gs-sim (same hulls, no script call per player); 0: by script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.native = new_value.to_float() >= 0.5)
	add_cvar("fc_motor_batch", "1" if FcHullGrid.batch else "0",
		"1: with fc_hull_native, gs-sim ticks the players' motors in runs of one call a game tick (same states); 0: one call per player",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.batch = new_value.to_float() >= 0.5)
	add_cvar("fc_bot_pvs", "1" if FcBotPvs.enabled else "0",
		"1: a bot's sight ray is skipped where the map's PVS rules the pair out (same answers: those rays come back blocked); 0: every ray is cast",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotPvs.enabled = new_value.to_float() >= 0.5)
	add_cvar("fc_bot_pvs_native", "1" if FcBotPvs.native else "0",
		"1: with fc_bot_pvs, gs-sim asks the PVS where its library has it (bit for bit with the script), else no pre-cull; 0: the script set (slower than none)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotPvs.native = new_value.to_float() >= 0.5)
	add_cvar("fc_posture_native", "1" if FcPlayer.posture_native else "0",
		"1: an idle weapon tick's posture row and flinch check run in gs-sim where its library has GSSimPlayerPost (bit for bit with the script); 0: the script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcPlayer.posture_native = new_value.to_float() >= 0.5)
	add_cvar("fc_bot_pvs_verify", "1" if FcBotPvs.verify else "0",
		"1: every sight the PVS rules out is cast anyway and every native ask is put to the script too, disagreements counted (a check, not for play)",
		0).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotPvs.verify = new_value.to_float() >= 0.5)


## How many ticks one frame may run to catch up: solo (`fc_tick_max_steps`) and server (`sv_max_physics_steps`).
func _add_tick_budget_cvars() -> void:
	add_cvar("fc_tick_max_steps", str(FcTickBudget.max_steps),
		"Solo: the most ticks a frame may run to catch up with wall-clock time. 8 (default) keeps real time while ticks are cheap; 1 draws more frames while the simulation runs slower; 0 = no limit (the 45 ms budget alone)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcTickBudget.max_steps = maxi(int(new_value.to_float()), 0))
	var server_steps := add_cvar("sv_max_physics_steps", str(FcTickBudget.SERVER_STEPS),
		"Server: the most ticks one frame may run to catch up with wall-clock time (16, a quarter second at 66 Hz; the engine's 8 drops ticks after a stall); 0 = no limit",
		GSConVar.FLAG_ARCHIVE).with_min(0.0)
	server_steps.changed.connect(func(_old: String, new_value: String) -> void:
		FcTickBudget.apply_server_steps(int(new_value.to_float())))
	FcTickBudget.apply_server_steps(server_steps.get_int())


## `sv_grenade_*` (fc_weapons' [AwGrenadeRules]) and `sv_grenade_utility`: 0 keeps flash, smoke and incendiary out of
## the loadout menu (the default), 1 entitles everyone to them.
func _add_grenade_cvars() -> void:
	if not game.FcGrenades.supported():
		return
	# Replicated: a client flies its own copy of every grenade and has to bounce it the server's way.
	var replicated := GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
	var _made := game.grenades_rules.bind_cvars(add_cvar, replicated)
	_add_rocket_cvars(replicated)
	add_cvar("sv_grenade_utility", "1" if game.utility_grenades else "0",
		"1 lets players pick flash, smoke and incendiary grenades in the loadout menu",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.utility_grenades = new_value.to_float() != 0.0
			log_info("utility grenades changed", {"on": game.utility_grenades}))


## `sv_rocket_*` (fc-weapons' `AwRocketRules`, level 27): the single-missile launcher's tube and blast and the
## Rocketjump warhead. Replicated, so a client's launcher and warhead carry the same numbers; every change is put
## back on the shared catalogues.
func _add_rocket_cvars(flags: int) -> void:
	var rules: Object = game.rocket_rules
	if rules == null:
		return
	var _made: Array = rules.call(&"bind_cvars", add_cvar, flags)
	if not rules.is_connected(&"changed", game.apply_rocket_rules):
		rules.connect(&"changed", game.apply_rocket_rules)
	game.apply_rocket_rules()


## `sv_maxrate`: bytes a second each client may be sent, 0 for no cap (the default).
##
## [b]0, because a cap here can only ever hurt[/b] (2026-10-15, `tools/net_probe.gd`): the
## stream to one client is ~6 kB/s steady and ~16 kB/s at a join with up to 31 bots, and a
## snapshot is already bounded by `max_entities_per_snapshot` and the mtu. What a cap does
## when it bites is hold a snapshot back, which a player reads as a ping spike. It is here
## for an operator on a metered uplink, and it is gs-net's `per_client_budget`, read live.
func _add_rate_cvar() -> void:
	_cv_maxrate = add_cvar("sv_maxrate", "0",
		"Bytes a second each client may be sent; 0 is no cap (a cap that bites delays snapshots)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0)
	_cv_maxrate.changed.connect(
		func(_old: String, new_value: String) -> void:
			if net != null and net.config != null:
				net.config.per_client_budget = new_value.to_int()
			log_info("rate cap changed", {"bytes_per_sec": new_value.to_int()}))


## `fc_loadout_roll_text`: see [member FcGame.loadout_roll_text]. Off by default.
func _add_loadout_roll_text_cvar() -> void:
	add_cvar("fc_loadout_roll_text", "1" if game.loadout_roll_text else "0",
		"Print \"Random loadout: ...\" on screen when a random loadout is rolled at spawn (1), or roll silently (0, default)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.loadout_roll_text = new_value.to_float() != 0.0)


## `fc_team_spawn_split`: see [member FcGame.team_spawn_split]. Read when a map loads.
func _add_team_spawn_split_cvar() -> void:
	add_cvar("fc_team_spawn_split", "1" if game.team_spawn_split else "0",
		"A team mode on a map with no team spawns splits its spawns into two halves, one per team (1), or both teams share one pool (0); read when a map loads",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.team_spawn_split = new_value.to_float() != 0.0
			log_info("team spawn split changed", {"on": game.team_spawn_split}))


## `sv_snapshot_rate`: snapshots a second to aim at, 0 for the derived default ([constant FcGame.NET_SNAPSHOT_RATE]).
## Independent of the tick rate: the rate sent is the nearest whole-tick divisor ([method FcGame.snapshot_rate_for]),
## HELLO carries it to each client, so it applies to the map being built and to clients that join after.
func _add_snapshot_rate_cvar() -> void:
	_cv_snapshot_rate = add_cvar("sv_snapshot_rate", "0",
		"Snapshots a second to aim at; 0 is the default (32). Applies when the game is built; clients learn it at join.",
		GSConVar.FLAG_ARCHIVE).with_min(0.0)


## `sv_snapshot_workers`: [member GSNetConfig.snapshot_workers], live. The same bytes on the wire either way (gs-net builds each peer's snapshot from one frozen instant);
## net_probe, 31 bots + 31 fake peers on PH: send 4.31 -> 2.86 ms/tick with 4 (nightly fc-snapshot-workers-1). Launch `+sv_snapshot_workers N` or env ARENA_SNAPSHOT_WORKERS.
func _add_snapshot_workers_cvar() -> void:
	add_cvar("sv_snapshot_workers", str(net.config.snapshot_workers if net != null and net.config != null else 0),
		"Worker threads that build the per-peer snapshots; 0 builds them on the tick thread, -1 is the processor count less one. Same bytes either way",
		GSConVar.FLAG_ARCHIVE).with_min(-1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			if net != null and net.config != null:
				net.config.snapshot_workers = int(new_value.to_float()))


## `sv_net_lagcomp`: gs-net's own rewind history ([member GSNetConfig.enable_lag_compensation]), off by default. FC rewinds with its own ring
## (fc_game_unlag.gd, combat.rewind_fn) and nothing reads `net.history`, so recording it only cost 0.185 ms/tick at 31 bots (fc-srv-netlagcomp-off-1).
func _add_net_lagcomp_cvar() -> void:
	add_cvar("sv_net_lagcomp", "1" if net != null and net.config != null and net.config.enable_lag_compensation else "0",
		"Record gs-net's rewind history every snapshot (1) or not (0, default); FC's shots rewind with their own ring either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			if net != null and net.config != null:
				net.config.enable_lag_compensation = new_value.to_float() != 0.0
				if not net.config.enable_lag_compensation and net.history != null:
					net.history.clear())


## The snapshot workers a server starts with: env ARENA_SNAPSHOT_WORKERS when set, else a quarter of the machine's threads, at most
## [constant SNAPSHOT_WORKERS_MAX], and 0 (inline) under 8 threads, where the bots' threads and the tick already want the cores.
static func default_snapshot_workers() -> int:
	var env := OS.get_environment("ARENA_SNAPSHOT_WORKERS")
	if env.is_valid_int():
		if env.to_int() >= -1:
			return env.to_int()
		push_error("ARENA_SNAPSHOT_WORKERS=%s is below -1; using the default" % env)
	elif not env.is_empty():
		push_error("ARENA_SNAPSHOT_WORKERS=%s is not a whole number; using the default" % env)
	var n := mini(floori(OS.get_processor_count() / 4.0), SNAPSHOT_WORKERS_MAX)
	return n if n >= 2 else 0


## Fatal Contact's own limits on `sv_tickrate` (gs-server's range is wider; [constant FcGame.MIN_TICK_RATE] to
## [constant FcGame.MAX_TICK_RATE]), and `bot_think_hz`: the bots' think rate in Hertz, so 33 means a think every 2nd
## tick at 66 and every 4th at 128 (`bot_think_every` counts ticks; the last one set wins; 0 leaves it to `bot_think_every`).
func _add_tick_rate_cvars() -> void:
	var tickrate := console.find_cvar("sv_tickrate")
	if tickrate != null:
		var _ranged := tickrate.with_range(float(FcGame.MIN_TICK_RATE), float(FcGame.MAX_TICK_RATE))  # structural: the rates the sim and netcode are tuned and tested for; refused outside, never clamped
	add_cvar("bot_think_hz", "0",
		"Bot brain runs this many times a second whatever the tick rate (a far bot's cadence for bot_think_every); 0 uses bot_think_every ticks",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			var hz := new_value.to_float()
			if hz > 0.0:
				FcBots.think_every = FcBots.every_for_hz(hz, game.tick_rate))


## The target `sv_snapshot_rate` names, or the game's default when it is 0 or unset.
func snapshot_target() -> int:
	var asked := _cv_snapshot_rate.get_int() if _cv_snapshot_rate != null else 0
	return asked if asked > 0 else FcGame.NET_SNAPSHOT_RATE


func _add_spawn_cvars() -> void:
	var stack: Object = game.get("player_stack")

	if stack == null:
		return

	for cvar in SPAWN_CVARS:
		var key: String = SPAWN_CVARS[cvar][0]
		add_cvar(cvar, ("1" if stack.spawn_settings[key] else "0") if key == "one_per_spawn" else str(stack.spawn_settings[key]), SPAWN_CVARS[cvar][1], GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).changed.connect(
			func(_old: String, new_value: String) -> void:
				if key == "one_per_spawn":
					var asked := new_value.strip_edges().to_lower()

					if not ["0", "1", "true", "false"].has(asked):
						GSLog.error("fc_module_cvars", "fc_spawn_one_per_spawn takes 0, 1, true or false, kept the old value", {"asked": new_value})
						return

					stack.spawn_settings[key] = asked == "1" or asked == "true"
				elif key == "mode":
					if not stack.SPAWN_MODES.has(new_value):
						log_info("unknown spawn mode, kept the old one", {"asked": new_value, "modes": stack.SPAWN_MODES})
						return

					stack.spawn_settings[key] = new_value
				else:
					stack.spawn_settings[key] = maxf(new_value.to_float(), 0.0)

				stack.refresh_spawn_rules()
				log_info("spawn rule changed", {"rule": key, "value": new_value}))


## How the flags are shown, not how they are played: kept out of [constant CTF_CVARS], whose every key names a [GSObjectiveCtfRules] rule. Sent to clients with the flag state.
const CTF_VIEW_CVARS := {
	"fc_ctf_indicator": ["indicator", "A small team-coloured flag icon with its distance (\"19.4m\") over each flag (1, default) or none (0)"],
	"fc_ctf_indicator_seethrough": ["see_through", "The flag indicator shows through walls (1, default) or only in plain sight (0)"],
}


func _add_ctf_cvars() -> void:
	for cvar in CTF_VIEW_CVARS:
		var view_key: String = CTF_VIEW_CVARS[cvar][0]
		add_cvar(
			cvar, "1" if game.ctf_view[view_key] else "0", CTF_VIEW_CVARS[cvar][1], GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				game.ctf_view[view_key] = new_value.to_float() != 0.0
				log_info("ctf view changed", {"rule": view_key, "value": new_value})
		)
	for cvar in CTF_CVARS:
		var key: String = CTF_CVARS[cvar][0]
		var value: Variant = game.ctf_rules[key]
		var text := ("1" if value else "0") if value is bool else str(value)
		var ctf_cvar := add_cvar(
			cvar, text, CTF_CVARS[cvar][1], GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
		).with_min(0.0)
		if key == "team_count":
			# Structural: FcMode builds at most 8 sides (the team menu palette). Out of range is refused, not clamped.
			var _teams := ctf_cvar.with_range(2.0, 8.0)
		elif key == "carrier_speed":
			# A carrier that cannot move is a stuck match; no ceiling, a faster carrier is the server's call.
			var _speed := ctf_cvar.with_min(0.1)
		ctf_cvar.changed.connect(
			func(_old: String, new_value: String) -> void:
				var was: Variant = game.ctf_rules[key]
				game.ctf_rules[key] = (
					new_value.to_float() != 0.0 if was is bool
					else (new_value.to_int() if was is int else new_value.to_float())
				)
				game.apply_match_limits()
				log_info("ctf rule changed", {"rule": key, "value": new_value})
		)


func _add_flag_carry_cvars() -> void:
	for cvar in FLAG_CARRY_CVARS:
		var key: String = FLAG_CARRY_CVARS[cvar][0]
		var value: Variant = FcFlagCarry.setting(key)
		var text := ("1" if value else "0") if value is bool else str(value)
		add_cvar(
			cvar, text, FLAG_CARRY_CVARS[cvar][1], GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				FcFlagCarry.set_setting(key, new_value)
				log_info("flag carry rule changed", {"rule": key, "value": new_value})
		)


## The knife rules as cvars (`fc_knife_throw`, `_speed`, `_pickup`, `_damage`): gs-weapon's table.
func _add_knife_cvars() -> void:
	var _made := GSWeaponKnives.bind_cvars(
		game.knife_rules, add_cvar, "fc_knife",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
	)


func _add_drop_cvars() -> void:
	for cvar in DROP_CVARS:
		var key: String = DROP_CVARS[cvar][0]
		var value: Variant = game.drop_rules[key]
		var text := ("1" if value else "0") if value is bool else str(value)
		add_cvar(
			cvar, text, DROP_CVARS[cvar][1], GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				var was: Variant = game.drop_rules[key]
				game.drop_rules[key] = (
					new_value.to_float() != 0.0 if was is bool
					else (new_value.to_int() if was is int else new_value.to_float())
				)
				game.apply_drop_rules()
				log_info("drop rule changed", {"rule": key, "value": new_value})
		)


func _add_jail_cvars() -> void:
	for cvar in JAIL_CVARS:
		var key: String = JAIL_CVARS[cvar][0]
		var value: Variant = game.jail_rules[key]
		add_cvar(
			cvar, ("1" if value else "0") if value is bool else str(value),
			JAIL_CVARS[cvar][1], GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
		).with_min(0.0).changed.connect(
			func(_old: String, new_value: String) -> void:
				game.jail_rules[key] = (
					new_value.to_float() != 0.0 if game.jail_rules[key] is bool else new_value.to_float()
				)
				game.apply_jail_rules()
				log_info("jail rule changed", {"rule": key, "value": new_value})
		)


func _add_critical_cvar(cvar: String, help: String) -> void:
	var rules: GSDamageRules = game.combat.resolver.rules if game.combat != null else null
	if rules == null:
		return

	var scale := cvar == "fc_crit_scale"
	add_cvar(
		cvar, str(rules.critical_scale if scale else rules.critical_chance), help,
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			if scale:
				rules.critical_scale = maxf(new_value.to_float(), 0.0)
			else:
				rules.critical_chance = clampf(new_value.to_float(), 0.0, 1.0)
			log_info("critical rule changed", {"cvar": cvar, "value": new_value})
	)


## `sv_net_*`: relevance rings, on only above `sv_net_aoi_players` players (default 32, so a 16v16 is untouched).
func _add_aoi_cvars() -> void:
	net_aoi = FcNetAoi.new()
	net_aoi.bind_cvars(add_cvar, GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY)
	add_cvar("sv_net_hold_subquantum", "1" if FcPlayerNet.hold_subquantum else "0",
		"1 skips re-sending a player's view or velocity when the change is smaller than one wire step (receivers decode the same values either way)",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcPlayerNet.hold_subquantum = new_value.to_float() != 0.0
			log_info("sub-quantum hold changed", {"on": FcPlayerNet.hold_subquantum}))


## Once a second from the module: turns the rings on or off for the current player count.
func _refresh_aoi() -> void:
	if net_aoi != null and net != null and game != null and net.interest != null:
		if net_aoi.refresh(net.interest, game.players().size()):
			log_info("net relevance rings", {"on": net_aoi.active, "players": game.players().size()})


## A `bot_tier_*` cvar onto a field of [member FcBots.tiers] ([param field] is `tiers.<name>`).
func _add_bot_tier_cvar(cvar: String, field: String, help: String, min_value: float) -> void:
	var tiers := FcBots.tiers
	var name := StringName(field.trim_prefix("tiers."))
	add_cvar(cvar, str(tiers.get(name)), help, GSConVar.FLAG_ARCHIVE).with_min(min_value).changed.connect(
		func(_old: String, new_value: String) -> void:
			tiers.set(name, int(new_value.to_float()) if typeof(tiers.get(name)) == TYPE_INT else new_value.to_float()))


## The counts in [member FcGame.shot_rewind_counts] that mean a shot was not stood where its shooter drew the target.
const SHOT_FALLBACKS: Array[StringName] = [&"ring", &"held", &"refused_span", &"refused_view", &"unrecorded", &"target_held", &"refused_ease"]
var _shot_log_since := 0.0
var _shot_logged: Dictionary = {}

## Logs every hitscan rewind count once `sv_shot_rewind_log_sec` has passed and a fallback in [constant SHOT_FALLBACKS] grew since the last line.
func _log_shot_rewinds(delta: float) -> void:
	if game == null or game.shot_rewind_log_sec <= 0.0:
		return
	_shot_log_since += delta
	if _shot_log_since < game.shot_rewind_log_sec:
		return
	_shot_log_since = 0.0
	for key: StringName in SHOT_FALLBACKS:
		if int(game.shot_rewind_counts.get(key, 0)) > int(_shot_logged.get(key, 0)):
			_shot_logged = game.shot_rewind_counts.duplicate()
			log_warn("hitscan rewinds fell back", _shot_logged)
			return
