@tool
extends "fc_nameplate_view.gd"

func _solid_hulls() -> Array:
	return solid_hulls_fn.call(player_id, _hull_tick) if solid_hulls_fn.is_valid() else []

## The map's movement body, wrapped so the other players' hulls stop its sweeps.
func _movement_body(of_map: FcMap) -> GSFpsBody:
	return FcSolidBody.new().wrap(of_map.movement_body(), _solid_hulls)

func _build_view() -> void:
	view = Node3D.new()
	view.name = "View"
	# The eye of the configured body (64 units by default), what the controller reports.
	view.position = Vector3(0.0, FcPlayerTunables.eye_height_m(), 0.0)
	add_child(view)

## Movement that feels like Fatal Contact shooter rather than a modern one. Fast, floaty, high air
## control, and no sprint: the speed is the speed, and the way to go faster is to move well.
static func configure_body(height_units: float, crouch_units: float, radius_units: float, unit_metres: float) -> void:
	FcPlayerTunables.configure_body(height_units, crouch_units, radius_units, unit_metres)

## Standing height of the body, metres (72 units by default).
static func stand_height() -> float:
	return FcPlayerTunables.stand_height_m()

## Standing eye height above the feet, metres (64 units by default).
static func eye_height() -> float:
	return FcPlayerTunables.eye_height_m()

static func fc_tunables() -> GSFpsTunables:
	return FcPlayerTunables.make()

## Hands the swim and ladder modes the map's water and ladders, or nothing. A player left
## swimming or climbing on a map with none is put in the air, which the motor resolves.
func _use_map_volumes() -> void:
	var mechanics: FcMapMechanics = _map.mechanics if _map != null else null
	swim.volumes = mechanics.water if mechanics != null else ([] as Array[AABB])
	ladder.volumes = mechanics.ladders if mechanics != null else ([] as Array[AABB])

	if controller == null or controller.state == null or controller.motor == null:
		return

	var mode_now := controller.state.mode

	if (mode_now == swim.mode_id and swim.volumes.is_empty()) \
			or (mode_now == ladder.mode_id and ladder.volumes.is_empty()):
		controller.motor.set_mode(controller.state, GSFpsState.Mode.AIR)

func _build_controller() -> void:
	var tunables := fc_tunables()

	if mode == Mode.HEADLESS:
		var headless := HeadlessController.new()
		# The map's own backend: its boxes for a built-in map, the physics space for an
		# imported one (see `FcMap.movement_body`).
		headless.flat_body = _movement_body(_map)
		controller = headless
	else:
		controller = GSFpsController.new()

	controller.name = "Movement"
	controller.drive = GSFpsController.Drive.EXTERNAL
	controller.tick_rate = _tick_rate
	controller.tunables = tunables
	controller.register_service = false
	controller.register_default_actions = false
	# No run HUD reads the movement stats (jumps, strafe sync) in FC: not folded every tick per player.
	# By name: the live shell's gs-player-controller 28 has no observe_stats (API 29) and folds them always.
	if &"observe_stats" in controller:
		controller.set(&"observe_stats", false)
	# On for every player on every machine, because a registration order is part of the
	# wire: an admin's noclip or freeze is a modifier the owning client has to predict,
	# and a client that had not registered it would read that index as something else.
	controller.admin_abilities = true
	controller.body_ref = GSNodeRef.of_path(NodePath(".."))
	# The genre's water, in the genre's numbers, because the maps were built for them: 200 u/s at
	# most, and a player who presses nothing sinks at 60 u/s rather than floating, so a pit full of
	# water is climbed out of by holding jump.
	swim.swim_speed = 200.0 * GENRE_UNIT
	swim.idle_sink_speed = 60.0 * GENRE_UNIT
	swim.accelerate = 10.0
	swim.waist = tunables.stand_height * 0.5
	swim.float_depth = tunables.stand_height * 56.0 / 72.0
	swim.exit_speed = 300.0 * GENRE_UNIT
	swim.exit_reach = 24.0 * GENRE_UNIT
	# A narrower body reaches less far to a ladder fixed on a wall: keep the grab distance the 0.4064 m hull had.
	ladder.reach = 0.05 + maxf(0.0, 0.4064 - tunables.radius)
	controller.extra_modes = [swim, ladder]
	_use_map_volumes()
	add_child(controller)

func is_alive() -> bool:
	return health.alive

## The body flinches on a hit that leaves the player alive, so a third-person view shows it.
func _on_damaged(_damage: GSDamage) -> void:
	if figure != null and is_alive():
		figure.flinch()

func make_dead() -> void:
	arsenal.disabled = true
	health.alive = false
	hitboxes.enabled = false
	if hull_world != null:
		hull_world.set_alive(hull_slot, false)


## Files this player in [param world] (gs-sim's `GSSimHullWorld`) as roster slot [param slot] for this players' loop;
## with [param native] its movement body gathers its hulls from the world. Whether the body does.
func use_hull_world(world: Object, slot: int, native: bool) -> bool:
	hull_world = world
	hull_slot = slot
	var body: GSFpsBody = controller.body if native and controller != null else null
	if body != _hull_body or slot != _hull_body_slot:
		if _hull_body != null and _hull_body != body:
			var _off := _hull_body.set_hull_world(null, -1)
		_hull_body = body
		_hull_body_slot = slot
		_hull_body_ok = body != null and body.set_hull_world(world, slot)
	return _hull_body_ok

func _on_died(damage: GSDamage) -> void:
	if before_death.is_valid(): before_death.call()
	make_dead()
	died.emit(damage)

func _build_health() -> void:
	health = GSHealth.new()
	health.name = "Health"
	health.max_health = _max_health
	health.max_armour = _max_armour
	# No regeneration. Fatal Contact shooter's health is a resource you pick up, and
	# regeneration turns every fight into a question of who disengages first.
	health.regen_per_second = _regen
	health.set_tick_rate(_tick_rate)
	add_child(health)

	health.died.connect(_on_died)
	health.damaged.connect(_on_damaged)

static func _catalogue() -> GSWeaponCatalogue:
	Roles.ensure()
	_build_shared_catalogue()
	if not _shared_warm:
		_shared_warm = true
		# Built once at setup, under the loading cover; the first spawn then loads no script.
		_shared_catalogue.warm_scripts()
	return _shared_catalogue

static func _build_shared_catalogue() -> void:
	if _shared_catalogue != null and _shared_generation == Roles.generation:
		return
	_shared_generation = Roles.generation
	_shared_warm = false
	_shared_catalogue = FcContent.weapon_catalogue()
	var res := _shared_catalogue.validate()
	if not res.ok:
		push_error(res.error.message)

## [method weapon_catalogue]'s first build in steps a loading screen can spread over frames (it was one
## 53 ms step on staging02): the roles, the table, then one weapon's behaviour script per step, kept in
## [param held] so the last step's warm finds each cached. False once the table is ready.
static func warm_catalogue_step(step: int, held: Array) -> bool:
	if step == 0:
		Roles.ensure()
		return true
	if step == 1:
		_build_shared_catalogue()
		return not _shared_warm
	var ids := _shared_catalogue.ids()
	if step - 2 < ids.size():
		var path := _shared_catalogue.get_def(ids[step - 2]).behaviour_path
		if path != "" and ResourceLoader.exists(path):
			held.append(load(path))
		return true
	_catalogue()
	held.clear()
	return false

func _on_used(outcome: GSWeaponOutcome) -> void:
	if camera != null:
		recoil_view.kick(outcome)
	used.emit(outcome)

## Puts a [AwWeaponRig] over [member arsenal], replacing any rig that was there. [b]The rig is
## handed THIS player's arsenal rather than building its own[/b] (`arsenal_ref`), and that is what
## lets it be rebuilt.
func _build_rig(role: AwWeaponRig.Role, authority: bool, view_model: Node3D) -> void:
	if weapons != null:
		remove_child(weapons)
		# free(), not queue_free(): the old rig is connected to the arsenal's signals, and
		# one left alive until the end of the frame would count this tick's reload twice.
		weapons.free()
		weapons = null

	weapons = AwWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = role
	weapons.authority = authority
	weapons.tick_rate = _tick_rate
	# The held weapon lowers at every brush that stops the player, clip and fences included, though shots pass them.
	weapons.wall_extra_mask = controller.tunables.collision_mask if controller != null else 0
	weapons.catalogue = _catalogue()
	weapons.arsenal_ref = GSNodeRef.of_path(^"../Arsenal")
	weapons.player_ref = GSNodeRef.of_path(^"..")
	if ads_rules != null:
		weapons.ads_rules = ads_rules

	if view_model != null:
		# In the tree by now: it hangs under this player's camera.
		weapons.view_model_ref = GSNodeRef.of_path(view_model.get_path())

	add_child(weapons)

	var res := weapons.setup()
	if not res.ok:
		push_error(res.error.message)

	# The rig's signal rather than the arsenal's: it carries the bash too, and it is
	# silent during a reconciliation replay, so a corrected client does not hear the
	# same shot once per replayed tick.
	weapons.used.connect(_on_used)

func _build_arsenal() -> void:
	arsenal = GSWeaponArsenal.new()
	arsenal.name = "Arsenal"
	arsenal.tick_rate = _tick_rate
	# One per pack slot: melee, sidearm, primary, heavy, thrown. `FcNetCommand`
	# bounds a slot request to the same number.
	arsenal.max_slots = MAX_SLOTS
	# Every player shares one catalogue: definitions are read-only and a per-player
	# copy would be twenty-seven resources per player for nothing. Behaviour instances
	# are per-player, which is the half that actually holds state.
	arsenal.catalogue = _catalogue()
	# Fitted only by the server (Ask.ATTACH); a client's copy follows `net_fitted`.
	arsenal.attachments = FcAttach.catalogue()
	# The posture from the simulated state, as the full weapon context has it; set before the rig, which
	# otherwise puts its own (read from the controller's motion, without the flinch) there.
	arsenal.idle_posture = _idle_posture
	arsenal.idle_still = _idle_still
	add_child(arsenal)

	var res := arsenal.setup()
	if not res.ok:
		push_error(res.error.message)

	_build_rig(AwWeaponRig.Role.SERVER, false, null)












func _build_hitboxes() -> void:
	var plan := GSPlayerHitboxes.new()
	plan.name = "HitboxPlan"
	# The zones were drawn for a 1.8 m body; they follow the configured height.
	var k := FcPlayerTunables.body_scale()
	plan.height = FcPlayerTunables.stand_height_m()
	plan.set_factory = func() -> Node3D:
		var set_ := GSHitboxSet.new()
		set_.bounds_offset = Vector3(0.0, 0.9 * k, 0.0)
		set_.bounds_radius = 1.6 * k
		return set_
	# Fatal Contact's five zones in absolute metres (not scaled from the height), so hit geometry and
	# hitzone stats stay as they were; the other stock zones are dropped. Head outranks the
	# torso so their shared surface resolves to the head every time.
	plan.config = {
		"disabled": ["arm_l", "arm_r", "hand_l", "hand_r", "leg_l", "leg_r", "foot_l", "foot_r"],
		"zones": {
			"head": {"position": [0.0, 1.62 * k, 0.0], "radius": 0.15 * k, "precedence": 10},
			"neck": {"position": [0.0, 1.46 * k, 0.0], "radius": 0.09 * k, "precedence": 5},
			"torso": {"position": [0.0, 0.98 * k, 0.0], "radius": 0.30 * k, "height": 1.05 * k, "precedence": 0},
			"legs": {"group": "leg", "shape": "capsule", "position": [0.0, 0.45 * k, 0.0], "radius": 0.24 * k, "height": 0.9 * k, "precedence": 0},
			"feet": {"group": "foot", "shape": "sphere", "position": [0.0, 0.12 * k, 0.0], "radius": 0.14 * k, "precedence": 5},
		},
	}
	add_child(plan)
	# Built now rather than on the plan's _ready: the set must exist when this returns.
	var built := plan.build()
	if not built.ok:
		push_error("arena hitboxes: " + built.error.message)
	# The set's entity owner is its parent, so it hangs off the player, not off the plan.
	hitboxes = plan.hitbox_set() as GSHitboxSet
	plan.remove_child(hitboxes)
	remove_child(plan)
	plan.free()
	add_child(hitboxes)
	hitboxes.refresh()
	_fit_k = -1.0

## The game's tick rate: the controller, health and weapons are built on it, and a bot's simulator
## steps at it, so a rate other than the default must reach them. Given before [method setup], and
## again whenever the game's rate changes ([method FcGame.set_tick_rate]: a client learns the
## server's from HELLO after its players exist), when it reaches the parts already built.
func use_tick_rate(rate: int) -> void:
	_tick_rate = maxi(rate, 1)
	if controller != null:
		controller.tick_rate = _tick_rate
		# The controller hands its rate to the motor once, when it readies.
		if controller.motor != null:
			controller.motor.set_tick_rate(_tick_rate)
			GSFpsNetSync.set_tick_rate(_tick_rate)
	if health != null:
		health.set_tick_rate(_tick_rate)
	if weapons != null:
		# The rig's setter passes it on to its arsenal.
		weapons.tick_rate = _tick_rate
	elif arsenal != null:
		arsenal.tick_rate = _tick_rate


## Builds the whole player. Call before adding to the tree.
func setup(p_mode: Mode, map: FcMap, id: int, name_text: String = "") -> void:
	mode = p_mode
	_map = map
	player_id = id

	if name_text != "":
		display_name = name_text

	name = "Player%d" % id

	_build_view()
	_build_controller()
	_build_health()
	_build_arsenal()
	_build_hitboxes()

## The collision layers this player's movement sweeps against. [b]Not left at `GSFpsTunables`'
## default of 1.[/b] One means bit 0, which is right only while every body in the game is on bit 0 —
## the state the layout exists to end.
func use_collision_mask(mask: int) -> void:
	if controller == null or controller.tunables == null:
		return

	controller.tunables.collision_mask = mask
	if weapons != null:
		weapons.wall_extra_mask = mask

## The class profile's `look_down_back` attribute (metres your body trails back looking down), else the default.
static func look_down_back_of(def: GSPlayerClassDef) -> float:
	var attrs: Variant = def.get("attributes") if def != null else null
	if attrs is Dictionary and (attrs as Dictionary).has("look_down_back"):
		return clampf(float((attrs as Dictionary)["look_down_back"]), 0.0, 2.0)
	return 0.45

## Scales this player's movement by their class.
func apply_class_movement(def: GSPlayerClassDef) -> void:
	if controller == null or controller.tunables == null or def == null:
		return

	if _class_base == null:
		_class_base = ClassBase.new()
		_class_base.max_speed = controller.tunables.max_speed
		_class_base.jump_height = controller.tunables.jump_height

	var _n := GSPlayerClassApply.to_movement(def, controller.tunables, _class_base)
	FcPlayerTunables.apply_class_attributes(def, controller.tunables)
	first_person_look_down_back = look_down_back_of(def)

## Puts this player's movement on what the map asks for: [param overrides] (keys from [constant
## SURF_TUNABLES]) on top of [method fc_tunables], and every key it does not name back to the
## Fatal Contact's own.
func apply_map_movement(overrides: Dictionary) -> void:
	if controller == null or controller.tunables == null:
		return

	var base := fc_tunables()

	for key: String in SURF_TUNABLES:
		var value := float(overrides.get(key, base.get(key)))
		controller.tunables.set(key, value)

		if _class_base != null:
			_class_base.set(key, value)

## Drops what the drawing carries from tick to tick: the stair easing, the frame two ticks back, the
## camera's motion. After a spawn or a teleport, which the eye jumps with.
func _forget_drawn() -> void:
	_yaw_before_tick = controller.state.yaw
	_position_two_back = Vector3(NAN, NAN, NAN)
	_step_offset = 0.0
	_step_rise = 0.0
	_step_drawn = 0.0
	_step_tick = controller.state.tick
	_landing_impact = 0.0
	if camera_motion != null:
		camera_motion.snap()
	if body_motion != null:
		body_motion.snap()

## Sends this player through a teleport volume of an imported map, or back to a spawn when they have
## fallen out of the bottom of it.
func _follow_map_volumes() -> void:
	if _map == null or not _map.is_imported():
		return

	var feet := controller.state.position

	# On the game tick, never controller.state.tick: the jail's gate opened on it (jail-sim-tick-1).
	var pit := _map.pit_at(feet, _hull_tick)
	if not pit.is_empty():
		controller.teleport(pit["to"], float(pit["yaw"]), 0.0)
		_post_moved = true
		_forget_drawn()
		return

	if feet.y < _map.bounds.position.y - _fall_out_depth and not _map.spawns.is_empty():
		var at: Transform3D = _map.spawns[0]
		controller.teleport(at.origin, rad_to_deg(at.basis.get_euler().y), 0.0)
		_post_moved = true
		_forget_drawn()

## FcConfig's player numbers, given before the first spawn resets health to the maximum.
func apply_vitals(max_health: float, max_armour: float, regen: float, fall_out_depth: float) -> void:
	_max_health = max_health
	_max_armour = max_armour
	_regen = regen
	_fall_out_depth = fall_out_depth
	if health != null:
		health.max_health = max_health
		health.max_armour = max_armour
		health.regen_per_second = regen
		health.health = minf(health.health, max_health) if health.alive else health.health

## What the map's brush entities do to this player this tick: its pushes, gravity and conveyors,
## then into the water or onto a ladder.
func _run_map_mechanics(start: Vector3, delta: float) -> void:
	if _map == null or _map.mechanics == null or controller.motor == null:
		return

	var state := controller.state
	if _map.mechanics.acts() or not ladder.volumes.is_empty() or not swim.volumes.is_empty():
		_post_moved = true
	_map.mechanics.simulate(controller.motor, state, start, delta)

	if not ladder.volumes.is_empty():
		ladder.update(controller.motor, state)

	if not swim.volumes.is_empty() and state.mode != ladder.mode_id:
		swim.update(controller.motor, state)

	# A push moved the state after the controller wrote it out; the node follows, as the
	# controller's own publish does, so the muzzle and the hitboxes are where the player is.
	# Nothing moved it (most ticks): the node is already there, and a write would only send every child's transform round again.
	if lean_tick and global_position == state.position:
		return
	global_position = state.position

func _apply_body_rules() -> void:
	if body_motion == null:
		return
	for key in _body_rules:
		body_motion.set(key, _body_rules[key])

static func _set_rule(tunables: Object, key: String, value: Variant) -> void:
	if key.ends_with("_enabled") or typeof(tunables.get(key)) == TYPE_BOOL:
		tunables.set(key, float(value) != 0.0)
	elif typeof(tunables.get(key)) == TYPE_INT:
		# RULES carries every value as a float32; a count (wall_jump_max_per_air) is an int.
		tunables.set(key, roundi(float(value)))
	else:
		tunables.set(key, float(value))

## Writes [param rules] (key -> number, from [constant MOVEMENT_RULES]) into this player's
## movement, and into the class base it is re-derived from, or the next class change would
## put the old value back. A key not in the list is ignored: RULES came over the wire.
func apply_movement_rules(rules: Dictionary) -> void:
	if controller == null or controller.tunables == null:
		return

	for key in rules:
		if not MOVEMENT_RULES.has(String(key)):
			continue
		if BODY_RULES.has(String(key)):
			_body_rules[String(key)] = float(rules[key])
			_apply_body_rules()
			continue
		_set_rule(controller.tunables, String(key), rules[key])
		if _class_base != null:
			_set_rule(_class_base, String(key), rules[key])

## Poses [member body_mesh] from [param drawn]: its yaw, then the wall-run roll and turn.
## A body not on a wall has exactly the yaw it had, so this is every body's placement.
func _pose_body(drawn: GSFpsState, yaw: float, delta: float) -> void:
	if body_mesh == null:
		return
	if body_motion == null:
		body_motion = GSFpsViewMotion.new()
		body_motion.wall_run_body_roll = BODY_RULES.wall_run_body_roll
		body_motion.wall_run_body_yaw = BODY_RULES.wall_run_body_yaw
		_apply_body_rules()
	# The wall is not replicated: a body drawn from the wire finds it with two rays.
	if drawn.is_wall_running() and drawn.wall_normal == Vector3.ZERO and body_mesh.is_inside_tree():
		drawn.wall_normal = GSFpsWallProbe.find(
			body_mesh.get_world_3d().direct_space_state, drawn.position, drawn.velocity,
			controller.tunables.collision_mask if controller != null else 1)
	# Off a wall with the lean eased out, the advance only moves cues a body never reads (its roll and turn stay put).
	if drawn.is_wall_running() or absf(body_motion.body_yaw()) > POSE_SETTLED_DEG or absf(body_motion.body_roll()) > POSE_SETTLED_DEG:
		body_motion.advance(drawn, delta)
	var posed := (
		Basis(Vector3.UP, deg_to_rad(yaw + body_motion.body_yaw()))
		* Basis(Vector3.BACK, deg_to_rad(body_motion.body_roll()))
	)
	# A body that did not turn keeps its placement: a write re-propagates the transform through the whole figure
	# (skeleton, gun, tag) even when it is the same. Compared against the node itself, so whatever else turned it is undone.
	if pose_skip_enabled and body_mesh.global_basis.is_equal_approx(posed):
		return
	body_mesh.global_basis = posed

## Makes this the player at this keyboard: the hands under [param view_model] and a rig that draws
## them, its tracers and its reports. Client side, once, on adoption.
func arm_first_person(view_model: Node3D, authority: bool) -> void:
	_build_rig(AwWeaponRig.Role.LOCAL, authority, view_model)



## The shared weapon table, for anything else in the game that reads a definition.
static func weapon_catalogue() -> GSWeaponCatalogue:
	return _catalogue()

## The map this player's collision was built against, which [method rebind_map] replaces.
func map_in_hand() -> FcMap:
	return _map

## Rebuilds this player's collision against a different map.
func rebind_map(new_map: FcMap) -> void:
	_map = new_map

	if new_map == null or controller == null:
		return

	if controller is HeadlessController:
		(controller as HeadlessController).flat_body = _movement_body(new_map)

	_use_map_volumes()

	# `setup()` is what builds the body and the motor, and it is the documented way to
	# rebuild both. Re-running it also re-resolves the node references, which is
	# harmless: they name this player's own children and have not moved.
	var rebuilt := controller.setup()

	if not rebuilt.ok:
		GSLog.warn(CHANNEL, "a player could not be re-bodied for the new map", {
			"player": player_id, "why": rebuilt.error.message
		})

## Where shots start: the eyes, not the feet. Read off the View node when there is one, because that is what the arsenal is handed to place a shot;
## computing it a second way would let the server's idea of the muzzle drift from the one shots came out of, and `_correct_origin` would relocate every legitimate shot.
func muzzle_position() -> Vector3:
	if view != null and view.is_inside_tree():
		return view.global_position

	return controller.state.position + Vector3(0.0, eye_height(), 0.0)

# --- Registration ----------------------------------------------------------

## Registers with the combat manager so this player can shoot and be shot. Both halves matter and
## they are separate calls in gs-combat: hitboxes make you hittable, health makes you damageable.
func join_combat(combat: GSCombatManager) -> void:
	_combat = combat
	hitboxes.register_with(combat, player_id)
	combat.register_health(player_id, health)
	combat.set_authoritative_origin(player_id, muzzle_position())

func leave_combat() -> void:
	if _combat != null and is_instance_valid(_combat):
		_combat.forget(player_id)
	_combat = null

## Which of two slots to spawn holding: the heaviest GUN, never the grenade.
static func _better_hand(have: int, slot: int) -> int:
	if FcContent.is_grenade_slot(slot):
		return have if have > 0 else slot
	if have == 0 or FcContent.is_grenade_slot(have) or slot > have:
		return slot
	return have

## Holds [param slot] at once. A spawn into a round's freeze has the arsenal disabled, where `select`
## refuses and a bot (which presses no slot key) would stay on the knife it was given first.
func hold(slot: int) -> void:
	if not arsenal.equip(slot):
		var _selected := arsenal.select(slot, controller.state.tick)

# --- Loadout ---------------------------------------------------------------

## Gives the weapons a resolved loadout names. [param entries] is what [method
## GSLoadoutManager.resolve] returns: dictionaries of `slot`, `arsenal_slot`, `item` and `count`.
func give_loadout(entries: Array[Dictionary]) -> void:
	# sg_* laps (--sim_sections 2) split sl_give: clear, the item gives, the melee fallback, the hold.
	var t_lap := FcFrameProbe.lap_start()
	arsenal.clear()
	t_lap = FcFrameProbe.lap(&"sg_clear", t_lap)

	var catalogue := arsenal.catalogue
	var hand := 0

	for entry in entries:
		var item: GSItem = entry["item"]

		if not catalogue.has(item.id):
			# An equipment item with no weapon behind it. Armour goes through here.
			if item.id == &"armour":
				health.add_armour(100.0)
			continue

		var res := arsenal.give(item.id)

		if not res.ok:
			# [b]`GSLog`, not `push_warning`.[/b] A loadout entry the arsenal refused is a RUNTIME
			# condition an operator would want to see -- somebody spawned without the weapon they
			# picked -- so it belongs in the log file, on a channel, with the item that caused it.
			GSLog.warn(
				CHANNEL,
				"a loadout item could not be given",
				{
					"item": String(item.id),
					"player": player_id,
					"detail": res.error.message,
				}
			)
			continue

		hand = _better_hand(hand, catalogue.get_def(item.id).slot)

	# Something under the 1 key whatever the document said. A loadout from before the
	# melee slot names none, and a player whose last magazine runs dry should still have
	# something to swing.
	t_lap = FcFrameProbe.lap(&"sg_items", t_lap)
	if not arsenal.has_slot(AwWeaponIds.SLOT_MELEE):
		var _knife := arsenal.give(FcContent.melee_id())
	t_lap = FcFrameProbe.lap(&"sg_melee", t_lap)

	if hand > 0:
		hold(hand)
	FcFrameProbe.lap(&"sg_hold", t_lap)

## The default loadout, for a player who has not chosen one.
func give_default_loadout() -> void:
	arsenal.clear()

	for id in FcContent.default_loadout():
		var _given := arsenal.give(id)

	hold(FcContent.DEFAULT_SLOT)

# --- Lifecycle -------------------------------------------------------------

## Puts the player into the world alive and whole.
func spawn(at: Transform3D, tick: int, protection_ticks: int = 0) -> void:
	# teleport() takes the look angles, not a velocity: it zeroes the velocity itself
	# and setting yaw afterwards would miss the sampler and the view, which it also
	# snaps.
	controller.teleport(at.origin, rad_to_deg(at.basis.get_euler().y), 0.0)
	_forget_drawn()

	health.spawn_protection_ticks = protection_ticks
	health.reset(tick)

	arsenal.disabled = false
	global_transform = at

	# The view model back to rest, so a respawn does not inherit the last life's sway.
	if weapons != null:
		weapons.on_reset()

	if _combat != null:
		_combat.set_authoritative_origin(player_id, muzzle_position())

	if hull_world != null:
		var feet := controller.state.position
		hull_world.moved(hull_slot, feet.x, feet.y, feet.z)
		hull_world.set_alive(hull_slot, is_alive())

	spawned.emit(at)
