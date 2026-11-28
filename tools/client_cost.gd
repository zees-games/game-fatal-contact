extends Node

const FcFrameProbe := preload("../game/fc_frame_probe.gd")
const FcPresentation := preload("../game/fc_presentation.gd")
const FcPlayer := preload("../game/fc_player.gd")
const ClientBench := preload("client_bench.gd")
const FcKillcamBodies := preload("../game/fc_killcam_bodies.gd")

## What the CLIENT costs per remote player in one offline process: the frame, engine process time, each client section in ms per frame and per remote player, and a node census.
## `godot --headless --path . res://tools/client_cost.tscn -- --bots 16 --seconds 15 [--map atrium] [--variants default,full]`; variants `before`, `default`, `nogate` (default without the game-time animation gate), `off8`, `full`, `no_anim`/`no_held`/`no_held_proc`/`no_rest`/`bare` (`full` less that part, `FcPlayer.present_ablate`), `still` (remotes not presented).
## Headless draws nothing: this is script and scene-tree cost; render cost needs a windowed GPU profile.

var _bots := 16
var _seconds := 15.0
var _variants: PackedStringArray = ["before", "default", "full", "bare"]
var _client: Node = null
var _rounds := 3
var _map := ""


func _ready() -> void:
	preload("../game/fc_weapon_roles.gd").ensure()
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--variants": _variants = args[i + 1].split(",")
			"--phys-hz":
				# Fewer, cheaper sim ticks per frame so the frame is mostly presentation (a GPU machine's 150+ fps).
				Engine.physics_ticks_per_second = maxi(1, int(args[i + 1]))
				Engine.max_physics_steps_per_frame = 1
			"--map": _map = args[i + 1]
			"--rounds": _rounds = maxi(1, int(args[i + 1]))
	var _scratch := FcPresentation.use_scratch_settings("client_cost")
	_run.call_deferred()


func _run() -> void:
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", _bots)
	add_child(_client)
	var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	var pilot := ClientBench.Pilot.new()
	pilot.process_priority = -999
	add_child(pilot)
	FcFrameProbe.set_interval(1.0e9)
	await _frames_for(8.0)
	var remotes := 0
	for p: FcPlayer in _client.game.players():
		if p.camera == null:
			remotes += 1
	print("CLIENT_COST bots %d remotes %d" % [_bots, remotes])
	_census()
	_tree_census()
	# Interleaved rounds, so a machine that speeds up or slows down mid-run hits every variant alike.
	var acc := {}
	for round_i in _rounds:
		for v in _variants:
			_apply(v)
			await _frames_for(1.5)
			var got := await _measure(_seconds / _rounds)
			if not acc.has(v):
				acc[v] = {"proc": PackedFloat64Array(), "frame": PackedFloat64Array(), "sections": {}, "n": 0}
			var a_v: Dictionary = acc[v]
			a_v.proc.append_array(got.proc)
			a_v.frame.append_array(got.frame)
			a_v.n += got.proc.size()
			for key: StringName in got.sections:
				a_v.sections[key] = a_v.sections.get(key, 0.0) + got.sections[key]
	_apply("default")
	_report(acc, remotes)
	get_tree().quit(0)


func _apply(variant: String) -> void:
	# "before" is the game as it was: the cone, a kill-cam recording every frame. "default" is the game as it ships now.
	FcPlayer.lod_frustum = variant != "before"
	FcPlayer.lod_off_every = 8 if variant == "off8" else 4
	FcKillcamBodies.record_hz = 0.0 if variant == "before" else 60.0
	FcPlayer.anim_gate_enabled = variant not in ["nogate", "before"]
	FcPlayer.present_lod_enabled = variant in ["default", "before", "off8", "nogate"]
	FcPlayer.present_remote_paused = variant == "still"
	# "full" with one part of the remote presentation left out: the cost of that part alone.
	FcPlayer.present_ablate = {"no_anim": 1, "no_held": 2, "no_held_proc": 6, "no_rest": 8, "bare": 15}.get(variant, 0)
	if variant in ["default", "before", "off8", "full", "nogate"]:
		for p: FcPlayer in _client.game.players():
			if p.held != null:
				p.held.set_ticking(true)


func _frames_for(seconds: float) -> void:
	var t0 := Time.get_ticks_usec()
	while (Time.get_ticks_usec() - t0) / 1.0e6 < seconds:
		await get_tree().process_frame


func _measure(seconds: float) -> Dictionary:
	FcFrameProbe._reset()
	var frames := PackedFloat64Array()
	var proc := PackedFloat64Array()
	var t0 := Time.get_ticks_usec()
	var last := t0
	while (last - t0) / 1.0e6 < seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	var sections := {}
	for key: StringName in FcFrameProbe._sections:
		var row: PackedInt64Array = FcFrameProbe._sections[key]
		sections[key] = float(row[0]) / 1000.0
	return {"proc": proc, "frame": frames, "sections": sections}


static func _median(values: PackedFloat64Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2] if sorted.size() > 0 else 0.0


func _report(acc: Dictionary, remotes: int) -> void:
	var r := maxf(float(remotes), 1.0)
	var bare: float = _median(acc["bare"].proc) if acc.has("bare") else NAN
	for v: String in _variants:
		var a: Dictionary = acc[v]
		var n: int = a.n
		var mean := 0.0
		for f in a.frame:
			mean += f
		mean /= maxi(n, 1)
		var med := _median(a.proc)
		var extra := ""
		if not is_nan(bare):
			extra = " | over bare %.2f ms = %.3f ms per remote" % [med - bare, (med - bare) / r]
		print("  [%s] fps %.1f (frame mean %.2f p50 %.2f) | engine process median %.2f ms/frame%s" % [v, 1000.0 / mean, mean, _median(a.frame), med, extra])
		var keys: Array = a.sections.keys()
		keys.sort()
		for key: StringName in keys:
			if String(key).begins_with("bot") or String(key).begins_with("tick") or String(key).begins_with("p_") or key in [&"physics", &"game_tick", &"bots"]:
				continue
			var per_frame: float = a.sections[key] / n
			print("      %-16s %7.3f ms/frame  %7.4f ms/remote" % [key, per_frame, per_frame / r])


## Nodes, meshes, lights, skeletons and processing nodes under one remote player (the render-side bill the headless run cannot time).
func _census() -> void:
	for p: FcPlayer in _client.game.players():
		if p.camera != null:
			continue
		var c := {"nodes": 0, "meshes": 0, "lights": 0, "skeletons": 0, "processing": 0, "particles": 0, "audio": 0, "visible_meshes": 0}
		_count(p, c)
		print("  census per remote: ", c)
		return


func _count(node: Node, c: Dictionary) -> void:
	c.nodes += 1
	if node.is_processing() or node.is_physics_processing():
		c.processing += 1
	if node is MeshInstance3D:
		c.meshes += 1
		if (node as MeshInstance3D).is_visible_in_tree():
			c.visible_meshes += 1
	elif node is Light3D:
		c.lights += 1
	elif node is Skeleton3D:
		c.skeletons += 1
	elif node is GPUParticles3D:
		c.particles += 1
	elif node is AudioStreamPlayer3D:
		c.audio += 1
	for ch in node.get_children():
		_count(ch, c)


## Whole-tree breakdown: nodes per class, and per script/class the nodes that process (process or physics_process on) split into visible-in-tree and hidden-or-offscreen-owner.
## Lines: `CENSUS_CLASS name count`, `CENSUS_PROC key processing hidden_processing total_with_script` (key = script file or class), `CENSUS_TOTAL nodes processing hidden_processing`.
func _tree_census() -> void:
	var classes := {}
	var procs := {}
	var tot := [0, 0, 0]
	_walk(get_tree().root, true, classes, procs, tot)
	var names := classes.keys()
	names.sort_custom(func(a, b): return classes[a] > classes[b])
	for n in names:
		print("CENSUS_CLASS %s %d" % [n, classes[n]])
	var keys := procs.keys()
	keys.sort_custom(func(a, b): return procs[a][0] > procs[b][0])
	for k in keys:
		print("CENSUS_PROC %s %d %d %d" % [k, procs[k][0], procs[k][1], procs[k][2]])
	print("CENSUS_TOTAL %d %d %d (engine node count %d, orphans %d, skeletons %d)" % [tot[0], tot[1], tot[2], Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), classes.get("Skeleton3D", 0)])


func _walk(node: Node, vis: bool, classes: Dictionary, procs: Dictionary, tot: Array) -> void:
	var v := vis
	if node is Node3D:
		v = vis and (node as Node3D).visible
	elif node is CanvasItem:
		v = vis and (node as CanvasItem).visible
	var cls := node.get_class()
	classes[cls] = classes.get(cls, 0) + 1
	tot[0] += 1
	var proc := node.is_processing() or node.is_physics_processing()
	var scr: Script = node.get_script()
	var key: String = scr.resource_path.get_file() if scr != null and scr.resource_path != "" else cls
	if proc:
		tot[1] += 1
		if not v:
			tot[2] += 1
	var e: Array = procs.get(key, [0, 0, 0])
	if proc:
		e[0] += 1
		if not v:
			e[1] += 1
	e[2] += 1
	procs[key] = e
	for ch in node.get_children(true):
		_walk(ch, v, classes, procs, tot)
