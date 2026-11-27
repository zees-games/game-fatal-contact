extends RefCounted

## `bot_native_think_mt`: gs-sim's GSSimBotThinkMt.perceive_all perceives for every threaded bot at once on its own threads (gs-bot 53);
## uncached rays are cast on the main thread, and each brain's think takes its answer, to the bit the script path's
## (`headless_botthreads`). Off, or without the class, think perceives on its worker.

const FcBots := preload("fc_bots.gd")

const CLASS := &"GSSimBotThinkMt"

## The cvar's value.
static var on: bool = true
static var _pass: Object = null
## Whether gs-bot's brains have think_mt_row (API 53).
static var _has_rows: bool = GSAddonApi.build_level("gs_bot") >= 53
## [method run]'s brains and gs-sim minds, reused call to call (main thread).
static var _brains: Array[Object] = []
static var _minds: Array[Object] = []


## The pass over [param jobs] (FcBots.Mind, after their brains' par_ready) with [param threads] Rust threads.
static func run(jobs: Array[FcBots.Mind], threads: int) -> void:
	if not on or not _has_rows or not ClassDB.class_exists(CLASS):
		return
	var brains := _brains
	var minds := _minds
	brains.clear()
	minds.clear()
	var rows := PackedFloat64Array()
	var world: FcBots.World = null
	for mind: FcBots.Mind in jobs:
		var brain: Object = mind.brain  # Untyped: think_mt_row is gs-bot API 53, above the floor.
		var row: PackedFloat64Array = brain.think_mt_row(mind.t_me, mind.t_world, mind.t_world.now())
		if row.is_empty():
			continue
		brains.append(brain)
		minds.append(brain.think_mt_mind())
		rows.append_array(row)
		world = mind.t_world
	if brains.is_empty():
		return
	if _pass == null:
		_pass = ClassDB.instantiate(CLASS)
	var r: PackedInt32Array = _pass.perceive_all(minds, rows, world.sight_callable(), threads)
	for k in brains.size():
		brains[k].think_mt_put(r.slice(2 * k, 2 * k + 2))
