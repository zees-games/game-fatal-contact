## The server weapon tick's switches: the native idle batch, its lean join and the census of which path each weapon takes.
## Split out of fc_module_cvars.gd for file size.

const FcPlayer := preload("fc_player.gd")
const FcWeaponCensus := preload("fc_weapon_census.gd")


static func add_to(m: GSModule) -> void:
	m.add_cvar("fc_weapon_idle_batch", "1" if FcPlayer.weapon_idle_batch else "0",
		"1: every idle server weapon's native idle step runs in one gs-sim call per tick where its library has GSSimWeaponIdleBatch (bit for bit with one call each); 0: one call each",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcPlayer.weapon_idle_batch = new_value.to_float() >= 0.5)
	m.add_cvar("fc_weapon_census", "1" if FcWeaponCensus.on else "0",
		"1: count each tick which path every server weapon tick takes and why (wc_* and pwx_* in SIM_HOST_SECTIONS; a check, not for play)",
		0).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcWeaponCensus.on = new_value.to_float() >= 0.5)
	# Read and written through the script so an fc-weapons below API 46 (no such flag) still loads; the cvar then does nothing.
	var rig_script: Script = AwWeaponRig
	m.add_cvar("fc_weapon_idle_lean", "0" if rig_script.get(&"idle_batch_lean") == false else "1",
		"1: a server weapon joining the native idle batch writes the rig's idle bookkeeping straight; 0: through the rig's idle helpers (same result, slower)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			rig_script.set(&"idle_batch_lean", new_value.to_float() >= 0.5))
