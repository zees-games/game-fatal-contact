@tool
extends "fc_game_idle.gd"

## The batched loop's per-player command input (weapon drop, knife, activity, surf ride); split out of
## fc_game_tick.gd for file size.


## Ticks between two activity notes of one player (`sv_activity_every`; 1 or less = every tick, as before). The idle
## check ([method GSMatch._check_idle]) only asks whether a player sent a command within `idle_seconds` (180 s by
## default), so a note every 8 ticks (0.12 s at 66 Hz) gives it the same answer; each note was a [code]str(id)[/code]
## and a scoreboard lookup per player per tick (pp_note, 0.19 ms a tick at 64 bots). Never more than a quarter of the
## idle threshold, so a short idle time still sees every active player in time.
var activity_every := 8

var _activity_tick := -1
var _activity_stride := 1


## [method GSMatch.note_activity] for [param id] on this tick's stride (offset by id, so the notes spread over the ticks).
func _note_activity(id: int) -> void:
	if _activity_tick != _tick:
		_activity_tick = _tick
		var config := match_node.config
		var threshold := int(config.idle_seconds * float(config.tick_rate)) if config != null else 0
		_activity_stride = clampi(mini(activity_every, threshold / 4), 1, maxi(activity_every, 1))
	if _activity_stride > 1 and posmod(_tick + id, _activity_stride) != 0:
		return
	match_node.note_activity(str(id), _tick)


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
	_note_activity(id)
	t_lap = FcFrameProbe.lap(&"pp_note", t_lap)
	if surfing:
		surf_rides.call(&"before_synced", id, player)
	elif not FcPlayer.lean_tick and surf_rides != null:
		surf_rides.call(&"before", id, player)
	FcFrameProbe.lap(&"pp_surf", t_lap)
	return pair if pair.size() == 2 else [move, fire]
