extends GSGameCheckSuite

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMaps := preload("../game/fc_maps.gd")
const FcMode := preload("../game/fc_mode.gd")

## Every map can host a team deathmatch: a map with no tagged sides has its spawns split into two halves that start apart. Checks the capability (what the ballot, the map menu and the refusals read) for every map in the catalogue,
## that the split gives each side spawns and puts the halves apart, and that a running free-for-all game changes onto a map and into a team mode (gg-canyon when linked).
## Run: [code]godot --headless --path . res://examples/headless_team_capable.tscn[/code]

var _n := 0


func _ok(cond: bool, label: String, detail: String = "") -> bool:
	_n += 1
	return _check(cond, label, detail)


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: every map can host a team mode")
	var tdm := FcMode.team_deathmatch()
	var catalogue := FcMaps.catalogue()
	var count := 0
	for def: GSMapDef in catalogue.maps:
		count += 1
		var map: FcMap = FcMap.by_id(def.id)
		_ok(FcMaps.supports_mode(def, tdm), "%s can host Team Deathmatch" % def.id)
		if map == null or map.spawns.size() < 2:
			continue
		var _n := map.split_spawns_for_teams()
		var red := 0
		var blue := 0
		var centre_red := Vector3.ZERO
		var centre_blue := Vector3.ZERO
		for i in range(map.spawns.size()):
			if map.spawn_tag(i) == &"red":
				red += 1
				centre_red += map.spawns[i].origin
			elif map.spawn_tag(i) == &"blue":
				blue += 1
				centre_blue += map.spawns[i].origin
		_ok(red > 0 and blue > 0, "%s has spawns for both sides" % def.id, "%d red %d blue" % [red, blue])
		if red > 0 and blue > 0:
			_ok(centre_red / float(red) != centre_blue / float(blue), "%s: the sides start apart" % def.id)
	_ok(count >= 3, "the catalogue lists the maps", str(count))
	var again := FcMap.by_id(&"gg-canyon")
	if again == null:
		print("skip gg-canyon change: not linked")
	else:
		await _change_into_team_mode(again, tdm)
	_report_sections(1, 1, 1, _n)


func _change_into_team_mode(canyon: FcMap, tdm: FcMode) -> void:
	var game := FcGame.new()
	game.tick_rate = 64
	game.headless = true
	game.is_authority = true
	game.register_service = false
	game.mode = FcMode.free_for_all()
	add_child(game)
	_ok(game.setup(FcMap.box()).ok, "a free-for-all game sets up")
	var changed := game.change_map(canyon, tdm)
	_ok(changed.ok, "and changes onto gg-canyon in Team Deathmatch", changed.error.message if not changed.ok else "")
	_ok(Array(canyon.spawn_tags).has("red") and Array(canyon.spawn_tags).has("blue"), "with a spawn for each side")
	game.queue_free()
