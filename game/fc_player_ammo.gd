@tool
extends "fc_player_idle.gd"

## Whether any carried weapon's reserve is below its cap: what an ammo pack asks before it
## is taken, so one is left for someone who needs it.
func needs_ammo() -> bool:
	if arsenal == null:
		return false
	for slot_id in arsenal.slots():
		var def: DotWeaponDef = arsenal.slot_at(slot_id).def
		if def != null and def.uses_ammo() and def.ammo_type != &"" and not def.infinite_reserve \
				and arsenal.ammo().count(def.ammo_type) < def.reserve_cap():
			return true
	return false


## Adds [param share] (0 to 1) of every carried weapon's reserve cap to its pool: an ammo pack.
func refill_ammo(share: float) -> void:
	if arsenal == null:
		return
	for slot_id in arsenal.slots():
		var def: DotWeaponDef = arsenal.slot_at(slot_id).def
		if def != null and def.uses_ammo() and def.ammo_type != &"" and not def.infinite_reserve:
			var _added := arsenal.add_ammo(def.ammo_type, int(ceil(float(def.reserve_cap()) * share)))
