extends RefCounted

## The crouch and slide blend on a REMOTE player's copy (no local prediction: a networked state drawn by present()):
## the figure's crouch amount lerps over a short time and the head glides down with no pop, and once settled the drawn head
## is inside the hit zones, crouched and sliding (a slide must not draw the head on the floor, under the zones).

const FcPlayer := preload("../game/fc_player.gd")

const RANGE_M := 65.0
## The most a head may move in one 64 Hz tick while changing stance (metres): a pop is well over this.
const MAX_STEP := 0.05

var suite: DotGameCheckSuite
var game: Node


func _init(p_suite: DotGameCheckSuite, p_game: Node) -> void:
	suite = p_suite
	game = p_game


func run(target: FcPlayer, tag: String) -> void:
	var eye := Vector3(0.0, 0.05 + FcPlayer.eye_height(), 0.0)
	for slide in [false, true]:
		var label := "%s %s" % [tag, "slide" if slide else "crouch"]
		var t: int = game._tick
		target.spawn(Transform3D(Basis(), Vector3(0.0, 0.05, -RANGE_M)), t)
		game.player_for(1).spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)), t)
		var last := INF
		var worst := 0.0
		var amounts: Array[float] = []
		var inside := 0
		var settled := 0
		var stand_head := 0.0
		var lowest := INF
		for i in 40 + 90:
			var cmd := DotFpsCommand.new()
			cmd.move = Vector2(0, 1) if slide else Vector2.ZERO
			cmd.buttons = DotFpsCommand.BUTTON_SPRINT if slide else 0
			if i >= 40:
				cmd.buttons |= DotFpsCommand.BUTTON_CROUCH
			game.tick({1: [DotFpsCommand.new(), DotWeaponCommand.new()], 2: [cmd, DotWeaponCommand.new()]})
			target.present(1.0 / 64.0)
			await suite.get_tree().physics_frame
			var sk: Skeleton3D = target.figure.skeleton()
			var head: Vector3 = sk.global_transform * sk.get_bone_global_pose(sk.find_bone("Head")).origin
			var h := head.y - target.global_position.y
			if i == 39:
				stand_head = h
			if i >= 40:
				amounts.append(target.figure.crouch_amount)
				worst = maxf(worst, absf(h - last))
				lowest = minf(lowest, h)
			last = h
			if i >= 40 + 70:
				settled += 1
				for b: DotHitbox in target.hitboxes.hitboxes():
					if b.intersect_ray(eye, (head - eye).normalized(), RANGE_M * 2.0).hitbox != null:
						inside += 1
						break
		var rose := absf(amounts[amounts.size() - 1] - 1.0) < 0.01 and amounts[0] < 0.5 and amounts[4] > amounts[0]
		suite._check(rose, "%s: the drawn crouch amount lerps up to 1 (%.2f, %.2f, %.2f)" % [label, amounts[0], amounts[4], amounts[-1]])
		suite._check(worst < MAX_STEP, "%s: the head glides down, at most %.3f m a tick (stood at %.2f, now %.2f)" % [label, worst, stand_head, last])
		suite._check(lowest < stand_head - 0.1, "%s: the head goes lower than standing (%.2f to %.2f)" % [label, stand_head, lowest])
		suite._check(settled > 0 and inside == settled, "%s: the drawn head is inside a hit zone once settled (%d of %d ticks)" % [label, inside, settled])
