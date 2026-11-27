extends RefCounted
## A player's weapon pull in one gs-sim call ([code]GSSimFpsWeaponNet.pull[/code]): the fields [method AwWeaponNet.pull], the knife's wind-up
## and [method FcContent.weapon_index] write, to the bit ([code]headless_netpull_weapons_parity[/code]). Static, like the wire table; takes the
## net as an Object because a typed reference back to [code]FcPlayerNet[/code] would make the two scripts a compile cycle.

const FcContent := preload("fc_content.gd")
const Roles := preload("fc_weapon_roles.gd")

## cvar [code]sv_net_pull_weapons_native[/code] (default on): the rig's fields through gs-sim; off, the script.
static var weapons_enabled := true
## cvar [code]sv_net_pull_content_native[/code] (default on): the held weapon's wire number through gs-sim; off, the script.
static var content_enabled := true
static var _native: Object = null
static var _native_tried := false
static var _sent_ids: Array[StringName] = []
static var _sent := false


## gs-sim's [code]GSSimFpsWeaponNet[/code] when the library has its [code]pull[/code], else null. Made once.
static func native() -> Object:
	if not _native_tried:
		_native_tried = true
		if ClassDB.class_exists(&"GSSimFpsWeaponNet") and ClassDB.class_has_method(&"GSSimFpsWeaponNet", &"pull"):
			_native = ClassDB.instantiate(&"GSSimFpsWeaponNet")
	return _native


## Registers both switches on a module ([param add_cvar]: [method GSModule.add_cvar]).
static func bind_cvars(add_cvar: Callable) -> void:
	add_cvar.call("sv_net_pull_weapons_native", "1" if weapons_enabled else "0",
		"1: a player's weapon fields (slot, magazine, reserve, fire counter, charge) are pulled in one gs-sim call where its library has GSSimFpsWeaponNet.pull (bit for bit with the script); 0: the script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(_set_weapons)
	add_cvar.call("sv_net_pull_content_native", "1" if content_enabled else "0",
		"1: the held weapon's wire number comes from gs-sim's copy of the wire table (bit for bit with FcContent.weapon_index); 0: the script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(_set_content)


static func _set_weapons(_old: String, new_value: String) -> void:
	weapons_enabled = new_value.to_float() >= 0.5


static func _set_content(_old: String, new_value: String) -> void:
	content_enabled = new_value.to_float() >= 0.5


## Hands gs-sim the wire table when Roles has rebuilt it (every build is a new array).
static func _sync_wire(n: Object) -> void:
	var ids := Roles.wire_ids()
	if not _sent or not is_same(ids, _sent_ids):
		n.set_wire_ids(ids)
		_sent_ids = ids
		_sent = true


## Writes [param net]'s weapon fields from [param rig] (its arsenal), the wind-up as the charge while
## [param windup] >= 0. Returns the wire number of [param arsenal]'s held weapon when gs-sim worked it out (for
## [method pull_content]), else -1. The script runs where the cvar is off, there is no library, or no rig arsenal.
static func pull_weapons(net: Object, rig: AwWeaponRig, arsenal: GSWeaponArsenal, windup: float) -> int:
	var n := native() if weapons_enabled else null
	if n == null or rig == null or rig.arsenal == null:
		pull_script(net, rig, arsenal, windup)
		return -1
	_sync_wire(n)
	var a := rig.arsenal
	var slot := a.current()
	var has := slot != null
	var fitted := 0
	if has and a.attachments != null and slot.fitting != null:
		var base := a.catalogue.get_def(slot.id())
		if base != null and a.attachments.code_bits(base) <= GSWeaponNetSync.FITTED_BITS:
			fitted = a.attachments.encode(base, slot.fitting)
	var held: GSWeaponDef = arsenal.current_def() if arsenal != null else null
	var r: PackedInt64Array = n.pull(a.current_slot(), has, slot.fire_mode_index if has else 0,
		slot.magazine if has else 0, a.ammo().count(slot.def.ammo_type) if has else 0, rig.fire_seq, rig.fire_kind,
		rig.charge_shown, windup, held.id if held != null else &"")
	net.net_slot = r[0]
	net.net_fitted = fitted
	net.net_fire_mode = r[1]
	net.net_magazine = r[2]
	net.net_reserve = r[3]
	net.net_reloading = a.is_reloading()
	net.net_switching = a.is_switching()
	net.net_fire_seq = r[4]
	net.net_fire_kind = r[5]
	net.net_charge = r[6]
	return r[7] if content_enabled else -1


## The script pull: gs-weapon's three and the pack's four (or gs-weapon's alone without a rig), then the wind-up.
static func pull_script(net: Object, rig: AwWeaponRig, arsenal: GSWeaponArsenal, windup: float) -> void:
	if rig != null:
		AwWeaponNet.pull(rig, net)
	else:
		GSWeaponNetSync.pull(arsenal, net)
	# The knife throw's wind-up rides the charge draw: at least 1 while winding, so 0 still means not winding.
	if windup >= 0.0:
		net.net_charge = maxi(1, roundi(clampf(windup, 0.0, 1.0) * AwWeaponNet.CHARGE_MAX))


## Writes [member FcPlayerNet.net_weapon]: [param code] when [method pull_weapons] already has it, else gs-sim's
## table or [method FcContent.weapon_index].
static func pull_content(net: Object, arsenal: GSWeaponArsenal, code: int) -> void:
	if code >= 0 and content_enabled:
		net.net_weapon = code
		return
	var def := arsenal.current_def() if arsenal != null else null
	var id: StringName = def.id if def != null else &""
	var n := native() if content_enabled else null
	if n == null:
		net.net_weapon = FcContent.weapon_index(id)
		return
	_sync_wire(n)
	net.net_weapon = n.weapon_code(id)
