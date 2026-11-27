extends RefCounted

## FC's native server tick (phase P1): gs-sim's `GSSimServerTick` stepped once per tick, after the batched players' loop.
##
## It holds the struct-of-arrays player table later phases read instead of asking each player per field: the roster
## in order (the hull world's slots), each row's motor part taken from the motor batch's resident row and its origin
## from the hull world's feet. The players' loop hands it the motor batch ([method GSFpsMotorBatch.use_native]) and
## its idle posture rows (`run_rows`, the same to the bit as `GSSimPlayerPost`), so nothing is computed twice.
##
## [member enabled] is `sv_native_motor_state`. Off, or without the library, the loop runs as before. A library that is
## present but lacks the class, a method or the API level is said loudly once, never skipped in silence.

## The `GSSimServerTick` API level this needs.
const API := 1
## gs-player-controller's level with [method GSFpsMotorBatch.use_native].
const GSPC_LEVEL := 51
const FcPlayer := preload("fc_player.gd")
const CLASS := &"GSSimServerTick"
const METHODS: Array[StringName] = [&"configure", &"motor", &"bind_world", &"begin", &"run_rows", &"step", &"table", &"digest", &"events", &"counters"]

## `sv_native_motor_state`: 1 steps the native tick (with `fc_motor_batch`); 0 the script loop alone.
static var enabled := true
## Ticks stepped natively since start (the suites check it moved).
static var steps := 0

static var _checked := false
static var _ok := false

## The `GSSimServerTick` (null until [method start] first answers true).
var native: Object = null
var _begin_rows := PackedFloat64Array()
var _world: Object = null
var _motor: Object = null


## Whether the library has a usable server tick. Checked once; says what is missing when the library is there.
static func available() -> bool:
	if _checked:
		return _ok
	_checked = true
	if not GSSim.has(&"motor"):
		return false
	var missing: Array[String] = []
	if not ClassDB.class_exists(CLASS):
		missing.append("class %s" % CLASS)
	else:
		for m in METHODS:
			if not ClassDB.class_has_method(CLASS, m):
				missing.append("%s.%s" % [CLASS, m])
		if missing.is_empty():
			var api: int = ClassDB.class_get_integer_constant(CLASS, &"API")
			if api < API:
				missing.append("%s API %d (have %d)" % [CLASS, API, api])
	var level := GSAddonApi.build_level("gs_player_controller")
	if level < GSPC_LEVEL:
		missing.append("gs_player_controller level %d (have %d)" % [GSPC_LEVEL, level])
	if not missing.is_empty():
		push_error("FcNativeTick: sv_native_motor_state 1 needs %s; the script loop runs instead" % ", ".join(missing))
		return false
	_ok = true
	return true


## Whether this tick runs natively; hands [param batch] the tick's resident motor batch (or takes it back when off).
func start(batch: GSFpsMotorBatch) -> bool:
	if not (enabled and available()):
		if _motor != null and batch.native() == _motor:
			var _taken := batch.use_native(null)
		return false
	if native == null:
		native = ClassDB.instantiate(CLASS)
		native.call(&"configure", GSFpsState.Mode.GROUND, GSWeaponAccuracyClass.FLINCH_SEC)
		_motor = native.call(&"motor")
	if batch.native() != _motor:
		var _used := batch.use_native(_motor)
	return true


## Ends the players' loop: the roster's begin rows (after the loop, so each motor's resident slot is this tick's),
## the hull world bound, one native step [param delta] long.
func step(roster: Array[FcPlayer], ids: PackedInt64Array, hull_world: Object, delta: float) -> void:
	var n := roster.size()
	var stride := 5
	if _begin_rows.size() != n * stride:
		var _r := _begin_rows.resize(n * stride)
	for i in range(n):
		var p := roster[i]
		var o := i * stride
		_begin_rows[o] = float(ids[i])
		if p == null or p.controller == null or p.health == null:
			_begin_rows[o + 1] = -1.0
			_begin_rows[o + 2] = 0.0
			_begin_rows[o + 3] = 0.0
		else:
			_begin_rows[o + 1] = float(p.controller.motor.batch_slot)
			_begin_rows[o + 2] = 1.0 if p.health.alive else 0.0
			_begin_rows[o + 3] = p.health.health
		_begin_rows[o + 4] = 0.0
	native.begin(_begin_rows)
	if hull_world != _world:
		_world = hull_world
		native.bind_world(hull_world)
	var _rows: int = native.step(delta)
	steps += 1
