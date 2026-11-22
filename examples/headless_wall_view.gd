extends GSGameCheckSuite

## Walking into walls never snaps the first-person view. A wall-dense map (brick walls, steps) with the
## auto wall run on touched a wall in the air and turned the view along it, up to 180 degrees each
## time (nightly fc-native-via-gs-app-1: the camera "spazzed", the yaw jumping tens of degrees every
## ~0.1 s). The probe drives a jumping player through a field of walls at many headings and records
## every `view_turn` the motor asks the camera for and the wall-run starts.

const FcPlayer := preload("../game/fc_player.gd")
const STEP := 1.0 / 66.0
const HEADINGS := 24
const SECONDS := 4.0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


## A corridor of two long walls 8 m apart, with a stair of low boxes along one side: heading off its axis at
## speed, a player in the air touches a wall every few tenths of a second.
func _world() -> GSFpsFlatBody:
	var w := GSFpsFlatBody.with_floor(0.0)
	w.add_box(AABB(Vector3(4.0, 0.0, -400.0), Vector3(0.5, 12.0, 800.0)))
	w.add_box(AABB(Vector3(-4.5, 0.0, -400.0), Vector3(0.5, 12.0, 800.0)))
	for s in 10:
		w.add_box(AABB(Vector3(-4.0, 0.0, -40.0 - s * 1.5), Vector3(1.2, 0.3 * (s + 1), 1.5)))
	return w


func _cmd(forward: float, jump: bool, yaw: float) -> GSFpsCommand:
	var c := GSFpsCommand.new()
	c.yaw = yaw
	c.move = Vector2(0.0, forward)
	c.buttons = GSFpsCommand.BUTTON_JUMP if jump else 0
	return c


## What a run of [param t] through [method _world] did: view turns, wall-run starts, the largest turn.
func _probe(t: GSFpsTunables) -> Dictionary:
	var motor := GSFpsMotor.new(t, _world())
	var turns := 0
	var runs := 0
	var worst := 0.0
	for h in HEADINGS:
		var s := GSFpsState.new()
		s.position = Vector3(0.0, 1.5, 0.0)
		# Yaw 0 looks down -Z, the corridor's axis; the headings fan 5 to 60 degrees to either side of it.
		var off := (5.0 + float(h / 2) * 5.0) * (1.0 if h % 2 == 0 else -1.0)
		s.yaw = off
		s.velocity = Vector3(-sin(deg_to_rad(off)), 0.0, -cos(deg_to_rad(off))) * 9.0
		s.mode = GSFpsState.Mode.AIR
		s.time_since_grounded = 1.0
		var was_running := false
		for i in int(SECONDS / STEP):
			# Bunny-hop forward: a jump every half second, so most touches are in the air.
			motor.simulate(s, _cmd(1.0, i % 33 == 0, s.yaw), STEP)
			if motor.view_turn != 0.0:
				turns += 1
				worst = maxf(worst, absf(motor.view_turn))
				s.yaw += motor.view_turn
			if s.is_wall_running() and not was_running:
				runs += 1
			was_running = s.is_wall_running()
	return {"turns": turns, "runs": runs, "worst": worst}


func _run() -> void:
	print("arena: the view is never snapped by a wall")
	var shipped := FcPlayer.fc_tunables()
	_check(not shipped.wall_run_turn_view, "the shipped tunables do not turn the view on a wall run")
	_check(shipped.wall_run_turn_view_max_angle <= 90.0, "a turn, if a server turns it on, is at most 90 degrees (%.0f)" % shipped.wall_run_turn_view_max_angle)
	_check(FcPlayer.MOVEMENT_RULES.has("wall_run_turn_view"), "wall_run_turn_view travels in RULES, so a client predicts what the server does")

	# The old shipped settings, for the numbers that explain the bug.
	var old := FcPlayer.fc_tunables()
	old.wall_run_turn_view = true
	old.wall_run_turn_view_max_angle = 180.0
	var before := _probe(old)
	print("  measured: old settings (turn view on, 180): %d turns, %d wall runs, worst turn %.0f degrees" % [before.turns, before.runs, before.worst])

	var now := _probe(shipped)
	print("  measured: shipped settings: %d turns, %d wall runs, worst turn %.0f degrees" % [now.turns, now.runs, now.worst])
	_check(now.runs > 0, "the field makes wall runs start (the probe reaches walls)", "%d runs" % now.runs)
	_check(now.turns == 0, "no view turn is asked of the camera with the shipped tunables", "%d turns" % now.turns)

	var capped := FcPlayer.fc_tunables()
	capped.wall_run_turn_view = true
	var opted := _probe(capped)
	print("  measured: opted in at the default angle: %d turns, worst %.0f degrees" % [opted.turns, opted.worst])
	_check(opted.worst <= shipped.wall_run_turn_view_max_angle + 0.5, "an operator who turns it on still gets at most the capped angle", "worst %.1f" % opted.worst)
	_report()
	get_tree().quit(0 if _failed == 0 else 1)
