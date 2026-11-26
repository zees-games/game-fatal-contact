extends GSGameCheckSuite

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPlayer := preload("../game/fc_player.gd")

## The COUNTDOWN-start bulk spawn: the director's cost per player, and what FcGame.respawn_player costs, on the largest map.
const PLAYERS := 11
const BUDGET_MS := 4.0
## The very first respawn pays lazy loadout/resource setup once (5-9 ms on PH, 12-20 ms before); budget is one 60 fps frame.
const FIRST_BUDGET_MS := 16.0

var _class_checked := false


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact spawn cost")
	var maps: Array[StringName] = []
	for a in OS.get_cmdline_user_args():
		maps.append(StringName(a))
	if maps.is_empty():
		maps = [&"crackhouse", &"dm-overwatch", &"dm_box"]
	var ran := 0
	for id in maps:
		if FcMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			continue
		await _one(id)
		ran += 1
	_report_sections(maps.size(), ran, maps.size(), ran * 4 + (1 if ran > 0 else 0))


func _one(id: StringName) -> void:
	var game := FcGame.new()
	game.tick_rate = 64
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	if not game.setup(FcMap.by_id(id)).ok:
		_check(false, "%s sets up" % id)
		return
	for b in PLAYERS:
		var _a := game.add_player(b + 1, "P%d" % b)
	game.player_stack.refresh_spawn_rules()
	game.start(0)
	game.tick({})
	var worst_choose := 0.0
	var sum_choose := 0.0
	var worst_respawn := 0.0
	var first_respawn := 0.0
	for r in 5:
		var t_batch := Time.get_ticks_usec()
		for b in PLAYERS:
			var t0 := Time.get_ticks_usec()
			var _c := game.player_stack.choose_spawn(b + 1)
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			worst_choose = maxf(worst_choose, ms)
			sum_choose += ms
		for b in PLAYERS:
			var t0 := Time.get_ticks_usec()
			var _r := game.respawn_player(b + 1)
			var rms := (Time.get_ticks_usec() - t0) / 1000.0
			if r == 0 and b == 0:
				first_respawn = rms
			else:
				worst_respawn = maxf(worst_respawn, rms)
		game.tick({})
		var _tb := t_batch
	_sight_parity(game, id)
	if not _class_checked:
		_class_checked = true
		_class_base_parity(game.player_for(1))
	var mean := sum_choose / float(PLAYERS * 5)
	print("COST %s: choose_spawn mean %.2f ms worst %.2f ms; respawn_player first %.2f ms, then worst %.2f ms (sites %d)" % [id, mean, worst_choose, first_respawn, worst_respawn, game.player_stack.spawns.sites().size()])
	_check(mean <= BUDGET_MS, "%s: choose_spawn mean under %.0f ms" % [id, BUDGET_MS], "%.2f ms" % mean)
	_check(first_respawn <= FIRST_BUDGET_MS, "%s: first respawn_player under %.0f ms" % [id, FIRST_BUDGET_MS], "first %.2f ms" % first_respawn)
	_check(worst_respawn <= BUDGET_MS * 4.0, "%s: respawn_player worst under %.0f ms" % [id, BUDGET_MS * 4.0], "%.2f ms" % worst_respawn)
	game.queue_free()


## The spawn sight answer (a flat map's native line_of_sight) against the ray() it replaced: every standing player against every site, the same answer.
func _sight_parity(game: FcGame, id: StringName) -> void:
	var stack = game.player_stack
	var trace: GSTrace = game.combat.trace
	var sites: Array[GSSpawnSite] = stack.spawns.sites()
	var eye := Vector3(0, FcPlayer.eye_height(), 0)
	var pairs := 0
	var differ := 0
	var seen := 0
	for player in game.players():
		if not player.is_alive() or player.controller == null:
			continue
		var from: Vector3 = player.controller.state.position
		for site in sites:
			var answer: bool = stack._can_see_site(from, site.position)
			# The answer before the flat trace's line_of_sight: one ray(), clear if it hit nothing or only the last 5 cm.
			var span: Vector3 = (site.position + eye) - (from + eye)
			var by_ray := true
			if span.length() > 0.05:
				var hit := trace.ray(from + eye, span / span.length(), span.length())
				by_ray = not hit.ok() or hit.distance >= span.length() - 0.05
			pairs += 1
			seen += 1 if answer else 0
			differ += 1 if answer != by_ray else 0
	print("PARITY %s: %d pairs, %d seen, %d differ, trace %s" % [id, pairs, seen, differ, trace.get_script().resource_path.get_file()])
	_check(pairs > 0 and differ == 0, "%s: spawn sight matches the per-pair ray() answer" % id, "%d of %d differ" % [differ, pairs])


## The class base is two numbers, not a duplicated tunables object: scales land on the pre-class
## values, a second application does not compound, and an unscaled class puts them back.
func _class_base_parity(player: FcPlayer) -> void:
	var tunables: GSFpsTunables = player.controller.tunables
	var speed := tunables.max_speed
	var jump := tunables.jump_height
	var def := GSPlayerClassDef.new()
	def.move_speed_scale = 0.5
	def.jump_scale = 2.0
	player.apply_class_movement(def)
	player.apply_class_movement(def)
	var scaled := is_equal_approx(tunables.max_speed, speed * 0.5) and is_equal_approx(tunables.jump_height, jump * 2.0)
	player.apply_class_movement(GSPlayerClassDef.new())
	var restored := is_equal_approx(tunables.max_speed, speed) and is_equal_approx(tunables.jump_height, jump)
	_check(scaled and restored, "a class scales movement from its base, without compounding, and back",
		"speed %.3f jump %.3f, scaled %s restored %s" % [speed, jump, scaled, restored])
