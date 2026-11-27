@tool
extends "fc_game_idle.gd"

## The batched loop's per-player command input (weapon drop, knife, activity, surf ride); split out of
## fc_game_tick.gd for file size.


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
		surf_rides.call(&"before_synced", id, player)
	elif not FcPlayer.lean_tick and surf_rides != null:
		surf_rides.call(&"before", id, player)
	FcFrameProbe.lap(&"pp_surf", t_lap)
	return pair if pair.size() == 2 else [move, fire]
