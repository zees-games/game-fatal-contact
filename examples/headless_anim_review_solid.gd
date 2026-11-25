extends GSGameCheckSuite

## anim_review's "forearm inside weapon" depth (tools/anim_review_solid.gd): a point counts only where the mesh closes round it, not
## where the part's box does, so a one-mesh grip (the smg's mac10) no longer reads as solid air (nightly game-arena-visual-qa-rest-1).
## gs-rename: keep (nightly item key)

const Solid := preload("../tools/anim_review_solid.gd")
const SMG := "res://addons/fc_weapons/assets/models/smg.glb"
## Wrist points the box check put 0.034-0.046 m inside the mac10 (smg avatar_run #100).
const SMG_WRIST: Array[Vector3] = [Vector3(-0.029268, -0.036866, -0.0041), Vector3(-0.023916, -0.028877, 0.00047), Vector3(-0.023172, -0.038684, 0.000372)]
const SMG_SCALE := Vector3(1.64345, 3.421247, 3.346062)


func _ready() -> void:
	_run.call_deferred()


## Two boxes in one mesh: a 0.4 x 0.1 x 0.1 receiver on top and a 0.1 x 0.2 x 0.1 grip under its front end, so the box
## of the whole is 0.4 x 0.3 x 0.1 with an empty notch behind the grip.
func _l_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for box: AABB in [AABB(Vector3(0.0, 0.2, 0.0), Vector3(0.4, 0.1, 0.1)), AABB(Vector3(0.3, 0.0, 0.0), Vector3(0.1, 0.2, 0.1))]:
		var faces := BoxMesh.new()
		faces.size = box.size
		for v in faces.get_faces():
			st.add_vertex(v + box.get_center())
	return st.commit()


func _run() -> void:
	var l := _l_mesh()
	_check(l.get_aabb().has_point(Vector3(0.1, 0.1, 0.05)), "the notch behind the grip is inside the L's box")
	_check(Solid.depth(l, Vector3(0.1, 0.1, 0.05), Vector3.ONE) == 0.0, "a point in the notch is not inside the mesh",
		"%.3f" % Solid.depth(l, Vector3(0.1, 0.1, 0.05), Vector3.ONE))
	var in_receiver := Solid.depth(l, Vector3(0.1, 0.25, 0.05), Vector3.ONE)
	_check(absf(in_receiver - 0.05) < 0.001, "a point in the middle of the receiver is 0.05 m deep (half its height)", "%.4f" % in_receiver)
	var in_grip := Solid.depth(l, Vector3(0.35, 0.1, 0.03), Vector3.ONE)
	_check(absf(in_grip - 0.03) < 0.001, "a point in the grip is as deep as its nearest face (0.03 m)", "%.4f" % in_grip)
	var scaled := Solid.depth(l, Vector3(0.1, 0.25, 0.05), Vector3(2.0, 3.0, 0.5))
	_check(absf(scaled - 0.025) < 0.001, "the depth is in metres: the part's scale per axis (z scaled 0.5 makes 0.025)", "%.4f" % scaled)
	_check(Solid.depth(l, Vector3(0.5, 0.1, 0.05), Vector3.ONE) == 0.0, "a point outside the box is 0")

	var scene := (load(SMG) as PackedScene).instantiate() if ResourceLoader.exists(SMG) else null
	var mac10: MeshInstance3D = null
	if scene != null:
		for m in scene.find_children("*", "MeshInstance3D", true, false):
			if m.name == &"mac10":
				mac10 = m
	if _check(mac10 != null and mac10.mesh != null, "the smg model has its one-mesh mac10 body"):
		for p in SMG_WRIST:
			var deep := Solid.depth(mac10.mesh, p, SMG_SCALE)
			_check(mac10.mesh.get_aabb().has_point(p), "the wrist point %s is inside the mac10's box" % str(p))
			_check(deep < 0.03, "the wrist that holds the smg's grip is not inside the mac10 (limit 0.03 m)", "%.3f m" % deep)
	if scene != null:
		scene.free()
	_report(13)
