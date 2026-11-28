extends Node

const FcPresentation := preload("../game/fc_presentation.gd")
const FcContent := preload("../game/fc_content.gd")
const FcSimHost := preload("../game/fc_sim_host.gd")

## The owner's native solo game is hosted (a loopback server process, the client predicts and draws). With no mouse and no key, the local player's view must hold still:
## the drawn camera may not turn or jump from one frame to the next, and the viewport's current camera is the player's own every frame (nightly fc-native-via-gs-app-1).

const BOTS := 4
const WATCH_SEC := 10.0
## A still player turns by nothing; a few degrees allow for the spawn turn settling.
const MAX_TURN_DEG := 3.0
const MAX_JUMP_M := 0.5
## Seconds of undisturbed (alive, no death in the last [constant QUIET_SEC]) frames a phase needs, and its cap.
const QUIET_NEED_SEC := 5.0
const PHASE_CAP_SEC := 40.0
## A death's kill view and respawn teleport are not a view fault; frames this soon after one are skipped.
const QUIET_SEC := 6.0

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
	FcSimHost.ask_map = "box"
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
	await _settle_and_check_origin()
	_check_one_local_player()
	_check_weapon()
	_print_server_loadout_lines()
	await _watch("idle", func(_t: float) -> void: pass)
	# Delayed, bunched snapshots: the main thread stalls at random (the datagrams queue and arrive together), the
	# view of a player who stands still may not move or alternate.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var next_stall := 0.0
	await _watch("stalled", func(t: float) -> void:
		if t >= next_stall:
			OS.delay_msec(rng.randi_range(60, 220))
			next_stall = t + rng.randf_range(0.2, 0.6))
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
	# The native window without focus (the app shell keeps it): the mouse is not captured ("Click to play"), the OS
	# recentres the cursor and the game gets a stream of motion. The view holds still, keeps its weapon, and does not
	# alternate between the server's pose and the predicted one.
	_client.set("mouse_capture_override", false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var spin := RandomNumberGenerator.new()
	spin.seed = 11
	await _watch("unfocused", func(_t: float) -> void:
		var motion := InputEventMouseMotion.new()
		motion.relative = Vector2(spin.randf_range(-400.0, 400.0), spin.randf_range(-300.0, 300.0))
		motion.position = Vector2(640, 360)
		Input.parse_input_event(motion))
	_check(not bool(_client.call("mouse_drives_view")), "unfocused: the mouse does not drive the view")
	_check_weapon()
	_end()


## From the moment the local player is alive for three seconds: the eye is never drawn at the map origin while the
## load cover is down (it was, until the first server state placed the player: an 18 m teleport at join).
func _settle_and_check_origin() -> void:
	var drawn_at_origin := 0
	var end := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
		var p: Object = _client.get("player")
		var gate: Object = _client.get("gate")
		var cam: Camera3D = p.get("camera") if p != null else null
		if cam == null or gate == null or not bool(gate.call("is_open")):
			continue
		if bool(p.call("is_alive")) and Vector2(cam.global_position.x, cam.global_position.z).length() < 0.1:
			drawn_at_origin += 1
			if drawn_at_origin == 1:
				var net: Node = p.get_node_or_null("Net")
				print("  at the origin with the cover down: state tick %s, gate %s" % [
					str(net.get("last_state_tick")) if net != null else "no net", str(gate.call("reasons"))])
	_check(drawn_at_origin == 0, "the eye is never drawn at the map origin once the cover is down", str(drawn_at_origin))


func _count_players(node: Node, id: int) -> int:
	var found := 1 if node.get_class() != "" and node.get_script() != null and node.get("player_id") != null \
		and node.has_method("is_alive") and int(node.get("player_id")) == id else 0
	for child in node.get_children():
		found += _count_players(child, id)
	return found


func _check_one_local_player() -> void:
	var p: Object = _client.get("player")
	var n := _count_players(_client, int(p.get("player_id")))
	_check(n == 1, "exactly one entity is the local player", str(n))


func _check_weapon() -> void:
	var p: Object = _client.get("player")
	var arsenal: Object = p.get("arsenal")
	var def: Object = arsenal.call("current_def") if arsenal != null else null
	var net: Node = p.get_node_or_null("Net")
	var detail := "carry %s, ready %s, wire ids %s, slots %s, catalogue %s, state tick %s, mode %s" % [
		str(net.get("net_carry")) if net != null else "?", str(arsenal.call("is_ready")) if arsenal != null else "?",
		str(FcContent.Roles.wire_ids().size()),
		str(arsenal.call("slots").size()) if arsenal != null else "no arsenal",
		str(arsenal.get("catalogue").call("size")) if arsenal != null and arsenal.get("catalogue") != null else "none",
		str(net.get("last_state_tick")) if net != null else "no net",
		str(_client.get("game").get("mode_id")) if _client.get("game") != null else "?"]
	_check(def != null, "the local player holds a weapon", detail)
	var vm: Node3D = _client.get("view_model")
	_check(vm != null and vm.is_visible_in_tree(), "the view model is shown")


func _watch(phase: String, drive: Callable) -> void:
	var worst_turn := 0.0
	var worst_jump := 0.0
	var foreign := 0
	var frames := 0
	var turns := 0
	var shown := 0
	var last := Transform3D.IDENTITY
	var last2 := Transform3D.IDENTITY
	var have := false
	var have2 := false
	var flips := 0
	var round_seen := -1
	var started := Time.get_ticks_msec()
	var quiet := 0.0
	var last_bad := -QUIET_SEC
	var prev_ms := started
	while quiet < QUIET_NEED_SEC and (Time.get_ticks_msec() - started) < int(PHASE_CAP_SEC * 1000.0):
		await get_tree().process_frame
		var t := (Time.get_ticks_msec() - started) / 1000.0
		drive.call(t)
		var dt := (Time.get_ticks_msec() - prev_ms) / 1000.0
		prev_ms = Time.get_ticks_msec()
		var p: Object = _client.get("player")
		if p == null or not bool(p.call("is_alive")):
			last_bad = t
			have = false
			continue
		var cam: Camera3D = p.get("camera")
		var gate: Object = _client.get("gate")
		# The round starting (the end of the warmup) puts every player on a round spawn: a teleport by design.
		var round_now := int(_client.get("game").get("match_node").get("round_number"))
		if round_seen != -1 and round_now != round_seen:
			last_bad = t
		round_seen = round_now
		# Under the loading cover the view is not on screen; a jump there is the join, not a flash.
		if cam == null or t - last_bad < QUIET_SEC or (gate != null and not bool(gate.call("is_open"))):
			have = false
			continue
		# Only time outside a stall counts as watched time.
		quiet += minf(dt, 0.1)
		frames += 1
		if get_viewport().get_camera_3d() != cam:
			foreign += 1
		var now := cam.global_transform
		if have:
			var turn := rad_to_deg((-last.basis.z).angle_to(-now.basis.z))
			var jump := last.origin.distance_to(now.origin)
			worst_turn = maxf(worst_turn, turn)
			worst_jump = maxf(worst_jump, jump)
			# A, B, A: the pose goes away and comes back the next frame (server state against predicted state).
			if have2 and (turn > 1.0 or jump > 0.2) and last2.origin.distance_to(now.origin) < 0.05 \
					and rad_to_deg((-last2.basis.z).angle_to(-now.basis.z)) < 0.5:
				flips += 1
			if turn > MAX_TURN_DEG:
				turns += 1
			if (turn > MAX_TURN_DEG or jump > MAX_JUMP_M) and shown < 40:  # the first few say where
				shown += 1
				print("  frame %d t=%.2fs: turn %.1f deg, jump %.2f m, from %s to %s, cam current %s, state tick %s, gate open %s" % [
					frames, t, turn, jump, last.origin, now.origin, str(cam.current), str(p.get_node("Net").get("last_state_tick")), str(gate.call("is_open"))])
		last2 = last
		have2 = have
		last = now
		have = true
	print("  [%s] %d frames, worst turn %.2f deg, %d turns over %.0f, worst jump %.2f m, %d frames on another camera" % [
		phase, frames, worst_turn, turns, MAX_TURN_DEG, worst_jump, foreign])
	_check(frames > 20, phase + ": the player was watched", str(frames))
	_check(flips == 0, phase + ": the view never alternates between two poses", str(flips))
	_check(foreign == 0, phase + ": the viewport shows the player's own camera every frame", str(foreign))
	_check(worst_turn <= MAX_TURN_DEG, phase + ": view never turns between frames", "%.2f deg" % worst_turn)
	_check(worst_jump <= MAX_JUMP_M, phase + ": eye never jumps between frames", "%.2f m" % worst_jump)


## The loadout lines of the hosted server's own log: the server arms the player, the client only hears of it.
func _print_server_loadout_lines() -> void:
	var text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(FcSimHost.SERVER_LOG))
	var shown := 0
	for line in text.split("\n"):
		if shown < 40 and (line.contains("loadout") or line.contains("arsenal") or line.contains("give")):
			shown += 1
			print("  [server] ", line.left(240))
	print("  [server] log: %d bytes, %d loadout lines" % [text.length(), shown])
	var lines := text.split("\n")
	for i in range(maxi(0, lines.size() - 14), lines.size()):
		print("  [server] tail: ", lines[i].left(200))


func _end() -> void:
	FcSimHost.forced = -1
	FcSimHost.ask_map = ""
	if _client != null:
		_client.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	print("headless_hosted_view: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
