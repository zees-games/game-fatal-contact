@tool
extends "fc_game_idle.gd"

## The batched loop's per-player command input (weapon drop, knife, activity, surf ride) and the countdown's round
## freeze; split out of fc_game_tick.gd for file size.


## Ticks between two activity notes of one player (`sv_activity_every`; 1 or less = every tick, as before). The idle
## check ([method GSMatch._check_idle]) only asks whether a player sent a command within `idle_seconds` (180 s by
## default), so a note every 8 ticks (0.12 s at 66 Hz) gives it the same answer; each note was a [code]str(id)[/code]
## and a scoreboard lookup per player per tick (pp_note, 0.19 ms a tick at 64 bots). Never more than a quarter of the
## idle threshold, so a short idle time still sees every active player in time.
var activity_every := 8

var _activity_tick := -1
var _activity_stride := 1


## [method GSMatch.note_activity] for [param id] (its score key [param key]) on this tick's stride (offset by id, so the notes spread over the ticks).
func _note_activity(id: int, key: String) -> void:
	if _activity_tick != _tick:
		_activity_tick = _tick
		var config := match_node.config
		var threshold := int(config.idle_seconds * float(config.tick_rate)) if config != null else 0
		_activity_stride = clampi(mini(activity_every, threshold / 4), 1, maxi(activity_every, 1))
	if _activity_stride > 1 and posmod(_tick + id, _activity_stride) != 0:
		return
	match_node.note_activity(key, _tick)


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
	# With the column on (sv_native_activity), the whole roster is noted every tick in one call after the loop's
	# first pass; off, the script's note on its sv_activity_every stride.
	if not _activity.active:
		_note_activity(id, player.score_key if player.player_id == id else str(id))
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
	_round_frozen_ids[id] = player.health.invulnerable
	player.health.invulnerable = true
	player.arsenal.disabled = true
	var _r := GSFpsAdminModifiers.set_frozen(player.controller, true)

func _release_from_round(id: int, player: FcPlayer) -> void:
	var god: bool = _round_frozen_ids[id]
	_round_frozen_ids.erase(id)
	player.health.invulnerable = god
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
