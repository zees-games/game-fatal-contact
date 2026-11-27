extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcBotThreads := preload("../game/fc_bot_threads.gd")
const FcBotRows := preload("../game/fc_bot_rows.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcSimServer := preload("../game/fc_sim_server.gd")
const FcBotThinkMt := preload("../game/fc_bot_think_mt.gd")

## `bot_threads`: 24 bots on dm_box play a deathmatch at threads 0, 0 again, 1, 4 and 8 with
## bot_native_think's reused command pair off; every bot's position, view, health and commands,
## hashed every few ticks, are identical in all of them.

const TICK_RATE := 33
const BOTS := 24
const SECONDS := 20.0
const THREADS := [0, 0, 1, 4, 8]

const SECTIONS := 6
const CHECKS := 26

## An imported map, whose sight is the physics space's (dm_box's is analytic) and whose routes come from a baked mesh.
const IMPORTED_MAP := &"dm-morpheus"
const IMPORTED_BOTS := 16
const IMPORTED_SECONDS := 10.0

var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: bot_threads plays the same match")
	# 24 bots and no person would coast on think tiers, leaving fewer thinkers a tick than the pool starts for.
	FcBots.tiers.above = -1
	_section("the same match at every thread count")
	var digests: Array[PackedStringArray] = []
	var kills: Array[int] = []
	var parallel: Array[int] = []
	for count: int in THREADS:
		var played := await _play(count)
		digests.append(played[0])
		kills.append(played[1])
		parallel.append(played[2])
	_check(digests[0].size() > 10 and kills[0] >= 0, "the match was played (%d digests, %d kills)" % [digests[0].size(), kills[0]])
	_check(digests[0] == digests[1], "two runs on one thread are identical (the match is deterministic)")
	for i in range(2, THREADS.size()):
		_check(digests[i] == digests[0], "bot_threads %d plays the match thread 0 plays (%d kills)" % [THREADS[i], kills[i]])
	_check(parallel[2] > 100 and parallel[3] > 100 and parallel[4] > 100, "the brains really ran through the parallel path (%d, %d, %d ticks)" % [parallel[2], parallel[3], parallel[4]])
	_check(parallel[0] == 0, "and bot_threads 0 never did")
	await _switches_play_the_same(digests[0])
	_done()

	_section("bot_native_think_mt: the threaded native perceive plays the script's match")
	await _think_mt_plays_the_same(digests[0])
	_done()

	_section("the brain profile (--brain-us) times brains on bot threads")
	await _brain_phases_threaded(digests[0])
	_done()

	_section("an imported map, sight through the physics space")
	if FcMap.by_id(IMPORTED_MAP) == null:
		print("skip %s: not linked" % IMPORTED_MAP)
		_check(true, "(skipped: no imported map linked)")
		_check(true, "(skipped: no imported map linked)")
	else:
		var off := await _play(0, IMPORTED_MAP)
		var off_again := await _play(0, IMPORTED_MAP)
		var on := await _play(4, IMPORTED_MAP)
		var first_diff := -1
		for i in mini(off[0].size(), on[0].size()):
			if off[0][i] != on[0][i]:
				first_diff = i
				break
		var first_off_diff := -1
		for i in mini(off[0].size(), off_again[0].size()):
			if off[0][i] != off_again[0][i]:
				first_off_diff = i
				break
		var one := await _play(1, IMPORTED_MAP)
		var first_one_diff := -1
		for i in mini(off[0].size(), one[0].size()):
			if off[0][i] != one[0][i]:
				first_one_diff = i
				break
		print("imported: threads 1 vs off first differing window %d" % first_one_diff)
		print("imported: off vs off-again first differing window %d, off vs on %d (of %d)" % [first_off_diff, first_diff, off[0].size()])
		_check(off[0] == off_again[0], "two runs on one thread are identical on %s too" % IMPORTED_MAP)
		_check(off[0] == on[0] and off[0].size() > 5, "bot_threads 4 plays the %s match thread 0 plays (%d, %d kills)" % [IMPORTED_MAP, off[1], on[1]])
		_check(on[2] > 50 and off[2] == 0, "through the parallel path (%d ticks)" % on[2])
	_done()

	_section("under the minimum, or off, nothing changes")
	FcBotThreads.threads = 4
	_check(not FcBotThreads.active(FcBotThreads.MIN_BOTS - 1), "fewer bots than the minimum think on the main thread")
	_check(FcBotThreads.active(FcBotThreads.MIN_BOTS), "the minimum goes parallel")
	FcBotThreads.threads = 0
	_check(not FcBotThreads.active(64), "bot_threads 0 is off at any count")
	_done()

	_section("the live shell's gs-bot 26 path plays the same match")
	await _older_api()
	_done()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## The native switches off play the match they play on: bot_native_think's script contacts, commands and tricks;
## bot_native_pickup's and bot_native_act's script pickup choice and steer.
func _switches_play_the_same(native: PackedStringArray) -> void:
	# bot_native_think 0: gs-bot packs the contacts, new commands every tick, tricks in script; the same match to the digest.
	FcBotRows.set_native_think(false)
	var fresh := await _play(0)
	FcBotRows.set_native_think(true)
	_check(fresh[0] == native, "bot_native_think 0 (script contacts, new commands, script tricks) plays the match its reused pair plays (%d kills)" % fresh[1])
	# bot_native_pickup 0 and bot_native_act 0 (gs-bot 46/47, by name): the pickup choice and the steer in script, on
	# workers; the same match to the digest (an older gs-bot has neither switch and plays it anyway).
	var brain := GSBotBrain as Script
	brain.set(&"native_pickup", false)
	brain.set(&"native_act", false)
	var scripted := await _play(4)
	brain.set(&"native_pickup", true)
	brain.set(&"native_act", true)
	_check(scripted[0] == native, "bot_native_pickup 0 and bot_native_act 0 (script pickup and steer) play the native match (%d kills)" % scripted[1])


## bot_native_think_mt 1 (gs-sim perceives for every threaded bot before the workers start) and 0 play [param script]'s
## match to the digest at 4 threads; the brains took the pass's answers, and never asked it differently.
func _think_mt_plays_the_same(script: PackedStringArray) -> void:
	if not ClassDB.class_exists(FcBotThinkMt.CLASS) or GSAddonApi.build_level("gs_bot") < 53:
		print("skip bot_native_think_mt: gs_sim has no %s or gs-bot is older than 53" % FcBotThinkMt.CLASS)
		for i in 3:
			_check(true, "(skipped: no threaded native perceive)")
		return
	FcBotThinkMt.on = false
	var off := await _play(4)
	FcBotThinkMt.on = true
	var on := await _play(4)
	var hits := 0
	var misses := 0
	for mind: FcBots.Mind in on[3]:
		if mind.brain != null:
			hits += int(mind.brain.get(&"mt_hits"))
			misses += int(mind.brain.get(&"mt_misses"))
	print("bot_native_think_mt: %d answers taken, %d asked differently" % [hits, misses])
	_check(off[0] == script and on[0] == script, "bot_native_think_mt 0 and 1 at 4 threads play thread 0's match (%d, %d kills)" % [off[1], on[1]])
	_check(hits > 1000, "the brains took the threaded pass's answers (%d)" % hits)
	_check(misses == 0, "and never asked a perceive the pass had answered differently (%d)" % misses)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


## One match with [param count] threads: [digests, kills, parallel ticks, the bots' FcBots.Mind].
func _play(count: int, map_id: StringName = &"") -> Array:
	FcBotThreads.threads = count
	FcBotThreads.par_ticks = 0
	var game := FcGame.new()
	game.name = "Arena_%d" % count
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var _setup := game.setup(FcMap.dm_box() if map_id == &"" else FcMap.by_id(map_id))
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0
	var kills := [0]
	game.player_killed.connect(func(_entry: GSKillFeed.Entry) -> void: kills[0] += 1)
	var players: Array = []
	var minds: Array = []
	for i in BOTS if map_id == &"" else IMPORTED_BOTS:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
			var mind := FcBots.Mind.new()
			mind.seed = 100 + i
			minds.append(mind)
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	if map_id != &"":
		# The routes start when the mesh bake lands; start every run from there.
		var world := FcBots.world_for(game)
		var _first := world.route(Vector3.ZERO, Vector3.ONE)
		var frames := 0
		while world.is_route_pending() and frames < 3000:
			await get_tree().process_frame
			frames += 1
		# The navigation server syncs its map a frame or more after the bake lands; a match that starts before
		# warm() is true gets its routes and surf on a load-dependent tick, and no two runs then agree.
		while not world.warm() and frames < 3000:
			await get_tree().process_frame
			frames += 1
	var digests := PackedStringArray()
	var window := PackedStringArray()
	for tick_index in int((SECONDS if map_id == &"" else IMPORTED_SECONDS) * TICK_RATE):
		var tick := game.current_tick()
		var made: Array = []
		if FcBotThreads.active(players.size()):
			made = FcBotThreads.think_all(game, players, minds, tick, float(TICK_RATE))
		else:
			for i in players.size():
				made.append(FcBots.think(game, players[i], minds[i], tick, float(TICK_RATE)))
		var commands := {}
		for i in players.size():
			var pair: Array = made[i]
			var move: GSFpsCommand = pair[0]
			var fire: GSWeaponCommand = pair[1]
			commands[players[i].player_id] = pair
			window.append("%d:%.4f,%.4f,%d,%d" % [i, move.yaw, move.pitch, move.buttons, fire.buttons])
			var state: GSFpsState = players[i].controller.state if players[i].controller != null else null
			if state != null:
				window.append("%.4f,%.4f,%.4f" % [state.position.x, state.position.y, state.position.z])
		game.tick(commands)
		if tick_index % 10 == 9:
			digests.append(" ".join(window).md5_text())
			window.clear()
		# Exactly one physics step every 8 ticks, never "a frame": a frame runs as many steps as the wall clock owes, so a loaded
		# box stepped the dead bots' weapon drops a different number of times and the space's queries with them; off vs off and
		# off vs on then differed on dm-morpheus about 1 run in 6 on PH (headless_motor_batch had the same, ecaa619).
		if tick_index % 8 == 0:
			await get_tree().physics_frame
	var parallel := FcBotThreads.par_ticks
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	FcBotThreads.threads = 0
	return [digests, kills[0], parallel, minds]


## Think and body tiers on (every bot coasts when nobody sees it), played on the current addons' calls, then on the
## calls a gs-bot 26 host has (the floor in requires.floor.json): the same digests.
func _older_api() -> void:
	var tiers := FcBots.tiers
	var was := [tiers.above, tiers.body_above, FcBots.tier_schedule]
	tiers.above = 0
	tiers.body_above = 0
	var current_bot := GSAddonApi.build_level("gs_bot") >= 27
	var body_before := _sum(tiers.body_counts)
	FcBots.tier_schedule = current_bot
	var now := await _play(0)
	var body_now := _sum(tiers.body_counts) - body_before
	FcBots.tier_schedule = false
	var old := await _play(0)
	var body_old := _sum(tiers.body_counts) - body_before - body_now
	tiers.above = was[0]
	tiers.body_above = was[1]
	FcBots.tier_schedule = was[2]
	print("gs-bot %d: body tier answers above 1 %d current, %d older path" % [GSAddonApi.build_level("gs_bot"), body_now, body_old])
	_check(body_now > 0 and body_old > 0, "bots coasted on body tiers both ways (%d, %d)" % [body_now, body_old])
	_check(now[0].size() > 10 and now[0] == old[0], "gs-bot 26's period/until_beat/body_period play the match schedule plays (%d kills, %d)" % [now[1], old[1]])
	_check(current_bot == FcBots.tier_schedule, "the guard follows the build's gs-bot level (%d)" % GSAddonApi.build_level("gs_bot"))
	var phases := FcBots.brain_phases
	FcBots.brain_phases = false
	var line_old := FcSimServer.phases_line(1)
	FcBots.brain_phases = phases
	var line_now := FcSimServer.phases_line(1)
	_check(line_old.begins_with("SIM_HOST_PHASES") and not line_old.contains("bb_"), "the sim host's phase line leaves out the brain on gs-bot 26: " + line_old)
	_check(line_now.contains("bb_setup") == (GSAddonApi.build_level("gs_bot") >= 29), "and has the brain's phases from gs-bot 29: " + line_now)


## The tier's answers above 1 so far, the native tier's included (flushed by name: not every gs-bot level has it).
static func _sum(counts: Dictionary) -> int:
	if FcBots.tiers.has_method(&"_flush"):
		FcBots.tiers.call(&"_flush")
	var total := 0
	for k: Variant in counts:
		total += int(counts[k])
	return total


## gs-bot 40: with bot_threads 4 the brains' phases (bb_*) and world queries (bq_*) are timed on the workers and
## merged after the join, where they read 0 before; and timing changes nothing the bots do. By name: older gs-bot has neither.
func _brain_phases_threaded(match_digests: PackedStringArray) -> void:
	if not FcBots.brain_merge:
		for i in 3:
			_check(true, "(skipped: gs-bot %d has no threaded brain timers)" % GSAddonApi.build_level("gs_bot"))
		return
	var brain: GDScript = GSBotBrain
	var us: PackedInt64Array = brain.get(&"phase_us")
	var calls: PackedInt64Array = brain.get(&"phase_calls")
	us.fill(0)
	calls.fill(0)
	brain.set(&"phase_us", us)
	brain.set(&"phase_calls", calls)
	brain.set(&"phase_timers", true)
	var played := await _play(4)
	brain.set(&"phase_timers", false)
	var names: Array = brain.get(&"PHASES")
	us = brain.get(&"phase_us")
	calls = brain.get(&"phase_calls")
	var bb := 0
	var bq := 0
	for i in names.size():
		if String(names[i]).begins_with("bb_"):
			bb += us[i]
		else:
			bq += calls[i]
	var thinks := calls[0]
	us.fill(0)
	calls.fill(0)
	brain.set(&"phase_us", us)
	brain.set(&"phase_calls", calls)
	_check(played[2] > 100, "the profiled match ran through the parallel path (%d ticks)" % played[2])
	_check(bb > 0 and thinks > 0, "its brain phases are non-zero (%d us over %d thinks)" % [bb, thinks])
	_check(bq > 0 and played[0] == match_digests, "its world queries were counted (%d), and the timed match is the untimed one" % bq)
