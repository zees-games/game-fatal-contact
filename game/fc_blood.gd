extends GSFxBlood
## Blood on the surface behind a body the local player hit, from the HIT event the server already sends.


## The server confirmed a hit on [param victim] at [param point], seen from [param from]. Null for a victim that is not a body.
func on_body_hit(victim: int, point: Vector3, from: Vector3, reach: float = 4.0) -> Node3D:
	var kind := GSEntity.kind_of(victim)
	if kind != GSEntity.KIND_PLAYER and kind != GSEntity.KIND_NPC:
		return null
	return splat_behind(from, point, reach, 0.8)
