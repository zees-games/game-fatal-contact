extends GSGameCheckSuite

## Maps handed to Fatal Contact outside the window (FcMapDrop, gs-map's GSMapDropIntake, API 30): dropped on the executable or named by `--map-path=`, through the same intake and the same on-screen answer as a window drop.
## A path that holds no converted map is refused out loud with what the game takes. Window drops: headless_local_maps. [codeblock] ./game.sh test headless_mapdrop [/codeblock]

const FcClient := preload("../game/fc_client.gd")
const FcMaps := preload("../game/fc_maps.gd")
const FcMapDrop := preload("../game/fc_map_drop.gd")

const FIXTURE_DIR := "res://examples/local_maps"
const SOURCE := "user://headless_mapdrop"
const MAP := "zz_headless_mapdrop"
const SECTIONS := 3


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	if GSAddonApi.build_level("gs_map") < FcMapDrop.NEEDS_LEVEL:
		print("-- skipped: gs-map API %d < %d (no GSMapDropIntake)" % [GSAddonApi.build_level("gs_map"), FcMapDrop.NEEDS_LEVEL])
		_report_sections(0, 0, 0)
		return
	var entered := 0
	var finished := 0
	_clean()
	entered += 1
	_test_args()
	finished += 1
	entered += 1
	await _test_intake()
	finished += 1
	entered += 1
	await _test_cmdline()
	finished += 1
	_clean()
	_report_sections(entered, finished, SECTIONS)


func _test_args() -> void:
	print("-- the command line: config options are not drops, --map-path and bare paths are")
	var folder := ProjectSettings.globalize_path(SOURCE.path_join("args"))
	DirAccess.make_dir_recursive_absolute(folder)
	var client := FcClient.new()
	var intake := client.drop_intake()
	if not _check(intake != null, "the client makes the shared intake"):
		client.free()
		return
	var kept: PackedStringArray = intake.call(&"strip_config_args", PackedStringArray(["--arena-bots", folder, "--gs_net.port", folder,
		"--arena-no-weapon-packs", folder, "--config=x", "--headless"]), intake.get(&"config_prefixes"), intake.get(&"option_takes_value"))
	_check(kept == PackedStringArray([folder, "--config=x", "--headless"]),
		"--arena-<key> and --<addon>.<key> values are not drops; a --arena-no- switch takes no value", str(kept))
	_check(not bool(intake.get(&"watch_window")), "it leaves the window to the client's own handler (Importing… first)")
	var paths: PackedStringArray = intake.call(&"paths_in", PackedStringArray(["--path", folder, "--map", folder, "--map-path=" + folder]))
	_check(paths == PackedStringArray([folder]), "--map-path= is a drop; --path and --map values are not", str(paths))
	paths = intake.call(&"paths_in", PackedStringArray([folder, "--arena-port", folder]))
	_check(paths == PackedStringArray([folder]), "a bare path is a drop (the executable's drop)", str(paths))
	paths = intake.call(&"paths_in", PackedStringArray(["--map-path=/no/such/zz_headless_mapdrop"]))
	_check(paths == PackedStringArray(["/no/such/zz_headless_mapdrop"]), "a --map-path that does not exist is kept, to be refused", str(paths))
	paths = intake.call(&"paths_in", PackedStringArray(["--headless", "res://examples/headless_mapdrop.tscn"]))
	_check(paths.is_empty(), "no path on a plain start", str(paths))
	paths = intake.call(&"paths_in", PackedStringArray(["wss://tmcdev.net:6100/", "ws://127.0.0.1:6100", "https://games.tmcdev.net/x", "tmcdev.net:6100", "--join", "wss://tmcdev.net:6100/"]))
	_check(paths.is_empty(), "a connect URL or host:port is never a drop (the 'dropped maps play in solo only' toast)", str(paths))
	paths = intake.call(&"paths_in", PackedStringArray(["wss://tmcdev.net:6100/", folder]))
	_check(paths == PackedStringArray([folder]), "a real path beside a connect URL is still a drop", str(paths))
	_check((intake.call(&"paths_in_args", PackedStringArray(["wss://tmcdev.net:6100/", "tmcdev.net:6100"])) as Dictionary)["missing"].is_empty(),
		"gs-map's own intake skips URLs too")
	client.free()


func _test_intake() -> void:
	print("-- every drop goes through the intake: a deep download, a depth limit, junk, a missing path")
	FcMaps.list_local = true
	var client := FcClient.new()
	client._menu_catalogue = FcMaps.catalogue()
	client.source_game_path = SOURCE.path_join("no_such_install")
	var intake := client.drop_intake()
	var id := StringName(MAP + GSMapLocalMaps.ID_SUFFIX)
	var deep := SOURCE.path_join("deep")
	_pack_as(deep.path_join("a/b/c/d/convert"), MAP)
	var said: String = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(deep)]))
	_check(said.contains("not a map this game can load (it takes %s)" % FcMapDrop.TAKES),
		"a pack deeper than search_depth (3) is refused with what the game takes", said)
	_check(not client._menu_catalogue.has(id), "and not listed")
	intake.set(&"search_depth", 0)
	said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(deep)]))
	_check(said.begins_with("Added %s" % (MAP + GSMapLocalMaps.TAG)), "search_depth 0 is no limit: found five folders down", said)
	_check(client._menu_catalogue.has(id), "M lists it")
	var result: Dictionary = intake.get(&"last_result")
	_check(str(result.get("source", "")) == "window" and (result.get("added", []) as Array).size() == 1,
		"the intake's result says where it came from and what it added", str(result.get("source", "")))
	intake.set(&"search_depth", 3)
	_wipe("user://maps".path_join(MAP))

	var junk := SOURCE.path_join("notes.txt")
	_write(junk, "not a map")
	var refused := int(intake.get(&"refused_total"))
	said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(junk)]))
	_check(said.begins_with("Could not import notes.txt: not a map this game can load"), "junk is refused out loud", said)
	_check(int(intake.get(&"refused_total")) == refused + 1, "and counted as refused")
	_check(not FileAccess.file_exists("user://maps/notes.txt"), "and nothing is copied")
	said = await client.import_dropped(PackedStringArray(["/no/such/zz_headless_mapdrop"]))
	_check(said.contains("zz_headless_mapdrop: not found"), "a path that does not exist is said", said)

	FcMaps.list_local = false
	said = await client.import_dropped(PackedStringArray([ProjectSettings.globalize_path(deep)]), "command line")
	_check(said.contains("dropped maps play in solo only"), "a server's client refuses an executable drop too", said)
	FcMaps.list_local = true
	client.free()


func _test_cmdline() -> void:
	print("-- dropped on the executable / --map-path: imported and said like a window drop")
	FcMaps.list_local = true
	var client := FcClient.new()
	client._menu_catalogue = FcMaps.catalogue()
	client.source_game_path = SOURCE.path_join("no_such_install")
	var folder := SOURCE.path_join("exe/convert")
	_pack_as(folder, MAP)
	var said: String = await client._take_cmdline_drops(PackedStringArray(["--headless", "--map-path=" + ProjectSettings.globalize_path(folder)]))
	var id := StringName(MAP + GSMapLocalMaps.ID_SUFFIX)
	_check(said.begins_with("Added %s" % (MAP + GSMapLocalMaps.TAG)), "a --map-path map is added and said", said)
	_check(client._menu_catalogue.has(id), "M lists it")
	_check(str((client.drop_intake().get(&"last_result") as Dictionary).get("source", "")) == "command line",
		"the intake knows it came from the command line")
	_check(GSMapLocalMaps.prefix_in("user://maps".path_join(MAP).path_join("convert")) != "",
		"copied as user://maps/<map>/convert, as a window drop is")
	said = await client._take_cmdline_drops(PackedStringArray(["wss://tmcdev.net:6100/"]))
	_check(said == "", "a connect URL on the command line says nothing", said)
	client.last_drop_said = ""
	FcMaps.list_local = false
	said = await client._take_cmdline_drops(PackedStringArray([ProjectSettings.globalize_path(SOURCE.path_join("notes.txt")), "wss://tmcdev.net:6100/"]))
	_check(said == "" and client.last_drop_said == "", "a joined session never reads the command line", said)
	FcMaps.list_local = true
	_wipe("user://maps".path_join(MAP))
	said = await client._take_cmdline_drops(PackedStringArray(["--headless", "res://examples/headless_mapdrop.tscn"]))
	_check(said == "", "a start with no path imports nothing", said)
	said = await client._take_cmdline_drops(PackedStringArray([ProjectSettings.globalize_path(SOURCE.path_join("notes.txt"))]))
	_check(said.contains("not a map this game can load"), "a file dropped on the executable that is no map is refused", said)
	client.free()


func _pack_as(dir: String, map_name: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join(map_name + ".json"),
		FileAccess.get_file_as_string(FIXTURE_DIR.path_join("fixture.json")).replace("\"fixture.bin\"", "\"%s.bin\"" % map_name))
	var _copied := DirAccess.copy_absolute(FIXTURE_DIR.path_join("fixture.bin"), dir.path_join(map_name + ".bin"))


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	_wipe(SOURCE)
	_wipe("user://maps".path_join(MAP))


func _wipe(dir: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		_wipe(dir.path_join(sub))
	for file in d.get_files():
		var _gone := DirAccess.remove_absolute(dir.path_join(file))
	var _removed := DirAccess.remove_absolute(dir)
