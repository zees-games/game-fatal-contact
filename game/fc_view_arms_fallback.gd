extends RefCounted

## Arms never disappear (fc_view_arms.gd). Where the arms cannot be drawn, because the body model is missing
## (dot-player-char falls back to a skinless capsule) or its meshes did not load, they are rebuilt as the stock person
## (TMC's default arms), and if that cannot be drawn either the view model's own hands come back.
## It also covers the Compatibility renderer (every browser): it has no per-instance shader uniforms, so
## DotViewArmsMaterial's `instance uniform draw_depth` does not compile and the arms drew as nothing at all while the
## view model's hands were off. There the arms' material is swapped for a copy with plain uniforms, set each frame.

## Set from a test to take the plain-material path without the Compatibility renderer.
static var force_plain_material := false
## Frames the arms may stay undrawable before the next step of the fallback.
const AFTER_FRAMES := 20
const STOCK := 1
const VIEW_MODEL := 2

var state := 0
var _frames := 0
var _key := ""
var _plain: Array[ShaderMaterial] = []


static func needs_plain_material() -> bool:
	return force_plain_material or RenderingServer.get_current_rendering_method() == "gl_compatibility"


## The arms' figure (dot-player-char adds it as the child "Arms"); null when it is not built.
static func figure(arms: Node) -> DotHumanoidFigure:
	return arms.get_node_or_null(^"Arms") as DotHumanoidFigure if arms != null else null


## Whether [param fig] has something to draw: a skinned body with a mesh, not the capsule a missing body falls back to.
static func drawable(fig: DotHumanoidFigure) -> bool:
	if fig == null or not fig.from_art or fig.skeleton() == null:
		return false
	var mesh := fig.mesh()
	return mesh != null and mesh.mesh != null and mesh.mesh.get_surface_count() > 0


## Called every frame by the arms. True while the arms are theirs to draw.
func tick(arms: DotPlayerViewArms, model: AwViewModel, camera: Camera3D, depth: float) -> bool:
	if state == VIEW_MODEL:
		return false
	var fig := figure(arms)
	if not drawable(fig):
		_frames += 1
		if _frames >= AFTER_FRAMES:
			_frames = 0
			_step(arms, model)
		return state != VIEW_MODEL
	_frames = 0
	if needs_plain_material():
		var key := "%d/%d" % [fig.mesh().get_instance_id(), arms.get_child_count()]
		if key != _key:
			_key = key
			_plain = plain_materials(arms)
		var eye := camera.global_position if camera != null else Vector3.ZERO
		for mat in _plain:
			mat.set_shader_parameter(&"draw_depth", depth)
			mat.set_shader_parameter(&"draw_eye", eye)
	return true


func _step(arms: DotPlayerViewArms, model: AwViewModel) -> void:
	if state == 0:
		state = STOCK
		DotLog.warn(&"fc.view_arms", "arms undrawable; rebuilding as the stock person")
		arms.build(DotHumanoidLook.stock(0), 1.8)
		_key = ""
		return
	state = VIEW_MODEL
	DotLog.warn(&"fc.view_arms", "stock arms undrawable too; the view model draws its own hands")
	arms.visible = false
	if model != null:
		model.show_arms = true


## Every mesh under [param root] drawn with a shader that has `instance uniform`s gets a copy of that material with
## plain `uniform`s; the copies are returned (one per original material).
static func plain_materials(root: Node) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	var made := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var mat := mesh.material_override as ShaderMaterial
		if mat == null or mat.shader == null or not mat.shader.code.contains("instance uniform"):
			continue
		if not made.has(mat):
			made[mat] = plain_copy(mat)
			out.append(made[mat])
		mesh.material_override = made[mat]
	return out


static func plain_copy(mat: ShaderMaterial) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = mat.shader.code.replace("instance uniform", "uniform")
	var copy := ShaderMaterial.new()
	copy.shader = shader
	for param in mat.shader.get_shader_uniform_list():
		var uname: StringName = param["name"]
		if uname != &"draw_depth" and uname != &"draw_eye":
			copy.set_shader_parameter(uname, mat.get_shader_parameter(uname))
	return copy
