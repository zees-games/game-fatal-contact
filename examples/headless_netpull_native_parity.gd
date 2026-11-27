extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcPlayerNet := preload("../game/fc_player_net.gd")
const FcNetPullNative := preload("../game/fc_net_pull_native.gd")

## A player's movement pull (FcPlayerNet.pull, cvar `sv_net_pull_native`): gs-sim's `GSSimFpsNetPack.pull` writes the same net_* values
## as GSFpsNetSync.pull then FcPlayerNet._hold_subquantum, to the bit, over seeded states, held values, velocity configs, angle widths and
## the hold off; a declaration the native lane cannot mirror falls back to the script. Without the library only the script lane runs, and the suite says so.

const STATES := 20000
const SEED := 6060
const TICK_RATE := 64
const FIELDS: Array[StringName] = [&"net_position", &"net_velocity", &"net_yaw", &"net_pitch", &"net_crouch", &"net_flags",
		&"net_modifiers", &"net_timers2"]
## [max_speed, velocity_bits, yaw_bits, pitch_bits]: the default declarations, then others the lane must follow.
const WIRES := [[0.0, 0, 0, 0], [100.0, 12, 0, 0], [40.0, 10, 9, 8], [300.0, 16, 12, 16], [10.0, 1, 1, 1]]

var _checks := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail := "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _run() -> void:
	print("FC — movement pull: native and script agree")
	var game := FcGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = FcMode.team_deathmatch()
	add_child(game)
	_check(game.setup(FcMap.dm_atrium()).ok, "a game sets up")
	game.start(0)
	var _a := game.add_player(31, "A")
	game.tick({})
	var player := game.player_for(31)
	var net := FcPlayerNet.new()
	net.player = player
	net._bind(GSNetConfig.new())
	_check(net._velocity_var != null and net._yaw_var != null and net._pitch_var != null, "the pull declares velocity, yaw and pitch")

	var native := FcNetPullNative.native_pack() != null
	if not native:
		print("gs-sim has no GSSimFpsNetPack.pull: only the script lane is exercised")
	var was_hold := FcPlayerNet.hold_subquantum
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var differ := 0
	var native_ran := 0
	var held_counts := [0, 0, 0]
	var first := ""
	var config := GSNetConfig.new()
	for i in STATES:
		var wire: Array = WIRES[i % WIRES.size()]
		FcPlayerNet.hold_subquantum = i % 11 != 0
		_configure(net, config, wire)
		_randomize(player.controller.state, rng)
		var held := _held(player.controller.state, rng, wire)
		var script := _lane(net, held, false)
		for k in 3:
			if script[FIELDS.size()] & (1 << k):
				held_counts[k] += 1
		var got := _lane(net, held, true)
		if got.is_empty():
			continue
		native_ran += 1
		if var_to_bytes(got.slice(0, FIELDS.size())) != var_to_bytes(script.slice(0, FIELDS.size())):
			differ += 1
			if first == "":
				first = "state %d: native %s, script %s" % [i, got, script]
	FcPlayerNet.hold_subquantum = was_hold
	print("  %d states, %d through gs-sim; held velocity %d, yaw %d, pitch %d" % [STATES, native_ran, held_counts[0], held_counts[1], held_counts[2]])
	_check(held_counts[0] > STATES / 20 and held_counts[1] > STATES / 20 and held_counts[2] > STATES / 20,
			"the seeded held values hold each field often", str(held_counts))
	if native:
		_check(native_ran == STATES, "every state ran through gs-sim", "%d of %d" % [native_ran, STATES])
		_check(differ == 0, "native net_* equal the script's to the bit", "%d differ; %s" % [differ, first])
		_configure(net, config, [100.0, 63, 16, 16])
		_check(_lane(net, _held(player.controller.state, rng, WIRES[1]), true).is_empty(),
				"a velocity width gs-net round-trips (63 bits) is left to the script")
		_configure(net, config, [100.0, 12, 64, 16])
		_check(_lane(net, _held(player.controller.state, rng, WIRES[1]), true).is_empty(), "so is a 64-bit angle")
		_bench(net, player.controller.state, rng)
	net.free()
	var expected := 7 if native else 3
	var ok := _failed == 0 and _checks == expected
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, expected])
	get_tree().quit(0 if ok else 1)


## Sets the declarations to [param wire] ([code][max_speed, velocity_bits, yaw_bits, pitch_bits][/code]; zeros are the defaults).
func _configure(net: FcPlayerNet, config: GSNetConfig, wire: Array) -> void:
	if float(wire[0]) > 0.0:
		config.max_speed = float(wire[0])
		config.velocity_bits = int(wire[1])
		net._velocity_var.bind_config(config)
	else:
		net._velocity_var.bind_config(null)
	net._yaw_var.bit_width = int(wire[2]) if int(wire[2]) > 0 else 16
	net._pitch_var.bit_width = int(wire[3]) if int(wire[3]) > 0 else 16
	net._native_pull.invalidate()


## The movement fields one lane writes, then the script lane's hold mask, from the same held values; empty when the native lane declines.
func _lane(net: FcPlayerNet, held: Array, native: bool) -> Array:
	for k in FIELDS.size():
		net.set(FIELDS[k], held[k])
	if native:
		if not net._native_pull.pull(net, FcPlayerNet.hold_subquantum, held[1], held[2], held[3]):
			return []
	else:
		GSFpsNetSync.pull(net.player.controller.state, net)
		var raw := [net.net_velocity, net.net_yaw, net.net_pitch]
		if FcPlayerNet.hold_subquantum:
			net._hold_subquantum(held[1], held[2], held[3])
		var mask := 0
		if net.net_velocity == held[1] and raw[0] != held[1]:
			mask |= 1
		if net.net_yaw == held[2] and raw[1] != held[2]:
			mask |= 2
		if net.net_pitch == held[3] and raw[2] != held[3]:
			mask |= 4
		var out: Array = []
		for p in FIELDS:
			out.append(net.get(p))
		out.append(mask)
		return out
	var got: Array = []
	for p in FIELDS:
		got.append(net.get(p))
	return got


func _randomize(state: GSFpsState, rng: RandomNumberGenerator) -> void:
	state.position = Vector3(rng.randf_range(-500.0, 500.0), rng.randf_range(-50.0, 50.0), rng.randf_range(-500.0, 500.0))
	var speed: float = [0.0, 1.0, 12.0, 60.0, 150.0, 400.0][rng.randi_range(0, 5)]
	state.velocity = Vector3(rng.randf_range(-speed, speed), rng.randf_range(-speed, speed), rng.randf_range(-speed, speed))
	var yaws := [rng.randf_range(-720.0, 720.0), rng.randf_range(0.0, 360.0), 0.0, -0.0, 360.0, -180.0, 359.999]
	state.yaw = yaws[rng.randi_range(0, 6)]
	var pitches := [rng.randf_range(-89.0, 89.0), 0.0, -89.0, 89.0]
	state.pitch = pitches[rng.randi_range(0, 3)]
	state.crouch_fraction = rng.randf() if rng.randf() < 0.3 else 0.0
	state.crouch_held = rng.randf() < 0.2
	state.mode = rng.randi_range(0, 2)
	state.slide_time = -1.0 if rng.randf() < 0.8 else rng.randf()
	state.time_since_jump = rng.randf_range(0.0, 3.0)
	state.stamina = rng.randf()
	state.stamina_exhausted = rng.randf() < 0.1


## Held net_* values: unchanged, a sub-quantum step, a step across the nearest code boundary, or far off.
func _held(state: GSFpsState, rng: RandomNumberGenerator, wire: Array) -> Array:
	var speed := float(wire[0]) if float(wire[0]) > 0.0 else 100.0
	var velocity_step := 2.0 * speed / float((1 << (int(wire[1]) if int(wire[1]) > 0 else 12)) - 1)
	var held := [state.position, state.velocity, state.yaw, state.pitch, 0.0, 0, 0, 0]
	var v := state.velocity
	match rng.randi_range(0, 3):
		1:
			v += Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(-0.2, 0.2), 0.0) * velocity_step
		2:
			v.x = (roundf(v.x / velocity_step) + 0.5) * velocity_step + rng.randf_range(-1e-4, 1e-4) * velocity_step
		3:
			v += Vector3(rng.randf_range(-5.0, 5.0), 0.0, rng.randf_range(-5.0, 5.0))
	held[1] = v
	held[2] = _held_angle(state.yaw, rng, int(wire[2]) if int(wire[2]) > 0 else 16)
	held[3] = _held_angle(state.pitch, rng, int(wire[3]) if int(wire[3]) > 0 else 16)
	return held


func _held_angle(degrees: float, rng: RandomNumberGenerator, bits: int) -> float:
	var step := 360.0 / float((1 << bits) - 1)
	match rng.randi_range(0, 4):
		1:
			return degrees + rng.randf_range(-0.2, 0.2) * step
		2:
			return (roundf(degrees / step) + 0.5) * step + rng.randf_range(-1e-6, 1e-6)
		3:
			return degrees + 360.0 * rng.randi_range(-2, 2) + rng.randf_range(-0.1, 0.1) * step
		4:
			return degrees + rng.randf_range(-30.0, 30.0)
	return degrees


func _bench(net: FcPlayerNet, state: GSFpsState, rng: RandomNumberGenerator) -> void:
	var config := GSNetConfig.new()
	_configure(net, config, WIRES[0])
	FcPlayerNet.hold_subquantum = true
	var held := _held(state, rng, WIRES[0])
	var rounds := 20000
	var t := Time.get_ticks_usec()
	for _k in rounds:
		GSFpsNetSync.pull(state, net)
		net._hold_subquantum(held[1], held[2], held[3])
	var script_us := float(Time.get_ticks_usec() - t) / rounds
	t = Time.get_ticks_usec()
	for _k in rounds:
		net._native_pull.pull(net, FcPlayerNet.hold_subquantum, held[1], held[2], held[3])
	var native_us := float(Time.get_ticks_usec() - t) / rounds
	print("  bench: script %.2f us, native %.2f us per pull" % [script_us, native_us])
