extends Node

const FcPresentation := preload("../game/fc_presentation.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcPlayerTunables := preload("../game/fc_player_tunables.gd")
const FcBotThreads := preload("../game/fc_bot_threads.gd")

## Offline bots' drawn-body sink into the floor in metres: lowest sole and root vs a floor ray.
## `hv . scene res://tools/floor_probe.tscn -- [--bots 12] [--seconds 20] [--unit 0.025] [--pre-draw] [--worst 25, 0 = all] [--web] [--fps N]`
## Runs after every `_process`; `--pre-draw` samples at `frame_pre_draw`. Rows: stand, crouch, root, figure, body.

var _bots := 12
var _worst_rows := 25  ## worst samples printed per list; 0 = all
var _seconds := 20.0
var _unit := 0.0
var _pre_draw := false
var _web := false  ## the browser's drawing settings (LOD every 8, clip gate every 2, held range 30 m, 4 bot threads)
var _client: Node = null
var _clear := {}
var _worst: PackedStringArray = []
var _root_worst: PackedStringArray = []
var _floor_normal := Vector3.UP


func _ready() -> void:
	preload("../game/fc_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--unit": _unit = float(args[i + 1])
			"--worst": _worst_rows = int(args[i + 1])
			"--fps": Engine.max_fps = int(args[i + 1])
	_pre_draw = args.has("--pre-draw")
	_web = args.has("--web")
	if _web:
		FcPlayer.lod_off_every = FcPlayer.WEB_LOD_OFF_EVERY
		FcPlayer.anim_gate_every = FcPlayer.WEB_ANIM_GATE_EVERY
		FcPlayer.held_draw_range = FcPlayer.WEB_HELD_DRAW_RANGE
		FcPlayer.held_shadows = false
		FcBotThreads.threads = FcBotThreads.WEB_THREADS
	var _scratch := FcPresentation.use_scratch_settings("floor_probe")
	if _unit > 0.0:
		get_tree().node_added.connect(_override_unit)
	_run.call_deferred()


## The A/B: the same body at another map unit (0.025 is the 1.8 m body before the classic one).
func _override_unit(node: Node) -> void:
	var config = node.get("config")
	if config is Object and "avatar_unit_metres" in config:
		config.avatar_unit_metres = _unit


class Late extends Node:
	signal tick
	func _process(_d: float) -> void:
		tick.emit()


var _late: Late


func _run() -> void:
	_late = Late.new()
	_late.process_priority = 1 << 30
	add_child(_late)
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	await _frames_for(30.0)
	var rows := {"stand": PackedFloat64Array(), "crouch": PackedFloat64Array(), "root": PackedFloat64Array(), "figure": PackedFloat64Array(), "body": PackedFloat64Array()}
	var t0 := Time.get_ticks_usec()
	var heights := {}
	while (Time.get_ticks_usec() - t0) / 1.0e6 < _seconds:
		if _pre_draw:
			await RenderingServer.frame_pre_draw
		else:
			await _late.tick
		for p: FcPlayer in _client.game.players():
			if p.camera != null or p.figure == null or p.body_mesh == null or not p.body_mesh.visible or not p.is_alive():
				continue
			var state: DotFpsState = p.controller.state
			if not state.is_grounded():
				continue
			var floor_y := _floor_under(p)
			if is_nan(floor_y):
				continue
			heights["%.3f" % p.figure.height] = true
			var root_gap := p.body_mesh.global_position.y - floor_y
			rows.root.append(root_gap)
			var fig_gap := p.figure.global_position.y - floor_y
			rows.figure.append(fig_gap)
			rows.body.append(fig_gap + float(p.figure.get("floor_lift") if p.figure.get("floor_lift") != null else 0.0))
			if root_gap < -0.05 and (_worst_rows == 0 or _root_worst.size() < _worst_rows):
				_root_worst.append(_root_row(p, root_gap, fig_gap, floor_y))
			var sole := _sole_y(p.figure)
			if not is_nan(sole):
				(rows.crouch if state.is_crouched() else rows.stand).append(sole - floor_y)
				if sole - floor_y < -0.06 and (_worst_rows == 0 or _worst.size() < _worst_rows):
					_worst.append("gap %.3f clip %s speed %.2f crouch %.2f step %d normal_y %.2f" % [sole - floor_y, p.figure.clip, state.horizontal_speed(), state.crouch_fraction, p.figure.anim_step, _floor_normal.y])
	print("FLOOR_PROBE figure heights %s stand_height %.3f" % [str(heights.keys()), FcPlayerTunables.stand_height_m()])
	for w: String in _worst:
		print("FLOOR_PROBE worst ", w)
	for w: String in _root_worst:
		print("FLOOR_PROBE rootworst ", w)
	for key: String in rows:
		print("FLOOR_PROBE %s" % _line(key, rows[key]))
	get_tree().quit(0)


func _root_row(p: FcPlayer, root_gap: float, fig_gap: float, floor_y: float) -> String:
	var f = p.figure
	var state: DotFpsState = p.controller.state
	var lift_now: float = f.legs.floor_lift(f, f.floor_mask, 0.45)
	var lift_game: float = f.legs.floor_lift(f, p.controller.tunables.collision_mask, 0.45)
	var parts := PackedStringArray([
		"root %.3f fig %.3f" % [root_gap, fig_gap],
		"state_y-floor %.3f prev_y-floor %.3f" % [state.position.y - floor_y, p.controller.previous_position().y - floor_y],
		"normal_y %.2f speed %.2f clip %s" % [_floor_normal.y, state.horizontal_speed(), f.clip],
		"lift now %.3f game_mask %.3f stored %.3f" % [lift_now, lift_game, f.floor_lift],
		"state %s masks fig %d game %d" % [f.state, f.floor_mask, p.controller.tunables.collision_mask],
		"processing %s seated %s driving %s" % [f.is_processing(), f.seated, f.driving],
	])
	return " | ".join(parts)


func _line(key: String, v: PackedFloat64Array) -> String:
	if v.is_empty():
		return "%-6s n 0" % key
	var s := v.duplicate()
	s.sort()
	var sum := 0.0
	var sunk := 0
	var deep := 0
	for x in s:
		sum += x
		if x < -0.03:
			sunk += 1
		if x < -0.04:
			deep += 1
	return "%-6s n %d min %.3f p05 %.3f p50 %.3f mean %.3f max %.3f below_3cm %.1f%% n_below_4cm %d" % [key, s.size(), s[0], s[s.size() / 20], s[s.size() / 2], sum / s.size(), s[s.size() - 1], 100.0 * sunk / s.size(), deep]


func _floor_under(p: FcPlayer) -> float:
	var at := p.body_mesh.global_position
	var q := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.6, at + Vector3.DOWN * 2.0, p.controller.tunables.collision_mask)
	q.collide_with_areas = false
	var hit := p.body_mesh.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return NAN
	_floor_normal = hit.normal
	return float((hit.position as Vector3).y)


## The lowest sole in world y: each ankle (found as [DotClipMetrics] finds it, IK feet through their
## leg) less its rest height over the mesh bottom, so a sole on the floor reads 0.
func _sole_y(figure: DotHumanoidFigure) -> float:
	var skel := figure.skeleton()
	var mesh := figure.mesh()
	if skel == null or mesh == null or mesh.mesh == null:
		return NAN
	var key := figure.get_instance_id()
	if not _clear.has(key):
		var to_fig := figure.global_transform.affine_inverse()
		var bottom := (to_fig * mesh.global_transform * mesh.mesh.get_aabb()).position.y
		var feet: Array = []
		for i in skel.get_bone_count():
			var bone := skel.get_bone_name(i).to_lower()
			if bone.contains("foot") and not bone.contains("toe"):
				var rest := skel.get_bone_global_rest(i).origin
				feet.append([i, DotClipMetrics._leg_anchor(skel, i), (to_fig * skel.global_transform * rest).y - bottom])
		_clear[key] = feet
		print("FLOOR_PROBE figure %s look %s mesh %s bottom %.3f height %.3f" % [figure.get_path(), String(figure.look.body) if figure.look else "-", mesh.mesh.resource_path, bottom, figure.height])
		if _clear.size() == 1:
			print("FLOOR_PROBE ankles %s" % str(feet.map(func(f: Array) -> String: return "%s ik=%s clear %.3f" % [skel.get_bone_name(f[0]), f[1] != null, f[2]])))
	var low := INF
	for f: Array in _clear[key]:
		var at := skel.get_bone_global_pose(f[0]).origin
		if f[1] != null:
			at = skel.get_bone_global_pose(f[1][0]) * (f[1][1] as Vector3)
		low = minf(low, (skel.global_transform * at).y - float(f[2]))
	return low if low < INF else NAN


func _frames_for(seconds: float) -> void:
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) / 1.0e6 < seconds:
		await get_tree().process_frame
