extends GSGameCheckSuite

## Control point end to end: the line's lock order, capture by standing, a contest pausing it, decay, the sweep
## ending the match, the replicated state and the HUD rows on a built-in map; then bots taking all five points of
## cp-orange-x3 (fc-dm-maps), which skips when the map is not linked at maps/imported_dm.

const FcGame := preload("../game/fc_game.gd")
const FcHud := preload("../game/fc_hud.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcModes := preload("../game/fc_modes.gd")
const FcBots := preload("../game/fc_bots.gd")
const FcControlPoints := preload("../game/fc_control_points.gd")
const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcBspMap := preload("../maps/fc_bsp_map.gd")

const TICK_RATE := 64
const MAP := &"cp-orange-x3"
const BOTS := 6
const BOT_SECONDS := 240.0
const SECTIONS := 3

var _entered := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("arena — control point: lock order, capture, contest, decay, sweep, wire, bots")
	_test_mode()
	_test_scripted()
	await _test_bots()
	_report_sections(_entered, _finished, SECTIONS)


func _new_game(map: FcMap, authority := true) -> FcGame:
	var game := FcGame.new()
	game.tick_rate = TICK_RATE
	game.headless = true
	game.is_authority = authority
	game.register_service = false
	game.mode = FcMode.control_point()
	add_child(game)
	var res := game.setup(map)
	if not _check(res.ok, "a control point game sets up on %s" % map.id, str(res.error)):
		game.queue_free()
		return null
	return game


func _go_live(game: FcGame) -> void:
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.min_players = 1
	game.freeze_sec = 0.0
	var guard := 0
	while not game.match_node.is_live() and guard < TICK_RATE * 20:
		game.tick({})
		guard += 1


func _stand(game: FcGame, id: int, at: Vector3) -> void:
	var player := game.player_for(id)
	if player != null and player.controller != null:
		player.controller.state.position = at
		player.controller.state.velocity = Vector3.ZERO


## Ticks with each named player held at a spot, until [param until] says so or [param limit] ticks pass.
func _hold(game: FcGame, spots: Dictionary, limit: int, until: Callable = Callable()) -> int:
	for i in limit:
		for id in spots:
			_stand(game, id, spots[id])
		game.tick({})
		if until.is_valid() and until.call():
			return i + 1
	return limit


func _test_mode() -> void:
	_entered += 1
	print("-- the mode is data: one display name, a team mode, the cp layout, appended last")
	var mode := FcModes.by_id(&"cp")
	_check(mode != null and mode.display_name == FcMode.CONTROL_POINT_NAME, "the mode by id carries the one display name")
	_check(mode != null and mode.is_team_mode() and mode.team_count == 2, "a two-side team mode")
	_check(FcModes.ids()[FcModes.ids().size() - 1] == &"cp", "appended after every older mode (mode_index travels)")
	_finished += 1


func _test_scripted() -> void:
	_entered += 1
	print("-- three fallback points on a built-in map: lock order, capture, contest, decay, sweep, wire, HUD")
	var game := _new_game(FcMap.dm_atrium())
	if game == null:
		return
	game.start(0)
	var _a := game.add_player(901, "Red")
	var _b := game.add_player(902, "Blue")
	_go_live(game)
	var red := 901 if game.team_of(901) == FcControlPoints.RED else 902
	var blue := 902 if red == 901 else 901
	_check(game.team_of(red) == FcControlPoints.RED and game.team_of(blue) == FcControlPoints.BLUE, "one player per side")
	var manager: GSObjectiveManager = game.objectives.manager
	var line := FcControlPoints.line_of(manager)
	if not _check(line.size() == 3, "three points in the line", str(line.size())):
		return
	_check(line[0].owner_team == FcControlPoints.RED and line[1].owner_team == 0 and line[2].owner_team == FcControlPoints.BLUE,
		"red holds its end, blue its end, the middle is neutral")
	_check(FcControlPoints.open_to(manager, line[1], FcControlPoints.RED) and FcControlPoints.open_to(manager, line[1], FcControlPoints.BLUE),
		"both sides may start the middle")
	_check(not FcControlPoints.open_to(manager, line[2], FcControlPoints.RED) and not FcControlPoints.open_to(manager, line[0], FcControlPoints.BLUE),
		"neither may start the other's end before the middle")

	var away := Vector3(0.0, game.map.floor_y + 1.0, game.map.extent * 0.5)
	var mid: Vector3 = line[1].def.area.centre
	var far: Vector3 = line[2].def.area.centre
	var _t := _hold(game, {red: far, blue: away}, TICK_RATE * 2)
	_check(line[2].progress() == 0.0 and line[2].owner_team == FcControlPoints.BLUE, "red standing on blue's locked end does nothing")

	_t = _hold(game, {red: mid, blue: away}, TICK_RATE * 2)
	var part := line[1].progress()
	_check(part > 0.0 and line[1].progressing_team() == FcControlPoints.RED, "standing on the middle captures it", "%.2f" % part)
	_t = _hold(game, {red: mid, blue: mid}, TICK_RATE)
	_check(is_equal_approx(line[1].progress(), part), "blue standing on it too pauses the capture", "%.2f vs %.2f" % [line[1].progress(), part])
	_t = _hold(game, {red: away, blue: away}, TICK_RATE)
	_check(line[1].progress() < part, "left alone, the capture decays", "%.2f < %.2f" % [line[1].progress(), part])

	var took := _hold(game, {red: mid, blue: away}, TICK_RATE * 30, func() -> bool: return line[1].owner_team == FcControlPoints.RED)
	_check(line[1].owner_team == FcControlPoints.RED, "red holds the middle", "%d ticks" % took)
	_check(FcControlPoints.open_to(manager, line[2], FcControlPoints.RED) and not FcControlPoints.open_to(manager, line[0], FcControlPoints.BLUE),
		"blue's end opens to red; red's end stays shut to blue")
	_check(FcControlPoints.front(manager) == line[2], "the bots' front is red's next point")

	var hud := FcHud.new()
	hud.game = game
	var rows := hud.control_point_rows()
	_check(rows.size() == 3 and int(rows[1]["owner"]) == FcControlPoints.RED and not bool(rows[2]["locked"]),
		"the HUD rows read the line: three, the middle red, blue's end open", str(rows))
	hud.free()

	var text := game.objectives.ctf_wire_text(game.current_tick(), true)
	var client := _new_game(FcMap.dm_atrium(), false)
	if client != null:
		client.objectives.apply_ctf_text(text)
		var mirrored := FcControlPoints.line_of(client.objectives.manager)
		_check(mirrored.size() == 3 and mirrored[1].owner_team == FcControlPoints.RED and mirrored[2].owner_team == FcControlPoints.BLUE,
			"a client applies the replicated owners", text)
		client.queue_free()

	var ended := [false]
	game.match_node.match_ended.connect(func(_w: Variant, _o: Variant) -> void: ended[0] = true)
	took = _hold(game, {red: far, blue: away}, TICK_RATE * 30, func() -> bool: return ended[0])
	_check(line[2].owner_team == FcControlPoints.RED or ended[0], "red takes blue's end")
	_check(game.match_node.scoreboard.team_score(FcControlPoints.RED) >= 1, "the sweep scores red's round",
		str(game.match_node.scoreboard.team_score(FcControlPoints.RED)))
	_check(ended[0], "holding every point wins the match at the score limit", "%d ticks" % took)
	game.queue_free()
	_finished += 1


func _test_bots() -> void:
	_entered += 1
	print("-- cp-orange-x3: the manifest's five points, and bots taking them all")
	if not FcImportedMaps.has(MAP):
		print("no %s under maps/imported_dm — skipping the bot run (link fc-dm-maps)" % MAP)
		_finished += 1
		return
	var map: FcMap = FcMap.by_id(MAP)
	var points := FcControlPoints.points_of(map)
	_check(points.size() == 5, "five control points from the manifest", str(points.size()))
	var owners := []
	for p in points:
		owners.append(str(p["owner"]))
	_check(owners == ["red", "", "", "", "blue"], "red holds point 1, blue point 5, the rest neutral", str(owners))
	_check(points.size() > 0 and absf(float(points[0]["radius"]) - FcBspMap.CONTROL_POINT_RADIUS_UNITS * FcBspMap.METRES_PER_UNIT) < 0.05, "the default radius is 160 units",
		"%.2f" % float(points[0]["radius"]) if points.size() > 0 else "")
	var game := _new_game(map)
	if game == null:
		return
	# Every bot on red, so the line is pushed home rather than fought over: the check is that bots go and take points.
	var teams = game.match_node.teams
	teams.default_team = FcControlPoints.RED
	teams.force_balance = false
	teams.max_difference = 0
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.min_players = 1
	game.freeze_sec = 0.0
	var minds := {}
	for i in BOTS:
		var _added := game.add_player(i + 1, "bot%d" % (i + 1))
		minds[i + 1] = FcBots.Mind.new()
	var world := FcBots.world_for(game)
	var frames := 0
	while not world.warm() and frames < 6000:
		await get_tree().process_frame
		frames += 1
	game.start(0)
	_go_live(game)
	var on_red := 0
	for id in minds:
		on_red += 1 if game.team_of(id) == FcControlPoints.RED else 0
	_check(on_red == BOTS, "every bot is red", "%d of %d" % [on_red, BOTS])
	var ended := [false]
	game.match_node.match_ended.connect(func(_w: Variant, _o: Variant) -> void: ended[0] = true)
	var manager: GSObjectiveManager = game.objectives.manager
	var took := {}
	var ticks := 0
	while ticks < int(BOT_SECONDS * TICK_RATE) and not ended[0]:
		var commands := {}
		for id in minds:
			commands[id] = FcBots.think(game, game.player_for(id), minds[id], game.current_tick() + 1, float(TICK_RATE))
		game.tick(commands)
		ticks += 1
		for obj in FcControlPoints.line_of(manager):
			if obj.owner_team == FcControlPoints.RED and not took.has(obj.id()):
				took[obj.id()] = ticks
		if ticks % 4 == 0:
			await get_tree().process_frame
	print("  points taken at ticks %s; %.1f s of play" % [took, float(ticks) / TICK_RATE])
	_check(took.size() == 5, "the bots hold all five points", str(took.keys()))
	_check(ended[0], "the sweep ends the match", "%.1f s" % (float(ticks) / TICK_RATE))
	game.queue_free()
	_finished += 1
