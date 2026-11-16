extends "render_base.gd"

## Remote figures near and far through the real offline client: its three bots, frozen along one clear line of sight at
## 8, 28 and 36 m (both far ones past the 22 m lift range), photographed with cl_figure_lift_range at 22 m (the FC default) and at 0 (every frame), and with
## cl_figure_bone_lod_range at 22 m (the far ones posed without finger joints, foot plants or limb turn limit) beside 0, with a
## close crop of each bot beside the whole frame, so a person can see the lifted far figures still read as players.
## Frames in screenshots/far_figures/; exit 1 on a failed check. Run:
##   xvfb-run -a godot --path . --resolution 1280x720 --script tools/render_far_figures.gd

const ArenaPlayer := preload("../game/arena_player.gd")
const DISTANCES: Array[float] = [8.0, 28.0, 36.0]
const CROP := 96


func _setup() -> void:
	_out_dir = "res://screenshots/far_figures"
	_scratch_name = "render_far_figures"


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	await _wait_gate(60.0)
	await _wait(4.0)
	var game: Node = client.get("game")
	var me: Node = client.get("player")
	game.match_node.rules.warmup_sec = 0.0
	game.freeze_sec = 0.0
	for i in 100:
		if game.match_node.state == DotMatch.State.LIVE:
			break
		await _wait(0.1)
	me.health.invulnerable = true
	var bots: Array = []
	for id in game.player_ids():
		if id != me.player_id:
			var bot = game.player_for(id)
			if bot != null:
				bot.set_meta(&"bot_scripted", true)
				bot.health.invulnerable = true
				bots.append(bot)
	_check(bots.size() >= DISTANCES.size(), "at least %d bots (%d)" % [DISTANCES.size(), bots.size()])
	if bots.size() < DISTANCES.size():
		quit(1)
		return
	await _wait(1.0)
	var origins: Array = [me.global_position]
	for bot in bots:
		origins.append(bot.global_position)
	var line := {}
	var from: Vector3 = origins[0]
	for o: Vector3 in origins:
		line = _clear_line(o)
		if not line.is_empty():
			from = o
			break
	_check(not line.is_empty(), "a clear line %d m long from the player or a bot" % int(DISTANCES[-1]))
	if line.is_empty():
		quit(1)
		return
	var spots: Array = line["spots"]
	var ahead: Vector3 = spots[-1]
	for i in DISTANCES.size():
		var bot = bots[i]
		bot.controller.teleport(spots[i] + Vector3.UP * 0.05, _yaw_to(spots[i], from), 0.0)
	_put(from, ahead + Vector3.UP * 1.2, -2.0)
	await _wait(1.5)
	var camera := root.get_viewport().get_camera_3d()
	# [lift range, bone LOD range, name]: the bone LOD pass beside the full pose at the same lift.
	for pass_row: Array in [[22.0, 0.0, "lift22"], [0.0, 0.0, "lift0"], [22.0, 22.0, "bonelod22"]]:
		var pass_lift: float = pass_row[0]
		ArenaPlayer.figure_lift_range = pass_lift
		(DotHumanoidFigure as Script).set(&"lift_range", pass_lift)
		ArenaPlayer.figure_bone_lod_range = pass_row[1]
		(DotHumanoidFigure as Script).set(&"bone_lod_range", pass_row[1])
		await _wait(0.8)
		var name: String = pass_row[2]
		await _shot(name)
		var image := root.get_viewport().get_texture().get_image()
		for i in DISTANCES.size():
			var bot = bots[i]
			var chest: Vector3 = bot.global_position + Vector3.UP * 1.1
			var seen: bool = camera != null and camera.is_position_in_frustum(chest)
			_check(seen, "%s: the %d m bot is in view" % [name, int(DISTANCES[i])])
			var body_drawn: bool = bot.figure != null and bot.figure.is_visible_in_tree()
			_check(body_drawn, "%s: the %d m bot's figure is drawn" % [name, int(DISTANCES[i])])
			if seen:
				_crop(image, camera.unproject_position(chest), "%s_%dm" % [name, int(DISTANCES[i])])
	print("render_far_figures: %d failed" % _failed)
	quit(1 if _failed > 0 else 0)


## The first yaw from [param from] whose floor carries on unbroken, a whole body (shin, chest, head) in sight of the eye, out to every distance; {} if none.
func _clear_line(from: Vector3) -> Dictionary:
	var space := root.get_world_3d().direct_space_state
	var eye := from + Vector3.UP * 1.6
	for step in 48:
		var yaw := deg_to_rad(step * 7.5)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var spots: Array = []
		for d: float in DISTANCES:
			var probe := from + dir * d
			var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(probe + Vector3.UP * 2.5, probe + Vector3.DOWN * 3.0))
			if down.is_empty():
				break
			var floor_at: Vector3 = down["position"]
			if absf(floor_at.y - from.y) > 3.0:
				break
			var clear := true
			for h: float in [0.3, 1.0, 1.7]:
				if not space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, floor_at + Vector3.UP * h)).is_empty():
					clear = false
			if not clear:
				break
			spots.append(floor_at)
		if spots.size() == DISTANCES.size():
			return {"spots": spots}
	return {}


func _crop(image: Image, at: Vector2, file: String) -> void:
	var rect := Rect2i(Vector2i(at) - Vector2i(CROP / 2, CROP / 2), Vector2i(CROP, CROP)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var part := image.get_region(rect)
	part.resize(rect.size.x * 4, rect.size.y * 4, Image.INTERPOLATE_NEAREST)
	var path := ProjectSettings.globalize_path("%s/%s.png" % [_out_dir, file])
	var _s := part.save_png(path)
	print("  wrote %s" % path)
