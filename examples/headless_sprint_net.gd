extends "headless_lossy.gd"

## Holding the sprint bit with the game's own settings (no stamina, no dash cvar) runs faster than a run, on the server's
## player and on A's own copy, and A's prediction agrees with the server while it does. Boots one real server and client.
const SPRINT_SECTIONS := 3


func _run() -> void:
	print("game-fatal-contact: sprint over a real server and a real ENet client")
	GSPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE
	if await _boot():
		if await _connect_everyone():
			await _measured(_test_default_sprint)
	await _teardown()
	GSPaths.remove_tree(DATA)
	_report_sections(_entered, _completed, SPRINT_SECTIONS, -1)


func _horizontal(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _test_default_sprint() -> void:
	_section("sprint with the game's defaults")
	var a: Dictionary = _clients["A"]
	var net: GSNetManager = a["net"]
	var session := int(a["session"])
	var server_a := _game.player_for(session)
	var own: FcPlayer = (a["game"] as FcGame).player_for(session)
	if not _check(server_a != null and own != null, "A is on both ends to sprint with"):
		_done()
		return
	_check(not server_a.controller.tunables.stamina_enabled and not server_a.controller.tunables.dash_enabled,
		"the server's A has no stamina and no dash, as shipped")
	_check(own.controller.tunables.can_sprint and own.controller.tunables.sprint_speed_scale > 1.1,
		"A's own tunables let it sprint (scale %.2f)" % own.controller.tunables.sprint_speed_scale)
	var run_speed := server_a.controller.tunables.max_speed
	var top := {"server": 0.0, "client": 0.0}
	_stam_from = net.clock.input_tick() + 4
	var from := _stam_from
	var until := Engine.get_physics_frames() + 6 * Engine.physics_ticks_per_second
	while Engine.get_physics_frames() < until:
		await get_tree().physics_frame
		top["server"] = maxf(top["server"], _horizontal(server_a.controller.state.velocity))
		top["client"] = maxf(top["client"], _horizontal(own.controller.state.velocity))
	var last := net.clock.input_tick()
	_stam_from = -1
	await _wait_game(0.5)
	_stam_from = from
	var open: Array = _prediction_gap(session, from, last, _excused(_edge_holes(from, last, _command_a), net))
	_stam_from = -1
	print("    run %.2f m/s; sprint reached %.2f on the server, %.2f on A; prediction p95 %.3f over %d ticks" % [
		run_speed, top["server"], top["client"], open[1], open[0]])
	_check(top["server"] > run_speed * 1.15, "the server's A sprints faster than a run", "%.2f vs %.2f" % [top["server"], run_speed])
	_check(top["client"] > run_speed * 1.15, "A's own copy sprints faster than a run", "%.2f vs %.2f" % [top["client"], run_speed])
	_check(open[0] > 3 * Engine.physics_ticks_per_second and open[1] >= 0.0 and open[1] <= 0.05,
		"A's prediction of the sprint is within 5 cm for 95% of its ticks", "%d ticks, p95 %.3f" % [open[0], open[1]])
	_done()
