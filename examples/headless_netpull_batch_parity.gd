extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcPlayerNet := preload("../game/fc_player_net.gd")
const FcNetPullNative := preload("../game/fc_net_pull_native.gd")
const FcNetPullWeapons := preload("../game/fc_net_pull_weapons.gd")
const FcNetPullBatch := preload("../game/fc_net_pull_batch.gd")
const MoveParity := preload("headless_netpull_native_parity.gd")
const WeaponParity := preload("headless_netpull_weapons_parity.gd")

## The batched pull (FcNetPullBatch, `sv_net_pull_batch`, with and without `sv_net_pull_apply_native`) writes every replicated net_* field,
## the identity's relevance and the snapshot state bytes as each player's own FcPlayerNet.pull does, to the bit, over seeded bots and
## people, arsenals, rigs and wind-ups. Without the library the suite says so.

const ROUNDS := 4000
const SEED := 6262
const PLAYERS := 6
## [max_speed, velocity_bits, yaw_bits, pitch_bits]: MoveParity.WIRES, then a velocity width only the script handles.
const WIRES := [[0.0, 0, 0, 0], [100.0, 12, 0, 0], [40.0, 10, 9, 8], [300.0, 16, 12, 16], [10.0, 1, 1, 1], [100.0, 63, 16, 16]]
const DECLINED := 5

var _checks := 0
var _failed := 0
var _move := MoveParity.new()
var _weapon := WeaponParity.new()
var _fields: Array[StringName] = []
var _base: Array = []


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail := "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _run() -> void:
	print("FC — every player's pull in one call: batch and per-player pulls agree")
	var game := FcGame.new()
	game.name = "G"
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = FcMode.team_deathmatch()
	add_child(game)
	_check(game.setup(FcMap.dm_atrium()).ok, "a game sets up")
	game.start(0)
	for k in PLAYERS:
		var _added := game.add_player(31 + k, "P%d" % k)
	game.tick({})
	var nets: Array = []
	var configs: Array = []
	for k in PLAYERS:
		var net := FcPlayerNet.new()
		net.player = game.player_for(31 + k)
		net._bind(GSNetConfig.new())
		var identity := GSNetIdentity.new()
		identity.is_authoritative = true
		identity.owner_peer_id = 0 if k % 2 == 0 else 7 + k
		net.identity = identity
		nets.append(net)
		configs.append(GSNetConfig.new())
	for p in nets[0].get_property_list():
		if (p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) and String(p.name).begins_with("net_"):
			_fields.append(StringName(p.name))
	for f in _fields:
		_base.append(nets[0].get(f))
	var armed := true
	for net: FcPlayerNet in nets:
		armed = armed and net.player.weapons != null and net.player.weapons.arsenal != null and not net.player.arsenal._slots.is_empty()
	_check(armed and _fields.size() > 30, "every player has a rig and an armed arsenal", "%d net_* fields" % _fields.size())

	var native := FcNetPullBatch.native() != null and FcNetPullNative.native_pack() != null and FcNetPullWeapons.native() != null
	if not native:
		print("gs-sim has no GSSimFpsNetPullBatch: only the per-player lanes are exercised")
	var was := [FcPlayerNet.hold_subquantum, FcNetPullBatch.enabled, FcNetPullNative.enabled, FcNetPullWeapons.weapons_enabled,
			FcNetPullWeapons.content_enabled, FcNetPullBatch.apply_native]
	if native:
		_check(FcNetPullBatch.applies_natively(), "gs-sim writes the batch's fields (GSSimFpsNetPullBatch.pull_apply)")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var run := _rounds(nets, configs, rng, native)
	var differ: Array = run[0]
	var first: String = run[1]
	var batched: int = run[2]
	var expect_batched: int = run[3]
	FcPlayerNet.hold_subquantum = was[0]
	FcNetPullBatch.enabled = was[1]
	FcNetPullNative.enabled = was[2]
	FcNetPullWeapons.weapons_enabled = was[3]
	FcNetPullWeapons.content_enabled = was[4]
	FcNetPullBatch.apply_native = was[5]
	print("  %d rounds of %d players, %d player pulls through the batch" % [ROUNDS, PLAYERS, batched])
	_check(differ[0] == 0, "batch net_* equal each player's script pull to the bit", "%d differ; %s" % [differ[0], first])
	_check(differ[1] == 0, "and each player's native pull", "%d differ; %s" % [differ[1], first])
	_check(differ[2] == 0, "and the batch with the script writing the fields, snapshot bytes included", "%d differ; %s" % [differ[2], first])
	if native:
		_check(batched == expect_batched, "every player the batch can pull went through it, the declined width did not",
				"%d of %d" % [batched, expect_batched])
		FcNetPullBatch.enabled = false
		_check(FcNetPullBatch.pull_all(nets, ROUNDS + 1) == 0, "sv_net_pull_batch 0 pulls nobody")
		FcNetPullBatch.enabled = was[1]
		_bench(nets, configs, rng)
	for net: FcPlayerNet in nets:
		net.identity.free()
		net.free()
	_move.free()
	_weapon.free()
	var expected := 8 if native else 5
	var ok := _failed == 0 and _checks == expected
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, expected])
	get_tree().quit(0 if ok else 1)


## [constant ROUNDS] seeded rounds in four lanes (batch with gs-sim writing the fields, script, per-player natives, batch
## with the script writing them): [differences per other lane, the first, players batched, players the batch should take].
func _rounds(nets: Array, configs: Array, rng: RandomNumberGenerator, native: bool) -> Array:
	var differ := [0, 0, 0]
	var first := ""
	var batched := 0
	var expect_batched := 0
	for i in ROUNDS:
		FcPlayerNet.hold_subquantum = i % 11 != 0
		var start := rng.state
		var lanes: Array = []
		for lane in 4:
			rng.state = start
			_seed_round(nets, configs, rng, i, i % 2 == 0)
			_set_natives(lane != 1, lane == 0 or lane == 3)
			FcNetPullBatch.apply_native = lane == 0
			if lane == 0 or lane == 3:
				var n := FcNetPullBatch.pull_all(nets, i)
				if lane == 0:
					batched += n
				for net: FcPlayerNet in nets:
					if net._batched_tick != i:
						net.pull()
			else:
				for net: FcPlayerNet in nets:
					net.pull()
			lanes.append(_read(nets))
		if native:
			for k in PLAYERS:
				if FcPlayerNet.hold_subquantum and (i + k) % WIRES.size() == DECLINED:
					continue
				expect_batched += 1
		for other in 3:
			if var_to_bytes(lanes[0]) != var_to_bytes(lanes[other + 1]):
				differ[other] += 1
				if first == "":
					first = "round %d vs %s: %s" % [i, ["script", "native", "script apply"][other],
						_first_diff(lanes[0], lanes[other + 1])]
	return [differ, first, batched, expect_batched]


## Seeds every player's movement, held values, wire widths, rig and wind-up from [param rng], then poisons each
## net_* field (alternating bools by [param poison]) and puts back the held movement values.
func _seed_round(nets: Array, configs: Array, rng: RandomNumberGenerator, at: int, poison: bool) -> void:
	for k in nets.size():
		var net: FcPlayerNet = nets[k]
		var wire: Array = WIRES[(at + k) % WIRES.size()]
		_move._configure(net, configs[k], wire)
		var state: GSFpsState = net.player.controller.state
		_move._randomize(state, rng)
		var held := _move._held(state, rng, wire)
		var arsenal: GSWeaponArsenal = net.player.arsenal
		net.player.windup = _weapon._randomize(net.player.weapons, arsenal, arsenal._slots.keys(), rng)
		for f in _fields.size():
			var v: Variant = _base[f]
			match typeof(v):
				TYPE_BOOL:
					v = poison
				TYPE_INT:
					v = -7
				TYPE_FLOAT:
					v = -7.0
			net.set(_fields[f], v)
		for f in MoveParity.FIELDS.size():
			net.set(MoveParity.FIELDS[f], held[f])
		net._batched_tick = -1
		net.identity.always_relevant = not poison


## Batch on ([param batch]) needs the per-player natives on ([param natives]); both off is the script.
func _set_natives(natives: bool, batch: bool) -> void:
	FcNetPullNative.enabled = natives
	FcNetPullWeapons.weapons_enabled = natives
	FcNetPullWeapons.content_enabled = natives
	FcNetPullBatch.enabled = batch


## Every net_* field of every player, then its identity's relevance and its snapshot state bytes (all declarations).
func _read(nets: Array) -> Array:
	var out: Array = []
	for net: FcPlayerNet in nets:
		for f in _fields:
			out.append(net.get(f))
		out.append(net.identity.always_relevant)
		out.append(net._encode(net.net_vars)[0])
	return out


func _first_diff(a: Array, b: Array) -> String:
	var per := _fields.size() + 2
	for j in a.size():
		if var_to_bytes(a[j]) != var_to_bytes(b[j]):
			var f := j % per
			var what: StringName = _fields[f] if f < _fields.size() else [&"always_relevant", &"snapshot bytes"][f - _fields.size()]
			return "player %d %s: batch %s, other %s" % [j / per, what, a[j], b[j]]
	return "sizes %d, %d" % [a.size(), b.size()]


## Microseconds a tick for all players' pulls: each player alone through the natives, then the batch.
func _bench(nets: Array, configs: Array, rng: RandomNumberGenerator) -> void:
	_seed_round(nets, configs, rng, 0, false)
	FcPlayerNet.hold_subquantum = true
	var us := []
	for lane in 2:
		_set_natives(true, lane == 1)
		var t := Time.get_ticks_usec()
		for tick in 4000:
			if lane == 1:
				var _n := FcNetPullBatch.pull_all(nets, 100 + tick)
			else:
				for net: FcPlayerNet in nets:
					net.pull()
		us.append((Time.get_ticks_usec() - t) / 4000.0)
	print("  bench, %d players: per-player %.2f us, batch %.2f us a tick" % [nets.size(), us[0], us[1]])
