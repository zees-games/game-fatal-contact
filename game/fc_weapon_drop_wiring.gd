extends RefCounted

const FcContent := preload("fc_content.gd")
## How Fatal Contact feeds the shared dropped-weapon layer: building it, the drop key, and the drop on death.

const FcFlagCarry := preload("fc_flag_carry.gd")
const KillPovRules := preload("fc_kill_pov.gd")
const FitCache := preload("fc_drop_fit_cache.gd")

## The weapon layer, on both sides: the server simulates it, a client draws what it is told.
static func build(game) -> void:
	var layer := GSWeaponDrops.new()
	layer.name = "WeaponDrops"
	layer.rules = game.weapon_drop_rules
	layer.is_authority = game.is_authority
	# `game.headless` is the collision backend and is true on every client; a screen decides drawing.
	layer.draws = not GSPlatform.is_headless()
	layer.collision_mask = game.ragdoll_rules.collision_mask
	layer.keep_slots = [AwWeaponIds.SLOT_MELEE]
	layer.team_of = func(pid: int) -> int: return game.team_of(pid) if not game.teams().is_empty() else 0
	layer.look_of = look
	game.weapon_drops = layer
	game.add_child(layer)
	# A client parks its bodies under the loading cover; a server that draws nothing has no cover, and
	# its first throw of each weapon built and measured the model inside a tick (75 ms for a rifle).
	# The server parks them here, before its first tick.
	if not layer.draws and layer.is_authority:
		warm_server(layer)


## Bodies parked for each weapon a player starts with: a death drops one, and a round's deaths come close together, so one spare left the next drop building a model inside the tick (40 to 70 ms in the bench).
const POOL_DEPTH := 8


## Weapons worth parking a drop body for: every one with art, the same set the first-person warm-up walks.
static func prewarm_ids() -> Array:
	return AwWeaponArtTable.table().keys()


## Parks one body per weapon of [param ids] from index [param from] until [param until_msec]; returns the next index. Under the loading cover, a slice a frame, so the first throw builds nothing.
static func prewarm_step(game, ids: Array, from: int, until_msec: int) -> int:
	var next := from
	while next < ids.size() and Time.get_ticks_msec() < until_msec and game.weapon_drops != null:
		game.weapon_drops.prewarm(ids[next], POOL_DEPTH if ids[next] in FcContent.default_loadout() else 1)
		next += 1
	if next >= ids.size() and game.weapon_drops != null:
		game.weapon_drops.set_meta(POOLED, true)
	return next


## Set on a layer whose bodies [method prewarm_step] has parked. A map change builds a new layer, without it.
const POOLED := &"fc_drops_pooled"
## Game meta: the ids whose drop key let go of a flag, until that key is up again.
const SWALLOWED := &"drop_swallowed"


## Whether [param game]'s drop layer still has to be given its parked bodies (true after every game or map rebuild).
static func needs_pool(game) -> bool:
	return game != null and game.weapon_drops != null and game.weapon_drops.draws and not game.weapon_drops.has_meta(POOLED)


const CHARGE_FX := preload("res://addons/fc_weapons/view/aw_charge_fx.gd")

## The meshes and materials of the world model of each weapon of [param ids] from index [param from] until
## [param until_msec], appended to [param into]; returns the next index. A drop body waits outside the tree and
## a held weapon is built when its carrier spawns, so neither is drawn under the loading cover unless handed to it.
static func warm_looks(ids: Array, from: int, until_msec: int, into: Array) -> int:
	var next := from
	if from == 0:
		# The charge ball a watcher sees is built on the first charge (r_held_hooks 346 ms in the owner's profile).
		var ball: Node = CHARGE_FX.new()
		GSRenderWarmup.collect(ball, into)
		ball.free()
	while next < ids.size() and Time.get_ticks_msec() < until_msec:
		var model := look(ids[next])
		if model != null:
			# The watcher's reload splits the magazine out of the gun on its first frame; the cut is cached by model.
			model.on_reloading(true)
			GSRenderWarmup.collect(model, into)
			model.free()
		next += 1
	return next


## Parks a body per weapon on a layer that draws nothing, all at once: the first throw of a weapon loads and measures its
## model (150 to 1150 ms), and a death can drop any weapon a bot or player picked, so none may be left for a tick. Runs
## in [method build], before the first tick; a threaded warm-up stayed behind the early deaths. A weapon whose box
## [FitCache] remembers is parked without loading its model, so only the first boot of a host measures them (9.5 s on PH).
static func warm_server(layer: GSWeaponDrops) -> void:
	var started := Time.get_ticks_msec()
	var measured := 0
	for id in prewarm_ids():
		var sig := FitCache.signature(id)
		var fit := FitCache.recall(id, sig)
		if not fit.is_empty():
			layer._fits[id] = fit
		layer.prewarm(id, 1)
		if fit.is_empty():
			measured += 1
			FitCache.keep(id, sig, layer._fits.get(id, []))
	FitCache.save()
	layer.set_meta(SERVER_WARM, true)
	GSLog.info("fc.drops", "server drop warm", {"weapons": prewarm_ids().size(), "measured": measured, "msec": Time.get_ticks_msec() - started})


## Set on a server drop layer once [method warm_server] has parked a body for every weapon.
const SERVER_WARM := &"fc_drops_server_warm"


## Whether the server drop layer of [param game] is still warming (false once done, or when it has none).
static func server_warming(game) -> bool:
	return game != null and game.weapon_drops != null and not game.weapon_drops.draws and not game.weapon_drops.has_meta(SERVER_WARM)


static func teardown(game) -> void:
	if game.weapon_drops != null:
		game.remove_child(game.weapon_drops)
		game.weapon_drops.queue_free()
		game.weapon_drops = null
	game.drop_held.clear()
	game.use_held.clear()
	if game.has_meta(SWALLOWED):
		game.remove_meta(SWALLOWED)


## The drop key's rising edge throws the weapon in hand along the aim; the use key's takes the
## dropped weapon looked at; with `sv_weapon_drop_auto` an empty slot also takes one in reach.
static func input(game, id: int, player, pair: Array) -> void:
	if not game.is_authority or pair.size() < 2 or pair[1] == null:
		return
	# The shot hooks are put on once a tick by the game's tick ([method hook_shots]), not here once per player.
	var held: bool = (pair[1] as GSWeaponCommand).is_pressed(GSWeaponCommand.BUTTON_DROP)
	var was: bool = game.drop_held.get(id, false)
	game.drop_held[id] = held
	var use_now: bool = (pair[1] as GSWeaponCommand).is_pressed(GSWeaponCommand.BUTTON_USE)
	var used: bool = game.use_held.get(id, false)
	game.use_held[id] = use_now
	# A flag carrier's drop key lets go of the flag, not the gun. An id is only swallowed while its key is held (set on a
	# held tick, cleared on the first tick up; teardown clears it with `drop_held`), so a key up last tick and this one has
	# nothing to clear: the per-player per-tick meta lookup and its throwaway default dictionary are skipped then.
	if not held:
		if was and game.has_meta(SWALLOWED):
			(game.get_meta(SWALLOWED) as Dictionary).erase(id)
	elif not was and FcFlagCarry.try_drop(game, id, player):
		# The press let go of the flag: the weapon key waits for a release, or it would read the next tick as a new press.
		_swallowed(game)[id] = true
		return
	# One key, one target: a map button or door looked at in reach wins; else the weapon on the floor.
	if use_now and not used and game.map_io != null and game.map_io.press_for(player, id):
		return
	if game.weapon_drops == null:
		return
	# `auto_pickup` is a server rule, not a class one (not in GSWeaponDropRules.CLASS_KEYS), so it is read off the rules as they are: `resolve(def)` builds a fresh rules object per call, and this ran for every idle player every tick while any drop lay on the floor.
	var auto_pickup: bool = game.weapon_drops.rules.auto_pickup
	# Nobody touched a key this tick or last, and nothing here acts without one (the auto pickup needs a drop and its rule on): the use key's hold has nothing to cancel and the prompt query is skipped. This was ~60 us per player per tick at 64 players.
	if not held and not was and not use_now and not used \
			and (not auto_pickup or game.weapon_drops.count() == 0):
		return
	var def := class_def_of(game, id)
	var velocity: Vector3 = player.controller.state.velocity
	var _thrown: int = _drop_key(game, id).step(game.weapon_drops, player.arsenal, player.muzzle_position(),
		player.aim_direction(), id, held and not (game.has_meta(SWALLOWED) and (game.get_meta(SWALLOWED) as Dictionary).has(id)),
		game.get_physics_process_delta_time(), def, velocity)
	if held and not was:
		return
	if _use_hold(game, id, player, def, use_now):
		pass
	elif auto_pickup and game.weapon_drops.count() > 0:
		var _taken: int = game.weapon_drops.take_for(player.arsenal, player.controller.state.position + Vector3.UP * 0.5, id, def)


## Client, every frame: the panel over the dropped weapon looked at, and the circle while the use key is held.
static func update_panel(client, pressed: bool, delta: float) -> void:
	var game = client.game
	var player = client.player
	var view: GSWeaponPickupView = client.get_meta(&"pickup_view") if client.has_meta(&"pickup_view") else null
	var hold: GSWeaponUseHold = client.get_meta(&"pickup_hold") if client.has_meta(&"pickup_hold") else null
	if view == null:
		view = GSWeaponPickupView.new()
		view.name = "PickupView"
		view.visible = false
		game.add_child(view)
		hold = GSWeaponUseHold.new()
		client.set_meta(&"pickup_view", view)
		client.set_meta(&"pickup_hold", hold)
	var info := {}
	# A replay (killcam) draws a past moment: the live "E to pickup" tag must not hang over its ground weapons.
	var replaying: bool = client.is_inside_tree() and KillPovRules.is_replay_camera(client.get_viewport().get_camera_3d())
	if not replaying and game.weapon_drops != null and player != null and player.is_alive() and player.arsenal != null and game.weapon_drops.count() > 0:
		info = game.weapon_drops.prompt_for(player.arsenal, player.camera.global_position, -player.camera.global_basis.z, game.weapon_drop_class_of(player.player_id), game.team_of(player.player_id) if not game.teams().is_empty() else 0)
	hold.hold_time = game.weapon_drops.rules.hold_time if game.weapon_drops != null else 0.6
	var _event := hold.step(pressed, delta, not info.is_empty() and (info.get("mode", "") == "ammo" or bool(info.get("hold", false))))
	var fill := hold.progress
	if client.hud != null:
		view.key_text = String(client.hud.keys.get(&"use", "E"))
	view.name_of = func(id: StringName) -> String:
		var def: Variant = player.arsenal.catalogue.get_def(id)
		return def.name_or_id() if def != null else String(id)
	# One ring: the crosshair's. The panel's own world circle stays off (fill 0), or two rings fill at once.
	view.show_prompt(info, 0.0)
	if client.hud != null and client.hud.crosshair != null:
		client.hud.crosshair.hold_progress = fill


## Lets every traced shot and splash push a dropped weapon (a splash not through a wall); idempotent, as the trace is built
## later than the layer. The server's tick calls it once a tick, before any player's input.
static func hook_shots(game) -> void:
	if game.weapon_drops == null or game.combat == null or not game.combat.trace is GSTrace:
		return
	var trace: GSTrace = game.combat.trace
	if trace.ray_observer.is_valid():
		return
	var drops: GSWeaponDrops = game.weapon_drops
	drops.can_see = trace.line_of_sight
	trace.ray_observer = func(from: Vector3, dir: Vector3, dist: float) -> void:
		if drops.count() == 0:
			return
		var found := drops.raycast(from, from + dir * dist)
		if not found.is_empty():
			var _pushed := drops.hit(int(found["id"]), found["point"], dir, 3.0)
	trace.sphere_observer = func(centre: Vector3, radius: float) -> void:
		if drops.count() > 0:
			var _n := drops.blast(centre, radius, 8.0)


## The player's drop key: a press throws at once, or after `sv_weapon_drop_key_hold` seconds held.
static func _drop_key(game, id: int) -> GSWeaponDropKey:
	var keys: Dictionary = game.get_meta(&"drop_keys", {})
	game.set_meta(&"drop_keys", keys)
	var key: GSWeaponDropKey = keys.get(id)
	if key == null:
		key = GSWeaponDropKey.new()
		keys[id] = key
	return key


## Forgets a hold in progress: call on death, respawn and disconnect.
static func reset_drop_key(game, id: int) -> void:
	var keys: Dictionary = game.get_meta(&"drop_keys", {})
	if keys.has(id):
		(keys[id] as GSWeaponDropKey).reset()
	if game.has_meta(SWALLOWED):
		(game.get_meta(SWALLOWED) as Dictionary).erase(id)


## The ids whose drop key let go of a flag and waits for a release.
static func _swallowed(game) -> Dictionary:
	if not game.has_meta(SWALLOWED):
		game.set_meta(SWALLOWED, {})
	return game.get_meta(SWALLOWED)


## The use key on a dropped weapon: the shared rules in [GSWeaponUseKey].
static func _use_hold(game, id: int, player, def: GSPlayerClassDef, pressed: bool) -> bool:
	var keys: Dictionary = game.get_meta(&"use_keys", {})
	game.set_meta(&"use_keys", keys)
	var key: GSWeaponUseKey = keys.get(id)
	if key == null:
		key = GSWeaponUseKey.new()
		keys[id] = key
	return key.step(game.weapon_drops, player.arsenal, player.muzzle_position(), player.aim_direction(), id, pressed,
		game.get_physics_process_delta_time(), def, game.team_of(id) if not game.teams().is_empty() else 0)


static func class_def_of(game, id: int) -> GSPlayerClassDef:
	if game.player_stack == null or game.player_stack.classes == null:
		return null
	return game.player_stack.classes.def_of(str(id))


static func look(weapon_id: StringName) -> Node3D:
	var art: Variant = AwWeaponArtTable.table().get(weapon_id)
	if not (art is AwWeaponVisual):
		return null
	var model := AwWorldModel.new()
	# Its wall probe would slide the mesh out of the collision box beside any wall or step.
	model.wall_response = false
	var _drawn := model.equip(art as AwWeaponVisual)
	return model


## Called by the player as it dies, before its arsenal is disabled (a dead arsenal gives up nothing).
static func drop_for_death(game, player) -> void:
	reset_drop_key(game, player.player_id)
	if game.weapon_drops == null or not game.is_authority:
		return
	var state: Variant = player.controller.state
	var _gun: Variant = game.weapon_drops.drop_dead(player.arsenal, state.position + Vector3.UP, state.velocity * 0.5 + Vector3.UP * 2.0, player.player_id, class_def_of(game, player.player_id))
