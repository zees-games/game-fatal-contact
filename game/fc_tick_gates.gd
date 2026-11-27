extends RefCounted
## Exact skips inside the batched players loop (docs/native-server-tick.md, lanes `knife` and `flush`): work a
## player provably does not need this tick is not called, and the state after is the called path's bit for bit.
##
## The batched pass1's knife gate (cvar `fc_knife_gate`, docs/native-server-tick.md): most players most ticks
## neither hold the aim key nor held it last tick nor wind up a throw, and for them [method GSWeaponKnives.input]
## changes nothing and [method GSWeaponKnives.charge_of] is -1. The gate answers that from three lookups
## instead of the two calls, so the skipped and the called tick leave the same state (examples/headless_tick_gates_parity).
##
## Why the skip is exact: with the key up, input only writes `_aim_held[id] = false` (already false, or absent and
## read as false), and with no `_charge[id]` it neither releases nor cancels. Every early return of input (not the
## authority, no arsenal, rules off) writes no more than that. The gate reads the knives' own state, never a mirror,
## so a [method GSWeaponKnives.clear] or a call that returned early cannot leave it stale.
## TODO(gs_weapon): an `idle_for(id, fire) -> bool` on GSWeaponKnives would replace the two private reads.

## Cvar [code]fc_knife_gate[/code]: 1 skips the knife calls for an idle player (bit for bit); 0 calls them for everyone.
static var knife_gate := true
## Cvar [code]fc_flush_idle_skip[/code]: 1 lets tb_flush post an idle, unprotected player's outcome (no shots, no
## spawns, not spawn protected) in place, which is all [code]_post_outcome[/code] does for one; 0 calls it for everyone.
static var flush_idle_skip := true


## True when [param id]'s knife input this tick is a no-op and its windup is -1 (key up, not held last tick, not winding up).
static func idle(knives: GSWeaponKnives, id: int, fire: GSWeaponCommand) -> bool:
	if fire == null or fire.is_pressed(GSWeaponCommand.BUTTON_AIM):
		return false
	return not knives._aim_held.get(id, false) and not knives._charge.has(id)


## Pass1's knife step for one player: the gate when [member knife_gate], else the calls. Returns true when it skipped.
static func step(knives: GSWeaponKnives, id: int, player, fire: GSWeaponCommand, knife_charge: bool) -> bool:
	if knife_gate and idle(knives, id, fire):
		player.windup = -1.0
		return true
	knives.input(id, player, fire)
	# By name: charge_of is gs_weapon 41+, which knife_charge has checked.
	player.windup = knives.call(&"charge_of", id) if knife_charge else -1.0  # perf-lint: allow dynamic_call older gs_weapon, only for a non-idle player
	return false


## True when [param outcome] did nothing the flush hands on (no shots, no spawns) for a player outside spawn
## protection at [param tick]: its post is then only the protection reset ([member flush_idle_skip]).
static func idle_outcome(outcome: GSWeaponOutcome, health: GSHealth, tick: int) -> bool:
	return outcome.shots.is_empty() and outcome.spawns.is_empty() and not health.is_protected(tick)
