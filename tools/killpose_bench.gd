extends Node

## Microbench for the kill view's per-frame body posing: with 32 bots a kill view plays, and each frame this calls
## the killcam host's pose_at again, timing it whole and by hook (place_body, apply_pose, event).
## Run: hv <worktree> scene res://tools/killpose_bench.tscn (prints BENCH lines; not a suite).

const FcContent := preload("../game/fc_content.gd")
const BOTS := 32

var _client: Node = null
var _game: Object = null
var _acc := {}
var _shots := []


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
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


func _add(key: String, t0: int) -> void:
	var v: Array = _acc.get(key, [0, 0])
	_acc[key] = [v[0] + Time.get_ticks_usec() - t0, v[1] + 1]


func _boot() -> void:
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("offline_bots", BOTS)
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
	await _until(func() -> bool:
		var me: Object = _client.get("player")
		return me != null and me.is_alive() and _game.match_node.state == GSMatch.State.LIVE, 120.0)


## Times the per-body replay pieces of the kill view at its kill moment, then quits.
func _bodies_bench(host: Node, kill_at: float) -> void:
	var Bodies := preload("../game/fc_killcam_bodies.gd")
	var smp: Dictionary = host.buffer.sample(kill_at + 0.2)
	var yard: Variant = _client.get("ragdolls")
	var shots: Variant = host.get("shots") if host.get("shots") != null else _client.get("killcam_shots")
	var ps: Array = []
	for id in smp["b"]:
		var pn: Node = host._player(id)
		if pn != null:
			ps.append([pn, smp["a"].get(id, smp["b"][id]), smp["b"][id]])
	var parts := {"again": 0, "meta": 0, "replay": 0, "get2": 0}
	for r in 100:
		for e: Array in ps:
			var t0 := Time.get_ticks_usec()
			var again: Array = host.get(&"_again")
			var _at: float = float((again[0] as Dictionary).get("time", -1.0)) if not again.is_empty() else -1.0
			parts["again"] += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			var _b: Node3D = e[0].get(&"body_mesh")
			var _h: Node3D = e[0].get(&"held")
			parts["get2"] += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			var _m: Variant = e[0].get_meta(&"zz_bench", 1)
			e[0].set_meta(&"zz_bench", 1)
			parts["meta"] += Time.get_ticks_usec() - t0
			t0 = Time.get_ticks_usec()
			Bodies.replay_events(e[0], e[1], e[2], smp["alpha"], false, yard, shots, kill_at + 0.2)
			parts["replay"] += Time.get_ticks_usec() - t0
	var sh: RefCounted = shots
	var tk := 0
	var pl := 0
	var of := 0
	var cnt := 0
	var fx_full := 0
	for e: Array in ps:
		var pn: Node = e[0]
		var t0 := Time.get_ticks_usec()
		for r in 20:
			sh._played.clear()
			var got: Dictionary = sh.take(int(pn.get(&"player_id")), kill_at + 0.2)
		tk += Time.get_ticks_usec() - t0
		var held: Node3D = pn.get(&"held")
		if held == null:
			continue
		cnt += 1
		t0 = Time.get_ticks_usec()
		for r in 5:
			held.call(&"on_fired", Vector2(0.6, 0.1), 0, false)
		of += Time.get_ticks_usec() - t0
		var t1 := Time.get_ticks_usec()
		for r in 5:
			held.call(&"on_fired", Vector2(0.6, 0.1), 0)
		fx_full += Time.get_ticks_usec() - t1
		var fake := {"dir": Vector3.FORWARD, "origin": Vector3(0, 1, 0), "serial": 1}
		t0 = Time.get_ticks_usec()
		for r in 5:
			sh.play(fake, pn, 0)
		pl += Time.get_ticks_usec() - t0
	print("BENCH on_fired with fx %.2f us" % (fx_full / 5.0 / maxf(cnt, 1)))
	print("BENCH shots held=%d size=%d: take %.2f us, on_fired(no fx) %.2f us, shots.play %.2f us" % [cnt, sh.shots.size(), tk / 20.0 / ps.size(), of / 5.0 / maxf(cnt, 1), pl / 5.0 / maxf(cnt, 1)])
	var n := 100.0 * maxf(ps.size(), 1)
	print("BENCH per body us: again %.2f get2 %.2f meta %.2f replay_events %.2f (%d bodies)" % [parts["again"] / n, parts["get2"] / n, parts["meta"] / n, parts["replay"] / n, ps.size()])
	get_tree().quit(0)


func _run() -> void:
	await _boot()
	var host: Node = _client.get("killcam")
	await _wait(5.0)
	var me: Object = _client.get("player")
	var bots: Dictionary = _client.get("_bots")
	var killer: Object = null
	var best := INF
	for id in bots:
		var b: Object = bots[id]
		var d: float = (b as Node3D).global_position.distance_to((me as Node3D).global_position)
		if b.is_alive() and d < best:
			best = d
			killer = b
	for i in 30:
		if not me.is_alive():
			break
		var dmg := GSDamage.make(killer.player_id, me.player_id, 1000.0, _game.combat.damage_type(FcContent.DAMAGE_BULLET))
		dmg.weapon_id = &"smg"
		dmg.tick = _game.current_tick()
		_game.combat.apply_damage(dmg)
		await _wait(0.2)
	var kv: Node = _client.get("killview")
	if not await _until(func() -> bool: return kv.is_active(), 5.0):
		print("BENCH no kill view")
		get_tree().quit(1)
		return
	var pb: Callable = host.place_body_fn
	var ap: Callable = host.apply_pose_fn
	var ev: Callable = host.event_fn
	host.place_body_fn = func(p: Node, f: Vector3, y: float, s: bool, pi: float, sp: float, t: Dictionary) -> void:
		var t0 := Time.get_ticks_usec()
		pb.call(p, f, y, s, pi, sp, t)
		var animated: bool = s and t.has(p) and not bool(t[p][1])
		_add("place_body_animated" if animated else ("place_body_shown" if s else "place_body_hidden"), t0)
	host.apply_pose_fn = func(p: Node, a: PackedFloat32Array, b: PackedFloat32Array, al: float) -> void:
		var t0 := Time.get_ticks_usec()
		ap.call(p, a, b, al)
		_add("apply_pose", t0)
	host.event_fn = func(p: Node, ra: Array, rb: Array, al: float, v: bool) -> void:
		var row: Array = rb if al >= 0.5 else ra
		var fresh := row.size() > 8 and int(row[7]) != int(p.get_meta(&"killcam_seen_seq", int(row[7])))
		var t0 := Time.get_ticks_usec()
		ev.call(p, ra, rb, al, v)
		if fresh:
			_shots.append(Time.get_ticks_usec() - t0)
		_add("event_shot" if fresh else ("event_victim" if v else "event_idle"), t0)
	print("BENCH native pose: %s" % GSHumanoidPoseRecord.native_available())
	var frames := 0
	var tot := 0
	var worst := 0
	var kill_at: float = kv.get("_kill_at")
	var moments := []
	var cl: Node = kv
	cl.kv.moment.disconnect(cl._on_moment)
	cl.kv.moment.connect(func(sec: float) -> void:
		var t0 := Time.get_ticks_usec()
		cl._on_moment(sec)
		moments.append(Time.get_ticks_usec() - t0)
		if moments.size() <= 3:
			var split := ""
			for k: String in _acc:
				split += " %s=%dus/%d" % [k, _acc[k][0], _acc[k][1]]
			print("BENCH moment #%d: %d us (cumulative hooks:%s)" % [moments.size(), moments[-1], split]))
	while kv.is_active():
		await get_tree().process_frame
		frames += 1
	print("BENCH first _on_moment calls (us): %s" % str(moments.slice(0, 6)))
	print("BENCH event_shot calls in order (us): %s" % str(_shots))
	moments.sort()
	var sum := 0
	for m: int in moments:
		sum += m
	print("BENCH kill view %d frames, _on_moment n=%d avg %.3f ms median %.3f p90 %.3f max %.3f" % [frames, moments.size(), sum / 1000.0 / maxf(moments.size(), 1), moments[moments.size() / 2] / 1000.0, moments[moments.size() * 9 / 10] / 1000.0, moments[-1] / 1000.0])
	for k: String in _acc:
		print("BENCH   %s: %.3f ms/frame (%d calls/frame)" % [k, _acc[k][0] / 1000.0 / maxf(moments.size(), 1), _acc[k][1] / maxi(moments.size(), 1)])
	await _bodies_bench(host, kill_at)
