extends DotGameCheckSuite

## "Crosshair on his chest at 65 m and nothing": does the body the client draws stand inside the hit zones the server traces? For every stock avatar and each way a player moves (idle, walking away, strafing, walking at you, aiming up and down, crouched still, crouch walking), a shot from
## 65 m at the drawn skeleton's head, neck, torso, belly and hips (and arms when standing) must land in a zone, on every tick of the walk cycle. Only the hit zones' own fit is measured here; the netcode and the gun are headless_hitreg_ping's and headless_hitreg_scope's.
## The crouch walk once drew the head higher than standing while the zones squeezed to crouch height (head shots missed 43-64 of 64); dot-player-char's made CROUCH_WALK now holds the hips at the crouch's height (dpc-crouch-walk-pose-fit-1), so it is asserted like the rest.
## A shot at the middle of the drawn head ("HeadMid") is asserted too: at the original 36 unit crouch the zones squeezed under it and all 64 such shots missed on every
## avatar, crouched or crouch walking (the head bone, the head's base, still landed). The crouch is 54 units now and the figure crouches with its knees near square.

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaAvatars := preload("../game/arena_avatars.gd")

const RANGE_M := 65.0
const WARMUP_TICKS := 40
const SAMPLE_TICKS := 64
const AVATARS: Array[String] = ["arena-player-00000001", "arena-player-00000002", "arena-player-00000003",
	"arena-player-00000004", "arena-player-00000005", "arena-player-00000006"]
## "HeadMid" is no bone: the middle of the drawn head, half way from the Head bone (its base) to the top of the mesh
## along the head's own up, so a shot at the face is asserted and not only one at the neck.
const CORE: Array[String] = ["HeadMid", "Head", "Neck", "Torso", "Abdomen", "Hips"]
const ARMS: Array[String] = ["UpperArm.L", "UpperArm.R"]
## name, move, crouch, pitch, whether the arms must be inside a zone too. Not when strafing:
## seen side-on, the far shoulder joint swings to the torso capsule's edge (7-11 of 64 ticks
## miss by a few centimetres), and not crouched, where the arms ride outside the squeezed capsule.
const CASES: Array = [
	["idle", Vector2.ZERO, false, 0.0, true],
	["walk away", Vector2(0, -1), false, 0.0, true],
	["strafe", Vector2(1, 0), false, 0.0, false],
	["walk at", Vector2(0, 1), false, 0.0, true],
	["aim down", Vector2(0, 1), false, -10.0, true],
	["aim up", Vector2(0, 1), false, 10.0, true],
	["crouch", Vector2.ZERO, true, 0.0, false],
	["crouch walk", Vector2(1, 0), true, 0.0, false],
]

var _game: ArenaGame = null
## The last [method _measure]'s pose numbers: mean knee angle (degrees, 180 straight), drawn head bone and head zone
## centre over the feet (metres), averaged over the sampled ticks.
var _pose := {}
## Metres from the Head bone to the drawn head's middle, measured on the rest pose by [method _wear].
var _head_mid := 0.0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	Engine.physics_ticks_per_second = 64
	_run.call_deferred()


func _run() -> void:
	print("arena: the drawn figure stands inside the hit zones at %d m" % int(RANGE_M))
	_build()
	var target: ArenaPlayer = _game.player_for(2)
	for key in AVATARS:
		_wear(target, key)
		if not _check(target.figure != null, "%s has a figure" % key):
			continue
		for case: Array in CASES:
			var misses := await _measure(target, case)
			print("  %s %s: knee %.0f deg, head bone %.3f m (middle +%.3f), head zone %.3f m (zone - bone %+.3f)" % [key, case[0],
				_pose.knee, _pose.head, _head_mid, _pose.zone, _pose.zone - _pose.head])
			_check(misses.is_empty(), "%s %s: every shot at the drawn body lands in a zone" % [key, case[0]], str(misses))
	_report()
	get_tree().quit(0 if _failed == 0 else 1)


func _build() -> void:
	_game = ArenaGame.new()
	_game.name = "Arena"
	_game.tick_rate = 64
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	add_child(_game)
	var map := ArenaMap.new()
	map.id = &"fit_lane"
	map.display_name = "fit_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p: RefCounted = map.add_perimeter()
	var _s1: RefCounted = map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2: RefCounted = map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	var _r := _game.setup(map)
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var _a := _game.add_player(1, "Shooter")
	var _b := _game.add_player(2, "Target")
	_game.start(0)
	_game.tick({})


func _wear(target: ArenaPlayer, key: String) -> void:
	if target.body_mesh != null:
		target.remove_child(target.body_mesh)
		target.body_mesh.free()
		target.body_mesh = null
		target.figure = null
		target.held = null
	target.attach_body_mesh(Color.WHITE, ArenaAvatars.stock_avatar(StringName(key)))
	_head_mid = 0.0
	if target.figure == null:
		return
	var sk: Skeleton3D = target.figure.skeleton()
	var head := sk.find_bone("Head")
	if head < 0:
		return
	var top := -INF
	for mi: MeshInstance3D in target.figure.find_children("*", "MeshInstance3D", true, false):
		top = maxf(top, (mi.global_transform * mi.get_aabb()).end.y)
	_head_mid = maxf(0.0, (top - (sk.global_transform * sk.get_bone_global_rest(head)).origin.y) * 0.5)


## Bone -> "missed n of m" for every bone a shot from [constant RANGE_M] at missed at least once.
func _measure(target: ArenaPlayer, case: Array) -> Dictionary:
	var t: int = _game._tick
	target.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, -RANGE_M)), t)
	_game.player_for(1).spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)), t)
	var eye := Vector3(0.0, 0.05 + ArenaPlayer.eye_height(), 0.0)
	var bones: Array[String] = CORE.duplicate()
	if case[4]:
		bones.append_array(ARMS)
	var missed := {}
	var knee_sum := 0.0
	var head_sum := 0.0
	var zone_sum := 0.0
	for i in WARMUP_TICKS + SAMPLE_TICKS:
		var cmd := DotFpsCommand.new()
		cmd.move = case[1]
		cmd.buttons = DotFpsCommand.BUTTON_CROUCH if case[2] else 0
		cmd.pitch = case[3]
		_game.tick({1: [DotFpsCommand.new(), DotWeaponCommand.new()], 2: [cmd, DotWeaponCommand.new()]})
		target.present(1.0 / 64.0)
		await get_tree().physics_frame
		if i < WARMUP_TICKS:
			continue
		var sk: Skeleton3D = target.figure.skeleton()
		var boxes: Array = target.hitboxes.hitboxes()
		var feet_y := target.global_position.y
		knee_sum += (_knee(sk, ".L") + _knee(sk, ".R")) * 0.5
		head_sum += (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Head")).origin).y - feet_y
		for b: DotHitbox in boxes:
			if b.group == DotHitGroup.HEAD:
				zone_sum += b.global_position.y - feet_y
				break
		for bone in bones:
			var bi := sk.find_bone("Head" if bone == "HeadMid" else bone)
			if bi < 0:
				continue
			var at: Transform3D = sk.global_transform * sk.get_bone_global_pose(bi)
			var p: Vector3 = at.origin
			if bone == "HeadMid":
				p += at.basis.y.normalized() * _head_mid
			var dir := (p - eye).normalized()
			var hit := false
			for b: DotHitbox in boxes:
				var h = b.intersect_ray(eye, dir, RANGE_M * 2.0)
				if h.hitbox != null:
					hit = true
					break
			if not hit:
				missed[bone] = int(missed.get(bone, 0)) + 1
	_pose = {"knee": knee_sum / SAMPLE_TICKS, "head": head_sum / SAMPLE_TICKS, "zone": zone_sum / SAMPLE_TICKS}
	var out := {}
	for bone: String in missed:
		out[bone] = "%d/%d" % [missed[bone], SAMPLE_TICKS]
	return out


## The knee's inside angle in degrees (180 a straight leg, 90 square), from the drawn hip, knee and ankle. The ankle is
## the shin's end (where the foot sits on it at rest): the Foot bones hang off the root, so their origin is no joint.
static func _knee(sk: Skeleton3D, side: String) -> float:
	var hip := sk.find_bone("UpperLeg" + side)
	var knee := sk.find_bone("LowerLeg" + side)
	var foot := sk.find_bone("Foot" + side)
	if hip < 0 or knee < 0 or foot < 0:
		return 0.0
	var shin := sk.get_bone_global_pose(knee)
	var ankle: Vector3 = shin * (sk.get_bone_global_rest(knee).affine_inverse() * sk.get_bone_global_rest(foot).origin)
	return rad_to_deg((sk.get_bone_global_pose(hip).origin - shin.origin).angle_to(ankle - shin.origin))
