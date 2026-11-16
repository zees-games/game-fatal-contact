extends "weapon_lab.gd"

## The animation review: the weapon lab's first-person clips, plus two outside views of your own body (behind-right, and an
## opponent's view from in front) and numeric glitch metrics per frame, judged per clip. See docs/anim-review.md; run through tools/anim_review.sh.
## The avatar_* clips (walk, strafe, run, crouch, jump) move the player with the weapon held, for the body's locomotion.
## Per clip it prints an `ANIMREVIEW {json}` verdict line and an `ANIMFRAMES {json}` line with every frame's numbers (both travel on stdout, since a GPU box only sends PNGs back).

## Your own body draws only in the third-person view; the arms only in the first-person one.
const BODY_LAYER := 1 << 18
const ARMS_LAYER := 1 << 17
const VIEW_LAYER := 1 << 19
const ARM_BONES: PackedStringArray = ["UpperArm.R", "LowerArm.R", "Middle1.R", "UpperArm.L", "LowerArm.L", "Middle1.L"]
## Failure limits. Distances in metres, angles in degrees; steps and frame counts are per frame at 30 fps and _limit scales them.
const LIMITS := {"detach_m": 0.06, "intersect_m": 0.03, "near_cut_m": 0.005, "pop_m": 0.04, "pop_deg": 25.0,
	"pop_ratio": 3.0, "kick_m": 0.09, "wrong_hand_frames": 2, "hidden_frames": 3, "tpose_frames": 1,
	"muzzle_behind_m": 0.10, "muzzle_ahead_m": 0.10, "muzzle_off_m": 0.03}
## Per-frame steps (a velocity) shrink at a higher fps; a frame count (a duration) grows. A kick is one impulse at any fps.
const PER_STEP: PackedStringArray = ["pop_m", "pop_deg"]
const PER_COUNT: PackedStringArray = ["wrong_hand_frames", "hidden_frames"]
## The opponent's view: standing this far in front of you, eyes at this height, looking at your chest.
const OPPONENT_AT := Vector3(0.4, 1.6, -4.0)
const AVATAR_ANIMS := {"avatar_walk": [&"dot_fps_forward"], "avatar_strafe": [&"dot_fps_left"],
	"avatar_run": [&"dot_fps_forward", &"dot_fps_sprint"], "avatar_crouch": [&"dot_fps_crouch"], "avatar_jump": [&"dot_fps_jump"]}

var _tp_view: SubViewport = null
var _tp_cam: Camera3D = null
var _op_view: SubViewport = null
var _op_cam: Camera3D = null
var _frames: Array[Dictionary] = []
var _body_metrics := DotClipMetrics.new()
var _clip_key := ""


func _build_lab() -> void:
	super._build_lab()
	_tp_view = _outside_view()
	_tp_cam = _tp_view.get_child(0) as Camera3D
	_op_view = _outside_view()
	_op_cam = _op_view.get_child(0) as Camera3D
	# With your own body off the client draws the figure whole and only hides it, which the staging undoes before the draw.
	var presentation = client.get("presentation")
	if presentation != null and presentation.settings != null:
		var _off: Variant = presentation.settings.set_value(DotOwnBodySetting.KEY, false)


## A 480x540 view of the shared world that sees your body and the world gun but not the first-person arms or weapon.
func _outside_view() -> SubViewport:
	var view := SubViewport.new()
	view.size = Vector2i(480, 540)
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.world_3d = root.world_3d
	root.add_child(view)
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.cull_mask = 0xFFFFF & ~VIEW_LAYER & ~ARMS_LAYER
	cam.environment = (client.get("player").camera as Camera3D).environment
	view.add_child(cam)
	return view


## A limit at the run's fps (see PER_STEP and PER_COUNT).
func _limit(key: String) -> float:
	var v := float(LIMITS[key])
	if key in PER_STEP:
		return v * 30.0 / float(fps)
	if key in PER_COUNT:
		return v * float(fps) / 30.0
	return v


func _save_frame(d: String, i: int, vp: Viewport = null) -> void:
	if vp != null or _tp_view == null:
		await super._save_frame(d, i, vp)
		return
	if i == 0:
		_frames.clear()
		_body_metrics = DotClipMetrics.new()
		# The outside views draw one frame behind a clip's first staging (the last clip's gun, or the camera inside a wall):
		# one staged draw before frame 0 is saved.
		await RenderingServer.frame_pre_draw
		_stage_views()
		await RenderingServer.frame_post_draw
	# Staged after every _process (the client re-hides your body each frame) and just before this frame draws.
	await RenderingServer.frame_pre_draw
	_stage_views()
	_frames.append(_sample(float(i) / float(fps)))
	await RenderingServer.frame_post_draw
	var _e := root.get_viewport().get_texture().get_image().save_jpg("%s/f_%03d.jpg" % [d, i], 0.9)
	var _t := _tp_view.get_texture().get_image().save_jpg("%s/t_%03d.jpg" % [d, i], 0.9)
	var _o := _op_view.get_texture().get_image().save_jpg("%s/o_%03d.jpg" % [d, i], 0.9)
	_frames_saved += 1


## Shows your own body to the outside cameras only, and places them: a fixed three-quarter view and an opponent in front.
func _stage_views() -> void:
	var me = client.get("player")
	var cam := me.camera as Camera3D
	cam.cull_mask = 0xFFFFF & ~BODY_LAYER
	var arms_node := client.get("view_arms") as Node
	if arms_node != null:
		_tag(arms_node, ARMS_LAYER, null)
	var body: Node3D = me.body_mesh
	if body != null:
		body.visible = true
		body.global_position = me.controller.state.position
		body.global_rotation = Vector3(0.0, deg_to_rad(float(me.controller.state.yaw)), 0.0)
		# The gun in the body's hands, as everyone else sees it; the first-person present hides it.
		me._present_held()
		_tag(body, BODY_LAYER, cam)
	var feet: Vector3 = me.controller.state.position
	var yaw := deg_to_rad(float(me.controller.state.yaw))
	_tp_cam.global_position = feet + Basis(Vector3.UP, yaw) * Vector3(1.4, 1.5, 2.0)
	_tp_cam.look_at(feet + Vector3(0.0, 1.1, 0.0))
	_op_cam.global_position = feet + Basis(Vector3.UP, yaw) * OPPONENT_AT
	_op_cam.look_at(feet + Vector3(0.0, 1.3, 0.0))


func _tag(node: Node, layer: int, skip: Node) -> void:
	if node == skip:
		return
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = layer
	for child in node.get_children():
		_tag(child, layer, skip)


## One frame's raw numbers: where the hands and weapon are in camera space, and how the arms sit against the grip, the weapon and the near plane.
func _sample(time: float) -> Dictionary:
	var me = client.get("player")
	var cam := me.camera as Camera3D
	var view := _view_model(me)
	var out := {"t": snappedf(time, 0.001), "switching": bool(me.arsenal.is_switching()), "reloading": bool(me.arsenal.is_reloading())}
	var figure: DotHumanoidFigure = me.figure
	if figure != null and figure.skeleton() != null:
		_body_metrics.add(_body_metrics.pose_sample(time, figure.skeleton(), me.controller.state.position, true))
	if view == null:
		return out
	var pose = view.get("_pose")
	if pose != null and pose.has_method(&"deploy_fraction"):
		out["deploy"] = snappedf(float(pose.call(&"deploy_fraction")), 0.001)
	var to_cam := cam.global_transform.affine_inverse()
	var weapon := view.weapon_node()
	out["model_visible"] = view.visible and weapon != null and weapon.is_visible_in_tree()
	out["scoped"] = view.arms_hidden_by_scope()
	out["cut"] = snappedf(view.weapon_cut_depth(cam, cam.near), 0.0001)
	if weapon != null:
		var local := to_cam * weapon.global_transform
		out["weapon"] = _v(local.origin)
		var q := local.basis.get_rotation_quaternion()
		out["weapon_q"] = [snappedf(q.x, 0.00001), snappedf(q.y, 0.00001), snappedf(q.z, 0.00001), snappedf(q.w, 0.00001)]
		out["weapon_id"] = weapon.get_instance_id()
		if view.has_method(&"muzzle_transform"):
			_muzzle_fit(to_cam, weapon, (view.call(&"muzzle_transform") as Transform3D).origin, out)
	var mounted := client.get("view_arms") as Node3D
	if mounted == null or not (mounted.get("arms") is DotPlayerViewArms):
		return out
	var arms := mounted.get("arms") as DotPlayerViewArms
	var grip: DotViewGrip = mounted.get("_grip")
	out["arms_visible"] = mounted.is_visible_in_tree() and arms.shown
	out["holding"] = bool(mounted.call(&"holding"))
	if not out["holding"] or not (arms.arms() is DotHumanoidFigure):
		return out
	out["hand_error"] = snappedf(arms.hand_error(grip), 0.0001)
	var skeleton := (arms.arms() as DotHumanoidFigure).skeleton()
	var at := {}
	for bone in ARM_BONES:
		var index := skeleton.find_bone(bone)
		if index >= 0:
			at[bone] = skeleton.global_transform * skeleton.get_bone_global_pose(index).origin
	if at.size() < ARM_BONES.size():
		return out
	for bone: String in at:
		out[bone] = _v(to_cam * (at[bone] as Vector3))
	var grip_at := grip.grip_world()
	out["hand_swap"] = snappedf((at["Middle1.R"] as Vector3).distance_to(grip_at) - (at["Middle1.L"] as Vector3).distance_to(grip_at), 0.0001) if grip.is_two_hand() else 0.0
	out["seen.R"] = _arm_seen(cam, at, ".R")
	out["seen.L"] = _arm_seen(cam, at, ".L")
	out["tpose"] = (_straight_out(to_cam, at, ".R") and out["seen.R"]) or (_straight_out(to_cam, at, ".L") and out["seen.L"])
	out["near"] = snappedf(_near_depth(cam, at, arms.arm_radius), 0.0001)
	out["intersect"] = snappedf(_inside_weapon(weapon, at), 0.0001) if weapon != null else 0.0
	return out


## Where the muzzle (the flash and tracer origin) sits against the weapon's drawn meshes, in camera space (forward is -z):
## muzzle_ahead is its distance past the front-most mesh point (negative = inside the gun), muzzle_off how far it is
## outside the meshes' outline across the view.
func _muzzle_fit(to_cam: Transform3D, weapon: Node3D, muzzle_world: Vector3, out: Dictionary) -> void:
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for part in weapon.find_children("*", "MeshInstance3D", true, false):
		var mesh := part as MeshInstance3D
		if not mesh.is_visible_in_tree() or mesh.mesh == null:
			continue
		var box := mesh.mesh.get_aabb()
		var into := to_cam * mesh.global_transform
		for c in 8:
			var p := into * box.get_endpoint(c)
			lo = lo.min(p)
			hi = hi.max(p)
	if lo == Vector3.INF:
		return
	var m := to_cam * muzzle_world
	out["muzzle"] = _v(m)
	out["muzzle_ahead"] = snappedf(lo.z - m.z, 0.0001)
	out["muzzle_off"] = snappedf(Vector2(maxf(maxf(lo.x - m.x, m.x - hi.x), 0.0), maxf(maxf(lo.y - m.y, m.y - hi.y), 0.0)).length(), 0.0001)


func _v(p: Vector3) -> Array:
	return [snappedf(p.x, 0.0001), snappedf(p.y, 0.0001), snappedf(p.z, 0.0001)]


## The upper arm held straight out sideways and level: a T-pose (no IK applied).
func _straight_out(to_cam: Transform3D, at: Dictionary, side: String) -> bool:
	var dir: Vector3 = (to_cam.basis * ((at["LowerArm" + side] as Vector3) - (at["UpperArm" + side] as Vector3))).normalized()
	return absf(dir.x) > 0.95 and absf(dir.y) < 0.2


## How far inside the near plane plus the arm's own radius any visible point of an arm reaches (positive is a cut).
func _near_depth(cam: Camera3D, at: Dictionary, radius: float) -> float:
	var worst := -1.0
	var size := Vector2(root.get_viewport().get_visible_rect().size)
	for side in [".R", ".L"]:
		for seg in [["UpperArm", "LowerArm"], ["LowerArm", "Middle1"]]:
			for k in 6:
				var p: Vector3 = (at[seg[0] + side] as Vector3).lerp(at[seg[1] + side], float(k) / 5.0)
				var depth := -(cam.global_transform.affine_inverse() * p).z
				if depth <= 0.0:
					continue
				var px := cam.unproject_position(p)
				if px.x < 0.0 or px.y < 0.0 or px.x > size.x or px.y > size.y:
					continue
				worst = maxf(worst, cam.near + radius - depth)
	return worst


## Whether any of an arm's elbow-to-hand line is on screen: the free arm of a one-handed weapon hangs out of view, posed or not.
func _arm_seen(cam: Camera3D, at: Dictionary, side: String) -> bool:
	var size := Vector2(root.get_viewport().get_visible_rect().size)
	for k in 5:
		var p: Vector3 = (at["LowerArm" + side] as Vector3).lerp(at["Middle1" + side], float(k) / 4.0)
		if cam.is_position_behind(p):
			continue
		var px := cam.unproject_position(p)
		if px.x >= 0.0 and px.y >= 0.0 and px.x <= size.x and px.y <= size.y:
			return true
	return false


## How deep the arm bones (elbow to just short of the wrist) sink into any one part of the weapon (receiver, scope,
## magazine): the union of the parts' boxes takes in the air under a scope, where a forearm belongs.
func _inside_weapon(weapon: Node3D, at: Dictionary) -> float:
	var worst := 0.0
	for part in weapon.find_children("*", "MeshInstance3D", true, false):
		var mesh := part as MeshInstance3D
		if not mesh.is_visible_in_tree() or mesh.mesh == null:
			continue
		var box := mesh.mesh.get_aabb()
		if not box.has_volume():
			continue
		var to_part := mesh.global_transform.affine_inverse()
		var scale := mesh.global_transform.basis.get_scale()
		for side in [".R", ".L"]:
			for k in 7:
				var p: Vector3 = to_part * (at["LowerArm" + side] as Vector3).lerp(at["Middle1" + side], float(k) / 10.0)
				if box.has_point(p):
					var lo := (p - box.position) * scale
					var hi := (box.end - p) * scale
					worst = maxf(worst, minf(minf(minf(lo.x, hi.x), minf(lo.y, hi.y)), minf(lo.z, hi.z)))
	return worst


## A clip the lab cannot play (no magazine, no sights, no inspect animation) is still a line of the report.
func _fp_animation(a: String, me, id: StringName, def: DotWeaponDef, wdir: String, other_slot: int) -> Dictionary:
	var res: Dictionary
	if AVATAR_ANIMS.has(a):
		res = await _avatar_clip(a, me, id, def, wdir)
	else:
		res = await super._fp_animation(a, me, id, def, wdir, other_slot)
	if res.get("status", "") != "ok":
		print("ANIMREVIEW " + JSON.stringify({"weapon": str(id), "anim": a, "status": res.get("status", ""), "why": res.get("why", "")}))
	return res


## A locomotion clip: the keys held from 0.2 s to 1.6 s of a 2.4 s clip (jump: one press), the yaw turned back each time so
## every run walks the same way. The player is put back where it stood afterwards.
func _avatar_clip(a: String, me, id: StringName, def: DotWeaponDef, wdir: String) -> Dictionary:
	var res := {"status": "ok"}
	await _ensure_in_hand(me, id, def)
	var start: Vector3 = me.controller.state.position
	var keys: Array = AVATAR_ANIMS[a]
	var tap := a == "avatar_jump"
	await _clip(wdir, "fp_" + a, _f(72), func(i: int) -> void:
		if i == _f(6):
			for k: StringName in keys:
				Input.action_press(k)
		elif i == (_f(9) if tap else _f(48)):
			for k: StringName in keys:
				Input.action_release(k), res)
	for k: StringName in keys:
		Input.action_release(k)
	res["moved_m"] = snappedf((me.controller.state.position as Vector3).distance_to(start), 0.01)
	if a != "avatar_crouch" and a != "avatar_jump" and float(res["moved_m"]) < 0.5:
		res = {"status": "missing", "why": "the movement keys moved the player %.2f m" % float(res["moved_m"])}
	me.controller.state.position = start
	await _wait(0.6)
	return res


func _finish_clip(wdir: String, key: String, count: int) -> void:
	_clip_key = key
	var verdict := _judge(_frames)
	verdict["weapon"] = wdir.get_file()
	verdict["anim"] = key.trim_prefix("fp_")
	verdict["frames"] = count
	verdict["fps"] = fps
	for row in _body_metrics.evaluate({}):
		if row["check"] == "pop" and not row.get("skip", false):
			verdict["tp_pop"] = row["value"]
			if not row["pass"]:
				(verdict["fail"] as Array).append("tp body pop %s" % row["value"])
	verdict["pass"] = (verdict["fail"] as Array).is_empty()
	var file := FileAccess.open("%s/%s_metrics.json" % [wdir, key], FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"verdict": verdict, "frames": _frames}))
	print("ANIMREVIEW " + JSON.stringify(verdict))
	print("ANIMFRAMES " + JSON.stringify({"weapon": verdict["weapon"], "anim": verdict["anim"], "frames": _frames}))
	super._finish_clip(wdir, key, count)


## The clip's worst numbers and the reasons it fails, frame indexes included so a sheet can be read at the right cell.
func _judge(frames: Array[Dictionary]) -> Dictionary:
	var fail: Array = []
	var worst := {"hand_error": 0.0, "intersect": 0.0, "near": -1.0, "cut": 0.0, "pop_m": 0.0, "pop_deg": 0.0}
	var counts := {"wrong_hand": 0, "hidden": 0, "tpose": 0, "detached": 0}
	var first := {}
	for i in frames.size():
		var f := frames[i]
		var steady: bool = not f.get("switching", false)
		for k in ["hand_error", "intersect", "near", "cut"]:
			if f.has(k) and float(f[k]) > float(worst[k]):
				worst[k] = float(f[k])
				first[k] = i
		if float(f.get("hand_error", 0.0)) > LIMITS["detach_m"]:
			counts["detached"] += 1
		if float(f.get("hand_swap", 0.0)) > 0.02:
			counts["wrong_hand"] += 1
			first["wrong_hand"] = first.get("wrong_hand", i)
		if f.get("tpose", false):
			counts["tpose"] += 1
			first["tpose"] = first.get("tpose", i)
		if steady and f.get("model_visible", false) and not f.get("scoped", false) and not f.get("holding", false):
			counts["hidden"] += 1
			first["hidden"] = first.get("hidden", i)
	var pops := _pops(frames, _clip_key.ends_with("fire"))
	worst["pop_m"] = pops["m"]
	worst["pop_deg"] = pops["deg"]
	if worst["hand_error"] > LIMITS["detach_m"]:
		fail.append("hand off grip %.3f m (%d frames, worst #%d)" % [worst["hand_error"], counts["detached"], first["hand_error"]])
	if worst["intersect"] > LIMITS["intersect_m"]:
		fail.append("forearm inside weapon %.3f m at #%d" % [worst["intersect"], first["intersect"]])
	if worst["near"] > 0.0:
		fail.append("arm through near plane %.3f m at #%d" % [worst["near"], first["near"]])
	if worst["cut"] > LIMITS["near_cut_m"]:
		fail.append("weapon through near plane %.3f m at #%d" % [worst["cut"], first["cut"]])
	if counts["wrong_hand"] > _limit("wrong_hand_frames"):
		fail.append("left hand nearer the grip in %d frames from #%d" % [counts["wrong_hand"], first["wrong_hand"]])
	if counts["tpose"] >= LIMITS["tpose_frames"]:
		fail.append("arms in T-pose in %d frames from #%d" % [counts["tpose"], first["tpose"]])
	if counts["hidden"] > _limit("hidden_frames"):
		fail.append("weapon drawn without arms in %d frames from #%d" % [counts["hidden"], first["hidden"]])
	for p: String in pops["at"]:
		fail.append(p)
	if _clip_key.ends_with("fire"):
		_judge_muzzle(frames, worst, fail)
	# A draw or holster whose deploy never leaves 1 is an instant swap: the gun appears or vanishes with no motion.
	if _clip_key.ends_with("draw") or _clip_key.ends_with("holster"):
		var low := 1.0
		for f in frames:
			low = minf(low, float(f.get("deploy", 1.0)))
		worst["deploy_min"] = low
		if low > 0.9:
			fail.append("no %s motion: deploy never below %.2f" % [_clip_key.trim_prefix("fp_"), low])
	for k in worst:
		worst[k] = snappedf(float(worst[k]), 0.001)
	return {"worst": worst, "counts": counts, "fail": fail}


## The muzzle against the gun in settled frames (deploy done, no swap): the flash must leave the barrel's end, not the
## receiver, the air in front or a point beside the gun.
func _judge_muzzle(frames: Array[Dictionary], worst: Dictionary, fail: Array) -> void:
	var ahead := -INF
	var behind := -INF
	var off := 0.0
	var at := {}
	for i in frames.size():
		var f := frames[i]
		if not f.has("muzzle_ahead") or f.get("switching", false) or float(f.get("deploy", 1.0)) < 0.99:
			continue
		var a := float(f["muzzle_ahead"])
		if a > ahead:
			ahead = a
			at["ahead"] = i
		if -a > behind:
			behind = -a
			at["behind"] = i
		if float(f["muzzle_off"]) > off:
			off = float(f["muzzle_off"])
			at["off"] = i
	if at.is_empty():
		return
	worst["muzzle_ahead"] = ahead
	worst["muzzle_behind"] = behind
	worst["muzzle_off"] = off
	if ahead > LIMITS["muzzle_ahead_m"]:
		fail.append("muzzle %.3f m in front of the barrel at #%d" % [ahead, at["ahead"]])
	if behind > LIMITS["muzzle_behind_m"]:
		fail.append("muzzle %.3f m inside the gun at #%d" % [behind, at["behind"]])
	if off > LIMITS["muzzle_off_m"]:
		fail.append("muzzle %.3f m beside the gun at #%d" % [off, at["off"]])


## Single-frame jumps of a hand, an elbow or the weapon, in camera space: far above both neighbours, so steady motion is not one.
## The weapon's own node changing (a swap) is not a pop, nor the hands' regrip in the frame after it, nor a hand jump off screen.
func _pops(frames: Array[Dictionary], firing := false) -> Dictionary:
	var out := {"m": 0.0, "deg": 0.0, "at": []}
	var keys := ["weapon", "Middle1.R", "Middle1.L", "LowerArm.R", "LowerArm.L"]
	for key in keys:
		var steps: Array[float] = []
		for i in range(1, frames.size()):
			# The arms take the new grip a frame after the weapon node swaps, low in the view: that frame is the swap too.
			var regrip: bool = key != "weapon" and i >= 2 and frames[i - 2].get("weapon_id") != frames[i - 1].get("weapon_id")
			# A free hand dropping out of view to its rest is a jump nobody sees.
			var side: String = key.right(2)
			var unseen: bool = key != "weapon" and not (frames[i - 1].get("seen" + side, true) or frames[i].get("seen" + side, true))
			steps.append(-1.0 if regrip or unseen else _step(frames[i - 1], frames[i], key))
		# Every shot kicks the gun and the hands on it back in one frame by design; the fire clip allows a kick, not a snap.
		_spikes(steps, _limit("kick_m") if firing else _limit("pop_m"), "%s jumps %.3f m at #%d", key, out, "m")
	var turns: Array[float] = []
	for i in range(1, frames.size()):
		var a: Dictionary = frames[i - 1]
		var b: Dictionary = frames[i]
		if not (a.has("weapon_q") and b.has("weapon_q")) or a.get("weapon_id") != b.get("weapon_id"):
			turns.append(-1.0)
			continue
		var qa := Quaternion(a["weapon_q"][0], a["weapon_q"][1], a["weapon_q"][2], a["weapon_q"][3])
		var qb := Quaternion(b["weapon_q"][0], b["weapon_q"][1], b["weapon_q"][2], b["weapon_q"][3])
		turns.append(rad_to_deg(qa.angle_to(qb)))
	_spikes(turns, _limit("pop_deg"), "%s turns %.1f deg at #%d", "weapon", out, "deg")
	return out


func _step(a: Dictionary, b: Dictionary, key: String) -> float:
	if not (a.has(key) and b.has(key)) or a.get("weapon_id") != b.get("weapon_id"):
		return -1.0
	return Vector3(a[key][0], a[key][1], a[key][2]).distance_to(Vector3(b[key][0], b[key][1], b[key][2]))


func _spikes(steps: Array[float], limit: float, text: String, key: String, out: Dictionary, unit: String) -> void:
	for i in steps.size():
		var v := steps[i]
		out[unit] = maxf(float(out[unit]), v)
		var before := steps[i - 1] if i > 0 else 0.0
		var after := steps[i + 1] if i + 1 < steps.size() else 0.0
		if v > limit and v > float(LIMITS["pop_ratio"]) * maxf(maxf(before, after), limit * 0.1):
			(out["at"] as Array).append(text % [key, v, i + 1])
