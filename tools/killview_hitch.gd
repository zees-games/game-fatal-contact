extends Node

## Windowed trace of the kill-view switch: kills the local player with 32 bots around and prints every frame from the
## death to 1.5 s after it (wall ms, draws, objects, nodes, physics steps, vram, render cpu/gpu ms, kill view active),
## then the worst frame. Run on a GPU box: ../gpu.sh run game-fatal-contact res://tools/killview_hitch.tscn
## (add -- --rendering-driver opengl3 for the web path). Prints HITCH lines; not a suite.

const FcContent := preload("../game/fc_content.gd")
const BOTS := 32
const TRACE_SEC := 5.0

var _client: Node = null
var _game: Object = null
var _fr := {}
var _added := {}


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
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
	_fr[key] = int(_fr.get(key, 0)) + Time.get_ticks_usec() - t0


## Wraps the kill view's per-frame hooks so each row can say where the script time of its frame went.
func _hook(kv: Node) -> void:
	var host: Node = _client.get("killcam")
	var pb: Callable = host.place_body_fn
	var ap: Callable = host.apply_pose_fn
	var ev: Callable = host.event_fn
	host.place_body_fn = func(p: Node, f: Vector3, y: float, s: bool, pi: float, sp: float, t: Dictionary) -> void:
		var t0 := Time.get_ticks_usec()
		pb.call(p, f, y, s, pi, sp, t)
		_add("place", t0)
	host.apply_pose_fn = func(p: Node, a: PackedFloat32Array, b: PackedFloat32Array, al: float) -> void:
		var t0 := Time.get_ticks_usec()
		ap.call(p, a, b, al)
		_add("pose", t0)
	host.event_fn = func(p: Node, ra: Array, rb: Array, al: float, v: bool) -> void:
		var t0 := Time.get_ticks_usec()
		ev.call(p, ra, rb, al, v)
		_add("event", t0)
	get_tree().node_added.connect(func(n: Node) -> void:
		var key := "%s<%s" % [n.get_class(), n.get_parent().name if n.get_parent() != null else ""]
		_added[key] = int(_added.get(key, 0)) + 1)
	var pf: Callable = kv.present_fn
	kv.present_fn = func(v: Dictionary) -> void:
		var t0 := Time.get_ticks_usec()
		pf.call(v)
		_add("present", t0)
	kv.kv.moment.disconnect(kv._on_moment)
	kv.kv.moment.connect(func(sec: float) -> void:
		var t0 := Time.get_ticks_usec()
		kv._on_moment(sec)
		_add("moment", t0))
	kv.kv.view.disconnect(kv._on_view)
	kv.kv.view.connect(func(x: Transform3D, fov: float, cur: Vector2, hc: bool) -> void:
		var t0 := Time.get_ticks_usec()
		kv._on_view(x, fov, cur, hc)
		_add("view", t0))


func _row(i: int, ms: float, kv_on: bool, steps: int) -> Dictionary:
	var vp := get_viewport().get_viewport_rid()
	return {
		"hooks": _fr.duplicate(), "added": _added.duplicate(), "i": i, "ms": ms, "kv": kv_on, "steps": steps,
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"objs": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"vram": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"cpu": RenderingServer.viewport_get_measured_render_time_cpu(vp),
		"gpu": RenderingServer.viewport_get_measured_render_time_gpu(vp),
	}


func _run() -> void:
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
	# The warm-up behind the loading cover (and the late weapon views after it) must be over, or the trace measures it.
	await _until(func() -> bool:
		return (_client.get("_warm") as Dictionary).is_empty() and (_client.get("_late_views") as Dictionary).is_empty(), 180.0)
	await _wait(float(OS.get_environment("HITCH_SETTLE") if OS.has_environment("HITCH_SETTLE") else "6"))
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
	var kv: Node = _client.get("killview")
	_hook(kv)
	var sk: Object = _client.get("solo_killview")
	printerr("HITCH setup solo_killview=%s enabled=%s" % [sk != null, _game.killview_rules.enabled])
	if sk != null:
		var orig: Callable = sk.deliver_fn
		sk.deliver_fn = func(clip: Dictionary, info: Dictionary) -> void:
			printerr("HITCH deliver at frame %d" % Engine.get_process_frames())
			orig.call(clip, info)
	var rows: Array = []
	var last := Time.get_ticks_usec()
	var steps0 := Engine.get_physics_frames()
	var dmg := GSDamage.make(killer.player_id, me.player_id, 1000.0, _game.combat.damage_type(FcContent.DAMAGE_BULLET))
	dmg.weapon_id = &"smg"
	dmg.tick = _game.current_tick()
	_game.combat.apply_damage(dmg)
	var t_end := Time.get_ticks_usec() + int(TRACE_SEC * 1e6)
	var i := 0
	while Time.get_ticks_usec() < t_end:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var st := Engine.get_physics_frames()
		rows.append(_row(i, (now - last) / 1000.0, kv.is_active(), st - steps0))
		_fr.clear()
		_added.clear()
		steps0 = st
		last = now
		i += 1
	var worst := {"ms": 0.0}
	var over := 0
	for r: Dictionary in rows:
		printerr("HITCH f%02d %6.1f ms kv=%s steps=%d draws=%d objs=%d nodes=%d vram=%.1fMB cpu=%.1f gpu=%.1f %s" % [
			r["i"], r["ms"], r["kv"], r["steps"], r["draws"], r["objs"], r["nodes"], r["vram"], r["cpu"], r["gpu"], str(r["hooks"])])
		if int(r["ms"]) > 30 and not r["added"].is_empty():
			printerr("HITCH    added f%02d %s" % [r["i"], str(r["added"])])
		if r["ms"] > worst["ms"]:
			worst = r
		if r["ms"] > 20.0:
			over += 1
	printerr("HITCH worst f%d %.1f ms; frames over 20 ms: %d of %d" % [worst.get("i", -1), worst["ms"], over, rows.size()])
	get_tree().quit(0)
