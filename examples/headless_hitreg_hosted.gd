extends Node

const FcPresentation := preload("../game/fc_presentation.gd")
const FcSimHost := preload("../game/fc_sim_host.gd")
const FcBindings := preload("../game/fc_bindings.gd")
const FcPlayer := preload("../game/fc_player.gd")

## The owner's recording (3:24, strip_204.20): the hosted solo game (a loopback server process, 32 bots, 66 tick), a scoped rifle, a bot 40-80 m out walking,
## a spark on its body and no hit marker. This plays that game as the owner did: the local player scopes in on the body its own screen draws, holds the
## crosshair on the middle of the torso, and taps. Every tap whose predicted shot hits that bot must come back from the server as a HIT; and a tap
## aimed at the drawn torso should be predicted to hit it. Each tap prints its range, the bot's drawn speed, where the ray passed the torso and both verdicts.

## 31 bots and the player are 32 players, the top of the hosted room's 66-tick tier (`solo_tick_tiers`); one more drops it to 33.
const BOTS := 31
## The drawn body a predicted impact counts on: within this of the feet across, and from the feet to this above them.
const BODY_RADIUS_M := 0.5
const BODY_TOP_M := 2.0
## The video's band; the closest bot in it with a clear line is the one shot.
const NEAR_M := 38.0
const FAR_M := 85.0
const TAPS := 48
const RUN_CAP_SEC := 240.0
## Frames scoped and tracking the drawn torso before the tap (the scope settles), and frames after it for the server's HIT.
const TRACK_FRAMES := 24
const CONFIRM_SEC := 0.6
## How close the predicted ray must pass the drawn torso's centre for the tap to count as aimed there.
const AIMED_M := 0.12

var _checks := 0
var _failed := 0
var _client: Node = null
var _shot: GSShot = null
var _confirmed: Dictionary = {}


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	var _scratch := FcPresentation.use_scratch_settings(_suite())
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


## This run's name, for its scratch settings and its last line.
func _suite() -> String:
	return "headless_hitreg_hosted"


## Server cvars (`name=value`) the hosted server is started with; a variant names its own.
func _server_cvars() -> PackedStringArray:
	return PackedStringArray()


static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


## The middle of [param p]'s drawn torso.
static func torso(p: FcPlayer) -> Vector3:
	return p.global_position + Vector3(0.0, p.eye_height() * 0.72, 0.0)


func _run() -> void:
	print("game-fatal-contact: hosted solo, %d bots, scoped taps at a drawn bot %.0f-%.0f m out; server cvars %s" % [BOTS, NEAR_M, FAR_M, _server_cvars()])
	FcSimHost.ask_cvars = _server_cvars() + PackedStringArray(["sv_shot_debug=1"])
	FcSimHost.ask_map = "dm_atrium"
	FcSimHost.ask_mode = "snipers"
	FcSimHost.hold_joined_sec = 1.0
	for act in [FcBindings.FIRE, FcBindings.AIM]:
		if not InputMap.has_action(act):
			InputMap.add_action(act)
	if not await _start_client():
		await _end()
		return
	var limit := FcSimHost.BOOT_LIMIT_SEC + FcSimHost.JOIN_LIMIT_SEC + FcSimHost.hold_joined_sec + 60.0
	var built := await _until(func() -> bool: return _client.get("game") != null, limit)
	_check(built, "the hosted client builds")
	if not built:
		await _end()
		return
	var g: Object = _client.get("game")
	var alive := await _until(func() -> bool:
		var p: Object = _client.get("player")
		return p != null and bool(p.call("is_alive")), 60.0)
	_check(alive, "the local player is alive")
	if not alive:
		await _end()
		return
	var bridge: Object = _client.get("bridge")
	_check(bridge != null, "the hosted client has a bridge")
	if bridge == null:
		await _end()
		return
	bridge.connect(&"hit_received", func(info: Dictionary) -> void:
		var v := int(info.get("victim_id", 0))
		_confirmed[v] = int(_confirmed.get(v, 0)) + 1)
	print("  tick rate %d, players %d" % [int(g.get("tick_rate")), (g.call("players") as Array).size()])
	await _taps(g)
	_print_server_lines()
	await _end()


func _taps(g: Object) -> void:
	var sampler: GSFpsSampler = _client.get("_sampler")
	var started := Time.get_ticks_msec()
	var taps := 0
	var predicted := 0
	var predicted_confirmed := 0
	var aimed := 0
	var aimed_predicted := 0
	var aimed_confirmed := 0
	var hooked: Object = null
	var rows: Array[String] = []
	while taps < TAPS and Time.get_ticks_msec() - started < int(RUN_CAP_SEC * 1000.0):
		await get_tree().process_frame
		var me: FcPlayer = _client.get("player")
		if me == null or not me.is_alive() or me.camera == null:
			Input.action_release(FcBindings.AIM)
			continue
		if hooked != me:
			hooked = me
			# The player's `used`, which the spark is drawn from (FcClient._on_local_used), not the arsenal's: that one
			# also fires on every reconciliation replay. Copied as it is emitted, so a later re-trace of a reused shot
			# cannot rewrite what this tap drew.
			me.used.connect(func(outcome: GSWeaponOutcome) -> void:
				if _shot == null and not outcome.shots.is_empty():
					_shot = _copy_shot(outcome.shots[0]))
		var def: GSWeaponDef = me.arsenal.current_def()
		if def == null or not def.tags.has(&"scoped") or not me.arsenal.is_ready():
			continue
		var target := _pick(g, me)
		if target == null:
			continue
		# Scope in and hold the crosshair on the drawn torso, frame by frame, as a player tracks it.
		Input.action_press(FcBindings.AIM)
		var lost := false
		var drawn_prev := target.global_position
		var speed := 0.0
		for f in TRACK_FRAMES:
			await get_tree().process_frame
			if not is_instance_valid(target) or not target.is_alive() or not me.is_alive():
				lost = true
				break
			var a := angles_to(me.camera.global_position, torso(target))
			sampler.look_at_angles(a.x, a.y)
			var dt := maxf(get_process_delta_time(), 0.001)
			speed = target.global_position.distance_to(drawn_prev) / dt
			drawn_prev = target.global_position
		if lost:
			continue
		_shot = null
		var victim := int(target.get("player_id"))
		var before := int(_confirmed.get(victim, 0))
		var at := torso(target)
		var feet := target.global_position
		var range_m := me.camera.global_position.distance_to(at)
		var pinned := false
		var cam_deg := 0.0
		var eye_gap := 0.0
		var drawn_hit := false
		Input.action_press(FcBindings.FIRE)
		for _f in 3:
			await get_tree().process_frame
			if is_instance_valid(target):
				var a := angles_to(me.camera.global_position, torso(target))
				sampler.look_at_angles(a.x, a.y)
			if _shot != null and not pinned:
				pinned = true
				# The crosshair is the camera's forward; the shot should leave along it from the eye.
				cam_deg = rad_to_deg((-me.camera.global_basis.z).angle_to(_shot.direction.normalized()))
				eye_gap = me.camera.global_position.distance_to(_shot.origin)
				if is_instance_valid(target):
					at = torso(target)
					feet = target.global_position
					drawn_hit = _drawn_on(me, _shot, target)
		Input.action_release(FcBindings.FIRE)
		var waited := await _until(func() -> bool: return int(_confirmed.get(victim, 0)) > before, CONFIRM_SEC)
		if _shot == null:
			continue
		taps += 1
		var miss_m := _ray_gap(_shot.origin, _shot.direction, at)
		var said_hit := _sparked_on(_shot, feet) or drawn_hit
		var is_aimed := miss_m <= AIMED_M
		predicted += int(said_hit)
		predicted_confirmed += int(said_hit and waited)
		aimed += int(is_aimed)
		aimed_predicted += int(is_aimed and said_hit)
		aimed_confirmed += int(is_aimed and waited)
		rows.append("    tap %2d %-9s %5.1f m  bot %d drawn %.1f m/s  ray %.3f m off the torso  crosshair %.3f deg %.2f m off the shot  client %-4s server %s  tick %d feet %s dir %s" % [
			taps, def.id, range_m, victim, speed, miss_m, cam_deg, eye_gap, "HIT" if said_hit else "miss", "HIT" if waited else "nothing",
			_shot.tick, feet.snappedf(0.001), _shot.direction.normalized().snappedf(0.00001)])
		print(rows.back())
		Input.action_release(FcBindings.AIM)
		for _f in 6:
			await get_tree().process_frame
	Input.action_release(FcBindings.AIM)
	print("  taps %d; aimed at the drawn torso %d; client predicted a hit %d (%d aimed); server confirmed %d of the predicted, %d of the aimed" % [
		taps, aimed, predicted, aimed_predicted, predicted_confirmed, aimed_confirmed])
	_check(taps >= TAPS / 2, "the local player tapped at far drawn bots", "%d taps" % taps)
	_check(predicted_confirmed == predicted, "every tap the client drew hitting the bot comes back a HIT", "%d of %d" % [predicted_confirmed, predicted])
	_check(aimed_predicted == aimed, "every tap aimed at the drawn torso is predicted to hit it", "%d of %d" % [aimed_predicted, aimed])
	_check(aimed_confirmed == aimed, "every tap aimed at the drawn torso is a HIT on the server", "%d of %d" % [aimed_confirmed, aimed])


## The live bot nearest the middle of the band with a clear line from the eye to its drawn torso, or null.
func _pick(g: Object, me: FcPlayer) -> FcPlayer:
	var eye := me.camera.global_position
	var space := me.get_world_3d().direct_space_state
	var best: FcPlayer = null
	var best_d := INF
	for p: FcPlayer in g.call("players"):
		if p == me or not p.is_alive():
			continue
		var d := eye.distance_to(torso(p))
		if d < NEAR_M or d > FAR_M:
			continue
		var q := PhysicsRayQueryParameters3D.create(eye, torso(p), 1)
		if not space.intersect_ray(q).is_empty():
			continue
		var score := absf(d - 0.5 * (NEAR_M + FAR_M))
		if score < best_d:
			best_d = score
			best = p
	return best


## Whether one of [param shot]'s predicted impacts is on the drawn body standing at [param feet].
static func _sparked_on(shot: GSShot, feet: Vector3) -> bool:
	for at in shot.impacts:
		var flat := Vector2(at.x - feet.x, at.z - feet.z)
		if flat.length() <= BODY_RADIUS_M and at.y >= feet.y - 0.1 and at.y <= feet.y + BODY_TOP_M:
			return true
	return false


## Whether the client's own shot picture lands on [param target]: AwShotFx's ray (from the shot's eye, its mask, its
## carrier excluded) striking the target's body, which it draws as a flesh impact.
static func _drawn_on(me: FcPlayer, shot: GSShot, target: FcPlayer) -> bool:
	if not is_instance_valid(target) or me.weapons == null or not me.weapons.has_method(&"shot_fx"):
		return false
	var fx: AwShotFx = me.weapons.call(&"shot_fx")
	if fx == null or fx.get_world_3d() == null:
		return false
	var dir := shot.direction.normalized()
	var query := PhysicsRayQueryParameters3D.create(shot.origin, shot.origin + dir * 400.0, fx.collision_mask, fx.exclude)
	var found := fx.get_world_3d().direct_space_state.intersect_ray(query)
	var node := found.get("collider") as Node
	return node != null and (node == target or target.is_ancestor_of(node))


## What a tap needs of [param shot], taken when it is drawn.
static func _copy_shot(shot: GSShot) -> GSShot:
	var copy := GSShot.new()
	copy.origin = shot.origin
	copy.direction = shot.direction
	copy.tick = shot.tick
	copy.impacts = shot.impacts.duplicate()
	return copy


## How far the ray from [param origin] along [param direction] passes from [param at].
static func _ray_gap(origin: Vector3, direction: Vector3, at: Vector3) -> float:
	var dir := direction.normalized()
	var along := maxf(0.0, (at - origin).dot(dir))
	return (origin + dir * along).distance_to(at)


func _print_server_lines() -> void:
	var text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(FcSimHost.SERVER_LOG))
	var shown := 0
	for line in text.split("\n"):
		if line.contains("shot debug"):
			print("  [server] ", line.left(420))
		elif shown < 30 and (line.contains("rewind") or line.contains("refus") or line.contains("overrun") or line.contains("ERROR")
				or line.contains("WARNING") or line.contains("at: ")):
			shown += 1
			print("  [server] ", line.left(300))
	print("  [server] log: %d bytes, %d rewind/refusal lines" % [text.length(), shown])


## Builds [member _client]: here the solo client, which starts the hosted server process itself and joins it over its
## local link. False when nothing could be built.
func _start_client() -> bool:
	FcSimHost.forced = 1
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("offline_bots", BOTS)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	return true


func _end() -> void:
	Input.action_release(FcBindings.AIM)
	Input.action_release(FcBindings.FIRE)
	FcSimHost.forced = -1
	FcSimHost.ask_map = ""
	FcSimHost.ask_mode = ""
	FcSimHost.ask_cvars = PackedStringArray()
	if _client != null:
		_client.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	print("%s: %d checks, %d failed" % [_suite(), _checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
