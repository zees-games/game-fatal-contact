extends RefCounted
## gs-sim's collision mirror of the map in play (cvar `sv_trace_mirror`): the static bodies under the map's
## collision root copied once into a native BVH (`GSSimTraceMirror`), so a bot's sight and wall rays cost about a
## microsecond instead of a physics-server query under the shared ray lock. Moving bodies (AnimatableBody3D, the
## `trace_dynamic` group) are re-posed once a tick. The mirror holds the map's world and nothing else: a weapon
## drop or a toy (RigidBody3D) no longer blocks a bot's line, as Source's world trace ignores entities.
## Answers match Godot Physics within float noise (hit or miss, fraction 1e-3, normal 1 degree): the suite
## headless_trace_mirror holds that on every map kind. Without the library, or at 0, every ray asks the space.
## Typed loosely on purpose: a build without the class still parses this file.

## Cvar `sv_trace_mirror`: 0 asks the physics space for every ray (the reference and the fallback).
static var enabled := true

static var _mirror: Object = null
static var _root_id := 0
static var _synced_frame := -1
static var _movers := 0


## The mirror of [param root]'s collision, built on the first ask after a map change and re-posed once a physics
## frame; null when off, without gs-sim's class, or with no root in the tree. Main thread only.
static func of(root: Variant) -> Object:
	if not enabled or not root is Node3D or not (root as Node3D).is_inside_tree() \
			or not GSSim.has(&"trace_mirror"):
		return null
	var id := (root as Node3D).get_instance_id()
	if _mirror == null or _root_id != id:
		_mirror = ClassDB.instantiate(&"GSSimTraceMirror")
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
	return of((map as Object).get("collision_root") if map is Object else null)


## Drops the mirror (a test that rebuilds a scene under the same root).
static func reset() -> void:
	_mirror = null
	_root_id = 0
	_synced_frame = -1
	_bound_mirror = 0


## Whether gs-sim's motor body can collide against a mirror ([code]GSSimFpsBody.set_trace_mirror[/code]).
static func motor_available() -> bool:
	if _motor_known < 0:
		_motor_known = 1 if ClassDB.class_has_method(&"GSSimFpsBody", &"set_trace_mirror") else 0
	return _motor_known == 1


static var _motor_known := -1
static var _bound_mirror := 0


## Points [param body]'s native motor (a [GSFpsPhysicsBody]) at [param mirror], or back at its physics space with
## null. Remembered on the body, so a tick that changes nothing costs one meta read. The flat body of a built-in
## map is left alone: its analytic world is already native and exact. Whether the body now asks the mirror.
static func bind_body(body: Object, mirror: Object) -> bool:
	if not body is GSFpsPhysicsBody or not motor_available():
		return false
	var native: Object = body.call(&"_nat") if mirror != null else body.get(&"_native")
	if native == null:
		return false
	var key := Vector2i(native.get_instance_id(), mirror.get_instance_id() if mirror != null else 0)
	if body.get_meta(&"fc_trace_mirror", Vector2i.ZERO) == key:
		return mirror != null
	body.set_meta(&"fc_trace_mirror", key)
	if mirror != null:
		native.call(&"set_trace_mirror", mirror)
	else:
		native.call(&"clear_flat_world")
	return mirror != null


## Once a tick before the players' loop: every player's native motor collides against the map's mirror while
## [member enabled] (and gs-sim has it), else against the physics space. [param players] holds FcPlayer nodes.
static func bind_players(game: Object, players: Array) -> void:
	var mirror: Object = of_game(game) if motor_available() else null
	if mirror == null and _bound_mirror == 0:
		return
	_bound_mirror = mirror.get_instance_id() if mirror != null else 0
	for p: Variant in players:
		var controller: Variant = (p as Object).get(&"controller") if p is Object else null
		if controller is Object:
			bind_body((controller as Object).get(&"body"), mirror)
