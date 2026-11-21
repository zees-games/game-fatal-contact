@tool
extends "fc_player_state.gd"

## The arsenal's [member DotWeaponArsenal.idle_posture] (set in [method _build_arsenal]): the posture fields
## of the full context [method simulate_tick] builds, from the same simulated state, so an idle tick's
## spread state matches a full tick's.
func _idle_posture() -> DotWeaponContext:
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


## The arsenal's [member DotWeaponArsenal.idle_still]: whether [method _idle_posture] is the settled one
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
	return _posture_tick - hurt > ceili(DotWeaponAccuracyClass.FLINCH_SEC * float(rate))


## [method _idle_posture] as the packed row of [method AwWeaponRig.simulate_idle_row] ([code][speed, airborne, crouched,
## aiming, sliding, sprinting, wall_running, tick, hurt_tick][/code], aiming never set there), written into
## [member _posture_row], with [method _idle_still]'s answer returned: one read of the controller state for both.
## Needs a controller (the caller checks). dot-sim's [code]DotSimPlayerPost[/code] answers it where the library has it
## (bit for bit: [code]headless_posture_native_parity[/code]); [method _idle_row_script] is the fallback (web without the
## library, [member posture_native] off).
func _idle_row() -> bool:
	if posture_native and _post_native():
		var state := controller.state
		_posture_row = _native_post.idle_row(state.velocity, state.mode, state.crouch_fraction, state.slide_time,
				state.wall_run_time, state.sprinting, _posture_tick,
				health.last_damage_tick if health != null else -1, arsenal.tick_rate if arsenal != null else 0)
		return _posture_row[9] != 0.0
	return _idle_row_script()


## Whether [member _native_post] is there, made on first use (the library has [code]DotSimPlayerPost[/code]).
func _post_native() -> bool:
	if _native_post == null:
		if not DotSim.has(&"players"):
			return false
		_native_post = ClassDB.instantiate(&"DotSimPlayerPost")
		_native_post.configure(DotFpsState.Mode.GROUND, DotWeaponAccuracyClass.FLINCH_SEC)
	return true


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
	return _posture_tick - hurt > ceili(DotWeaponAccuracyClass.FLINCH_SEC * float(rate))


## [method _idle_posture]'s context, refilled each idle tick: a new one per idle player per tick cost
## an allocation of 21 fields and a dictionary. A behaviour's tick only reads it.
var _posture_ctx := DotWeaponContext.new()


## Cvar [code]fc_posture_native[/code]: 1 runs [method _idle_row] in dot-sim where its library has
## [code]DotSimPlayerPost[/code] (bit for bit with the script); 0 runs the script (the reference and the A/B arm).
static var posture_native := true


## dot-sim's [code]DotSimPlayerPost[/code] for this player, or null before the first native [method _idle_row].
var _native_post: Object = null


## [method _idle_row]'s row, refilled each idle tick. The native lane hands back a new one of 10 floats (the still flag
## last); the rig reads the first 9.
var _posture_row := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])


## The tick the weapons are being simulated for, read by [method _idle_posture] (the flinch counts from it).
var _posture_tick: int = 0
