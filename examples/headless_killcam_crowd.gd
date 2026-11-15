extends DotGameCheckSuite

const ArenaContent := preload("../game/arena_content.gd")

## Three crowds, grown in one solo match: each round kills the local player twice.
const CROWDS := [32, 64, 128]
const KILLS_PER_CROWD := 2
## One to go live, then per crowd: two setup checks, three per kill and two over the round.
const EXPECTED_CHECKS := 31
## How far a recorded body may sit from the authoritative one: the recording is the drawn body,
## at most a tick behind the tick state, plus the frame the two clocks are read apart.
const RECORD_TOLERANCE_M := 0.6
## A body that moved more than this between two of our samples respawned or teleported: not compared.
const JUMP_M := 1.5

## The kill view and the final killcam replay from rows recorded as the match runs. With many bots,
## a kill view used to record the bodies it had posed from history as where they were now (the remote
## LOD skips presenting most of them each frame), so the next replay drew bodies seconds out of place.
## Every bot's tick position is kept here as the authority, every recorded row is checked against it,
## and every body a replay poses is checked against the row it was posed from.
var _client: Node = null
var _host: Node = null
var _game: Object = null
var _times := PackedFloat64Array()
## One entry per [member _times]: player id -> tick position, for the players alive then.
var _alive_at: Array[Dictionary] = []
## While a kill view plays: [compared, off, worst, which], filled at the end of each frame.
var _posed: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	# Last in the frame, after the client presented the bodies and the killcam posed them: what is drawn.
	# (Checked earlier, the physics ticks have already moved the players the posed meshes hang under.)
	process_priority = 1 << 29
	_run.call_deferred()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _until(cond: Callable, limit: float) -> bool:
	var t := 0.0
	while t < limit:
		if cond.call():
			return true
		await _wait(0.05)
		t += 0.05
	return cond.call()


func _process(_delta: float) -> void:
	if _host == null or _game == null:
		return
	if not _posed.is_empty():
		_compare_posed(_posed)
	var now: float = _host.now_fn.call()
	if not _times.is_empty() and now <= _times[_times.size() - 1]:
		return
	var at := {}
	for p: Node in _game.players():
		var controller: DotFpsController = p.get(&"controller")
		if controller != null and bool(p.call(&"is_alive")):
			at[int(p.get(&"player_id"))] = controller.state.position
	_times.append(now)
	_alive_at.append(at)


## The authoritative position of [param id] at [param t], or INF when it cannot be told (dead,
## unknown, respawned between the samples, or outside what was kept).
func _truth(id: int, t: float) -> Vector3:
	var nope := Vector3(INF, INF, INF)
	var i := _times.bsearch(t, false)
	if i <= 0 or i >= _times.size():
		return nope
	var before: Dictionary = _alive_at[i - 1]
	var after: Dictionary = _alive_at[i]
	if not before.has(id) or not after.has(id):
		return nope
	var a: Vector3 = before[id]
	var b: Vector3 = after[id]
	if a.distance_to(b) > JUMP_M:
		return nope
	var alpha := clampf((t - _times[i - 1]) / maxf(_times[i] - _times[i - 1], 0.000001), 0.0, 1.0)
	return a.lerp(b, alpha)


func _lethal(killer: Object, me: Object) -> DotDamage:
	var damage := DotDamage.make(killer.player_id, me.player_id, 1000.0, _game.combat.damage_type(ArenaContent.DAMAGE_BULLET))
	damage.weapon_id = &"smg"
	damage.tick = _game.current_tick()
	return damage


func _run() -> void:
	_client = (load("res://game/arena.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("offline_bots", CROWDS[0])
	_client.set("mouse_capture_override", true)
	add_child(_client)
	while _game == null or _game.match_node == null:
		await _wait(0.1)
		_game = _client.get("game")
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	_game.match_node.rules.min_players = 1
	_game.match_node.rules.score_limit = 100000
	_game.match_node.rules.time_limit_sec = 0.0
	var live := await _until(func() -> bool:
		var me: Object = _client.get("player")
		return me != null and me.is_alive() and _game.match_node.state == DotMatch.State.LIVE, 120.0)
	if not _check(live, "the offline match goes live"):
		_report(EXPECTED_CHECKS)
		return
	_host = _client.get("killcam")
	for crowd: int in CROWDS:
		await _test_crowd(crowd)
	_report(EXPECTED_CHECKS)


func _test_crowd(crowd: int) -> void:
	_client.call("_keep_offline_bots", crowd)
	var bots: Dictionary = _client.get("_bots")
	_check(bots.size() == crowd, "%d bots play" % crowd, str(bots.size()))
	var buffer: DotKillcamBuffer = _host.buffer
	_check(buffer.max_events >= _game.players().size() * 4,
		"the killcam keeps kill events for every player, not dot-replay's 64", "%d for %d players" % [buffer.max_events, _game.players().size()])
	# Long enough for the new bots to spread out and run.
	await _wait(4.0)
	var since: float = _host.now_fn.call()
	var thinned := 0
	for k in KILLS_PER_CROWD:
		var me: Object = _client.get("player")
		await _until(func() -> bool: return me.is_alive(), 20.0)
		await _wait(1.5)
		var killer: Object = _nearest_bot(bots, me)
		for i in 30:
			if not me.is_alive():
				break
			_game.combat.apply_damage(_lethal(killer, me))
			await _wait(0.2)
		var kv: Node = _client.get("killview")
		var started := kv != null and await _until(func() -> bool: return kv.is_active(), 5.0)
		_check(started, "%d bots, kill %d: the killer's view plays" % [crowd, k + 1])
		if not started:
			continue
		await _wait(0.3)
		_check(not is_nan(float(kv.get("_kill_at"))), "%d bots, kill %d: the kill view finds its kill in the buffer" % [crowd, k + 1],
			"%d kill events held of %d" % [buffer.events_between(-INF, INF, &"kill").size(), buffer.max_events])
		var posed := [0, 0, 0.0, ""]
		_posed = posed
		while kv.is_active():
			thinned = maxi(thinned, _thinned_now())
			await get_tree().process_frame
		_posed = []
		_check(posed[0] > 0 and posed[1] == 0,
			"%d bots, kill %d: every body the replay drew stands where its row puts it" % [crowd, k + 1],
			"%d compared, %d off, worst %.2f m %s" % posed)
	await _wait(1.0)
	_check(thinned > 0, "%d bots: the remote LOD skipped bodies while a replay was posed (the case this covers)" % crowd, str(thinned))
	var swept := _sweep(buffer, since)
	_check(swept[0] > crowd * 10 and swept[1] == 0,
		"%d bots: every recorded row, during and after the kill views, matches the authoritative position" % crowd,
		"%d rows, %d off by more than %.1f m, worst %.2f m %s" % [swept[0], swept[1], RECORD_TOLERANCE_M, swept[2], swept[3]])


func _nearest_bot(bots: Dictionary, me: Object) -> Object:
	var best: Object = null
	var best_d := INF
	for id in bots:
		var b: Object = bots[id]
		if not b.is_alive():
			continue
		var d: float = (b as Node3D).global_position.distance_to((me as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = b
	return best


## How many bodies the remote LOD is holding back this frame.
func _thinned_now() -> int:
	var n := 0
	for p: Node in _game.players():
		if int(p.get(&"_lod_frames")) > 0:
			n += 1
	return n


## Every shown body the host posed this frame against the row it was posed from.
func _compare_posed(out: Array) -> void:
	var again: Array = _host.get(&"_again")
	if again.is_empty():
		return
	var s: Dictionary = again[0]
	var a: Dictionary = s["a"]
	var b: Dictionary = s["b"]
	var alpha: float = s["alpha"]
	for id: Variant in b:
		var p: Node = _game.player_for(int(id))
		if p == null:
			continue
		var body: Node3D = p.get(&"body_mesh")
		if body == null or not body.visible:
			continue
		var rb: Array = b[id]
		var ra: Array = a.get(id, rb)
		var want: Vector3 = (ra[0] as Vector3).lerp(rb[0], alpha)
		var off := body.global_position.distance_to(want)
		out[0] += 1
		if off > 0.05:
			out[1] += 1
			if off > out[2]:
				out[2] = off
				out[3] = "(id %s)" % id


## Every row recorded since [param since] against the authoritative positions: [rows, off, worst, which].
func _sweep(buffer: DotKillcamBuffer, since: float) -> Array:
	var me: Object = _client.get("player")
	var rows := 0
	var off := 0
	var worst := 0.0
	var which := ""
	for f: Dictionary in buffer.frames_between(since, buffer.newest_time()):
		var t: float = f["time"]
		var frame: Dictionary = f["frame"]
		for id: Variant in frame:
			if me != null and int(id) == int(me.player_id):
				continue
			var row: Array = frame[id]
			if not bool(row[3]):
				continue
			var truth := _truth(int(id), t)
			if not truth.is_finite():
				continue
			rows += 1
			var d := (row[0] as Vector3).distance_to(truth)
			if d > RECORD_TOLERANCE_M:
				off += 1
				if d > worst:
					worst = d
					which = "(id %s at %.2f s)" % [id, t - since]
	return [rows, off, worst, which]
