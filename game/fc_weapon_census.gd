@tool
extends RefCounted

## A per-tick census of the server's weapon tick (cvar `fc_weapon_census`, off in play; read with `--sim_sections 1` or 2):
## which path each player's weapon takes, why a non-idle one is not idle and why an idle one stays off gs-sim's idle batch.
## Each is a `wc_*` count in the SIM_HOST_SECTIONS line (its xN/tick is the number per tick); the `pwx_*` spans split
## p_weapons by path. Reads the rig's and the arsenal's fields by name: diagnostics only, never game logic.

const FcFrameProbe := preload("fc_frame_probe.gd")

static var on := false


## Why [method AwWeaponRig.would_idle] said no for [param player] (the first reason [method GSWeaponArsenal.is_idle_for] meets).
static func active(player: Object) -> void:
	FcFrameProbe.count(&"wc_active")
	FcFrameProbe.count(_active_reason(player))


static func _active_reason(player: Object) -> StringName:
	var rig: Object = player.get(&"weapons")
	var cmd: GSWeaponCommand = player.get(&"_command")
	var ars: GSWeaponArsenal = rig.get(&"arsenal") if rig != null else null
	if ars == null or not rig.get(&"_ready_for_use") or not ars.get(&"_ready_for_use") or ars.disabled:
		return &"wc_a_unready"
	if cmd.is_pressed(GSWeaponCommand.BUTTON_ATTACK):
		return &"wc_a_attack"
	if cmd.buttons != 0:
		return &"wc_a_button"
	if cmd.slot > 0 and cmd.slot != int(ars.get(&"_current")):
		return &"wc_a_switch_cmd"
	var prev: GSWeaponCommand = rig.get(&"_previous_command")
	if prev != null and prev.buttons != 0:
		return &"wc_a_prev_button"
	if int(ars.get(&"_switch_done_tick")) >= 0:
		return &"wc_a_switching"
	if ars.get(&"_reloading"):
		return &"wc_a_reloading"
	if int(ars.get(&"_burst_left")) > 0 or int(ars.get(&"_charge_started")) >= 0 or int(ars.get(&"_buffer_until")) >= 0:
		return &"wc_a_burst_charge"
	if ars.current() == null:
		return &"wc_a_no_slot"
	return &"wc_a_context"


## Why [method AwWeaponRig.idle_batch] handed [param player]'s idle weapon back (the first reason it and
## [method GSWeaponArsenal.idle_batch_add] meet).
static func not_joined(player: Object) -> void:
	FcFrameProbe.count(&"wc_nojoin")
	FcFrameProbe.count(_nojoin_reason(player))


static func _nojoin_reason(player: Object) -> StringName:
	var rig: Object = player.get(&"weapons")
	if not rig.has_method(&"idle_batch"):
		return &"wc_n_old_pack"
	if int(rig.get(&"role")) != 2 or rig.get(&"phase_timers"):
		return &"wc_n_role_timers"
	var ars: GSWeaponArsenal = rig.get(&"arsenal")
	if ars.phase_timers or not ars.idle_posture.is_valid():
		return &"wc_n_arsenal"
	var slot := ars.current()
	if slot == null:
		return &"wc_n_no_slot"
	var b := slot.behaviour
	if not b.has_method(&"_plain_hitscan") or not b.call(&"_plain_hitscan"):
		return StringName("wc_n_kind_" + String(slot.def.id))
	if GSWeaponBehaviour.idle_gate != 1:
		return &"wc_n_idle_gate"
	if int(b.get(&"_native_idle")) != 1:
		return &"wc_n_native_idle"
	var cone := ars.crosshair_cone and ars.spread_rules != null
	if not b.call(&"_tick_gate_holds", ars.spread_rules, cone, ars.tick_rate):
		return &"wc_n_rows_stale"
	if cone and b.get(&"_steady"):
		return &"wc_n_steady_cone"
	return &"wc_n_other"
