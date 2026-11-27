extends RefCounted
## A spatial index of the players for [method FcGame.solid_hulls_for] (cvar `fc_hull_grid`): each bot asked for "every living player within a few metres", which scanned the whole roster, 127 reads per bot per tick at 128.
## Built once at the start of the players' loop and moved by one player's cell after that player ticked, so a player moved earlier in the tick is found where it moved to. The caller applies the same filters in roster order, so the answer is the full scan's.

## Players are typed as Node3D on purpose: fc_player.gd reaches this file through
## fc_player_state.gd, and a typed reference back closes a parser cycle GDScript never frees.

const CELL := 6.0
const BIAS := 4096

## Cvar `fc_hull_grid`: 0 scans the whole roster.
static var enabled := true

## Test hook (scale128 --hullverify): every grid answer is also computed by the full scan and compared.
## Cvar `fc_hull_fast`: 0 runs the per-candidate [method FcGame._add_hull] for the grid's candidates.
static var fast := true
## Cvar `fc_hull_native`: with [member fast], a mover that is not lag-compensated gathers its hulls in gs-sim's
## `GSSimHullWorld` (same hulls, no script call per player); 0 or without the library, by script.
static var native := true
## Cvar `fc_motor_batch`: with the hull world, the players' loop prepares every player's tick first and gs-sim ticks
## their motors in runs of one call (`GSSimMotorBatch`, same states to the bit); 0 or without it, one call per player.
static var batch := true
## Players the batched loop found changed by another player's turn (dead, moved or pushed after its own preparation):
## the one-by-one loop would have ticked them differently. A match counts none.
static var batch_faults := 0
## Motor ticks the batch ran, for the tests and the bench.
static var batch_rows := 0
## Whether the batched loop may skip flushing the waiting idle weapon ticks before `demo_stats.after` when its `after_reads(player)` answers
## false (FcDemoStats reads only a recording human's tick); without the method it flushes every time. Off (`fc_demo_flush_gate 0`), every
## player's turn flushes first, so the idle ticks run as one-row gs-sim calls.
static var demo_flush_gate := true
## Non-empty idle-tick flushes (one gs-sim posture call each), for the parity suite.
static var post_flushes := 0
## With [member verify], native gathers checked against the script's (exact AABB equality) and how many differed.
static var native_verified := 0
static var native_mismatches := 0
static var verify := false
static var verified := 0
static var mismatches := 0

## Cvar `fc_hull_grid_native`: where the loop has gs-sim's `GSSimHullWorld` with `near`, the players are filed in its
## cells instead of this script's ([method begin_native]): same answers, the re-file folded into the hull world's
## `turn` call. With [member verify] both are filed and every answer compared ([member grid_native_mismatches]).
static var grid_native := true
static var grid_native_verified := 0
static var grid_native_mismatches := 0

## Below this many players a scan is cheaper than the lookups.
const MIN_PLAYERS := 12
## [constant MIN_PLAYERS], for the bench to move (`--hull-min N`).
static var min_players := MIN_PLAYERS

## True from [method begin] until the players' loop ends.
var live := false
var _cells := {}
var _key_of := PackedInt64Array()
var _index_of := {}
## The hull world filing the cells ([method begin_native]), or null: this script's cells.
var _native: Object = null
## With [member _native], whether this script's cells are filed too (a [member verify] run).
var _scripted := true


static func key_at(at: Vector3) -> int:
	return (int(floorf(at.x / CELL)) + BIAS) * 8192 + int(floorf(at.z / CELL)) + BIAS


static func _key_of_player(p: Node3D) -> int:
	if p == null or p.controller == null or p.controller.state == null:
		return -1
	return key_at(p.controller.state.position)


func begin(roster: Array, ids: PackedInt64Array) -> void:
	_native = null
	_scripted = true
	_cells.clear()
	_index_of.clear()
	_key_of.resize(roster.size())
	for i in range(roster.size()):
		var k := _key_of_player(roster[i])
		_key_of[i] = k
		_index_of[int(ids[i])] = i
		if k >= 0:
			_put(k, i)
	live = true


## Whether [param world] (the loop's `GSSimHullWorld`, begun with this roster) can file the players: the library has
## `near` and [member grid_native] is on.
static func can_file(world: Object) -> bool:
	return grid_native and world != null and world.has_method(&"near")


## Starts the loop with the cells kept in [param world] (it filed the roster in its `begin`, from the same feet); with
## [member verify] this script's cells are filed too ([param roster], [param ids]), for the comparison.
func begin_native(world: Object, roster: Array, ids: PackedInt64Array) -> void:
	if verify:
		begin(roster, ids)
	else:
		_cells.clear()
		_index_of.clear()
	_native = world
	_scripted = verify
	live = true


## Whether the hull world files the cells: the loop then re-files a player with its `turn` and [method moved_script].
func native_filed() -> bool:
	return _native != null


func _put(k: int, i: int) -> void:
	var cell: Variant = _cells.get(k)
	if cell == null:
		_cells[k] = [i]
	else:
		(cell as Array).append(i)


## Player [param id] has just ticked: re-file it if it left its cell.
func moved(id: int, p: Node3D) -> void:
	if _native != null and p != null and p.controller != null:
		var at: Vector3 = p.controller.state.position
		_native.refile(p.hull_slot, at.x, at.z)
	moved_script(id, p)


## The end of [param p]'s turn in the players' loop: re-filed in the cells, standing at [param feet] in [param world]
## for the gathers when [param move_feet], and not alive there when it died. Where the hull world files the cells, one
## gs-sim call (`turn`).
func turned(world: Object, id: int, p: Node3D, feet: Vector3, move_feet: bool, alive: bool) -> void:
	if _native != null:
		world.turn(p.hull_slot, feet.x, feet.y, feet.z, move_feet, not alive)
		moved_script(id, p)
		return
	moved(id, p)
	if move_feet:
		world.moved(p.hull_slot, feet.x, feet.y, feet.z)
	if not alive:
		world.set_alive(p.hull_slot, false)


## [method moved] in this script's cells only (none kept when the hull world files them, outside a [member verify] run).
func moved_script(id: int, p: Node3D) -> void:
	if not _scripted:
		return
	var i: int = _index_of.get(id, -1)
	if i < 0:
		return
	var k := _key_of_player(p)
	var old := _key_of[i]
	if k == old:
		return
	if old >= 0:
		(_cells[old] as Array).erase(i)
	_key_of[i] = k
	if k >= 0:
		_put(k, i)


## Roster indices, ascending, of every player filed within [param reach_sq] (squared metres) of [param at], and some farther: the caller's own distance test decides.
func near(at: Vector3, reach_sq: float) -> Array:
	if _native == null:
		return _near_script(at, reach_sq)
	var out := Array(_native.near(at.x, at.z, reach_sq))
	if _scripted:
		grid_native_verified += 1
		if _near_script(at, reach_sq) != out:
			grid_native_mismatches += 1
	return out


func _near_script(at: Vector3, reach_sq: float) -> Array:
	var reach := sqrt(reach_sq)
	var x0 := int(floorf((at.x - reach) / CELL)) + BIAS
	var x1 := int(floorf((at.x + reach) / CELL)) + BIAS
	var z0 := int(floorf((at.z - reach) / CELL)) + BIAS
	var z1 := int(floorf((at.z + reach) / CELL)) + BIAS
	var out: Array = []
	for cx in range(x0, x1 + 1):
		for cz in range(z0, z1 + 1):
			var cell: Variant = _cells.get(cx * 8192 + cz)
			if cell != null:
				out.append_array(cell)
	if out.size() > 1:
		out.sort()
	return out
