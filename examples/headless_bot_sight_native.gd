extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcBotsWorld := preload("../game/fc_bots_world.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")

## The bots' native sight on the built-in maps: on a box world (GSTraceFlat) the world binds gs-sim's
## GSSimSightRay to the trace's own box hierarchy (bind_flat), so a native mind asks its rays with no call into
## script. Over seeded random eye and target points through each map, the native answer (one ray and the batched
## clear_many) is the world's line_of_sight and the trace's, to the bit; cvar bot_native_sight 0 hands the script
## callable. Without the gs-sim library (or one without bind_flat) only the script answers are checked, and it says so.
##
## [codeblock]
## godot --headless --path . res://examples/headless_bot_sight_native.tscn
## [/codeblock]

const TICK_RATE := 64
const MAPS: Array[StringName] = [&"dm_box", &"dm_pit", &"dm_atrium"]
const RAYS := 4000
const SEED := 0x51647

## Checks per map with the native ray, and without it.
const NATIVE_CHECKS := 7
const SCRIPT_CHECKS := 3

var _native := false


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless bot sight native")
	_native = ClassDB.class_exists(&"GSSimSightRay") and ClassDB.class_exists(&"GSSimFlatBvh") \
			and ClassDB.class_has_method(&"GSSimSightRay", &"bind_flat")
	if not _native:
		print("no gs-sim library with GSSimSightRay.bind_flat: script answers only")
	for id in MAPS:
		await _map(id)
	_report(MAPS.size() * (NATIVE_CHECKS if _native else SCRIPT_CHECKS))


func _map(id: StringName) -> void:
	var game := FcGame.new()
	game.tick_rate = TICK_RATE
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var ok := game.setup(FcMap.by_id(id)).ok
	_check(ok, "%s: the game sets up" % id)
	if not ok:
		game.queue_free()
		return
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var world := FcBots.world_for(game)
	var trace: Variant = game.combat.trace
	_check(trace is GSTraceFlat, "%s: the map's trace is the box world" % id, str(trace))
	if not trace is GSTraceFlat:
		game.queue_free()
		return
	var flat := trace as GSTraceFlat
	var pairs := _pairs(flat)
	var froms: PackedVector3Array = pairs[0]
	var tos: PackedVector3Array = pairs[1]
	var want := PackedByteArray()
	want.resize(froms.size())
	var same_world := 0
	var blocked := 0
	for k in froms.size():
		var seen := flat.line_of_sight(froms[k], tos[k])
		want[k] = 1 if seen else 0
		if world.line_of_sight(froms[k], tos[k]) == seen:
			same_world += 1
		if not seen:
			blocked += 1
	_check(same_world == froms.size(), "%s: the world's line_of_sight is the trace's" % id,
			"%d of %d" % [same_world, froms.size()])
	if not _native:
		game.queue_free()
		return
	FcBotsWorld.World.native_sight = true
	var sight: Callable = world._sight_bind()
	var ray: Object = sight.get_object()
	_check(ray != null and ray.is_class("GSSimSightRay") and bool(ray.call(&"is_flat")),
			"%s: the native ray is bound to the box world" % id, str(ray))
	if ray == null or not ray.has_method(&"clear_many"):
		game.queue_free()
		return
	var same := 0
	for k in froms.size():
		if bool(sight.call(froms[k], tos[k])) == (want[k] == 1):
			same += 1
	var batch: PackedByteArray = ray.call(&"clear_many", froms, tos)
	_check(same == froms.size() and blocked > froms.size() / 20 and blocked < froms.size() * 19 / 20,
			"%s: the native ray answers as the trace on %d random lines" % [id, froms.size()],
			"%d the same, %d blocked" % [same, blocked])
	_check(batch == want, "%s: the batched clear_many answers as the trace" % id)
	FcBotsWorld.World.native_sight = false
	var off: Callable = world._sight_bind()
	FcBotsWorld.World.native_sight = true
	_check(off.get_object() == world and off.get_method() == &"line_of_sight",
			"%s: bot_native_sight 0 hands the script line_of_sight" % id, str(off))
	game.queue_free()
	await get_tree().process_frame


## Seeded eye and target points through the map's boxes: from a little under the ground to above the tallest box.
func _pairs(flat: GSTraceFlat) -> Array:
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	var corners: PackedVector3Array = flat.get("_corners")
	for c in corners:
		lo = lo.min(c)
		hi = hi.max(c)
	if flat.floor_y > -INF:
		lo.y = minf(lo.y, flat.floor_y)
	lo.y -= 0.5
	hi.y += 2.0
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var froms := PackedVector3Array()
	var tos := PackedVector3Array()
	for k in RAYS:
		var a := Vector3(rng.randf_range(lo.x, hi.x), rng.randf_range(lo.y, hi.y), rng.randf_range(lo.z, hi.z))
		# Every 50th line is very short (the 0.0001 m answer) and every 7th level (no ground hit).
		var b := Vector3(rng.randf_range(lo.x, hi.x), rng.randf_range(lo.y, hi.y), rng.randf_range(lo.z, hi.z))
		if k % 50 == 0:
			b = a + Vector3(0.00003, 0.0, 0.00004)
		elif k % 7 == 0:
			b.y = a.y
		froms.append(a)
		tos.append(b)
	return [froms, tos]
