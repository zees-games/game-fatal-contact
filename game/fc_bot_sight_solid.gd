extends RefCounted
## An imported map's static solid for the native sight ray (gs-sim [code]GSSimSolid[/code], bound by
## [code]GSSimSightRay.bind_solid[/code]): every static body on the sight mask under the map's collision root,
## its brushes' convex hulls and its terrain's triangles, built once in Rust on a worker thread, so a bot's
## sight on that map skips the physics engine and its query lock. Bodies on the mask that are not in the solid
## (movers, props, spawned rubble) go in as bounds each bind: a line the solid finds clear but that crosses one
## asks the engine. headless_bot_sight_native checks the answers match the engine's on imported maps.

## Ticks between scans of the game for bodies on the mask outside the solid.
const RESCAN_TICKS := 32

## Whether the native ray asks an imported map's solid in place of the physics space and its lock; off: every
## imported-map ray is an engine ray (headless_bot_sight_native turns it off for the engine's answer).
static var enabled: bool = true
## One solid per collision root (instance id), shared by every world and round on that map.
static var _by_root: Dictionary = {}

var root: Node3D = null
var mask: int = 0
## Why the solid is not used ("" while it builds or once it is built).
var refused: String = ""
var _game: Node = null
var _solid: Object = null
var _task: int = -1
var _ready: bool = false
## Instance ids of the bodies in the solid, and their RIDs (an excluded one means the solid is not the space).
var _in_solid: Dictionary = {}
var _rids: Dictionary = {}
var _movers: Array = []
var _scanned_at: int = -1000000
var _local_bounds: Dictionary = {}

## Binds [param native] (a GSSimSightRay just bound to the physics space) to the solid of [param game]'s map,
## started on the first bind there. Nothing while it builds, when it is refused, or without bind_solid.
static func bind(native: Object, game: Object, mask: int, exclude: Array, tick: int) -> void:
	if not enabled or not native.has_method(&"bind_solid"):
		return
	var map: Variant = game.get("map")
	var root: Variant = (map as Object).get("collision_root") if map is Object else null
	if not root is Node3D or not (root as Node3D).is_inside_tree():
		return
	var held: RefCounted = held_for(root as Node3D)
	if held == null or int(held.get(&"mask")) != mask:
		for stale: int in _by_root.keys():
			if not is_instance_id_valid(stale):
				_by_root.erase(stale)
		held = start(root as Node3D, mask, game as Node)
		if held == null:
			return
		_by_root[(root as Node3D).get_instance_id()] = held
	var solid: Object = held.call(&"solid", exclude)
	if solid == null:
		return
	var movers: PackedVector3Array = held.call(&"movers", tick)
	if str(held.get(&"refused")) == "":
		native.call(&"bind_solid", solid, movers)

## The solid of [param root] (null before its first bind).
static func held_for(root: Node3D) -> RefCounted:
	return _by_root.get(root.get_instance_id()) if root != null else null

## Starts building the solid of [param p_root]'s bodies on [param p_mask]; null when the library has no solid.
static func start(p_root: Node3D, p_mask: int, game: Node) -> RefCounted:
	if not ClassDB.class_exists(&"GSSimSolid"):
		return null
	var made: RefCounted = (load("res://game/fc_bot_sight_solid.gd") as GDScript).new()
	made.root = p_root
	made.mask = p_mask
	made._game = game if game.is_ancestor_of(p_root) else p_root
	made._begin()
	return made

func _begin() -> void:
	var hulls: Array = []
	var faces: Array = []
	for node in root.find_children("*", "CollisionObject3D", true, false):
		var body := node as CollisionObject3D
		if body is Area3D or body.collision_layer & mask == 0:
			continue
		if not body is StaticBody3D or body is AnimatableBody3D:
			continue
		if not _gather(body, hulls, faces):
			return
		_in_solid[body.get_instance_id()] = true
		_rids[body.get_rid()] = true
	_solid = ClassDB.instantiate(&"GSSimSolid")
	_task = WorkerThreadPool.add_task(_build.bind(_solid, hulls, faces), false, "bot sight solid")

## The body's enabled shapes as hulls ([Transform3D, points]) and faces ([Transform3D, faces, two-sided]);
## false (the solid refused) for a shape the native solid does not model.
func _gather(body: CollisionObject3D, hulls: Array, faces: Array) -> bool:
	var xform := body.global_transform
	for owner_id in body.get_shape_owners():
		if body.is_shape_owner_disabled(owner_id):
			continue
		var placed := xform * body.shape_owner_get_transform(owner_id)
		for i in body.shape_owner_get_shape_count(owner_id):
			var shape: Shape3D = body.shape_owner_get_shape(owner_id, i)
			if shape is ConvexPolygonShape3D:
				hulls.append([placed, (shape as ConvexPolygonShape3D).points])
			elif shape is ConcavePolygonShape3D:
				var concave := shape as ConcavePolygonShape3D
				faces.append([placed, concave.get_faces(), concave.backface_collision])
			elif shape is BoxShape3D:
				var half := (shape as BoxShape3D).size * 0.5
				var corners := PackedVector3Array()
				for c in 8:
					corners.append(Vector3(half.x if c & 1 else -half.x, half.y if c & 2 else -half.y,
							half.z if c & 4 else -half.z))
				hulls.append([placed, corners])
			else:
				refused = "%s on %s" % [shape.get_class(), body.name]
				return false
	return true

## On a worker: the solid's only user until [method _build] returns.
static func _build(solid: Object, hulls: Array, faces: Array) -> void:
	for hull in hulls:
		solid.call(&"add_hull", hull[0], hull[1])
	for face in faces:
		solid.call(&"add_faces", face[0], face[1], face[2])
	solid.call(&"build")

## The built solid, or null while it builds or when refused (or [param exclude] holds a body in it).
func solid(exclude: Array) -> Object:
	if not _ready:
		if _task < 0 or not WorkerThreadPool.is_task_completed(_task):
			return null
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_ready = true
	if refused != "":
		return null
	for rid in exclude:
		if _rids.has(rid):
			return null
	return _solid

## Low and high corners of every body on the mask outside the solid, as placed now (rescanned every
## [constant RESCAN_TICKS] ticks: a body added since is bounded from the next scan).
func movers(tick: int) -> PackedVector3Array:
	if tick - _scanned_at >= RESCAN_TICKS or tick < _scanned_at:
		_scanned_at = tick
		_movers.clear()
		var kept := 0
		for node in _game.find_children("*", "CollisionObject3D", true, false):
			var body := node as CollisionObject3D
			if _in_solid.has(body.get_instance_id()):
				kept += 1
			elif not body is Area3D and body.collision_layer & mask != 0:
				_movers.append(body)
		if kept != _in_solid.size():
			# A body of the solid left (a broken brush): the solid no longer answers as the space.
			refused = "solid body freed"
	var out := PackedVector3Array()
	for held: Variant in _movers:
		if not is_instance_valid(held):
			continue
		var body := held as CollisionObject3D
		if not body.is_inside_tree() or body.collision_layer & mask == 0:
			continue
		var xform := body.global_transform
		for owner_id in body.get_shape_owners():
			if body.is_shape_owner_disabled(owner_id):
				continue
			var placed := xform * body.shape_owner_get_transform(owner_id)
			for i in body.shape_owner_get_shape_count(owner_id):
				var box := placed * _bounds_of(body.shape_owner_get_shape(owner_id, i))
				out.append(box.position)
				out.append(box.end)
	return out

func _bounds_of(shape: Shape3D) -> AABB:
	var key := shape.get_instance_id()
	if not _local_bounds.has(key):
		var mesh := shape.get_debug_mesh()
		_local_bounds[key] = mesh.get_aabb().grow(0.01) if mesh != null else AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	return _local_bounds[key]
