extends RefCounted

## Whether this process runs the gs-sim native library its checkout pins. A checkout pins a
## release in .gitignore ("# bootstrap-natives: gs-sim v0.2.35"); bootstrap and hv put that
## release's library under addons/gs_sim with the stamp "<tag> <platform>". An older library
## loads without a word, and each native call it lacks quietly runs its GDScript twin, so a
## suite or a bench measured half in script. [method problem] names the difference; the sim
## host and the suites exit nonzero on it (game.sh fails a log holding [constant ERROR_TAG]).
## The web build has no library by design and is never checked. An exported build ships
## neither .gitignore nor the stamp, so it has no pin to compare and is not checked either.
## gs-net's snapshot library is checked everywhere on a desktop, exports included: an export
## carries it beside the executable (gs_net_native/), never in the pck, and a build without
## it builds and decodes every snapshot in GDScript behind one log warning.

const ERROR_TAG := "GS-SIM PIN ERROR"
const NET_ERROR_TAG := "GS-NET NATIVE ERROR"
const PIN_FILE := "res://.gitignore"
const PIN_PREFIX := "# bootstrap-natives: gs-sim "
const STAMP := "res://addons/gs_sim/bin/.natives-linux-x86_64"
## The single-stamp layout older bootstraps wrote.
const STAMP_OLD := "res://addons/gs_sim/bin/.natives"

## Native methods Fatal Contact's server and its addons call when they are present, by class.
## Each one missing is a path that silently runs in GDScript.
const METHODS := {
	&"GSSimFpsBody": [&"motor_tick", &"motor_pre", &"set_flat_world", &"set_hull_world",
		&"runs_after_wall_jump"],
	&"GSSimBotMind": [&"perceive", &"perceive_held", &"hear", &"steer_step", &"sight_cached_far",
		&"pickup_choose", &"worker_safe", &"unstick_step", &"tricks"],
	&"GSSimFpsNetPack": [&"pull"],
	&"GSSimFpsWeaponNet": [&"pull"],
}


## The tag this checkout pins ("v0.2.35"), or "" when there is no pin to read.
static func pinned() -> String:
	if not FileAccess.file_exists(PIN_FILE):
		return ""
	for line: String in FileAccess.get_file_as_string(PIN_FILE).split("\n"):
		if line.begins_with(PIN_PREFIX):
			return line.trim_prefix(PIN_PREFIX).strip_edges().get_slice(" ", 0)
	return ""


## The tag the installed library was fetched as, or "" when it was built here (no stamp).
static func stamped() -> String:
	for path: String in [STAMP, STAMP_OLD]:
		if FileAccess.file_exists(path):
			return FileAccess.get_file_as_string(path).strip_edges().get_slice(" ", 0)
	return ""


## Every native class or "Class.method" asked for but not in the loaded library.
static func missing() -> PackedStringArray:
	var out: PackedStringArray = []
	for module: StringName in GSSim.MODULES:
		var cls: StringName = GSSim.MODULES[module]
		if not ClassDB.class_exists(cls):
			out.append(String(cls))
	for cls: StringName in METHODS:
		if not ClassDB.class_exists(cls):
			if not out.has(String(cls)):
				out.append(String(cls))
			continue
		for method: StringName in METHODS[cls]:
			if not ClassDB.class_has_method(cls, method):
				out.append("%s.%s" % [cls, method])
	return out


## "" when the library is the pinned one with nothing missing (or nothing is checked here),
## else one line saying what differs.
static func problem() -> String:
	if OS.has_feature("web"):
		return ""
	var why := _sim_problem()
	return why if why != "" else net_problem()


## "" when gs-net's native snapshot library loads (or this platform never loads one), else why not.
static func net_problem() -> String:
	if OS.has_feature("web") or not GSPlatform.is_desktop():
		return ""
	var res := GSNetNative.load_library()
	if res.ok:
		return ""
	return "%s: gs-net's native snapshot library did not load, so snapshots run in GDScript: %s" % [
		NET_ERROR_TAG, res.error.message]


static func _sim_problem() -> String:
	var pin := pinned()
	if pin == "":
		return ""
	var have := stamped()
	var gone := missing()
	if not ClassDB.class_exists(&"GSSimFpsBody"):
		return "%s: this checkout pins gs-sim %s but the native library is not loaded (stamp %s); everything runs in GDScript" % [
			ERROR_TAG, pin, have if have != "" else "none"]
	if have != "" and have != pin:
		return "%s: gs-sim library is %s but this checkout pins %s; missing=%d %s" % [
			ERROR_TAG, have, pin, gone.size(), " ".join(gone)]
	if not gone.is_empty():
		return "%s: gs-sim library %s lacks what the game asks for; missing=%d %s" % [
			ERROR_TAG, have if have != "" else "(built here)", gone.size(), " ".join(gone)]
	return ""


## Prints [method problem] to stderr when there is one; a suite's log then fails in game.sh.
static func complain() -> void:
	var why := problem()
	if why != "":
		printerr(why)


## "version=v0.2.35 pin=v0.2.35 missing=0" for the ready and status lines.
static func summary() -> String:
	var have := stamped()
	return "version=%s pin=%s missing=%d" % [have if have != "" else "unstamped",
		pinned() if pinned() != "" else "none", missing().size()]
