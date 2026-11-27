extends RefCounted
## gs-sim's collision mirror of the map in play (cvar `sv_trace_mirror`): the static bodies under the map's
## collision root copied once into a native BVH (`GSSimTraceMirror`), so a bot's sight and wall rays cost about a
## microsecond instead of a physics-server query under the shared ray lock. Players' native motors collide against it
## too, server and predicting client alike (the cvar is replicated), except near anything it does not hold. Moving bodies (AnimatableBody3D, the
## `trace_dynamic` group) are re-posed once a tick. The mirror holds the map's world and nothing else: a weapon
## drop or a toy (RigidBody3D) no longer blocks a bot's line, as Source's world trace ignores entities.
## Answers match Godot Physics within float noise (hit or miss, fraction 1e-3, normal 1 degree): the suite
## headless_trace_mirror holds that on every map kind. Without the library, or at 0, every ray asks the space.
## A map that ships a baked blob beside its manifest ([method bake_path], written by [code]to_bytes[/code]) loads its
## static part from it instead of walking the scene; moving bodies are still read from the scene.
## Typed loosely on purpose: a build without the class still parses this file.

## Cvar `sv_trace_mirror`: 0 asks the physics space for every ray (the reference and the fallback).
static var enabled := true

static var _mirror: Object = null
static var _root_id := 0
static var _synced_frame := -1
static var _movers := 0


## The mirror of [param root]'s collision, built on the first ask after a map change and re-posed once a physics
## frame; null when off, without gs-sim's class, or with no root in the tree. [param baked] names a blob to load the
## static part from when it exists and is one; otherwise the scene is walked. Main thread only.
static func of(root: Variant, baked: String = "") -> Object:
	if not enabled or not root is Node3D or not (root as Node3D).is_inside_tree() \
			or not GSSim.has(&"trace_mirror"):
		return null
	var id := (root as Node3D).get_instance_id()
	if _mirror == null or _root_id != id:
		_mirror = ClassDB.instantiate(&"GSSimTraceMirror")
		var bytes := FileAccess.get_file_as_bytes(baked) if baked != "" and FileAccess.file_exists(baked) \
				else PackedByteArray()
		if bytes.is_empty() or not bool(_mirror.call(&"load_baked", root, bytes)):
			_mirror.call(&"load_scene", root)
		_root_id = id
		_synced_frame = Engine.get_physics_frames()
		_movers = int((_mirror.call(&"stats") as Dictionary).get("movers", 0))
	elif _movers > 0 and _synced_frame != Engine.get_physics_frames():
		_synced_frame = Engine.get_physics_frames()
		_mirror.call(&"sync_dynamic")
	return _mirror


## The mirror of [param game]'s map ([code]map.collision_root[/code]), or null as [method of].
static func of_game(game: Object) -> Object:
	if not enabled or game == null:
		return null
	var map: Variant = game.get("map")
	if not map is Object:
		return null
	return of((map as Object).get("collision_root"), bake_path(str((map as Object).get("manifest_path"))))


## Where a map's baked mirror lives: beside its manifest, [code]<manifest>.gscm[/code]; empty for a map without
## one (the built-in boxes are walked, which is quick).
static func bake_path(manifest_path: String) -> String:
	return "" if manifest_path.is_empty() or manifest_path == "<null>" else manifest_path.get_basename() + ".gscm"


## A client follows the server's [code]sv_trace_mirror[/code] (replicated), because it predicts its own motor against
## the same world. Whether [param source] (gs-server's client link) can say it.
static func follow_cvars(source: Object) -> bool:
	if source == null or not is_instance_valid(source) or not source.has_method(&"replicated_cvar") \
			or not source.has_signal(&"replicated_cvar_changed"):
		return false
	var held := String(source.call(&"replicated_cvar", CVAR, ""))
	if held != "":
		enabled = held.to_float() >= 0.5
	if not source.is_connected(&"replicated_cvar_changed", _on_replicated):
		source.connect(&"replicated_cvar_changed", _on_replicated)
	return true


const CVAR := "sv_trace_mirror"


static func _on_replicated(cvar_name: String, value: String) -> void:
	if cvar_name == CVAR:
		enabled = value.to_float() >= 0.5


## Drops the mirror (a test that rebuilds a scene under the same root).
static func reset() -> void:
	_mirror = null
	_root_id = 0
	_synced_frame = -1
	_bound_mirror = 0


## Whether a player's native motor can collide against a mirror: gs-sim's body has [code]set_trace_mirror[/code] and
## gs-player-controller has the public seam [code]GSFpsPhysicsBody.set_trace_world[/code] (level 53).
static func motor_available() -> bool:
	if _motor_known < 0:
		_motor_known = 1 if ClassDB.class_has_method(&"GSSimFpsBody", &"set_trace_mirror") \
				and GSFpsPhysicsBody.new().has_method(&"set_trace_world") else 0
	return _motor_known == 1


static var _motor_known := -1
static var _bound_mirror := 0

## Metres around a player's middle (plus this tick's travel) that must hold only the mirror's static brushes for its
## motor to ask the mirror; anything else there sends that player back to the space for the tick.
const NEAR_RADIUS := 2.5
## A crowded sphere is not sorted through: this many answers or more counts as something unmirrored near.
const NEAR_MAX := 32
## Ticks a player's motor was sent back to the space because something the motor's mirror does not hold was near.
static var near_fallbacks := 0
static var _near_params: PhysicsShapeQueryParameters3D = null


## The map body under [param body] whose native motor takes a trace world: a [GSFpsPhysicsBody], unwrapped from a
## [GSFpsHullBody] (solid players); null for a built-in map's flat body, whose analytic world is already native.
static func world_body(body: Object) -> GSFpsPhysicsBody:
	if body is GSFpsHullBody:
		body = (body as GSFpsHullBody).inner
	return body as GSFpsPhysicsBody if body is GSFpsPhysicsBody else null


## Points [param body]'s native motor at [param mirror], or back at its physics space with null, through
## gs-player-controller's public seam (resent whenever the native body is rebuilt). Whether the body now asks the mirror.
static func bind_body(body: Object, mirror: Object) -> bool:
	var world := world_body(body)
	if world == null or not motor_available():
		return false
	return bool(world.call(&"set_trace_world", mirror))


## Whether everything [param world] could touch this tick is in the motor's mirror: within [constant NEAR_RADIUS] plus
## [param travel] of its middle there is only static brush under [param root] that it does not exclude. A mover (the
## motor's mirror does not follow movers yet), a toy or weapon drop (never mirrored), a physics hull, or a mirrored
## brush the body excludes sends the body back to the space, so those still collide exactly as before.
static func clear_near(world: GSFpsPhysicsBody, feet: Vector3, height: float, travel: float, root: Node3D) -> bool:
	var space := root.get_world_3d().direct_space_state if root.is_inside_tree() else null
	if space == null:
		return false
	if _near_params == null:
		_near_params = PhysicsShapeQueryParameters3D.new()
		_near_params.shape = SphereShape3D.new()
		_near_params.collide_with_areas = false
	(_near_params.shape as SphereShape3D).radius = NEAR_RADIUS + travel
	_near_params.transform = Transform3D(Basis.IDENTITY, feet + Vector3(0.0, height * 0.5, 0.0))
	_near_params.collision_mask = world.collision_mask | world.pass_out_mask
	var hits := space.intersect_shape(_near_params, NEAR_MAX)
	if hits.size() >= NEAR_MAX:
		return false
	for hit: Dictionary in hits:
		var c: Object = hit.get("collider")
		if not c is StaticBody3D or c is AnimatableBody3D or (c as Node).is_in_group(&"trace_dynamic") \
				or not root.is_ancestor_of(c as Node) or world.exclude.has(hit.get("rid", RID())):
			return false
	return true


## Once a tick before the players' loop, on every end that simulates (the server, and a client predicting its own
## player, so both ask the same world): every player's native motor collides against the map's mirror while
## [member enabled] (a replicated cvar) and gs-sim has it, except a player with something unmirrored near
## ([method clear_near]), who asks the space that tick. [param players] holds FcPlayer nodes.
static func bind_players(game: Object, players: Array) -> void:
	var mirror: Object = of_game(game) if motor_available() else null
	if mirror == null and _bound_mirror == 0:
		return
	_bound_mirror = mirror.get_instance_id() if mirror != null else 0
	var root: Node3D = null
	if mirror != null:
		var map: Variant = game.get("map")
		root = (map as Object).get("collision_root") as Node3D
	var delta := 1.0 / maxf(1.0, float(game.get("tick_rate")))
	for p: Variant in players:
		var controller: Variant = (p as Object).get(&"controller") if p is Object else null
		if not controller is GSFpsController:
			continue
		var c := controller as GSFpsController
		var world := world_body(c.body)
		if world == null:
			continue
		var use: Object = mirror
		if use != null and not clear_near(world, c.state.position, c.tunables.stand_height, c.state.velocity.length() * delta, root):
			use = null
			near_fallbacks += 1
		var _on := bind_body(world, use)
