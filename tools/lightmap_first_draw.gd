extends Node

const FcMap := preload("../maps/fc_map.gd")
const FcMapLighting := preload("../maps/fc_map_lighting.gd")
const FcPresentation := preload("../game/fc_presentation.gd")

## What a LightmapGI's first drawn frame costs, by what its data holds and what was drawn before it. One variant per process
## (the first use is the cost), on a GPU box only: `GPU_BOX=staging GPU_XORG=1 gs-bootstrap/tools/gpu.sh run <worktree>
## res://tools/lightmap_first_draw.tscn -- --variant <v> [--map dm_box]`. Bake alone: full, none, tinytex, noprobes, proxy.
## Real level: level, level_nobake, level_lightfirst, level_nolight, level_hidden, level_proxy, level_proxy2, level_arm
## (a lightmapped box in a SubViewport first), level_arm_main, level_arm_world (arm, then the world shader warm-ups).

var _variant := "full"
var _map := "dm_box"
var _versions := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--variant":
			_variant = args[i + 1]
		elif args[i] == "--map":
			_map = args[i + 1]
		elif args[i] == "--versions":
			_versions = int(args[i + 1])
	Engine.max_fps = 0
	if _variant.begins_with("level"):
		var _scratch := FcPresentation.use_scratch_settings("lightmap_first_draw")
		_run_level.call_deferred()
	else:
		_run.call_deferred()


func _frames(n: int, label: String) -> void:
	var vp := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	var p0 := _pipes()
	var worst := 0
	var worst_cpu := 0.0
	var worst_gpu := 0.0
	var times: Array = []
	for i in range(n):
		var t := Time.get_ticks_usec()
		await get_tree().process_frame
		var d := Time.get_ticks_usec() - t
		times.append(d / 1000)
		if d > worst:
			worst = d
			worst_cpu = RenderingServer.viewport_get_measured_render_time_cpu(vp)
			worst_gpu = RenderingServer.viewport_get_measured_render_time_gpu(vp)
	print("lmfd %s %s: worst %d ms (render cpu %.1f gpu %.1f) frames %s pipelines +%s" % [
		_variant, label, worst / 1000, worst_cpu, worst_gpu, str(times.slice(0, 8)), str(_pipes() - p0)])


func _pipes() -> int:
	return RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE) \
		+ RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION) \
		+ RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW)


## `--versions N`: N shader versions (one ShaderMaterial each, distinct code) drawn before the arm or level, to see whether
## the first lightmapped frame scales with how many 3D shaders exist (ShaderRD::enable_group loads the group for each).
func _add_versions(at: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(0.05, 0.05, 0.05)
	for i in range(_versions):
		var mat := ShaderMaterial.new()
		mat.shader = Shader.new()
		mat.shader.code = "shader_type spatial;\nvoid fragment() { ALBEDO = vec3(%f, 0.5, 0.5); }\n" % (float(i) / 100000.0)
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.material_override = mat
		mi.position = at + Vector3(0.06 * float(i % 20) - 0.6, 0.0, 0.06 * float(i / 20) - 0.6)
		add_child(mi)
	await _frames(20, "versions %d" % _versions)


func _tiny_texture() -> Texture2DArray:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBAH)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	var arr := Texture2DArray.new()
	var _e := arr.create_from_images([img])
	return arr


func _run() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 2, 6)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.material_override = StandardMaterial3D.new()
	add_child(box)
	var sun := DirectionalLight3D.new()
	add_child(sun)
	await _frames(30, "plain")
	var path := "res://lightmaps/%s.res" % _map
	var t := Time.get_ticks_usec()
	var data := load(path) as LightmapGIData
	print("lmfd %s load %d ms" % [_variant, (Time.get_ticks_usec() - t) / 1000])
	for tex: TextureLayered in data.lightmap_textures:
		print("lmfd tex %s %dx%d layers %d format %d mipmaps %s" % [tex.get_class(), tex.get_width(), tex.get_height(), tex.get_layers(), tex.get_format(), tex.has_mipmaps()])
	print("lmfd shadowmask %d, sh %s, probes %d" % [data.shadowmask_textures.size(), data.is_using_spherical_harmonics(), (data.get("probe_data") as Dictionary).get("points", PackedVector3Array()).size()])
	if _variant == "none":
		await _frames(30, "after")
		get_tree().quit(0)
		return
	if _variant == "tinytex" or _variant == "proxy":
		var tiny := data.duplicate() as LightmapGIData
		tiny.lightmap_textures = [_tiny_texture()]
		tiny.shadowmask_textures = []
		if _variant == "tinytex":
			data = tiny
		else:
			var proxy := LightmapGI.new()
			proxy.light_data = tiny
			add_child(proxy)
			await _frames(30, "proxy")
			proxy.free()
			await _frames(5, "proxy gone")
	if _variant == "noprobes":
		data = data.duplicate() as LightmapGIData
		data.set("probe_data", {})
	var gi := LightmapGI.new()
	gi.light_data = data
	add_child(gi)
	await _frames(30, "after")
	get_tree().quit(0)


## The real level: variants level (lighting and level together, as first boot), level_nobake, level_lightfirst (lighting drawn
## first), level_nolight (no sun or environment), level_hidden (every level mesh hidden), level_proxy (a tiny bake drawn first).
func _run_level() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	var map: Object = FcMap.by_id(StringName(_map))
	var extent: float = maxf(float(map.get("extent")), 8.0)
	cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(0.0, extent * 2.0, 0.0))
	cam.far = extent * 6.0
	cam.make_current()
	await _frames(20, "empty")
	if _versions > 0:
		await _add_versions(cam.global_position + Vector3(0.0, -4.0, 0.0))
	await _arm(extent)
	if _variant == "level_nobake":
		FcMap.use_bakes = false
	var level: Node3D = map.call("to_scene")
	var gi := level.get_node_or_null("LightmapGI") as LightmapGI
	print("lmfd %s bake %s" % [_variant, gi != null])
	if gi != null and gi.light_data != null:
		var tex: TextureLayered = gi.light_data.lightmap_textures[0]
		print("lmfd tex %dx%d layers %d format %d users %d" % [tex.get_width(), tex.get_height(), tex.get_layers(), tex.get_format(), gi.light_data.get_user_count()])
	await _proxies(level, gi, extent)
	var lighting: Node3D = null
	if _variant != "level_nolight":
		lighting = FcMapLighting.build(map)
		add_child(lighting)
		if _variant == "level_lightfirst":
			await _frames(20, "lit")
	if _variant == "level_hidden":
		for m: Node in level.find_children("*", "MeshInstance3D", true, false):
			(m as MeshInstance3D).visible = false
	add_child(level)
	await _frames(30, "level")
	get_tree().quit(0)


## The arm variants: a lightmapped box drawn before the level (level_arm in a SubViewport, level_arm_main in the main
## viewport), and level_arm_world: the world shader warm-ups, then a second box.
func _arm(extent: float) -> void:
	if _variant.begins_with("level_arm"):
		var host: Node = self
		if _variant == "level_arm":
			var view := SubViewport.new()
			view.size = Vector2i(4, 4)
			view.own_world_3d = true
			view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			view.add_child(Camera3D.new())
			add_child(view)
			host = view
		var box := BoxMesh.new()
		box.add_uv2 = true
		var arm := Node3D.new()
		var mi := MeshInstance3D.new()
		mi.name = "Box"
		mi.mesh = box
		mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		arm.add_child(mi)
		var data := LightmapGIData.new()
		data.lightmap_textures = [_tiny_texture()]
		data.add_user(NodePath("../Box"), Rect2(0, 0, 1, 1), 0, -1)
		var gi0 := LightmapGI.new()
		gi0.light_data = data
		arm.add_child(gi0)
		arm.position = Vector3(0.0, extent * 2.0 - 3.0, 0.0) if host == self else Vector3(0.0, 0.0, -3.0)
		host.add_child(arm)
		await _frames(10, "arm")
		(arm if host == self else host).free()
	if _variant == "level_arm_world":
		await GSMapSurfaces.warm_shaders_async(get_tree())
		await GSMapBspMesh.warm_prop_shaders_async(get_tree())
		await _frames(10, "world warmed")
		var probe := MeshInstance3D.new()
		var b2 := BoxMesh.new()
		b2.add_uv2 = true
		probe.name = "Box"
		probe.mesh = b2
		probe.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		var d2 := LightmapGIData.new()
		d2.lightmap_textures = [_tiny_texture()]
		d2.add_user(NodePath("../Box"), Rect2(0, 0, 1, 1), 0, -1)
		var g2 := LightmapGI.new()
		g2.light_data = d2
		var a2 := Node3D.new()
		a2.add_child(probe)
		a2.add_child(g2)
		a2.position = Vector3(0.0, extent * 2.0 - 3.0, 0.0)
		add_child(a2)
		await _frames(10, "arm again")
		a2.free()


## level_proxy (a tiny bake of the level's own users) and level_proxy2 (one lightmapped box per level material), drawn first.
func _proxies(level: Node3D, gi: LightmapGI, extent: float) -> void:
	if _variant == "level_proxy" and gi != null:
		var tiny := gi.light_data.duplicate() as LightmapGIData
		tiny.lightmap_textures = [_tiny_texture()]
		var proxy := LightmapGI.new()
		proxy.light_data = tiny
		add_child(proxy)
		await _frames(20, "proxy")
		proxy.free()
		await _frames(5, "proxy gone")
	if _variant == "level_proxy2" and gi != null:
		var mats := {}
		for m: Node in level.find_children("*", "MeshInstance3D", true, false):
			var mo := (m as MeshInstance3D).material_override
			if mo != null:
				mats[mo] = true
		var tiny := LightmapGIData.new()
		tiny.lightmap_textures = [_tiny_texture()]
		var proxy := LightmapGI.new()
		proxy.light_data = tiny
		var box := FcMap.lightmap_box(Vector3(0.2, 0.2, 0.2), false)
		var i := 0
		for mat: Material in mats:
			var mi := MeshInstance3D.new()
			mi.name = "P%d" % i
			mi.mesh = box
			mi.material_override = mat
			mi.gi_mode = GeometryInstance3D.GI_MODE_STATIC
			mi.position = Vector3(0.3 * i - 1.0, extent * 2.0 - 3.0, 0.0)
			proxy.add_child(mi)
			tiny.add_user(NodePath(mi.name), Rect2(0, 0, 1, 1), 0, -1)
			i += 1
		print("lmfd proxy materials %d" % i)
		add_child(proxy)
		await _frames(20, "proxy")
		proxy.free()
		await _frames(5, "proxy gone")
