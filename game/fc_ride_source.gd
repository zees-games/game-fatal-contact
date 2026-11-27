extends RefCounted

## What `fc_surf.gd` and FcGame's tick ask of the recorded rides ([code]fc_surf_rides.gd[/code], which
## extends this): a base they can name without preloading the recorder, which preloads it back and
## names gs-bot-record's classes. Every method here is a no-op; the recorder overrides them.


## One of edge [param _edge_id]'s rides if a recording is among them; otherwise empty.
func pick(_edge_id: int) -> Dictionary:
	return {}


## Writes one recorded action into a bot's intent.
func decode(_action: PackedFloat32Array, _state: Variant, _intent: GSBotIntent) -> void:
	pass


## Whether this tick records anything: false here.
func begin_tick() -> bool:
	return false


## Before [param _player] (an FcPlayer) simulates its tick.
func before(_id: int, _player: Object) -> void:
	pass


## Before a player whose command came in synced simulates its tick.
func before_synced(_id: int, _player: Object) -> void:
	pass


## After [param _player] simulated a tick with [param _command].
func after(_id: int, _player: Object, _command: GSFpsCommand, _tick: int) -> void:
	pass


## Once a frame.
func process(_delta: float) -> void:
	pass


## Breaks the callables pointing back at the recorder.
func release() -> void:
	pass
