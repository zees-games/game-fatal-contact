extends GSGameCheckSuite

const FcMap := preload("../maps/fc_map.gd")
const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcTraceMirror := preload("../game/fc_trace_mirror.gd")
const FcPlayerTunables := preload("../game/fc_player_tunables.gd")

## The native motor (cvar `sv_trace_mirror`) colliding against gs-sim's collision mirror instead of the physics
## space: the same bodies, inputs and start on the same solid, ticked once against Godot Physics and once against
## the mirror, the whole tick native both times. Bodies stand at the map's spawns and run seeded random commands
## (as motor_native_tick_parity) and scripted bot-like ones (run a heading, strafe-jump, turn at walls).
## The bar: every body, every tick, the mirror's state within POS_EPS / VEL_EPS of the space's and in the same mode.
## Each map prints how many bodies part, and for the first parting the tick, both states, the previous states and
## the command, so a divergence can be handed on as a sample. Then: two mirrors built apart from the same map (the
## server's and a client's) tick to the bit (prediction asks the same world), the client follows the replicated
## cvar, anything the motor's mirror does not hold sends a body back to the space, and the microseconds per tick of
## 31 bodies on cp-orange-x3, space against mirror. Imported maps skip when not linked, the suite without gs-sim's
## mirror motor or gs-player-controller's trace-world seam (level 53).

const SEED := 20261127
const BODIES := 12
const TICKS := 400
const STEP := 1.0 / 60.0
## Per tick: positions farther apart than this (metres) part a body.
const POS_EPS := 1e-3
## Per tick: velocities farther apart than this (metres a second) part a body.
const VEL_EPS := 1e-2
const BENCH_BODIES := 31
const BENCH_TICKS := 300
const IMPORTED: Array[StringName] = [&"dm-industrial-gamma", &"surf_ski_2", &"cp-orange-x3"]

var _sections := 0
var _finished := 0
var _checks := 0
## The physics bodies' node (the suite itself is not 3D).
var _anchor := Node3D.new()


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	add_child(_anchor)
	_run.call_deferred()


func _run() -> void:
	print("motor on mirror — the native motor tick against gs-sim's mirror and against the physics space")
	if not GSSim.has(&"trace_mirror") or not FcTraceMirror.motor_available():
		print("no GSSimFpsBody.set_trace_mirror or GSFpsPhysicsBody.set_trace_world — nothing to compare")
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
	await _prediction(FcMap.dm_pit())
	await _near(FcMap.dm_pit())
	_follow()
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

	var parted := 0
	var first := [TICKS, -1]
	var worst := 0.0
	var worst_any := 0.0
	for b in BODIES:
		worst_any = maxf(worst_any, _max_gap(space_runs[b], mirror_runs[b]))
		var t := _parting(space_runs[b], mirror_runs[b])
		if t < 0:
			continue
		parted += 1
		worst = maxf(worst, ((space_runs[b][TICKS - 1] as Array)[0] as Vector3).distance_to(
			(mirror_runs[b][TICKS - 1] as Array)[0]))
		if t < int(first[0]):
			first = [t, b]
	print("     %d of %d bodies part (pos > %s m, vel > %s m/s or mode, any tick); largest gap any tick %.6f m, worst end gap %.4f m" % [
		parted, BODIES, POS_EPS, VEL_EPS, worst_any, worst])
	if int(first[1]) >= 0:
		var b := int(first[1])
		var t := int(first[0])
		var sp: Array = space_runs[b]
		var mp: Array = mirror_runs[b]
		print("     first parting: body %d (%s) tick %d start %s cmd %s\n       space  %s\n       mirror %s\n       prev space  %s\n       prev mirror %s" % [
			b, "scripted" if b % 2 == 1 else "random", t, starts[b % starts.size()], _cmd(streams[b][t]),
			_row(sp[t]), _row(mp[t]), _row(sp[maxi(t - 1, 0)]), _row(mp[maxi(t - 1, 0)])])
	_check(parted == 0, "%s: every body, every tick, the mirror within %s m / %s m/s of the space (%d of %d parted)" % [
		label, POS_EPS, VEL_EPS, parted, BODIES])
	if label == "cp-orange-x3":
		_bench(mirror, starts)
	FcTraceMirror.reset()
	_drop(solid)
	_finished += 1


## One body's [position, velocity, mode] tick by tick against [param mirror] or (null) the space.
func _replay(mirror: Object, start: Vector3, stream: Array[GSFpsCommand]) -> Array:
	var motor := _motor(mirror)
	var s := GSFpsState.new()
	s.position = start
	s.mode = GSFpsState.Mode.AIR
	var out: Array = []
	for c in stream:
		motor.simulate(s, c, STEP)
		out.append([s.position, s.velocity, int(s.mode)])
	return out


## The first tick two runs part, or -1.
func _parting(a: Array, b: Array) -> int:
	for t in a.size():
		var x: Array = a[t]
		var y: Array = b[t]
		if (x[0] as Vector3).distance_to(y[0]) > POS_EPS or (x[1] as Vector3).distance_to(y[1]) > VEL_EPS \
				or int(x[2]) != int(y[2]):
			return t
	return -1


func _max_gap(a: Array, b: Array) -> float:
	var out := 0.0
	for t in a.size():
		out = maxf(out, ((a[t] as Array)[0] as Vector3).distance_to((b[t] as Array)[0]))
	return out


func _row(r: Array) -> String:
	return "pos %s vel %s mode %d" % [r[0], r[1], r[2]]


func _motor(mirror: Object) -> GSFpsMotor:
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = true
	GSFpsMotor.native_full = true
	var body := GSFpsPhysicsBody.for_node(_anchor)
	var _on := FcTraceMirror.bind_body(body, mirror)
	return GSFpsMotor.new(FcPlayerTunables.make(), body)


## The server's mirror and a client's, each built from its own copy of the map's solid (as each end builds the map
## from the def): every body ticks to the bit against both, so a client predicting under the mirror asks the world
## the server answers from.
func _prediction(map: FcMap) -> void:
	_sections += 1
	print("-- prediction: a server's and a client's mirror, built apart")
	var server_solid := map.to_collision()
	var client_solid := map.to_collision()
	add_child(server_solid)
	add_child(client_solid)
	await get_tree().physics_frame
	var server: Object = ClassDB.instantiate(&"GSSimTraceMirror")
	server.call(&"load_scene", server_solid)
	var client: Object = ClassDB.instantiate(&"GSSimTraceMirror")
	client.call(&"load_scene", client_solid)
	var starts := _starts(map)
	var differ := 0
	for b in BODIES:
		var stream := _stream(SEED ^ (b * 104729), b % 2 == 0)
		var a := _replay(server, starts[b % starts.size()], stream)
		var c := _replay(client, starts[b % starts.size()], stream)
		for t in TICKS:
			if a[t] != c[t]:
				differ += 1
				print("     body %d parts at tick %d: server %s client %s" % [b, t, _row(a[t]), _row(c[t])])
				break
	_check(differ == 0, "prediction: %d bodies x %d ticks bit-identical against the server's and the client's mirror (%d differ)" % [
		BODIES, TICKS, differ])
	_drop(server_solid)
	_drop(client_solid)
	_finished += 1


## What the motor's mirror does not hold sends a body back to the space: a toy (RigidBody3D), a mover
## (AnimatableBody3D) and a mirrored brush the body excludes, each beside a player; open floor keeps the mirror.
func _near(map: FcMap) -> void:
	_sections += 1
	print("-- near: toys, movers and excluded brushes send the motor back to the space")
	var solid := map.to_collision()
	add_child(solid)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var start := _starts(map)[0]
	var body := GSFpsPhysicsBody.for_node(_anchor)
	body.collision_mask = 0xFFFFFFFF
	_check(FcTraceMirror.clear_near(body, start, 1.83, 0.0, solid), "near: a player on the map's open floor keeps the mirror")
	var kinds: Array[CollisionObject3D] = [RigidBody3D.new(), AnimatableBody3D.new()]
	for k in kinds:
		var shape := CollisionShape3D.new()
		shape.shape = BoxShape3D.new()
		k.add_child(shape)
		k.position = start + Vector3(1.0, 0.9, 0.0)
		if k is RigidBody3D:
			(k as RigidBody3D).freeze = true
			add_child(k)
		else:
			solid.add_child(k)
		await get_tree().physics_frame
		await get_tree().physics_frame
		_check(not FcTraceMirror.clear_near(body, start, 1.83, 0.0, solid),
			"near: a %s a metre away sends the motor back to the space" % k.get_class())
		k.get_parent().remove_child(k)
		k.free()
	await get_tree().physics_frame
	var probe := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = FcTraceMirror.NEAR_RADIUS
	probe.shape = sphere
	probe.transform = Transform3D(Basis.IDENTITY, start + Vector3(0.0, 0.9, 0.0))
	var hits: Array[Dictionary] = _anchor.get_world_3d().direct_space_state.intersect_shape(probe, 1)
	var brush := RID()
	if not hits.is_empty():
		brush = hits[0].get("rid", RID())
	var excluded: Array[RID] = [brush]
	body.exclude = excluded
	_check(brush.is_valid() and not FcTraceMirror.clear_near(body, start, 1.83, 0.0, solid),
		"near: a mirrored brush the player excludes sends the motor back to the space")
	_drop(solid)
	_finished += 1


## A client follows the server's replicated sv_trace_mirror through its link.
func _follow() -> void:
	_sections += 1
	print("-- follow: the client takes the server's sv_trace_mirror")
	var link := _FakeLink.new()
	link.held = "0"
	var was := FcTraceMirror.enabled
	_check(FcTraceMirror.follow_cvars(link) and not FcTraceMirror.enabled,
		"follow: the held value 0 turns the client's mirror off")
	link.replicated_cvar_changed.emit("sv_trace_mirror", "1")
	_check(FcTraceMirror.enabled, "follow: a change to 1 turns it back on")
	FcTraceMirror.enabled = was
	_finished += 1


class _FakeLink:
	extends RefCounted
	signal replicated_cvar_changed(cvar_name: String, value: String)
	var held := ""

	func replicated_cvar(cvar_name: String, fallback: String) -> String:
		return held if cvar_name == "sv_trace_mirror" else fallback


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
