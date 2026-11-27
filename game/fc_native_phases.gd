extends RefCounted
## The native server tick's master switch and startup report (docs/native-server-tick.md): `sv_native_tick`
## 1/0 writes every phase cvar of this build; a later phase cvar write overrides until the master is written.
## A phase is "absent" (cvars unregistered), "fallback" (gs-sim class/method missing; warns once) or native.

const CHANNEL := "arena.native_tick"
const MASTER := "sv_native_tick"

## id: the phase. cvars: its switches (1 = native). classes: the gs-sim classes it needs.
## methods: [class, method] pairs a too-old library lacks.
const PHASES: Array[Dictionary] = [
	{"id": "players", "cvars": ["sv_native_players", "sv_native_slots"],
		"classes": ["GSSimServerTick"], "methods": []},
	{"id": "mirror", "cvars": ["sv_trace_mirror"],
		"classes": ["GSSimTraceMirror", "GSSimFpsBody"], "methods": [["GSSimFpsBody", "set_trace_mirror"]]},
	{"id": "motor", "cvars": ["motor_native", "sv_native_motor_state", "motor_native_tick", "motor_native_full", "fc_hull_native",
		"fc_posture_native", "fc_mechanics_native", "fc_tick_events"],
		"classes": ["GSSimFpsBody", "GSSimMotorBatch"], "methods": []},
	{"id": "bots", "cvars": ["bot_native", "bot_native_brain", "bot_native_pickup", "bot_native_drops",
		"bot_native_unstick", "bot_native_act", "bot_native_think", "fc_bot_pvs_native", "bot_native_think_mt",
		"bot_native_refresh", "bot_native_contacts", "fc_hull_grid_native", "bot_native_finish"],
		"classes": ["GSSimBotSenses", "GSSimBotMind"], "methods": []},
	{"id": "shots", "cvars": ["sv_native_shots", "sv_native_unlag"],
		"classes": ["GSSimShots", "GSSimUnlagRing"], "methods": []},
	{"id": "snapshots", "cvars": ["net_pack_native", "sv_net_pull_native", "sv_net_pull_weapons_native",
		"sv_net_pull_content_native", "sv_native_snapshots", "sv_net_pull_apply_native", "sv_net_pull_batch",
			"sv_net_pull_rest_native"],
		"classes": ["GSSimFpsNetPack", "GSSimSnapshotCodec"], "methods": []},
]

## The class every gs-sim build registers; without it the library is not loaded at all.
const LIBRARY_PROBE := "GSSimFpsBody"

## Indices into PHASES, native_calls and script_calls (P1 players .. P6 snapshots).
const PLAYERS := 0
const MIRROR := 1
const MOTOR := 2
const BOTS := 3
const SHOTS := 4
const SNAPSHOTS := 5

static var _warned := false
## Per-phase call counts since the process started (or reset_calls): one per tick or per call the
## phase's dispatch made, native or GDScript fallback. Printed once at the end of the run.
static var native_calls := PackedInt64Array([0, 0, 0, 0, 0, 0])
static var script_calls := PackedInt64Array([0, 0, 0, 0, 0, 0])
static var _calls_printed := false


## Counts one dispatch of [param phase] (PLAYERS .. SNAPSHOTS). Hot path: no allocation.
static func tally(phase: int, native: bool) -> void:
	if native:
		native_calls[phase] += 1
	else:
		script_calls[phase] += 1


static func reset_calls() -> void:
	native_calls.fill(0)
	script_calls.fill(0)
	_calls_printed = false


## `players=native/script mirror=0/0 motor=1500/0 ...` in PHASES order.
static func calls_line() -> String:
	var parts := PackedStringArray()
	for i: int in PHASES.size():
		parts.append("%s=%d/%d" % [PHASES[i]["id"], native_calls[i], script_calls[i]])
	return " ".join(parts)


## Prints `FC_NATIVE_TICK_CALLS <calls_line>` once per run, only if any phase dispatched.
static func print_calls_once() -> void:
	if _calls_printed:
		return
	var any := false
	for i: int in native_calls.size():
		if native_calls[i] > 0 or script_calls[i] > 0:
			any = true
			break
	if not any:
		return
	_calls_printed = true
	print("FC_NATIVE_TICK_CALLS ", calls_line())  # check-logging: allow print (end-of-run summary)


## The bench's end-of-run lines: `SIM_HOST_NATIVE <status_line> | end`, then the call counts.
## Built only when the bench quits, never per frame.
static func print_bench_end(console: GSConsole) -> void:
	print("SIM_HOST_NATIVE %s | end" % status_line(console))  # check-logging: allow print (bench end line)
	print_calls_once()

## Registers (or adopts) the master, applies it and prints the startup line. Call last in the
## module load, after every phase cvar exists.
static func install(module: GSModule) -> GSConVar:
	var console: GSConsole = module.console
	var master: GSConVar = console.find_cvar(MASTER)
	var adopted := master != null
	if master == null:
		master = module.add_cvar(MASTER, "1",
			"1: every server tick phase (players, collision mirror, motor, bots, shots, snapshots) runs in gs-sim where its library has it; 0: every phase runs the GDScript fallback. Each phase's own cvar still overrides until this is written again",
			GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0)
	else:
		# An older branch registered this name for the motor-state switch alone; it keeps that
		# meaning and gains the master's. Its default may be 0 without that library, which must
		# not force every other phase off, so only an explicit write applies 0.
		GSLog.warn(CHANNEL, "sv_native_tick was already registered (motor-state switch); it now also drives every phase")
	master.changed.connect(func(_old: String, new_value: String) -> void:
		apply(console, new_value.to_float() >= 0.5)
		GSLog.info(CHANNEL, status_line(console)))
	if master.get_bool() or not adopted:
		apply(console, master.get_bool())
	var line := status_line(console)
	print("FC_NATIVE_TICK ", line)  # check-logging: allow print (startup report the benches grep)
	_warn_fallbacks(console)
	return master


## Writes every registered phase cvar to 1 (on) or 0 (off); the native paths still check their
## library at the call site, so 1 without it is the fallback, never an error.
static func apply(console: GSConsole, on: bool) -> void:
	var value := "1" if on else "0"
	for phase: Dictionary in PHASES:
		for name: String in phase["cvars"]:
			if name == MASTER:
				continue
			var cvar: GSConVar = console.find_cvar(name)
			if cvar != null:
				cvar.force_set(value)


## One row per phase: {id, status: "native" | "fallback" | "absent", reason}.
static func report(console: GSConsole) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var master: GSConVar = console.find_cvar(MASTER)
	var master_on := master == null or master.get_bool()
	var library := ClassDB.class_exists(LIBRARY_PROBE)
	for phase: Dictionary in PHASES:
		out.append(_phase_row(console, phase, master_on, library))
	return out


static func _phase_row(console: GSConsole, phase: Dictionary, master_on: bool, library: bool) -> Dictionary:
	var id: String = phase["id"]
	var present: Array[GSConVar] = []
	var off := ""
	for name: String in phase["cvars"]:
		var cvar: GSConVar = console.find_cvar(name)
		if cvar == null:
			continue
		present.append(cvar)
		if off.is_empty() and not cvar.get_bool():
			off = name
	var cvars: Array = phase["cvars"]
	if present.is_empty():
		return {"id": id, "status": "absent", "reason": "not in this build (no %s)" % cvars[0]}
	if not library:
		return {"id": id, "status": "fallback", "reason": "gs-sim library not loaded"}
	for cls: String in phase["classes"]:
		if not ClassDB.class_exists(cls):
			return {"id": id, "status": "fallback", "reason": "library missing %s" % cls}
	for pair: Array in phase["methods"]:
		if not ClassDB.class_has_method(pair[0], pair[1]):
			return {"id": id, "status": "fallback", "reason": "API too old: %s.%s" % [pair[0], pair[1]]}
	if not master_on and not off.is_empty():
		return {"id": id, "status": "fallback", "reason": "%s 0" % MASTER}
	if not off.is_empty():
		return {"id": id, "status": "fallback", "reason": "%s 0" % off}
	var runtime := _runtime_off(id)
	if not runtime.is_empty():
		return {"id": id, "status": "fallback", "reason": "runtime off: %s" % runtime}
	return {"id": id, "status": "native", "reason": ""}


## The script-side switches the cvars drive, read back: a cvar can say 1 while the addon's own
## availability check (library too old for the full tick) keeps the script path.
static func _runtime_off(id: String) -> String:
	match id:
		"motor":
			if not GSFpsPhysicsBody.native_enabled:
				return "GSFpsPhysicsBody.native_enabled"
			var body: Script = GSFpsPhysicsBody
			if body.has_method(&"native_tick_available") and not body.call(&"native_tick_available"):
				return "GSFpsPhysicsBody.native_tick_available()"
		"bots":
			if not GSBotWorld.native_enabled:
				return "GSBotWorld.native_enabled"
		"snapshots":
			if (GSFpsNetSync as Script).get(&"native_pack") == false:
				return "GSFpsNetSync.native_pack"
	return ""


## `master=1 native=[motor, bots] fallback=[shots: library missing GSSimShots] absent=[players]`.
static func status_line(console: GSConsole) -> String:
	var master: GSConVar = console.find_cvar(MASTER)
	var native := PackedStringArray()
	var fallback := PackedStringArray()
	var absent := PackedStringArray()
	for row: Dictionary in report(console):
		match row["status"]:
			"native":
				native.append(row["id"])
			"fallback":
				fallback.append("%s: %s" % [row["id"], row["reason"]])
			_:
				absent.append("%s: %s" % [row["id"], row["reason"]])
	return "master=%s native=[%s] fallback=[%s] absent=[%s]" % [
		master.get_string() if master != null else "?", ", ".join(native), "; ".join(fallback), "; ".join(absent)]


static func _warn_fallbacks(console: GSConsole) -> void:
	if _warned:
		return
	var why := PackedStringArray()
	for row: Dictionary in report(console):
		if row["status"] != "native":
			why.append("%s (%s)" % [row["id"], row["reason"]])
	if why.is_empty():
		return
	_warned = true
	GSLog.warn(CHANNEL, "server tick phases on the GDScript path: " + ", ".join(why))
