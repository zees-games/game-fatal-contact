extends RefCounted

## What FcGame's tick asks of the play statistics ([code]fc_demo_stats.gd[/code], which extends this):
## a base it can name without compiling the statistics, which name gs-bot-record's classes. Every
## method here is a no-op; the statistics override them.


## Whether [method after] reads anything of [param _player] this tick: true here, so nothing is skipped.
func after_reads(_player: Object) -> bool:
	return true


## After [param _player] simulated a tick with [param _move] and [param _fire].
func after(_id: int, _player: Object, _move: GSFpsCommand, _fire: GSWeaponCommand, _tick: int) -> void:
	pass


## Once a frame.
func process(_delta: float) -> void:
	pass


## Breaks the callables pointing back at the statistics.
func release() -> void:
	pass
