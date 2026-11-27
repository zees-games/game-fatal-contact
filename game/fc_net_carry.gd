extends RefCounted
## A person's [member FcPlayerNet.net_carry]: [method FcContent.carry_mask] once per change, not once a tick. The mask
## only moves with what the arsenal carries or the wire table, so it is kept until the arsenal's [code]revision()[/code]
## (gs-weapon API 51: a give, take, drop, cycle, refit or count change), the arsenal itself or the table
## ([method FcWeaponRoles.wire_ids], a new array on each rebuild) moves. It was a shelf walk and a wire lookup per
## weapon on every server tick per person (~10 us of a ~29 us pull). An arsenal without [code]revision()[/code]
## (gs-weapon before 51) is walked every time, as before. Bit for bit with the walk ([code]headless_netpull_weapons_parity[/code]).

const FcContent := preload("fc_content.gd")
const Roles := preload("fc_weapon_roles.gd")

var _arsenal: Object = null
## Whether [member _arsenal] has [code]revision()[/code]: asked once per arsenal, not once a tick.
var _versioned := false
var _revision := 0
var _ids: Array[StringName] = []
var _mask := 0


## [method FcContent.carry_mask] of [param arsenal], from the kept mask while nothing it reads has moved.
func mask(arsenal: GSWeaponArsenal) -> int:
	if arsenal == null:
		return 0
	if arsenal != _arsenal:
		_arsenal = arsenal
		_versioned = arsenal.has_method(&"revision")
		_ids = []
	if not _versioned:
		return FcContent.carry_mask(arsenal)
	var revision: int = arsenal.call(&"revision")
	var ids := Roles.wire_ids()
	if revision == _revision and is_same(ids, _ids):
		return _mask
	_mask = FcContent.carry_mask(arsenal)
	_revision = revision
	_ids = ids
	return _mask
