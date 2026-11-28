@tool
extends "fc_game_loadouts.gd"

const FcWeaponCensus := preload("fc_weapon_census.gd")

## The tick's posture flush (the waiting idle players' rows and their weapon outcomes in roster order) and the idle
## weapons' native batch ([member FcPlayer.weapon_idle_batch]); split out of fc_game_tick.gd for file size.


## Whether gs-sim's [code]GSSimWeaponIdleBatch[/code] is there (made once).
func _idle_batch_ready() -> bool:
	if _idle_batch == null and GSSim.has(&"weapon_idle"):
		_idle_batch = ClassDB.instantiate(GSSim.MODULES[&"weapon_idle"])
	return _idle_batch != null


## Each waiting player's weapon tick with the native idle calls in one gs-sim run: each rig ticks around its deferred
## call (or alone, when it cannot join), the batch runs, the entries it declined tick in script. Returns the outcomes
## in roster order (the caller clears them). The batch only touches weapon state nothing reads in between.
func _idle_batch_ticks(out: PackedFloat64Array, count: int) -> Array:
	_idle_entries.clear()
	_idle_owners.clear()
	_idle_outs.resize(count)
	for k in range(count):
		var player: FcPlayer = _post_players[k]
		var size := _idle_entries.size()
		var outcome := player.tick_idle_batch(_idle_entries, k)
		if outcome == null:
			if FcWeaponCensus.on:
				FcWeaponCensus.not_joined(player)
			var at := k * 10
			outcome = player.tick_idle_row(out.slice(at, at + 10), out[at + 9] != 0.0)
		elif _idle_entries.size() > size:
			_idle_owners.append(player)
		_idle_outs[k] = outcome
	if not _idle_owners.is_empty():
		var t_wp := Time.get_ticks_usec()
		var declined: PackedInt32Array = _idle_batch.call(&"run", _idle_entries, out, 10)
		for e in declined:
			_idle_owners[e].weapons.idle_batch_declined()
		FcFrameProbe.add(&"p_weapons", t_wp)
		if FcWeaponCensus.on:
			FcFrameProbe.add(&"pwx_batch_run", t_wp)
			FcFrameProbe.count(&"wc_joined", _idle_owners.size())
			FcFrameProbe.count(&"wc_declined", declined.size())
	return _idle_outs


## What a player's weapon tick did, in roster order: its shots, its protection and the horde's and rockets' share.
func _post_outcome(id: int, player: FcPlayer, move: GSFpsCommand, outcome: GSWeaponOutcome, shots: Array[GSShot]) -> void:
	shots.append_array(outcome.shots)
	if shot_debug:
		_debug_fire(id, player, outcome)
	_note_protected_action(id, player, move, not outcome.shots.is_empty())
	if horde != null and (not outcome.shots.is_empty() or not outcome.spawns.is_empty()):
		horde.note_fire(id, player.controller.state.position)
	if projectiles != null:
		projectiles.accept(outcome)


## The waiting idle players' posture rows in one gs-sim call, then each one's weapon tick and outcome in roster order.
func _flush_posts(shots: Array[GSShot]) -> void:
	var count := _post_players.size()
	if count == 0:
		return
	FcHullGrid.post_flushes += 1
	if FcWeaponCensus.on: FcFrameProbe.count(&"wc_flush")
	var input := _post_in if _post_in.size() == count * 10 else _post_in.slice(0, count * 10)
	var out: PackedFloat64Array = _post_native.run_rows(input)
	if FcPlayer.weapon_idle_batch and _idle_batch_ready():
		_flush_idle_batch(out, count, shots)
	else:
		for k in range(count):
			var player: FcPlayer = _post_players[k]
			var at := k * 10
			var outcome := player.tick_idle_row(out.slice(at, at + 10), out[at + 9] != 0.0)
			_post_outcome(_post_ids[k], player, _post_moves[k], outcome, shots)
	_post_players.clear()
	_post_ids.clear()
	_post_moves.clear()


## [method _flush_posts] with the weapons' native idle calls batched ([method _idle_batch_ticks]); the outcomes are
## posted in roster order as before.
func _flush_idle_batch(out: PackedFloat64Array, count: int, shots: Array[GSShot]) -> void:
	var outs := _idle_batch_ticks(out, count)
	for k in range(count):
		_post_outcome(_post_ids[k], _post_players[k], _post_moves[k], outs[k], shots)
	outs.fill(null)


## [member shot_debug]'s "fire refused" line: a human's trigger went down on a simulated command and no shot came out,
## with why the weapon said no. The server-side half of a tap the client drew and the server never traced.
func _debug_fire(id: int, player: FcPlayer, outcome: GSWeaponOutcome) -> void:
	if not is_authority:
		return
	var pair: Array = _debug_commands.get(id, [])
	if pair.size() < 3 or float(pair[2]) < 0.0:
		return
	var fire: GSWeaponCommand = pair[1]
	var held := fire != null and fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK)
	var was := bool(_debug_fire_held.get(id, false))
	_debug_fire_held[id] = held
	if not held or was or not outcome.shots.is_empty():
		return
	var arsenal := player.arsenal
	var def: GSWeaponDef = arsenal.current_def() if arsenal != null else null
	# next_use is gs-weapon 60's; an older link logs -1 rather than failing the line.
	var next_use: int = arsenal.call(&"next_use_tick") if arsenal != null and arsenal.has_method(&"next_use_tick") else -1
	GSLog.warn(CHANNEL, "shot debug fire refused", {"by": id, "tick": _tick, "why": outcome.refusal,
		"weapon": def.id if def != null else &"", "ready": arsenal.is_ready() if arsenal != null else false,
		"next_use": next_use})
