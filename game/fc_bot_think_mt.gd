extends RefCounted

## `bot_native_think_mt`: before the brain threads start, GSSimBotThinkMt.perceive_all perceives for every threaded bot
## at once on Rust threads (gs-bot 53); each think takes its answer, the script path's to the bit (`headless_botthreads`).
## Off, or without the class, think perceives on its worker. Detail: docs/native-server-tick.md (Bots perceive_all).

const FcBots := preload("fc_bots.gd")

const CLASS := &"GSSimBotThinkMt"

## The cvar's value.
static var on: bool = true
static var _pass: Object = null


## The pass over [param jobs] (FcBots.Mind, after their brains' par_ready) with [param threads] Rust threads.
static func run(jobs: Array, threads: int) -> void:
	if not on or not ClassDB.class_exists(CLASS):
		return
	var brains: Array = []
	var minds: Array = []
	var rows := PackedFloat64Array()
	var world: FcBots.World = null
	for mind: FcBots.Mind in jobs:
		var brain: Object = mind.brain
		if not brain.has_method(&"think_mt_row"):
			continue
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
