extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcModule := preload("../game/fc_module.gd")
const LoopbackServer := preload("loopback_server.gd")
const FcPresentation := preload("../game/fc_presentation.gd")
const FcFrameProbe := preload("../game/fc_frame_probe.gd")
const FcHullGrid := preload("../game/fc_hull_grid.gd")
const FcBotBrain := preload("../game/fc_bot_brain.gd")
const FcBotThreads := preload("../game/fc_bot_threads.gd")
const FcBots := preload("../game/fc_bots.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcBotPvs := preload("../game/fc_bot_pvs.gd")
const FcBotsWorld := preload("../game/fc_bots_world.gd")

## The 128-player scale harness (nightly arena-128-scale-1). Measures; asserts nothing; prints one `SCALE128 {json}` line. Driven by tools/scale128.sh, which runs it through `heavy`.
## `godot --headless --path . res://tools/scale128.tscn -- --role server --bots 64 --tick 33 --seconds 30` (or `--role offline --bots 32 --tick 66 --seconds 20`). [b]server[/b]: GSServer + FcModule with N bots, no client, one physics tick timed three ways (script half between sentinels, TIME_PHYSICS_PROCESS, wall-clock ticks/s).
## [b]offline[/b]: the real offline client (game, bots and drawing in one process), the same numbers plus how fast game time ran against the wall clock (`sim_speed`) and a node census of one other player.

var _role := "server"
var _bots := 16
var _tick := 66
var _seconds := 30.0
var _settle := 4.0
var _port := 27230
var _map := "dm_box"
var _mode := "ffa"
## --botstyles: the bot_styles value (gs-bot weapon styles); empty leaves the default.
var _botstyles := ""

var _t_start := 0
var _script_us := PackedFloat64Array()
var _phys_ms := PackedFloat64Array()
var _count := 0
var _first: Node = null
var _last: Node = null
var _recording := false


class Sentinel extends Node:
	var bench: Node
	var is_start := true
	func _physics_process(_d: float) -> void:
		bench._sentinel(is_start)


var _t0 := 0
## --nodeprobe: a stamp after each physics-processing node; each spike tick keeps the gap ending at each stamp.
var _stamps: Array = []


class Stamp extends Node:
	var bench: Node
	var label := ""
	func _physics_process(_d: float) -> void:
		if bench._recording:
			bench._stamps.append([label, Time.get_ticks_usec()])


func _sentinel(is_start: bool) -> void:
	if not _recording:
		return
	var now := Time.get_ticks_usec()
	if is_start:
		if _cellab > 0 and _count > 0 and _count % _cellab == 0:
			_ab_flip()
		_t0 = now
		_count += 1
		if _cellab > 0:
			_ab_ticks[_ab_side] += 1
		if _spikes:
			_spike_open(now)
	else:
		_script_us.append(float(now - _t0))
		if _spikes:
			_spike_close(now - _t0)
		if _cellab > 0:
			_ab_script[_ab_side] += float(now - _t0)
		_phys_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)


const _PlayerBody := preload("res://game/fc_player_body.gd")

## --cellab N: an in-process A/B of gs-sim's binding cell (GSSimCell): every N ticks the run flips between the patched
## cell (side 0, notify only waiters) and upstream's notify-on-every-drop (side 1); the report splits the sections by side.
var _cellab := 0
## --weapab N: the same alternating A/B for gs-weapon's native hitscan spread tick (GSWeaponHitscan.native_tick):
## side 0 ("patched") runs gs-sim's GSSimWeaponSpread, side 1 ("upstream") the GDScript tick.
var _ab_weap := false
## --leanab N: the same alternating A/B for the server's lean players' loop (FcPlayer.lean_tick): side 0 ("patched") lean,
## side 1 ("upstream") every per-player call the long way.
var _ab_lean := false
## --gateab N: the same alternating A/B for gs-weapon's idle gate (GSWeaponBehaviour.idle_gate): side 0 ("patched") 1,
## the cached native rows reused while they provably hold; side 1 ("upstream") 0, every idle row re-read and re-checked.
## --idlegate 2 runs the verify mode instead; the report counts its misses either way.
var _ab_gate := false
var _ab_side := 0
var _ab_ticks := PackedInt64Array([0, 0])
var _ab_script := PackedFloat64Array([0.0, 0.0])
var _ab_snap := {}
var _ab_acc: Array[Dictionary] = [{}, {}]
var _ab_net: Object = null
var _ab_net_snap := PackedInt64Array([0, 0])
var _ab_net_acc := PackedInt64Array([0, 0, 0, 0])


func _ab_begin() -> void:
	if _cellab <= 0:
		return
	var need := &"GSSimWeaponSpread" if _ab_weap else &"GSSimCell"
	if not _ab_lean and not _ab_gate and not ClassDB.class_exists(need):
		push_error("scale128: --%s needs gs-sim's %s" % ["weapab" if _ab_weap else "cellab", need])
		get_tree().quit(1)
		return
	_ab_side = 0
	_ab_ticks = PackedInt64Array([0, 0])
	_ab_script = PackedFloat64Array([0.0, 0.0])
	_ab_acc = [{}, {}]
	_ab_net_acc = PackedInt64Array([0, 0, 0, 0])
	_ab_set(0)
	_ab_take_snap()


func _ab_set(side: int) -> void:
	if _ab_lean:
		FcPlayer.lean_tick = side == 0
	elif _ab_gate:
		GSWeaponBehaviour.idle_gate = 1 if side == 0 else 0
	elif _ab_weap:
		GSWeaponHitscan.native_tick = side == 0
	else:
		ClassDB.class_call_static(&"GSSimCell", &"set_notify_always", side == 1)


func _ab_take_snap() -> void:
	_ab_snap.clear()
	for k in FcFrameProbe._sections:
		_ab_snap[k] = (FcFrameProbe._sections[k] as PackedInt64Array)[0]
	if _ab_net != null:
		var c: Dictionary = _ab_net.perf_counters()
		_ab_net_snap = PackedInt64Array([int(c[&"server_sim_usec"]), int(c[&"server_ticks"])])


## Adds the window just run to its side and switches the cell to the other side.
func _ab_flush() -> void:
	var acc := _ab_acc[_ab_side]
	for k in FcFrameProbe._sections:
		acc[k] = int(acc.get(k, 0)) + (FcFrameProbe._sections[k] as PackedInt64Array)[0] - int(_ab_snap.get(k, 0))
	if _ab_net != null:
		var c: Dictionary = _ab_net.perf_counters()
		_ab_net_acc[_ab_side * 2] += int(c[&"server_sim_usec"]) - _ab_net_snap[0]
		_ab_net_acc[_ab_side * 2 + 1] += int(c[&"server_ticks"]) - _ab_net_snap[1]


func _ab_flip() -> void:
	_ab_flush()
	_ab_side = 1 - _ab_side
	_ab_set(_ab_side)
	_ab_take_snap()


func _ab_report() -> Dictionary:
	if _cellab <= 0:
		return {}
	_ab_flush()
	_ab_set(0)
	var out := {}
	for side in 2:
		var n := maxi(1, _ab_ticks[side])
		var sec := {}
		for k in _ab_acc[side]:
			sec[String(k)] = snappedf(int(_ab_acc[side][k]) / 1000.0 / n, 0.001)
		out["patched" if side == 0 else "upstream"] = {
			"ticks": _ab_ticks[side], "script_ms": snappedf(_ab_script[side] / 1000.0 / n, 0.001),
			"net_sim_ms": snappedf(_ab_net_acc[side * 2] / 1000.0 / maxi(1, _ab_net_acc[side * 2 + 1]), 0.001),
			"sections_ms": sec,
		}
	var key := "leanab" if _ab_lean else ("gateab" if _ab_gate else ("weapab" if _ab_weap else "cellab"))
	return {key: out}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--role": _role = args[i + 1]
			"--bots": _bots = int(args[i + 1])
			"--tick": _tick = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--port": _port = int(args[i + 1])
			"--map": _map = args[i + 1]
			"--mode": _mode = args[i + 1]
			"--fastsense": FcBotBrain.fast_sense = args[i + 1] != "0"
			"--hullgrid": FcHullGrid.enabled = args[i + 1] != "0"
			"--hullfast": FcHullGrid.fast = args[i + 1] != "0"
			"--worldcoarse": GSFpsFlatBody.world_coarse = args[i + 1] != "0"
			"--hullverify": FcHullGrid.verify = args[i + 1] != "0"
			"--hullnative": FcHullGrid.native = args[i + 1] != "0"
			"--threads": FcBotThreads.threads = int(args[i + 1])
			"--thinkevery": FcBots.think_every = int(args[i + 1])
			"--thinknear": FcBots.think_near = float(args[i + 1])
			"--tierabove": FcBots.tiers.above = int(args[i + 1])
			"--motorprof": _motorprof = args[i + 1] != "0"
			"--spawn": _spawn = args[i + 1] != "0"
			"--botstyles": _botstyles = args[i + 1]
			"--wphases":
				AwWeaponRig.phase_timers = args[i + 1] != "0"
				GSWeaponArsenal.phase_timers = AwWeaponRig.phase_timers
			# --wlane 0: idle weapons through the arsenal's idle_still and idle_posture callables (the row lane's A/B arm).
			# --bphases 1: GSBotBrain's phase clocks (bb_*, main thread only: with --threads 0), the split of bot_brain.
			"--bphases": (GSBotBrain as GDScript).set(&"phase_timers", args[i + 1] != "0")
			# --pvs/--pvsnative/--pvsverify: the bots' PVS pre-cull before a sight ray (fc_bot_pvs*).
			"--pvs": FcBotPvs.enabled = args[i + 1] != "0"
			"--pvsnative": FcBotPvs.native = args[i + 1] != "0"
			"--pvsverify": FcBotPvs.verify = args[i + 1] != "0"
			"--wlane": _PlayerBody.idle_row_lane = args[i + 1] != "0"
			"--native": GSBotWorld.native_enabled = args[i + 1] != "0"
			# --scanbudget/--pairsight/--sightgrid: the bot perception cvars (bot_scan_budget, bot_pair_sight, bot_sight_grid);
			# all three 0 is the perception before them.
			"--scanbudget": FcBots.scan_budget = int(args[i + 1])
			"--pairsight": FcBots.pair_sight = args[i + 1] != "0"
			"--sightgrid": FcBots.sight_grid = float(args[i + 1])
			# --native-sight 0: bot sight rays through script, never gs-sim's native ray (the A/B of World.native_sight).
			"--native-sight": FcBotsWorld.World.native_sight = args[i + 1] != "0"
			"--motornative": GSFpsPhysicsBody.native_enabled = args[i + 1] != "0"
			# --fine 1: FcFrameProbe.fine for the recording, so the sections split tick_players, bots and the world (laps).
			"--fine": _fine = args[i + 1] != "0"
			"--cellab": _cellab = int(args[i + 1])
			"--weapab":
				_cellab = int(args[i + 1])
				_ab_weap = _cellab > 0
			"--leanab":
				_cellab = int(args[i + 1])
				_ab_lean = _cellab > 0
			"--gateab":
				_cellab = int(args[i + 1])
				_ab_gate = _cellab > 0
			"--idlegate": GSWeaponBehaviour.idle_gate = int(args[i + 1])
			# --engaged 1: the firefight preset (dm_box, everyone spawned and respawned), so the bots meet within seconds.
			"--engaged":
				if args[i + 1] != "0":
					_map = "dm_box"
					_spawn = true
			"--settle": _settle = float(args[i + 1])
			# --spikes 1: keeps the worst ticks with the sections each one spent (a dictionary snapshot per tick: opt-in).
			"--spikes": _spikes = args[i + 1] != "0"
			# --pin 2-5: pins every thread of this process to those cores (taskset), away from the host's other work.
			"--pin": _pin = args[i + 1]
	if not _pin_threads():
		return
	GSLog.set_level(GSLog.Level.ERROR)
	var _scratch := FcPresentation.use_scratch_settings("scale128_" + _role)
	for is_start in [true, false]:
		var s := Sentinel.new()
		s.bench = self
		s.is_start = is_start
		s.process_physics_priority = -1000000 if is_start else 1000000
		add_child(s)
	if _role == "offline":
		_offline.call_deferred()
	else:
		_serve.call_deferred()


## --pin: taskset every thread of this process to [member _pin]; false (and quits) when taskset fails.
func _pin_threads() -> bool:
	if _pin == "":
		return true
	var out := []
	var rc := OS.execute("taskset", ["-a", "-p", "-c", _pin, str(OS.get_process_id())], out, true)
	if rc != 0:
		push_error("scale128: taskset -c %s failed (%d): %s" % [_pin, rc, out])
		get_tree().quit(1)
		return false
	return true


## --spikes: the [constant SPIKE_KEEP] slowest recorded ticks, each with the sections it spent and the combat in it.
const SPIKE_KEEP := 8
var _spikes := false
var _pin := ""
var _spike_snap := {}
var _spike_combat := PackedInt64Array([0, 0, 0])
var _worst: Array[Dictionary] = []
## Wall time between the starts of consecutive recorded ticks: what the engine did outside the physics step shows here.
var _gap_ms := PackedFloat64Array()
var _last_start := 0


func _spike_open(now: int) -> void:
	if _last_start > 0:
		_gap_ms.append((now - _last_start) / 1000.0)
	_last_start = now
	_spike_snap.clear()
	for k in FcFrameProbe._sections:
		_spike_snap[k] = (FcFrameProbe._sections[k] as PackedInt64Array)[0]
	_spike_combat = PackedInt64Array([_shots, _kills, _respawns])
	_stamps.clear()


func _spike_close(spent: int) -> void:
	if _worst.size() >= SPIKE_KEEP and spent <= int(_worst[-1]["us"]):
		return
	var parts := {}
	for k in FcFrameProbe._sections:
		var d: int = (FcFrameProbe._sections[k] as PackedInt64Array)[0] - int(_spike_snap.get(k, 0))
		if d >= 500:
			parts[String(k)] = snappedf(d / 1000.0, 0.1)
	var prev := _t0
	for st: Array in _stamps:
		if int(st[1]) - prev >= 500:
			parts["@" + String(st[0])] = snappedf((int(st[1]) - prev) / 1000.0, 0.1)
		prev = int(st[1])
	_worst.append({"us": spent, "tick": _count, "ms": snappedf(spent / 1000.0, 0.1), "sections": parts,
		"shots": _shots - _spike_combat[0], "kills": _kills - _spike_combat[1], "respawns": _respawns - _spike_combat[2]})
	_worst.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["us"]) > int(b["us"]))
	if _worst.size() > SPIKE_KEEP:
		_worst.resize(SPIKE_KEEP)


static func _stats(a: PackedFloat64Array, scale := 1.0) -> Dictionary:
	if a.is_empty():
		return {}
	var s := a.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	var n := s.size()
	return {
		"mean": snappedf(sum / n * scale, 0.001), "p50": snappedf(s[n / 2] * scale, 0.001),
		"p95": snappedf(s[mini(n - 1, int(n * 0.95))] * scale, 0.001),
		"p99": snappedf(s[mini(n - 1, int(n * 0.99))] * scale, 0.001), "max": snappedf(s[n - 1] * scale, 0.001),
	}


func _spike_report(out: Dictionary) -> void:
	if not _spikes:
		return
	out["gap_ms"] = _stats(_gap_ms)
	for w in _worst:
		w.erase("us")
	out["worst_ticks"] = _worst


func _rss_mb() -> float:
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return -1.0
	for line in f.get_as_text().split("\n"):
		if line.begins_with("VmRSS:"):
			return snappedf(float(line.split(" ", false)[1]) / 1024.0, 0.1)
	return -1.0


func _sections_ms(ticks: int) -> Dictionary:
	var out := {}
	for k in FcFrameProbe._sections:
		var row: PackedInt64Array = FcFrameProbe._sections[k]
		out[String(k)] = {"per_tick_ms": snappedf(row[0] / 1000.0 / maxi(1, ticks), 0.001), "calls": row[1], "max_ms": snappedf(row[2] / 1000.0, 0.001)}
	return out


func _report(extra: Dictionary) -> void:
	var wall := (Time.get_ticks_usec() - _t_start) / 1.0e6
	var budget_ms := 1000.0 / _tick
	var script := _stats(_script_us, 0.001)
	var out := {
		"role": _role, "bots": _bots, "tick_hz": _tick, "budget_ms": snappedf(budget_ms, 0.01),
		"wall_s": snappedf(wall, 0.1), "ticks": _count, "ticks_per_s": snappedf(_count / wall, 0.1),
		"tick_ratio": snappedf(_count / wall / _tick, 0.001),
		"script_ms": script, "physics_frame_ms": _stats(_phys_ms),
		"engine_ms_mean": snappedf(float(_stats(_phys_ms).get("mean", 0.0)) - float(script.get("mean", 0.0)), 0.001),
		"per_actor_us": snappedf(float(script.get("mean", 0.0)) * 1000.0 / maxi(1, _bots), 0.1),
		"mem_static_mb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"rss_mb": _rss_mb(), "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"sections": _sections_ms(_count),
		"verdict_holds": float(script.get("mean", 99999.0)) < 0.7 * budget_ms and float(script.get("p95", 99999.0)) < budget_ms and _count / wall / _tick > 0.97,
	}
	out["bot_threads"] = FcBotThreads.threads
	out["think_every"] = FcBots.think_every
	out["think_near"] = FcBots.think_near
	out["par_ticks"] = FcBotThreads.par_ticks
	out["tiers"] = FcBots.tiers.describe()
	# What the bots did while recorded, so a think-rate change shows its cost in play (shots per hit, kills).
	out["combat"] = {"shots": _shots, "hits": _hits, "headshots": _heads, "kills": _kills,
		"hit_rate": snappedf(float(_hits) / maxi(1, _shots), 0.001), "respawns": _respawns}
	var minutes := maxf(wall, 0.001) / 60.0
	out["per_min"] = {"shots": snappedf(_shots / minutes, 0.1), "kills": snappedf(_kills / minutes, 0.1),
		"respawns": snappedf(_respawns / minutes, 0.1)}
	out["over_budget_ticks"] = _over(budget_ms * 1000.0)
	_spike_report(out)
	out["native_scan"] = GSBotWorld.native_available()
	out["motor_native"] = GSFpsPhysicsBody.native_enabled and ClassDB.class_exists(&"GSSimFpsBody")
	out.merge(extra)
	out.merge(_ab_report())
	out["idle_gate"] = GSWeaponBehaviour.idle_gate
	out["idle_gate_misses"] = GSWeaponBehaviour.idle_gate_misses
	if FcHullGrid.verify:
		out["hull_verified"] = FcHullGrid.verified
		out["hull_mismatches"] = FcHullGrid.mismatches
		out["hull_native_verified"] = FcHullGrid.native_verified
		out["hull_native_mismatches"] = FcHullGrid.native_mismatches
	# Hull gathers gs-sim's hull world answered in the motor tick (no script call), and the pair calls it made.
	var arena := get_tree().root.find_child("Arena", true, false)
	var world: Object = arena.get(&"_hull_world") if arena != null else null
	if world != null:
		var c: PackedInt64Array = world.counters()
		out["hull_native_gathers"] = c[0]
		out["hull_native_pair_calls"] = c[1]
	out["motor_us_per_bot_tick"] = _motor_phases(_count)
	if AwWeaponRig.phase_timers:
		# Weapon tick sub-phases (ms per tick), the split of p_weapons, and how many idle/full ticks they cover.
		var wp := {}
		for i in AwWeaponRig.PHASES.size():
			wp["rig_" + AwWeaponRig.PHASES[i]] = snappedf(AwWeaponRig.phase_us[i] / 1000.0 / maxi(1, _count), 0.001)
		for i in GSWeaponArsenal.PHASES.size():
			wp["ars_" + GSWeaponArsenal.PHASES[i]] = snappedf(GSWeaponArsenal.phase_us[i] / 1000.0 / maxi(1, _count), 0.001)
		wp["rig_calls"] = AwWeaponRig.phase_calls
		wp["ars_calls"] = GSWeaponArsenal.phase_calls
		out["weapon_phases_ms"] = wp
	if (GSBotBrain as GDScript).get(&"phase_timers"):
		# Brain think sub-phases (ms per tick), by name: an older gs-bot has no such clocks.
		var bp := {}
		var b_names: Array = (GSBotBrain as GDScript).get(&"PHASES")
		var b_us: PackedInt64Array = (GSBotBrain as GDScript).get(&"phase_us")
		for i in b_names.size():
			bp[b_names[i]] = snappedf(b_us[i] / 1000.0 / maxi(1, _count), 0.001)
		out["brain_phases_ms"] = bp
	var pv := FcBotPvs.stats
	out["bot_pvs"] = {
		"mode": ("native" if FcBotPvs.native and GSSim.has(&"pvs") else "script") if FcBotPvs.enabled else "off",
		"on_net": _pvs_net, "on_game": _pvs_game, "asks": pv[0], "ruled_out": pv[1], "ruled_out_clear": pv[2], "native_mismatch": pv[3],
	}
	print("SCALE128 ", JSON.stringify(out))
	# One greppable line per run (tools/engaged_bench.sh reads it).
	print("SERVER_TICK bots=%d p50=%.2f p95=%.2f p99=%.2f mean=%.2f tps=%.1f over=%d shots/min=%.0f kills/min=%.0f respawns/min=%.0f" % [
		_bots, script.get("p50", 0.0), script.get("p95", 0.0), script.get("p99", 0.0), script.get("mean", 0.0),
		_count / wall, out["over_budget_ticks"], _shots / minutes, _kills / minutes, _respawns / minutes])


func _over(limit_us: float) -> int:
	var n := 0
	for v in _script_us:
		n += int(v > limit_us)
	return n


## Whether the map's PVS was on the netcode and on the game (for the bots) when the record began.
var _pvs_net := false
var _pvs_game := false
var _motorprof := false
var _fine := false
var _spawn := false


## `--spawn 1`: respawns the dead (or, with [param all], everyone) through FcGame.respawn_player, about once a
## second; the match's own queue never runs without a person in it.
func _respawn_dead(game: Node, all: bool) -> void:
	for p in game.players():
		if all or not p.is_alive():
			var _r: GSResult = game.respawn_player(p.player_id)
			_respawns += int(_recording)


var _shots := 0
var _hits := 0
var _heads := 0
var _kills := 0
var _respawns := 0


func _tally_on(g: Object) -> void:
	g.connect(&"hit_confirmed", func(_a: int, _v: int, _amount: float, _p: Vector3, head: bool, lethal: bool) -> void:
		if _recording:
			_hits += 1
			_heads += int(head)
			_kills += int(lethal))
	for p in g.call("players"):
		p.connect(&"used", func(outcome: GSWeaponOutcome) -> void:
			if _recording and outcome != null and outcome.used:
				_shots += outcome.shots.size())


func _motor_phases(ticks: int) -> Dictionary:
	var out := {}
	if not _motorprof:
		return out
	var n := maxi(1, _bots * ticks)
	for i in GSFpsMotor.PHASES.size():
		if GSFpsMotor.PHASES[i] != "":
			out["m_" + GSFpsMotor.PHASES[i]] = snappedf(GSFpsMotor.phase_us[i] / float(n), 0.01)
	var cn := ["pre", "consume", "motor", "publish", "report", "signals+stats", "post", "other"]
	for i in cn.size():
		out["c_" + cn[i]] = snappedf(GSFpsController.phase_us[i] / float(n), 0.01)
	return out


func _begin_record() -> void:
	FcBotPvs.counting = true
	FcBotPvs.reset_stats()
	if _motorprof:
		GSFpsMotor.profile = true
		GSFpsMotor.phase_us.fill(0)
		GSFpsController.phase_us.fill(0)
	FcFrameProbe.set_interval(1.0e9)
	FcFrameProbe.fine = _fine
	FcFrameProbe._sections.clear()
	AwWeaponRig.phase_us.fill(0)
	AwWeaponRig.phase_calls.fill(0)
	GSWeaponArsenal.phase_us.fill(0)
	GSWeaponArsenal.phase_calls.fill(0)
	if (GSBotBrain as GDScript).get(&"phase_timers"):
		var b_us: PackedInt64Array = (GSBotBrain as GDScript).get(&"phase_us")
		b_us.fill(0)
		(GSBotBrain as GDScript).set(&"phase_us", b_us)
	_script_us.clear()
	_phys_ms.clear()
	_gap_ms.clear()
	_worst.clear()
	_last_start = 0
	_count = 0
	_t_start = Time.get_ticks_usec()
	_ab_begin()
	_recording = true


# server

func _add_stamps() -> void:
	for n in get_tree().root.find_children("*", "", true, false):
		if n.is_physics_processing() and not (n is Sentinel) and n.get_parent() != null:
			var st := Stamp.new()
			st.bench = self
			st.label = "%s:%s" % [n.name, n.get_script().resource_path.get_file() if n.get_script() else n.get_class()]
			st.process_physics_priority = n.process_physics_priority
			n.add_sibling(st)


func _serve() -> void:
	var data := "user://scale128_server"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))
	Engine.physics_ticks_per_second = _tick
	var game := FcGame.new()
	game.name = "Arena"
	game.tick_rate = _tick
	game.score_limit = 0
	game.time_limit_sec = 0.0
	game.warmup_sec = 0.0
	game.headless = true
	game.mode_id = StringName(_mode)
	game.register_service = true
	add_child(game)
	if _botstyles != "":
		var _st := GSBotSettings.of(game).set_value("styles", _botstyles)
	var map: FcMap = FcMap.by_id(StringName(_map))
	if map == null and _map != "dm_box":
		# Loud: an unknown id (cp_orange_x3 for cp-orange-x3) profiled dm_box under the asked name.
		push_error("scale128: no map '%s' (converted maps use dashes, e.g. cp-orange-x3)" % _map)
		get_tree().quit(2)
		return
	var _set := game.setup(map if map != null else FcMap.dm_box())
	var config := LoopbackServer.config("scale128", _port, data, "error", 256)
	config.tickrate = _tick
	var server := await LoopbackServer.boot(self, config, "scale128")
	if server == null:
		get_tree().quit(1)
		return
	var module := server.modules.get_module("arena") as FcModule
	var quota: GSBotQuota = module.get("_bot_quota")
	# The server's own quota manages the bots (fixed N): an "off" quota removes every bot a second later.
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(_bots))
		quota.empty_cvar.force_set("1")
	var made := 0
	var t_add := Time.get_ticks_usec()
	while module.bridge.bot_ids().size() < _bots and (Time.get_ticks_usec() - t_add) < 60000000:
		await get_tree().create_timer(0.5).timeout
	made = module.bridge.bot_ids().size()
	var add_ms := (Time.get_ticks_usec() - t_add) / 1000.0
	game = module.game
	if _spawn:
		# With no person in it the match never runs its respawn queue: the bots would stand where they joined with
		# empty hands, and p_weapons would time unarmed players. Spawn each one the way a respawn does (loadout too).
		_respawn_dead(game, true)
	await get_tree().create_timer(_settle).timeout
	var net: GSNetManager = module.net
	_pvs_net = net.interest != null and net.interest.visibility != null
	_pvs_game = game.has_meta(FcBotPvs.META)
	var before: Dictionary = net.perf_counters()
	_ab_net = net
	if "--nodeprobe" in OS.get_cmdline_user_args():
		_add_stamps()
	_begin_record()
	_tally_on(game)
	var t_end := Time.get_ticks_usec() + int(_seconds * 1.0e6)
	while Time.get_ticks_usec() < t_end:
		await get_tree().create_timer(minf(1.0, (t_end - Time.get_ticks_usec()) / 1.0e6)).timeout
		if _spawn:
			_respawn_dead(game, false)
	_recording = false
	var after: Dictionary = net.perf_counters()
	var nt := maxi(1, int(after[&"server_ticks"]) - int(before[&"server_ticks"]))
	var alive := 0
	for p in game.players():
		alive += int(p.is_alive())
	_report({
		"alive": alive, "bots_made": made, "engine_hz": Engine.physics_ticks_per_second, "players": game.players().size(), "add_bots_ms": snappedf(add_ms, 0.1),
		"net_sim_ms_per_tick": snappedf((int(after[&"server_sim_usec"]) - int(before[&"server_sim_usec"])) / 1000.0 / nt, 0.001),
		"net_send_ms_per_tick": snappedf((int(after[&"server_send_usec"]) - int(before[&"server_send_usec"])) / 1000.0 / nt, 0.001),
		"net_ticks": nt, "snapshot_every_ticks": net.config.ticks_per_snapshot(),
		"snapshot_hz": net.config.snapshot_rate, "entities": net.registry.all().size(),
		# Whether gs-sim's hitscan spread tick is loaded: false with a gs-sim build older than its weapon module, where
		# every weapon tick runs the GDScript fallback (--weapab toggles GSWeaponHitscan.native_tick on top of this).
		"weapon_native_loaded": ClassDB.class_exists(&"GSSimWeaponSpread"),
	})
	get_tree().quit()


# offline

func _census(g: Node, local: Node) -> Dictionary:
	var classes := {}
	var procs := 0
	var physprocs := 0
	var scripts := 0
	var lights := 0
	var bodies := 0
	var shapes := 0
	var anim := 0
	var tags := 0
	var meshes := 0
	var nodes := 0
	var players := 0
	for p in g.players():
		if p == local:
			continue
		players += 1
		var st := [p]
		while not st.is_empty():
			var nd: Node = st.pop_back()
			st.append_array(nd.get_children())
			nodes += 1
			classes[nd.get_class()] = int(classes.get(nd.get_class(), 0)) + 1
			procs += int(nd.is_processing())
			physprocs += int(nd.is_physics_processing())
			scripts += int(nd.get_script() != null)
			lights += int(nd is Light3D)
			bodies += int(nd is PhysicsBody3D or nd is Area3D)
			shapes += int(nd is CollisionShape3D)
			anim += int(nd is AnimationPlayer or nd is AnimationTree or nd is Skeleton3D)
			tags += int(nd is Label3D or nd is Sprite3D or nd.name.to_lower().contains("tag"))
			meshes += int(nd is MeshInstance3D)
	var n := float(maxi(1, players))
	var top := []
	var keys := classes.keys()
	keys.sort_custom(func(a, b): return classes[a] > classes[b])
	for k in keys.slice(0, 8):
		top.append("%s:%.1f" % [k, classes[k] / n])
	return {
		"remote_players": players, "nodes_per_player": snappedf(nodes / n, 0.1),
		"scripts_per_player": snappedf(scripts / n, 0.1), "processing_nodes_per_player": snappedf(procs / n, 0.1),
		"physics_processing_nodes_per_player": snappedf(physprocs / n, 0.1),
		"lights_per_player": snappedf(lights / n, 0.1), "phys_bodies_areas_per_player": snappedf(bodies / n, 0.1),
		"collision_shapes_per_player": snappedf(shapes / n, 0.1), "anim_nodes_per_player": snappedf(anim / n, 0.1),
		"tag_nodes_per_player": snappedf(tags / n, 0.1), "meshes_per_player": snappedf(meshes / n, 0.1),
		"top_classes": top,
	}


func _offline() -> void:
	var client: Node = (load("res://game/fc.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	var spin := 0.0
	while spin < 90.0:
		await get_tree().create_timer(0.25).timeout
		spin += 0.25
		var g0 = client.get("game")
		var p0 = client.get("player")
		if g0 != null and p0 != null and p0.is_alive() and g0.match_node != null and g0.match_node.state == GSMatch.State.LIVE:
			break
	var g = client.get("game")
	g.tick_rate = _tick
	Engine.physics_ticks_per_second = _tick
	Engine.max_fps = 0
	await get_tree().create_timer(_settle).timeout
	var census := _census(g, client.get("player"))
	var tick0: int = g.current_tick()
	var frames := PackedFloat64Array()
	_begin_record()
	_tally_on(g)
	var t_last := Time.get_ticks_usec()
	var proc := 0.0
	var render := 0.0
	var draw := 0.0
	var n := 0
	var spikes := []
	var nodes_last := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	while (Time.get_ticks_usec() - _t_start) / 1.0e6 < _seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var nodes_now := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		spikes.append([snappedf((now - t_last) / 1000.0, 0.1), nodes_now - nodes_last, snappedf((now - _t_start) / 1.0e6, 0.01)])
		nodes_last = nodes_now
		frames.append(float(now - t_last))
		t_last = now
		proc += Performance.get_monitor(Performance.TIME_PROCESS)
		draw += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		n += 1
	_recording = false
	spikes.sort_custom(func(x, y): return x[0] > y[0])
	var cold := {}
	if _role == "offline" and "--cold" in OS.get_cmdline_user_args():
		cold = await _cold(client, g)
	var wall := (Time.get_ticks_usec() - _t_start) / 1.0e6
	var game_ticks: int = g.current_tick() - tick0
	_report({
		"frame_ms": _stats(frames, 0.001), "fps": snappedf(n / wall, 0.1),
		"process_ms_mean": snappedf(proc / maxi(1, n) * 1000.0, 0.001), "draw_calls": snappedf(draw / maxi(1, n), 1.0),
		"game_ticks": game_ticks, "sim_speed": snappedf(game_ticks / wall / _tick, 3),
		"max_physics_steps_per_frame": Engine.max_physics_steps_per_frame, "census": census,
		"players": g.players().size(), "worst_frames_ms_nodes_t": spikes.slice(0, 6), "cold": cold,
	})
	get_tree().quit()


## First use against the Nth: what adding bots costs (ms and nodes each, 1st..8th), then the
## frames in which the first hurt, the first kill and the first shots land.
func _cold(client: Node, g: Node) -> Dictionary:
	var adds := []
	for i in 8:
		var nodes0 := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		var t0 := Time.get_ticks_usec()
		client.call("_add_offline_bot", "ColdBot%d" % i)
		adds.append([snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.01), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - nodes0])
		await get_tree().process_frame
	var frames := []
	var nodes_last := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var t_last := Time.get_ticks_usec()
	var t_end := t_last + 15000000
	while Time.get_ticks_usec() < t_end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var nodes_now := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		frames.append([snappedf((now - t_last) / 1000.0, 0.1), nodes_now - nodes_last])
		nodes_last = nodes_now
		t_last = now
	var spiky := frames.filter(func(f): return f[1] != 0 or f[0] > 40.0)
	spiky.sort_custom(func(x, y): return x[0] > y[0])
	return {"bot_adds_ms_nodes": adds, "spiky_frames_ms_nodes": spiky.slice(0, 12), "frames": frames.size()}
