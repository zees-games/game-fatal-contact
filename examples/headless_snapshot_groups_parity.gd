extends "headless_net_base.gd"

## cl_native_snapshot: a remote player's snapshot hook (FcPlayerNet._net_state_applied) skips the movement, health and
## weapon pushes whose state groups the snapshot left unchanged (gs-sim's GSSimSnapshotBatch or gs-net's script read
## marks them in `_changed_groups`). After every snapshot each client's remote players are fingerprinted (the whole
## GSFpsState, health, arsenal, mirror fields and node position, compared as bytes), the full hook is run again with the
## cvar off, and the fingerprint must not move: what was skipped would have written nothing new. Client 2 reads through
## the native batch where the library groups, client 3 through gs-net's script read.
const EXPECTED_SECTIONS := 2
const TICKS := 480

var _differ := 0
var _compared := 0
var _first_diff := ""


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors := EngineErrors.new()
	OS.add_logger(errors)
	print("FC — snapshot state groups: skipped pushes change nothing")

	_build_server()
	_build_client(2, 11)
	_build_client(3, 12)
	_join_everyone()
	var joined := _joins.size()
	for i in 3:
		_check(_server_bridge.add_bot("Grouper%d" % i) != 0, "the server seats bot %d" % i)
	# _join_everyone hands the clients only the joins made before it. A client that meets an entity it
	# has no join for stops reading the snapshot there, players and all, so without this no remote
	# player ever got state and the comparison below ran over nothing.
	_check(_joins.size() == joined + 3, "the bots' joins were announced", str(_joins.size() - joined))
	for peer_id in _clients:
		for k in range(joined, _joins.size()):
			_check(_clients[peer_id]["bridge"].apply_join(_joins[k]).ok, "client %d mirrors bot join %d" % [peer_id, k])
	# Client 3 reads through the script: gs-net's _apply_read marks the groups.
	var script_net: GSNetManager = _clients[3]["net"]
	if script_net.interpolator != null:
		script_net.interpolator.snapshot_batch = null
	var native_net: GSNetManager = _clients[2]["net"]
	var batch: GSNetSnapshotBatch = native_net.interpolator.snapshot_batch if native_net.interpolator != null else null
	var native := batch != null and batch._group_rows
	if not native:
		print("gs-sim's snapshot batch does not group (or is absent): both clients read through the script")

	_test_parity(native, batch)

	OS.remove_logger(errors)
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])
	_report_sections(_entered, _completed, EXPECTED_SECTIONS)


func _test_parity(native: bool, batch: GSNetSnapshotBatch) -> void:
	print("")
	_section("[after every snapshot, the full hook changes no remote player]")
	FcPlayerNet.native_snapshot = true
	var skips_before := FcPlayerNet.group_skips
	for _i in TICKS:
		var tick := _server_game.current_tick() + 1
		for peer_id in _clients:
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			_server_bridge.receive_input(peer_id, entry["bridge"].encode_input(tick, pair[0], pair[1]))
		_server_bridge.server_tick(tick)
		var delivered := not _downstream.is_empty()
		for entry_down in _downstream:
			var peer: int = entry_down["peer"]
			var targets: Array = _clients.keys() if peer == 0 else [peer]
			for target in targets:
				if _clients.has(target):
					_clients[target]["bridge"].receive_snapshot(entry_down["bytes"])
		_downstream.clear()
		if delivered:
			_compare_all(tick)
		for peer_id in _clients:
			var entry: Dictionary = _clients[peer_id]
			var pair := _commands_for(peer_id, tick)
			entry["net"].clock.tick = tick
			entry["bridge"].client_tick(tick, pair[0], pair[1])
	var skips := FcPlayerNet.group_skips - skips_before
	_check(_compared > TICKS, "remote players were compared after snapshots", str(_compared))
	_check(skips > 0, "hooks skipped unchanged groups", str(skips))
	_check(_differ == 0, "a full push on top of the grouped one changed nothing",
		"%d of %d; first: %s" % [_differ, _compared, _first_diff])
	_done()

	print("")
	_section("[the native batch held the remote players and grouped them]")
	if native:
		_check(batch.size() > 0, "the batch holds entities", str(batch.size()))
	else:
		print("  (no grouping library: the script lane alone ran)")
	_done()


## Varied commands so movement, view, weapons and health all change and all stand still at times.
func _commands_for(peer_id: int, tick: int) -> Array:
	var move := GSFpsCommand.new()
	var phase := floori(tick / 40.0) % 3
	if phase != 2:
		move.move = Vector2(0.0, 1.0 if peer_id == 2 else -1.0)
	move.yaw = fmod(float(tick * (3 if peer_id == 2 else 5)), 360.0) if phase == 0 else 90.0
	var fire := GSWeaponCommand.new()
	fire.slot = 2 if floori(tick / 120.0) % 2 == 0 else 1
	if tick % 8 == 0:
		fire.set_button(GSWeaponCommand.BUTTON_ATTACK, true)
	return [move, fire]


func _compare_all(tick: int) -> void:
	for peer_id in _clients:
		var bridge: FcNetBridge = _clients[peer_id]["bridge"]
		for id: int in bridge._behaviours:
			var b: FcPlayerNet = bridge._behaviours[id]
			if b == null or b.player == null or b.identity == null or b.identity.is_predicted() or b.last_state_tick < 0:
				continue
			var grouped := _fingerprint(b)
			FcPlayerNet.native_snapshot = false
			b._net_state_applied(b.last_state_tick)
			FcPlayerNet.native_snapshot = true
			var full := _fingerprint(b)
			_compared += 1
			if grouped != full:
				_differ += 1
				if _first_diff == "":
					_first_diff = "tick %d client %d entity %d: %s" % [tick, peer_id, id, _diff_fields(grouped, full)]


## Every script variable of the state, health and arsenal, the player's mirror fields and node position, as bytes.
func _fingerprint(b: FcPlayerNet) -> Dictionary:
	var p := b.player
	var out := {}
	out["state"] = _vars(p.controller.state)
	out["health"] = _vars(p.health)
	out["arsenal"] = _vars(p.arsenal)
	var current: Variant = p.arsenal.current()
	out["weapon"] = _vars(current) if current is Object else []
	out["player"] = var_to_bytes([p.global_position, p.blinded, p.challenge, p.beacon, p.flashlight, p.protected_view,
			p.mirrored, p.mirror_weapon, p.mirror_fire_seq, p.mirror_fire_kind, p.mirror_switching, p.mirror_charge,
			p.windup, p.mirror_reloading, p.mirror_fitted, p.hitboxes.enabled, p.arsenal.disabled])
	return out


func _vars(o: Object) -> Array:
	var out := []
	for prop in o.get_property_list():
		if not (int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var value: Variant = o.get(prop["name"])
		if value is Object or value is Callable or value is Signal:
			continue
		out.append([prop["name"], var_to_bytes(value)])
	return out


func _diff_fields(a: Dictionary, b: Dictionary) -> String:
	for key in a:
		if a[key] != b.get(key):
			if a[key] is Array and b[key] is Array:
				for i in mini(a[key].size(), b[key].size()):
					if a[key][i] != b[key][i]:
						return "%s.%s" % [key, str(a[key][i][0]) if a[key][i] is Array else str(i)]
			return str(key)
	return "?"


## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out

