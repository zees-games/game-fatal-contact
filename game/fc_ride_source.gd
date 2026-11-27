extends RefCounted

## What `fc_surf.gd` asks of the recorded rides ([code]fc_surf_rides.gd[/code], which extends
## this): a base it can name without preloading the recorder, which preloads it back.


## One of edge [param _edge_id]'s rides if a recording is among them; otherwise empty.
func pick(_edge_id: int) -> Dictionary:
	return {}


## Writes one recorded action into a bot's intent.
func decode(_action: PackedFloat32Array, _state: Variant, _intent: GSBotIntent) -> void:
	pass
