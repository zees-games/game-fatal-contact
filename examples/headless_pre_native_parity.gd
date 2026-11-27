extends GSGameCheckSuite

const FcPlayer := preload("../game/fc_player.gd")

## The players' loop pre-motor pass (cvar `fc_pre_native`): gs-sim's `GSSimServerTick.pre` (API 6) answers
## FcPlayerBody.body_delta's gate and tick_pre's ladder wish to the bit over seeded bodies (gaps in and out of range,
## body_every, button edges, pushes, air, slide, wall run, yaws past a turn, zero moves), applied through
## pre_apply onto the same body fields the script writes. The inlined ladder wish is checked against
## GSFpsMotor._view_basis too. Without the library only the script checks run, and the suite says so.

const STATES := 20000
const SEED := 2711

var _body: FcPlayer
var _controller: GSFpsController


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC — players' pre-motor pass: native and script agree")
	_body = FcPlayer.new()
	_controller = GSFpsController.new()
	_body.controller = _controller
	var st: Object = null
	if FcPlayer.body_cols and ClassDB.class_exists(&"GSSimServerTick") and ClassDB.class_has_method(&"GSSimServerTick", &"pre"):
		st = ClassDB.instantiate(&"GSSimServerTick")
		st.call(&"configure", GSFpsState.Mode.GROUND, 0.4)
	else:
		print("SKIP native lane: gs-sim has no GSSimServerTick.pre (API 6) or body_cols is off; only the script checks run")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var wish_diff := 0
	var diff := 0
	var first := ""
	var kinds := [0, 0, 0]
	var rows := PackedFloat64Array()
	rows.resize(FcPlayer.PRE_IN)
	var cmd := GSFpsCommand.new()
	for i in STATES:
		var tick := _randomize(rng, cmd)
		var s := _controller.state
		var last := _body.body_last_tick
		var s_tick := s.tick
		var s_pitch := s.pitch
		var s_yaw := s.yaw
		_body._yaw_before_tick = s_yaw
		# The view basis the script built before the inlined wish.
		var view := GSFpsMotor._view_basis(s_yaw, 0.0)
		var intent: Vector3 = view.right * cmd.move.x + view.forward * cmd.move.y
		var wish_ref := Vector3(intent.x, 0.0, intent.z).normalized()
		var wish := FcPlayer.ladder_wish(s_yaw, cmd.move)
		if var_to_bytes(wish) != var_to_bytes(wish_ref):
			wish_diff += 1
			if first == "":
				first = "state %d: wish %s view basis %s" % [i, wish, wish_ref]
		var skipped := FcPlayer.body_skipped
		var d := _body.body_delta(tick, 1.0 / 64.0, cmd)
		var want := [d, _body.body_last_tick, s.tick, s.pitch, s.yaw, FcPlayer.body_skipped - skipped, wish]
		kinds[0 if last < 0 or tick - last <= 0 or tick - last > FcPlayer.BODY_MAX_GAP else (2 if d == 0.0 else 1)] += 1
		if st == null:
			continue
		_body.body_last_tick = last
		s.tick = s_tick
		s.pitch = s_pitch
		s.yaw = s_yaw
		_body._pre_move = cmd.move
		_body.pre_row(rows, 0, tick, 1.0 / 64.0, cmd)
		var out: PackedFloat64Array = st.call(&"pre", rows, 1, FcPlayer.BODY_MAX_GAP)
		skipped = FcPlayer.body_skipped
		var got_d := _body.pre_apply(out, 0, tick, cmd)
		var got := [got_d, _body.body_last_tick, s.tick, s.pitch, s.yaw, FcPlayer.body_skipped - skipped, _body.ladder.wish]
		if var_to_bytes(got) != var_to_bytes(want):
			diff += 1
			if first == "":
				first = "state %d: script %s native %s" % [i, want, got]
	print("  %d states: %d reset, %d run, %d skip" % [STATES, kinds[0], kinds[1], kinds[2]])
	_check(kinds[0] > 0 and kinds[1] > STATES / 10 and kinds[2] > STATES / 10, "the seeded bodies reset, run and skip", str(kinds))
	_check(wish_diff == 0, "the inlined ladder wish equals GSFpsMotor._view_basis's to the bit", "%d differ; %s" % [wish_diff, first])
	if st != null:
		_check(diff == 0, "native gate, delta, view writes and wish equal the script's to the bit", "%d differ; %s" % [diff, first])
	_body.free()
	_controller.free()
	_report(3 if st != null else 2)


## One seeded body and command; returns the tick.
func _randomize(rng: RandomNumberGenerator, cmd: GSFpsCommand) -> int:
	var s := _controller.state
	var tick := rng.randi_range(0, 100000)
	_body.body_last_tick = ([-1, tick, tick + 1, tick - 9, tick - 1, tick - 1, tick - 2, tick - 3, tick - 8] as Array[int])[rng.randi_range(0, 8)]
	_body.body_every = rng.randi_range(1, 4)
	s.mode = GSFpsState.Mode.GROUND if rng.randf() < 0.85 else rng.randi_range(0, 3)
	s.slide_time = -1.0 if rng.randf() < 0.9 else ([0.0, rng.randf()] as Array[float])[rng.randi_range(0, 1)]
	s.wall_run_time = -1.0 if rng.randf() < 0.9 else ([0.0, rng.randf()] as Array[float])[rng.randi_range(0, 1)]
	s.previous_buttons = rng.randi_range(0, 7)
	s.yaw = rng.randf_range(-1000.0, 1000.0)
	s.pitch = rng.randf_range(-89.0, 89.0)
	s.tick = rng.randi_range(0, 100000)
	_controller._external_velocity = Vector3(0.0, 3.0, 0.0) if rng.randf() < 0.05 else Vector3.ZERO
	cmd.buttons = s.previous_buttons if rng.randf() < 0.85 else rng.randi_range(0, 7)
	cmd.yaw = rng.randf_range(-1000.0, 1000.0)
	cmd.pitch = rng.randf_range(-89.0, 89.0)
	cmd.move = Vector2.ZERO if rng.randf() < 0.15 else Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
	return tick
