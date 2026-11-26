extends "imported_base.gd"

## The map-volume skip (cvar `fc_mechanics_native`): gs-sim's `GSSimVolumes.clear_of` gives the script's
## `FcVolumePrefilter.clear_of_script` answer byte for byte over seeded boxes and points (faces, one step off them,
## inside, far, not finite), and on a converted map with ladders, water or pushes every tick a player was marked clear
## runs the full mechanics anyway (`mechanics_verify`) and changes nothing. Without the library only the script runs.

const FcMode := preload("../game/fc_mode.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcHullGrid := preload("../game/fc_hull_grid.gd")
const FcVolumePrefilter := preload("../game/fc_volume_prefilter.gd")

const POINTS := 20000
const SEED := 4243
const MAPS: Array[StringName] = [&"crackhouse", &"cp-orange-x3"]
## At least FcHullGrid.MIN_PLAYERS (the batched loop marks them all in one call) ...
const PLAYERS := 14
## ... and below it (the one-by-one loop asks per player, tick start and end).
const FEW_PLAYERS := 6
const ROUNDS := 120
const TICKS_PER_ROUND := 6


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC — map volume skip: native and script agree, and a skipped tick changes nothing")
	var native := GSSim.has(&"volumes")
	if not native:
		print("gs-sim has no volumes module: only the script lane is exercised")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var boxes: Array[AABB] = []
	for i in 40:
		var at := Vector3(rng.randf_range(-50, 50), rng.randf_range(-10, 10), rng.randf_range(-50, 50))
		var size := Vector3(rng.randf_range(-4, 6), rng.randf_range(-2, 4), rng.randf_range(-4, 6))
		boxes.append(AABB(at, size))
	var points := PackedVector3Array()
	for i in POINTS:
		points.append(_point(rng, boxes))
	var want := FcVolumePrefilter.clear_of_script(boxes, points, FcVolumePrefilter.BELOW, FcVolumePrefilter.ABOVE)
	var clear := want.count(1)
	print("  %d points, %d clear" % [POINTS, clear])
	_check(clear > POINTS / 10 and clear < POINTS - POINTS / 10, "the seeded points are both clear and near", "%d" % clear)
	var checks := 1
	if native:
		var vol: Object = ClassDB.instantiate(&"GSSimVolumes")
		vol.add_boxes(boxes)
		var got: PackedByteArray = vol.clear_of(points, FcVolumePrefilter.BELOW, FcVolumePrefilter.ABOVE)
		var diff := 0
		var first := ""
		for i in POINTS:
			if got[i] != want[i]:
				diff += 1
				if first == "":
					first = "%s native %d script %d" % [points[i], got[i], want[i]]
		_check(diff == 0, "native clear flags equal the script's, point for point", "%d differ; %s" % [diff, first])
		vol.clear()
		_check(vol.count() == 0 and vol.clear_of(points.slice(0, 8), Vector3.ZERO, Vector3.ZERO).count(1) == 8,
				"a cleared set finds everything clear")
		checks += 2
		for id in MAPS:
			if FcImportedMaps.has(id):
				checks += await _verify_map(id, rng, PLAYERS)
				checks += await _verify_map(id, rng, FEW_PLAYERS)
			else:
				print("absent here: %s" % id)
	_report(checks)


## A point near a box (on a grown face, one step either side of it, inside), far from all, or not finite.
func _point(rng: RandomNumberGenerator, boxes: Array[AABB]) -> Vector3:
	var roll := rng.randf()
	if roll < 0.01:
		return Vector3(NAN, 0.0, 0.0) if rng.randf() < 0.5 else Vector3(INF, 1.0, 2.0)
	if roll < 0.3:
		return Vector3(rng.randf_range(-70, 70), rng.randf_range(-20, 20), rng.randf_range(-70, 70))
	var b := boxes[rng.randi() % boxes.size()].abs()
	var lo := b.position - FcVolumePrefilter.BELOW
	var hi := b.end + FcVolumePrefilter.ABOVE
	var p := Vector3(rng.randf_range(lo.x - 1, hi.x + 1), rng.randf_range(lo.y - 1, hi.y + 1), rng.randf_range(lo.z - 1, hi.z + 1))
	if roll < 0.7:
		var axis := rng.randi() % 3
		var face := lo[axis] if rng.randf() < 0.5 else hi[axis]
		var step := rng.randi() % 3 - 1
		p[axis] = face if step == 0 else (nextafter(face, INF) if step > 0 else nextafter(face, -INF))
	return p


static func nextafter(x: float, toward: float) -> float:
	var bytes := PackedFloat64Array([x]).to_byte_array()
	var bits := bytes.decode_s64(0)
	bits += 1 if (toward > x) == (x >= 0.0) else -1
	bytes.encode_s64(0, bits)
	return bytes.decode_double(0)


## Players dropped at seeded spots near and away from a converted map's volumes; every tick one is marked clear,
## the full mechanics run anyway and must leave its position, velocity and mode alone and find no pit.
func _verify_map(id: StringName, rng: RandomNumberGenerator, count: int) -> int:
	_game = FcGame.new()
	_game.tick_rate = 64
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	_game.mode = FcMode.free_for_all(10)
	add_child(_game)
	var res := _game.setup(FcMap.by_id(id))
	_check(res.ok, "%s: setup succeeds" % id)
	var boxes := FcVolumePrefilter.boxes_of(_game.map)
	for i in count:
		_game.add_player(10 + i, "p%d" % i)
		_game.respawn_player(10 + i)
	FcPlayer.mechanics_verify = true
	FcPlayer.mechanics_checked = 0
	var rows_before := FcHullGrid.batch_rows
	FcPlayer.mechanics_misses = 0
	var bounds := AABB()
	for b in boxes:
		bounds = b.abs() if bounds.size == Vector3.ZERO else bounds.merge(b.abs())
	bounds = bounds.grow(20.0)
	for r in ROUNDS:
		for i in count:
			var player := _game.player_for(10 + i)
			if player == null:
				_game.respawn_player(10 + i)
				continue
			var at := bounds.position + Vector3(rng.randf(), rng.randf(), rng.randf()) * bounds.size
			if rng.randf() < 0.6 and not boxes.is_empty():
				var b := boxes[rng.randi() % boxes.size()].abs()
				var reach := FcVolumePrefilter.ABOVE + Vector3.ONE * 2.0
				at = b.get_center() + Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)) \
						* (b.size * 0.5 + reach)
			player.controller.teleport(at, rng.randf_range(-180, 180), 0.0)
		await _ticks(TICKS_PER_ROUND)
	FcPlayer.mechanics_verify = false
	var checked := FcPlayer.mechanics_checked
	var rows := FcHullGrid.batch_rows - rows_before
	var lane := "batched" if count >= FcHullGrid.MIN_PLAYERS else "one by one"
	print("  %s, %d players: %d boxes, %d batched rows, %d clear player ticks verified, %d changed" % [id, count, boxes.size(),
			rows, checked, FcPlayer.mechanics_misses])
	if count >= FcHullGrid.MIN_PLAYERS:
		_check(rows > 0, "%s: the batched tick ran (it marks the clear players)" % id, "%d rows" % rows)
	else:
		_check(rows == 0, "%s, %d players: the one-by-one tick ran" % [id, count], "%d rows" % rows)
	_check(checked > ROUNDS, "%s (%s): players were marked clear" % [id, lane], "%d" % checked)
	_check(FcPlayer.mechanics_misses == 0, "%s (%s): no clear tick's full mechanics changed the player" % [id, lane],
			"%d of %d" % [FcPlayer.mechanics_misses, checked])
	_game.queue_free()
	_game = null
	await get_tree().physics_frame
	return 4
