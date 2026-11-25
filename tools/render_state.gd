extends RefCounted
## What the renderer is told, as one line each: the display and rendering device, the viewport's anti-aliasing and scale, the project's shadow
## settings, every environment's screen effects, and a census of the lights by type with how many cast shadows.
## `--ablate rstate` in tools/perf_bench.gd prints it, so a bench on one box can be diffed against another's (the owner's Windows 3090 Ti run
## shows 4166 objects where the staging02 bench shows 719; the profile header carries none of this).


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
	for we in root.find_children("*", "WorldEnvironment", true, false):
		out.append(_env("world", (we as WorldEnvironment).environment))
	for cam in root.find_children("*", "Camera3D", true, false):
		if (cam as Camera3D).environment != null:
			out.append(_env("cam " + String(cam.name), (cam as Camera3D).environment))
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
	var subs := root.find_children("*", "SubViewport", true, false)
	var live := 0
	for s in subs:
		if (s as SubViewport).render_target_update_mode != SubViewport.UPDATE_DISABLED:
			live += 1
	out.append("subviewports %d (updating %d)" % [subs.size(), live])
	var meshes := 0
	var casters := 0
	var multis := 0
	for m in root.find_children("*", "GeometryInstance3D", true, false):
		var g := m as GeometryInstance3D
		if not g.is_visible_in_tree():
			continue
		meshes += 1
		casters += 1 if g.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF else 0
		multis += 1 if g is MultiMeshInstance3D else 0
	out.append("geometry visible=%d casters=%d multimesh=%d" % [meshes, casters, multis])
	return out


static func _env(label: String, e: Environment) -> String:
	if e == null:
		return "env %s none" % label
	return "env %s ssao=%s ssil=%s sdfgi=%s glow=%s fog=%s vfog=%s adjust=%s tonemap=%d" % [
		label, e.ssao_enabled, e.ssil_enabled, e.sdfgi_enabled, e.glow_enabled, e.fog_enabled, e.volumetric_fog_enabled,
		e.adjustment_enabled, e.tonemap_mode]
