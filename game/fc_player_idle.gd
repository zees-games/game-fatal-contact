@tool
extends "fc_player_state.gd"

## The arsenal's [member GSWeaponArsenal.idle_posture] (set in [method _build_arsenal]): the posture fields
## of the full context [method simulate_tick] builds, from the same simulated state, so an idle tick's
## spread state matches a full tick's.
func _idle_posture() -> GSWeaponContext:
	var ctx := _posture_ctx
	ctx.tick = _posture_tick
	ctx.authority = arsenal.authority if arsenal != null else false
	if controller == null:
		return ctx
	var state := controller.state
	ctx.speed = state.horizontal_speed()
	ctx.airborne = not state.is_grounded()
	ctx.crouched = state.is_crouched()
	ctx.sliding = state.is_sliding()
	ctx.sprinting = state.sprinting
	ctx.wall_running = state.is_wall_running()
	ctx.hurt_tick = health.last_damage_tick if health != null and health.last_damage_tick >= 0 else -1
	return ctx


## The arsenal's [member GSWeaponArsenal.idle_still]: whether [method _idle_posture] is the settled one
## (still, grounded, standing, no flinch left), so a weapon with nothing to recover skips its tick.
## Erring towards false only costs a tick.
func _idle_still() -> bool:
	if controller == null:
		return true
	var state := controller.state
	if state.horizontal_speed() != 0.0 or not state.is_grounded() or state.is_crouched() or state.is_sliding() \
			or state.sprinting or state.is_wall_running():
		return false
	var hurt: int = health.last_damage_tick if health != null else -1
	if hurt < 0 or _posture_tick < hurt:
		return true
	var rate := maxi(arsenal.tick_rate, 64) if arsenal != null else 64
	return _posture_tick - hurt > ceili(GSWeaponAccuracyClass.FLINCH_SEC * float(rate))


## [method _idle_posture] as the packed row of [method AwWeaponRig.simulate_idle_row] ([code][speed, airborne, crouched, aiming, sliding, sprinting, wall_running, tick, hurt_tick][/code], aiming never set there), written into [member _posture_row], with [method _idle_still]'s answer returned: one read of the controller state for both.
## Needs a controller (the caller checks). gs-sim's [code]GSSimPlayerPost[/code] answers it where the library has it (bit for bit: [code]headless_posture_native_parity[/code]);
## [method _idle_row_script] is the fallback (web without the library, [member posture_native] off).
func _idle_row() -> bool:
	if posture_native and _post_native():
		var state := controller.state
		_posture_row = _native_post.idle_row(state.velocity, state.mode, state.crouch_fraction, state.slide_time,
				state.wall_run_time, state.sprinting, _posture_tick,
				health.last_damage_tick if health != null else -1, arsenal.tick_rate if arsenal != null else 0)
		return _posture_row[9] != 0.0
	return _idle_row_script()


## Whether [member _native_post] is there, made on first use (the library has [code]GSSimPlayerPost[/code]).
func _post_native() -> bool:
	if _native_post == null:
		if not GSSim.has(&"players"):
			return false
		_native_post = make_native_post()
	return true


## A configured gs-sim [code]GSSimPlayerPost[/code] (the library must have it: [code]GSSim.has(&"players")[/code]),
## for one player's [method _idle_row] or for FcGame's batched loop, which fills every idle player's row in one call.
static func make_native_post() -> Object:
	var post: Object = ClassDB.instantiate(&"GSSimPlayerPost")
	post.configure(GSFpsState.Mode.GROUND, GSWeaponAccuracyClass.FLINCH_SEC)
	return post


## The input row of [code]GSSimPlayerPost.run_rows[/code] for this player, 10 floats at [param at] in [param into], after [method tick_post_head] answered true. [param batch] (a [GSFpsMotorBatch] with [code]post_row[/code], API 34, or null) and [param row] are the batched loop's motor row:
## its first 7 columns come from the batch's answer ([method GSFpsMotorBatch.post_row]) unless something after the motor moved the state ([member _post_moved]); else from the state. With [member posture_verify] the row is checked here.
func post_input(into: PackedFloat64Array, at: int, batch: Object, row: int) -> void:
	var state := controller.state
	if row < 0 or _post_moved or batch == null:
		var v := state.velocity
		into[at] = v.x
		into[at + 1] = v.z
		into[at + 2] = state.mode
		into[at + 3] = state.crouch_fraction
		into[at + 4] = state.slide_time
		into[at + 5] = state.wall_run_time
		into[at + 6] = 1.0 if state.sprinting else 0.0
	else:
		batch.post_row(row, into, at)
	into[at + 7] = _posture_tick
	into[at + 8] = health.last_damage_tick if health != null else -1
	into[at + 9] = arsenal.tick_rate if arsenal != null else 0
	if posture_verify:
		_verify_input(into, at)


# The script's row from the state now against the native answer to [param into]'s row: the batched loop's
# input is the state's to the bit, or the deferred weapon tick would see another posture.
func _verify_input(into: PackedFloat64Array, at: int) -> void:
	posture_batched_rows += 1
	var still := _idle_row_script()
	var native: PackedFloat64Array = _verify_post().run_rows(into.slice(at, at + 10))
	for k in range(9):
		if native[k] != _posture_row[k]:
			posture_misses += 1
			return
	if (native[9] != 0.0) != still:
		posture_misses += 1


static func _verify_post() -> Object:
	if _verify_native == null:
		_verify_native = make_native_post()
	return _verify_native


## [method _idle_row] in script: the reference the native answer is held to, and the fallback.
func _idle_row_script() -> bool:
	if _posture_row.size() != 9:
		_posture_row = PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	var row := _posture_row
	var state := controller.state
	var speed := state.horizontal_speed()
	var grounded := state.is_grounded()
	var crouched := state.is_crouched()
	var sliding := state.is_sliding()
	var sprinting := state.sprinting
	var wall := state.is_wall_running()
	var last: int = health.last_damage_tick if health != null else -1
	var hurt := last if last >= 0 else -1
	row[0] = speed
	row[1] = 0.0 if grounded else 1.0
	row[2] = 1.0 if crouched else 0.0
	row[3] = 0.0
	row[4] = 1.0 if sliding else 0.0
	row[5] = 1.0 if sprinting else 0.0
	row[6] = 1.0 if wall else 0.0
	row[7] = _posture_tick
	row[8] = hurt
	if speed != 0.0 or not grounded or crouched or sliding or sprinting or wall:
		return false
	if hurt < 0 or _posture_tick < hurt:
		return true
	var rate := maxi(arsenal.tick_rate, 64) if arsenal != null else 64
	return _posture_tick - hurt > ceili(GSWeaponAccuracyClass.FLINCH_SEC * float(rate))


## [method _idle_posture]'s context, refilled each idle tick: a new one per idle player per tick cost
## an allocation of 21 fields and a dictionary. A behaviour's tick only reads it.
var _posture_ctx := GSWeaponContext.new()


## Cvar [code]fc_posture_native[/code]: 1 runs [method _idle_row] in gs-sim where its library has
## [code]GSSimPlayerPost[/code] (bit for bit with the script); 0 runs the script (the reference and the A/B arm).
static var posture_native := true


## Checks every row FcGame's batched loop hands gs-sim against the script ([method post_input]), counting
## [member posture_batched_rows] and [member posture_misses]. For the parity suites; off in play.
static var posture_verify := false
static var posture_batched_rows: int = 0
static var posture_misses: int = 0
static var _verify_native: Object = null


## Set by [method tick_post_head] when the map's mechanics, a ladder, water or a teleport may have moved the state
## after the motor: the batched loop then reads the post columns from the state, not the batch's answer.
var _post_moved := false


## Whether this tick's weapons would idle ([method tick_post_head]), and the muzzle it read, for [method tick_weapons].
var _idle_now := false
var _muzzle := Vector3.ZERO


## gs-sim's [code]GSSimPlayerPost[/code] for this player, or null before the first native [method _idle_row].
var _native_post: Object = null


## [method _idle_row]'s row, refilled each idle tick. The native lane hands back a new one of 10 floats (the still flag
## last); the rig reads the first 9.
var _posture_row := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])


## The tick the weapons are being simulated for, read by [method _idle_posture] (the flinch counts from it).
var _posture_tick: int = 0
