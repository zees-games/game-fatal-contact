@tool
extends "fc_game_tick.gd"
## `sv_native_players`: the batched players' loop handed to gs-player-controller as one call (phase P1). The script
## loop in fc_game_tick.gd stays the specification and the fallback; this layer only overrides its hook.


## Tallies the players phase and, when the batched call is ready, runs the whole loop through it.
func _tick_players_native(commands: Dictionary, delta: float, hull_world: Object, shots: Array[GSShot], ids: Array[int],
		knife_charge: bool, surfing: bool, rows: GSFpsTickEvents, fine: bool, t_tb: int) -> bool:
	var players_native := rows != null and FcNativeTick.players and _players_call_ready()
	FcNativePhases.tally(FcNativePhases.PLAYERS, players_native)
	if not players_native:
		return false
	_tick_players_call(commands, delta, hull_world, shots, ids, knife_charge, surfing, rows, fine)
	t_tb = FcFrameProbe.lap(&"tb_players", t_tb)
	_flush_posts(shots)
	t_tb = FcFrameProbe.lap(&"tb_flush", t_tb)
	_dispatch_tick_events(rows, ids, t_tb)
	_close_batch_counts(fine)
	return true


## Whether `sv_native_players` has gs-player-controller's batched call (made once; FcNativeTick says loudly when not).
func _players_call_ready() -> bool:
	if not _ctl_tried:
		_ctl_tried = true
		_ctl_batch = FcNativeTick.make_players()
		if _ctl_batch != null:
			_ctl_controllers = _ctl_batch.get(&"controllers")
			_pc_pre_fn = _pc_pre
			_pc_live_fn = _pc_live
			_pc_post_fn = _pc_post
	return _ctl_batch != null


## The batched loop's two passes as one gs-player-controller call, in the same order, so the same states and edges:
## [method _pc_pre], [method _pc_live] and [method _pc_post] are its three callbacks (docs/native-server-tick.md, Players).
func _tick_players_call(commands: Dictionary, delta: float, hull_world: Object, shots: Array[GSShot], ids: Array[int],
		knife_charge: bool, surfing: bool, rows: GSFpsTickEvents, fine: bool) -> void:
	var n := ids.size()
	var _r: Variant = _ctl_batch.call(&"resize", n)
	for i in range(n):
		_ctl_controllers[i] = (_players[ids[i]] as FcPlayer).controller
	_pc_ids = ids
	_pc_commands = commands
	_pc_shots = shots
	_pc_hull_world = hull_world
	_pc_delta = delta
	_pc_knife = knife_charge
	_pc_surfing = surfing
	_pc_fine = fine
	_pc_post_lane = FcPlayer.posture_native and GSSim.has(&"players")
	if _pc_post_lane and _post_native == null:
		_post_native = FcPlayer.make_native_post()
	_pc_post_from = _motor_batch if _pc_post_lane and _motor_batch.has_method(&"post_row") else null
	_demo_gated = FcHullGrid.demo_flush_gate and demo_stats != null and demo_stats.has_method(&"after_reads")
	_pc_mark_due = FcPlayer.mechanics_native
	var _motored: Variant = _ctl_batch.call(&"tick", _motor_batch, _tick, rows, _pc_pre_fn, _pc_live_fn, _pc_post_fn)
	if _pc_mark_due:
		# No row reached its finish: the marks still run, as between the two passes.
		_pc_mark_due = false
		_volume_pre.mark(_tick, ids, _players, _ctl_batch.get(&"rows"))
	FcHullGrid.batch_faults += int(_ctl_batch.get(&"faults"))
	_ctl_batch.set(&"faults", 0)
	_pc_hull_world = null
	_pc_post_from = null
	FcNativeTick.player_calls += 1


## Pass one's part of row [param i]: the input and the tick start, then the body's delta (-1 leaves the row out).
func _pc_pre(i: int) -> float:
	var id: int = _pc_ids[i]
	var player: FcPlayer = _players[id]
	if not player.health.alive:
		return -1.0
	var t_fine := Time.get_ticks_usec() if _pc_fine else 0
	var pair: Array = _pc_commands.get(id, [])
	_pre_vy[id] = player.controller.state.velocity.y
	pair = _batched_input(id, player, pair, _pc_knife, _pc_surfing, t_fine)
	if pair.is_empty():
		return -1.0
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
		_volume_pre.mark(_tick, _pc_ids, _players, _ctl_batch.get(&"rows"))
	return (_players[_pc_ids[i]] as FcPlayer).health.alive


## The rest of row [param i]'s tick after its controller ([param told]: the motor batch's answer).
func _pc_post(i: int, row: int, told: bool) -> void:
	var id: int = _pc_ids[i]
	_finish_batched_player(_batch_pairs[i], row, id, _players[id], _pc_delta, _pc_hull_world, _pc_shots, _pc_fine, _pc_post_lane,
			_pc_post_from, true, told)
