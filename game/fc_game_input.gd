@tool
extends "fc_game_idle.gd"

## The batched loop's per-player command input (weapon drop, knife, activity, surf ride) and the countdown's round
## freeze; split out of fc_game_tick.gd for file size.


## A player's command input before its controller ticks (weapon drop, knife, activity note, surf ride), with
## [code]pp_*[/code] laps from [param t_fine]: the command pair as it came (no new two-item array per player per tick),
## or empty when the move or fire command is null.
func _batched_input(id: int, player: FcPlayer, pair: Array, knife_charge: bool, surfing: bool, t_fine: int) -> Array:
	var t_lap := t_fine
	FcWeaponDropWiring.input(self, id, player, pair)
	t_lap = FcFrameProbe.lap(&"pp_drop", t_lap)
	var move: GSFpsCommand = pair[0] if pair.size() > 0 else GSFpsCommand.new()
	var fire: GSWeaponCommand = pair[1] if pair.size() > 1 else GSWeaponCommand.new()
	if knives != null:
		knives.input(id, player, fire)
		player.windup = knives.call(&"charge_of", id) if knife_charge else -1.0
	t_lap = FcFrameProbe.lap(&"pp_knife", t_lap)
	if move == null or fire == null:
		return []
	match_node.note_activity(player.score_key if player.player_id == id else str(id), _tick)
	t_lap = FcFrameProbe.lap(&"pp_note", t_lap)
	if surfing:
		surf_rides.before_synced(id, player)
	elif not FcPlayer.lean_tick and surf_rides != null:
		surf_rides.before(id, player)
	FcFrameProbe.lap(&"pp_surf", t_lap)
	return pair if pair.size() == 2 else [move, fire]


## Whether the round is waiting to go live with everyone held still. The client reads the
## state MATCH told it; a countdown only exists when its length is above zero.
func round_frozen() -> bool:
	return match_node != null and match_node.state == GSMatch.State.COUNTDOWN \
			and match_node.rules != null and match_node.rules.freeze_during_countdown

func _freeze_for_round(id: int, player: FcPlayer) -> void:
	if _round_frozen_ids.has(id) or GSFpsAdminModifiers.is_frozen(player.controller):
		return
	var held := {"god": player.health.invulnerable}
	_round_frozen_ids[id] = held
	player.health.invulnerable = true
	player.arsenal.disabled = true
	var _r := GSFpsAdminModifiers.set_frozen(player.controller, true)

func _release_from_round(id: int, player: FcPlayer) -> void:
	var held: Dictionary = _round_frozen_ids[id]
	_round_frozen_ids.erase(id)
	player.health.invulnerable = bool(held["god"])
	player.arsenal.disabled = false
	var _r := GSFpsAdminModifiers.set_frozen(player.controller, false)

## Holds every living player still, unarmed and unhurtable while [method round_frozen], and
## lets exactly those go afterwards; an admin's own freeze or god mode is left alone.
func _sync_round_freeze() -> void:
	var want := round_frozen()
	_round_frozen_want = want
	for id in player_ids():
		var player: FcPlayer = _players[id]
		if want and player.health.alive:
			_freeze_for_round(id, player)
		elif _round_frozen_ids.has(id):
			_release_from_round(id, player)
