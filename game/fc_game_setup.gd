@tool
extends "fc_game_tick.gd"

const FcKnifeFollow := preload("fc_knife_follow.gd")

## The monsters and the props the mode asks for.
func _reconcile_world_layers() -> void:
	if not is_authority and mode != null:
		# A networked client builds one layer of the world's: the spectator camera, which
		# is drawn where it is computed. Until it did, a client had no spectate layer at
		# all and a dead player's camera stayed on the body for the whole of every death.
		_build_spectate()
		_reconcile_client_objectives()
		return

	if not is_authority or mode == null:
		return

	_build_world_layers()

	# And the other direction. A mode with no objectives must not keep the last one's,
	# because a HUD reads the layer rather than the mode and would draw a hill nobody
	# can capture.
	if objectives != null and mode.objective_layout == &"":
		remove_child(objectives)
		objectives.queue_free()
		objectives = null

	if horde != null and not mode.horde:
		remove_child(horde)
		horde.queue_free()
		horde = null

	if props != null and not mode.player_props and mode.scatter_props <= 0:
		remove_child(props)
		props.queue_free()
		props = null

func _free_map_io() -> void:
	if map_io != null and is_instance_valid(map_io):
		remove_child(map_io)
		map_io.free()
	map_io = null
	map_use.attach(null)

## Puts an imported map's solid in the tree, replacing the last one; nothing on a built-in map.
func _build_world_collision() -> void:
	if _world_collision != null and is_instance_valid(_world_collision):
		remove_child(_world_collision)
		_world_collision.free()

	_world_collision = null
	_free_map_io()

	if map == null or not map.is_imported():
		return

	_world_collision = map.to_collision()
	_world_collision.name = "WorldCollision"
	add_child(_world_collision)
	map.collision_root = _world_collision
	glass_rules.glass_mask = 0
	map.glass = null
	var cell: Variant = _world_collision.get_meta(&"glass_sight") if _world_collision.has_meta(&"glass_sight") else null
	if cell is GSMapGlassSight:
		glass_rules.centre = (cell as GSMapGlassSight).centre
		glass_rules.radius = (cell as GSMapGlassSight).radius
		glass_rules.glass_mask = (cell as GSMapGlassSight).glass_mask
		glass_rules.world_mask = GSPhysicsLayout.shooter_3d().mask_of([&"world", &"player_clip"])
		map.glass = glass_rules

	# Before `_build_match` turns the spawns into spawn points: a mapper's spawn inside the
	# floor would otherwise be a player rising through it. See `FcMap.settle_spawns`.
	var lifted := map.settle_spawns(map.movement_body(), FcPlayer.fc_tunables())
	if not defer_map_io:
		map_io = FcMapIo.build(self, map_use)
		if map_io != null:
			add_child(map_io)

	if lifted > 0:
		GSLog.debug(CHANNEL, "spawns lifted out of an imported map's solid", {
			"map": String(map.id), "lifted": lifted, "of": map.spawns.size()
		})

## The solid on the layout's `world` layer, once there is a layout to ask.
func _classify_world_collision() -> void:
	if _world_collision != null and player_stack != null:
		var _n := player_stack.classify_tree(_world_collision, &"world")

## Puts [member score_limit], [member time_limit_sec], [member warmup_sec] and [member min_players] on the match being played, from the next tick (gs-match reads its rules every tick).
## The authority's to call; a client is told the score limit and the clock by MATCH. Capture the flag plays `fc_ctf_teams` sides, from the next map.
func _apply_ctf_teams() -> void:
	if mode != null and mode.objective_layout == &"ctf":
		mode.team_count = ctf_rules.team_count


func apply_match_limits() -> void:
	if match_node == null or match_node.rules == null or mode == null:
		return
	# From the mode again, so setting an export back to zero restores the mode's number
	# rather than keeping the last override.
	var from_mode: GSMatchRules = mode.rules
	match_node.rules.score_limit = from_mode.score_limit
	match_node.rules.time_limit_sec = from_mode.time_limit_sec
	match_node.rules.warmup_sec = from_mode.warmup_sec
	match_node.rules.min_players = from_mode.min_players
	match_node.rules.respawn_delay_sec = from_mode.respawn_delay_sec
	match_node.rules.spawn_protection_sec = from_mode.spawn_protection_sec
	if freeze_sec >= 0.0 or _freeze_overridden:
		match_node.rules.countdown_sec = from_mode.countdown_sec
	_freeze_overridden = freeze_sec >= 0.0
	_override_rules(match_node.rules)

## The movement overrides the current map asks for, after the server's rules.
##
## [b]Per map, and derived on both ends from the map itself[/b] — `FcMap.movement_profile`,
## which an imported map's manifest decides — so a client that loaded the map already knows,
## and only an operator's change has to travel (in RULES, as `surf` and
## `surf_air_accelerate`). Empty on Fatal Contact's own maps, which is what puts Fatal Contact's air
## control back after a surf map: `FcPlayer.apply_map_movement` resets every key it is
## not given.
func map_movement() -> Dictionary:
	if map == null or map.movement_profile != &"surf" or rule("surf") == 0.0:
		return {}

	var out: Dictionary = FcPlayer.SURF_TUNABLES.duplicate()
	out["air_accelerate"] = rule("surf_air_accelerate")
	return out

## Sets movement rules (key -> number, see [constant FcPlayer.MOVEMENT_RULES]) for
## every player now and later. On a server, the bridge forwards them to clients; on a
## client, this is where RULES lands.
func set_movement_rules(rules: Dictionary) -> void:
	for key in rules:
		if FcPlayer.MOVEMENT_RULES.has(String(key)) or SHOW_RULES.has(String(key)):
			movement_rules[String(key)] = float(rules[key])

	for player in players():
		player.apply_movement_rules(movement_rules)

		if rules.has("surf") or rules.has("surf_air_accelerate"):
			player.apply_map_movement(map_movement())

	if not is_authority and rules.has("mode_index"):
		var all := FcModes.all()
		var index := int(rules["mode_index"])
		if index >= 0 and index < all.size() and (shown_mode == null or shown_mode.id != all[index].id):
			shown_mode = all[index]
			if map != null:
				_reconcile_client_objectives()
			mode_shown.emit(shown_mode)

	if is_authority and rules.has("killcam"):
		apply_match_limits()

	if not is_authority and rules.has("fire_buffer"):
		fire_buffer_seconds = float(rules["fire_buffer"])

	if not is_authority and rules.has("max_unlag_ms"):
		max_unlag_ms = float(rules["max_unlag_ms"])

	movement_rules_changed.emit(movement_rules)

## Tells clients which mode this is, by its index in the catalogue they share. Server side.
func _announce_mode() -> void:
	if is_authority and mode != null:
		var index := FcModes.ids().find(mode.id)
		if index >= 0:
			set_movement_rules({"mode_index": index})

func _clear_toys() -> void:
	if toys != null:
		toys_clearing.emit()
		remove_child(toys)
		toys.queue_free()
		toys = null
	if _toy_level != null and is_instance_valid(_toy_level):
		remove_child(_toy_level)
		_toy_level.queue_free()
	_toy_level = null

func _on_detonated_near_toys(at: Vector3, spawn: GSWeaponSpawn) -> void:
	if toys != null and is_authority and spawn != null:
		var _thrown := toys.blast(at, maxf(spawn.splash_radius, 2.0), TOY_BLAST_SPEED)

## The map's toys from [member FcMap.toys], on both ends, in the order the map lists them:
## that order is how a client pairs each with the server's entity. A headless authority gets
## a collision copy of a built-in level for them to land on; an imported map's solid is in the
## physics space already, and a drawing end's level is its scene.
func _build_toys() -> void:
	_clear_toys()
	if map == null:
		return
	var layout: GSPhysicsLayout = player_stack.physics.layout if player_stack != null and player_stack.physics != null else null

	if is_authority and headless and not map.is_imported() and not map.toys.is_empty():
		_toy_level = map.to_collision()
		_toy_level.name = "ToyLevel"
		add_child(_toy_level)
		if player_stack != null:
			var _n := player_stack.classify_tree(_toy_level, &"world")

	toys = GSPropBodyBox.new()
	toys.name = "Toys"
	toys.authoritative = is_authority
	toys.draw = not headless
	toys.rules = toy_rules
	toys.gravity = 20.0
	toys.kill_y = map.floor_y - 40.0
	if layout != null:
		toys.loose_layer = layout.layer_mask(&"toy")
		toys.loose_mask = layout.collision_mask(&"toy")
		toys.solid_layer = layout.layer_mask(&"prop")
		toys.solid_mask = layout.collision_mask(&"prop")
		toys.footprint_layer = layout.layer_mask(&"footprint")
		toys.aim_mask = layout.mask_of([&"world", &"toy"] as Array[StringName])
	add_child(toys)
	var built := toys.build(map.toys)
	if not built.ok:
		GSLog.warn(CHANNEL, "a map's toys would not build", {"map": String(map.id), "why": built.error.message})
	var _sounds := toys.sound.connect(func(id: StringName, at: Vector3, strength: float) -> void: toy_sound.emit(id, at, strength))

	if projectiles != null and is_authority and not projectiles.detonated.is_connected(_on_detonated_near_toys):
		projectiles.detonated.connect(_on_detonated_near_toys)

	toys_built.emit()

## Builds everything. Call after adding to the tree. One go: [method setup_begin] and every
## [method setup_step]; a client that draws runs the steps a frame apart (FcClient).
##
## A step that dies on a script error hands back null, not a [GSResult] (on a server that was a
## script missing from the pack mount, 0.1.69): that is turned into a failure that names the step,
## so the log says what broke instead of "Invalid access to property 'ok' on Nil".
func setup(p_map: FcMap = null) -> GSResult:
	var step: StringName = &"begin"
	var built: Variant = setup_begin(p_map)
	while built is GSResult and (built as GSResult).ok and not setup_done():
		step = setup_next_step()
		built = setup_step()
	if not (built is GSResult):
		_setup_step = SETUP_STEPS.size()
		var failed := GSResult.fail(GSError.CODE_STATE, "setup step %s died on a script error (see the SCRIPT ERROR above)" % step)
		GSLog.error(CHANNEL, "the game would not build", {"step": String(step), "why": failed.error.message})
		return failed
	return built

## The parts of [method setup] after the mode and the map, in order, one [method setup_step] each. Split
## because together they were one 222 ms frame on a drawing client (staging02, cp-orange-x3).
const SETUP_STEPS: Array[StringName] = [&"collision", &"combat", &"match", &"loadouts", &"loadout_command", &"progress", &"layers", &"stack", &"toys"]

## The next [constant SETUP_STEPS] index; [code]SETUP_STEPS.size()[/code] once set up.
var _setup_step := 0

## The mode and the map; then [method setup_step] until [method setup_done]. Not re-entrant, like setup.
func setup_begin(p_map: FcMap = null) -> GSResult:
	_setup_step = 0
	# The mode first: the map default, the damage rules and the match rules all come
	# out of it, so resolving it after any of them would build them from the old one.
	if mode == null:
		mode = FcModes.by_id_or_default(mode_id)

	_apply_ctf_teams()
	var mode_res := mode.validate()

	if not mode_res.ok:
		_setup_step = SETUP_STEPS.size()
		return mode_res

	map = (
		p_map if p_map != null
		else (
			FcMap.by_id(mode.preferred_map) if mode.preferred_map != &""
			else null
		)
	)

	if map == null:
		map = FcMap.dm_box()
	if map == null:
		# A map script that is missing from the pack mount (0.1.69: an un-rebased res://maps path) is a SCRIPT
		# ERROR above and a null here; every step after it would fail on the null instead of saying so.
		_setup_step = SETUP_STEPS.size()
		return GSResult.fail(GSError.CODE_STATE, "no map could be built (see the script error above)")

	if mode.is_team_mode() and team_spawn_split:
		var _tagged := map.split_spawns_for_teams()

	if mode.is_team_mode() and Array(map.spawn_tags).count("") == map.spawns.size():
		# Not fatal: gs-match falls back to the shared pool and everyone still spawns.
		GSLog.warn(
			CHANNEL,
			"a team mode on a map with no tagged spawns; both sides share one pool",
			{"mode": str(mode.id), "map": map.display_name}
		)
	return GSResult.success(null)

func setup_done() -> bool:
	return _setup_step >= SETUP_STEPS.size()

## The step [method setup_step] runs next (for a load timeline), or &"" once set up.
func setup_next_step() -> StringName:
	return SETUP_STEPS[_setup_step] if not setup_done() else &""

## Runs the next of [constant SETUP_STEPS]. A failed step ends the setup, as it did in one go.
func setup_step() -> GSResult:
	if setup_done():
		return GSResult.success(null)
	var step := SETUP_STEPS[_setup_step]
	_setup_step += 1
	var result := GSResult.success(null)
	match step:
		&"collision":
			# Before the combat manager and before any player: both bind to it.
			_build_world_collision()
		&"combat":
			result = _build_combat()
		&"match":
			result = _build_match()
		&"loadouts":
			result = _build_loadouts(false)
		&"loadout_command":
			_build_loadout_command()
		&"progress":
			result = _build_progress()
		&"layers":
			# Last, and after the combat manager: a monster is a combat entity and a prop is a rigid body
			# that has to land on the map.
			_reconcile_world_layers()
		&"stack":
			result = _build_player_stack()
		&"toys":
			# The stack is what knows the collision layout, and it is built last.
			_classify_world_collision()
			_build_toys()
			if register_service:
				_registered_name = (
					GSRegistry.scoped_name(SERVICE, service_scope)
					if service_scope != &""
					else SERVICE
				)
				GSRegistry.register(_registered_name, self)
			_announce_mode()
	if not result.ok:
		_setup_step = SETUP_STEPS.size()
	return result

## Keeps this world's combat manager on the server's replicated cvars (gs-combat's
## `mp_teammate_passthrough`), as [param source] reports them: the client's `GSClientLink`.
## Remembered, because a map change builds a new manager. True when it is following.
func follow_server_cvars(source: Object) -> bool:
	_cvar_source = source
	# The ragdoll rules are the game's, not the map's, so they follow once and keep following.
	var _bodies := ragdoll_rules.follow_cvars(source)
	var _toys := toy_rules.follow_cvars(source)
	var _weapon_drops := weapon_drop_rules.follow_cvars(source)
	var _view := view_rules.follow_cvars(source)
	var _killview := killview_rules.follow_cvars(source)
	var _mobile := mobile_rules.follow_cvars(source)
	var _shots := shot_rules.follow_cvars(source)
	var _grenades := grenades_rules.follow_cvars(source)
	if rocket_rules != null:
		var _rockets: bool = rocket_rules.call(&"follow_cvars", source)
		if not rocket_rules.is_connected(&"changed", apply_rocket_rules):
			rocket_rules.connect(&"changed", apply_rocket_rules)
		apply_rocket_rules()
	var _ambient := ambient_rules.follow_cvars(source)
	var _spectate := spectate_rules.follow_cvars(source)
	var _knives := FcKnifeFollow.follow(knife_rules, source)
	var _solid := body_rules.follow_cvars(source)
	if noblock != null:
		noblock.follow(source)
	var _feel := feel_rules.follow_cvars(source)
	var _ads := ads_rules.follow_cvars(source)
	combat_feel.follow_cvars(source)
	return _follow_cvar_source()

func _forget_mirror(local_id: int) -> void:
	for sid in _mirror_ids.keys():
		if int(_mirror_ids[sid]) == local_id:
			_mirror_ids.erase(sid)

func _mirror_cast(from: Vector3, to: Vector3, owner_id: int) -> Dictionary:
	var offset := to - from
	var dist := offset.length()
	if dist <= 0.0 or combat == null:
		return {}
	var shooter := combat.hitboxes_of(owner_id)
	combat.trace.exclude = [shooter] if shooter != null else []
	var hit := combat.trace.ray(from, offset / dist, dist, combat.hitbox_sets())
	return {"position": hit.point} if hit.ok() else {}

## A bullet the server announced (BULLET): flies the same path here for a tracer. False when
## ballistics is off here, the weapon is unknown, or the mirror is full. Client side.
func mirror_bullet(server_id: int, weapon_id: StringName, origin: Vector3, velocity: Vector3, owner_id: int = 0) -> bool:
	var rules := combat_feel.ballistics as GSWeaponBallisticsRules
	var catalogue := FcPlayer.weapon_catalogue()
	if is_authority or rules == null or combat == null or not catalogue.has(weapon_id) or velocity.length() < 0.001:
		return false
	var tuning := catalogue.get_def(weapon_id).tuning as GSWeaponBallistics
	if tuning == null:
		return false
	if bullet_mirrors == null:
		bullet_mirrors = GSWeaponBullets.new()
		bullet_mirrors.name = "BulletMirrors"
		bullet_mirrors.tick_rate = tick_rate
		bullet_mirrors.cast_fn = _mirror_cast
		bullet_mirrors.expired.connect(func(id: int) -> void: _forget_mirror(id))
		bullet_mirrors.hit.connect(func(id: int, _o: int, _i: Dictionary, _d: float, _m: float, _t: GSWeaponBallistics) -> void:
			_forget_mirror(id))
		add_child(bullet_mirrors)
	bullet_mirrors.rules = rules
	if tracers == null:
		tracers = GSWeaponTracers.new()
		tracers.name = "Tracers"
		add_child(tracers)
		tracers.follow(bullet_mirrors)
	elif not bullet_mirrors.tracer.is_connected(tracers.add):
		tracers.follow(bullet_mirrors)
	var id := bullet_mirrors.spawn(owner_id, origin, velocity, tuning)
	if id > 0:
		_mirror_ids[server_id] = id
	return id > 0

## The server ended bullet [param server_id] (BULLET_END). Client side.
func end_bullet_mirror(server_id: int) -> void:
	if bullet_mirrors != null and _mirror_ids.has(server_id):
		bullet_mirrors.despawn(int(_mirror_ids[server_id]))
	_mirror_ids.erase(server_id)

## Advances the mirrored bullets one tick. Client side, from the bridge's client tick.
func step_bullet_mirrors(now_tick: float) -> void:
	if bullet_mirrors != null and bullet_mirrors.count() > 0:
		bullet_mirrors.step(now_tick)

## The server's jail state, on a client: the rules in ticks and when the gate was last opened.
func apply_jail_state(told: Dictionary) -> void:
	if map == null or map.jail == null:
		return
	var jail: RefCounted = map.jail
	jail.enabled = bool(told["enabled"])
	jail.open_ticks = int(told["open_ticks"])
	jail.cooldown_ticks = int(told["cooldown_ticks"])
	jail.opened_at = int(told["opened_at"])

func start(tick: int = 0) -> void:
	_tick = tick
	match_node.start(tick)

## Puts every player in the match at a spawn point of the map that was just built. [b]A position is
## a place in a room, and the room was replaced.[/b] Before this, a map change re-bodied each player
## against the new geometry and left them where they had been standing in the old one.
func _respawn_for_new_map() -> void:
	if not is_authority or match_node == null:
		return

	for id in player_ids():
		var key := str(id)
		var record := match_node.scoreboard.find(key)

		if record == null or not record.present or record.spectating:
			continue

		_on_respawn_due(key, match_node.choose_spawn(key, _tick), _tick)

## Frees everything that belongs to the map, in the order the connections require.
##
## [b]Disconnect before free, and disconnect from the object that holds the
## connection.[/b] Godot cleans up connections when a node is freed, so most of this
## is belt and braces — but [FcProgress] outlives the teardown and is connected to
## both the combat manager and the match node, and a node that is still connected to a
## freed object when its own handler runs is the error that has no line number.
func _teardown_world() -> void:
	_clear_toys()

	if progress != null:
		progress.unbind_world()

	for id in player_ids():
		(_players[id] as FcPlayer).leave_combat()

	if match_node != null and is_instance_valid(match_node):
		if match_node.respawn_due.is_connected(_on_respawn_due):
			match_node.respawn_due.disconnect(_on_respawn_due)

		if match_node.state_changed.is_connected(_on_match_state_changed):
			match_node.state_changed.disconnect(_on_match_state_changed)

		# The position callable closes over this node and is read on every spawn
		# selection. Cleared rather than left to the free, because a Callable held by
		# a node being freed is exactly the sort of thing that runs once more.
		match_node.position_fn = Callable()

		remove_child(match_node)
		match_node.queue_free()

	match_node = null

	if combat != null and is_instance_valid(combat):
		if combat.entity_killed.is_connected(_on_entity_killed):
			combat.entity_killed.disconnect(_on_entity_killed)

		if combat.damage_applied.is_connected(_on_damage_applied):
			combat.damage_applied.disconnect(_on_damage_applied)

		remove_child(combat)
		combat.queue_free()

	combat = null
	projectiles = null
	grenades = null

	if jail_view != null:
		remove_child(jail_view)
		jail_view.queue_free()
		jail_view = null
	if drops != null:
		remove_child(drops)
		drops.queue_free()
		drops = null
	FcWeaponDropWiring.teardown(self)
	if knives != null:
		remove_child(knives)
		knives.queue_free()
		knives = null
	_free_map_io()

	for point in _spawn_points:
		if is_instance_valid(point):
			remove_child(point)
			point.queue_free()

	_spawn_points.clear()

## One [GSFallDamage] per player, rebuilt when the combat manager is (a map change).
func _add_fall_damage(player: FcPlayer) -> void:
	var old := player.get_node_or_null("FallDamage")

	if old != null:
		player.remove_child(old)
		old.queue_free()

	if combat == null or player.controller == null:
		return

	var fall := GSFallDamage.new()
	fall.name = "FallDamage"
	fall.rules = fall_rules
	fall.victim = player.player_id
	fall.controller = GSNodeRef.of_path(player.controller.get_path())
	fall.controller.mode = GSNodeRef.Mode.ABSOLUTE
	fall.combat = GSNodeRef.of_path(combat.get_path())
	fall.combat.mode = GSNodeRef.Mode.ABSOLUTE
	fall.context_checks[&"protected"] = func() -> bool:
		if map != null and map.movement_profile == &"surf":
			return true
		return match_node != null and match_node.state != GSMatch.State.LIVE
	player.add_child(fall)

# --- Changing the map ------------------------------------------------------

## Replaces the world under the players who are standing in it.
func change_map(new_map: FcMap, new_mode: FcMode = null) -> GSResult:
	if new_map == null:
		return GSResult.fail(GSError.CODE_INVALID, "There is no map to change to.")

	if map == null or match_node == null:
		return GSResult.fail(
			GSError.CODE_STATE, "The game has not been set up, so there is nothing to change."
		)

	if new_mode != null:
		var mode_res := new_mode.validate()

		if not mode_res.ok:
			return mode_res.wrap("The mode that map wanted is not usable")

	# Read before the teardown: `_players` survives it, but the team a player was on
	# belongs to the match that is about to be freed.
	var roster: Array = []

	for id in player_ids():
		var player: FcPlayer = _players[id]
		roster.append({"id": id, "name": player.display_name})

	_teardown_world()
	_hurt_due.clear()

	map = new_map

	if new_mode != null:
		mode = new_mode
		_apply_ctf_teams()

	# Before the combat manager and before any player is re-bodied: both bind to it.
	_build_world_collision()
	_classify_world_collision()

	var combat_result := _build_combat()

	if not combat_result.ok:
		return combat_result.wrap("The new map's combat could not be built")

	var match_result := _build_match()

	if not match_result.ok:
		return match_result.wrap("The new map's match could not be built")

	for row in roster:
		var id := int(row["id"])
		var player := player_for(id)

		if player == null:
			continue

		# The body first. A player whose collision is still the old map's geometry is one standing
		# inside a wall that no longer exists, and the first tick after the change would push them
		# out of a room they are not in.
		player.ads_rules = ads_rules
		player.apply_map_movement(map_movement())
		player.rebind_map(map)
		player.join_combat(combat)
		_add_fall_damage(player)

		var added := match_node.add_player(str(id), String(row["name"]), _tick, 0)

		if not added.ok:
			GSLog.warn(CHANNEL, "a player could not rejoin after the map change", {
				"player": id, "why": added.error.message
			})
			continue

		player.team = team_of(id)

	if progress != null:
		progress.rebind_world()

	# The layers the NEW mode asks for, and only them: a changegame must not leave a mode with
	# objectives whose objectives are null, or a siege with no monsters.
	_reconcile_world_layers()

	# Before the announcement: the net bridge registers them inside its `map_changed`.
	_build_toys()

	# Whatever state the last match ended in, the new one starts from the beginning.
	match_node.start(_tick)

	GSLog.info(CHANNEL, "map changed", {
		"map": map.display_name, "mode": String(mode.id), "players": _players.size()
	})

	map_changed.emit(map)
	_announce_mode()

	# After the announcement, so every layer that rebinds on it — the player stack's
	# spawn sites and spawn rules, the effects' resolver hook — has done so before the
	# first spawn on the new map asks it anything.
	_respawn_for_new_map()

	return GSResult.success(map)

## Builds the movers [member defer_map_io] left out, a slice at a time. Call it after setup or change_map.
func build_map_io_async(slice: GSFrameSlice) -> void:
	if map_io != null or map == null:
		return
	var built = await FcMapIo.build_async(self, map_use, slice)
	if built != null and map_io == null and is_instance_valid(self):
		map_io = built
		add_child(map_io)
	elif built != null:
		built.free()

func remove_player(id: int) -> void:
	FcWeaponDropWiring.reset_drop_key(self, id)
	_unlag.erase(id)
	if _unlag_native != null:
		_unlag_native.forget(id)
	if block_rules != null:
		block_rules.forget(id)
	medals.forget(id)
	var player := player_for(id)

	if player == null:
		return

	if props != null:
		# Before anything else: it drops whatever they were carrying, and a physics
		# gun still holding a crate for a player who no longer exists holds it for
		# ever — the prop is frozen mid-air and nothing owns it.
		props.release_player(id)

	if progress != null:
		# Before the player leaves the match: `leave` files the session onto the
		# boards and reads the display name off the player to do it.
		progress.leave(id)

	if player_stack != null:
		# Before gs-match forgets them: the stack reads the scoreboard and the match's team for the records it
		# files, and after `match_node.remove_player` there is nothing there to read. A method rather than a
		# signal, because there is no signal here and adding one for a single subscriber is worse than a call.
		player_stack.drop_player(id)

	player.leave_combat()
	match_node.remove_player(str(id))

	_players.erase(id)
	_roster_dirty = true
	_ids_cache = []
	remove_child(player)
	player.queue_free()

## The flashlight config, made (with its cfg layers) on first use so a suite that builds a game by hand has one.
func flashlight_conf() -> GSFlashlightConfig:
	if flashlight_config == null:
		flashlight_config = FcFlashlight.make_config()
		flashlight_binder = FcFlashlight.make_binder(flashlight_config)
		GSLog.result(CHANNEL, "flashlight config", flashlight_binder.load_layers())
	return flashlight_config
