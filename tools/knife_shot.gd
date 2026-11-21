extends SceneTree

## A knife thrown into a bot, then one thrown at the floor: frames of it in flight, stuck in the falling body, the body at rest, and the miss lying where it bounced to.
## `tools/knife_shot.sh [map]` writes screenshots/knife_throw/; `--boomerang` first throws a Boomerang knife where its whole
## loop is clear and films it three times: from above the loop (`<map>_5_boomerang_<n>`: out the configured distance, the
## circle, back to the throw point), chasing the knife (`_6_chase_<n>`: spin and streak) and through the thrower's own eyes
## (`_7_catch_<n>`: the hand empty until the knife comes back into it). `--distance M` / `--radius M` set
## fc_knife_boomerang_distance / _radius for the run, `--slow F` the time scale while filming (default 0.1), `--frames N`
## stops each pass after N frames (default 0: when the knife is caught or lands).
## Fails (exit 1) when the farthest point is off the distance, it does not come back, does not spin or is not caught.
## The bots are frozen and nobody can die; the tool's camera wins over the client's (which re-asserts its own every frame).

const FcPresentation := preload("../game/fc_presentation.gd")
const OUT_DIR := "res://screenshots/knife_throw"

var client: Node = null
var _map := "dm_atrium"
var _cam: Camera3D = null
var _keeper: CameraKeeper = null


## Keeps the tool's camera current: the client makes the player's camera current again every frame, so this runs after
## it (the highest process priority runs last) while [member hold] is set.
class CameraKeeper extends Node:
	var cam: Camera3D = null
	var hold: bool = false
	## Called every frame while set (after the knives layer drew), to keep a moving subject in frame.
	var follow: Callable = Callable()

	func _ready() -> void:
		process_priority = 1 << 30
		process_physics_priority = 1 << 30

	func _process(_delta: float) -> void:
		if hold and cam != null and not cam.current:
			cam.current = true
		if follow.is_valid():
			follow.call()

	func _physics_process(_delta: float) -> void:
		_process(0.0)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--map")
	if at >= 0 and at + 1 < args.size():
		_map = args[at + 1]
	var _scratch := FcPresentation.use_scratch_settings("knife_shot")
	client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	client.set("offline_bots", 1)
	root.add_child(client)
	_run.call_deferred()


var _tick_hz := 0
var _bot = null
var _bot_far := Vector3.ZERO


## Slow motion by [param scale]: the game steps a fixed tick per physics step whatever the delta, so fewer physics steps a
## second slow the play itself, and the time scale slows what draws off the frame delta (the knife's spin) to match.
func _slow_motion(scale: float) -> void:
	if _tick_hz <= 0:
		_tick_hz = Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = maxi(1, roundi(_tick_hz * scale))
	Engine.time_scale = scale


## The number after [param flag] on the command line, or [param default].
func _arg(flag: String, default: float) -> float:
	var args := OS.get_cmdline_user_args()
	var i := args.find(flag)
	return float(args[i + 1]) if i >= 0 and i + 1 < args.size() else default


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	return root.world_3d.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF))


func _spot(game) -> Dictionary:
	for spawn: Transform3D in game.map.spawns:
		var foot: Vector3 = spawn.origin
		for n in 16:
			var dir := Vector3(sin(n * TAU / 16.0), 0.0, cos(n * TAU / 16.0))
			if _ray(foot + Vector3.UP, foot + Vector3.UP + dir * 7.0).is_empty():
				return {"me": foot, "bot": foot + dir * 5.0, "dir": dir}
	return {}


func _grab(name: String) -> void:
	await process_frame
	await process_frame
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, name])
	root.get_texture().get_image().save_png(path)
	print("wrote %s" % path)


## The side camera [param back] metres off [param at], a little above it.
func _look(at: Vector3, side: Vector3, back: float) -> void:
	_cam.global_position = at + side * back + Vector3.UP * 0.7
	_cam.look_at(at, Vector3.UP)
	_take_camera(true)


func _take_camera(on: bool) -> void:
	_keeper.hold = on
	_cam.current = on
	if not on:
		var me = client.get("player")
		if me != null and me.camera != null:
			me.camera.current = true


## Nobody dies while filming: the bots stand still (scripted) and nobody takes damage.
func _freeze(game, me) -> void:
	me.health.invulnerable = true
	for id in game.player_ids():
		if id != me.player_id:
			var bot = game.player_for(id)
			if bot != null:
				bot.set_meta(&"bot_scripted", true)
				bot.health.invulnerable = true


## The slot with a knife in front (the melee slot is not one of 1..7 on every loadout), or -1.
func _knife_slot(me) -> int:
	for slot: int in me.arsenal.slots():
		var held: Array = me.arsenal.weapons_in(slot)
		if not held.is_empty() and held[0].id() == &"knife":
			return slot
	return -1


## Teleports [param me] to [param at] looking along [param yaw] (degrees). The client's own look sampler feeds the
## controller every tick, so it is turned too or the next tick swings the view straight back.
func _place(me, at: Vector3, yaw: float) -> void:
	me.controller.teleport(at, yaw, 0.0)
	var sampler = client.get("_sampler")
	if sampler != null and me == client.get("player"):
		sampler.look_at_angles(yaw, 0.0)


## What [param me] carries, slot by slot (front first), for the log.
func _carried(me) -> String:
	var out := PackedStringArray()
	for slot: int in me.arsenal.slots():
		var ids := PackedStringArray()
		for w in me.arsenal.weapons_in(slot):
			ids.append(String(w.id()))
		out.append("%d:%s" % [slot, "/".join(ids)])
	return " ".join(out)


## The knife into the hand; its slot, or -1 without one.
func _knife_to_hand(me) -> int:
	var slot := _knife_slot(me)
	if slot >= 0:
		me.arsenal.bring_to_hand(slot)
	return slot


## Takes the knife out of the arsenal the way a throw does (dot_weapon_knives `_release`): the drop state rides the knife.
func _knife_out(me) -> Dictionary:
	var slot := _knife_to_hand(me)
	if slot < 0:
		return {}
	return me.arsenal.drop_from_slot(slot, [] as Array[int])


func _miss_throw(game: Object, me: Object, bot: Object, spot: Dictionary, yaw: float, dir: Vector3, side: Vector3) -> int:
	var failures := 0
	var eye: Vector3
	# A miss: at the floor a few metres off to the side, and where it ends up.
	_place(me, spot["me"], yaw)
	await _wait(0.2)
	var floor_at: Vector3 = spot["me"] + side * 3.0 - dir * 0.5
	if me.arsenal.carries(&"knife"):
		var _second := _knife_out(me)
	eye = me.muzzle_position()
	var miss_id: int = game.knives.throw(me.player_id, eye, (floor_at - eye).normalized())
	_look(floor_at, -dir, 4.0)
	for n in 3:
		await _wait(0.06)
		await _grab("%s_3_bounce_%d" % [_map, n])
	await _wait(2.0)
	var miss = game.knives.get_knife(miss_id)
	print("miss phase=%s bounces=%s at=%s" % [miss.phase if miss != null else -1, miss.bounces if miss != null else -1, miss.at if miss != null else Vector3.ZERO])
	if miss == null or miss.phase != 1:
		failures += 1
	_look(miss.at if miss != null else floor_at, side, 1.2)
	await _grab("%s_4_rest" % _map)
	return failures


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var game = client.get("game")
	for i in range(80):
		await _wait(0.25)
		game = client.get("game")
		if game != null and game.map != null and client.get("player") != null:
			break
	var _changed = game.change_map(load("res://maps/fc_map.gd").by_id(StringName(_map)))
	await _wait(3.0)
	# The weapons warm up under the loading cover after the map opens; frames before it lifts film the cover.
	var gate: Object = client.get("gate")
	for i in range(240):
		if gate == null or gate.call(&"is_open"):
			break
		await _wait(0.25)
	var me = client.get("player")
	var bots: Dictionary = client.get("_bots")
	var bot_id := int(bots.keys()[0])
	var bot = game.player_for(bot_id)
	var spot := _spot(game)
	if spot.is_empty() or bot == null or game.knives == null:
		print("FAIL no spot, bot or knives layer")
		quit(1)
		return
	_cam = Camera3D.new()
	_cam.fov = 60.0
	root.add_child(_cam)
	_keeper = CameraKeeper.new()
	_keeper.cam = _cam
	root.add_child(_keeper)
	_freeze(game, me)
	var args := OS.get_cmdline_user_args()
	for knob in ["distance", "radius"]:
		var i := args.find("--" + knob)
		if i >= 0 and i + 1 < args.size():
			game.knives.rules["boomerang_" + knob] = float(args[i + 1])
	var dir: Vector3 = spot["dir"]
	var side := dir.cross(Vector3.UP).normalized()
	var yaw := rad_to_deg(atan2(-dir.x, -dir.z))  # the controller keeps degrees
	for _k in 2:
		_place(me, spot["me"], yaw)
		bot.controller.teleport(spot["bot"], yaw + 180.0, 0.0)
		await _wait(0.4)
	var failures := 0
	if args.has("--boomerang"):
		failures += await _boomerang(game, me, bot)
		for _k in 2:
			_place(me, spot["me"], yaw)
			bot.controller.teleport(spot["bot"], yaw + 180.0, 0.0)
			await _wait(0.4)
	bot.health.invulnerable = false
	bot.health.invulnerable_until_tick = -1

	# The throw, from the eye at the bot's chest.
	var _first := _knife_out(me)
	var eye: Vector3 = me.muzzle_position()
	var chest: Vector3 = bot.controller.state.position + Vector3.UP * 1.15
	var _id: int = game.knives.throw(me.player_id, eye, (chest - eye).normalized())
	_look(eye.lerp(chest, 0.5), side, 3.0)
	await _grab("%s_1_flight" % _map)
	for at_sec in [0.4, 1.2, 3.0]:
		await _wait(at_sec - (0.0 if at_sec == 0.4 else (0.4 if at_sec == 1.2 else 1.2)))
		var held: Array = game.knives.entries()
		var k = held[0] if not held.is_empty() else null
		var where: Vector3 = k.holder.global_position if k != null and k.holder != null else chest
		print("t=%.1f knives=%d phase=%s victim=%s alive=%s part=%s at=%s" % [at_sec, held.size(),
			k.phase if k != null else -1, k.victim if k != null else -1, game.combat.health_of(bot_id).alive,
			k.part.name if k != null and k.part != null else "none", where])
		if k == null or k.phase != 2:
			failures += 1
		_look(where, side, 1.6)
		await _grab("%s_2_stuck_%02d" % [_map, int(at_sec * 10.0)])

	failures += await _miss_throw(game, me, bot, spot, yaw, dir, side)

	quit(1 if failures > 0 else 0)


## A spawn and a direction whose whole Boomerang loop (as the knives layer will fly it) is clear of walls, the floor
## under the throw point found; {} when none on the map is.
func _loop_spot(game, me) -> Dictionary:
	var eye_up: float = (me.muzzle_position() - me.controller.state.position).y
	for spawn: Transform3D in game.map.spawns:
		var foot: Vector3 = spawn.origin
		for n in 16:
			var dir := Vector3(sin(n * TAU / 16.0), 0.0, cos(n * TAU / 16.0))
			var eye := foot + Vector3.UP * eye_up
			var path := _loop_points(game, eye, dir)
			var clear := path.size() > 2
			for i in range(1, path.size()):
				if not clear:
					break
				# A little above and below the line, so the knife's streak does not graze a ledge either.
				for lift in [0.25, -0.25]:
					if not _ray(path[i - 1] + Vector3.UP * lift, path[i] + Vector3.UP * lift).is_empty():
						clear = false
						break
			if clear:
				return {"me": foot, "dir": dir, "path": path}
	return {}


## The loop the knives layer flies from [param eye] along [param dir], sampled every half metre.
func _loop_points(game, eye: Vector3, dir: Vector3) -> PackedVector3Array:
	var k := GSWeaponKnives.Knife.new()
	k.at = eye
	k.velocity = dir * float(game.knives.rules.get("speed", 40.0))
	game.knives.set("_throw_power", 1.0)
	game.knives._launch_boomerang(k)
	var out := PackedVector3Array()
	if k.path_len <= 0.0:
		return out
	var s := 0.0
	while s < k.path_len:
		out.append(game.knives._path_point(k, s)[0])
		s += 0.5
	out.append(k.origin)
	return out


## Throws a Boomerang from [param spot] the way the aim key does (knife in hand, out of the arsenal, into the air) and
## films it with [param shoot] (called with the knife each frame grabbed and the grab's index) until it is caught or
## lands; [param frames_max] stops sooner (0 = until then). Returns what it saw: farthest along the throw, closest
## return to the throw point and to the hand, spin, caught, the hand empty all the way.
func _fly_once(game, me, spot: Dictionary, shoot: Callable, name: String, frames_max: int) -> Dictionary:
	var dir: Vector3 = spot["dir"]
	var yaw := rad_to_deg(atan2(-dir.x, -dir.z))  # the controller keeps degrees
	var slow := Engine.time_scale
	_slow_motion(1.0)
	# A round going live respawns everyone and a countdown holds the arsenal shut: wait for the round to be live
	# (a warm-up turns into a countdown mid-flight otherwise) and a live hand.
	for _w in 240:
		var now = client.get("player")
		if now != null and is_instance_valid(now):
			me = now
		var live: bool = game.match_node == null or game.match_node.state == GSMatch.State.LIVE
		if live and not me.arsenal.disabled and not game.round_frozen():
			break
		await _wait(0.25)
	if _bot != null and is_instance_valid(_bot):
		_bot.controller.teleport(_bot_far, 0.0, 0.0)
	for _k in 2:
		_place(me, spot["me"], yaw)
		await _wait(0.3)
	var seen := {"along": 0.0, "back": INF, "hand": INF, "spun": 0.0, "caught": false, "empty": true, "frames": 0,
		"fell": false, "ticks": 0}
	if _knife_to_hand(me) < 0:
		print("FAIL %s: the thrower has no knife to throw (%s)" % [name, _carried(me)])
		_slow_motion(slow)
		return seen
	await _wait(0.8)
	var eye: Vector3 = me.muzzle_position()
	var before := _carried(me)
	var state := _knife_out(me)
	print("%s: carried %s; after the throw %s" % [name, before, _carried(me)])
	var id: int = game.knives.throw(me.player_id, eye, dir, Vector3.ZERO, 1.0, true, state)
	_slow_motion(slow)
	var k = game.knives.get_knife(id)
	var n := 0
	while frames_max <= 0 or n < frames_max:
		k = game.knives.get_knife(id)
		if k == null or k.phase != GSWeaponKnives.Phase.FLY:
			break
		seen["along"] = maxf(seen["along"], (k.at - eye).dot(dir))
		if k.leg == 2:
			seen["back"] = minf(seen["back"], k.at.distance_to(eye))
			seen["hand"] = minf(seen["hand"], k.at.distance_to(me.muzzle_position()))
		seen["spun"] = maxf(seen["spun"], k.spun)
		seen["ticks"] = k.age
		if me.arsenal.carries(&"knife"):
			seen["empty"] = false
		if not k.glide:
			seen["fell"] = true
		shoot.call(k, n)
		await _grab("%s_%s_%02d" % [_map, name, n])
		n += 1
	seen["caught"] = game.knives.get_knife(id) == null and me.arsenal.carries(&"knife") and not seen["fell"]
	seen["frames"] = n
	print("%s: carried after %s" % [name, _carried(me)])
	# A few more after the catch: the knife back in the hand.
	for after in 3:
		shoot.call(null, n)
		await _wait(0.15)
		await _grab("%s_%s_%02d" % [_map, name, n])
		n += 1
	print("%s: farthest %.2f m along the throw (distance %.1f), closest back to the throw point %.2f m and to the hand %.2f m, spun %.1f rad over %d ticks, caught %s, hand empty in flight %s, %d frames" % [
		name, seen["along"], float(game.knives.rules["boomerang_distance"]), seen["back"], seen["hand"], seen["spun"], seen["ticks"], seen["caught"], seen["empty"], seen["frames"]])
	return seen


## The Boomerang filmed from above, chasing it and through the thrower's eyes; returns the number of failed checks.
func _boomerang(game, me, bot) -> int:
	var spot := _loop_spot(game, me)
	if spot.is_empty():
		print("FAIL no spot on %s where the whole Boomerang loop is clear" % _map)
		return 1
	# The bot well away from the loop.
	var far: Vector3 = spot["me"]
	for spawn: Transform3D in game.map.spawns:
		if spawn.origin.distance_to(spot["me"]) > far.distance_to(spot["me"]):
			far = spawn.origin
	_bot = bot
	_bot_far = far
	bot.controller.teleport(far, 0.0, 0.0)
	var path: PackedVector3Array = spot["path"]
	var lo := path[0]
	var hi := path[0]
	for q in path:
		lo = Vector3(minf(lo.x, q.x), minf(lo.y, q.y), minf(lo.z, q.z))
		hi = Vector3(maxf(hi.x, q.x), maxf(hi.y, q.y), maxf(hi.z, q.z))
	var middle := (lo + hi) * 0.5
	var dir: Vector3 = spot["dir"]
	var slow := _arg("--slow", 0.1)
	var frames := int(_arg("--frames", 0.0))
	var distance := float(game.knives.rules["boomerang_distance"])
	var reach := float(game.knives.rules.get("boomerang_catch", 0.0))
	var failures := 0
	var config: Variant = game.get("config")
	if config != null:
		config.set(&"spawn_protection_bubble", false)
	var side := dir.cross(Vector3.UP).normalized()
	var eye: Vector3 = spot["me"] + Vector3.UP * (me.muzzle_position() - me.controller.state.position).y
	root.canvas_cull_mask = 0
	_slow_motion(slow)
	# 1. Over the thrower's shoulder, high: the throw, the far turn and the way back all in frame.
	_cam.fov = 70.0
	_cam.global_position = eye - dir * 6.0 - side * 2.5 + Vector3.UP * 5.0
	_cam.look_at(middle + Vector3.DOWN * 1.0, Vector3.UP)
	_take_camera(true)
	var top: Dictionary = await _fly_once(game, me, spot, func(_k, _n): pass, "5_boomerang", frames)
	# 2. Chasing the knife from just behind and off its side, moved every frame.
	_cam.fov = 60.0
	var chase := func(k, _n):
		if k == null or k.holder == null:
			_keeper.follow = Callable()
			return
		_keeper.follow = func():
			if k.holder == null or not is_instance_valid(k.holder):
				return
			var at: Vector3 = k.holder.global_position
			var heading: Vector3 = k.velocity.normalized() if k.velocity.length() > 0.1 else dir
			var off := heading.cross(Vector3.UP).normalized()
			_cam.global_position = at - heading * 1.3 - off * 0.9 + Vector3.UP * 0.45
			_cam.look_at(at + heading * 0.4, Vector3.UP)
	var near: Dictionary = await _fly_once(game, me, spot, chase, "6_chase", frames)
	_keeper.follow = Callable()
	# 3. Through the thrower's eyes, looking along the throw: the hand empty until the catch.
	root.canvas_cull_mask = 0xFFFFFFFF
	_take_camera(false)
	var mine: Dictionary = await _fly_once(game, me, spot, func(_k, _n): pass, "7_catch", frames)
	_slow_motion(1.0)
	if config != null:
		config.set(&"spawn_protection_bubble", true)
	for seen: Dictionary in [top, near, mine]:
		if absf(seen["along"] - distance) > 1.0:
			print("FAIL the farthest point %.2f m is not the configured %.1f m" % [seen["along"], distance])
			failures += 1
		if seen["spun"] < TAU:
			print("FAIL it barely spun (%.1f rad)" % seen["spun"])
			failures += 1
		if not seen["empty"]:
			print("FAIL the thrower's hand held a knife while it flew")
			failures += 1
		if reach > 0.0 and not seen["caught"]:
			print("FAIL not caught in the air (closest to the hand %.2f m, reach %.1f m)" % [seen["hand"], reach])
			failures += 1
		if seen["back"] > maxf(reach, 0.5) + 1.5:
			print("FAIL it did not come back to the throw point (closest %.2f m)" % seen["back"])
			failures += 1
	return failures
