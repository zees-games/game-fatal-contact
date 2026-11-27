extends "fc_bots_world_nav.gd"
## The bots' sight: the line-of-sight ray a brain asks, on the main thread or on a worker, over the map's PVS, the
## jail glass rule and gs-sim's native sight ray. [code]fc_bots_world.gd[/code]'s World is this with the contacts.

const FcBotPvs := preload("fc_bot_pvs.gd")


class SightWorld:
	extends NavWorld

	## The map's PVS before each sight ray (cvar `fc_bot_pvs`), bound by World.refresh.
	var pvs := FcBotPvs.new()
	## Whether the jail glass rule applies to rays on workers, set by World.par_begin.
	var _par_glass: bool = false

	func _los_par(from: Vector3, to: Vector3) -> bool:
		if _par_glass:
			_ray_lock.lock()
			var shut := _los_cell.blocks(_par_space, from, to)
			_ray_lock.unlock()
			if shut:
				return false
		if not _par_physics:
			return _par_trace.line_of_sight(from, to)
		var distance := from.distance_to(to)
		if distance <= 0.0001:
			return true
		var glass := _glass_of_trace()
		var base: int = _par_trace.collision_mask
		return _ray_par(from, from + (to - from) / distance * distance, (base & ~glass.glass_mask) if glass != null else base).is_empty()

	func line_of_sight(from: Vector3, to: Vector3) -> bool:
		if par:
			if pvs.active != null and not pvs.open(from, to):
				return _pvs_ruled_out(from, to)
			return _los_par(from, to)
		var t_los := Time.get_ticks_usec()
		var seen := _pvs_ruled_out(from, to) if pvs.active != null and not pvs.open(from, to) else _line_of_sight(from, to)
		FcFrameProbe.add(&"bot_los", t_los)
		return seen

	## A sight the map's PVS ruled out: blocked; with `fc_bot_pvs_verify`, the ray's own answer, a clear one counted.
	func _pvs_ruled_out(from: Vector3, to: Vector3) -> bool:
		if not FcBotPvs.verify:
			return false
		var seen := _los_par(from, to) if par else _line_of_sight(from, to)
		FcBotPvs.ruled_out_but(seen)
		return seen

	func _line_of_sight(from: Vector3, to: Vector3) -> bool:
		if _los_at != _tick:
			_los_bind()
		# Bots inside the jail cell cannot see out through its glass; the trace itself ignores that layer for sight.
		var root := _cell_root()
		if root != null and _los_cell.blocks(root.get_world_3d().direct_space_state, from, to):
			return false
		if _los_ray != null:
			return _sight_ray(_los_ray, from, to)
		if _los_trace != null:
			return _los_trace.line_of_sight(from, to)
		return true

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

	func _on_map_changed(_map: Object) -> void:
		_los_at = -2
		_sight_at = -1
		_nav_at = -2
		_graph_at = -2

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
	var _sight_query: PhysicsRayQueryParameters3D = null
	## The sight mask of [member _mask_trace] on tick [member _mask_at] (its glass is looked up by name).
	var _mask_trace: GSTracePhysics = null
	var _mask_at: int = -2
	var _mask: int = 0

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
		var space := bound.direct_space_state
		if space == null:
			return true
		if trace != _mask_trace or _mask_at != _tick:
			_mask_trace = trace
			_mask_at = _tick
			_mask = _sight_mask(trace)
		if _sight_query == null:
			_sight_query = PhysicsRayQueryParameters3D.new()
			_sight_query.collide_with_areas = false
			_sight_query.collide_with_bodies = true
			_sight_query.hit_from_inside = false
		_sight_query.from = from
		_sight_query.to = from + offset / distance * distance
		_sight_query.collision_mask = _mask
		_sight_query.exclude = trace.exclude_rids
		return space.intersect_ray(_sight_query).is_empty()

	## The physics trace's collision mask without its sight glass layer.
	static func _sight_mask(trace: GSTracePhysics) -> int:
		var glass := _trace_glass(trace)
		return trace.collision_mask & ~glass.glass_mask if glass != null else trace.collision_mask

	## Whether a native mind may ask sight of gs-sim's [code]GSSimSightRay[/code] (when loaded) in place of
	## [method line_of_sight]; off: every ray goes through script (scale128 [code]--native-sight 0[/code]).
	static var native_sight: bool = true
	## The native ray (a GSSimSightRay), made once when the class is loaded; null: script only.
	var _sight_native: Object = null
	var _sight_tried: bool = false
	## [method sight_callable]'s answer while a tick's brains think on workers, bound by [method par_begin].
	var _sight_par: Callable = Callable()
	## [method sight_callable]'s answer on the main thread, bound once per tick ([member _sight_at]).
	var _sight_main: Callable = Callable()
	var _sight_at: int = -1

	## gs-bot's hook: the native ray's [code]clear[/code] when this world's sight is the one plain engine ray
	## [method _sight_ray] / [method _los_par] ask (a plain physics or glass trace; the jail glass rule goes with it),
	## bound to that ray's space, mask and exclusions; else [method line_of_sight]. The same answer to the bit.
	func sight_callable() -> Callable:
		if par:
			return _sight_par
		if _sight_at != _tick or not _sight_main.is_valid():
			_sight_at = _tick
			_sight_main = _sight_bind()
		return _sight_main

	## The native ray bound to this moment's trace, or [method line_of_sight] when the ray does not answer the same.
	func _sight_bind(for_par: bool = false) -> Callable:
		var script_sight := line_of_sight
		if not native_sight:
			return script_sight
		if not _sight_tried:
			_sight_tried = true
			if ClassDB.class_exists(&"GSSimSightRay"):
				_sight_native = ClassDB.instantiate(&"GSSimSightRay")
		if _sight_native == null:
			return script_sight
		# The jail glass rule, as _line_of_sight (main thread: the collision root's space) and _los_par
		# (par_begin's space) ask it: the native ray asks it too, for rays from inside the cell.
		if _los_at != _tick:
			_los_bind()
		var trace := _los_ray
		if trace == null:
			return script_sight
		var root := _cell_root()
		var cell: GSMapGlassSight = _los_cell if root != null else null
		var cell_space: PhysicsDirectSpaceState3D = null
		if cell != null:
			cell_space = _par_space if for_par else root.get_world_3d().direct_space_state
		var bound: World3D = trace._world
		var space: PhysicsDirectSpaceState3D = bound.direct_space_state if bound != null else null
		# GSSimSightRay is a native class only some builds have, so it is called by name, once a tick.
		_sight_native.call(&"bind", space, _sight_mask(trace), trace.exclude_rids, _ray_lock,
				cell_space, cell.glass_mask if cell != null else 0, cell.centre if cell != null else Vector3.ZERO,
				cell.radius if cell != null else 0.0, cell.radius + cell.margin if cell != null else 0.0)
		return Callable(_sight_native, &"clear")
