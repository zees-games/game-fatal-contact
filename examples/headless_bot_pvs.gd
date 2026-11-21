extends GSGameCheckSuite

const FcMap := preload("../maps/fc_map.gd")
const FcBspMap := preload("../maps/fc_bsp_map.gd")
const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcBotPvs := preload("../game/fc_bot_pvs.gd")

## The bots' PVS pre-cull (FcBotPvs, cvar `fc_bot_pvs`): on converted maps with vis data, dot-sim's native
## `GSSimPvs` gives the same cluster and the same answer as dot-net's script `GSNetVisibility` for seeded points
## (around the spawns and anywhere in the map's box, with and without bounds), `visible_many` agrees pair for pair, and
## the wrapper in verify mode counts no disagreement. Skips (exit 0, says so) a map that is not linked; without the
## library only the script set is exercised. The rays a ruled-out pair saves are checked live by scale128 `--pvsverify 1`
## (`ruled_out_clear`).

const MAPS: Array[StringName] = [&"cp-orange-x3", &"crackhouse", &"dm-industrial-gamma", &"dm-scarletdevilmansion"]
const PAIRS := 4000
const SEED := 1117


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC — bot PVS: native and script sets agree")
	var native := GSSim.has(&"pvs")
	if not native:
		print("dot-sim has no pvs module: only the script set is exercised")
	var tried := 0
	for id in MAPS:
		if not FcImportedMaps.has(id):
			print("no %s linked — skipped" % id)
			continue
		var map: FcMap = FcMap.by_id(id)
		var prefix := FcBspMap.world_prefix(String(map.id), String(map.manifest_path).get_base_dir())
		var got: GSResult = GSMapBspMesh.load_prefix(prefix)
		if not _check(got != null and got.ok, "%s: the converted world loads" % id):
			continue
		var box := AABB(map.spawns[0].origin, Vector3.ZERO) if map.spawns.size() > 0 else AABB()
		for s in map.spawns:
			box = box.expand(s.origin)
		box = box.grow(24.0)
		for bounds in [AABB(), box.grow(-12.0)]:
			var vis: GSNetVisibility = GSNetVisibility.from_dot_map_mesh(got.value, bounds)
			if not _check(vis != null and vis.is_ready(), "%s: the map has a PVS" % id):
				break
			tried += 1
			_compare(id, map, vis, box, native, bounds.has_volume())
	_check(tried > 0 or MAPS.all(func(m: StringName) -> bool: return not FcImportedMaps.has(m)), "at least one map was compared")
	_report(-1)


func _compare(id: StringName, map: FcMap, vis: GSNetVisibility, box: AABB, native: bool, bounded: bool) -> void:
	var tag := "%s%s" % [id, " (bounded)" if bounded else ""]
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var points := PackedVector3Array()
	for i in PAIRS * 2:
		var p: Vector3
		if i % 2 == 0 and map.spawns.size() > 0:
			p = map.spawns[rng.randi_range(0, map.spawns.size() - 1)].origin + Vector3(rng.randf_range(-6, 6), rng.randf_range(0, 2), rng.randf_range(-6, 6))
		else:
			p = box.position + Vector3(rng.randf(), rng.randf(), rng.randf()) * box.size
		points.append(p)
	var blocked := 0
	for i in PAIRS:
		if not vis.visible(points[i * 2], points[i * 2 + 1]):
			blocked += 1
	print("  %s: %d clusters, %d of %d pairs ruled out" % [tag, vis.clusters, blocked, PAIRS])
	_check(blocked < PAIRS, "%s: the set does not rule out every pair" % tag)
	if not native:
		return
	var set: Object = ClassDB.instantiate(&"GSSimPvs")
	_check(bool(set.call(&"load", vis.native_dict())) and bool(set.call(&"is_ready")) and int(set.call(&"serial")) == vis.serial,
		"%s: GSSimPvs loads the set" % tag)
	var cluster_diff := 0
	for p in points:
		if int(set.call(&"cluster_of", p)) != vis.cluster_of(p):
			cluster_diff += 1
	_check(cluster_diff == 0, "%s: the same cluster for %d points" % [tag, points.size()], "%d differ" % cluster_diff)
	var seen_diff := 0
	for i in PAIRS:
		if bool(set.call(&"visible", points[i * 2], points[i * 2 + 1])) != vis.visible(points[i * 2], points[i * 2 + 1]):
			seen_diff += 1
	_check(seen_diff == 0, "%s: the same answer for %d pairs" % [tag, PAIRS], "%d differ" % seen_diff)
	var many: PackedByteArray = set.call(&"visible_many", points)
	var many_diff := 0
	for i in PAIRS:
		if (many[i] == 1) != vis.visible(points[i * 2], points[i * 2 + 1]):
			many_diff += 1
	_check(many.size() == PAIRS and many_diff == 0, "%s: visible_many agrees pair for pair" % tag, "%d differ" % many_diff)
	# The wrapper the bots use: bound off a game's meta, native, verify mode counting disagreements.
	var game := Node.new()
	game.set_meta(FcBotPvs.META, vis)
	var pvs := FcBotPvs.new()
	var was := [FcBotPvs.verify, FcBotPvs.counting]
	FcBotPvs.verify = true
	FcBotPvs.counting = true
	FcBotPvs.reset_stats()
	pvs.bind(game)
	var wrap_diff := 0
	for i in PAIRS:
		if pvs.open(points[i * 2], points[i * 2 + 1]) != vis.visible(points[i * 2], points[i * 2 + 1]):
			wrap_diff += 1
	_check(pvs.active != null and pvs.active != vis, "%s: the bots' wrapper binds the native set" % tag)
	_check(wrap_diff == 0 and FcBotPvs.stats[3] == 0 and FcBotPvs.stats[0] == PAIRS and FcBotPvs.stats[1] == blocked,
		"%s: the wrapper answers as the script and verify counts no mismatch" % tag, str(FcBotPvs.stats))
	FcBotPvs.verify = was[0]
	FcBotPvs.counting = was[1]
	FcBotPvs.reset_stats()
	game.free()
