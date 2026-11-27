@tool
extends "fc_game_setup.gd"

## Work heard between ticks that touches the physics space (a respawn, a restart, a map change),
## held for the next server tick; armed only by [code]FcModule[/code]. See gs_tick_gate.gd.
var tick_gate := GSTickGate.new()

## The standing hulls player [param id] stops at: every other living player's, where they stand now; none
## while `mp_solidplayers` is 0. Asked per sweep by the movement body, so a player moved earlier in this tick
## is met where it moved to (the same on every machine: players tick in one order).
func solid_hulls_for(id: int, tick: int = -1) -> Array:
	var t_h := Time.get_ticks_usec()
	var got := _solid_hulls_for(id, tick)
	FcFrameProbe.add(&"p_hulls", t_h)
	return got


func _solid_hulls_for(id: int, tick: int = -1) -> Array:
	var out: Array = []
	if not body_rules.solid:
		return out
	var me: FcPlayer = _players.get(id)
	var me_at := me.controller.state.position if me != null and me.controller != null and me.controller.state != null else Vector3.INF
	_ensure_roster()
	var remote: bool = remote_feet_fn.is_valid() and tick >= 0 and (not FcHullGrid.enabled or not remote_lags_fn.is_valid() or remote_lags_fn.call(id))
	var near := me_at != Vector3.INF
	# Position first: most of a crowd is out of reach, and the pair and alive tests cost more than the read.
	var coarse := HULL_NEAR_SQ if remote else HULL_REACH_SQ
	if near and _hull_grid.live:
		var cand: Array = _hull_grid.near(me_at, coarse)
		if FcHullGrid.fast and not remote:
			_add_hulls_local(out, cand, id, me_at, coarse, tick)
		else:
			for i: int in cand:
				_add_hull(out, i, id, me_at, near, coarse, remote, tick)
		if FcHullGrid.verify:
			var full: Array = []
			for i in range(_roster.size()):
				_add_hull(full, i, id, me_at, near, coarse, remote, tick)
			FcHullGrid.verified += 1
			if str(full) != str(out):
				FcHullGrid.mismatches += 1
			if not remote and _hull_world != null and _hull_world.is_live():
				FcHullGrid.native_verified += 1
				if _hull_world.gather(_roster_at.get(id, -1), me_at.x, me_at.y, me_at.z) != out:
					FcHullGrid.native_mismatches += 1
		return out
	for i in range(_roster.size()):
		_add_hull(out, i, id, me_at, near, coarse, remote, tick)
	return out


## [method _add_hull] over [param cand] for a mover whose neighbours are where they stand now (no lag compensation): the same tests, with the loop invariants (ids, roster, the pair callable) hoisted out of the per-candidate call. Cvar `fc_hull_fast`.
## The pair test is asked once per pair and tick ([method _pair_index]), and only of living players: about 10 us a call through gs-team's block rules, the largest part of a gather.
## One answer serves both players of a pair: gs-team's `blocks(a, b)` is symmetric (one relation, both players' overrides).
func _add_hulls_local(out: Array, cand: Array, id: int, me_at: Vector3, coarse: float, tick: int = -1) -> void:
	var ids := _roster_ids
	var roster := _roster
	var pair := body_rules.pair_fn
	var paired := pair.is_valid()
	var n := ids.size()
	var me_i := _pair_index(id, tick, pair) if paired and tick >= 0 else -1
	var row := me_i * n if me_i >= 0 else -1
	for i: int in cand:
		var other_id := ids[i]
		if other_id == id:
			continue
		var other := roster[i]
		if other == null:
			continue
		var ctl := other.controller
		if ctl == null or ctl.state == null:
			continue
		var feet := ctl.state.position
		if feet.distance_squared_to(me_at) > coarse:
			continue
		if not other.health.alive:
			continue
		if paired:
			var known: int = _pair_memo[row + i] if row >= 0 else 0
			if known == 0:
				known = 1 if bool(pair.call(id, other_id)) else 2
				if row >= 0:
					_pair_memo[row + i] = known
					_pair_memo[i * n + me_i] = known
			if known == 2:
				continue
		var tunables := ctl.tunables
		var radius: float = tunables.radius
		out.append(AABB(feet - Vector3(radius, 0.0, radius), Vector3(radius * 2.0, tunables.stand_height, radius * 2.0)))


## [param id]'s roster index, its row in [member _pair_memo], or -1 when it is not on the roster.
## The memo is cleared when the tick, the roster or the pair callable changes: block rules and
## sides change between ticks (commands, team switches), not while the players' loop runs.
func _pair_index(id: int, tick: int, pair: Callable) -> int:
	var n := _roster_ids.size()
	if tick != _pair_memo_tick or pair != _pair_memo_fn or _pair_memo.size() != n * n:
		_pair_memo.resize(n * n)
		_pair_memo.fill(0)
		_pair_memo_tick = tick
		_pair_memo_fn = pair
	var at: int = _roster_at.get(id, -1)
	return at


## Appends roster player [param i]'s hull to [param out] when it is one [param id] stops at.
func _add_hull(out: Array, i: int, id: int, me_at: Vector3, near: bool, coarse: float, remote: bool, tick: int) -> void:
	var other_id := _roster_ids[i]
	if other_id == id:
		return
	var other := _roster[i]
	if other == null:
		return
	var ctl := other.controller
	if ctl == null or ctl.state == null:
		return
	var feet := ctl.state.position
	if near and feet.distance_squared_to(me_at) > coarse:
		return
	if not body_rules.blocks(id, other_id) or not other.health.alive:
		return
	if remote:
		var at: Variant = remote_feet_fn.call(other_id, id, tick)
		if at is Vector3:
			feet = at
		if near and feet.distance_squared_to(me_at) > HULL_REACH_SQ:
			return
	var tunables := ctl.tunables
	out.append(FcSolidBody.hull_at(feet, tunables.stand_height, tunables.radius))
## Changes the game's tick rate and every player's with it. Assigning [member tick_rate] alone
## reaches only players added afterwards: a client learns the server's rate from HELLO after its
## players exist, and one left on the old rate predicts every tick a different distance.
func set_tick_rate(rate: int) -> void:
	tick_rate = maxi(rate, 1)
	for player: FcPlayer in _players.values():
		player.use_tick_rate(tick_rate)


## Adds a player, builds their body, and puts them in the match.
func add_player(
	id: int, display_name: String, wanted_team: int = 0
) -> GSResult:
	if _players.has(id):
		return GSResult.fail(GSError.CODE_STATE, "Player %d is already here." % id)

	var player := FcPlayer.new()
	player.use_tick_rate(tick_rate)
	player.before_death = FcWeaponDropWiring.drop_for_death.bind(self, player)
	player.setup(
		FcPlayer.Mode.HEADLESS if headless else FcPlayer.Mode.PHYSICS,
		map,
		id,
		display_name
	)
	# Before it enters the tree, so the controller that readies (and logs) is the map's.
	FcPlayer.configure_body(config.avatar_height_units, config.avatar_crouch_units, config.avatar_radius_units, config.avatar_unit_metres)
	player.apply_map_movement(map_movement())
	player.apply_vitals(config.player_health, config.player_armour, config.player_regen, config.fall_out_depth)
	player.volume_pre = _volume_pre
	add_child(player)

	# The layout's player mask, rather than `GSFpsTunables`' default of 1. See
	# `FcPlayer.use_collision_mask` — with props on their own layer, 1 is a player
	# who walks through crates.
	if player_stack != null:
		player.use_collision_mask(player_stack.player_collision_mask())

	if is_authority:
		player.flashlight_cfg = flashlight_conf()
		player.flashlight_map = String(map.id) if map != null else ""
	player.join_combat(combat)
	_add_fall_damage(player)
	combat_feel.attach(player.arsenal)
	player.arsenal.ammo_types = ammo_types
	combat_feel.track_tunables(player.controller.tunables)
	player.apply_movement_rules(movement_rules)
	player.arsenal.fire_buffer_seconds = fire_buffer_seconds
	player.solid_hulls_fn = solid_hulls_for
	_players[id] = player
	_roster_dirty = true
	_ids_cache = []

	var added := match_node.add_player(str(id), display_name, _tick, wanted_team)

	if not added.ok:
		remove_player(id)
		return added

	# The side gs-match actually put them on, which is not necessarily the one they
	# asked for: `GSTeamManager.assign` refuses a full team and balances an uneven one.
	# Reading it back rather than assuming is the difference between a scoreboard that
	# matches the game and one that matches the request.
	#
	# It is set on the player because that is what gs-combat's friendly-fire check and
	# the renderer's colour both read, and `FcPlayer.team` had been declared and
	# assigned by nothing since the class was written.
	player.team = team_of(id)

	if progress != null:
		# Not awaited. An achievement store may be remote and a join may not wait on
		# it; readings that arrive during the load are still counted, because
		# `GSAchievementStatsLink` holds its baseline until the tracker has the
		# player. See `FcProgress.begin`.
		progress.begin(id, display_name)

	# [b]Warmup is not a reason to stand at the origin with empty hands.[/b] gs-match spawns nobody until the countdown, so
	# a player who joined a 10 s warmup was alive at (0, 0, 0) with no weapon, then teleported ~18 m with a gun when the
	# round was set up (nightly fc-native-via-gs-app-1: the owner's native solo showed exactly that). They are put in the
	# world now, armed; the countdown places everybody again, as it always did.
	if match_node.state == GSMatch.State.WARMUP:
		var _placed := respawn_player(id)

	# Last, and only once the player is fully in: a handler runs synchronously inside
	# this and the first thing a client's does is hang a camera off them.
	player_added.emit(player)

	return GSResult.success(player)

func _mode_shown() -> FcMode:
	return displayed_mode()

func displayed_mode() -> FcMode:
	return shown_mode if shown_mode != null else mode

## How a body comes apart on death under the current rules.
func break_rules() -> GSPlayerBreakRules:
	var rules := GSPlayerBreakRules.new()
	rules.mode = clampi(int(rule("break_mode")), 0, 2) as GSPlayerBreakRules.Mode
	rules.limbs = maxi(int(rule("break_limbs")), 1)
	rules.criticals_only = rule("break_criticals_only") != 0.0
	return rules

## Puts a player back into the world now, alive, at a spawn the director chooses.
##
## An administrator's respawn, and the same path a queued respawn takes — so a player an
## admin put back gets the director's spawn choice, spawn protection, a cleared effect
## set and their loadout, exactly like one the match put back. Anything still queued for
## them is cancelled first, or the queue would respawn them a second time moments later.
func respawn_player(id: int) -> GSResult:
	var player := player_for(id)

	if player == null:
		return GSResult.fail(GSError.CODE_INVALID, "Player %d is not in the match." % id)

	var key := str(id)
	FcWeaponDropWiring.reset_drop_key(self, id)

	if match_node.respawns != null:
		match_node.respawns.cancel(key)

	_on_respawn_due(key, match_node.choose_spawn(key, _tick), _tick)
	return GSResult.success(player)

## gs-bot-record, loaded by path in [method start_ride_recording] only: a game that never records does not compile it.
const BOT_RECORD_DIR := "res://addons/gs_bot_record/"
## FC's kill view server: builds an eye only when the ring keeps it, straight into the ring.
const FcKillViewServer := preload("fc_killview_server.gd")

## The kill view's server half over this game: every living eye, respawns held in gs-match's queue.
func make_killview_server() -> GSKillViewServer:
	var server := FcKillViewServer.new(killview_rules, self)
	server.tick_rate = tick_rate
	KillPov.watch_hits(self)
	server.use_respawn_queue(func() -> Variant: return match_node.respawns if match_node != null else null,
		func(id: Variant) -> GSResult: return respawn_player(int(id)))
	return server

## Builds [member noblock] over gs-team's rules (its cfg layers; strict fails the boot) for a server or a solo game.
func make_noblock(strict := GSGameConfigBinder.default_strict()) -> GSResult:
	var made := GSGameNoblock.create("game-fatal-contact", Callable(self, "block_side"), PackedStringArray(), strict)
	if not made.ok:
		return made
	noblock = made.value
	noblock_bound = false
	noblock.feed(body_rules)
	block_rules = noblock.rules
	return made

## The side a player blocks as: its team, or "" in a free-for-all (no teammates, so it stays solid).
## gs-team asks it for both players of every pair it judges, so each side's text is built once and kept.
func block_side(id: Variant) -> Variant:
	var team := team_of(int(id)) if not teams().is_empty() else 0
	if team <= 0:
		return ""
	if team >= _side_texts.size():
		var from := _side_texts.size()
		var _sized := _side_texts.resize(team + 1)
		for t in range(from, team + 1):
			_side_texts[t] = str(t)  # perf-lint: allow string_build once a team id for the game's life
	return _side_texts[team]


## [method block_side]'s answers, indexed by team id.
var _side_texts := PackedStringArray()

## A storage key that is usable as a filename.
##
## `GSLoadoutKey.is_usable` has a minimum length, so a bare session id of "7" is
## refused before any store sees it. Padding here rather than loosening the check: the
## check exists so a malformed key can never reach a filesystem path.
##
## [b]One key for every store, and that is deliberate.[/b] Loadouts, achievement
## progress and gs-stats' sessions are three subsystems that each want a durable
## per-player id, and three formats would be three chances for one of them to file
## under a name the others cannot find. It also refuses to be an account id: gs-stats'
## reporter rejects anything with a `backbone:` prefix before it leaves the server, and
## a key built from the session id can never carry one.
static func storage_key(id: int) -> String:
	return FcLoadoutIdentity.seat_key(id)

## Where player [param id] was at [param at], blended between the recorded ticks [param older]
## and [param newer] (the snapshots the client drew between); null when either is not recorded.
func unlag_position_between(id: int, older: int, newer: int, at: float, snap := Callable()) -> Variant:
	var a: Variant = unlag_position_at(id, float(older))
	var b: Variant = unlag_position_at(id, float(newer))
	if a == null or b == null:
		return null
	if snap.is_valid():
		a = snap.call(a)
		b = snap.call(b)
	if newer <= older:
		return a
	return (a as Vector3).lerp(b, clampf((at - float(older)) / float(newer - older), 0.0, 1.0))

## Player [param id]'s crouch blended between the recorded ticks [param older] and [param newer], as
## [method unlag_position_between] blends the feet; -1 when either is not recorded.
func unlag_crouch_between(id: int, older: int, newer: int, at: float) -> float:
	var a := unlag_crouch_at(id, float(older))
	var b := unlag_crouch_at(id, float(newer))
	if a < 0.0 or b < 0.0:
		return -1.0
	if newer <= older:
		return a
	return lerpf(a, b, clampf((at - float(older)) / float(newer - older), 0.0, 1.0))

## A mover's view lag in ticks as both ends collide with it: -1 (the present) when none was sent
## or compensation is off, else at most `max_unlag_ms` and [constant COLLISION_LAG_MAX_SEC].
func collision_lag(view_lag: float) -> float:
	if view_lag < 0.0 or max_unlag_ms <= 0.0:
		return -1.0
	return minf(view_lag, minf(max_unlag_ms * 0.001, COLLISION_LAG_MAX_SEC) * float(tick_rate))

func current_tick() -> int:
	return _tick

## Records the surf rides real players take (`fc_surf_rides.gd`), off unless `bot_record` is on in the config, environment, command line or console; a no-op on a shell without gs-bot's recorder.
func start_ride_recording(add_cvar: Callable = Callable(), config_file: String = "user://bot_record.json") -> GSResult:
	if surf_rides != null:
		return GSResult.success(surf_rides)
	if GSAddonApi.build_level("gs_bot") < 5 or GSAddonApi.build_level("gs_player_controller") < 3 \
			or not ResourceLoader.exists("res://addons/gs_bot/runtime/surf/gs_bot_ride_harvest.gd"):
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "This shell has no ride recorder.")
	# gs-bot-record's classes are loaded here, by path, so a game that never records does not compile them.
	var config: RefCounted = (load(BOT_RECORD_DIR + "core/gs_bot_demo_config.gd") as GDScript).new()
	config.set(&"record", false)
	var layered: GSResult = config.call(&"load_layered", config_file if FileAccess.file_exists(config_file) else "")
	if not layered.ok:
		return layered
	if add_cvar.is_valid():
		var _cvars: Variant = config.call(&"bind_cvars", add_cvar, GSConVar.FLAG_NOTIFY)
	var made: GSResult = (load(BOT_RECORD_DIR + "store/gs_bot_demo_store.gd") as GDScript).call(&"from_config", config, null)
	if not made.ok or made.value == null:
		return made if not made.ok else GSResult.fail(GSError.CODE_STATE, "bot_record_store is off.")
	var store: RefCounted = made.value
	var opened: GSResult = store.call(&"open")
	if not opened.ok:
		return opened
	var rides: FcRideSource = (load(FcPaths.rebase("res://game/fc_surf_rides.gd")) as GDScript).new()
	var ready: GSResult = rides.call(&"setup", self, config, store, float(tick_rate))
	if not ready.ok:
		return ready
	surf_rides = rides
	var _stats := start_demo_stats(config, store)
	return GSResult.success(rides)

## Records `place` and `engage` episodes into [param store] and lets the bots roam where people stand; a no-op on a shell without gs-bot's heatmap and aim statistics.
func start_demo_stats(config: RefCounted, store: RefCounted) -> GSResult:
	if demo_stats != null:
		return GSResult.success(demo_stats)
	if not ResourceLoader.exists("res://addons/gs_bot/runtime/gs_bot_demo_heatmap.gd") or not ResourceLoader.exists("res://addons/gs_bot/runtime/gs_bot_aim_stats.gd"):
		return GSResult.fail(GSError.CODE_UNSUPPORTED, "This shell has no heatmap or aim statistics.")
	var stats: FcDemoSource = (load(FcPaths.rebase("res://game/fc_demo_stats.gd")) as GDScript).new()
	var ready: GSResult = stats.call(&"setup", self, config, store, float(tick_rate))
	if not ready.ok:
		return ready
	demo_stats = stats
	return GSResult.success(stats)

# --- Events ----------------------------------------------------------------

## Whether [param entity_id] may be hurt now. False only for a player whose client is behind
## its loading cover (frozen by its own client, unable to see); a monster, a bot or a game
## with no [member loading_fn] is always harmable, so every offline suite is unchanged.
func can_be_harmed(entity_id: int) -> bool:
	if not loading_fn.is_valid():
		return true
	return not bool(loading_fn.call(entity_id))

# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"tick": _tick,
		"map": map.describe() if map != null else {},
		"players": _players.size(),
		"match": match_node.describe() if match_node != null else {},
		"combat": combat.describe() if combat != null else {},
		"progress": progress.describe() if progress != null else {},
		"horde": horde.describe() if horde != null else {},
		"props": props.describe() if props != null else {},
	}

func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("arena    %s  tick %d" % [map.display_name if map != null else "?", _tick])
	out.append_array(match_node.describe_lines())
	out.append_array(combat.describe_lines())

	if progress != null:
		out.append_array(progress.describe_lines())

	if horde != null:
		out.append_array(horde.describe_lines())

	if props != null:
		out.append_array(props.describe_lines())

	return out
