extends GSGameCheckSuite

const FcPlayerIdle := preload("../game/fc_player_idle.gd")

## An idle weapon tick's posture row and flinch check (FcPlayerIdle._idle_row, cvar `fc_posture_native`): gs-sim's
## `GSSimPlayerPost` gives the script's row and still flag to the bit over seeded controller states (moving, air,
## crouch edges, slide, wall run, sprint, hurt ticks around the flinch window, arsenal rates and none, no health),
## one player at a time and as packed rows (`run_rows`). Without the library only the script lane runs, and the suite
## says so.

const STATES := 20000
const SEED := 4242

var _body: FcPlayerIdle
var _controller: GSFpsController
var _health: GSHealth
var _arsenal: GSWeaponArsenal


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC — idle posture row: native and script agree")
	_body = FcPlayerIdle.new()
	_controller = GSFpsController.new()
	_health = GSHealth.new()
	_arsenal = GSWeaponArsenal.new()
	_body.controller = _controller
	var native := GSSim.has(&"players")
	if not native:
		print("gs-sim has no players module: only the script lane is exercised")
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var row_diff := 0
	var still_diff := 0
	var lane_diff := 0
	var stills := 0
	var first := ""
	var input := PackedFloat64Array()
	var want := PackedFloat64Array()
	for i in STATES:
		var last := _randomize(rng)
		FcPlayerIdle.posture_native = false
		var still := bool(_body._idle_row_script())
		var row: PackedFloat64Array = _body._posture_row.duplicate()
		stills += 1 if still else 0
		want.append_array(row)
		want.append(1.0 if still else 0.0)
		var state := _controller.state
		input.append_array([state.velocity.x, state.velocity.z, state.mode, state.crouch_fraction, state.slide_time,
				state.wall_run_time, 1.0 if state.sprinting else 0.0, _body._posture_tick, last,
				_body.arsenal.tick_rate if _body.arsenal != null else 0])
		if not native:
			continue
		FcPlayerIdle.posture_native = true
		var got_still := bool(_body._idle_row())
		var got: PackedFloat64Array = _body._posture_row
		if got.size() != 10 or got.slice(0, 9).to_byte_array() != row.to_byte_array():
			row_diff += 1
			if first == "":
				first = "state %d: script %s native %s" % [i, row, got]
		if got_still != still:
			still_diff += 1
			if first == "":
				first = "state %d: script still %s native %s (row %s)" % [i, still, got_still, row]
		if got.size() == 10 and (got[9] != 0.0) != got_still:
			lane_diff += 1
	FcPlayerIdle.posture_native = true
	print("  %d states, %d still" % [STATES, stills])
	_check(stills > STATES / 20 and stills < STATES - STATES / 20, "the seeded states are both still and not", "%d" % stills)
	if native:
		_check(row_diff == 0, "native rows equal the script's to the bit", "%d differ; %s" % [row_diff, first])
		_check(still_diff == 0, "native still flags equal the script's", "%d differ; %s" % [still_diff, first])
		_check(lane_diff == 0, "the still flag is the row's tenth float")
		var post: Object = ClassDB.instantiate(&"GSSimPlayerPost")
		post.configure(GSFpsState.Mode.GROUND, GSWeaponAccuracyClass.FLINCH_SEC)
		var rows: PackedFloat64Array = post.run_rows(input)
		_check(rows.to_byte_array() == want.to_byte_array(), "run_rows over the packed columns equals the script, row for row",
				"%d floats, want %d" % [rows.size(), want.size()])
	_body.free()
	_controller.free()
	_health.free()
	_arsenal.free()
	_report(5 if native else 1)


## One seeded state on [member _body]; returns the last hurt tick the native lane is given.
func _randomize(rng: RandomNumberGenerator) -> int:
	var state := _controller.state
	var moving := rng.randf() < 0.3
	state.velocity = Vector3(rng.randf_range(-12.0, 12.0), rng.randf_range(-5.0, 5.0), rng.randf_range(-12.0, 12.0)) \
			if moving else Vector3(0.0, rng.randf_range(-1.0, 1.0) if rng.randf() < 0.2 else 0.0, 0.0)
	if rng.randf() < 0.05:
		state.velocity.x = 1e-30 * rng.randf()
	state.mode = GSFpsState.Mode.GROUND if rng.randf() < 0.8 else rng.randi_range(0, 2)
	state.crouch_fraction = ([0.0, 0.0, 0.0, 0.0, 0.001, 0.0011, rng.randf()] as Array[float])[rng.randi_range(0, 6)]
	state.slide_time = -1.0 if rng.randf() < 0.85 else ([0.0, rng.randf()] as Array[float])[rng.randi_range(0, 1)]
	state.wall_run_time = -1.0 if rng.randf() < 0.85 else ([0.0, rng.randf()] as Array[float])[rng.randi_range(0, 1)]
	state.sprinting = rng.randf() < 0.1
	var tick := rng.randi_range(0, 2000000)
	_body._posture_tick = tick
	_body.arsenal = null if rng.randf() < 0.2 else _arsenal
	_arsenal.tick_rate = ([1, 30, 64, 65, 66, 100, 128, 240] as Array[int])[rng.randi_range(0, 7)]
	_body.health = null if rng.randf() < 0.1 else _health
	var near := rng.randi_range(-3, 3) + ([26, 27, 52, 53, 96] as Array[int])[rng.randi_range(0, 4)]
	var last: int = ([-1000000, -1, 0, tick - near, tick - near, tick - near, tick + 1, tick, tick - 5000] as Array[int])[rng.randi_range(0, 8)]
	_health.last_damage_tick = last
	return last if _body.health != null else -1
