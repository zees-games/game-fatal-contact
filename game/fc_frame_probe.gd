extends RefCounted

const FcLoadTimeline := preload("fc_load_timeline.gd")

## Where a connected client's frame goes, reported every few seconds: frame times, the
## engine's own process and physics times, the client's sections (prediction, snapshots
## and the replays inside them, interpolation, the HUD), and the clock's round trip and
## input lead beside them.
##
## [b]Why it exists.[/b] A browser build has one thread: a frame that stalls also delays
## reading the socket, so a long frame reads as a ping spike, and the ping spike raises
## the input lead, which lengthens every replay. No profiler reaches a release web export,
## and a headless run has neither the browser's speed nor its single thread, so the only
## way to see that loop is to have the client say it. Off unless asked for:
##
## [codeblock]
## embed.html?server=ws://127.0.0.1:6074&cl_perf=5     a browser, every 5 s
## godot --path . -- --cl_perf 5                       a desktop client
## cl_perf 5                                           the console, at any time
## [/codeblock]
##
## Static on purpose: the sections are timed in the client, the bridge and the HUD, and a
## probe that has to be handed to each of them is a probe nobody adds a section to. It is
## per process, which is right for a client and harmless for a suite that never turns it on.

const CHANNEL := "arena.perf"

## Seconds between reports; 0 is off.
static var interval: float = 0.0

static var _sections: Dictionary = {}
static var _frames: PackedFloat32Array = PackedFloat32Array()
static var _process_max: float = 0.0
static var _process_sum: float = 0.0
static var _physics_max: float = 0.0
static var _physics_sum: float = 0.0
static var _steps_max: int = 0
static var _last_physics_frame: int = -1
static var _elapsed: float = 0.0
static var _last_usec: int = 0
## `arena.<section>` per section, built once: a string join and a StringName intern on each of
## the ~600 spans a 31-bot frame records were a measurable part of the profiler's own cost.
static var _profiled_names: Dictionary = {}

## The sub-spans inside a section (`p_pre`, `p_hitbox`, `p_wctx`, `w_props`, `s_resolve`, `br_contacts`, ...): off
## outside a recording, since each costs a clock read; a profiler recording turns them on ([member fine_on_record]).
static var fine: bool = false
## Whether a profiler recording turns [member fine] on for its length (`profiler_fine 0` or the bench's `--fine 0` say no).
static var fine_on_record: bool = true
## Whether [member fine] also turns the rig's and the arsenal's phase clocks on (pw_*, pa_*; `--sim_weapon_phases 1`).
## Off by default: an armed clock makes AwWeaponRig.idle_batch and GSWeaponArsenal.idle_batch_add decline, so a
## fine profile with them on times the per-weapon fallback, not the batched idle path production runs.
static var weapon_phases: bool = false


## `cl_perf_split 1` (`--cl_perf_split 1`, `?cl_perf_split=1`): the report also splits `p_controller` into its phases
## (`ctl_<phase>`, GSFpsController.phase_us) and gs-sim's native motor queries and ticks (`mt_<slot>`,
## GSSimFpsBody.profile_counters), which no browser profiler reaches. Off by default: clock reads per player tick.
static var split: bool = false
const CTL_PHASES := ["pre", "consume", "motor", "publish", "report", "signals", "post", "setpos"]
const MT_SLOTS := ["cast", "rest", "overlap", "ray", "tick"]


static func on() -> bool:
	return interval > 0.0


## The slow-tick dump (the sim host's `--sim_slow_tick MS`): while above 0, every [method add], [method lap] and
## [method count] is also kept for the current tick alone ([method tick_begin] clears it), with the events a tick had
## ([method tick_event]: kills, spawns, match states), so a tick over this many microseconds can say where it went
## ([method slow_tick_line]). 0, the default, keeps nothing: one test per span.
static var slow_tick_usec: int = 0
## Section (or count) -> PackedInt64Array([usec, calls]) for the current tick.
static var _tick_spans: Dictionary = {}
## Event name -> how many times it happened this tick.
static var _tick_events: Dictionary = {}


## Starts a tick's slow-tick record. From the server's tick, before any span.
static func tick_begin() -> void:
	_tick_spans.clear()
	_tick_events.clear()


## Notes that [param event] happened in this tick (a kill, a spawn, a match state); kept only while [member slow_tick_usec] is on.
static func tick_event(event: StringName) -> void:
	if slow_tick_usec <= 0:
		return
	_tick_events[event] = int(_tick_events.get(event, 0)) + 1


static func _tick_add(section: StringName, spent: int) -> void:
	var row: PackedInt64Array = _tick_spans.get(section, PackedInt64Array([0, 0]))
	row[0] += spent
	row[1] += 1
	_tick_spans[section] = row


## `SIM_HOST_SLOW_TICK`: tick [param tick] cost [param usec]; its [param top] costliest sections (they nest: srv_net holds
## srv_game, which holds tick_players, so read the leaves), its counts (`_n`) and its events, plus [param extra].
static func slow_tick_line(tick: int, usec: int, top: int, extra: String) -> String:
	var spans: Array = []
	var counts: Array = []
	for key: StringName in _tick_spans:
		var row: PackedInt64Array = _tick_spans[key]
		if String(key).ends_with("_n"):
			counts.append("%s %d" % [key, row[0]])
		else:
			spans.append([row[0], "%s %.2f x%d" % [key, row[0] / 1000.0, row[1]]])
	spans.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
	var parts: Array = []
	for i in mini(top, spans.size()):
		parts.append(spans[i][1])
	var events: Array = []
	for key: StringName in _tick_events:
		events.append("%s x%d" % [key, _tick_events[key]])
	return "SIM_HOST_SLOW_TICK %d %.2f ms | %s | counts %s | events %s%s" % [tick, usec / 1000.0, ", ".join(parts),
		", ".join(counts) if not counts.is_empty() else "-", ", ".join(events) if not events.is_empty() else "-", extra]


## Starts the probe from `--cl_perf N` or the page's `?cl_perf=N`, if either is given.
static func from_launch() -> void:
	var text := launch_value("cl_perf")
	if text.is_valid_float():
		set_interval(text.to_float())
	var split_text := launch_value("cl_perf_split")
	if split_text.is_valid_int():
		set_split(split_text.to_int() != 0)


static func set_split(enabled: bool) -> void:
	split = enabled
	GSFpsController.phase_timers = enabled
	GSFpsController.phase_us.fill(0)
	if ClassDB.class_exists(&"GSSimFpsBody"):
		ClassDB.class_call_static(&"GSSimFpsBody", &"reset_profile")
		ClassDB.class_call_static(&"GSSimFpsBody", &"set_profile", enabled)


## Adds the split rows for a report over [param n] frames to [param report], then restarts their counters.
static func _split_rows(report: Dictionary, n: int) -> void:
	var ctl_row: PackedInt64Array = _sections.get(&"p_controller", PackedInt64Array([0, 0, 0]))
	var calls := float(ctl_row[1]) / n
	var us := GSFpsController.phase_us
	for i in mini(CTL_PHASES.size(), us.size()):
		report["ctl_" + CTL_PHASES[i]] = "%.2f ms/frame max 0.0 x%.1f" % [float(us[i]) / n / 1000.0, calls]
	us.fill(0)
	if not ClassDB.class_exists(&"GSSimFpsBody"):
		return
	var c: PackedInt64Array = ClassDB.class_call_static(&"GSSimFpsBody", &"profile_counters")
	for i in mini(MT_SLOTS.size(), c.size() / 2):
		report["mt_" + MT_SLOTS[i]] = "%.2f ms/frame max 0.0 x%.1f" % [
			float(c[i * 2 + 1]) / n / 1000.0, float(c[i * 2]) / n]
	ClassDB.class_call_static(&"GSSimFpsBody", &"reset_profile")


## A launch option for a measurement, from `--name value` or the page's `?name=value`; ""
## when neither gives it. A browser has no command line, and a measurement has to be
## repeatable from a URL.
static func launch_value(option: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--" + option)
	if index >= 0 and index + 1 < args.size():
		return args[index + 1]
	return GSWeb.query_param(option) if GSWeb.available() else ""


## Whether a threaded resource read really runs beside the frame. Not on the threaded web engine: a worker's file
## reads are passed to the browser's main thread, which serves them only between frames, so a model read there took
## many frames (time to in-game 91-172 s threaded against 79-81 s single-threaded, staging02). There the reads run
## inline a slice at a time, as on the single-threaded engine. The page's `?web_loader_threads=1` puts them back for a measurement.
## The one switch for every load_threaded_request whose point is to keep a read off the frame (the client's
## warm-up, the level's textures, the setup's figures).
static func loader_threads_usable() -> bool:
	if not GSPlatform.has_threads():
		return false
	return not GSPlatform.is_web() or launch_value("web_loader_threads") == "1"


static func set_interval(seconds: float) -> void:
	interval = maxf(0.0, seconds)
	_last_usec = 0
	_reset()


## Adds the time since [param since_usec] to [param section]: `var t := Time.get_ticks_usec()` before the work, `FcFrameProbe.add(&"name", t)` after.
## While the dot profiler records ([member GSFrameCost.enabled]) the time is also charged to [GSFrameCost] as `arena.<section>`, so a recorded profile's hitches name the section (`r_held`, `bot_after`, ...) instead of a bare `engine.script`.
static func add(section: StringName, since_usec: int) -> void:
	var spent := Time.get_ticks_usec() - since_usec
	if spent >= FcLoadTimeline.SLOW_SECTION_USEC and FcLoadTimeline.tracing:
		FcLoadTimeline.mark("section %s %d ms" % [section, spent / 1000])
	if slow_tick_usec > 0:
		_tick_add(section, spent)
	if interval <= 0.0:
		if GSFrameCost.enabled:
			GSFrameCost.add_usec(_profiled(section), spent)
		return
	if GSFrameCost.enabled:
		GSFrameCost.add_usec(_profiled(section), spent)
	var row: PackedInt64Array = _sections.get(section, PackedInt64Array([0, 0, 0]))
	row[0] += spent
	row[1] += 1
	row[2] = maxi(row[2], spent)
	_sections[section] = row


## The clock a run of [method lap]s starts from; 0 while [member fine] is off.
static func lap_start() -> int:
	return Time.get_ticks_usec() if fine else 0


## Charges the time since [param since_usec] to the sub-span [param section] and returns the clock for the next
## lap, read after its own bookkeeping. Only while [member fine] is on (a recording), so a tick outside one pays a call and a test.
static func lap(section: StringName, since_usec: int) -> int:
	if not fine:
		return 0
	var now := Time.get_ticks_usec()
	if GSFrameCost.enabled:
		GSFrameCost.add_usec(_profiled(section), now - since_usec)
	if now - since_usec >= FcLoadTimeline.SLOW_SECTION_USEC and FcLoadTimeline.tracing:
		FcLoadTimeline.mark("lap %s %d ms" % [section, (now - since_usec) / 1000])
	if slow_tick_usec > 0:
		_tick_add(section, now - since_usec)
	# The sim host's `--sim_sections 2` has no recording: its laps go on the sections line.
	if interval > 0.0:
		var row: PackedInt64Array = _sections.get(section, PackedInt64Array([0, 0, 0]))
		row[0] += now - since_usec
		row[1] += 1
		row[2] = maxi(row[2], now - since_usec)
		_sections[section] = row
	# The next lap starts after this bookkeeping, or each lap carried the one before's (bt_coast its bt_gate's).
	return Time.get_ticks_usec()


## The rig's and the arsenal's phase clocks as read at the last [method charge_weapon_phases].
static var _pw_seen := PackedInt64Array()
static var _pa_seen := PackedInt64Array()
static var _pw_names: Array[StringName] = []
static var _pa_names: Array[StringName] = []


## Charges what the weapon rig's and arsenal's phase clocks gained since the last call to `arena.pw_<part>` and
## `arena.pa_<part>`, so a recorded profile splits p_weapons. After each p_weapons, while [member fine] is on.
static func charge_weapon_phases() -> void:
	if not GSFrameCost.enabled:
		return
	var rig := AwWeaponRig.phase_us
	var ars := GSWeaponArsenal.phase_us
	if _pw_names.is_empty():
		for part in AwWeaponRig.PHASES:
			_pw_names.append(StringName("arena.pw_" + part))
		for part in GSWeaponArsenal.PHASES:
			_pa_names.append(StringName("arena.pa_" + part))
	if _pw_seen.size() != rig.size():
		_pw_seen = rig.duplicate()
	if _pa_seen.size() != ars.size():
		_pa_seen = ars.duplicate()
	for i in rig.size():
		if rig[i] != _pw_seen[i]:
			GSFrameCost.add_usec(_pw_names[i], rig[i] - _pw_seen[i])
			_pw_seen[i] = rig[i]
	for i in ars.size():
		if ars[i] != _pa_seen[i]:
			GSFrameCost.add_usec(_pa_names[i], ars[i] - _pa_seen[i])
			_pa_seen[i] = ars[i]


static func _profiled(section: StringName) -> StringName:
	var name: Variant = _profiled_names.get(section)
	if name == null:
		name = StringName("arena." + section)
		_profiled_names[section] = name
	return name


## Counts [param amount] of something that is not a time (replayed ticks, snapshots).
static func count(key: StringName, amount: int = 1) -> void:
	if slow_tick_usec > 0:
		_tick_add(key, amount)
	if interval <= 0.0:
		return
	var row: PackedInt64Array = _sections.get(key, PackedInt64Array([0, 0, 0]))
	row[0] += amount
	row[1] += 1
	row[2] = maxi(row[2], amount)
	_sections[key] = row


## Once a frame, from the client's `_process`. Returns the report when one is due, else
## an empty dictionary; [param extra] is merged into it (round trip, lead).
static func frame(delta: float, extra: Callable) -> Dictionary:
	if interval <= 0.0:
		return {}

	# Wall time, not [param delta]: the engine clamps delta (max_physics_steps_per_frame
	# ticks' worth), so a 450 ms browser frame reads as 125 ms, and the stalls this exists
	# to show were the frames it shortened.
	var now := Time.get_ticks_usec()
	var spent := delta if _last_usec == 0 else (now - _last_usec) / 1000000.0
	_last_usec = now
	_frames.append(spent)
	var p := Performance.get_monitor(Performance.TIME_PROCESS)
	var f := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	_process_sum += p
	_process_max = maxf(_process_max, p)
	_physics_sum += f
	_physics_max = maxf(_physics_max, f)
	var physics_frame := Engine.get_physics_frames()
	if _last_physics_frame >= 0:
		_steps_max = maxi(_steps_max, physics_frame - _last_physics_frame)
	_last_physics_frame = physics_frame

	_elapsed += spent
	if _elapsed < interval:
		return {}

	var n := _frames.size()
	var sorted := _frames.duplicate()
	sorted.sort()
	var report := {
		"fps": snappedf(n / _elapsed, 0.1),
		"frame_ms": "p50 %.1f p95 %.1f max %.1f" % [
			sorted[n / 2] * 1000.0, sorted[mini(n - 1, int(n * 0.95))] * 1000.0, sorted[n - 1] * 1000.0],
		"process_ms": "avg %.2f max %.1f" % [_process_sum / n * 1000.0, _process_max * 1000.0],
		"physics_ms": "avg %.2f max %.1f" % [_physics_sum / n * 1000.0, _physics_max * 1000.0],
		"steps_max": _steps_max,
	}
	# Per frame: the average a frame spent in a section, the worst single call, and calls a
	# frame. A count's "ms" is its plain sum per frame instead.
	for key: StringName in _sections:
		var row: PackedInt64Array = _sections[key]
		if String(key).ends_with("_n"):
			report[key] = "%.1f/frame max %d" % [float(row[0]) / n, row[2]]
		else:
			report[key] = "%.2f ms/frame max %.1f x%.1f" % [
				float(row[0]) / n / 1000.0, row[2] / 1000.0, float(row[1]) / n]
	if split:
		_split_rows(report, n)
	if extra.is_valid():
		report.merge(extra.call(), true)
	GSLog.info(CHANNEL, "frame", report)
	_reset()
	return report


static func _reset() -> void:
	_sections.clear()
	_frames.clear()
	_process_max = 0.0
	_process_sum = 0.0
	_physics_max = 0.0
	_physics_sum = 0.0
	_steps_max = 0
	_elapsed = 0.0


## A client frame's stages in the order it runs them: prediction, the snapshot apply, the remote draw (the
## interpolator and each remote's copy onto its node), the bodies, then the presentation and its remote-player
## sub-spans (the `r_*` laps need [member fine]).
const STAGES: Array[StringName] = [&"predict", &"net_snapshot", &"interpolate", &"bodies", &"present", &"r_pose", &"r_held", &"r_tag", &"r_anim"]


## One `STAGES` line: each of [constant STAGES] in ms per client frame over [param frames] frames, then whether the
## remote copy ran natively (`present=mirror`, FcPlayerNet.native_present) and the copies the mirror has done since the
## interpolator started.
static func stages_line(frames: int, interpolator: Object) -> String:
	var n := float(maxi(1, frames))
	var out := "STAGES frames=%d" % frames
	for stage in STAGES:
		var row: PackedInt64Array = _sections.get(stage, PackedInt64Array([0, 0, 0]))
		out += " %s=%.3f" % [stage, row[0] / 1000.0 / n]
	var native: Object = interpolator.get(&"_native") if interpolator != null and &"_native" in interpolator else null
	var mirrored := 0
	if native != null and native.has_method(&"mirrored_count"):
		mirrored = int(native.call(&"mirrored_count"))
	return out + " present=%s mirrored=%d" % ["mirror" if mirrored > 0 else "script", mirrored]
