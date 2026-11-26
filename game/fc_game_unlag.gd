@tool
extends "fc_game_vars.gd"

## After everybody moved: a player who came down onto another's head kills them, and bounces.
## Server-authoritative; a client's prediction of the bounce is corrected by the next snapshot.
func _resolve_stomps() -> void:
	_sync_stomp_config()
	if not stomp.rules.enabled or combat == null:
		return
	# The hulls are gathered only once someone falls fast enough to stomp: GSStomp.find
	# returns 0 below min_speed without reading them, and most ticks nobody does.
	var gathered := false
	for id in player_ids():
		var player: FcPlayer = _players[id]
		if not _pre_vy.has(id) or not player.health.alive:
			continue
		if -float(_pre_vy[id]) < stomp.rules.min_speed:
			continue
		if not gathered:
			_gather_stomp_hulls()
			gathered = true
		var state: GSFpsState = player.controller.state
		var radius: float = player.controller.tunables.radius
		# Only the hulls under these feet: GSStomp.find refuses the rest on these same two tests, so its answer is unchanged.
		var hulls := _stomp_hulls_under(id, state.position, radius)
		if hulls.is_empty():
			continue
		var victim := stomp.find(
			id, state.position, radius, -float(_pre_vy[id]),
			team_of(id) if not teams().is_empty() else -1, hulls, _tick, tick_rate
		)
		if victim == 0:
			continue
		var hit := GSDamage.make(id, victim, stomp.amount(), combat.damage_type(FcContent.DAMAGE_STOMP))
		hit.tick = _tick
		hit.point = state.position
		hit.weapon_id = FcContent.DAMAGE_STOMP
		hit.context = {"why": &"stomp", "ignores_teams": stomp.rules.same_team}
		var _applied := combat.apply_damage(hit)
		if hit.refused:
			continue
		if stomp.rules.bounce > 0.0:
			state.velocity.y = stomp.rules.bounce
		stomped.emit(id, victim, -float(_pre_vy[id]), state.position, stomp.rules.sound, stomp.rules.effect)
		if progress != null:
			progress.record(id, FcStats.STOMPS)


func _gather_stomp_hulls() -> void:
	_st_ids.clear()
	_st_feet.clear()
	_st_team.clear()
	_st_height.clear()
	_st_radius.clear()
	var teamed := not teams().is_empty()
	for id in player_ids():
		var other: FcPlayer = _players[id]
		if not other.health.alive or other.controller == null:
			continue
		_st_ids.append(id)
		_st_feet.append(other.controller.state.position)
		_st_team.append(team_of(id) if teamed else -1)
		_st_height.append(other.controller.tunables.stand_height)
		_st_radius.append(other.controller.tunables.radius)


## The hulls GSStomp.find would weigh for feet at [param feet]: its head-gap and reach tests, same arithmetic, same order.
func _stomp_hulls_under(attacker: int, feet: Vector3, radius: float) -> Array:
	var hulls: Array = []
	var tolerance: float = stomp.rules.head_tolerance
	for i in _st_ids.size():
		if _st_ids[i] == attacker:
			continue
		var other := _st_feet[i]
		if absf(feet.y - (other.y + _st_height[i])) > tolerance:
			continue
		if Vector2(feet.x - other.x, feet.z - other.z).length() > radius + _st_radius[i]:
			continue
		hulls.append({"id": _st_ids[i], "feet": other, "team": _st_team[i], "height": _st_height[i], "radius": _st_radius[i]})
	return hulls


## Copies the cfg's stomp numbers onto [member stomp]'s rules. Rules the cfg does not own (sound ids) too.
func _sync_stomp_config() -> void:
	var r := stomp.rules
	r.enabled = config.stomp_enabled
	r.damage = config.stomp_damage
	r.min_speed = config.stomp_min_speed
	r.head_tolerance = config.stomp_head_tolerance
	r.same_team = config.stomp_same_team
	r.bounce = config.stomp_bounce
	r.cooldown_sec = config.stomp_cooldown_sec
	r.sound = StringName(config.stomp_sound)
	r.effect = StringName(config.stomp_effect)


## Every live player's hull this tick, in roster order, as plain columns: a falling player's
## [method _stomp_hulls_under] reads these instead of a dictionary per player per faller.
var _st_ids := PackedInt64Array()


var _st_feet := PackedVector3Array()


var _st_team := PackedInt64Array()


var _st_height := PackedFloat64Array()


var _st_radius := PackedFloat64Array()


## Cvar [code]fc_unlag_native[/code]: 1 keeps the rewind history in gs-sim's [code]GSSimUnlagRing[/code] where its library has it,
## recorded for every player in one call a tick (the same answers: [code]headless_unlag_native_parity[/code]); 0 keeps
## the script rings in [member _unlag]. A game reads it when it records its first tick and keeps that choice.
static var unlag_native := true


## Where player [param id] was at [param at] (a fractional tick), between the two
## recorded ticks either side; null when the history does not reach that far.
func unlag_position_at(id: int, at: float) -> Variant:
	if _unlag_ring != null:
		return _unlag_ring.call(&"position_at", id, at)
	return ring_position_at(_unlag.get(id, []), at)


## Player [param id]'s crouch fraction at [param at], lerped as [method unlag_position_at] is; -1 when not recorded.
func unlag_crouch_at(id: int, at: float) -> float:
	if _unlag_ring != null:
		return _unlag_ring.call(&"crouch_at", id, at)
	return ring_crouch_at(_unlag.get(id, []), at)


## A script ring's position at [param at] (see [method unlag_position_at]); null when it is empty or not recorded there.
static func ring_position_at(ring: Array, at: float) -> Variant:
	# Below tick 0, -1 % 128 indexes the last slot, whose unfilled tag is -1 too.
	if ring.is_empty() or at < 0.0:
		return null
	var positions: PackedVector3Array = ring[0]
	var ticks: PackedInt32Array = ring[1]
	var lo := floori(at)
	var size := positions.size()
	var a := lo % size
	var b := (lo + 1) % size
	if ticks[a] != lo:
		return null
	if ticks[b] != lo + 1:
		return positions[a]
	return positions[a].lerp(positions[b], at - float(lo))


## A script ring's crouch fraction at [param at] (see [method unlag_crouch_at]); -1 when not recorded.
static func ring_crouch_at(ring: Array, at: float) -> float:
	if ring.size() < 3 or at < 0.0:
		return -1.0
	var crouches: PackedFloat32Array = ring[2]
	var ticks: PackedInt32Array = ring[1]
	var lo := floori(at)
	var a := lo % ticks.size()
	var b := (lo + 1) % ticks.size()
	if ticks[a] != lo:
		return -1.0
	if ticks[b] != lo + 1:
		return crouches[a]
	return lerpf(crouches[a], crouches[b], at - float(lo))


## gs-combat's rewind: every other living player, put where they were at [param view_tick], in the stance they had then:
## the zones fit the present crouch, and a target that crouched since would be traced a standing head too short.
func _unlag_rewind(view_tick: float) -> void:
	for id in _players:
		if id == _unlag_shooter:
			continue
		var player: FcPlayer = _players[id]
		if not player.health.alive:
			continue
		# A hitscan shot: where the shooter's screen blended them, when the command named its two snapshots.
		var then: Variant = shot_feet_fn.call(id, _unlag_shooter, view_tick) if _unlag_shot and shot_feet_fn.is_valid() else null
		var crouch := -1.0
		if then != null and shot_crouch_fn.is_valid():
			crouch = shot_crouch_fn.call(id, _unlag_shooter, view_tick)
		if then == null:
			then = ring_feet(id, view_tick)
		if then == null:
			continue
		_unlag_moved[id] = player.global_position
		player.global_position = then
		if crouch < 0.0:
			crouch = unlag_crouch_at(id, view_tick)
		if crouch >= 0.0 and player.controller != null and crouch != player.controller.state.crouch_fraction:
			player.fit_hitboxes_to_crouch(crouch)
			_unlag_refit[id] = true


## And back, after the trace.
func _unlag_restore() -> void:
	for id in _unlag_moved:
		var player: FcPlayer = _players.get(id)
		if player != null:
			player.global_position = _unlag_moved[id]
	_unlag_moved.clear()
	for id in _unlag_refit:
		var player: FcPlayer = _players.get(id)
		if player != null:
			player.fit_hitboxes_to_stance()
	_unlag_refit.clear()


## Slots in a position ring: [constant UNLAG_SECONDS] of ticks at this game's rate (never under [constant UNLAG_HISTORY]).
func unlag_history() -> int:
	return maxi(UNLAG_HISTORY, ceili(UNLAG_SECONDS * float(tick_rate)) + 2)


## Records every player's position for this tick, for [method _unlag_rewind].
func _unlag_record() -> void:
	if not _unlag_decided:
		_unlag_decided = true
		if unlag_native and GSSim.has(&"unlag"):
			_unlag_ring = ClassDB.instantiate(&"GSSimUnlagRing")
			_unlag_ring.call(&"set_history", unlag_history())
	if _unlag_ring != null:
		_unlag_record_native()
		return
	for id in _players:
		var player: FcPlayer = _players[id]
		var crouch: float = player.controller.state.crouch_fraction if player.controller != null else 0.0
		_unlag[id] = ring_record(_unlag.get(id, []), _tick, unlag_history(), player.global_position, crouch)


## [method _unlag_record] in gs-sim: every player's feet and crouch gathered into packed rows, one call.
func _unlag_record_native() -> void:
	var n := _players.size()
	if _unlag_ids.size() != n:
		_unlag_ids.resize(n)
		_unlag_feet.resize(n)
		_unlag_crouch.resize(n)
	var i := 0
	for id in _players:
		var player: FcPlayer = _players[id]
		_unlag_ids[i] = id
		_unlag_feet[i] = player.global_position
		_unlag_crouch[i] = player.controller.state.crouch_fraction if player.controller != null else 0.0
		i += 1
	_unlag_ring.call(&"record", _tick, _unlag_ids, _unlag_feet, _unlag_crouch, TELEPORT_CUT)


## Writes tick [param tick] into a script ring (a new one of [param history] slots when [param ring] is empty) and returns it:
## the script lane of [code]GSSimUnlagRing.record[/code]. A respawn or teleport since the previous tick clears it first.
static func ring_record(ring: Array, tick: int, history: int, feet: Vector3, crouch: float) -> Array:
	if ring.is_empty():
		var positions := PackedVector3Array()
		positions.resize(history)
		var ticks := PackedInt32Array()
		ticks.resize(history)
		ticks.fill(-1)
		ring = [positions, ticks]
	if ring.size() < 3:
		var fresh := PackedFloat32Array()
		fresh.resize((ring[1] as PackedInt32Array).size())
		ring.append(fresh)
	# Packed arrays are values: taken out, written, and put back, or the write lands
	# on a copy and the history stays empty (it did, the first time).
	var positions: PackedVector3Array = ring[0]
	var ticks: PackedInt32Array = ring[1]
	var crouches: PackedFloat32Array = ring[2]
	# The ring's own references are dropped while the three are written, so each write is in place: with them
	# held, every write copies the whole 128-slot array (three copies per player per tick).
	ring[0] = null
	ring[1] = null
	ring[2] = null
	var slot := tick % ticks.size()
	var before := (tick - 1) % ticks.size()
	# A respawn or a teleport: rewinding across it would stand hitboxes where they died.
	if ticks[before] == tick - 1 and positions[before].distance_to(feet) > TELEPORT_CUT:
		ticks.fill(-1)
	positions[slot] = feet
	ticks[slot] = tick
	crouches[slot] = crouch
	ring[0] = positions
	ring[1] = ticks
	ring[2] = crouches
	return ring


func player_ids() -> Array[int]:
	# Asked for by a dozen steps of every tick, and the roster changes a few times a match: sorted once per change.
	# Callers only read it, and a change replaces the array rather than editing it, so a loop over it is safe.
	if _ids_cache.size() == _players.size():
		return _ids_cache
	var out: Array[int] = []
	for key in _players.keys():
		out.append(int(key))
	out.sort()
	_ids_cache = out
	return out


## Which side a player is on, or 0 in a free-for-all.
func team_of(id: int) -> int:
	if not is_authority and replicated_teams.has(id):
		return int(replicated_teams[id])

	if match_node == null or match_node.teams == null:
		return 0

	return match_node.teams.team_of(str(id))


## The sides in play, empty in a free-for-all.
func teams() -> Array[GSTeam]:
	# A client's own match is the mode it started in (free-for-all), not the one the server plays:
	# the sides come from the mode it is shown, which is what the server announced.
	if not is_authority:
		var shown := _mode_shown()
		if shown != null and shown.is_team_mode():
			if _shown_sides_for != shown:
				_shown_sides_for = shown
				_shown_sides = shown.teams()
			return _shown_sides

	if match_node != null and match_node.teams != null:
		return match_node.teams.teams

	return []


func player_for(id: int) -> FcPlayer:
	return _players.get(id)


## The mode on show (the top layer answers; null here).
func _mode_shown() -> FcMode:
	return null


var _shown_sides: Array[GSTeam] = []


var _shown_sides_for: FcMode = null
