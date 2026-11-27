extends GSGameCheckSuite

## Shift sprints: a player holding sprint runs faster than one running, on the GDScript motor, the native motor tick
## and with the speed rewritten between ticks (the effects and the carrier slowdown do that and drop the native tunables cache).

const FcPlayer := preload("../game/fc_player.gd")
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


func _run() -> void:
	print("fc: sprint is faster than a run")
	for native: bool in [false, true]:
		for rewrite: bool in [false, true]:
			var run := _speed(native, 0, rewrite)
			var sprint := _speed(native, GSFpsCommand.BUTTON_SPRINT, rewrite)
			_check(sprint > run * 1.15, "sprint beats run (native %s, rewrites %s)" % [native, rewrite], "%.2f vs %.2f" % [sprint, run])
	_report()
	get_tree().quit(0 if _failed == 0 else 1)
