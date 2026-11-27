extends GSGameCheckSuite

## Shift sprints: a player holding sprint runs faster than one running, on the GDScript motor, the native motor tick
## and with the speed rewritten between ticks (the effects and the carrier slowdown do that and drop the native tunables cache).

const FcPlayer := preload("../game/fc_player.gd")
const FcBindings := preload("../game/fc_bindings.gd")
const STEP := 1.0 / 33.0


var _world: Node3D


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_world = Node3D.new()
	add_child(_world)
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 2.0, 400.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0.0, -1.0, 0.0)
	_world.add_child(floor_body)
	_run.call_deferred()


func _speed(native: bool, buttons: int, rewrite_speed: bool) -> float:
	GSFpsMotor.native_tick = native
	GSFpsMotor.native_full = native
	GSFpsPhysicsBody.native_enabled = native
	var t := FcPlayer.fc_tunables()
	var body: GSFpsBody = GSFpsPhysicsBody.for_node(_world) if native else GSFpsFlatBody.with_floor(0.0)
	var motor := GSFpsMotor.new(t, body)
	var s := GSFpsState.new()
	s.mode = GSFpsState.Mode.GROUND
	var c := GSFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	c.buttons = buttons
	for i in 120:
		if rewrite_speed:
			t.max_speed = 5.74 + (0.5 if i % 2 == 0 else 0.0)
		motor.simulate(s, c, STEP)
	return Vector2(s.velocity.x, s.velocity.z).length()


## The server's loop: the motor ticked through [GSFpsMotorBatch] with a hull world, as FcServer runs its players.
func _batched(buttons: int) -> float:
	GSFpsMotor.native_tick = true
	GSFpsMotor.native_full = true
	GSFpsPhysicsBody.native_enabled = true
	var t := FcPlayer.fc_tunables()
	var physics := GSFpsPhysicsBody.for_node(_world)
	var body: GSFpsBody = GSFpsHullBody.new().wrap(physics, func() -> Array: return [])
	var world: Object = ClassDB.instantiate(&"GSSimHullWorld")
	body.set_hull_world(world, 0)
	var motor := GSFpsMotor.new(t, body)
	var s := GSFpsState.new()
	s.mode = GSFpsState.Mode.GROUND
	var c := GSFpsCommand.new()
	c.move = Vector2(0.0, 1.0)
	c.buttons = buttons
	var batch := GSFpsMotorBatch.new()
	for i in 120:
		var p := s.position
		world.begin(PackedInt64Array([100]), PackedFloat64Array([p.x, p.y, p.z, t.radius, t.stand_height, 7]), Callable(), 1.0e9)
		batch.start(STEP)
		var row := batch.add(motor, s, c)
		var told := batch.finish(row)
		if not told:
			world.moved(0, s.position.x, s.position.y, s.position.z)
		world.end()
	return Vector2(s.velocity.x, s.velocity.z).length()


## The key path: the game's own binding table on its defaults, Shift held, through the sampler the client uses.
func _shift_sprints() -> void:
	var keys := FcBindings.make()
	for row in keys.rows:
		keys.apply_row(row, str(row["default"]))
	var t := FcPlayer.fc_tunables()
	var sampler := GSFpsSampler.new(t)
	var key := InputEventKey.new()
	key.physical_keycode = KEY_SHIFT
	key.keycode = KEY_SHIFT
	key.pressed = true
	_check(InputMap.event_is_action(key, FcBindings.DASH), "Shift is the Dash row's key on the defaults")
	Input.action_press(FcBindings.DASH)
	Input.action_press(&"gs_fps_forward")
	var command := sampler.sample(STEP)
	Input.action_release(FcBindings.DASH)
	Input.action_release(&"gs_fps_forward")
	_check(command.is_pressed(GSFpsCommand.BUTTON_SPRINT) and command.move != Vector2.ZERO,
		"holding the Dash action while moving puts the sprint bit on the command", "buttons %d move %s" % [command.buttons, command.move])


func _run() -> void:
	_shift_sprints()
	if ClassDB.class_exists(&"GSSimHullWorld"):
		var brun := _batched(0)
		var bsprint := _batched(GSFpsCommand.BUTTON_SPRINT)
		_check(bsprint > brun * 1.15, "sprint beats run through the server's batch", "%.2f vs %.2f" % [bsprint, brun])
	print("fc: sprint is faster than a run")
	for native: bool in [false, true]:
		for rewrite: bool in [false, true]:
			var run := _speed(native, 0, rewrite)
			var sprint := _speed(native, GSFpsCommand.BUTTON_SPRINT, rewrite)
			_check(sprint > run * 1.15, "sprint beats run (native %s, rewrites %s)" % [native, rewrite], "%.2f vs %.2f" % [sprint, run])
	_report()
	get_tree().quit(0 if _failed == 0 else 1)
