extends "headless_native_snapshot_parity.gd"
## A timing check, not a gate: gs-net's snapshot send at 31 players with gs-sim's core and rest pull (native lane)
## against GDScript (script lane), same seeded world in lockstep, and the rest pull alone, GSSimNetRest against
## FcPlayerNet._pull_rest over the same nets. Prints microseconds; exits 0 unless gs-sim is missing.

const BENCH_PLAYERS := 31
const BENCH_TICKS := 600
const REST_LAPS := 200


func _run() -> void:
	print("FC — snapshot build time, gs-sim against GDScript, %d players" % BENCH_PLAYERS)
	if FcNetNativeCore.make_core() == null:
		print("gs-sim has no GSSimNetCore: nothing to time")
		get_tree().quit(0)
		return
	var was := FcNetNativeCore.enabled
	FcNetPullBatch.rest_enabled = true
	var lanes := [_lane(true, BENCH_PLAYERS), _lane(false, BENCH_PLAYERS)]
	var before: Array = []
	for t in range(1, BENCH_TICKS + 1):
		if t == BENCH_TICKS / 4:
			for lane: Dictionary in lanes:
				before.append((lane.net as GSNetManager).perf_counters())
		for lane: Dictionary in lanes:
			for peer: int in lane.sent:
				(lane.sent[peer] as Array).clear()
			_move_eyes(lane)
			FcNetNativeCore.enabled = lane.native_on
			(lane.net as GSNetManager).server_tick(t)
	for i in lanes.size():
		var now := (lanes[i].net as GSNetManager).perf_counters()
		var then: Dictionary = before[i]
		var ticks: int = now[&"server_ticks"] - then[&"server_ticks"]
		var send: int = now[&"server_send_usec"] - then[&"server_send_usec"]
		var sim: int = now[&"server_sim_usec"] - then[&"server_sim_usec"]
		print("  %s: %d ticks, send %.1f us/tick, sim %.1f us/tick (%s)" % ["native" if i == 0 else "script",
			ticks, float(send) / ticks, float(sim) / ticks, (lanes[i].net as GSNetManager).native_note()])
	# The rest pull alone, on the native lane's nets.
	FcNetNativeCore.enabled = true
	var rest := FcNetPullBatch.rest_native()
	var nets: Array[Object] = []
	var game: FcGame = lanes[0].game
	for p: FcPlayer in game.players():
		var b: Object = (lanes[0].bridge as FcNetBridge).behaviour_for(p.player_id)
		if b != null:
			nets.append(b)
	var start := Time.get_ticks_usec()
	for _l in REST_LAPS:
		for n: Object in nets:
			n.call(&"_pull_rest", false, 0)
	var script_us := float(Time.get_ticks_usec() - start) / REST_LAPS
	# The move rows pull_all has gathered for its movement batch by the time it pulls the rest.
	FcNetPullBatch.native()
	FcNetPullBatch._moves.clear()
	FcNetPullBatch._nets.clear()
	FcNetPullBatch._columns = 0
	for n: Object in nets:
		FcNetPullBatch._gather(n, false)
	var rows := FcNetPullBatch._moves.duplicate()
	var batched: Array[Object] = FcNetPullBatch._nets.duplicate()
	var aim: bool = batched[0].call(&"_rest_interest_aim")
	start = Time.get_ticks_usec()
	for _l in REST_LAPS:
		var follow: PackedInt32Array = rest.call(&"pull_rest_rows", batched, aim, rows, FcNetPullBatch._columns,
			FcNetPullBatch._move_extra)
		for i in follow:
			if i >= 0:
				FcNetPullBatch.rest_owned(batched[i])
			else:
				batched[-1 - i].call(&"_pull_rest", false, 0)
	var native_us := float(Time.get_ticks_usec() - start) / REST_LAPS
	print("  rest pull, %d nets (%d batched): script %.1f us, native %.1f us" % [nets.size(), batched.size(), script_us,
		native_us])
	for lane: Dictionary in lanes:
		(lane.root as Node).queue_free()
	FcNetNativeCore.enabled = was
	get_tree().quit(0)
