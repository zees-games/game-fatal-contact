extends GSGameCheckSuite

const FcMap := preload("../maps/fc_map.gd")
const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcTraceMirror := preload("../game/fc_trace_mirror.gd")
const FcPlayerTunables := preload("../game/fc_player_tunables.gd")

## The native motor (cvar `sv_trace_mirror`) colliding against gs-sim's collision mirror instead of the physics
## space: the same bodies, inputs and start on the same solid, ticked once against Godot Physics and once against
## the mirror, the whole tick native both times. Bodies stand at the map's spawns and run seeded random commands
## (as motor_native_tick_parity) and scripted bot-like ones (run a heading, strafe-jump, turn at walls). Reports per
## map the largest and median end gap, how many bodies end apart and the first tick a body parted, with both
## states. Its own tolerance (not the bit-exact one of the space path): END_EPS. Then the microseconds per tick of
## 31 bodies on cp-orange-x3, space against mirror. Imported maps skip when not linked, the suite without gs-sim's
## mirror motor.

const SEED := 20261127
const BODIES := 12
const TICKS := 400
const STEP := 1.0 / 60.0
## A body ends apart when its end position is farther than this from the space run's (metres).
const END_EPS := 0.05
## This share of a map's bodies must end within END_EPS.
const AGREE_SHARE := 0.75
const BENCH_BODIES := 31
const BENCH_TICKS := 300
const IMPORTED: Array[StringName] = [&"dm-industrial-gamma", &"surf_ski_2", &"cp-orange-x3"]

var _sections := 0
var _finished := 0
var _checks := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("motor on mirror — the native motor tick against gs-sim's mirror and against the physics space")
	if not GSSim.has(&"trace_mirror") or not FcTraceMirror.motor_available():
		print("no GSSimFpsBody.set_trace_mirror (gs-sim library without it) — nothing to compare")
		_report_sections(0, 0, 0, -1)
		return
	FcTraceMirror.enabled = true
	await _compare("box", FcMap.dm_box())
	await _compare("pit", FcMap.dm_pit())
	for id in IMPORTED:
		if not FcImportedMaps.has(id):
			print("-- %s: not linked under maps/imported* — skipped" % id)
			continue
		await _compare(String(id), FcMap.by_id(id))
	_report_sections(_sections, _finished, _sections, -1)


func _compare(label: String, map: FcMap) -> void:
	_sections += 1
	print("-- %s" % label)
	var solid := map.to_collision()
	add_child(solid)
	await get_tree().physics_frame
	await get_tree().physics_frame
	FcTraceMirror.reset()
	var mirror: Object = FcTraceMirror.of(solid)
	if not _check(mirror != null, "%s: the mirror holds the map's solid" % label):
		_drop(solid)
		return

	var starts := _starts(map)
	var streams: Array = []
	for b in BODIES:
		streams.append(_stream(SEED ^ label.hash() ^ (b * 7919), b % 2 == 1))
	var space_runs: Array = []
	var mirror_runs: Array = []
	for b in BODIES:
		space_runs.append(_replay(null, starts[b % starts.size()], streams[b]))
		mirror_runs.append(_replay(mirror, starts[b % starts.size()], streams[b]))

	var ends := PackedFloat32Array()
	var apart := 0
	var first := [TICKS, -1]
	for b in BODIES:
		var sp: PackedVector3Array = space_runs[b]
		var mp: PackedVector3Array = mirror_runs[b]
		var gap := sp[TICKS - 1].distance_to(mp[TICKS - 1])
		ends.append(gap)
		if gap > END_EPS:
			apart += 1
		for t in TICKS:
			if sp[t].distance_to(mp[t]) > END_EPS:
				if t < int(first[0]):
					first = [t, b]
				break
	var sorted := Array(ends)
	sorted.sort()
	print("     end gap: max %.4f m, median %.4f m, %d of %d bodies apart (> %.2f m)" % [
		sorted[-1], sorted[sorted.size() / 2], apart, BODIES, END_EPS])
	if int(first[1]) >= 0:
		var b := int(first[1])
		var t := int(first[0])
		var sp: PackedVector3Array = space_runs[b]
		var mp: PackedVector3Array = mirror_runs[b]
		print("     first parting: body %d (%s) tick %d start %s cmd %s space %s mirror %s (prev space %s mirror %s)" % [
			b, "scripted" if b % 2 == 1 else "random", t, starts[b % starts.size()], _cmd(streams[b][t]),
			sp[t], mp[t], sp[maxi(t - 1, 0)], mp[maxi(t - 1, 0)]])
	_check(BODIES - apart >= int(ceil(BODIES * AGREE_SHARE)),
		"%s: %d of %d bodies end within %.2f m of the space run" % [label, BODIES - apart, BODIES, END_EPS])
	if label == "cp-orange-x3":
		_bench(mirror, starts)
	FcTraceMirror.reset()
	_drop(solid)
	_finished += 1


## One body's positions, tick by tick, against [param mirror] or (null) the space.
func _replay(mirror: Object, start: Vector3, stream: Array[GSFpsCommand]) -> PackedVector3Array:
	var motor := _motor(mirror)
	var s := GSFpsState.new()
	s.position = start
	s.mode = GSFpsState.Mode.AIR
	var out := PackedVector3Array()
	for c in stream:
		motor.simulate(s, c, STEP)
		out.append(s.position)
	return out


func _motor(mirror: Object) -> GSFpsMotor:
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = true
	GSFpsMotor.native_full = true
	var body := GSFpsPhysicsBody.for_node(self)
	FcTraceMirror.bind_body(body, mirror)
	return GSFpsMotor.new(FcPlayerTunables.make(), body)


## Microseconds per tick of [constant BENCH_BODIES] bodies, space then mirror, printed (no check).
func _bench(mirror: Object, starts: PackedVector3Array) -> void:
	var stream := _stream(SEED, false)
	for way in 2:
		var motors: Array[GSFpsMotor] = []
		var states: Array[GSFpsState] = []
		for b in BENCH_BODIES:
			motors.append(_motor(mirror if way == 1 else null))
			var s := GSFpsState.new()
			s.position = starts[b % starts.size()]
			s.mode = GSFpsState.Mode.AIR
			states.append(s)
		var t0 := Time.get_ticks_usec()
		for t in BENCH_TICKS:
			for b in BENCH_BODIES:
				motors[b].simulate(states[b], stream[t], STEP)
		var per := float(Time.get_ticks_usec() - t0) / BENCH_TICKS
		print("     bench %s: %.1f us per tick of %d bodies (%.2f us per body)" % [
			"mirror" if way == 1 else "space ", per, BENCH_BODIES, per / BENCH_BODIES])


## Seeded commands: random ones (as motor_native_tick_parity), or [param scripted] bot-like runs: a heading held
## for a second or two with sprint, strafe-jumps, a crouch now and then, a sharp turn.
func _stream(seed: int, scripted: bool) -> Array[GSFpsCommand]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array[GSFpsCommand] = []
	var move := Vector2(0, -1)
	var buttons := 0
	var yaw := rng.randf_range(-PI, PI)
	for tick in TICKS:
		if scripted:
			if tick % 90 == 0:
				yaw = wrapf(yaw + rng.randf_range(-2.5, 2.5), -PI, PI)
				move = Vector2(float(rng.randi_range(-1, 1)), -1.0)
			buttons = GSFpsCommand.BUTTON_SPRINT
			if tick % 40 < 2:
				buttons |= GSFpsCommand.BUTTON_JUMP
			if tick % 150 > 135:
				buttons |= GSFpsCommand.BUTTON_CROUCH
			yaw = wrapf(yaw + move.x * 0.02, -PI, PI)
		else:
			if tick % 6 == 0 or rng.randf() < 0.08:
				move = Vector2(rng.randi_range(-1, 1), -1.0 if rng.randf() < 0.6 else float(rng.randi_range(-1, 1)))
				buttons = 0
				for bit: int in [GSFpsCommand.BUTTON_SPRINT, GSFpsCommand.BUTTON_CROUCH, GSFpsCommand.BUTTON_JUMP,
						GSFpsCommand.BUTTON_USER_0, GSFpsCommand.BUTTON_USER_1, GSFpsCommand.BUTTON_USER_2]:
					if rng.randf() < (0.5 if bit == GSFpsCommand.BUTTON_SPRINT else 0.18):
						buttons |= bit
			yaw = wrapf(yaw + rng.randf_range(-0.2, 0.2), -PI, PI)
		var c := GSFpsCommand.new()
		c.move = move
		c.buttons = buttons
		c.yaw = yaw
		out.append(c)
	return out


func _starts(map: FcMap) -> PackedVector3Array:
	var out := PackedVector3Array()
	for at: Transform3D in map.spawns:
		out.append(at.origin + Vector3.UP * 0.1)
	if out.is_empty():
		out.append(Vector3(0, 2, 0))
	return out


func _cmd(c: GSFpsCommand) -> String:
	return "move %s buttons %d yaw %.3f" % [c.move, c.buttons, c.yaw]


func _drop(solid: Node) -> void:
	remove_child(solid)
	solid.free()
