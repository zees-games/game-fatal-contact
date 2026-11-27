@tool
extends "fc_player_build.gd"
## The player's part of the packed post-head pass (cvar fc_post_head_native, docs/native-server-tick.md): its input
## row, taking its answer, and the parity check against the script.

## Cvar [code]fc_post_head_native[/code]: 1 lets FcGame's batched call answer every player's volume skip and hitbox
## height scale in one gs-sim call ([code]GSSimServerTick.post_head[/code]) from the resident motor rows;
## [method tick_post_head] takes a row only when its end feet are the state's. 0: each player works them out.
static var post_head_native := true
## For the parity suite: a player taking a native row also works both out itself; [member post_head_misses] counts
## the rows that differed. Off in play.
static var post_head_verify := false
static var post_head_used: int = 0
static var post_head_checked: int = 0
static var post_head_misses: int = 0
## This tick's packed answer (`GSSimServerTick.POST_HEAD_OUT` floats a row).
static var post_head_out := PackedFloat64Array()
## Where this player's row starts in [member post_head_out], and the game tick it is for.
var post_head_at := -1
var post_head_tick := -1


## Row [param o] of the post-head pass's input ([code][slot, gate, ratio][/code]): the motor slot (-1 asks
## nothing), whether [method _volumes_skip]'s mark and reach tests pass on [param tick], the crouch height ratio.
func post_head_input(rows: PackedFloat64Array, o: int, tick: int) -> void:
	var motor := controller.motor
	if motor == null or motor.tunables == null or motor.tunables != controller.tunables:
		rows[o] = -1.0
		return
	var t := motor.tunables
	var slack := FcVolumePrefilter.SLACK
	var side := t.radius + ladder.reach + slack
	var up := maxf(t.stand_height, swim.waist) + slack
	var fits := side <= minf(minf(FcVolumePrefilter.BELOW.x, FcVolumePrefilter.BELOW.z), minf(FcVolumePrefilter.ABOVE.x, FcVolumePrefilter.ABOVE.z)) \
		and up <= FcVolumePrefilter.BELOW.y and slack <= FcVolumePrefilter.ABOVE.y
	rows[o] = float(motor.batch_slot)
	rows[o + 1] = 1.0 if fits and _volumes_clear_tick == tick and _volumes_asked_tick == tick else 0.0
	rows[o + 2] = t.crouch_height / maxf(t.stand_height, 0.01)


## This tick's post-head row in [member post_head_out] when it may be taken (its end feet are the state's), else -1;
## either way the row is used up.
func _post_head_row(tick: int) -> int:
	var o := post_head_at
	post_head_at = -1
	if post_head_tick != tick or o < 0 or o + 6 > post_head_out.size() or post_head_out[o] == 0.0:
		return -1
	if Vector3(post_head_out[o + 3], post_head_out[o + 4], post_head_out[o + 5]) != controller.state.position:
		return -1
	return o


## The zones fitted to height scale [param k] (1 standing, the crouch height ratio crouched).
func _fit_hitboxes_k(k: float) -> void:
	if hitboxes == null:
		return
	if FcHullGrid.enabled and k == _fit_k:
		return
	_fit_k = k
	for box in hitboxes.hitboxes():
		if not box.has_meta(&"stand_y"):
			box.set_meta(&"stand_y", box.position.y)
			box.set_meta(&"stand_h", box.height)
		var y: float = box.get_meta(&"stand_y")
		var h: float = box.get_meta(&"stand_h")
		box.position.y = y * k
		if box.shape == GSHitbox.Shape.CAPSULE:
			box.height = maxf(h * k, box.radius * 2.0 + 0.02)


## Suites only: the script's height scale and volume skip (from tick start [param start]) against post-head row
## [param o] (counted, not acted on).
func _verify_post_head(o: int, tick: int, start: Vector3, clear: bool) -> void:
	post_head_checked += 1
	var t := controller.tunables
	var k := lerpf(1.0, t.crouch_height / maxf(t.stand_height, 0.01), clampf(controller.state.crouch_fraction, 0.0, 1.0))
	if k != post_head_out[o + 2] or clear != _volumes_skip(tick, start):
		post_head_misses += 1
