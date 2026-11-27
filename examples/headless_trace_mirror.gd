extends GSGameCheckSuite

const FcMap := preload("../maps/fc_map.gd")
const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcTraceMirror := preload("../game/fc_trace_mirror.gd")

## gs-sim's collision mirror (`GSSimTraceMirror`, cvar `sv_trace_mirror`) against Godot Physics on the same
## solid: seeded rays (`intersect_ray`), box hulls (`cast_motion`) and points (`intersect_point`) on box, pit,
## an imported deathmatch map, a surf map and cp-orange-x3. Every ray agrees on hit or miss, its fraction within
## 1e-3 and its normal within 1 degree; every hull's contact lies in Godot's [safe, unsafe] bracket (1e-3 slack);
## every point agrees on solid or open. Prints the microseconds per ray of each, as asked from script. Imported
## maps skip (say so) when not linked; the whole suite skips without gs-sim's library.

const SEED := 20261126
const RAYS := 10000
const HULLS := 3000
const POINTS := 3000
const MASK := 0xFFFFFFFF
const FRACTION_EPS := 1e-3
const NORMAL_DEG := 1.0
## Player hull and a small item hull (half extents).
const HULL_HALVES: Array[Vector3] = [Vector3(0.4, 0.9, 0.4), Vector3(0.15, 0.15, 0.15)]
const IMPORTED: Array[StringName] = [&"dm-industrial-gamma", &"surf_ski_2", &"cp-orange-x3"]

var _sections := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("trace mirror — gs-sim's BVH against Godot Physics, seeded rays, hulls and points")
	if not GSSim.has(&"trace_mirror"):
		print("no GSSimTraceMirror (gs-sim library not installed) — nothing to compare")
		_report_sections(0, 0, 0, -1)
		return

	_sections += 1
	_test_fallback()
	_finished += 1

	await _compare("box", FcMap.dm_box())
	await _compare("pit", FcMap.dm_pit())
	for id in IMPORTED:
		if not FcImportedMaps.has(id):
			print("-- %s: not linked under maps/imported* — skipped" % id)
			continue
		await _compare(String(id), FcMap.by_id(id))

	_report_sections(_sections, _finished, _sections, -1)


## The cvar at 0 hands every caller the physics space; at 1 the mirror is built once per root.
func _test_fallback() -> void:
	print("-- sv_trace_mirror: 0 falls back, 1 builds once per map")
	var root := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	root.add_child(shape)
	add_child(root)
	FcTraceMirror.reset()
	FcTraceMirror.enabled = false
	_check(FcTraceMirror.of(root) == null, "at 0 there is no mirror (every ray asks the space)")
	FcTraceMirror.enabled = true
	var first: Object = FcTraceMirror.of(root)
	_check(first != null and FcTraceMirror.of(root) == first, "at 1 one mirror serves every ask on the map")
	_check(FcTraceMirror.of(null) == null, "no map, no mirror")
	FcTraceMirror.reset()
	remove_child(root)
	root.free()


func _compare(label: String, map: FcMap) -> void:
	_sections += 1
	print("-- %s" % label)
	var solid := map.to_collision()
	add_child(solid)
	await get_tree().physics_frame
	await get_tree().physics_frame

	FcTraceMirror.reset()
	var mirror: Object = FcTraceMirror.of(solid)
	var stats: Dictionary = mirror.call(&"stats") if mirror != null else {}
	print("     mirror: %s" % [stats])
	if not _check(mirror != null and int(stats.get("pieces", 0)) > 0, "%s: the mirror holds the map's solid" % label):
		remove_child(solid)
		solid.free()
		return

	var bounds := _bounds(solid)
	var starts := _starts(map, bounds)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED ^ label.hash()
	var space := get_viewport().get_world_3d().direct_space_state

	_compare_rays(label, mirror, space, rng, bounds, starts)
	_compare_hulls(label, mirror, space, rng, starts)
	_compare_points(label, mirror, space, rng, bounds)

	FcTraceMirror.reset()
	remove_child(solid)
	solid.free()
	_finished += 1


func _compare_rays(label: String, mirror: Object, space: PhysicsDirectSpaceState3D, rng: RandomNumberGenerator,
		bounds: AABB, starts: PackedVector3Array) -> void:
	var froms := PackedVector3Array()
	var tos := PackedVector3Array()
	froms.resize(RAYS)
	tos.resize(RAYS)
	var reach := maxf(bounds.size.length() * 0.5, 10.0)
	for k in RAYS:
		# Three in four from where a player stands (sight and wall rays), the rest anywhere in the map.
		var from := starts[rng.randi() % starts.size()] if k % 4 != 3 else _inside(rng, bounds)
		froms[k] = from
		tos[k] = from + _direction(rng) * rng.randf_range(0.5, reach)

	var query := PhysicsRayQueryParameters3D.new()
	query.collision_mask = MASK
	var godot: Array[Dictionary] = []
	godot.resize(RAYS)
	var t0 := Time.get_ticks_usec()
	for k in RAYS:
		query.from = froms[k]
		query.to = tos[k]
		godot[k] = space.intersect_ray(query)
	var godot_us := float(Time.get_ticks_usec() - t0) / RAYS

	var mine: Array[Dictionary] = []
	mine.resize(RAYS)
	t0 = Time.get_ticks_usec()
	for k in RAYS:
		mine[k] = mirror.call(&"ray", froms[k], tos[k], MASK)
	var mirror_us := float(Time.get_ticks_usec() - t0) / RAYS
	t0 = Time.get_ticks_usec()
	var batch: Dictionary = mirror.call(&"rays", froms, tos, MASK)
	var batch_us := float(Time.get_ticks_usec() - t0) / RAYS

	var hits := 0
	var bad := PackedStringArray()
	var worst_fraction := 0.0
	var worst_degrees := 0.0
	var batch_bad := 0
	var fractions: PackedFloat64Array = batch.get("fraction", PackedFloat64Array())
	for k in RAYS:
		var g := godot[k]
		var m := mine[k]
		var length := froms[k].distance_to(tos[k])
		var gf := froms[k].distance_to(g["position"]) / length if not g.is_empty() else 1.0
		var mf := float(m["fraction"]) if not m.is_empty() else 1.0
		if k < fractions.size() and absf(fractions[k] - mf) > 1e-9:
			batch_bad += 1
		if g.is_empty() != m.is_empty():
			bad.append("ray %d %s -> %s: godot %s, mirror %s" % [k, froms[k], tos[k],
				"miss" if g.is_empty() else "hit at %.5f n %s" % [gf, g["normal"]],
				"miss" if m.is_empty() else "hit at %.5f n %s" % [mf, m["normal"]]])
			continue
		if g.is_empty():
			continue
		hits += 1
		var df := absf(gf - mf)
		var gn: Vector3 = g["normal"]
		var mn: Vector3 = m["normal"]
		var degrees := rad_to_deg(gn.angle_to(mn))
		worst_fraction = maxf(worst_fraction, df)
		worst_degrees = maxf(worst_degrees, degrees)
		if df > FRACTION_EPS or degrees > NORMAL_DEG:
			bad.append("ray %d %s -> %s: fraction %.5f vs %.5f, normal %s vs %s (%.2f deg)" % [k, froms[k], tos[k],
				gf, mf, gn, mn, degrees])

	print("     rays: %d (%d hit), worst fraction %.6f, worst normal %.3f deg" % [RAYS, hits, worst_fraction, worst_degrees])
	print("     us per ray: mirror %.2f (batch %.2f), godot %.2f" % [mirror_us, batch_us, godot_us])
	for line in bad.slice(0, 6):
		print("       " + line)
	_check(bad.is_empty(), "%s: %d rays agree with Godot on hit, fraction and normal (%d off)" % [label, RAYS, bad.size()])
	_check(batch_bad == 0, "%s: the batch answers every ray as the single ray does (%d off)" % [label, batch_bad])


func _compare_hulls(label: String, mirror: Object, space: PhysicsDirectSpaceState3D, rng: RandomNumberGenerator,
		starts: PackedVector3Array) -> void:
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = MASK
	var bad := PackedStringArray()
	var hits := 0
	var solid_starts := 0
	for k in HULLS:
		var half := HULL_HALVES[k % HULL_HALVES.size()]
		var box := BoxShape3D.new()
		box.size = half * 2.0
		query.shape = box
		var from := starts[rng.randi() % starts.size()] + Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(0.0, 1.5),
			rng.randf_range(-1.0, 1.0))
		var motion := _direction(rng) * rng.randf_range(0.2, 8.0)
		query.transform = Transform3D(Basis.IDENTITY, from)
		query.motion = motion
		var bracket := space.cast_motion(query)
		var got: Dictionary = mirror.call(&"cast_box", from, motion, half, MASK)
		var f := float(got["fraction"])
		if bracket[1] < 1.0:
			hits += 1
		if bracket[0] == 0.0 and bracket[1] == 0.0:
			solid_starts += 1
		var lo := float(bracket[0]) - FRACTION_EPS
		var hi := float(bracket[1]) + FRACTION_EPS
		if f < lo or f > hi:
			bad.append("hull %d %s half %s motion %s: godot [%.5f, %.5f], mirror %.5f%s" % [k, from, half, motion,
				bracket[0], bracket[1], f, " (start solid)" if got["start_solid"] else ""])
	print("     hulls: %d (%d hit, %d start in solid)" % [HULLS, hits, solid_starts])
	for line in bad.slice(0, 6):
		print("       " + line)
	_check(bad.is_empty(), "%s: %d box sweeps land in Godot's safe/unsafe bracket (%d off)" % [label, HULLS, bad.size()])


func _compare_points(label: String, mirror: Object, space: PhysicsDirectSpaceState3D, rng: RandomNumberGenerator,
		bounds: AABB) -> void:
	var query := PhysicsPointQueryParameters3D.new()
	query.collision_mask = MASK
	var bad := PackedStringArray()
	var solid := 0
	for k in POINTS:
		var at := _inside(rng, bounds)
		query.position = at
		var godot := not space.intersect_point(query, 1).is_empty()
		var mine := int(mirror.call(&"point_contents", at, MASK)) != 0
		if godot:
			solid += 1
		if godot != mine:
			bad.append("point %d %s: godot %s, mirror %s" % [k, at, godot, mine])
	print("     points: %d (%d in solid)" % [POINTS, solid])
	for line in bad.slice(0, 6):
		print("       " + line)
	_check(bad.is_empty(), "%s: %d points agree with Godot on solid or open (%d off)" % [label, POINTS, bad.size()])


## Where rays and hulls start: the map's spawns at eye height, else points in its bounds.
func _starts(map: FcMap, bounds: AABB) -> PackedVector3Array:
	var out := PackedVector3Array()
	for at: Transform3D in map.spawns:
		out.append(at.origin + Vector3.UP * 1.6)
	if out.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.seed = SEED
		for k in 64:
			out.append(_inside(rng, bounds))
	return out


## The world box of every collision shape under [param root].
func _bounds(root: Node) -> AABB:
	var box := AABB()
	var first := true
	for node in root.find_children("*", "CollisionShape3D", true, false):
		var cs := node as CollisionShape3D
		if cs.shape == null:
			continue
		var points := PackedVector3Array()
		if cs.shape is BoxShape3D:
			var h := (cs.shape as BoxShape3D).size * 0.5
			points = PackedVector3Array([-h, h])
		elif cs.shape is ConvexPolygonShape3D:
			points = (cs.shape as ConvexPolygonShape3D).points
		elif cs.shape is ConcavePolygonShape3D:
			points = (cs.shape as ConcavePolygonShape3D).get_faces()
		for p in points:
			var w := cs.global_transform * p
			if first:
				box = AABB(w, Vector3.ZERO)
				first = false
			else:
				box = box.expand(w)
	return box.grow(2.0)


func _inside(rng: RandomNumberGenerator, bounds: AABB) -> Vector3:
	return bounds.position + Vector3(rng.randf(), rng.randf(), rng.randf()) * bounds.size


func _direction(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf() * TAU
	var r := sqrt(1.0 - z * z)
	return Vector3(r * cos(a), z, r * sin(a))
