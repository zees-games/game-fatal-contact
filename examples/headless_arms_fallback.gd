extends GSGameCheckSuite
## The first-person arms never disappear (fc_view_arms_fallback.gd): the web build (Compatibility renderer, no per-instance
## shader uniforms) drew the AK with no arms at all. Stock arms are drawable, their material needs no instance uniform
## where the renderer has none, and arms that cannot be drawn are rebuilt as the stock person, then give way to the view
## model's own hands.
## Run: [code]godot --headless --path . res://examples/headless_arms_fallback.tscn[/code]

const Fallback := preload("../game/fc_view_arms_fallback.gd")

var _bad_builds := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _arms() -> GSPlayerViewArms:
	var arms := GSPlayerViewArms.new()
	add_child(arms)
	return arms


## An arms factory that yields something undrawable (not a figure) for its first [param bad] builds, then the default arms.
func _factory(bad: int) -> Callable:
	_bad_builds = 0
	return func(_look: GSHumanoidLook, _height: float) -> Node3D:
		_bad_builds += 1
		return Node3D.new() if _bad_builds <= bad else null


func _frames(fb: Object, arms: GSPlayerViewArms, n: int) -> bool:
	var drawn := true
	for i in n:
		drawn = fb.tick(arms, null, null, 1.0)
	return drawn


func _run() -> void:
	print("game-fatal-contact: the first-person arms never disappear")
	var arms := _arms()
	arms.build(GSHumanoidLook.stock(0), 1.8)
	_check(Fallback.drawable(Fallback.figure(arms)), "the stock arms are drawable")

	var fb := Fallback.new()
	_check(_frames(fb, arms, 3) and fb.state == 0, "drawable arms are left alone")

	Fallback.force_plain_material = true
	_frames(fb, arms, 1)
	var instance_left := 0
	for node in arms.find_children("*", "MeshInstance3D", true, false):
		var mat := (node as MeshInstance3D).material_override as ShaderMaterial
		if mat != null and mat.shader != null and mat.shader.code.contains("instance uniform"):
			instance_left += 1
	_check(instance_left == 0, "with no instance uniforms the arms' shader has none", "%d meshes left" % instance_left)
	var plain := Fallback.plain_materials(arms)
	_check(plain.is_empty(), "and is converted once, not every frame")
	var shader_plain := false
	for node in arms.find_children("*", "MeshInstance3D", true, false):
		var m := (node as MeshInstance3D).material_override as ShaderMaterial
		shader_plain = m != null and m.shader.code.contains("uniform float draw_depth")
	_check(shader_plain, "draw_depth is a plain uniform")
	Fallback.force_plain_material = false

	var broken := _arms()
	broken.arms_factory = _factory(1)
	broken.build(GSHumanoidLook.stock(0), 1.8)
	_check(not Fallback.drawable(Fallback.figure(broken)), "a factory yielding no figure leaves undrawable arms")
	var fb2 := Fallback.new()
	_frames(fb2, broken, Fallback.AFTER_FRAMES - 1)
	_check(fb2.state == 0 and broken.visible, "undrawable arms are given a moment")
	_frames(fb2, broken, 1)
	_check(fb2.state == Fallback.STOCK, "then rebuilt as the stock person")
	_check(Fallback.drawable(Fallback.figure(broken)), "which draws")
	_check(fb2.tick(broken, null, null, 1.0), "and stays the arms' to draw")

	var hopeless := _arms()
	hopeless.arms_factory = _factory(99)
	hopeless.build(GSHumanoidLook.stock(0), 1.8)
	var fb3 := Fallback.new()
	_frames(fb3, hopeless, Fallback.AFTER_FRAMES)
	_check(fb3.state == Fallback.STOCK, "arms still undrawable first try the stock person")
	var drawn := _frames(fb3, hopeless, Fallback.AFTER_FRAMES)
	_check(fb3.state == Fallback.VIEW_MODEL and not drawn, "and then give way to the view model's hands")
	_check(not hopeless.visible, "hiding the arms")
	_report_sections(1, 1, 1, 13)
