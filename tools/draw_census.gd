extends Node
## `--census-every S` in tools/perf_bench.gd: every S seconds of the recorded window, one `census` line with the frame's draw calls,
## objects and primitives and the video memory, then the geometry groups (tools/render_state.gd's names) with their visible nodes,
## surfaces, caster surfaces and thousands of triangles. A run that spikes (one in five gate runs draws 1000 calls instead of 630) is
## caught as it happens, and two runs' lines diff group by group.

const RenderState := preload("render_state.gd")

var every := 1.0
var top := 12
var say: Callable
var _left := 0.0
## Triangles by mesh instance id: a mesh's arrays are read once.
var _tris := {}


func _process(delta: float) -> void:
	_left -= delta
	if _left > 0.0:
		return
	_left = every
	var groups := {}
	for m in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		var g := m as GeometryInstance3D
		if not g.is_visible_in_tree():
			continue
		var surfs := 1
		var tris := 0
		if g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			var mesh := (g as MeshInstance3D).mesh
			surfs = maxi(1, mesh.get_surface_count())
			tris = _mesh_tris(mesh)
		elif g is MultiMeshInstance3D and (g as MultiMeshInstance3D).multimesh != null:
			var mm := (g as MultiMeshInstance3D).multimesh
			if mm.mesh != null:
				var count := mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
				tris = _mesh_tris(mm.mesh) * count
		var cast := g.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var k := RenderState.group_of(g)
		var row: Array = groups.get(k, [0, 0, 0, 0])
		row[0] += 1
		row[1] += surfs
		row[2] += surfs if cast else 0
		row[3] += tris
		groups[k] = row
	var ranked := groups.keys()
	ranked.sort_custom(func(x: String, y: String) -> bool: return groups[x][3] > groups[y][3])
	var parts := PackedStringArray()
	for k: String in ranked.slice(0, top):
		var r: Array = groups[k]
		parts.append("%s n%d s%d c%d k%d" % [k, r[0], r[1], r[2], r[3] / 1000])
	say.call("census draws %d objects %d prims %d video_mb %.0f nodes %d | %s | vps %s" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME), Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT), " ; ".join(parts), _viewports()])


## Each 3D viewport that rendered this frame, its visible and shadow passes as draws/thousand primitives: the window, then
## every SubViewport not disabled (a second pass sharing the world renders the sun's shadow casters again).
func _viewports() -> String:
	var out := PackedStringArray([_pass("root", get_tree().root)])
	for v in get_tree().root.find_children("*", "SubViewport", true, false):
		var sv := v as SubViewport
		if sv.disable_3d or sv.render_target_update_mode == SubViewport.UPDATE_DISABLED:
			continue
		var row := _pass("%s/%s" % [sv.get_parent().name, sv.name], sv)
		if not row.ends_with("v0/0 s0/0"):
			out.append(row)
	return " ; ".join(out)


func _pass(label: String, vp: Viewport) -> String:
	var rid := vp.get_viewport_rid()
	var v := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE
	var s := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW
	var draws := RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
	var prims := RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
	return "%s v%d/%d s%d/%d" % [label, RenderingServer.viewport_get_render_info(rid, v, draws), RenderingServer.viewport_get_render_info(rid, v, prims) / 1000,
		RenderingServer.viewport_get_render_info(rid, s, draws), RenderingServer.viewport_get_render_info(rid, s, prims) / 1000]


func _mesh_tris(mesh: Mesh) -> int:
	var id := mesh.get_instance_id()
	if _tris.has(id):
		return _tris[id]
	var n := 0
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh:
			var am := mesh as ArrayMesh
			var idx := am.surface_get_array_index_len(s)
			n += (idx if idx > 0 else am.surface_get_array_len(s)) / 3
		else:
			var arrays := mesh.surface_get_arrays(s)
			var ia: Variant = arrays[Mesh.ARRAY_INDEX]
			n += ((ia as PackedInt32Array).size() if ia != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	_tris[id] = n
	return n
