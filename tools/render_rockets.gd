extends "render_base.gd"

## The single-missile RPG, a bouncing grenade and a Rocketjump in the real offline client, each from the shooter's
## eye and from outside: frames to judge whether they look like a game (owner batch 2026-11-15 items 2, 3, 9, 10).
##
##     tools/render_rockets.sh [map]      # frames in screenshots/rockets/<map>_<shot>_NN.png
##
## Everything goes through the player's own input (`arena_fire`, `dot_fps_jump`), so the missile, the bounce and
## the launch are the game's, not a stand-in.

const ArenaPlayer := preload("../game/arena_player.gd")

## Seconds between the frames of a sequence.
const EVERY := 0.07
## Metres down the lane the shooter stands.
const INTO_LANE := 7.0



func _setup() -> void:
	_out_dir = "res://screenshots/rockets"
	_scratch_name = "render_rockets"
	_map_id = "dm_atrium"


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	return root.world_3d.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF))


## The spawn and flat direction with the longest clear run (up to 30 m) at chest height.
func _lane(game) -> Dictionary:
	var best := {}
	var best_len := 0.0
	for spawn: Transform3D in game.map.spawns:
		var foot: Vector3 = spawn.origin
		for n in 16:
			var dir := Vector3(sin(n * TAU / 16.0), 0.0, cos(n * TAU / 16.0))
			var hit := _ray(foot + Vector3.UP * 1.2, foot + Vector3.UP * 1.2 + dir * 30.0)
			var run := 30.0 if hit.is_empty() else (foot + Vector3.UP * 1.2).distance_to(hit["position"])
			var head := _ray(foot + Vector3.UP, foot + Vector3.UP * 8.0)
			if run > best_len and head.is_empty():
				best_len = run
				best = {"feet": foot, "dir": dir, "run": run}
	return best


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	client.set("offline_bots", 0)
	var game = null
	for i in 120:
		await _wait(0.25)
		game = client.get("game")
		if game != null and game.map != null and client.get("player") != null:
			break
	if String(game.map.id) != _map_id:
		var _changed = game.change_map(load("res://maps/arena_map.gd").by_id(StringName(_map_id)))
		await _wait(3.0)
	await _wait_gate(120.0)
	await _wait(1.0)
	var me = client.get("player")
	me.health.invulnerable = true
	# The spawn bubble would hide the shooter in every outside frame.
	for id: int in game._players:
		if game._players[id] == me:
			game.end_spawn_protection(id)
	var lane := _lane(game)
	if lane.is_empty():
		print("FAIL no clear lane on %s" % _map_id)
		quit(1)
		return
	print("lane from %s along %s, %.1f m clear" % [lane["feet"], lane["dir"], lane["run"]])

	for outside in [false, true]:
		# Outside is the game's own third-person camera: the only view that draws the shooter's body and gun.
		client.call(&"_set_third_person", outside)
		var view := "out" if outside else "fp"
		await _rpg(game, me, lane, view)
		await _grenade(game, me, lane, view)
		await _rocketjump(game, me, lane, view)

	print("%d checks failed" % _failed)
	quit(1 if _failed > 0 else 0)



func _hold(me, id: StringName, warhead: bool) -> DotWeaponDef:
	var arsenal = me.arsenal
	var _given: DotResult = arsenal.give(id)
	var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(id)
	var _held: bool = arsenal.equip(def.slot)
	var fitting := DotWeaponFitting.make(id)
	if warhead:
		fitting.fit(&"warhead", &"rocketjump")
	var fitted: DotResult = arsenal.fit(def.slot, fitting)
	_check(fitted.ok, "%s fitted%s" % [id, " with the Rocketjump" if warhead else ""])
	return arsenal.current_def()


func _place(me, lane: Dictionary, pitch: float) -> void:
	var dir: Vector3 = lane["dir"]
	# Some way down the lane, so the third-person camera behind the shooter stands in the clear run, not in the
	# wall the spawn backs onto.
	var feet: Vector3 = lane["feet"] + dir * minf(INTO_LANE, float(lane["run"]) * 0.3)
	_put(feet, feet + dir * 10.0, pitch)
	# The spawn bubble would hide the shooter from behind (the tool made them invulnerable, which is not protection).
	me.protected_view = false


func _press(action: StringName, seconds: float) -> void:
	Input.action_press(action)
	await _wait(seconds)
	Input.action_release(action)


func _sequence(name: String, count: int) -> void:
	for i in count:
		await _shot("%s_%02d" % [name, i])
		await _wait(EVERY)


## Item 2 and 3: one missile, the launcher's own model with its exhaust, and the 5.5 m blast at the end of the lane.
func _rpg(game, me, lane: Dictionary, view: String) -> void:
	var def := _hold(me, &"launcher", false)
	_check(def != null and def.magazine == 1, "the RPG holds one missile")
	_place(me, lane, 0.0)
	await _wait(1.2)
	await _shot("rpg_%s_ready" % view)
	var before: int = game.projectiles.flying().size()
	Input.action_press(&"arena_fire")
	await _wait(0.1)
	Input.action_release(&"arena_fire")
	var flying: int = game.projectiles.flying().size() - before
	_check(flying == 1, "%s: one missile in the air (%d)" % [view, flying])
	await _sequence("rpg_%s" % view, 6)
	await _wait(1.5)


## Item 9: a frag thrown at the floor ahead bounces and rolls instead of stopping dead. (The grenade launcher's round
## is a contact round in fc-weapons, with no fuse, so it goes off where it lands, as before.)
func _grenade(game, me, lane: Dictionary, view: String) -> void:
	var _def := _hold(me, &"frag", false)
	_place(me, lane, -25.0)
	await _wait(1.0)
	await _press(&"arena_fire", 0.1)
	var bounced := 0
	for i in 10:
		await _shot("grenade_%s_%02d" % [view, i])
		for f in game.projectiles.flying():
			bounced = maxi(bounced, int(f.bounces))
		await _wait(EVERY)
	_check(bounced >= 1, "%s: the frag bounced (%d)" % [view, bounced])
	await _wait(3.0)


## Item 10: jump, look down and fire the Rocketjump: the blast throws the shooter up and forward.
func _rocketjump(game, me, lane: Dictionary, view: String) -> void:
	var _def := _hold(me, &"launcher", true)
	_place(me, lane, -85.0)
	await _wait(1.2)
	var start: float = me.controller.state.position.y
	Input.action_press(&"dot_fps_forward")
	Input.action_press(&"dot_fps_jump")
	await _wait(0.08)
	Input.action_press(&"arena_fire")
	await _wait(0.1)
	Input.action_release(&"arena_fire")
	Input.action_release(&"dot_fps_jump")
	var top := start
	for i in 8:
		await _shot("rocketjump_%s_%02d" % [view, i])
		top = maxf(top, me.controller.state.position.y)
		await _wait(EVERY)
	Input.action_release(&"dot_fps_forward")
	for i in 20:
		await _wait(0.05)
		top = maxf(top, me.controller.state.position.y)
	print("%s rocketjump rose %.2f m" % [view, top - start])
	_check(top - start > 2.0, "%s: the Rocketjump throws the shooter well above a jump (%.2f m)" % [view, top - start])
	await _wait(1.5)
