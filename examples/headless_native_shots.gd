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
## over a standing target, a crouch-fitted one, a wood wall with bodies behind it, two walls in a row,
## a grazing metal wall, a one-sided sheet, a breakable pane (handed to the script), seeded shotgun
## spreads, and a strafing, crouching target rewound by lag compensation to fractional view ticks.
## sv_native_unlag: GSSimUnlagRing and the script rings, fed one history, answer the same feet and
## crouch at every view tick a ping names, and the shots rewound from each hit and miss alike. The defaults
## (both switches 1, the rewind posing the native tracer instead of moving nodes) against the specification (both
## 0, nodes moved, script tracer): the same rows. A posed shot a pane sends to the script moves the nodes late, alike.
## Without the native class every comparison FAILS: this suite exists to prove the native path.

const TICK_RATE := FcContent.TICK_RATE
const SHOOTER := 1
const STANDING := 2
const CROUCHED := 3
const BEHIND := 4
const SHIELD := 5
## Pellets per fan side: a FAN x FAN grid over +-SPAN degrees.
const FAN := 13
const SPAN := 5.0

const CHECKS := 30
const SECTIONS := 10

var _entered := 0
var _completed := 0
var _game: FcGame = null
var _native: FcNativeShots = null
var _script: GSPelletTracer = null
var _skip := ""
## Called before each trace of a comparison (a pane mended), when valid.
var _before_trace := Callable()


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
	_two_walls()
	_sheet()
	_pane()
	_spread()
	_lagcomp()
	_unlag_rings()
	_timing()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _boot() -> void:
	_game = FcGame.new()
	var defaults_on: bool = _game.native_shots == 1 and _game.native_unlag == 1
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
	_check(defaults_on, "sv_native_shots and sv_native_unlag default to 1", "shots %d, unlag %d" % [_game.native_shots, _game.native_unlag])
	_native = _game._native_tracer
	_check(_native != null and _game.combat.get_tracer() == _native, "sv_native_shots builds the native tracer on the combat manager (set_tracer)")
	_script = GSPelletTracer.new(_game.combat)
	if _native == null:
		_skip = "no FcNativeShots on the combat manager"
	elif not _native.is_native():
		_skip = "GameSpice Sim has no GSSimShots in this build"
	_check(_skip == "", "GameSpice Sim's GSSimShots is loaded (the comparisons need it)", _skip)


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
	var _w := _compare("standing", shot)
	_completed += 1


func _crouched() -> void:
	_section("a fan over a crouch-fitted target")
	var p: FcPlayer = _game.player_for(CROUCHED)
	p.fit_hitboxes_to_crouch(0.6)
	var _w := _compare("crouched", _shot_at(CROUCHED, 0.8, null))
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
	var _n := _compare("wall", shot)
	_check(not shot.penetrations.is_empty(), "the wall fan passes the wall", "%d passes" % shot.penetrations.size())
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
	var _n := _compare("ricochet", shot)
	_check(not shot.ricochets.is_empty(), "the grazing fan bounces", "%d bounces" % shot.ricochets.size())
	combat.ricochet_enabled = ricochet_was
	flat.boxes.assign(boxes_was)
	flat.box_materials.assign(mats_was)
	_completed += 1


func _two_walls() -> void:
	_section("two wood walls in a row, bodies behind, penetrating round")
	var flat := _game.combat.trace as GSTraceFlat
	var boxes_was := flat.boxes.duplicate()
	var mats_was := flat.box_materials.duplicate()
	var _a: RefCounted = flat.add_box(AABB(Vector3(-9.0, 0.0, -4.1), Vector3(6.0, 4.0, 0.2)), &"wood")
	var _b: RefCounted = flat.add_box(AABB(Vector3(-9.0, 0.0, -6.6), Vector3(6.0, 4.0, 0.25)), &"wood")
	var pen := _wood_round(2.4)
	var shot := _shot_at(SHIELD, 1.1, pen)
	var _w := _compare("two walls", shot)
	var per_pellet := {}
	for p: Dictionary in shot.penetrations:
		per_pellet[p["pellet"]] = int(per_pellet.get(p["pellet"], 0)) + 1
	var most := 0
	for n: int in per_pellet.values():
		most = maxi(most, n)
	_check(most >= 2, "a pellet passes both walls", "%d passes, at most %d by one pellet" % [shot.penetrations.size(), most])
	flat.boxes.assign(boxes_was)
	flat.box_materials.assign(mats_was)
	_completed += 1


func _sheet() -> void:
	_section("a one-sided sheet (no far face; sheet_thickness invents one)")
	var flat := _game.combat.trace as GSTraceFlat
	var faced := _faced(flat)
	faced.sheet_box = faced.boxes.size()
	var _s: RefCounted = faced.add_box(AABB(Vector3(-3.0, 0.0, -5.05), Vector3(6.0, 4.0, 0.05)), &"sheet_metal")
	var combat := _game.combat
	var sheets_was := combat.sheet_thickness.duplicate()
	combat.sheet_thickness[&"sheet_metal"] = 0.004
	combat.trace = faced
	var pen := GSPenetration.new()
	pen.power = 1.0
	pen.materials = {&"sheet_metal": 2.0}
	pen.max_depth = 1.0
	pen.body_cost = 0.3
	pen.max_passes = 3
	var shot := _shot_at(STANDING, 1.2, pen)
	var _w := _compare("sheet", shot)
	var sheets := 0
	for p: Dictionary in shot.penetrations:
		sheets += 1 if p["sheet"] else 0
	_check(sheets > 0, "the fan passes the sheet as a sheet", "%d sheet passes of %d" % [sheets, shot.penetrations.size()])
	combat.trace = flat
	combat.sheet_thickness = sheets_was
	_completed += 1


func _pane() -> void:
	_section("a breakable pane: its pellets go to the script, the rest stay native")
	var flat := _game.combat.trace as GSTraceFlat
	var faced := _faced(flat)
	faced.pane_box = faced.boxes.size()
	# Left of the line of fire only: the fan is about 0.7 m across here, so half its pellets meet the glass
	# and go to the script, and the other half must stay native.
	var _p: RefCounted = faced.add_box(AABB(Vector3(-1.0, 0.0, -4.005), Vector3(1.0, 3.0, 0.005)), &"glass")
	faced.pane = Pane.new()
	var combat := _game.combat
	combat.trace = faced
	_before_trace = func() -> void: faced.pane.mend(70.0)
	var shot := _shot_at(STANDING, 1.2, null)
	var walked := _compare("pane", shot)
	_check(faced.pane.hits > 0 and walked < shot.pellets.size(), "the pane takes pellets and hands them to the script",
		"%d pane hits, broken %s, %d of %d pellets native" % [faced.pane.hits, faced.pane.is_broken(), walked, shot.pellets.size()])
	# Rewound: the rewind poses the native tracer, and the first pellet for the script moves the nodes after all.
	var posed_was := _game.unlag_posed_rewinds
	var late_was := _game.unlag_materialized_rewinds
	var walked_late := _compare("pane, rewound", shot, float(_game.current_tick()) - 2.0)
	_check(_game.unlag_materialized_rewinds == late_was + 1 and _game.unlag_posed_rewinds == posed_was and walked_late > 0,
		"a posed rewind moves the nodes once a pellet goes to the script",
		"%d moved late, %d posed" % [_game.unlag_materialized_rewinds - late_was, _game.unlag_posed_rewinds - posed_was])
	_before_trace = Callable()
	combat.trace = flat
	faced.pane.free()
	_completed += 1


func _spread() -> void:
	_section("seeded shotgun spreads: 12 pellets in a 4 degree cone, four targets")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var crouched: FcPlayer = _game.player_for(CROUCHED)
	crouched.fit_hitboxes_to_crouch(1.0)
	var targets := [[STANDING, 1.0, null], [CROUCHED, 0.6, null], [SHIELD, 1.3, _wood_round(1.0)], [BEHIND, 0.9, _wood_round(1.6)]]
	for t: Array in targets:
		var shooter: FcPlayer = _game.player_for(SHOOTER)
		var target: FcPlayer = _game.player_for(t[0])
		var origin := shooter.muzzle_position()
		var aim := target.global_position + Vector3.UP * float(t[1]) * FcPlayerTunables.body_scale()
		var shot := _shot(origin, (aim - origin).normalized(), t[2])
		shot.pellets.clear()
		var right := shot.direction.cross(Vector3.UP).normalized()
		var up := right.cross(shot.direction).normalized()
		for i in 12:
			var spin := rng.randf() * TAU
			var off := tan(deg_to_rad(4.0)) * sqrt(rng.randf())
			shot.pellets.append((shot.direction + (right * cos(spin) + up * sin(spin)) * off).normalized())
		shot.pellet_count = shot.pellets.size()
		var _w := _compare("spread at P%d" % t[0], shot)
	crouched.fit_hitboxes_to_crouch(0.0)
	_completed += 1


## Lag compensation's rewind moves the bodies and refits their crouch before the pellets: the native
## poses must read both. Twelve recorded ticks of P2 strafing right 0.25 m a tick while crouching in.
func _lagcomp() -> void:
	_section("lag comp: a strafing, crouching target rewound to fractional view ticks")
	var p: FcPlayer = _game.player_for(STANDING)
	var now: int = _game._tick
	var start := p.global_position
	var crouch_was: float = p.controller.state.crouch_fraction
	for k in 12:
		var t := now - 11 + k
		p.global_position = start + Vector3.RIGHT * 0.25 * float(t - now)
		p.controller.state.crouch_fraction = clampf(0.15 * float(k), 0.0, 1.0) if t < now else crouch_was
		_game._tick = t
		_game._unlag_record()
	_game._tick = now
	p.global_position = start
	p.controller.state.crouch_fraction = crouch_was
	var hits := 0
	var rewound := true
	var posed_was := _game.unlag_posed_rewinds
	var late_was := _game.unlag_materialized_rewinds
	for view in [float(now) - 9.5, float(now) - 4.6]:
		var then: Vector3 = _game.unlag_position_at(STANDING, view)
		var shooter: FcPlayer = _game.player_for(SHOOTER)
		var origin := shooter.muzzle_position()
		var aim := then + Vector3.UP * 0.7 * FcPlayerTunables.body_scale()
		var shot := _shot(origin, (aim - origin).normalized(), null)
		var _w := _compare("rewound to %.1f" % (view - float(now)), shot, view)
		rewound = rewound and _outputs(shot, view)[4]
		for d in shot.damages:
			hits += 1 if d.victim == STANDING else 0
	_check(rewound and hits > 0 and p.global_position == start, "the rewound fans hit P2 where it was, and it is put back",
		"rewound %s, %d hits on P2" % [rewound, hits])
	# The native passes were posed: the rewound feet and crouch fit went to GSSimShots as numbers, no node moved.
	# Two a view: _compare's native pass and the rewound check above, both under the game's own (native) tracer.
	_check(_game.unlag_posed_rewinds == posed_was + 4 and _game.unlag_materialized_rewinds == late_was,
		"the native passes pose the rewound targets without moving a node",
		"%d posed, %d moved late" % [_game.unlag_posed_rewinds - posed_was, _game.unlag_materialized_rewinds - late_was])
	_completed += 1


## sv_native_unlag: forty ticks of a near target strafing and crouching and a far one (70 m) that
## teleports half-way, recorded once into the script rings and once into GSSimUnlagRing. Both answer
## the same feet and crouch at every view a ping from 0 to 900 ms names (before the history, across the
## cut, between ticks), and fans aimed at where each was, and at where each is, rewound from either
## ring hit and miss the same bodies with the same rows. The script tracer walks both: only the ring differs.
func _unlag_rings() -> void:
	_section("lag-comp rings: GSSimUnlagRing against the script rings, near and far, across pings")
	var near: FcPlayer = _game.player_for(STANDING)
	var far: FcPlayer = _game.player_for(BEHIND)
	var near_was := near.global_position
	var far_was := far.global_position
	var crouch_was: float = near.controller.state.crouch_fraction
	var far_now := Vector3(8.0, 0.05, -70.0)
	var tick_was: int = _game._tick
	var now: int = tick_was + 200
	var span := 40
	var views: Array[float] = [float(now - span - 3), float(now - span) + 0.5, float(now - span + 20) - 0.5, float(now - span + 20) + 0.25]
	for ping_ms in [0.0, 15.0, 33.0, 50.0, 80.0, 120.0, 180.0, 250.0, 400.0, 600.0, 900.0]:
		views.append(float(now) - ping_ms / 1000.0 * float(TICK_RATE) - 0.37)
	var answers := {}
	var shots := {}
	var native_used := false
	for mode in [0, 1]:
		_game.native_unlag = mode
		_game.apply_native_unlag()
		for k in span:
			var back := float(span - 1 - k)
			_game._tick = now - span + 1 + k
			near.global_position = near_was + Vector3.LEFT * 0.3 * back
			near.controller.state.crouch_fraction = clampf(fmod(0.13 * float(k), 1.4), 0.0, 1.0)
			far.global_position = far_now + Vector3.RIGHT * 0.2 * back + (Vector3.LEFT * 15.0 if k < 20 else Vector3.ZERO)
			_game._unlag_record()
		_game._tick = now
		near.global_position = near_was
		near.controller.state.crouch_fraction = crouch_was
		far.global_position = far_now
		if mode == 1:
			native_used = _game._unlag_native != null and _game._unlag.is_empty()
		var rows: Array = []
		for view in views:
			rows.append([_game.unlag_position_at(STANDING, view), _game.unlag_crouch_at(STANDING, view),
				_game.unlag_position_at(BEHIND, view), _game.unlag_crouch_at(BEHIND, view)])
		answers[mode] = rows
		var fired: Array = []
		for i in views.size():
			for target in [[STANDING, near_was], [BEHIND, far_now]]:
				var then: Variant = (answers[0] as Array)[i][0 if target[0] == STANDING else 2]
				for aim_at in [then, target[1]]:
					if aim_at == null:
						continue
					var shooter: FcPlayer = _game.player_for(SHOOTER)
					var origin := shooter.muzzle_position()
					var at: Vector3 = aim_at
					var aim: Vector3 = at + Vector3.UP * 1.0 * FcPlayerTunables.body_scale()
					var shot := _shot(origin, (aim - origin).normalized(), null)
					var tracer_was: RefCounted = _game.combat.get_tracer()
					var _s := _game.combat.set_tracer(_script)
					var out := _outputs(shot, views[i])
					# The defaults: the native rings, the native tracer, the rewind posed.
					var native_out: Array = []
					if mode == 1 and _skip == "":
						_s = _game.combat.set_tracer(_native)
						_native.enabled = true
						native_out = _outputs(shot, views[i])
					_s = _game.combat.set_tracer(tracer_was)
					fired.append([target[0], out, native_out])
		shots[mode] = fired
	_game.native_unlag = 1
	_game.apply_native_unlag()
	_game._tick = tick_was
	far.global_position = far_was
	var ring_diff := ""
	var unrecorded := 0
	for i in views.size():
		if var_to_str(answers[0][i]) != var_to_str(answers[1][i]) and ring_diff == "":
			ring_diff = "view %.2f: script %s vs native %s" % [views[i] - float(now), var_to_str(answers[0][i]), var_to_str(answers[1][i])]
		unrecorded += 1 if answers[0][i][0] == null else 0
	_check(native_used and ring_diff == "" and unrecorded > 0 and unrecorded < views.size(),
		"the native rings answer the script rings' feet and crouch at every view, both targets",
		"native %s, %d views, %d before the history%s" % [native_used, views.size(), unrecorded, "" if ring_diff == "" else "; " + ring_diff])
	var shot_diff := ""
	var hits := {STANDING: 0, BEHIND: 0}
	var misses := 0
	for j in (shots[0] as Array).size():
		var a: Array = shots[0][j]
		var b: Array = shots[1][j]
		var diff := _first_difference(a[1], b[1])
		if diff == "" and a[1][4] != b[1][4]:
			diff = "rewound %s (script) vs %s (native)" % [a[1][4], b[1][4]]
		if diff != "" and shot_diff == "":
			shot_diff = "shot %d at P%d: %s" % [j, a[0], diff]
		var hit := false
		for row in a[1][0]:
			hit = hit or row[1] == a[0]
		if hit:
			hits[a[0]] += 1
		else:
			misses += 1
	_check(shot_diff == "" and hits[STANDING] > 0 and hits[BEHIND] > 0 and misses > 0,
		"fans rewound from either ring hit and miss alike, near and far",
		"%d shots: %d near hits, %d far hits, %d misses%s" % [(shots[0] as Array).size(), hits[STANDING], hits[BEHIND], misses, "" if shot_diff == "" else "; " + shot_diff])
	# Default-on parity: native rings + native tracer + posed rewind against script rings + script tracer + moved nodes.
	var default_diff := "" if _skip == "" else "no native path: " + _skip
	for j in (shots[0] as Array).size():
		if default_diff != "":
			break
		var spec: Array = shots[0][j][1]
		var got: Array = shots[1][j][2]
		default_diff = _first_difference(spec, got)
		if default_diff == "" and spec[4] != got[4]:
			default_diff = "rewound %s (script) vs %s (native)" % [spec[4], got[4]]
		if default_diff != "":
			default_diff = "shot %d at P%d: %s" % [j, shots[0][j][0], default_diff]
	_check(default_diff == "", "the defaults (native rings, native tracer, posed rewind) give the specification's rows at every view",
		"%d shots%s" % [(shots[0] as Array).size(), "" if default_diff == "" else "; " + default_diff])
	_completed += 1


## Not a check: microseconds per traced shot (a 169-pellet penetrating fan at P4 in the open map), script then
## native, for the report. Printed only; boxes differ too much for a bound to mean anything.
func _timing() -> void:
	if _skip != "":
		return
	var shot := _shot_at(BEHIND, 1.0, _wood_round(2.4))
	var combat := _game.combat
	var tracer_was: RefCounted = combat.get_tracer()
	var per := {}
	_native.enabled = true
	for tracer in [_script, _native]:
		var _s := combat.set_tracer(tracer)
		for i in 5:
			var _warm := _outputs(shot, -1.0)
		var t0 := Time.get_ticks_usec()
		for i in 100:
			var _o := _outputs(shot, -1.0)
		per[tracer] = float(Time.get_ticks_usec() - t0) / 100.0
	var _r := combat.set_tracer(tracer_was)
	print("timing: %d pellets a shot, script %.0f us, native %.0f us (%.1fx)" % [shot.pellets.size(), per[_script], per[_native], per[_script] / maxf(per[_native], 0.001)])


func _wood_round(power: float) -> GSPenetration:
	var pen := GSPenetration.new()
	pen.power = power
	pen.materials = {&"wood": 1.0}
	pen.max_depth = 1.0
	pen.body_cost = 0.3
	pen.speed = 900.0
	pen.reference_speed = 850.0
	pen.min_damage = 0.2
	pen.max_passes = 4
	return pen


## A copy of [param flat] that can hold a one-sided sheet and a pane.
func _faced(flat: GSTraceFlat) -> FacedTrace:
	var faced := FacedTrace.new()
	faced.floor_y = flat.floor_y
	faced.boxes.assign(flat.boxes)
	faced.box_materials.assign(flat.box_materials)
	faced.native = flat.native
	faced.repack()
	return faced


## The flat trace with two test fixtures: box [member sheet_box] answers only on its +Z face (a ray
## from behind finds no far face), and box [member pane_box]'s hits carry [member pane] as the collider.
class FacedTrace extends GSTraceFlat:
	var sheet_box := -1
	var pane_box := -1
	var pane: Node = null

	func _world_ray(from: Vector3, direction: Vector3, max_distance: float) -> GSHitbox.Hit:
		var hit := super(from, direction, max_distance)
		if not hit.ok():
			return hit
		if sheet_box >= 0 and boxes[sheet_box].grow(0.0001).has_point(hit.point) and hit.normal != Vector3.BACK:
			return GSHitbox.Hit.new()
		if pane_box >= 0 and boxes[pane_box].grow(0.0001).has_point(hit.point):
			hit.collider = pane
		return hit


## gs-combat's pane contract: hurt() and is_broken().
class Pane extends Node:
	var health := 0.0
	var hits := 0

	func mend(to: float) -> void:
		health = to
		hits = 0

	func hurt(amount: float, _point: Vector3, _kind: StringName) -> void:
		health -= amount
		hits += 1

	func is_broken() -> bool:
		return health <= 0.0


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
func _compare(label: String, shot: GSShot, view_tick := -1.0) -> int:
	var combat := _game.combat
	var tracer_was: RefCounted = combat.get_tracer()
	var _s := combat.set_tracer(_script)
	var want := _outputs(shot, view_tick)
	if _skip != "":
		_s = combat.set_tracer(tracer_was)
		_check(false, "%s: native and script give the same hits, damage and passes" % label, "no native path: " + _skip)
		return 0
	_native.enabled = true
	var before := _native.native_pellets
	_s = combat.set_tracer(_native)
	var got := _outputs(shot, view_tick)
	_s = combat.set_tracer(tracer_was)
	var walked := _native.native_pellets - before
	var diff := _first_difference(want, got)
	_check(diff == "" and walked > 0, "%s: native and script give the same hits, damage and passes" % label,
		"%d damages, %d impacts, %d passes, %d bounces; %d of %d pellets native%s" % [
			(want[0] as Array).size(), (want[1] as Array).size(), (want[2] as Array).size(), (want[3] as Array).size(),
			walked, shot.pellets.size(), "" if diff == "" else "; " + diff])
	return walked


## [damages as value rows, impacts, penetrations, ricochets] after one trace of [param shot], rewound to [param view_tick] when it is not negative.
func _outputs(shot: GSShot, view_tick: float) -> Array:
	shot.damages.clear()
	shot.impacts.clear()
	shot.penetrations.clear()
	shot.ricochets.clear()
	if _before_trace.is_valid():
		_before_trace.call()
	var combat := _game.combat
	var rewound := false
	if view_tick >= 0.0:
		# As FcGame._resolve_shot stands it: the rewind may pose the native tracer instead of moving nodes.
		_game._unlag_shooter = SHOOTER
		_game._unlag_pose_shot = shot
		rewound = combat._begin_rewind(shot, view_tick)
	var _lap := combat._trace_shot(shot)
	combat._end_rewind(rewound)
	_game._unlag_pose_shot = null
	var rows: Array = []
	for d in shot.damages:
		rows.append([d.attacker, d.victim, d.base_amount, d.amount, d.hit_group, d.limb, d.point, d.direction,
			d.distance, d.weapon_id, d.tick, d.type, d.context])
	return [rows, shot.impacts.duplicate(), shot.penetrations.duplicate(true), shot.ricochets.duplicate(true), rewound]


static func _first_difference(want: Array, got: Array) -> String:
	var names := ["damage", "impact", "pass", "ricochet"]
	for k in names.size():
		var a: Array = want[k]
		var b: Array = got[k]
		if a.size() != b.size():
			return "%s count %d (script) vs %d (native)" % [names[k], a.size(), b.size()]
		for i in a.size():
			if a[i] != b[i]:
				return "%s %d: %s" % [names[k], i, _field_difference(a[i], b[i])]
	return ""


## The first differing field of two rows, printed shallowly: a row may hold objects, typed arrays or itself.
static func _field_difference(a: Variant, b: Variant) -> String:
	if a is Array and b is Array and (a as Array).size() == (b as Array).size():
		for f in (a as Array).size():
			if (a as Array)[f] != (b as Array)[f]:
				return "field %d: script %s vs native %s" % [f, _shallow((a as Array)[f]), _shallow((b as Array)[f])]
	return "script %s vs native %s" % [_shallow(a), _shallow(b)]


static func _shallow(v: Variant) -> String:
	match typeof(v):
		TYPE_OBJECT:
			return "<%s>" % (v as Object).get_class() if v != null else "null"
		TYPE_ARRAY:
			return "[%d items]" % (v as Array).size()
		TYPE_DICTIONARY:
			var parts: PackedStringArray = []
			for key: Variant in v:
				parts.append("%s=%s" % [str(key), _shallow((v as Dictionary)[key])])
			return "{%s}" % ", ".join(parts)
	return str(v)
