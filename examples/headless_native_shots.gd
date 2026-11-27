extends GSGameCheckSuite

const FcContent := preload("../game/fc_content.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcNativeShots := preload("../game/fc_native_shots.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcPlayerTunables := preload("../game/fc_player_tunables.gd")

## Hitscan parity: the same shots walked by GameSpice Sim's GSSimShots (sv_native_shots 1) and by
## gs-combat's script GSPelletTracer give the same damage rows (victim, amounts, group, limb, point,
## direction, distance, context), impacts, wall passes and ricochets, to the bit. Fans of pellets
## over a standing target, a crouch-fitted one, a wood wall with bodies behind it, and a grazing metal
## wall. Without the native class the comparison is skipped (and says so): the script path is all there is.

const TICK_RATE := FcContent.TICK_RATE
const SHOOTER := 1
const STANDING := 2
const CROUCHED := 3
const BEHIND := 4
const SHIELD := 5
## Pellets per fan side: a FAN x FAN grid over +-SPAN degrees.
const FAN := 13
const SPAN := 5.0

const CHECKS := 9
const SECTIONS := 4

var _entered := 0
var _completed := 0
var _game: FcGame = null
var _native: FcNativeShots = null
var _script: GSPelletTracer = null
var _skip := ""


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless native shots parity")
	await _boot()
	_plain()
	_crouched()
	_wall()
	_ricochet()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _boot() -> void:
	_game = FcGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	add_child(_game)
	var map := FcMap.new()
	map.id = &"native_shots_lane"
	map.display_name = "native_shots_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p: RefCounted = map.add_perimeter()
	for i in 5:
		var _s: RefCounted = map.add_spawn(Transform3D(Basis(), Vector3(4.0 * i, 0.05, 0.0)))
	var ready := _game.setup(map)
	_check(ready.ok, "Fatal Contact sets up", str(ready.error))
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	for id in [SHOOTER, STANDING, CROUCHED, BEHIND, SHIELD]:
		var _a := _game.add_player(id, "P%d" % id)
	_game.start(0)
	_game.tick({})
	var tick: int = _game.current_tick()
	_spawn(SHOOTER, Vector3(0.0, 0.05, 0.0), tick)
	_spawn(STANDING, Vector3(0.0, 0.05, -8.0), tick)
	_spawn(CROUCHED, Vector3(6.0, 0.05, -10.0), tick)
	_spawn(SHIELD, Vector3(-6.0, 0.05, -9.0), tick)
	_spawn(BEHIND, Vector3(-6.0, 0.05, -11.0), tick)
	for _i in 24:
		_game.tick({})
	await get_tree().physics_frame
	_native = _game.combat._tracer as FcNativeShots
	_check(_native != null, "sv_native_shots builds the native tracer on the combat manager")
	_script = GSPelletTracer.new(_game.combat)
	if _native == null:
		_skip = "no FcNativeShots on the combat manager"
	elif not _native.is_native():
		_skip = "GameSpice Sim has no GSSimShots in this build"
	if _skip != "":
		print("  SKIP native comparison: %s (the script tracer is the only path)" % _skip)


func _spawn(id: int, at: Vector3, tick: int) -> void:
	var p: FcPlayer = _game.player_for(id)
	p.spawn(Transform3D(Basis(), at), tick)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


# --- Scenarios ----------------------------------------------------------------

func _plain() -> void:
	_section("a fan over a standing target, no penetration")
	var shot := _shot_at(STANDING, 1.2, null)
	_compare("standing", shot)
	_completed += 1


func _crouched() -> void:
	_section("a fan over a crouch-fitted target")
	var p: FcPlayer = _game.player_for(CROUCHED)
	p.fit_hitboxes_to_crouch(0.6)
	_compare("crouched", _shot_at(CROUCHED, 0.8, null))
	p.fit_hitboxes_to_crouch(0.0)
	_completed += 1


func _wall() -> void:
	_section("a wood wall with two bodies behind it, penetrating round")
	var flat := _game.combat.trace as GSTraceFlat
	_check(flat != null, "the headless trace is flat")
	if flat == null:
		return
	var boxes_was := flat.boxes.duplicate()
	var mats_was := flat.box_materials.duplicate()
	var _w: RefCounted = flat.add_box(AABB(Vector3(-9.0, 0.0, -6.15), Vector3(6.0, 4.0, 0.3)), &"wood")
	var pen := GSPenetration.new()
	pen.power = 1.6
	pen.materials = {&"wood": 1.0}
	pen.max_depth = 1.0
	pen.body_cost = 0.3
	pen.speed = 900.0
	pen.reference_speed = 850.0
	pen.min_damage = 0.2
	pen.max_passes = 4
	var shot := _shot_at(SHIELD, 1.1, pen)
	_compare("wall", shot)
	_check(_skip != "" or not shot.penetrations.is_empty(), "the wall fan passes the wall", "%d passes" % shot.penetrations.size())
	flat.boxes.assign(boxes_was)
	flat.box_materials.assign(mats_was)
	_completed += 1


func _ricochet() -> void:
	_section("a grazing metal wall, ricochets on")
	var flat := _game.combat.trace as GSTraceFlat
	if flat == null:
		return
	var boxes_was := flat.boxes.duplicate()
	var mats_was := flat.box_materials.duplicate()
	# A metal wall along the lane, left of the shooter: a fan aimed just inside it grazes and bounces.
	var _w: RefCounted = flat.add_box(AABB(Vector3(-1.4, 0.0, -30.0), Vector3(0.3, 4.0, 29.0)), &"metal")
	var combat := _game.combat
	var ricochet_was := combat.ricochet_enabled
	combat.ricochet_enabled = true
	var pen := GSPenetration.new()
	pen.power = 0.2
	pen.materials = {&"metal": 8.0}
	pen.ricochet_materials = PackedStringArray(["metal"])
	pen.ricochet_angle = 25.0
	pen.ricochet_keep = 0.6
	pen.max_ricochets = 2
	var shooter: FcPlayer = _game.player_for(SHOOTER)
	var shot := _shot(shooter.muzzle_position(), Vector3(-0.12, 0.0, -1.0).normalized(), pen)
	_compare("ricochet", shot)
	_check(_skip != "" or not shot.ricochets.is_empty(), "the grazing fan bounces", "%d bounces" % shot.ricochets.size())
	combat.ricochet_enabled = ricochet_was
	flat.boxes.assign(boxes_was)
	flat.box_materials.assign(mats_was)
	_completed += 1


# --- Shots --------------------------------------------------------------------

func _shot_at(victim: int, height: float, pen: GSPenetration) -> GSShot:
	var shooter: FcPlayer = _game.player_for(SHOOTER)
	var target: FcPlayer = _game.player_for(victim)
	var origin := shooter.muzzle_position()
	var aim := target.global_position + Vector3.UP * height * FcPlayerTunables.body_scale()
	return _shot(origin, (aim - origin).normalized(), pen)


func _shot(origin: Vector3, direction: Vector3, pen: GSPenetration) -> GSShot:
	var shot := GSShot.new()
	shot.weapon_id = &"parity"
	shot.attacker = SHOOTER
	shot.tick = _game.current_tick()
	shot.origin = origin
	shot.direction = direction
	shot.damage = 30.0
	shot.max_range = 120.0
	shot.penetration = pen
	var right := direction.cross(Vector3.UP).normalized()
	for i in FAN:
		for j in FAN:
			var yaw := deg_to_rad(lerpf(-SPAN, SPAN, float(i) / float(FAN - 1)))
			var pitch := deg_to_rad(lerpf(-SPAN, SPAN, float(j) / float(FAN - 1)))
			shot.pellets.append(direction.rotated(Vector3.UP, yaw).rotated(right, pitch).normalized())
	shot.pellet_count = shot.pellets.size()
	return shot


## Traces [param shot] with the script tracer, then a copy with the native one, and checks every output matches.
func _compare(label: String, shot: GSShot) -> void:
	var combat := _game.combat
	var tracer_was: RefCounted = combat._tracer
	combat._tracer = _script
	var want := _outputs(shot)
	if _skip != "":
		combat._tracer = tracer_was
		_check(true, "%s: script tracer ran (%s; native skipped)" % [label, _skip])
		return
	_native.enabled = true
	var before := _native.native_pellets
	combat._tracer = _native
	var got := _outputs(shot)
	combat._tracer = tracer_was
	var walked := _native.native_pellets - before
	var diff := _first_difference(want, got)
	_check(diff == "" and walked > 0, "%s: native and script give the same hits, damage and passes" % label,
		"%d damages, %d impacts, %d passes, %d bounces; %d of %d pellets native%s" % [
			(want[0] as Array).size(), (want[1] as Array).size(), (want[2] as Array).size(), (want[3] as Array).size(),
			walked, shot.pellets.size(), "" if diff == "" else "; " + diff])


## [damages as value rows, impacts, penetrations, ricochets] after one trace of [param shot].
func _outputs(shot: GSShot) -> Array:
	shot.damages.clear()
	var _lap := _game.combat._trace_shot(shot)
	var rows: Array = []
	for d in shot.damages:
		rows.append([d.attacker, d.victim, d.base_amount, d.amount, d.hit_group, d.limb, d.point, d.direction,
			d.distance, d.weapon_id, d.tick, d.type, d.context])
	return [rows, shot.impacts.duplicate(), shot.penetrations.duplicate(true), shot.ricochets.duplicate(true)]


static func _first_difference(want: Array, got: Array) -> String:
	var names := ["damage", "impact", "pass", "ricochet"]
	for k in want.size():
		var a: Array = want[k]
		var b: Array = got[k]
		if a.size() != b.size():
			return "%s count %d (script) vs %d (native)" % [names[k], a.size(), b.size()]
		for i in a.size():
			if a[i] != b[i]:
				return "%s %d: script %s vs native %s" % [names[k], i, var_to_str(a[i]), var_to_str(b[i])]
	return ""
