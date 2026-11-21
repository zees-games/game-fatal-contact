extends "fc_server_suite.gd"

const FcTestPorts := preload("test_ports.gd")

## Fatal Contact's console names on a real dedicated server: the game's own are `fc_*`, the map
## change is gs-map's `map`, and an old `arena_*` name is only a hidden shim that says loudly
## what it was renamed to and then does it. Run `headless_console_names`.

var PORT := FcTestPorts.free_port()
const SERVER_DIR := "user://fc_console_names"
const TICK_RATE := 64

const SECTIONS := 3
const CHECKS := 13


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: console names on a dedicated server")
	GSPaths.remove_tree(SERVER_DIR)

	if await _boot_server("fc console names", PORT, SERVER_DIR, TICK_RATE):
		_test_new_names()
		_test_no_old_names_listed()
		_test_old_names_forward()

	_teardown()
	GSPaths.remove_tree(SERVER_DIR)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _test_new_names() -> void:
	_section("the new names")
	var console := _server.console
	var map_cmd := console.find_command("map")
	_check(map_cmd != null, "`map` is a known command (gs-map's map change)")
	_check(map_cmd != null and map_cmd.permission == GSAdminFlags.CHANGEMAP, "and it needs the changemap flag",
		map_cmd.permission if map_cmd != null else "")
	_check(console.find_command("maps") != null, "`maps` is a known command")
	_check(console.find_command("fc_maps") != null, "`fc_maps` (the listing that credits authors) is a known command")
	_check(console.find_cvar("fc_scorelimit") != null and console.find_cvar("fc_timelimit") != null,
		"fc_scorelimit and fc_timelimit are cvars")
	_done()


func _test_no_old_names_listed() -> void:
	_section("no arena_ name is listed")
	var console := _server.console
	var listed := PackedStringArray()
	var shims := 0
	for n: String in console.cvar_names():
		if n.begins_with("arena_"):
			listed.append(n)
	for n: String in console.command_names():
		if not n.begins_with("arena_"):
			continue
		var cmd := console.find_command(n)
		if cmd.hidden and cmd.description.begins_with("Renamed: use "):
			shims += 1
		else:
			listed.append(n)
	_check(listed.is_empty(), "no cvar or listed command starts with arena_", ", ".join(listed))
	_check(shims > 50, "the old names are hidden shims (%d)" % shims)
	_done()


func _test_old_names_forward() -> void:
	_section("an old name says what it became, then does it")
	var console := _server.console
	_replies.clear()
	var ctx := GSCmdContext.console("", PackedStringArray())
	ctx.reply_sink = func(text: String) -> void: _replies.append(text)
	var _r := console.execute("arena_scorelimit 30", ctx)
	_check(console.find_cvar("fc_scorelimit").get_int() == 30, "arena_scorelimit 30 sets fc_scorelimit",
		console.find_cvar("fc_scorelimit").get_string())
	_check("\n".join(_replies).contains("arena_scorelimit was renamed to fc_scorelimit"),
		"and the reply names the new name", "\n".join(_replies))

	var old_map := console.find_command("arena_map")
	_check(old_map != null and old_map.description == "Renamed: use map", "arena_map points at gs-map's map")
	var old_report := console.find_command("arena_stats_report")
	_check(old_report != null and old_report.description == "Renamed: use stats_report",
		"arena_stats_report points at stats_report, and is no silent alias")
	_check(console.find_cvar("arena_stats_report") == null and console.find_cvar("fc_stats_report") == null,
		"no stats_report alias cvar is left")
	_done()
