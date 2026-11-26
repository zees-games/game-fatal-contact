@tool
extends "fc_game_loadouts.gd"

const FcWeaponCensus := preload("fc_weapon_census.gd")

## The idle weapons' native batch of the tick's posture flush ([member FcPlayer.weapon_idle_batch]); split out of
## fc_game_tick.gd for file size.


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
