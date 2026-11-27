extends "fc_bots_world_nav.gd"

## The bots' line of sight against the game's shot trace, between [code]fc_bots_world_nav.gd[/code]'s routes and
## [code]fc_bots_world.gd[/code]'s contacts: what sight asks of the game, bound once a tick, and the one-query ray.


class SightWorld:
	extends NavWorld

	## What sight asks of the game, looked up by name once a tick (and again on a map change) rather than on every
	## ray: the shot trace, that trace when it is a plain physics one ([method _sight_ray]), the jail glass rule and
	## the map's collision root.
	var _los_at: int = -2
	var _los_trace: GSTrace = null
	var _los_ray: GSTracePhysics = null
	var _los_cell: GSMapGlassSight = null
	var _los_root: Node3D = null

	func _los_bind() -> void:
		_los_at = _tick
		var combat: Variant = game.get(&"combat")  # perf-lint: allow dynamic_call once a tick, not per ray
		var trace: Variant = (combat as Object).get(&"trace") if combat is Object else null  # perf-lint: allow dynamic_call once a tick, not per ray
		_los_trace = trace as GSTrace if trace is GSTrace else null
		_los_ray = trace as GSTracePhysics if trace is GSTracePhysics and _plain_sight_trace(trace as Object) else null
		var rules: Variant = game.get(&"glass_rules")  # perf-lint: allow dynamic_call once a tick, not per ray
		_los_cell = rules as GSMapGlassSight if rules is GSMapGlassSight else null
		var map: Variant = game.get(&"map")  # perf-lint: allow dynamic_call once a tick, not per ray
		var root: Variant = (map as Object).get(&"collision_root") if map is Object else null  # perf-lint: allow dynamic_call once a tick, not per ray
		_los_root = root as Node3D if root is Node3D else null

	func _shot_trace() -> GSTrace:
		if _los_at != _tick:
			_los_bind()
		return _los_trace

	## The map's collision root when the jail glass rule is on and the root is in the tree, else null.
	func _cell_root() -> Node3D:
		if _los_cell == null or not _los_cell.block_sight or _los_root == null or not is_instance_valid(_los_root):
			return null
		return _los_root if _los_root.is_inside_tree() else null

	## A trace's sight glass ([code]fc_glass_trace.gd[/code]'s), or null.
	static func _trace_glass(trace: Object) -> GSMapGlassSight:
		var g: Variant = trace.get(&"glass") if trace != null else null  # perf-lint: allow dynamic_call once a tick or per par_begin, not per ray
		return g as GSMapGlassSight if g is GSMapGlassSight and (g as GSMapGlassSight).glass_mask != 0 else null

	## The trace's own line_of_sight is a [GSHitbox.Hit] world ray: two Hit objects and, on a hit, the surface's
	## material looked up, all of which a yes/no sight drops. Only the plain physics trace and the glass one (whose
	## sight ray leaves the glass layer out) take this path; any other trace keeps its own rules.
	const _GLASS_TRACE := preload("fc_glass_trace.gd")
	var _sight_query: PhysicsRayQueryParameters3D = _make_sight_query()
	## The sight mask of [member _mask_trace] on tick [member _mask_at] (its glass is looked up by name), and the
	## space of its world [member _sight_world], bound by [method _bind_sight_ray] rather than read on every ray.
	var _mask_trace: GSTracePhysics = null
	var _mask_at: int = -2
	var _mask: int = 0
	var _sight_world: World3D = null
	var _sight_space: PhysicsDirectSpaceState3D = null

	static func _plain_sight_trace(trace: Object) -> bool:
		var script: Variant = trace.get_script()
		return script == _GLASS_TRACE or script == GSTracePhysics

	## [method GSTrace.line_of_sight] on a [GSTracePhysics] (and [code]fc_glass_trace.gd[/code]'s sight mask), the
	## same answer from one ray query; headless_bots checks both agree.
	func _sight_ray(trace: GSTracePhysics, from: Vector3, to: Vector3) -> bool:
		var offset := to - from
		var distance := offset.length()
		if distance <= 0.0001:
			return true
		var bound: World3D = trace._world
		if bound == null:
			return true
		if trace != _mask_trace or _mask_at != _tick or bound != _sight_world:
			_bind_sight_ray(trace, bound)
		if _sight_space == null:
			return true
		_sight_query.from = from
		_sight_query.to = from + offset / distance * distance
		_sight_query.collision_mask = _mask
		_sight_query.exclude = trace.exclude_rids
		return _sight_space.intersect_ray(_sight_query).is_empty()

	## The trace's sight mask and its world's space for [method _sight_ray]: once a tick (or when the trace or its
	## world changes), not per ray.
	func _bind_sight_ray(trace: GSTracePhysics, bound: World3D) -> void:
		_mask_trace = trace
		_mask_at = _tick
		_sight_world = bound
		_sight_space = bound.direct_space_state
		_mask = _sight_mask(trace)

	static func _make_sight_query() -> PhysicsRayQueryParameters3D:
		var q := PhysicsRayQueryParameters3D.new()
		q.collide_with_areas = false
		q.collide_with_bodies = true
		q.hit_from_inside = false
		return q

	## The physics trace's collision mask without its sight glass layer.
	static func _sight_mask(trace: GSTracePhysics) -> int:
		var glass := _trace_glass(trace)
		return trace.collision_mask & ~glass.glass_mask if glass != null else trace.collision_mask
