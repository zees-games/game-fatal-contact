extends RefCounted
## A person's [member FcPlayerNet.net_carry]: [method FcContent.carry_mask] once per change of the arsenal's [code]revision()[/code]
## (gs-weapon API 51), the arsenal or the wire table, not once a tick; an arsenal without [code]revision()[/code] is walked every time.
## Bit for bit with the walk ([code]headless_netpull_weapons_parity[/code]).

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
