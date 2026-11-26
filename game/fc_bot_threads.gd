extends RefCounted

## The bots' brains on worker threads (cvar `bot_threads`, 0 = off: the stock one-bot-at-a-time loop). A tick of bot commands is three steps (see [method FcBots.think_begin]): per bot on the main thread the snapshot and bookkeeping;
## the brains' decisions, which read that snapshot and write one [GSBotIntent] each, split over [member threads] threads; per bot on the main thread the commands from the intent. The motor and weapons run after, from those commands.
## The brains touch no node: sight and wall rays use queries of their own, routes and waypoints take the world's lock ([member FcBots.World.par]); a brain is only its bot's, so answers do not depend on which thread runs which bot.

const FcBots := preload("fc_bots.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")

## Fewer bots than this think on the main thread: the hand-off costs more than it saves.
const MIN_BOTS := 8

## Brains per grab from the shared queue: one, so the main thread's wait for the last worker is one brain, not four (the lock is cheap beside a brain).
const CHUNK := 1

## Threads that decide (the main thread is one); 0 and 1 think on the main thread.
static var threads: int = launch_default()

## [member threads] on a threaded web engine (gs-server-deploy's `index-mt`, picked when the page is
## cross-origin isolated): the browser's main thread draws too, so the brains go to workers there.
const WEB_THREADS := 4


## Most brain threads [method native_default] gives; the cvar sets any count. On staging02 at 64 players 3 threads took the sim from 24.7 to 22.3 ms/tick and 6 gave nothing more.
const NATIVE_THREADS_MAX := 4


## [member threads] before the cvar says otherwise: [constant WEB_THREADS] (at most the browser's cores) on a threaded web engine, [method native_default] on a desktop or dedicated server, 0 on the
## single-threaded web engine, which always thinks on the main thread. The page's `?bot_threads=N` overrides the web count, so a browser measurement can compare counts from a URL.
static func launch_default() -> int:
	if not GSPlatform.is_web():
		return native_default() if GSPlatform.has_threads() else 0
	if not GSPlatform.has_threads():
		return 0
	var asked := FcFrameProbe.launch_value("bot_threads")
	if asked.is_valid_int():
		return clampi(int(asked), 0, 64)
	return mini(WEB_THREADS, OS.get_processor_count())


## A quarter of the machine's threads, at most [constant NATIVE_THREADS_MAX]; 0 (one bot after another)
## below 8, where the game's own threads already fill the cores.
static func native_default() -> int:
	var n := mini(floori(OS.get_processor_count() / 4.0), NATIVE_THREADS_MAX)
	return n if n >= 2 else 0

## Ticks whose brains went through the worker path (for the suite).
static var par_ticks: int = 0

## srv_bots outside the brains, by part, for the sim host's SIM_HOST_PHASES line (`--sim_sections` 1 or 2): the
## main-thread begin and finish loops, the par hand-off, the main thread's own share of brains, the join and the
## merge; sb_gather and sb_apply are the net bridge's loops either side of [method think_all]. A clock read a part.
const PHASES := ["sb_gather", "sb_begin", "sb_ready", "sb_par_begin", "sb_main", "sb_join", "sb_par_end", "sb_merge", "sb_finish", "sb_apply"]
enum { SB_GATHER, SB_BEGIN, SB_READY, SB_PAR_BEGIN, SB_MAIN, SB_JOIN, SB_PAR_END, SB_MERGE, SB_FINISH, SB_APPLY }
static var phase_timers: bool = false
static var phase_us := PackedInt64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])


## Charges the time since [param since] to part [param part] and returns the clock for the next one; 0 and no clock
## read while [member phase_timers] is off.
static func phase(part: int, since: int) -> int:
	if not phase_timers:
		return 0
	var now := Time.get_ticks_usec()
	phase_us[part] += now - since
	return now


## The clock [method phase] counts from; 0 while [member phase_timers] is off.
static func phase_start() -> int:
	return Time.get_ticks_usec() if phase_timers else 0

var _jobs: Array = []
var _next := 0
var _lock := Mutex.new()


## Whether [param bot_count] bots go through [method think_all] this tick.
static func active(bot_count: int) -> bool:
	return threads > 0 and bot_count >= MIN_BOTS and GSPlatform.has_threads()


## [move, fire] per bot, in order, as [method FcBots.think] gives each one. [param players] and
## [param minds] are parallel arrays.
static func think_all(game: Object, players: Array, minds: Array, tick: int, tick_rate: float) -> Array:
	var out: Array = []
	out.resize(players.size())
	var pending: Array[int] = []
	var t_part := phase_start()
	for i in players.size():
		var early := FcBots.think_begin(game, players[i], minds[i], tick, tick_rate)
		if early.is_empty():
			pending.append(i)
		else:
			out[i] = early
	t_part = phase(SB_BEGIN, t_part)
	if not pending.is_empty():
		_decide(pending, minds)
		t_part = phase_start()
		for i in pending:
			out[i] = FcBots.think_finish(game, players[i], minds[i], tick, tick_rate)
		phase(SB_FINISH, t_part)
	return out


static func _decide(pending: Array[int], minds: Array) -> void:
	var jobs: Array = []
	for i in pending:
		jobs.append(minds[i])
	var world: FcBots.World = (jobs[0] as FcBots.Mind).t_world
	var started := Time.get_ticks_usec()
	if jobs.size() < MIN_BOTS:
		for mind: FcBots.Mind in jobs:
			mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
		FcFrameProbe.add(&"bot_brain", started)
		return
	# Before par_begin (the world hands out no native scan once it is on): a native brain takes a
	# handle on this tick's packed scan and stays native on its worker (gs-bot API 34 with a
	# worker-safe gs_sim); without that it moves into script (a no-op once it is).
	var t_part := phase_start()
	for mind: FcBots.Mind in jobs:
		if mind.brain.has_method(&"par_ready"):
			mind.brain.par_ready(mind.t_world)
		elif mind.brain.has_method(&"leave_native"):
			mind.brain.leave_native()
	t_part = phase(SB_READY, t_part)
	var began := world.par_begin()
	t_part = phase(SB_PAR_BEGIN, t_part)
	if not began:
		for mind: FcBots.Mind in jobs:
			mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
	else:
		var run := new()
		par_ticks += 1
		run._jobs = jobs
		var helpers := mini(threads, jobs.size() / CHUNK + 1) - 1
		var group := WorkerThreadPool.add_group_task(run._work, helpers, helpers, true, "arena bot brains") if helpers > 0 else -1
		run._work(0)
		t_part = phase(SB_MAIN, t_part)
		if group >= 0:
			WorkerThreadPool.wait_for_group_task_completion(group)
		t_part = phase(SB_JOIN, t_part)
		world.par_end()
		t_part = phase(SB_PAR_END, t_part)
	FcFrameProbe.add(&"bot_brain", started)
	# The --brain-us profile: threaded brains timed into their own clocks; the main thread adds them up here, after
	# the join and outside bot_brain (gs-bot 40). Off: one static read a tick.
	if FcBots.brain_merge and (GSBotBrain as GDScript).get(&"phase_timers"):
		var brains: Array = []
		for mind: FcBots.Mind in jobs:
			brains.append(mind.brain)
		(GSBotBrain as GDScript).call(&"merge_phases", brains)
	phase(SB_MERGE, t_part)


## Takes brains off the shared queue until it is empty.
func _work(_slot: int) -> void:
	while true:
		_lock.lock()
		var from := _next
		_next += CHUNK
		_lock.unlock()
		if from >= _jobs.size():
			return
		for j in range(from, mini(from + CHUNK, _jobs.size())):
			var mind: FcBots.Mind = _jobs[j]
			(mind.t_world as FcBots.World).par_job(j)
			mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
