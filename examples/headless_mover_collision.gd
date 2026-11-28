extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcBspMap := preload("../maps/fc_bsp_map.gd")

## Door collision follows the door: a sliding door, a swinging jail door opened by its button, and a toggled brush
## each stop a player when shut and let one through when open. The importer also bakes these brushes into the static
## world at their compiled pose; that copy is released, so an opened door no longer leaves its collision behind.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mover_collision.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_CHECKS := 30
## map, door entity, how it opens, how it shuts. An input name is sent to the door; "button:N" presses entity N.
const CASES := [
	[&"surf_10x_final", 143, "Open", "Close", "a sliding door (func_door)"],
	[&"surf_10x_reloaded_fixed", 308, "button:271", "Close", "a swinging jail door (func_door_rotating)"],
	[&"surf_ski_2_source", 178, "Disable", "Enable", "a toggled brush (func_brush)"],
]

var _checks := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _run() -> void:
	for c: Array in CASES:
		if FcMap.imported(c[0]) == null:
			print("  skip  %s is not linked (fc-surf-dm-maps)" % c[0])
			get_tree().quit(0)
			return
	for c: Array in CASES:
		await _case(c[0], int(c[1]), str(c[2]), str(c[3]), str(c[4]))
	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _case(id: StringName, door_index: int, open: String, shut: String, what: String) -> void:
	print("%s on %s" % [what, id])
	var game := FcGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = FcMode.team_deathmatch()
	game.mode.player_props = true
	add_child(game)
	var ready := game.setup(FcMap.imported(id))
	game.start(0)
	var _a := game.add_player(21, "A")
	game.tick({})
	var mio = game.map_io
	_check(ready.ok and mio != null, "the map sets up with a mover world", str(ready.error))
	if mio == null:
		game.queue_free()
		return
	var world: GSMapWorld = mio.world
	var door: GSMapEntity = world.io.entity_of(door_index)
	var model := int(door.key("model").trim_prefix("*"))
	var shut_box := AABB()
	for h: Dictionary in world.mesh.hull_shapes(model):
		var b := FcBspMap._box_of((h["shape"] as ConvexPolygonShape3D).points, world.mesh.model_origin(model))
		shut_box = b if shut_box.size == Vector3.ZERO else shut_box.merge(b)
	_check(shut_box.size.length() > 0.5, "the door has a body to stand in the way", str(shut_box))
	var released := FcBspMap.release_mover_hulls(game.map.collision_root, world)
	# The map's own setup already released them; a second pass finds none left on.
	_check(released == 0, "its baked-in hull was released when the map set up", str(released))
	var probe := _probe(shut_box)
	_check(_blocked(game, probe), "shut, it stops a player in the doorway")
	_check(game.props != null and _blocked(game, probe, &"prop"), "shut, it stops a prop in the doorway")
	_check(game.props != null and game.props.get("_collision") == null, "props share the game's solid, no second copy")
	_nav_check(game, shut_box)
	if open.begins_with("button:"):
		var button: GSMapEntity = world.io.entity_of(int(open.trim_prefix("button:")))
		var eye: Vector3 = button.origin(world.io) + Vector3(0.0, 1.0, 0.0)
		game.player_for(21).controller.state.position = eye - Vector3(0.0, 1.6, 0.0)
		var _p: bool = mio.press_for(_AimAt.new(eye, button.origin(world.io) - eye), 21)
	else:
		var _s := world.io.send(door.key("targetname"), open)
	_check(await _until(game, probe, false), "opened, the doorway lets a player through")
	_check(not _blocked(game, probe, &"prop"), "opened, the doorway lets a prop through")
	var _c := world.io.send(door.key("targetname"), shut)
	_check(await _until(game, probe, true), "shut again, it stops the player again")
	_check(_blocked(game, probe, &"prop"), "shut again, it stops a prop again")
	game.queue_free()
	await get_tree().physics_frame


## A box a third the door's size at its shut centre: inside the door when shut, in the open doorway when not.
func _probe(box: AABB) -> AABB:
	var size := (box.size / 3.0).max(Vector3(0.02, 0.02, 0.02))
	return AABB(box.get_center() - size * 0.5, size)


## The bots' nav source leaves out the hulls the movers released.
func _nav_check(game: FcGame, shut_box: AABB) -> void:
	var root := game.map.collision_root as Node3D
	var enabled := 0
	var disabled := 0
	for n in root.find_children("*", "CollisionShape3D", true, false):
		if (n as CollisionShape3D).disabled:
			disabled += 1
		else:
			enabled += 1
	var holder: Node3D = game.map.nav_source()
	var copied := 0
	if holder != null:
		copied = holder.find_children("*", "CollisionShape3D", true, false).size()
		holder.get_parent().remove_child(holder)
		holder.free()
	_check(disabled > 0 and holder != null and copied < enabled + disabled and copied <= enabled,
		"the bot nav source skips the released hulls", "enabled %d, released %d, copied %d" % [enabled, disabled, copied])


func _blocked(game: FcGame, probe: AABB, layer: StringName = &"player") -> bool:
	var space := (game.map.collision_root as Node3D).get_world_3d().direct_space_state
	var shape := BoxShape3D.new()
	shape.size = probe.size
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis.IDENTITY, probe.get_center())
	q.collision_mask = GSPhysicsLayout.shooter_3d().collision_mask(layer)
	return not space.intersect_shape(q, 4).is_empty()


## Ticks the game for up to six seconds until the doorway is [param blocked] or not.
func _until(game: FcGame, probe: AABB, blocked: bool) -> bool:
	for _k in TICK_RATE * 6:
		game.tick({})
		await get_tree().physics_frame
		if _blocked(game, probe) == blocked:
			return true
	return false


## Stands in for a player looking along a direction.
class _AimAt:
	var at: Vector3
	var dir: Vector3

	func _init(pos: Vector3, look: Vector3) -> void:
		at = pos
		dir = look.normalized()

	func muzzle_position() -> Vector3:
		return at

	func aim_direction() -> Vector3:
		return dir
