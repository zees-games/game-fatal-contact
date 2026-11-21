extends GSGameCheckSuite

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMaps := preload("../game/fc_maps.gd")
const FcModes := preload("../game/fc_modes.gd")
const FcMapDirector := preload("../game/fc_map_director.gd")
const FcMapConfig := preload("../game/fc_map_config.gd")

## A maps.yml entry's profile (`GSMapDef.profile`, dot-map's `mode:`/`cfg:`): its mode on the map change when the map can host it, the server's mode back on the next map, its cvars for that map only, and the rotation filter.
## [codeblock] godot --headless --path . res://examples/headless_rotation_profile.tscn
## [/codeblock]

const CHECKS := 15


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


# Every map hosts a team mode now, so the refusal this file exercises is simulated: dm_pit's listing says it cannot (the filter reads that one property).
func _pit_cannot_host_teams(catalogue: GSMapCatalogue) -> GSMapCatalogue:
	catalogue.get_map(&"dm_pit").meta["teams"] = false
	return catalogue


func _run() -> void:
	print("FC: per-map rotation profiles (mode and cvars)")
	var catalogue := _pit_cannot_host_teams(FcMaps.catalogue())
	var ffa := FcModes.by_id(&"ffa")
	var tdm := FcModes.by_id(&"tdm")
	var team_map: StringName = &""
	var other_map: StringName = &""
	for id in FcMap.ids():
		var def := catalogue.get_map(id)
		if def != null and team_map == &"" and FcMaps.supports_mode(def, tdm):
			team_map = id
		elif def != null and other_map == &"" and id != &"dm_pit":
			other_map = id
	if not _check(team_map != &"" and other_map != &"" and not FcMaps.supports_mode(catalogue.get_map(&"dm_pit"), tdm),
			"a built-in map hosts tdm, another does not need to and dm_pit cannot", "%s %s" % [team_map, other_map]):
		_report(CHECKS)
		return

	var game := FcGame.new()
	game.tick_rate = 64
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = ffa
	add_child(game)
	var started := game.setup(FcMap.by_id(other_map))
	var director := FcMapDirector.new()
	director.name = "Maps"
	director.game = game
	director.map_seconds = 0.0
	add_child(director)
	var ready := director.setup()
	if not _check(started.ok and ready.ok, "the game and the map director set up"):
		_report(CHECKS)
		return
	var defs := _pit_cannot_host_teams(director.session.catalogue)

	# A profile mode the map hosts: the change plays it.
	defs.get_map(team_map).profile = {"value": "tdm", "mode": "tdm", "cfg_path": "", "values": {}}
	var changed: GSResult = await director.change_to(team_map)
	_check(changed.ok and game.map.id == team_map, "the profile map is built", str(changed.error))
	_check(game.mode.id == &"tdm", "in its profile's mode", String(game.mode.id))

	# The next map names none: the server's mode comes back.
	changed = await director.change_to(other_map)
	_check(changed.ok and game.mode.id == &"ffa", "the next map without a profile has the server's mode back", String(game.mode.id))

	# A profile naming a mode the map cannot host: the map still plays, in the current mode.
	defs.get_map(&"dm_pit").profile = {"value": "tdm", "mode": "tdm", "cfg_path": "", "values": {}}
	changed = await director.change_to(&"dm_pit")
	_check(changed.ok and game.map.id == &"dm_pit", "a map whose profile mode it cannot host still plays", str(changed.error))
	_check(game.mode.id == &"ffa", "and the current mode stays", String(game.mode.id))

	# A mode id nothing knows: the same.
	defs.get_map(other_map).profile = {"value": "nosuch", "mode": "nosuch", "cfg_path": "", "values": {}}
	changed = await director.change_to(other_map)
	_check(changed.ok and game.mode.id == &"ffa", "an unknown profile mode keeps the current mode", String(game.mode.id))
	defs.get_map(other_map).profile = {}

	# An operator's mode is not a profile's to undo.
	changed = await director.change_to(team_map)
	director.session.forget_profile_mode()
	var after := director.session.mode_after(defs.get_map(other_map))
	_check(changed.ok and after != null and after.id == &"tdm", "after an operator's mode the next plain map keeps it",
		String(after.id) if after != null else "null")

	# The rotation filter, with a team mode running: dm_pit is kept only for its ffa profile.
	game.change_map(FcMap.by_id(team_map), tdm)
	director.session.forget_profile_mode()
	defs.get_map(&"dm_pit").profile = {}
	director.restrict_rotation()
	_check(not director.session.rotation.order.has(&"dm_pit"), "a team mode drops a map that cannot host it from the rotation")
	defs.get_map(&"dm_pit").profile = {"value": "ffa", "mode": "ffa", "cfg_path": "", "values": {}}
	director.restrict_rotation()
	_check(director.session.rotation.order.has(&"dm_pit"), "but keeps it when its profile names a mode it hosts")
	_check(director.session.mode_after(defs.get_map(&"dm_pit")).id == &"ffa", "mode_after answers the profile's mode")

	_check_profile_cvars()

	_report(CHECKS)

func _check_profile_cvars() -> void:
	# The profile's cvars, for one map only.
	var console := GSConsole.new()
	add_child(console)
	console.cvar("fc_profile_a", "1", "", GSConVar.FLAG_ARCHIVE)
	console.cvar("fc_mode", "ffa", "", GSConVar.FLAG_ARCHIVE)
	var applier := FcMapConfig.build_profile(console)
	var with := GSMapDef.new()
	with.id = &"p_with"
	with.profile = {"value": "x", "mode": "", "cfg_path": "/x.yml", "values": {"fc_profile_a": 5, "fc_mode": "ctf", "no_such_cvar": 2}}
	var got := FcMapConfig.apply_profile(applier, console, with)
	_check(console.find_cvar("fc_profile_a").get_int() == 5 and got.size() == 1, "a profile's cvar is set for its map", str(got))
	_check(console.find_cvar("fc_mode").get_string() == "ffa", "a profile cannot set fc_mode through its cvars")
	var plain := GSMapDef.new()
	plain.id = &"p_plain"
	FcMapConfig.apply_profile(applier, console, plain)
	_check(console.find_cvar("fc_profile_a").get_int() == 1, "the next map has the server's value back")

