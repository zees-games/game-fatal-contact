extends RefCounted
## What the renderer is told, as one line each: the display and rendering device, the viewport's anti-aliasing and scale, the project's shadow
## settings, every environment's screen effects, and a census of the lights by type with how many cast shadows.
## `--ablate rstate` in tools/perf_bench.gd prints it, so a bench on one box can be diffed against another's (the owner's Windows 3090 Ti run
## shows 4166 objects where the staging02 bench shows 719; the profile header carries none of this).

## The digits, @ and _ _group strips from node names, compiled once.
static var _digits: RegEx


static func lines(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var vp := root.get_viewport()
	out.append("renderer setting=%s method=%s adapter=%s vendor=%s driver=%s" % [
		ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"), RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor(), RenderingServer.get_current_rendering_driver_name()])
	out.append("display %s window=%s mode=%d dpi=%d scale=%.2f vsync=%d visible=%s content_scale=%s/%s" % [
		DisplayServer.get_name(), DisplayServer.window_get_size(), DisplayServer.window_get_mode(), DisplayServer.screen_get_dpi(),
		DisplayServer.screen_get_scale(), DisplayServer.window_get_vsync_mode(), vp.get_visible_rect().size,
		root.content_scale_mode, root.content_scale_factor])
	out.append("viewport msaa3d=%d msaa2d=%d ss_aa=%d taa=%s scaling=%d@%.2f lod_threshold=%.2f occlusion=%s" % [
		vp.msaa_3d, vp.msaa_2d, vp.screen_space_aa, vp.use_taa, vp.scaling_3d_mode, vp.scaling_3d_scale, vp.mesh_lod_threshold,
		vp.use_occlusion_culling])
	var keys := ["rendering/lights_and_shadows/directional_shadow/size", "rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality",
		"rendering/lights_and_shadows/positional_shadow/atlas_size", "rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality",
		"rendering/occlusion_culling/use_occlusion_culling", "rendering/anti_aliasing/quality/msaa_3d",
		"rendering/anti_aliasing/quality/screen_space_aa", "rendering/scaling_3d/scale",
		"rendering/mesh_lod/lod_change/threshold_pixels", "display/window/size/mode", "display/window/dpi/allow_hidpi"]
	var parts := PackedStringArray()
	for k: String in keys:
		parts.append("%s=%s" % [k.get_file(), ProjectSettings.get_setting(k, "-")])
	out.append("project " + " ".join(parts))
	out.append_array(_envs(root))
	out.append_array(_lights(root))
	out.append_array(_subviewports(root))
	out.append(_fxpools(root))
	out.append_array(_geometry(root))
	return out


static func _envs(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var envs := {}
	for we in root.find_children("*", "WorldEnvironment", true, false):
		var wl := _env("world", (we as WorldEnvironment).environment)
		envs[wl] = int(envs.get(wl, 0)) + 1
	for cam in root.find_children("*", "Camera3D", true, false):
		if (cam as Camera3D).environment != null:
			var cl := _env("cam", (cam as Camera3D).environment)
			envs[cl] = int(envs.get(cl, 0)) + 1
	for k: String in envs:
		out.append("%s x%d" % [k, envs[k]])
	return out


static func _lights(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var by := {}
	for l in root.find_children("*", "Light3D", true, false):
		var li := l as Light3D
		if not li.is_visible_in_tree():
			continue
		var kind := "dir" if li is DirectionalLight3D else "omni" if li is OmniLight3D else "spot"
		var row: Array = by.get(kind, [0, 0])
		row[0] += 1
		row[1] += 1 if li.shadow_enabled else 0
		by[kind] = row
		if li is DirectionalLight3D:
			var d := li as DirectionalLight3D
			out.append("sun mode=%d max_distance=%.0f shadow=%s" % [d.directional_shadow_mode, d.directional_shadow_max_distance, d.shadow_enabled])
	out.append("lights (visible, shadowed) %s" % by)
	return out


static func _subviewports(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var modes := {}
	for sv in root.find_children("*", "SubViewport", true, false):
		var port := sv as SubViewport
		var mk := "%s mode=%d visible_in_tree=%s size=%s" % [_group(sv), port.render_target_update_mode, _shown(port), port.size]
		modes[mk] = int(modes.get(mk, 0)) + 1
		# The port's last render (main pass + shadow passes): the engine keeps it until the port draws again, so a
		# DISABLED port shows what it drew last, not this frame. Read with mode: 0 disabled, 1 once, 2 when its texture
		# was drawn last frame, 3 when the parent drew, 4 always.
		var rid := port.get_viewport_rid()
		var vis_d := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		var sh_d := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)
		var vis_o := RenderingServer.viewport_get_render_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME)
		if vis_d + sh_d > 0:
			out.append("subviewport_last %s mode=%d draws=%d shadow_draws=%d objects=%d" % [_group(sv), port.render_target_update_mode, vis_d, sh_d, vis_o])
	for k: String in modes:
		out.append("subviewport %s x%d" % [k, modes[k]])
	# Every camera, and whether it is the one its viewport draws through (a camera that is not current renders nothing).
	var cams := {}
	for c in root.find_children("*", "Camera3D", true, false):
		var cam := c as Camera3D
		var ck := "%s current=%s in_port=%s mask=%x" % [_group(cam), cam.current, cam.get_viewport() != root.get_viewport(), cam.cull_mask]
		cams[ck] = int(cams.get(ck, 0)) + 1
	for k: String in cams:
		out.append("camera %s x%d" % [k, cams[k]])
	return out


static func _geometry(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	var groups := {}
	var meshes := 0
	var casters := 0
	var multis := 0
	for m in root.find_children("*", "GeometryInstance3D", true, false):
		var g := m as GeometryInstance3D
		if not g.is_visible_in_tree():
			continue
		var cast := g.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var surfs := 1
		if g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			surfs = maxi(1, (g as MeshInstance3D).mesh.get_surface_count())
		meshes += 1
		casters += 1 if cast else 0
		multis += 1 if g is MultiMeshInstance3D else 0
		var gk := _group(g)
		var row: Array = groups.get(gk, [0, 0, 0])
		row[0] += 1
		row[1] += surfs
		row[2] += surfs if cast else 0
		groups[gk] = row
	out.append("geometry visible=%d casters=%d multimesh=%d" % [meshes, casters, multis])
	# Draw attribution: a surface is one main-pass draw and, when it casts, one more per shadow view it lands in.
	var ranked := groups.keys()
	ranked.sort_custom(func(x: String, y: String) -> bool: return groups[x][1] > groups[y][1])
	for k: String in ranked.slice(0, 24):
		out.append("draws group %s nodes=%d surfaces=%d caster_surfaces=%d" % [k, groups[k][0], groups[k][1], groups[k][2]])
	return out


## Effect quad pools: an idle quad should be hidden and none should cast a shadow.
static func _fxpools(root: Node) -> String:
	var pools := 0
	var pooled := [0, 0, 0, 0, 0]
	for pool in root.find_children("*", "GSFxMeshPool", true, false):
		pools += 1
		var idle: Array = pool.get("_free") if pool.get("_free") != null else []
		for q in pool.get_children():
			if not (q is MeshInstance3D):
				continue
			var mi := q as MeshInstance3D
			pooled[0] += 1
			pooled[1] += 1 if idle.has(mi) else 0
			pooled[2] += 1 if idle.has(mi) and mi.visible else 0
			pooled[3] += 1 if mi.is_visible_in_tree() else 0
			pooled[4] += 1 if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else 0
	return "fxpools %d quads=%d idle=%d idle_visible=%d drawn=%d casting=%d" % [pools, pooled[0], pooled[1], pooled[2], pooled[3], pooled[4]]


static func _env(label: String, e: Environment) -> String:
	if e == null:
		return "env %s none" % label
	return "env %s ssao=%s ssil=%s sdfgi=%s glow=%s fog=%s vfog=%s adjust=%s tonemap=%d" % [
		label, e.ssao_enabled, e.ssil_enabled, e.sdfgi_enabled, e.glow_enabled, e.fog_enabled, e.volumetric_fog_enabled,
		e.adjustment_enabled, e.tonemap_mode]


## The node's place in the tree with the numbers taken out ("Level/Bot7/Figure" becomes "Level/Bot/Figure"): its first four ancestors
## under the root and its last two, so 31 bots count as one group.
static func _group(n: Node) -> String:
	var names := PackedStringArray()
	var cur := n.get_parent()
	while cur != null and cur != n.get_tree().root:
		names.append(String(cur.name))
		cur = cur.get_parent()
	names.reverse()
	if _digits == null:
		_digits = RegEx.create_from_string("[0-9@_]+")
	var re := _digits
	var out := PackedStringArray()
	for nm in names.slice(0, 4):
		out.append(re.sub(nm, "", true))
	# The owner's two levels up, so a player's figure, held gun and name tag are told apart.
	if names.size() > 4:
		out.append("..")
		for nm in names.slice(maxi(4, names.size() - 2)):
			out.append(re.sub(nm, "", true))
	return "/".join(out) + "|" + n.get_class()


## [method _group]'s name for [param n], for tools/draw_census.gd.
static func group_of(n: Node) -> String:
	return _group(n)


## Whether [param port]'s picture can be on screen: no hidden CanvasItem or CanvasLayer above it (a CanvasLayer is not a CanvasItem, and a
## hidden one hides its TextureRect, so a port under it with UPDATE_WHEN_VISIBLE does not render).
static func _shown(port: SubViewport) -> bool:
	var cur: Node = port.get_parent()
	while cur != null:
		if cur is CanvasItem and not (cur as CanvasItem).visible:
			return false
		if cur is CanvasLayer and not (cur as CanvasLayer).visible:
			return false
		cur = cur.get_parent()
	return true
