extends RefCounted

## A living player is never left with an empty arsenal (nightly fc-native-via-gs-app-1: a native client played a whole life with no gun and no ammo counter). Every loadout path ends here: a saved loadout that resolved to nothing, a mode that armed nobody, a weapon pack that delivered late.
## The repair is the default loadout, then any weapon the catalogue has, and it is logged on the `loadout` channel with the catalogue's size, so a log says which gap it was.

const CHANNEL := &"loadout"


## Arms [param player] when its arsenal holds nothing at all; true when it had to. A knife alone is not empty
## (a knife mode is a mode), and a dead player is left alone.
static func ensure_armed(player) -> bool:
	if player == null or player.arsenal == null or not player.is_alive() or not player.arsenal.slots().is_empty():
		return false
	var catalogue = player.arsenal.catalogue
	player.give_default_loadout()
	var how := "default loadout"
	if player.arsenal.slots().is_empty() and catalogue != null:
		how = "first catalogue weapon"
		for id: StringName in catalogue.ids():
			if player.arsenal.give(id).ok:
				break
		var slots: Array = player.arsenal.slots()
		if not slots.is_empty():
			player.hold(slots[0])
	GSLog.warn(CHANNEL, "empty arsenal repaired", {
		"player": player.player_id, "via": how, "now_holding": player.arsenal.slots().size(),
		"catalogue": catalogue.size() if catalogue != null else -1,
	})
	return true
