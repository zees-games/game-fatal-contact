extends SceneTree

## Scope clips of the real game for the visual judge (tools/render_scope_clips.sh): a scoped rifle at the hip with its idle sway, the aim-in to the full-screen scope,
## the zoom levels stepped through with the scope key (FcClient.cycle_scope_zoom), and the lower. One PNG per frame under <out>/<role>/<clip>/NNNN.png.
## Args: out dir (default screenshots/scope_clips); env SCOPE_ROLES (default sniper).

const FcPresentation := preload("../game/fc_presentation.gd")

var client: Node = null
var _out := "screenshots/scope_clips"


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() > 0:
		_out = a[0]
	preload("../game/fc_weapon_roles.gd").ensure()
	var _scratch := FcPresentation.use_scratch_settings("render_scope_clips")
	var scene: PackedScene = load("res://game/fc.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	await _wait(16.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	await _wait(14.0)
	var wanted := OS.get_environment("SCOPE_ROLES")
	var roles := wanted.split(",") if wanted != "" else PackedStringArray(["sniper"])
	for role in roles:
		var id := StringName(role)
		var def: GSWeaponDef = AwWeaponCatalogue.table().get(id)
		if def == null:
			print("no def %s" % role)
			continue
		var me = client.get("player")
		me.health.invulnerable = true
		var _g = me.arsenal.give(id)
		me.arsenal.equip(1 if def.slot != 1 else 2)
		await _wait(0.6)
		me.arsenal.equip(def.slot)
		await _wait(1.5)
		await _clip(role, "hip_idle", 120, 0)
		Input.action_press(&"arena_aim")
		await _clip(role, "aim_in", 45, 0)
		# Hold the widest level, then step through every level and back round to the widest.
		await _clip(role, "zoom_cycle", 210, 60)
		Input.action_release(&"arena_aim")
		await _clip(role, "lower", 45, 0)
		print("scope_clips done ", role)
	quit(0)


## frames of one clip; with cycle_every > 0 the scope key steps the level at that frame spacing (three presses: level 2, level 1 again... as many as the weapon has levels).
func _clip(role: String, clip: String, frames: int, cycle_every: int) -> void:
	var dir := "%s/%s/%s" % [_out, role, clip]
	DirAccess.make_dir_recursive_absolute(dir)
	for i in frames:
		if cycle_every > 0 and i > 0 and i % cycle_every == 0:
			var lvl := int(client.call(&"cycle_scope_zoom"))
			print("scope_clips %s %s frame %d level %d" % [role, clip, i, lvl])
		await process_frame
		await RenderingServer.frame_post_draw
		var vm := _vm()
		if i % 30 == 0 and vm != null:
			print("scope_clips %s %s frame %d aim %.2f scoped %s zoom %d fov %.1f" % [role, clip, i, vm.aim_fraction(), str(vm.is_scoped()), vm.zoom_level(), root.get_viewport().get_camera_3d().fov])
		var _s := root.get_viewport().get_texture().get_image().save_png("%s/%04d.png" % [dir, i])


func _vm() -> AwViewModel:
	var vms := client.find_children("*", "AwViewModel", true, false)
	return vms[0] as AwViewModel if not vms.is_empty() else null


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
