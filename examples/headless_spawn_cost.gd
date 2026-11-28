extends GSGameCheckSuite

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcSpawnPick := preload("../game/fc_spawn_pick.gd")

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
		maps = [&"crackhouse", &"dm-overwatch", &"box"]
	var ran := 0
	for id in maps:
		if FcMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			continue
		await _one(id)
		ran += 1
	var native_checks := _pick_parity()
	_report_sections(maps.size(), ran, maps.size(), ran * 5 + (1 if ran > 0 else 0) + native_checks)


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
	_batched_sight_parity(game, id)
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


## The batched spawn sight (every enemy's ray to a site in one native call) against `_traced_sight` pair by pair.
func _batched_sight_parity(game: FcGame, id: StringName) -> void:
	var stack = game.player_stack
	var froms: Array[Vector3] = []
	for player in game.players():
		if player.is_alive() and player.controller != null:
			froms.append(player.controller.state.position)
	var pairs := 0
	var differ := 0
	for site: GSSpawnSite in stack.spawns.sites():
		var batched: PackedByteArray = stack._traced_sights(froms, site.position)
		for k in froms.size():
			pairs += 1
			differ += 1 if (batched[k] != 0) != bool(stack._traced_sight(froms[k], site.position)) else 0
	print("BATCHED %s: %d pairs, %d differ" % [id, pairs, differ])
	_check(pairs > 0 and differ == 0, "%s: batched spawn sight matches the pair-by-pair trace" % id, "%d of %d differ" % [differ, pairs])


## `fc_spawn_native`'s pick against gs-spawn's `pick_scatter` on a seeded set: the same site from the same rng, and the rng
## left in the same state. The script weights always; gs-sim's kernel (and its occupancy) when the library has it.
## Returns how many checks it made.
func _pick_parity() -> int:
	var arms: Array[bool] = [false]
	if FcSpawnPick.has_kernel():
		arms.append(true)
	else:
		print("PICK: no GSSimSpawnPick in this gs-sim; the kernel arm and occupancy wait for a release")
	var can_see := func(a: Vector3, b: Vector3) -> bool: return posmod(int(floor(a.x * 0.37 + b.z * 0.53 + a.z * 0.11)), 3) == 0
	var seen_any := func(at: Vector3, enemies: Array) -> bool: return GSSpawnScoring.seen_by_any(at, enemies, can_see)
	for kernel in arms:
		var gen := RandomNumberGenerator.new()
		gen.seed = 20261126
		var trials := 400
		var differ := 0
		var nulls := 0
		for t in trials:
			var rules := GSSpawnRules.new()
			rules.scatter_min_gap = [0.0, 2.0, 6.0][gen.randi() % 3]
			rules.scatter_radius = [0.0, 25.0, 60.0][gen.randi() % 3]
			rules.scatter_enemy_radius = [0.0, 15.0, 40.0][gen.randi() % 3]
			rules.scatter_seen_factor = [0.05, 0.5, 1.0][gen.randi() % 3]
			var pool: Array[GSSpawnSite] = []
			for i in 1 + gen.randi() % 24:
				var site := GSSpawnSite.new()
				site.position = Vector3(gen.randf_range(-60, 60), gen.randf_range(0, 8), gen.randf_range(-60, 60))
				site.weight = [-1.0, 0.0, 0.5, 1.0, 2.0, 1.0][gen.randi() % 6]
				pool.append(site)
			var enemies: Array = []
			for i in gen.randi() % 9:
				enemies.append(Vector3(gen.randf_range(-60, 60), gen.randf_range(0, 8), gen.randf_range(-60, 60)))
			var recent: Array[Vector3] = []
			for i in gen.randi() % 13:
				recent.append(Vector3(gen.randf_range(-60, 60), 0, gen.randf_range(-60, 60)))
			var context := {"enemies": enemies, "can_see": can_see}
			var a := RandomNumberGenerator.new()
			var b := RandomNumberGenerator.new()
			a.seed = gen.randi()
			b.seed = a.seed
			var want := GSSpawnScoring.pick_scatter(rules, recent, pool, context, a)
			var got := FcSpawnPick.pick(rules, recent, pool, context, b, seen_any, kernel)
			nulls += 1 if want == null else 0
			differ += 1 if want != got or a.state != b.state else 0
		var arm := "gs-sim kernel" if kernel else "script weights"
		print("PICK %s: %d trials, %d differ, %d with no weight" % [arm, trials, differ, nulls])
		_check(differ == 0, "fc_spawn_native's pick (%s) matches gs-spawn's scatter" % arm, "%d of %d differ" % [differ, trials])
	if not FcSpawnPick.has_kernel():
		return 1
	var og := RandomNumberGenerator.new()
	og.seed = 7
	var sites := PackedVector3Array()
	var standing := PackedVector3Array()
	for i in 40:
		sites.append(Vector3(og.randf_range(-20, 20), 0, og.randf_range(-20, 20)))
	for i in 32:
		standing.append(Vector3(og.randf_range(-20, 20), 0, og.randf_range(-20, 20)))
	var counts := FcSpawnPick.occupancy(sites, standing, 3.0)
	var odiffer := 0 if counts.size() == sites.size() else 1
	for i in mini(counts.size(), sites.size()):
		var n := 0
		for p in standing:
			n += 1 if sites[i].distance_to(p) <= 3.0 else 0
		odiffer += 1 if n != counts[i] else 0
	_check(odiffer == 0, "gs-sim's occupancy matches the script's count", "%d of %d differ" % [odiffer, sites.size()])
	return 3


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
