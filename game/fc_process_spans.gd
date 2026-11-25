extends Node

const FcFrameProbe := preload("fc_frame_probe.gd")

## Splits a recorded frame's process phase into spans the dot profiler's tree can place, so "process scripts (no span)" names where it went. While [member GSFrameCost.trace] is on: - `arena.pf_head`: from SceneTree.process_frame to the first node's `_process` (message queue, transforms). - `arena.pf_nodes`: from the first node's `_process` to the last one's. Every timed section (`arena.present`, `arena.audio`, ...) nests inside it, so its self time is the nodes nobody times: other `_process` scripts and
## the engine's internal process (AnimationMixer/AnimationTree, particles, ...). - `arena.pf_tail`: from the last node's `_process` to RenderingServer.frame_pre_draw: deferred calls (skeleton updates), transform notifications, timers, tweens and the engine work before the draw. This node runs first by process_priority and its child last; outside a trace each pays a call and a test a frame. `--pf_split N` (a bench's `-- --pf_split 3`) splits `arena.pf_nodes` further for one recording: a marker node goes
## before each node down to depth N from the root, and each marker opens a span `arena.pn.<parent kind>/<kind>` that the next marker closes. Kinds are script file or class names, so 31 players' nodes sum into one row. Diagnostic only: the markers stay until the scene changes.

## This node's process_priority; its last child runs at the negative of it.
const EDGE := -1000000

const PF_HEAD := &"arena.pf_head"
const PF_NODES := &"arena.pf_nodes"
const PF_TAIL := &"arena.pf_tail"

## Depth from the root to put split markers down to; 0 is off. From `--pf_split N`.
var split_depth := 0
## Most markers to put in, so a deep tree cannot drown the recording in spans.
const SPLIT_MAX := 800

var _frame_usec := 0
var _split_done := false
var _open_name := &""
var _open_usec := 0
var _first_usec := 0
var _last_usec := 0


func _init() -> void:
	name = "ProcessSpans"
	process_priority = EDGE
	process_mode = Node.PROCESS_MODE_ALWAYS
	var tail := _Last.new()
	tail.name = "Last"
	tail.process_priority = -EDGE
	tail.process_mode = Node.PROCESS_MODE_ALWAYS
	tail.first = self
	add_child(tail)


func _ready() -> void:
	var text := FcFrameProbe.launch_value("pf_split")
	if text.is_valid_int():
		split_depth = clampi(text.to_int(), 0, 8)


func _enter_tree() -> void:
	var _a := get_tree().process_frame.connect(_on_process_frame)
	# Connected before the profiler starts recording, so this runs ahead of its own frame_pre_draw stamp.
	var _b := RenderingServer.frame_pre_draw.connect(_on_pre_draw)


func _exit_tree() -> void:
	get_tree().process_frame.disconnect(_on_process_frame)
	RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)


func _on_process_frame() -> void:
	_frame_usec = Time.get_ticks_usec() if GSFrameCost.trace else 0


func _process(_delta: float) -> void:
	if not GSFrameCost.trace:
		_first_usec = 0
		return
	var now := Time.get_ticks_usec()
	if _frame_usec > 0:
		GSFrameCost.span(PF_HEAD, _frame_usec, now - _frame_usec)
	_first_usec = now
	if split_depth > 0 and not _split_done:
		_split_done = true
		_put_markers.call_deferred()


func reach_last() -> void:
	if not GSFrameCost.trace:
		_last_usec = 0
		return
	var now := Time.get_ticks_usec()
	_close_split(now)
	if _first_usec > 0:
		GSFrameCost.span(PF_NODES, _first_usec, now - _first_usec)
	_last_usec = now


## From a split marker: closes the open split span and opens [param span_name].
func split_mark(span_name: StringName) -> void:
	if not GSFrameCost.trace:
		return
	var now := Time.get_ticks_usec()
	_close_split(now)
	_open_name = span_name
	_open_usec = now


func _close_split(now: int) -> void:
	if _open_usec > 0:
		GSFrameCost.span(_open_name, _open_usec, now - _open_usec)
	_open_usec = 0


func _put_markers() -> void:
	var count := [0]
	_mark_under(get_tree().root, 1, count)
	GSLog.info(FcFrameProbe.CHANNEL, "process split markers", {"depth": split_depth, "markers": count[0]})
	# The census of what the engine walks each frame, once, 15 s on (the bots have joined and the bodies are built).
	get_tree().create_timer(15.0).timeout.connect(census)


## Logs, per script file or class, how many nodes are in the tree and how many of them run `_process` or `_physics_process`
## (a `PfCensus` line each, the biggest first), plus the skeletons with their bone counts. Diagnostic: `--pf_split N` only.
func census() -> void:
	var rows := {}
	var skeletons := [0, 0, 0]
	_census_walk(get_tree().root, rows, skeletons)
	var keys := rows.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return rows[a][1] + rows[a][2] > rows[b][1] + rows[b][2] or (rows[a][1] + rows[a][2] == rows[b][1] + rows[b][2] and rows[a][0] > rows[b][0]))
	for key in keys.slice(0, 40):
		GSLog.info(FcFrameProbe.CHANNEL, "PfCensus", {"kind": key, "nodes": rows[key][0], "process": rows[key][1], "physics": rows[key][2]})
	GSLog.info(FcFrameProbe.CHANNEL, "PfCensus skeletons", {"skeletons": skeletons[0], "bones": skeletons[1], "visible": skeletons[2]})


func _census_walk(n: Node, rows: Dictionary, skeletons: Array) -> void:
	var key := _kind(n)
	if not rows.has(key):
		rows[key] = [0, 0, 0]
	var row: Array = rows[key]
	row[0] += 1
	if n.is_processing():
		row[1] += 1
	if n.is_physics_processing():
		row[2] += 1
	var skeleton := n as Skeleton3D
	if skeleton != null:
		skeletons[0] += 1
		skeletons[1] += skeleton.get_bone_count()
		if skeleton.is_visible_in_tree():
			skeletons[2] += 1
	for child in n.get_children():
		_census_walk(child, rows, skeletons)


func _mark_under(parent: Node, depth: int, count: Array) -> void:
	if depth > split_depth or parent == self:
		return
	var kids := parent.get_children()
	for child in kids:
		if count[0] >= SPLIT_MAX:
			return
		if child == self or child is _Mark:
			continue
		var mark := _Mark.new()
		mark.first = self
		mark.span_name = StringName("arena.pn.%s/%s" % [_kind(parent), _kind(child)])
		parent.add_child(mark)
		parent.move_child(mark, child.get_index())
		count[0] += 1
		_mark_under(child, depth + 1, count)


static func _kind(n: Node) -> String:
	var script := n.get_script() as Script
	if script != null and not script.resource_path.is_empty():
		return script.resource_path.get_file().get_basename()
	return n.get_class()


func _on_pre_draw() -> void:
	if _last_usec <= 0 or not GSFrameCost.trace:
		return
	# A microsecond short: a span ending past the profiler's own pre-draw stamp would sit beside the process
	# phase instead of inside it.
	var now := Time.get_ticks_usec() - 1
	if now > _last_usec:
		GSFrameCost.span(PF_TAIL, _last_usec, now - _last_usec)
	_last_usec = 0


class _Mark extends Node:
	var first: Node = null
	var span_name := &""

	func _init() -> void:
		name = "PfMark"
		process_mode = Node.PROCESS_MODE_ALWAYS

	func _process(_delta: float) -> void:
		first.call(&"split_mark", span_name)


class _Last extends Node:
	var first: Node = null

	func _process(_delta: float) -> void:
		first.call(&"reach_last")
