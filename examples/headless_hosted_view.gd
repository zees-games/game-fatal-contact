extends Node

const FcPresentation := preload("../game/fc_presentation.gd")
const FcSimHost := preload("../game/fc_sim_host.gd")

## The owner's native solo game is hosted (a loopback server process, the client predicts and draws).
## With no mouse and no key, the local player's view must hold still: the drawn camera may not turn or
## jump from one frame to the next, and the viewport's current camera is the player's own every frame
## (nightly fc-native-via-gs-app-1: the footage shows the view flipping between a few poses).

const BOTS := 4
const WATCH_SEC := 10.0
## A still player turns by nothing; a few degrees allow for the spawn turn settling.
const MAX_TURN_DEG := 3.0
const MAX_JUMP_M := 0.5

var _checks := 0
var _failed := 0
var _client: Node = null


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	var _scratch := FcPresentation.use_scratch_settings("headless_hosted_view")
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


func _run() -> void:
	print("game-fatal-contact: the hosted solo view holds still without input")
	FcSimHost.forced = 1
	FcSimHost.ask_map = "dm_box"
	FcSimHost.hold_joined_sec = 1.0
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("offline_bots", BOTS)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var limit := FcSimHost.BOOT_LIMIT_SEC + FcSimHost.JOIN_LIMIT_SEC + FcSimHost.hold_joined_sec + 30.0
	var built := await _until(func() -> bool: return _client.get("game") != null, limit)
	_check(built, "the hosted client builds")
	if not built:
		_end()
		return
	var alive := await _until(func() -> bool:
		var p: Object = _client.get("player")
		return p != null and bool(p.call("is_alive")), 40.0)
	_check(alive, "the local player is alive")
	# The player is alive at the map origin until the first server state places it at a spawn (a one-frame
	# teleport at join; the watch skips it). Let the spawn turn and the first snapshots settle.
	await _until(func() -> bool: return false, 3.0)
	await _watch("idle", func(_t: float) -> void: pass)
	# Walking: the predicted eye is corrected by the server's snapshots.
	await _watch("walking", func(t: float) -> void:
		Input.action_press(&"gs_fps_forward")
		if int(t * 2.0) % 2 == 0:
			Input.action_press(&"gs_fps_right")
			Input.action_release(&"gs_fps_left")
		else:
			Input.action_press(&"gs_fps_left")
			Input.action_release(&"gs_fps_right"))
	Input.action_release(&"gs_fps_forward")
	Input.action_release(&"gs_fps_left")
	Input.action_release(&"gs_fps_right")
	_end()


func _watch(phase: String, drive: Callable) -> void:
	var worst_turn := 0.0
	var worst_jump := 0.0
	var foreign := 0
	var frames := 0
	var turns := 0
	var shown := 0
	var last := Transform3D.IDENTITY
	var have := false
	var end := Time.get_ticks_msec() + int(WATCH_SEC * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
		drive.call(WATCH_SEC - (end - Time.get_ticks_msec()) / 1000.0)
		var p: Object = _client.get("player")
		if p == null or not bool(p.call("is_alive")):
			have = false
			continue
		var cam: Camera3D = p.get("camera")
		if cam == null:
			continue
		frames += 1
		if get_viewport().get_camera_3d() != cam:
			foreign += 1
		var now := cam.global_transform
		if have and Vector2(last.origin.x, last.origin.z).length() < 0.1:
			have = false
		if have:
			var turn := rad_to_deg((-last.basis.z).angle_to(-now.basis.z))
			var jump := last.origin.distance_to(now.origin)
			worst_turn = maxf(worst_turn, turn)
			worst_jump = maxf(worst_jump, jump)
			if turn > MAX_TURN_DEG:
				turns += 1
			if (turn > MAX_TURN_DEG or jump > MAX_JUMP_M) and shown < 12:  # the first few say where
				shown += 1
				print("  frame %d t=%.2fs: turn %.1f deg, jump %.2f m, from %s to %s, id %d, hp %s, cam current %s" % [
					frames, (Time.get_ticks_msec() - (end - int(WATCH_SEC * 1000.0))) / 1000.0, turn, jump,
					last.origin, now.origin, int(p.get("player_id")), str(p.get("health")), str(cam.current)])
		last = now
		have = true
	print("  [%s] %d frames, worst turn %.2f deg, %d turns over %.0f, worst jump %.2f m, %d frames on another camera" % [
		phase, frames, worst_turn, turns, MAX_TURN_DEG, worst_jump, foreign])
	_check(frames > 60, phase + ": the player was watched", str(frames))
	_check(foreign == 0, phase + ": the viewport shows the player's own camera every frame", str(foreign))
	_check(worst_turn <= MAX_TURN_DEG, phase + ": view never turns between frames", "%.2f deg" % worst_turn)
	_check(worst_jump <= MAX_JUMP_M, phase + ": eye never jumps between frames", "%.2f m" % worst_jump)


func _end() -> void:
	FcSimHost.forced = -1
	FcSimHost.ask_map = ""
	if _client != null:
		_client.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	print("headless_hosted_view: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
