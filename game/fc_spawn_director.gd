extends GSSpawnDirector
## gs-spawn's director with Fatal Contact's scatter pick ([code]fc_spawn_pick.gd[/code]): the same sites from the same rng,
## the weights in gs-sim and the sight check batched. Every other strategy, and `fc_spawn_native` 0, is gs-spawn's own.
## gs-spawn has no hook for a strategy's pick, so this overrides its internal `_pick_by_strategy` (nightly: a `scatter_fn` hook).

const FcSpawnPick := preload("fc_spawn_pick.gd")

## `(at: Vector3, enemies: Array) -> bool`: whether any enemy sees a site, all of them asked at once.
var seen_any_fn: Callable


func _pick_by_strategy(pool: Array[GSSpawnSite], context: Dictionary, rng: RandomNumberGenerator) -> GSSpawnSite:
	var names := rules.strategies()
	if not FcSpawnPick.native or not seen_any_fn.is_valid() or names.is_empty() or names[0] != "scatter":
		return super(pool, context, rng)
	var picked := FcSpawnPick.pick(rules, _recent, pool, context, rng, seen_any_fn)
	if picked != null:
		return picked
	# No site with weight: gs-spawn's scatter returns null too, before drawing anything, so the same rng runs the rest of the list.
	return super(pool, context, rng)
