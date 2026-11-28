@tool
extends "fc_game_input.gd"

## The batched loop's native players call (`sv_native_players`: gs-player-controller's one call for every live
## player's pre, motor and post rows); and the second half of each batched player's tick; split out of fc_game_tick.gd for file size.


## Whether `sv_native_players` has gs-player-controller's batched call (made once; FcNativeTick says loudly when not).
func _players_call_ready() -> bool:
	if not _ctl_tried:
		_ctl_tried = true
		_ctl_batch = FcNativeTick.make_players()
		if _ctl_batch != null:
			_ctl_controllers = _ctl_batch.controllers
			_pc_pre_fn = _pc_pre
			_pc_live_fn = _pc_live
			_pc_post_fn = _pc_post
	return _ctl_batch != null


## The batched loop's two passes as one gs-player-controller call (`sv_native_players`) in the same order: [method _pc_pre] before the
## controller, [method _pc_live] before a row finishes, [method _pc_post] after it. [param fine]: the fine probe's per-player laps
## (`pl_*`, `pp_*`, `po_*`); the controller's own laps are inside the call, under `p_controller`.
func _tick_players_call(delta: float, hull_world: Object, shots: Array[GSShot], ids: Array[int],
		knife_charge: bool, surfing: bool, rows: GSFpsTickEvents, fine: bool) -> void:
	var n := ids.size()
	var _r: Variant = _ctl_batch.resize(n)
	for i in range(n):
		_ctl_controllers[i] = (_players[ids[i]] as FcPlayer).controller
	_pc_ids = ids
	_pc_shots = shots
	_pc_hull_world = hull_world
	_pc_delta = delta
	_pc_knife = knife_charge
	_pc_surfing = surfing
	_pc_fine = fine
	_pc_post_lane = FcPlayer.posture_native and GSSim.has(&"players")
	if _pc_post_lane and _post_native == null:
		_post_native = FcPlayer.make_native_post()
	_pc_post_from = _motor_batch if _pc_post_lane and _motor_post_row else null
	_demo_gated = FcHullGrid.demo_flush_gate and demo_stats != null
	_pc_mark_due = FcPlayer.mechanics_native
	var _motored: Variant = _ctl_batch.tick(_motor_batch, _tick, rows, _pc_pre_fn, _pc_live_fn, _pc_post_fn)
	# The roster's activity in one call (sv_native_activity): _pc_pre marked every row that reached the note with 0.
	_activity.note(ids, _batch_rows, _tick)
	if _pc_mark_due:
		# No row reached its finish: the marks still run, as between the two passes.
		_pc_mark_due = false
		_volume_pre.mark(_tick, ids, _players, _ctl_batch.rows)
	FcHullGrid.batch_faults += int(_ctl_batch.faults)
	_ctl_batch.faults = 0
	_pc_hull_world = null
	_pc_post_from = null
	FcNativeTick.player_calls += 1


## Pass one's part of row [param i]: the input and the tick start, then the body's delta (-1 leaves the row out).
func _pc_pre(i: int) -> float:
	var id: int = _pc_ids[i]
	var player: FcPlayer = _players[id]
	_batch_rows[i] = -1
	if not player.health.alive:
		return -1.0
	var t_fine := Time.get_ticks_usec() if _pc_fine else 0
	_pre_vy[id] = player.controller.state.velocity.y
	var pair := _batched_input(id, player, _batch_pairs[i], _pc_knife, _pc_surfing, t_fine)
	if pair.is_empty():
		return -1.0
	# Past _batched_input's activity note (only the row's -1 / not -1 is read, by the activity lane).
	_batch_rows[i] = 0
	_batch_pairs[i] = pair
	if _pc_fine:
		FcFrameProbe.add(&"pl_pre", t_fine)
		t_fine = Time.get_ticks_usec()
	player.tick_pre(_tick, pair[0])
	var t_ctl := Time.get_ticks_usec()
	# Below zero: the controller does not tick (not started, or a far bot's body sitting this tick out); the rest still runs.
	var d := player.body_delta(_tick, _pc_delta, player.controller.current_command)
	player.ctl_usec = Time.get_ticks_usec() - t_ctl
	if _pc_fine:
		FcFrameProbe.lap(&"c_delta", t_ctl)
		FcFrameProbe.add(&"pl_sim", t_fine)
	return maxf(d, 0.0)


## Whether row [param i]'s player is still alive to finish (an earlier turn may have killed it); the first one asked
## runs the volume marks over every prepared row.
func _pc_live(i: int) -> bool:
	if _pc_mark_due:
		_pc_mark_due = false
		_volume_pre.mark(_tick, _pc_ids, _players, _ctl_batch.rows)
	return (_players[_pc_ids[i]] as FcPlayer).health.alive


## The rest of row [param i]'s tick after its controller ([param told]: the motor batch's answer).
func _pc_post(i: int, row: int, told: bool) -> void:
	var id: int = _pc_ids[i]
	_finish_batched_player(i, row, id, _players[id], _pc_delta, _pc_hull_world, _pc_shots, _pc_fine, _pc_post_lane,
			_pc_post_from, true, told)


## The second half of one player's batched tick: the motor's answer, the rest of the player's tick and what it did.
## [param pair_index]: the row's commands in _batch_pairs. [param ended]: the controller's half already ran (`sv_native_players`), [param told_in] the motor batch's answer.
func _finish_batched_player(pair_index: int, row: int, id: int, player: FcPlayer, delta: float, hull_world: Object, shots: Array[GSShot],
		fine: bool, post_lane: bool, post_from: Object, ended: bool = false, told_in: bool = false) -> void:
	var pair := _batch_pairs[pair_index]
	var controller := player.controller
	var t_fine := 0
	var t_post := 0
	if fine:
		t_fine = Time.get_ticks_usec()
	var move: GSFpsCommand = pair[0]
	var fire: GSWeaponCommand = pair[1]
	var told := told_in
	var t_ctl := Time.get_ticks_usec()
	if row >= 0 and not ended:
		if controller.has_external_velocity():
			FcHullGrid.batch_faults += 1
		var runs0 := _motor_batch.runs
		told = _motor_batch.finish(row)
		if fine:
			# c_finish split: the row that ran the batch's native call (c_fin_run) or only took its answer (c_fin_apply).
			FcFrameProbe.add(&"c_fin_run" if _motor_batch.runs != runs0 else &"c_fin_apply", t_ctl)
			t_fine = FcFrameProbe.lap(&"c_finish", t_ctl)
		controller.end_tick(_tick, player.body_d)
		if fine:
			FcFrameProbe.lap(&"c_end", t_fine)
	var rested := controller.state.position
	FcFrameProbe.add(&"p_controller", t_ctl - player.ctl_usec)
	var outcome: GSWeaponOutcome = null
	var t_h := FcFrameProbe.lap_start()
	var head := player.tick_post_head(_tick, delta, fire)
	t_h = FcFrameProbe.lap(&"pb_head", t_h)
	if not head:
		if FcWeaponCensus.on: FcWeaponCensus.active(player)
		# A weapon tick that does more than idle can reach other players: the waiting idle ones tick first, in order.
		_flush_posts(shots)
		outcome = player.tick_weapons(_tick)
	elif post_lane:
		var k := _post_players.size()
		if _post_in.size() < (k + 1) * 10:
			_post_in.resize((k + 1) * 10)
		player.post_input(_post_in, k * 10, post_from, row)
		_post_players.append(player)
		_post_ids.append(id)
		_post_moves.append(move)
		FcFrameProbe.lap(&"pb_postin", t_h)
		if FcWeaponCensus.on: FcFrameProbe.count(&"wc_posted")
	else:
		if FcWeaponCensus.on: FcFrameProbe.count(&"wc_idle_alone")
		var still := player._idle_row()
		outcome = player.tick_idle_row(player._posture_row, still)
	if fine:
		FcFrameProbe.add(&"pl_sim", t_fine)
		t_fine = Time.get_ticks_usec()
		t_post = t_fine
	if _surf_after:
		surf_rides.after(id, player, move, _tick)
	if fine:
		t_fine = FcFrameProbe.lap(&"po_surf", t_fine)
	var feet := controller.state.position
	var alive := player.health.alive
	_hull_grid.turned(hull_world, id, player, feet, not told or feet != rested, alive)
	if row >= 0 and (feet != rested or not alive):
		_motor_batch.moved_after(row)
	if fine:
		t_fine = FcFrameProbe.lap(&"po_hullw", t_fine)
	if demo_stats != null:
		# The demo's meddler may hurt or move anyone: the waiting weapon ticks come first, as one by one. FcDemoStats only
		# reads a human's tick while it records; for anyone else the idle ticks keep waiting and stay one gs-sim call.
		if not _demo_gated or demo_stats.after_reads(player):
			_flush_posts(shots)
		demo_stats.after(id, player, move, fire, _tick)
	if outcome != null:
		_post_outcome(id, player, move, outcome, shots)
	if fine:
		FcFrameProbe.lap(&"po_out", t_fine)
		FcFrameProbe.add(&"pl_post", t_post)
