extends Node

const FcPresentation := preload("../game/fc_presentation.gd")
const FcFrameProbe := preload("../game/fc_frame_probe.gd")
## Seconds of play timed after the gate opens (`--after_gate_sec`): the frames the player sees, which the timeline above ends before.
const AFTER_GATE_SEC := 6.0
## A frame this long or longer is a hitch in the after-gate summary.
const HITCH_MSEC := 100

## The load timeline offline (FcLoadTimeline prints one `arena.load` line when the cover lifts), for comparing a change back to back. Software GL: the CPU side is real, shader compiles are not.
## `xvfb-run -a godot --path . --rendering-driver opengl3 --resolution 480x270 res://tools/load_timeline.tscn [-- --map <id>]`


func _ready() -> void:
	var _scratch := FcPresentation.use_scratch_settings("load_timeline")
	Engine.max_fps = 0
	_run.call_deferred()


func _run() -> void:
	var client: Node = (load("res://game/fc.tscn") as PackedScene).instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	add_child(client)
	var t0 := Time.get_ticks_msec()
	var gate: Variant = client.get("gate")
	# Software GL frames are slow; the gate's own 20 s timeout would release the holds before the work is done.
	gate.timeout_sec = 300.0
	gate.warm_timeout_sec = 120.0
	while not (gate != null and gate.is_open()) and Time.get_ticks_msec() - t0 < 280_000:
		await get_tree().process_frame
	print("load_timeline: gate open at engine ms %d (%d ms after the client was added)" % [Time.get_ticks_msec(), Time.get_ticks_msec() - t0])
	await _time_after_gate()
	get_tree().quit(0 if gate != null and gate.is_open() else 1)


## Prints one `load_timeline: after gate` line: frames, the count at or over [constant HITCH_MSEC] and the worst, in the first seconds of play.
func _time_after_gate() -> void:
	var asked := FcFrameProbe.launch_value("after_gate_sec")
	var window_usec := int((asked.to_float() if asked.is_valid_float() else AFTER_GATE_SEC) * 1_000_000.0)
	var began := Time.get_ticks_usec()
	var last := began
	var frames := 0
	var worst := 0
	var hitches: PackedStringArray = []
	while last - began < window_usec:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var msec := (now - last) / 1000
		last = now
		frames += 1
		worst = maxi(worst, msec)
		if msec >= HITCH_MSEC:
			hitches.append("%d@+%d" % [msec, (now - began) / 1000])
	print("load_timeline: after gate %d frames in %d ms, >=%d ms: %d, worst %d ms [%s]" % [frames, (last - began) / 1000, HITCH_MSEC, hitches.size(), worst, ", ".join(hitches)])
