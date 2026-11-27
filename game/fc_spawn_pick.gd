extends RefCounted
## gs-spawn's `scatter` draw (`GSSpawnScoring.pick_scatter`), the same picks from the same rng, with the weights from gs-sim's `GSSimSpawnPick`
## (bit for bit; the script's `scatter_damping` otherwise) and one batched sight question per drawn site ([param seen_any]). Cvar `fc_spawn_native`
## 0 leaves the pick to gs-spawn, the parity reference. Typed loosely so a build whose gs-sim lacks the class still parses.

## Cvar `fc_spawn_native`: 0 is gs-spawn's own scatter pick.
static var native := true
## gs-sim's spawn kernel, or null without the library (or with one older than the class).
static var _kernel: Object = ClassDB.instantiate(&"GSSimSpawnPick") if ClassDB.class_exists(&"GSSimSpawnPick") else null


## Whether the weights are drawn natively.
static func has_kernel() -> bool:
	return _kernel != null


## The scatter pick over [param pool], or null when no site has weight. [param seen_any] answers
## `(at: Vector3, enemies: Array) -> bool`. [param use_kernel] false computes the weights in script (the parity check's other arm).
static func pick(
	rules: GSSpawnRules,
	recent: Array[Vector3],
	pool: Array[GSSpawnSite],
	context: Dictionary,
	rng: RandomNumberGenerator,
	seen_any: Callable,
	use_kernel: bool = true
) -> GSSpawnSite:
	if pool.is_empty():
		return null
	var enemies: Array = context.get("enemies", [])
	var weights := _weights(rules, recent, pool, enemies, use_kernel and _kernel != null)
	var n := pool.size()
	var total: float = weights[n]
	if total <= 0.0:
		return null
	var can_see: Variant = context.get("can_see", null)
	var checks: bool = can_see is Callable and (can_see as Callable).is_valid() and not enemies.is_empty() and rules.scatter_seen_factor < 1.0
	var drawn: GSSpawnSite = null
	for attempt in 8:
		drawn = pool[_draw(weights, rng.randf() * total, use_kernel and _kernel != null)]
		if not checks or not bool(seen_any.call(drawn.position, enemies)):
			return drawn
		if rng.randf() < rules.scatter_seen_factor:
			return drawn
	return drawn


## Every site's weight, then their sum.
static func _weights(rules: GSSpawnRules, recent: Array[Vector3], pool: Array[GSSpawnSite], enemies: Array, kernel: bool) -> PackedFloat64Array:
	var n := pool.size()
	if kernel:
		var at := PackedVector3Array()
		var own := PackedFloat64Array()
		at.resize(n)
		own.resize(n)
		for i in n:
			at[i] = pool[i].position
			own[i] = pool[i].weight
		return _kernel.scatter_weights(at, own, PackedVector3Array(recent), PackedVector3Array(enemies),
			rules.scatter_min_gap, rules.scatter_radius, rules.scatter_enemy_radius)
	var out := PackedFloat64Array()
	out.resize(n + 1)
	var total := 0.0
	for i in n:
		var w := maxf(pool[i].weight, 0.0)
		if w > 0.0:
			w *= GSSpawnScoring.scatter_damping(rules, recent, pool[i].position, enemies)
		out[i] = w
		total += w
	if total <= 0.0:
		for i in n:
			out[i] = maxf(pool[i].weight, 0.0)
			total += out[i]
	out[n] = total
	return out


## The cumulative draw: the first site with weight whose running sum reaches [param roll], else the last.
static func _draw(weights: PackedFloat64Array, roll: float, kernel: bool) -> int:
	if kernel:
		return int(_kernel.draw(weights, roll))
	var n := weights.size() - 1
	for i in n:
		roll -= weights[i]
		if roll <= 0.0 and weights[i] > 0.0:
			return i
	return n - 1


## How many of [param standing] stand within [param radius] of each site, or an empty array without the library.
static func occupancy(sites: PackedVector3Array, standing: PackedVector3Array, radius: float) -> PackedInt32Array:
	if _kernel == null:
		return PackedInt32Array()
	return _kernel.occupancy(sites, standing, radius)
