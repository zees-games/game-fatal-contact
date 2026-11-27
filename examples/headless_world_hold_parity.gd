extends GSGameCheckSuite

const FcPlayer := preload("../game/fc_player.gd")
const FcAvatars := preload("../game/fc_avatars.gd")

## The world hold's two paths agree on real Fatal Contact bodies: with cl_native_world_hold 0 (the GDScript fallback,
## each gun's advance) and 1 (fc-weapons' ticker stepping every gun in one GSSimWorldHoldBatch call), four FcPlayer
## bodies with stock avatars and four guns, driven through the same 130 frames (swing, shots, throw, wall, inspect,
## sprint, reload, an art edit), leave the same holder, support grip and magazine every frame within TOLERANCE.
## Skips without fc-weapons' native hold; checks the batch was used exactly when the library has GSSimWorldHoldBatch.
## Run: ./game.sh --no-parse test headless_world_hold_parity

const FRAMES := 130
const STEP := 1.0 / 60.0
## Float noise only: both paths are 32-bit float transforms over the same inputs.
const TOLERANCE := 1e-5
const GUNS: Array[StringName] = [&"rifle", &"pistol", &"launcher", &"knife"]
const TICKS_PATH := "res://addons/fc_weapons/view/aw_world_ticks.gd"
const CHECKS := 6

var _slotted := false
var _seen := {}


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	print("game-fatal-contact: the native world hold matches the script fallback on real bodies")
	_run.call_deferred()


static func _art(id: StringName) -> AwWeaponVisual:
	match id:
		&"knife":
			return AwWeaponArtTable.knife()
		&"pistol":
			return AwWeaponArtTable.pistol()
		&"launcher":
			return AwWeaponArtTable.launcher()
	return AwWeaponArtTable.rifle()


## Largest component difference of two values of the same shape (Transform3D, Vector3 or null).
static func _diff(a: Variant, b: Variant) -> float:
	if a == null or b == null:
		return 0.0 if a == null and b == null else INF
	if a is Vector3:
		var va: Vector3 = a
		var vb: Vector3 = b
		if not va.is_finite() or not vb.is_finite():
			return 0.0 if va == vb else INF
		return (va - vb).abs()[(va - vb).abs().max_axis_index()]
	var ta: Transform3D = a
	var tb: Transform3D = b
	return maxf(maxf(_diff(ta.basis.x, tb.basis.x), _diff(ta.basis.y, tb.basis.y)), maxf(_diff(ta.basis.z, tb.basis.z), _diff(ta.origin, tb.origin)))


func _frame(p: FcPlayer) -> Array:
	var held: Node = p.held
	var holder: Node3D = held.get(&"_holder")
	var mag: Variant = held.get(&"_mag")
	var mag_t: Variant = (mag as Node3D).transform if mag is Node3D and is_instance_valid(mag) else null
	return [holder.global_transform, p.figure.get(&"support_point") if p.figure != null else null, mag_t]


func _pass(batch: bool) -> Array:
	var script: Script = AwWorldModel
	var was: Variant = script.get(&"native_hold")
	script.set(&"native_hold", batch)
	var ticks: Node = (load(TICKS_PATH) as Script).new() if batch else null
	var root := Node3D.new()
	add_child(root)
	var bodies: Array[FcPlayer] = []
	var helds: Array = []
	for i in GUNS.size():
		var p := FcPlayer.new()
		root.add_child(p)
		p.global_position = Vector3(float(i) * 3.0, 0.0, 0.0)
		p.attach_body_mesh(Color.WHITE, FcAvatars.stock_avatar(StringName("arena-player-%08d" % (i + 1))))
		var held: Node = p.held
		held.set(&"_own_tick", true)
		held.call(&"equip", _art(GUNS[i]))
		held.call(&"set_ticking", false)
		held.set_process(false)
		held.visible = true
		bodies.append(p)
		helds.append(held)
	var out: Array = []
	for frame in FRAMES:
		var sprint := clampf(float(frame - 60) / 20.0, 0.0, 1.0) if frame < 112 else 0.0
		for i in bodies.size():
			var p := bodies[i]
			var held: Node = helds[i]
			if p.figure != null:
				p.figure.set(&"_sprint", sprint)
			match frame + i:
				5:
					held.call(&"swing")
				15, 120:
					held.call(&"on_fired", Vector2(0.9, 0.2))
				25:
					held.call(&"throw")
				80:
					held.call(&"on_reloading", true)
				104:
					held.call(&"on_reloading", false)
			if frame >= 45 and frame < 75:
				held.call(&"on_inspect", float(frame - 45) / 30.0)
			if frame >= 30 and frame < 50:
				held.set(&"_wall_amount", 0.02 + 0.001 * frame)
			if frame == 62:
				var art: AwWeaponVisual = held.get(&"_art")
				art.world_offset += Vector3(0.0, 0.01, -0.02)
				art.emit_changed()
		if ticks != null:
			ticks.call(&"advance_all", helds, STEP)
		else:
			for held: Node in helds:
				held.call(&"advance", STEP)
		var row: Array = []
		for i in bodies.size():
			var held: Node = helds[i]
			if batch and int(held.get(&"_batch_slot")) >= 0:
				_slotted = true
			if batch:
				if float(held.get(&"_reload_blend")) > 0.0:
					_seen["reload"] = true
				if float(held.get(&"_sprint")) > 0.0:
					_seen["sprint"] = true
				if float(held.get(&"_inspect_shown")) > 0.0:
					_seen["inspect"] = true
			row.append(_frame(bodies[i]))
		out.append(row)
	root.free()
	if ticks != null:
		ticks.free()
	script.set(&"native_hold", was)
	return out


func _run() -> void:
	var script: Script = AwWorldModel
	if script.get(&"native_hold") == null or not ResourceLoader.exists(TICKS_PATH):
		print("  SKIP: this fc-weapons has no native world hold (AwWorldModel.native_hold, aw_world_ticks.gd)")
		_report()
		return
	var library := ClassDB.class_exists(&"GSSimWorldHoldBatch")
	var fallback := _pass(false)
	var native := _pass(true)
	var worst := [0.0, 0.0, 0.0]
	var first := -1
	for frame in FRAMES:
		for i in GUNS.size():
			for k in 3:
				var d := _diff(fallback[frame][i][k], native[frame][i][k])
				worst[k] = maxf(worst[k], d)
				if d > TOLERANCE and first < 0:
					first = frame
	_check(_seen.has("sprint") and _seen.has("inspect") and _seen.has("reload"), "the run reached sprint, inspect and reload", str(_seen.keys()))
	_check(_slotted == library, "the batch took the guns exactly when GSSimWorldHoldBatch exists (library %s, slotted %s)" % [library, _slotted])
	_check(worst[0] <= TOLERANCE, "holder: fallback and native agree within %s over %d frames x %d guns (max %s)" % [TOLERANCE, FRAMES, GUNS.size(), worst[0]], "first frame over: %d" % first)
	_check(worst[1] <= TOLERANCE, "support grip: fallback and native agree (max %s)" % worst[1], "first frame over: %d" % first)
	_check(worst[2] <= TOLERANCE, "magazine: fallback and native agree (max %s)" % worst[2], "first frame over: %d" % first)
	_check(script.get(&"native_hold") == true, "the switch is back where it was")
	_report(CHECKS)
