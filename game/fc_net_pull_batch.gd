extends RefCounted
## Every player's movement and weapon pull in one gs-sim call a tick ([code]GSSimFpsNetPullBatch.pull[/code]), writing what
## [code]GSSimFpsNetPack.pull[/code] and [code]GSSimFpsWeaponNet.pull[/code] write per player, to the bit
## ([code]headless_netpull_batch_parity[/code]). The bridge runs it once the game has ticked; a player it leaves out (no
## library, a cvar off, a declaration or rig only the script handles) pulls alone in [code]_net_simulate[/code]. Takes the
## nets as Objects because a typed reference back to [code]FcPlayerNet[/code] would make the scripts a compile cycle.

const FcFrameProbe := preload("fc_frame_probe.gd")
const FcNetPullNative := preload("fc_net_pull_native.gd")
const FcNetPullWeapons := preload("fc_net_pull_weapons.gd")
const Roles := preload("fc_weapon_roles.gd")

## cvar [code]sv_net_pull_batch[/code] (default on): one gs-sim call for every player a tick, where the per-player
## native pulls are on too; off, each player pulls alone.
static var enabled := true
static var _native: Object = null
static var _native_tried := false
static var _min_columns := 0
static var _move_extra := 0
## State columns in every row of [member _moves] (the first player's; another width pulls alone).
static var _columns := 0
static var _weapon_stride := 0
static var _out_stride := 0
static var _sent_ids: Array[StringName] = []
static var _sent := false
static var _moves := PackedFloat64Array()
static var _weapons := PackedFloat64Array()
static var _ids: Array[StringName] = []
static var _nets: Array[Object] = []
## [code]net_fitted[/code] per row, from the script (gs-sim has no attachment table).
static var _fitted := PackedInt64Array()


## gs-sim's [code]GSSimFpsNetPullBatch[/code] when the library has it, else null. Made once.
static func native() -> Object:
	if not _native_tried:
		_native_tried = true
		if ClassDB.class_exists(&"GSSimFpsNetPullBatch") and ClassDB.class_has_method(&"GSSimFpsNetPullBatch", &"pull"):
			_native = ClassDB.instantiate(&"GSSimFpsNetPullBatch")
			_min_columns = _native.min_columns()
			_move_extra = _native.move_extra()
			_weapon_stride = _native.weapon_stride()
			_out_stride = _native.out_stride()
			# The rows [method _gather] builds: 10 values then the 4 wire widths after the state's columns.
			if _move_extra != 14 or _weapon_stride != 9 or _out_stride != 11:
				push_warning("gs-sim's GSSimFpsNetPullBatch rows are not this game's; each player pulls alone")
				_native = null
	return _native


## Registers the switch on a module ([param add_cvar]: [method GSModule.add_cvar]).
static func bind_cvars(add_cvar: Callable) -> void:
	add_cvar.call("sv_net_pull_batch", "1" if enabled else "0",
		"1: every player's movement and weapon fields are pulled in one gs-sim call a tick where its library has GSSimFpsNetPullBatch (bit for bit with the per-player pulls; needs sv_net_pull_native, sv_net_pull_weapons_native and sv_net_pull_content_native on); 0: each player pulls alone",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(_set_enabled)


static func _set_enabled(_old: String, new_value: String) -> void:
	enabled = new_value.to_float() >= 0.5


## Whether [method pull_all] runs at all: the cvar, the three per-player native cvars it stands in for, and the library.
static func active() -> bool:
	return enabled and FcNetPullNative.enabled and FcNetPullWeapons.weapons_enabled and FcNetPullWeapons.content_enabled \
			and native() != null


## Pulls every net in [param nets] whose [code]batch_wants(tick)[/code] says so, in one gs-sim call, then runs the rest of
## each one's pull ([code]_pull_rest[/code]) and marks [param tick] pulled. Returns how many it pulled; the rest are left alone.
static func pull_all(nets: Array, tick: int) -> int:
	if not active():
		return 0
	_moves.clear()
	_weapons.clear()
	_ids.clear()
	_nets.clear()
	_fitted.clear()
	_columns = 0
	for net: Object in nets:
		if net.batch_wants(tick):
			_gather(net)
	if _nets.is_empty():
		return 0
	_sync_wire()
	var out: PackedInt64Array = _native.pull(_moves, _columns, _weapons, _ids, GSFpsNetSync.timer_scale)
	if out.size() != _nets.size() * _out_stride:
		return 0
	var fine := FcFrameProbe.fine
	for i in _nets.size():
		var net := _nets[i]
		_apply(net, out, i * _out_stride, _fitted[i])
		net._batched_tick = tick
		net._pull_rest(fine, FcFrameProbe.lap_start() if fine else 0)
	return _nets.size()


## Appends [param net]'s rows, or nothing where only its own pull can decide.
static func _gather(net: Object) -> void:
	var player: Object = net.player
	var rig: AwWeaponRig = player.weapons
	if rig == null or rig.arsenal == null:
		return
	var wire: PackedFloat64Array = net._native_pull._wire_for(net) if net.hold_subquantum else PackedFloat64Array(FcNetPullNative._NO_HOLD)
	if wire.is_empty():
		return
	var state: GSFpsState = player.controller.state
	var f: PackedFloat64Array = state._f
	if _columns == 0 and f.size() >= _min_columns:
		_columns = f.size()
	if f.size() != _columns:
		return
	var held_velocity: Vector3 = net.net_velocity
	_moves.append_array(f)
	_moves.append_array(PackedFloat64Array([1.0 if state.crouch_held else 0.0, state.stamina,
		1.0 if state.stamina_exhausted else 0.0, state.stamina_delay_left, state.pitch, held_velocity.x, held_velocity.y,
		held_velocity.z, net.net_yaw, net.net_pitch]))
	_moves.append_array(wire)
	var a := rig.arsenal
	var slot := a.current()
	var has := slot != null
	_weapons.append_array(PackedFloat64Array([a.current_slot(), 1.0 if has else 0.0, slot.fire_mode_index if has else 0,
		slot.magazine if has else 0, a.ammo().count(slot.def.ammo_type) if has else 0, rig.fire_seq, rig.fire_kind,
		rig.charge_shown, player.windup]))
	var arsenal: GSWeaponArsenal = player.arsenal
	var held: GSWeaponDef = arsenal.current_def() if arsenal != null else null
	_ids.append(held.id if held != null else &"")
	_fitted.append(FcNetPullWeapons.fitted_code(a, slot))
	_nets.append(net)


## Writes row [param o] of [param out] into [param net], as FcNetPullNative.pull and FcNetPullWeapons.pull_weapons do.
static func _apply(net: Object, out: PackedInt64Array, o: int, fitted: int) -> void:
	var state: GSFpsState = net.player.controller.state
	var f: PackedFloat64Array = state._f
	var hold := out[o + 2]
	net.net_position = Vector3(f[0], f[1], f[2])
	if (hold & 1) == 0:
		net.net_velocity = Vector3(f[3], f[4], f[5])
	if (hold & 2) == 0:
		net.net_yaw = f[12]
	if (hold & 4) == 0:
		net.net_pitch = state.pitch
	net.net_crouch = state.crouch_fraction
	net.net_flags = out[o]
	net.net_modifiers = GSFpsNetSync.pack_modifiers(state) if not state.modifiers.is_empty() else 0
	net.net_timers2 = out[o + 1]
	var a: GSWeaponArsenal = net.player.weapons.arsenal
	net.net_slot = out[o + 3]
	net.net_fitted = fitted
	net.net_fire_mode = out[o + 4]
	net.net_magazine = out[o + 5]
	net.net_reserve = out[o + 6]
	net.net_reloading = a.is_reloading()
	net.net_switching = a.is_switching()
	net.net_fire_seq = out[o + 7]
	net.net_fire_kind = out[o + 8]
	net.net_charge = out[o + 9]
	net.net_weapon = out[o + 10]


## Hands gs-sim the wire table when Roles has rebuilt it (every build is a new array).
static func _sync_wire() -> void:
	var ids := Roles.wire_ids()
	if not _sent or not is_same(ids, _sent_ids):
		_native.set_wire_ids(ids)
		_sent_ids = ids
		_sent = true
