extends "fc_server_suite.gd"

const FcTestPorts := preload("test_ports.gd")
const FcMaps := preload("../game/fc_maps.gd")
const FcModes := preload("../game/fc_modes.gd")
const FcServer := preload("../game/fc_server.gd")

## Every way Fatal Contact's map changes takes ONE path, the module's map director (sync host, FC's state reset,
## `map_changed`, which applies the map config, the map list's `mode:`/`cfg:` and a pending `fc_mode`):
## `map`, `fc_map`, the rotation's next map, and a host's startup map (dot-server-deploy's `map:` in server.yml,
## which looks for `change_to` under `server.games`, where the game scene is and the module is not).
## And `fc_mode` is a cvar that refuses an unknown id, listing the valid ones, and waits for a map that can host it.
## Run `./game.sh test headless_map_path`.

var PORT := FcTestPorts.free_port()
const SERVER_DIR := "user://fc_map_path"
const TICK_RATE := 64

const SECTIONS := 5
const CHECKS := 33

## What the module handed this suite, the game's parent here as FcServer is on a real server.
var attached: Node = null
var _changed: Array[StringName] = []


## The module's hook (see FcServer.attach_maps): this suite stands where the game scene does.
func attach_maps(director: Node) -> void:
	attached = director


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: one map change path")
	GSPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	if await _boot_server("fc map path", PORT, SERVER_DIR, TICK_RATE):
		_module.maps.map_changed.connect(func(m: GSMapDef) -> void: _changed.append(m.id))
		_test_names()
		await _test_console_changes()
		await _test_host_startup()
		await _test_fc_mode()
		await _test_map_list_profile()

	_teardown()
	GSPaths.remove_tree(SERVER_DIR)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## Runs [param fn] (a coroutine returning a GSResult) while standing in for the server tick that opens the gate.
func _pump(fn: Callable) -> GSResult:
	var box := {"r": null}
	var runner := func() -> void:
		box["r"] = await fn.call()
	runner.call()
	for _i in 600:
		if box["r"] != null:
			break
		_game.tick_gate.open()
		await get_tree().process_frame
	return box["r"] if box["r"] != null else GSResult.fail(GSError.CODE_TIMEOUT, "never finished")


## Types [param line] at the server console and waits until the director reports a map change (or gives up).
func _console_change(line: String) -> GSResult:
	var before := _changed.size()
	var res := _server.console.execute(line, GSCmdContext.console("", PackedStringArray()))
	for _i in 600:
		if _changed.size() > before or not res.ok:
			break
		_game.tick_gate.open()
		await get_tree().process_frame
	return res


func _hosts(mode_id: StringName, other_than: StringName = &"") -> StringName:
	var mode := FcModes.by_id(mode_id)
	for id in FcMap.ids():
		var def := _module.maps.session.catalogue.get_map(id)
		if id != other_than and def != null and FcMaps.supports_mode(def, mode):
			return id
	return &""


func _test_names() -> void:
	_section("the commands exist")
	var console := _server.console
	for n: String in ["map", "fc_map", "fc_maps", "fc_nextmap", "fc_restart"]:
		_check(console.find_command(n) != null, "`%s` is a command" % n)
	_check(console.find_cvar("fc_mode") != null, "fc_mode is a cvar")
	var shim := console.find_command("arena_mode")
	_check(shim != null and shim.hidden and shim.description.contains("fc_mode"), "arena_mode is only a hidden shim naming fc_mode")
	_check(attached == _module.maps, "the module hands its director to the game scene (FcServer.attach_maps)")
	_done()


func _test_console_changes() -> void:
	_section("map and fc_map change through the director")
	var here := _game.map.id
	var a := &"dm_atrium" if here != &"dm_atrium" else &"dm_box"
	var res := await _console_change("map %s" % a)
	_check(res.ok and _changed.size() > 0 and _changed.back() == a and _game.map.id == a,
		"`map %s` changes the game and fires map_changed" % a, "%s %s game %s" % [str(res.error), _changed, _game.map.id])
	var b := &"dm_box"
	res = await _console_change("fc_map %s" % b)
	_check(res.ok and _changed.back() == b and _game.map.id == b,
		"`fc_map %s` takes the same path" % b, "%s %s game %s" % [str(res.error), _changed, _game.map.id])
	var count := _changed.size()
	res = await _console_change("fc_map no_such_map")
	_check(_changed.size() == count and _game.map.id == b, "an unknown id changes nothing", str(_changed))
	_done()


## dot-server-deploy's `_find_map_session`: the first node under `server.games` with `change_to` and `change_to_map`.
static func _host_find(root: Node, wants: Array[StringName]) -> Object:
	for child in root.get_children():
		var all := true
		for m in wants:
			all = all and child.has_method(m)
		if all:
			return child
		var found := _host_find(child, wants)
		if found != null:
			return found
	return null


func _test_host_startup() -> void:
	_section("a host's startup map (server.yml map:) goes through the director")
	# Not in the tree, so its _ready (which builds a second game) never runs: only its map forwarding is under test.
	var games := Node.new()
	var scene: Node = FcServer.new()
	scene.name = "ArenaServer"
	games.add_child(scene)
	var nothing: GSResult = await scene.change_to(&"dm_atrium")
	_check(not nothing.ok, "before the module attaches its director, the scene refuses a change")
	scene.attach_maps(_module.maps)
	var found := _host_find(games, [&"change_to", &"change_to_map"])
	_check(found == scene, "the host's search under server.games finds the game scene")
	var fetch := _host_find(games, [&"ensure_map_content"])
	var fetched: GSResult = await fetch.call(&"ensure_map_content", &"dm_atrium") if fetch != null else null
	var refused: GSResult = await fetch.call(&"ensure_map_content", &"no_such_map") if fetch != null else null
	_check(fetched != null and fetched.ok and refused != null and not refused.ok,
		"its fetch step knows the catalogue's maps and refuses others")
	var before := _changed.size()
	var res := await _pump(func() -> GSResult: return await found.call(&"change_to", &"dm_atrium"))
	_check(res.ok and _changed.size() == before + 1 and _game.map.id == &"dm_atrium",
		"change_to through it fires map_changed once", "%s %s" % [str(res.error), _changed])

	# `--map` naming a delivered pack: booted on the default, the director changes once, and the host asking again is that change.
	scene.attach_maps(null)
	scene.deferred_map = &"dm_box"
	before = _changed.size()
	scene.attach_maps(_module.maps)
	var again := await _pump(func() -> GSResult: return await found.call(&"change_to", &"dm_box"))
	for _i in 30:
		_game.tick_gate.open()
		await get_tree().process_frame
	_check(again.ok and _changed.size() == before + 1 and _game.map.id == &"dm_box",
		"a deferred --map changes once, and the host's change_to for it is the same change", "%s %s" % [str(again.error), _changed])
	scene.attach_maps(null)
	games.free()
	_done()


func _test_fc_mode() -> void:
	_section("fc_mode: validated, set like server.yml, applied at the next map that can host it")
	var console := _server.console
	var was := console.get_string("fc_mode", "")
	var bad := console.set_cvar("fc_mode", "not_a_mode")
	_check(not bad.ok, "an unknown mode is refused")
	var msg := bad.error.message if bad.error != null else ""
	var all_ids := true
	for id in FcModes.ids():
		all_ids = all_ids and msg.contains(String(id))
	_check(all_ids, "and the refusal lists every valid id", msg)
	_check(console.get_string("fc_mode", "") == was, "and the cvar keeps its value", console.get_string("fc_mode", ""))
	var typed := console.execute("fc_mode nope", GSCmdContext.console("", PackedStringArray()))
	_check(not typed.ok and console.get_string("fc_mode", "") == was, "typed at the console too")

	var ctf_map := _hosts(&"ctf")
	var no_ctf := &"dm_pit" if not FcMaps.supports_mode(_module.maps.session.catalogue.get_map(&"dm_pit"), FcModes.by_id(&"ctf")) else &""
	if not _check(ctf_map != &"" and no_ctf != &"", "a built-in map hosts ctf and dm_pit does not", "%s %s" % [ctf_map, no_ctf]):
		_done()
		return
	var res := await _console_change("map %s" % no_ctf)
	_check(res.ok and _game.map.id == no_ctf, "on %s" % no_ctf)
	# set_cvar is the path a server.yml / game.yml cvar takes once the module is loaded.
	var set := console.set_cvar("fc_mode", "ctf")
	for _i in 5:
		_game.tick_gate.open()
		await get_tree().process_frame
	_check(set.ok and _game.mode.id != &"ctf", "fc_mode ctf is taken, and waits on a map that cannot host it", String(_game.mode.id))
	_check(_module.maps.session.pending_mode != null and _module.maps.session.pending_mode.id == &"ctf", "as the pending mode")
	res = await _console_change("map %s" % ctf_map)
	_check(res.ok and _game.map.id == ctf_map and _game.mode.id == &"ctf", "and the next map that can host it plays it",
		"%s %s" % [_game.map.id, _game.mode.id])
	_check(_module.maps.session.pending_mode == null, "and nothing is pending after")
	var back := console.set_cvar("fc_mode", "ffa")
	for _i in 10:
		_game.tick_gate.open()
		await get_tree().process_frame
	_check(back.ok and _game.mode.id == &"ffa", "a mode the current map hosts applies live", String(_game.mode.id))
	_done()


func _test_map_list_profile() -> void:
	_section("the map list's per-map mode: and cfg: on map, fc_map and the rotation")
	var ctf_map := _hosts(&"ctf")
	var other := &"dm_box" if ctf_map != &"dm_box" else &"dm_atrium"
	var profile := SERVER_DIR + "/fast.yml"
	var pf := FileAccess.open(profile, FileAccess.WRITE)
	pf.store_string("mode: ffa\ncvars:\n  fc_scorelimit: 7\n")
	pf.close()
	var list := SERVER_DIR + "/maps.yml"
	var f := FileAccess.open(list, FileAccess.WRITE)
	f.store_string("defaults:\n  rotations:\n    main:\n      maps:\n        - map: %s\n          mode: ctf\n        - map: %s\n          cfg: %s\n" % [
		ctf_map, other, ProjectSettings.globalize_path(profile)])
	f.close()
	_module.maps.rotation_file_name = ProjectSettings.globalize_path(list)
	var read: GSResult = _module.maps.load_rotation()
	_check(read.ok and _module.maps.rotation_file != null and _module.maps.rotation_file.has_rotations(), "the map list is read", str(read.error))
	var limit_was := _server.console.get_string("fc_scorelimit", "")

	var res := await _console_change("fc_map %s" % other)
	_check(res.ok and _game.map.id == other and _server.console.get_string("fc_scorelimit", "") == "7",
		"fc_map onto an entry with cfg: applies its cvars", _server.console.get_string("fc_scorelimit", ""))
	res = await _console_change("map %s" % ctf_map)
	_check(res.ok and _game.map.id == ctf_map and _game.mode.id == &"ctf", "map onto an entry with mode: ctf plays ctf",
		"%s %s" % [_game.map.id, _game.mode.id])
	_check(_server.console.get_string("fc_scorelimit", "") == limit_was, "and the other entry's cvars are put back",
		_server.console.get_string("fc_scorelimit", ""))
	var _ok := _module.maps.set_next(other)
	var next := await _pump(func() -> GSResult: return await _module.maps.change_to_next())
	_check(next.ok and _game.map.id == other and _game.mode.id == &"ffa" and _server.console.get_string("fc_scorelimit", "") == "7",
		"the rotation's next map takes its entry's profile too", "%s %s %s" % [_game.map.id, _game.mode.id, _server.console.get_string("fc_scorelimit", "")])
	_done()
