extends RefCounted

## Paces the sim host's frames to its tick rate and records why a tick came late. Godot's limiter sleeps on the OS timer (15.6 ms on Windows),
## which bunched ticks; this sleeps in 1 ms steps and spins the last stretch, growing the margin while sleeps overshoot (`Engine.max_fps` 0).
## With gs-sim's `GSSimTimer` loaded (by name) it waits in one native high-resolution sleep: about 0.6 ms of spin a frame, whatever the OS tick.

## The share of the period a frame may wake late of the tick (usec): a tick only runs once the accumulator holds a whole period.
const WAKE_LATE_USEC := 150
## The sleep step (usec) the overshoot is measured on.
const STEP_USEC := 1000
## The wait the spin always keeps (usec), however well the sleeps behave.
const MIN_MARGIN_USEC := 600
## A gap between two reads of the spin loop over this is the thread having been descheduled (usec).
const STALL_USEC := 1000
## Weights of one sleep's overshoot in the running average the margin follows, rising and falling. An average,
## not the worst: a coarse timer overshoots every sleep and holds it at a whole period, while a busy box's rare
## long wake is forgotten within a frame's sleeps (spinning there takes a core from the client and gets the spinner preempted).
const HINT_UP := 0.5
const HINT_DOWN := 0.05
## A timer whose 1 ms sleeps overshoot by more than this (usec, the median of [constant PROBE_SLEEPS]) is coarse.
const COARSE_USEC := 2000
const PROBE_SLEEPS := 9
## Decay per frame of a hint no sleep measured (the whole wait spun), so a timer that got better is tried again.
const HINT_IDLE_DECAY := 0.999

var enabled := true
## gs-sim's GSSimTimer when loaded (untyped: reached by name), else null and `OS.delay_usec` steps.
var _timer: Object = null
var _deadline := 0
var _over_hint := 0.0
var _last_tick_usec := 0
## This window's gaps between tick starts (usec), the sleeps' overshoot and the spin loop's stalls.
var gaps := PackedInt32Array()
var over_max_usec := 0
var stall_max_usec := 0
var stall_count := 0
var spin_usec := 0
## Frames in the window, and how many took more than a period of work before the wait (the whole frame, not just the server tick).
var frames := 0
var frames_over := 0
var _exit_usec := 0
var _window_start_usec := 0


## Uses gs-sim's GSSimTimer when the library has it: holds a 1 ms OS timer resolution (Windows, kept while hidden or
## throttled; Godot's own raise can be ignored there) and sleeps with its precise timer. False without it.
func use_native_timer() -> bool:
	if not ClassDB.class_exists(&"GSSimTimer"):
		return false
	_timer = ClassDB.instantiate(&"GSSimTimer")
	if _timer == null:
		return false
	_timer.call(&"request_resolution_ms", 1)
	return true


## How the wait sleeps, for the `SIM_HOST_PACE` line.
func path() -> String:
	if not enabled:
		return "paced by the engine"
	if _timer != null:
		return "paced here: GSSimTimer %s%s + spin" % [_timer.call(&"sleep_kind"), ", 1 ms resolution held" if int(_timer.call(&"resolution_ms")) > 0 else ""]
	return "paced here: OS.delay_usec 1 ms steps + spin (no native timer)"


## Whether the OS timer is coarse (Windows' default 15.6 ms tick): the median overshoot of a few 1 ms sleeps.
## `--sim_pace auto` (the default) paces here only then; a fine timer leaves the engine's own pacing, which on a
## shared box keeps a core free for the client.
static func timer_is_coarse() -> bool:
	var overs: Array[int] = []
	for i in PROBE_SLEEPS:
		var t0 := Time.get_ticks_usec()
		OS.delay_usec(STEP_USEC)
		overs.append(Time.get_ticks_usec() - t0 - STEP_USEC)
	overs.sort()
	return overs[PROBE_SLEEPS / 2] > COARSE_USEC


## Call once per physics tick (from `_physics_process`).
func note_tick() -> void:
	var now := Time.get_ticks_usec()
	if _last_tick_usec > 0:
		gaps.append(mini(now - _last_tick_usec, 1000000))
	_last_tick_usec = now


## Call once per frame, last thing in `_process`: waits until the next tick is due.
func pace(rate: int) -> void:
	if not enabled or rate <= 0:
		return
	var period := 1000000 / rate
	var now := Time.get_ticks_usec()
	if _exit_usec > 0:
		frames += 1
		if now - _exit_usec > period:
			frames_over += 1
	if _window_start_usec == 0:
		_window_start_usec = now
	if _deadline == 0 or now > _deadline + period:
		_deadline = now
	_deadline += period
	var target := _deadline + WAKE_LATE_USEC
	var margin := mini(maxi(int(_over_hint * 1.25) + MIN_MARGIN_USEC, MIN_MARGIN_USEC), period)
	var slept := false
	while target - now > margin + STEP_USEC:
		# The native timer wakes on time, so it sleeps the whole stretch at once; OS.delay_usec in steps, as each may overshoot a tick.
		var ask := STEP_USEC if _timer == null else target - now - margin
		if _timer == null:
			OS.delay_usec(ask)
		else:
			_timer.call(&"sleep_usec", ask)
		var after := Time.get_ticks_usec()
		var over := after - now - ask
		over_max_usec = maxi(over_max_usec, over)
		var o := maxf(0.0, over)
		_over_hint += (o - _over_hint) * (HINT_UP if o > _over_hint else HINT_DOWN)
		slept = true
		now = after
	if not slept:
		_over_hint *= HINT_IDLE_DECAY
	var spin_from := now
	var prev := now
	while now < target:
		now = Time.get_ticks_usec()
		if now - prev > STALL_USEC:
			stall_max_usec = maxi(stall_max_usec, now - prev)
			stall_count += 1
		prev = now
	spin_usec += now - spin_from
	_exit_usec = now


## `SIM_HOST_PACE`: the spread of the gaps between ticks in the window against the period, the worst sleep overshoot
## and the worst stall of the spin loop (a descheduled thread), and the share of the window spent spinning.
## Resets the window.
func window_line(rate: int) -> String:
	var period := 1000000 / maxi(rate, 1)
	var sorted := gaps.duplicate()
	sorted.sort()
	var n := sorted.size()
	var late := 0
	for g in sorted:
		if g > period * 3 / 2:
			late += 1
	var wall := maxi(1, Time.get_ticks_usec() - _window_start_usec)
	var line := "SIM_HOST_PACE ms | tick gap p50 %.2f p95 %.2f max %.2f, late %d/%d (over 1.5 periods) | sleep overshoot max %.2f, spin stalls %d max %.2f, spin %d%%, frames over a period %d/%d | %s" % [
		_pick(sorted, 0.5) / 1000.0, _pick(sorted, 0.95) / 1000.0, _pick(sorted, 1.0) / 1000.0, late, n,
		over_max_usec / 1000.0, stall_count, stall_max_usec / 1000.0, roundi(spin_usec * 100.0 / wall),
		frames_over, frames,
		path()]
	reset_window()
	return line


func reset_window() -> void:
	gaps.clear()
	over_max_usec = 0
	stall_max_usec = 0
	stall_count = 0
	spin_usec = 0
	frames = 0
	frames_over = 0
	_window_start_usec = Time.get_ticks_usec()


## The likely cause of a window that fell behind: a tick dearer than its budget, a descheduled thread (CPU contention), overshooting sleeps
## (a coarse timer), or none seen. [param over] of [param n] ticks, or [param frames_over] of [param frames] frames, cost more than the
## budget; the times are usec against [param period].
static func cause(over: int, n: int, frames_over: int, frames: int, stall_max: int, over_max: int, period: int) -> String:
	if n > 0 and over * 20 >= n:
		return "ticks too dear (%d of %d over the budget): fewer bots or a lower solo_tick_tiers" % [over, n]
	if frames > 0 and frames_over * 20 >= frames:
		return "frames too dear (%d of %d took over a period outside the wait; a tick plus the rest of the process): fewer bots or a lower solo_tick_tiers" % [frames_over, frames]
	if stall_max >= maxi(period / 4, STALL_USEC * 2):
		return "starved: the sim thread was off a core for up to %.1f ms (the render client or other programs hold the cores)" % (stall_max / 1000.0)
	if over_max >= maxi(period / 4, STALL_USEC * 2):
		return "timer: sleeps overshoot by up to %.1f ms (a coarse OS timer)" % (over_max / 1000.0)
	return "ticks cheap and no stall seen: the engine's own pacing or the box"


static func _pick(sorted: PackedInt32Array, share: float) -> int:
	if sorted.is_empty():
		return 0
	return sorted[mini(sorted.size() - 1, int((sorted.size() - 1) * share))]
