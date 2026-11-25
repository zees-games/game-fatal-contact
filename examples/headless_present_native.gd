extends GSGameCheckSuite

const FcPlayer := preload("../game/fc_player.gd")

## The native present pass (one GSSimPresentLod call a frame) judges every remote body exactly as FcPlayer.present_lod does
## itself: two crowds of bare bodies at the same seeded spots, one presented each way, keep the same thinning counters and
## animation gates frame after frame. Skips when the library has no GSSimPresentLod.
## Run: [code]godot --headless --path . res://examples/headless_present_native.tscn[/code]

const BODIES := 200
const FRAMES := 12



func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	print("game-fatal-contact: the native present pass matches the script's")
	_run.call_deferred()


func _crowd(root: Node3D, spots: Array) -> Array:
	var out: Array = []
	for at: Vector3 in spots:
		var p := FcPlayer.new()
		root.add_child(p)
		p.global_position = at
		out.append(p)
	return out


func _state(bodies: Array) -> Array:
	var s: Array = []
	for p: FcPlayer in bodies:
		s.append([p.get("_lod_frames"), snappedf(p.get("_lod_delta") as float, 0.00001), p.get("_anim_min_dt")])
	return s


func _parity(frustum_on: bool, label: String) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261125
	var spots: Array = []
	for _i in BODIES:
		var r := pow(rng.randf(), 1.6) * 520.0
		var a := rng.randf() * TAU
		spots.append(Vector3(cos(a) * r, rng.randf_range(-3.0, 30.0), sin(a) * r))
	var root := Node3D.new()
	add_child(root)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(rng.randf_range(-20, 20), 1.7, rng.randf_range(-20, 20))
	cam.look_at(cam.global_position + Vector3(rng.randf_range(-1, 1), 0.0, rng.randf_range(-1, 1)).normalized() + Vector3.UP * 0.05)
	var script_crowd := _crowd(root, spots)
	var native_crowd := _crowd(root, spots)
	var frustum: Array = cam.get_frustum() if frustum_on else []
	var eye := cam.global_position
	var forward := -cam.global_basis.z
	var same := true
	var first_diff := ""
	for f in FRAMES:
		for p: FcPlayer in script_crowd:
			p.present_lod(0.016, eye, forward, frustum)
		var codes := FcPlayer.classify_crowd(native_crowd, eye, forward, frustum)
		if codes.size() != BODIES:
			same = false
			first_diff = "classify returned %d codes" % codes.size()
			break
		for i in BODIES:
			(native_crowd[i] as FcPlayer).present_lod_coded(0.016, codes[i], eye)
		var a := _state(script_crowd)
		var b := _state(native_crowd)
		if a != b:
			same = false
			for i in BODIES:
				if a[i] != b[i]:
					first_diff = "frame %d body %d at %s: script %s native %s" % [f, i, spots[i], a[i], b[i]]
					break
			break
	_check(same, "%d bodies x %d frames, %s: same counters as the script" % [BODIES, FRAMES, label], first_diff)
	root.free()


func _run() -> void:
	if not GSSim.has(&"present"):
		print("  SKIP: this gs-sim library has no GSSimPresentLod")
		_report()
		return
	_parity(true, "frustum")
	_parity(false, "cone")
	var was := FcPlayer.occlusion_enabled
	FcPlayer.occlusion_enabled = false
	_parity(true, "frustum, occlusion off")
	FcPlayer.occlusion_enabled = was
	var crowd := FcPlayer.classify_crowd([], Vector3.ZERO, Vector3.FORWARD, [])
	_check(crowd.is_empty(), "no bodies: no codes")
	FcPlayer.present_native = false
	var lone := FcPlayer.new()
	var off := FcPlayer.classify_crowd([lone], Vector3.ZERO, Vector3.FORWARD, [])
	lone.free()
	_check(off.is_empty(), "cl_remote_lod_native 0: no codes, the script judges")
	FcPlayer.present_native = true
	FcPlayer.release_crowd()
	_report()
