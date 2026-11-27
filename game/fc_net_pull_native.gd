extends RefCounted
## A player's movement pull in one gs-sim call ([code]GSSimFpsNetPack.pull[/code]), writing what [method GSFpsNetSync.pull] then
## [method FcPlayerNet._hold_subquantum] write, to the bit ([code]headless_netpull_native_parity[/code]). One per FcPlayerNet; takes the net
## as an Object because a typed reference back would make the two scripts a compile cycle.

## Whether [method FcPlayerNet.pull] goes through gs-sim where the library has it (cvar [code]sv_net_pull_native[/code],
## default on). Off, no library, or a declaration this cannot mirror runs the script.
static var enabled := true
static var _pack: Object = null
static var _pack_tried := false
## Widths of 0: nothing is held ([member FcPlayerNet.hold_subquantum] off).
const _NO_HOLD := [0.0, 0.0, 0.0, 0.0]

## [code][max_speed, velocity_bits, yaw_bits, pitch_bits][/code] built for [member _wire_config] (gs-net binds a
## declaration's config after [method FcPlayerNet._register_net_vars]); empty when only the script can decide.
var _wire := PackedFloat64Array()
var _wire_config: Object = null
var _wire_built := false


## gs-sim's [code]GSSimFpsNetPack[/code] when the library has its [code]pull[/code], else null. Made once.
static func native_pack() -> Object:
	if not _pack_tried:
		_pack_tried = true
		if ClassDB.class_exists(&"GSSimFpsNetPack") and ClassDB.class_has_method(&"GSSimFpsNetPack", &"pull"):
			_pack = ClassDB.instantiate(&"GSSimFpsNetPack")
	return _pack


## Writes [param net]'s movement fields from its player's state, keeping each held value that would send the code
## already on the wire ([param hold]: [member FcPlayerNet.hold_subquantum]); false (nothing written) where the script must run instead. Reads the state's columns
## ([code]GSFpsState._f[/code]) as GSFpsNetSync's own native pull does.
func pull(net: Object, hold_subquantum: bool, held_velocity: Vector3, held_yaw: float, held_pitch: float) -> bool:
	var pack := native_pack()
	if pack == null:
		return false
	var wire: PackedFloat64Array = _wire_for(net) if hold_subquantum else PackedFloat64Array(_NO_HOLD)
	if wire.is_empty():
		return false
	var state: GSFpsState = net.player.controller.state
	var f: PackedFloat64Array = state._f
	var codes: PackedInt64Array = pack.pull(f, state.crouch_held, GSFpsNetSync.timer_scale, state.stamina,
		state.stamina_exhausted, state.stamina_delay_left, state.pitch, held_velocity, held_yaw, held_pitch, wire)
	if codes.size() < 5:
		return false
	var hold := codes[4]
	net.net_position = Vector3(f[0], f[1], f[2])
	if (hold & 1) == 0:
		net.net_velocity = Vector3(f[3], f[4], f[5])
	if (hold & 2) == 0:
		net.net_yaw = f[12]
	if (hold & 4) == 0:
		net.net_pitch = state.pitch
	net.net_crouch = state.crouch_fraction
	net.net_flags = codes[0]
	net.net_modifiers = GSFpsNetSync.pack_modifiers(state) if not state.modifiers.is_empty() else 0
	net.net_timers2 = codes[2]
	return true


## Forgets the built widths, for a declaration changed in place.
func invalidate() -> void:
	_wire_built = false


## The widths [method FcPlayerNet._hold_subquantum] compares through: a missing declaration is width 0 (never held);
## a velocity gs-net quantises some other way, or a width past 62 bits, is empty (the script decides).
func _wire_for(net: Object) -> PackedFloat64Array:
	var velocity_var: GSNetVar = net._velocity_var
	var yaw_var: GSNetVar = net._yaw_var
	var pitch_var: GSNetVar = net._pitch_var
	var config: Object = velocity_var._config if velocity_var != null else null
	if _wire_built and config == _wire_config:
		return _wire
	_wire_built = true
	_wire_config = config
	_wire = PackedFloat64Array()
	var speed := 0.0
	var velocity_bits := 0
	if velocity_var != null:
		speed = velocity_var._max_speed()
		velocity_bits = velocity_var._velocity_bits()
		if not (speed > 0.0 and velocity_bits >= 1 and velocity_bits <= 62):
			return _wire
	var yaw_bits := yaw_var.bit_width if yaw_var != null else 0
	var pitch_bits := pitch_var.bit_width if pitch_var != null else 0
	if yaw_bits > 62 or pitch_bits > 62:
		return _wire
	_wire = PackedFloat64Array([speed, velocity_bits, yaw_bits, pitch_bits])
	return _wire
