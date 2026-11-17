extends DotGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")

## What the bot-on-an-imported-map suites share: the map loop, a game with bots (and optionally
## one human) on a map, the baked route mesh waited for, and the bots' think-and-tick step.
## A suite supplies [method _title], [method _default_maps] and [method _one].
const TICK_RATE := 64

var _world: FcBots.World = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _title() -> String:
	return ""


func _default_maps() -> Array[StringName]:
	return []


func _one(_id: StringName) -> void:
	pass


func _run() -> void:
	print(_title())
	var maps: Array[StringName] = []
	for a in OS.get_cmdline_user_args():
		maps.append(StringName(a))
	if maps.is_empty():
		maps = _default_maps()
	var ran := 0
	for id in maps:
		if FcMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			continue
		await _one(id)
		ran += 1
	_report_sections(maps.size(), ran, maps.size(), maps.size())


## A game on map [param id] with [param bots] bots (ids from 1) and, when [param human] is
## above 0, a human of that id. Null after a failed check when the map would not set up.
func _boot_map(id: StringName, bots: int, human := 0) -> FcGame:
	var game := FcGame.new()
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var map: FcMap = FcMap.by_id(id)
	if not game.setup(map).ok:
		_check(false, "%s sets up" % id)
		return null
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	for b in bots:
		var _a := game.add_player(b + 1, "Bot%d" % b)
	if human > 0:
		var _h := game.add_player(human, "Human")
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	_world = FcBots.world_for(game)
	var _first := _world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while _world.is_route_pending() and frames < 2400:
		await get_tree().process_frame
		frames += 1
	return game


func _make_minds(bots: int) -> Dictionary:
	var minds := {}
	for b in bots:
		var m := FcBots.Mind.new()
		m.seed = 11 + b
		minds[b + 1] = m
	return minds


## One game tick with every bot thinking.
func _tick_bots(game: FcGame, minds: Dictionary, bots: int, tick: int) -> void:
	var commands := {}
	for b in bots:
		var p := game.player_for(b + 1)
		if p != null:
			commands[b + 1] = FcBots.think(game, p, minds[b + 1], tick, float(TICK_RATE))
	game.tick(commands)


func _release(game: FcGame) -> void:
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
