extends GSGameCheckSuite

const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcSimHost := preload("../game/fc_sim_host.gd")
const FcNativePhases := preload("../game/fc_native_phases.gd")

## The native server tick's coverage (docs/native-server-tick.md): a 31-bot CTF server on cp-orange-x3 with `sv_native_tick 1` must run
## every expected phase native (the always-native ones plus every phase registered, not "absent"); a second run with
## `sv_native_tick 0` must put every phase on the fallback.

const MAP := &"cp-orange-x3"
const FALLBACK_MAP := &"dm_box"
const BOTS := 31
const ON_SEC := 25.0
const OFF_SEC := 8.0
## Boot (map load, 31 bots) plus the run, before the child counts as hung.
const BOOT_SEC := 150.0
const EXPECTED_BASE: Array[String] = ["motor", "bots", "snapshots"]


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: native server tick coverage (31 bots, dedicated server)")
	var map := MAP
	if not FcImportedMaps.has(MAP):
		map = FALLBACK_MAP
		print("WARNING: no %s under maps/imported_dm (link fc-dm-maps); running %s instead" % [MAP, map])

	print("-- sv_native_tick 1: every expected phase runs native")
	var on := await _serve(map, ON_SEC, "1")
	var on_rows: Dictionary = on.get("phases", {})
	var expected := expected_phases(on_rows)
	print("expected native: %s" % ", ".join(PackedStringArray(expected)))
	_check(on.has("ready"), "the server came up on %s" % map, String(on.get("ready", on.get("error", ""))))
	_check(not on_rows.is_empty(), "the server printed its SIM_HOST_NATIVE line", String(on.get("error", "")))
	_check(int(on.get("ticks", 0)) > 0, "the match ticked (%d SIM_HOST windows)" % int(on.get("ticks", 0)))
	for row: Dictionary in FcNativePhases.PHASES:
		var id: String = row["id"]
		var got: String = on_rows.get(id, "missing")
		print("  %-10s %s" % [id, got])
		if expected.has(id):
			_check(got == "native", "%s ran native" % id, got)

	print("-- sv_native_tick 0: every phase runs the GDScript fallback")
	var off := await _serve(map, OFF_SEC, "0")
	var off_rows: Dictionary = off.get("phases", {})
	_check(not off_rows.is_empty(), "the master-off server printed its SIM_HOST_NATIVE line", String(off.get("error", "")))
	for id: String in off_rows:
		var got: String = off_rows[id]
		_check(not got.begins_with("native"), "%s is off with the master off" % id, got)
	_report()


## The baseline phases plus every phase the server registered (any row that is not "absent").
static func expected_phases(rows: Dictionary) -> Array[String]:
	var out: Array[String] = EXPECTED_BASE.duplicate()
	for row: Dictionary in FcNativePhases.PHASES:
		var id: String = row["id"]
		if not out.has(id) and rows.has(id) and not String(rows[id]).begins_with("absent"):
			out.append(id)
	return out


## Runs the server process for [param seconds] and parses its log: ready line, tick windows and
## the last SIM_HOST_NATIVE line as {phase id: "native" | "fallback: why" | "absent: why"}.
func _serve(map: StringName, seconds: float, master: String) -> Dictionary:
	var port := FcSimHost._free_port()
	var log_path := ProjectSettings.globalize_path("user://logs/native_tick_coverage_%s.log" % master)
	if FileAccess.file_exists(log_path):
		var _gone := DirAccess.remove_absolute(log_path)
	var args := PackedStringArray(["--headless", "--log-file", log_path])
	var project := ProjectSettings.globalize_path("res://")
	if project != "" and not OS.has_feature("template"):
		args.append_array(["--path", project])
	args.append_array(["--", FcSimHost.SERVER_FLAG, "1", "--port", str(port), "--bots", str(BOTS),
		"--map", String(map), "--mode", "ctf", "--sim_bench_sec", str(seconds), "--cvar", "sv_native_tick=" + master])
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid <= 0:
		return {"error": "the server process did not start"}
	var deadline := Time.get_ticks_msec() + int((BOOT_SEC + seconds) * 1000.0)
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
	var out := {}
	if OS.is_process_running(pid):
		var _killed := OS.kill(pid)
		out["error"] = "the server ran past %.0f s and was killed" % (BOOT_SEC + seconds)
	var text := FileAccess.get_file_as_string(log_path)
	var ticks := 0
	var native_line := ""
	for line: String in text.split("\n"):
		if line.begins_with("SIM_HOST ready"):
			out["ready"] = line
		elif line.begins_with("SIM_HOST ") and line.contains(" ticks/s of "):
			ticks += 1
		elif line.begins_with("SIM_HOST_NATIVE "):
			native_line = line
	out["ticks"] = ticks
	if out.has("ready") and not String(out["ready"]).contains("map=%s" % map):
		out["error"] = "the server loaded another map: " + String(out["ready"])
		out.erase("ready")
	if native_line != "":
		print("  " + native_line)
		out["phases"] = parse_native_line(native_line)
	elif not out.has("error"):
		out["error"] = "no SIM_HOST_NATIVE line in " + log_path
	return out


## `SIM_HOST_NATIVE master=1 native=[a, b] fallback=[c: why; d: why] absent=[e: why]` to
## {a: "native", c: "fallback: why", e: "absent: why"}.
static func parse_native_line(line: String) -> Dictionary:
	var out := {}
	for key: String in ["native", "fallback", "absent"]:
		var from := line.find(" %s=[" % key)
		if from < 0:
			continue
		from += key.length() + 3
		var to := line.find("]", from)
		var body := line.substr(from, to - from) if to >= 0 else ""
		if body.strip_edges().is_empty():
			continue
		for part: String in body.split(", " if key == "native" else "; "):
			var id := part.get_slice(":", 0).strip_edges()
			out[id] = key if key == "native" else "%s:%s" % [key, part.substr(id.length() + 1)]
	return out
