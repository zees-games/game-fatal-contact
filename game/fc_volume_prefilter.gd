extends RefCounted

## Which players are clear of every map volume this tick, asked of gs-sim's [code]GSSimVolumes[/code] in one
## call for the whole batched loop, or per player in the one-by-one loop ([method mark_one], tick start and end)
## (cvar [code]fc_mechanics_native[/code]). On an imported map with no volumes everyone is clear without a call. A player marked clear skips the map's
## pushes, gravity, conveyors, ladders, water and pits in [method FcPlayerBuild.tick_post_head]: none of them can
## touch a hull that started the tick this far from every box and moved at most [constant SLACK] since.
## The reaches are generous on purpose (a hull reaches 0.5 m sideways, 1.8 m up and 0.05 m down); the player's
## own check ([method FcPlayerBuild._volumes_fit]) refuses the skip for a body that outgrows them.
## Bit for bit with the script's [method clear_of_script]: [code]headless_mechanics_native_parity[/code].

## The furthest a player may have moved from where the tick started and still take the skip, in metres.
const SLACK := 1.0
## How far below (and to each side of) a box's faces a tick start still counts as near it.
const BELOW := Vector3(3.0, 3.0, 3.0)
## How far above a box's faces a tick start still counts as near it (the hull's height and the swimmer's waist).
const ABOVE := Vector3(3.0, 5.0, 3.0)

var _native: Object = null
var _key := PackedInt64Array()
var _usable := false
var _boxes := 0
var _pair := PackedVector3Array([Vector3.ZERO, Vector3.ZERO])
var _marked: Array = []
var _points := PackedVector3Array()


## Every box a map's mechanics or pits can act through.
static func boxes_of(map: Object) -> Array[AABB]:
	var out: Array[AABB] = []
	var mech: Object = map.mechanics
	if mech != null:
		for list: Array in [mech.pushes, mech.gravity, mech.conveyors]:
			for entry: Dictionary in list:
				out.append(entry["box"])
		out.append_array(mech.water)
		out.append_array(mech.ladders)
	for pit: Dictionary in map.pits:
		out.append(pit["box"])
	return out


## The script's answer, for the parity suite: 1 where [param point] is clear of every box grown by
## [param below] under its low corner and [param above] over its high one (a face counts as near), else 0.
## A point that is not finite is never clear. Boxes of negative size are read as their [method AABB.abs].
static func clear_of_script(boxes: Array[AABB], points: PackedVector3Array, below: Vector3, above: Vector3) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(points.size())
	for i in range(points.size()):
		var p := points[i]
		var clear := p.is_finite()
		if clear:
			for raw in boxes:
				var b := raw.abs()
				var lo := b.position - below
				var hi := b.end + above
				if p.x >= lo.x and p.x <= hi.x and p.y >= lo.y and p.y <= hi.y and p.z >= lo.z and p.z <= hi.z:
					clear = false
					break
		out[i] = 1 if clear else 0
	return out


## Marks this tick's batched players ([param rows] other than -1) whose tick start is clear: their
## [code]_volumes_clear_tick[/code] becomes [param tick]. Off the map's volumes, or without the library, marks nobody.
func mark(tick: int, ids: Variant, players: Dictionary, rows: PackedInt32Array) -> void:
	_marked.clear()
	_points.clear()
	for i in range(ids.size()):
		if rows[i] == -1:
			continue
		var player: Object = players[ids[i]]
		player._volumes_asked_tick = tick
		_marked.append(player)
		_points.append(player._tick_start)
	if _marked.is_empty() or not _ready_for(_marked[0]._map):
		return
	if _boxes == 0:
		for player: Object in _marked:
			player._volumes_clear_tick = tick
		return
	var clear: PackedByteArray = _native.clear_of(_points, BELOW, ABOVE)
	for k in range(_marked.size()):
		if clear[k] == 1:
			_marked[k]._volumes_clear_tick = tick


## The one-by-one loop's question, after [param player]'s motor ran: clear when both its tick start and where
## the motor left it are clear (its [code]_volumes_clear_tick[/code] becomes [param tick]).
func mark_one(tick: int, player: Object) -> void:
	player._volumes_asked_tick = tick
	if not _ready_for(player._map):
		return
	if _boxes > 0:
		_pair[0] = player._tick_start
		_pair[1] = player.controller.state.position
		var clear: PackedByteArray = _native.clear_of(_pair, BELOW, ABOVE)
		if clear[0] == 0 or clear[1] == 0:
			return
	player._volumes_clear_tick = tick


## Builds the volume set when the map (or what it holds) changed; false when the skip cannot be used here.
func _ready_for(map: Object) -> bool:
	if map == null or not map.is_imported():
		return false
	var mech: Object = map.mechanics
	var key := PackedInt64Array([map.get_instance_id(), map.pits.size()])
	if mech != null:
		key.append_array([mech.get_instance_id(), mech.pushes.size(), mech.gravity.size(), mech.conveyors.size(),
				mech.water.size(), mech.ladders.size()])
	if key == _key:
		return _usable
	_key = key
	var boxes := boxes_of(map)
	_boxes = boxes.size()
	# No volumes: nothing to ask, so no library needed. Otherwise without gs-sim's volumes module nobody is marked.
	_usable = _boxes == 0 or GSSim.has(&"volumes")
	if _boxes > 0 and _usable:
		if _native == null:
			_native = ClassDB.instantiate(&"GSSimVolumes")
		_native.clear()
		_native.add_boxes(boxes)
	return _usable
