extends RefCounted

## Paces the sim host's frames to its tick rate and records why a tick came late. Godot's own frame limiter
## sleeps with the OS timer, which on Windows rounds up to its 15.6 ms tick unless something raised the
## resolution: a 15.15 ms frame became 16 to 31 ms, ticks bunched up and the client saw bursty snapshots.
## This sleeps in 1 ms steps while the sleeps land on time, and spins the last stretch to the deadline; when
## sleeps overshoot (a coarse timer, a busy box) the margin grows, up to spinning the whole wait, and decays
## again once they behave. It owns the pacing (`Engine.max_fps` 0), so it costs a spinning core only while the timer is bad.

## The share of the period a frame may wake late of the tick (usec): a tick only runs once the accumulator holds a whole period.
const WAKE_LATE_USEC := 150
## The sleep step (usec) the overshoot is measured on.
const STEP_USEC := 1000
## The wait the spin always keeps (usec), however well the sleeps behave.
const MIN_MARGIN_USEC := 600
## A gap between two reads of the spin loop over this is the thread having been descheduled (usec).
const STALL_USEC := 1000
## Decay of the remembered overshoot per frame.
const HINT_DECAY := 0.995

var enabled := true
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
	_over_hint *= HINT_DECAY
	var margin := mini(maxi(int(_over_hint * 1.25) + MIN_MARGIN_USEC, MIN_MARGIN_USEC), period)
	while target - now > margin + STEP_USEC:
		OS.delay_usec(STEP_USEC)
		var after := Time.get_ticks_usec()
		var over := after - now - STEP_USEC
		over_max_usec = maxi(over_max_usec, over)
		_over_hint = maxf(_over_hint, over)
		now = after
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
		"paced here" if enabled else "paced by the engine"]
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


## The likely cause of a window that fell behind, from what it measured: a tick dearer than its budget, a thread
## descheduled (CPU contention), sleeps overshooting (a coarse timer), or none of these seen.
## [param over] of [param n] server ticks, or [param frames_over] of [param frames] frames (everything between two waits),
## cost more than the budget; the times are usec against [param period].
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
