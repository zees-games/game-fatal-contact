extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcBotsWorld := preload("../game/fc_bots_world.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcBotSightSolid := preload("../game/fc_bot_sight_solid.gd")

## The bots' native sight on the built-in maps: on a box world (GSTraceFlat) the world binds gs-sim's
## GSSimSightRay to the trace's own box hierarchy (bind_flat), so a native mind asks its rays with no call into
## script. Over seeded random eye and target points through each map, the native answer (one ray and the batched
## clear_many) is the world's line_of_sight and the trace's, to the bit; cvar bot_native_sight 0 hands the script
## callable. Without the gs-sim library (or one without bind_flat) only the script answers are checked, and it says so.
## On imported maps (linked ones only) the world binds the map's static solid (GSSimSolid, bind_solid, built on a
## worker) behind the physics space: over seeded lines between spawn-area points the native answer is the engine
## ray's ([code]_sight_ray[/code]) but for at most [constant GRAZE_SHARE] grazing lines (an edge or a face's plane
## met within float error), and it prints both timings.
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
## Imported maps: their ids, checks per linked map with the native solid, and the grazing lines allowed.
const IMPORTED: Array[StringName] = [&"cp-orange-x3", &"crackhouse", &"surf_10x_final"]
const IMPORTED_CHECKS := 6
const GRAZE_SHARE := 0.005

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
	var linked := 0
	var solid := _native and ClassDB.class_exists(&"GSSimSolid") and ClassDB.class_has_method(&"GSSimSightRay", &"bind_solid")
	if not solid:
		print("no gs-sim library with GSSimSightRay.bind_solid: imported maps skipped")
	for id in IMPORTED:
		if not solid:
			break
		if not FcImportedMaps.has(id):
			print("no %s linked: skipped" % id)
			continue
		linked += 1
		await _imported(id)
	_report(MAPS.size() * (NATIVE_CHECKS if _native else SCRIPT_CHECKS) + linked * IMPORTED_CHECKS)


func _imported(id: StringName) -> void:
	var game := FcGame.new()
	game.tick_rate = TICK_RATE
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var map: FcMap = FcMap.by_id(id)
	var ok := map != null and game.setup(map).ok
	_check(ok, "%s: the game sets up" % id)
	if not ok:
		game.queue_free()
		return
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var world := FcBots.world_for(game)
	var trace: Variant = game.combat.trace
	var physics := trace is GSTracePhysics
	_check(physics, "%s: the map's trace is the physics one" % id, str(trace))
	if not physics:
		game.queue_free()
		return
	var sight: Callable = world._sight_bind()
	var ray: Object = sight.get_object()
	var frames := 0
	while ray != null and ray.is_class("GSSimSightRay") and not bool(ray.call(&"is_solid")) and frames < 2400:
		await get_tree().process_frame
		frames += 1
		sight = world._sight_bind()
		ray = sight.get_object()
	var built := ray != null and ray.is_class("GSSimSightRay") and bool(ray.call(&"is_solid"))
	var held := FcBotSightSolid.held_for(game.map.collision_root)
	var why: Variant = held.get(&"refused") if held != null else "no solid"
	_check(built, "%s: the native ray is bound to the map's solid" % id, "after %d frames: %s" % [frames, str(why)])
	if not built:
		game.queue_free()
		return
	var box := AABB(map.spawns[0].origin, Vector3.ZERO) if map.spawns.size() > 0 else AABB(Vector3.ZERO, Vector3.ONE)
	for s in map.spawns:
		box = box.expand(s.origin)
	box = box.grow(8.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var froms := PackedVector3Array()
	var tos := PackedVector3Array()
	for k in RAYS:
		froms.append(box.position + box.size * Vector3(rng.randf(), rng.randf(), rng.randf()))
		tos.append(box.position + box.size * Vector3(rng.randf(), rng.randf(), rng.randf()))
	var engine := PackedByteArray()
	engine.resize(froms.size())
	var t0 := Time.get_ticks_usec()
	for k in froms.size():
		engine[k] = 1 if world._sight_ray(trace as GSTracePhysics, froms[k], tos[k]) else 0
	var engine_us := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	var native: PackedByteArray = ray.call(&"clear_many", froms, tos)
	var native_us := Time.get_ticks_usec() - t0
	var differ := 0
	var blocked := 0
	for k in froms.size():
		if native[k] != engine[k]:
			differ += 1
		if engine[k] == 0:
			blocked += 1
	print("%s: %d lines, engine %.3f ms, native solid %.3f ms, %d differ, %d blocked" % [id, froms.size(),
			engine_us / 1000.0, native_us / 1000.0, differ, blocked])
	_check(differ <= int(froms.size() * GRAZE_SHARE),
			"%s: the native solid answers as the engine on %d random lines" % [id, froms.size()],
			"%d differ, %d blocked" % [differ, blocked])
	_check(blocked > froms.size() / 20 and blocked < froms.size() * 19 / 20,
			"%s: the lines both see and are blocked" % id, "%d blocked" % blocked)
	FcBotSightSolid.enabled = false
	var off: Object = world._sight_bind().get_object()
	FcBotSightSolid.enabled = true
	_check(off != null and off.is_class("GSSimSightRay") and not bool(off.call(&"is_solid")),
			"%s: native_solid off binds the engine ray" % id, str(off))
	game.queue_free()
	await get_tree().process_frame


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
