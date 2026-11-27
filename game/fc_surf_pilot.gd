extends RefCounted

## What the bots ask of the surf ([code]fc_surf.gd[/code], which extends this): a base they can
## name without preloading the surf, which needs gs-bot 4 and is only loaded once the shell has it.


## Steers [param _bot] (an FcPlayer) along its ride for this tick; [param _mind] is its FcBotsWorld.Mind.
func steer(_bot: Object, _mind: RefCounted, _intent: GSBotIntent, _tick: int, _tick_rate: float) -> void:
	pass


## A route that may ride or teleport (see [method GSBotNav.route]); empty from this base.
func route_detail(_from: Vector3, _to: Vector3) -> Dictionary:
	return {}
