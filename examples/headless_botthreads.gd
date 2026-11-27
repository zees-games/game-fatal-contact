extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcBotThreads := preload("../game/fc_bot_threads.gd")
const FcBotRows := preload("../game/fc_bot_rows.gd")
const FcBotCoast := preload("../game/fc_bot_coast.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcSimServer := preload("../game/fc_sim_server.gd")
const FcBotContacts := preload("../game/fc_bot_contacts.gd")
const FcBotThinkMt := preload("../game/fc_bot_think_mt.gd")

## `bot_threads`: 24 bots on dm_box play a deathmatch at threads 0, 0 again, 1, 4 and 8 with
## bot_native_think's reused command pair off; every bot's position, view, health and commands,
## hashed every few ticks, are identical in all of them.

const TICK_RATE := 33
const BOTS := 24
const SECONDS := 20.0
const THREADS := [0, 0, 1, 4, 8]

const SECTIONS := 8
const CHECKS := 48

## `bot_native_refresh`'s parity: seeded matches of this many bots, this long, on these maps, script against gs-sim.
const REFRESH_BOTS := 31
const REFRESH_SECONDS := 10.0
const REFRESH_MAPS: Array[StringName] = [&"dm_box", &"dm_pit", &"cp-orange-x3"]

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

	_section("bot_native_contacts: gs-sim builds the script's contacts")
	await _contacts_parity(digests[0])
	_section("bot_native_think_mt: the threaded native perceive plays the script's match")
	await _think_mt_plays_the_same(digests[0])
	_done()

	_section("bot_native_refresh: gs-sim's refresh (contacts, hearing) plays the script's 31-bot matches")
	await _refresh_parity()
	_done()

	_section("the brain profile (--brain-us) times brains on bot threads")
	await _brain_phases_threaded(digests[0])
	_done()

	_section("an imported map, sight through the physics space")
	await _imported_map()
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


## [constant IMPORTED_MAP] played at threads 0 twice, 4 and 1: the same digests, through the parallel path.
func _imported_map() -> void:
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


## The native switches off play the match they play on: bot_native_think's script contacts, commands and tricks;
## bot_native_pickup's, bot_native_act's, bot_native_drops's and bot_native_unstick's script pickup choice, steer, drop table and stuck watch.
func _switches_play_the_same(native: PackedStringArray) -> void:
	# bot_native_think 0: gs-bot packs the contacts, new commands every tick, tricks in script; the same match to the digest.
	FcBotRows.set_native_think(false)
	var fresh := await _play(0)
	FcBotRows.set_native_think(true)
	_check(fresh[0] == native, "bot_native_think 0 (script contacts, new commands, script tricks) plays the match its reused pair plays (%d kills)" % fresh[1])
	# bot_native_pickup 0, bot_native_act 0, bot_native_drops 0 and bot_native_unstick 0 (gs-bot 46/47/49/50, by name): the pickup choice, the
	# steer, the drop table and the stuck watch in script, on
	# workers; the same match to the digest (an older gs-bot has neither switch and plays it anyway).
	var brain := GSBotBrain as Script
	brain.set(&"native_pickup", false)
	brain.set(&"native_act", false)
	(GSBotWorld as Script).set(&"native_drops", false)
	(GSBotUnstick as Script).set(&"native_enabled", false)
	var scripted := await _play(4)
	brain.set(&"native_pickup", true)
	brain.set(&"native_act", true)
	(GSBotWorld as Script).set(&"native_drops", true)
	(GSBotUnstick as Script).set(&"native_enabled", true)
	_check(scripted[0] == native, "bot_native_pickup 0, bot_native_act 0, bot_native_drops 0 and bot_native_unstick 0 (script pickup, steer, drop table and stuck watch) play the native match (%d kills)" % scripted[1])
	# bot_coast_native: with think tiers on (every bot nobody sees coasts) the threaded runs work their coasting bots
	# in one gs-sim call a tick; 0 works them in script one by one, and plays the same match to the digest.
	var has_coast := FcBotCoast.native() != null
	var tiers := FcBots.tiers
	var was_above: int = tiers.above
	tiers.above = 0
	var before := FcBotCoast.batched
	var tiered := await _play(4)
	var batched := FcBotCoast.batched - before
	FcBotCoast.enabled = false
	var coasted := await _play(4)
	FcBotCoast.enabled = true
	tiers.above = was_above
	_check(not has_coast or batched > 0, "with gs-sim's bot_coast the coasting bots went through it (%d bot ticks, module %s)" % [batched, has_coast])
	_check(tiered[0].size() > 10 and coasted[0] == tiered[0] and FcBotCoast.batched == before + batched, "bot_coast_native 0 (script coast, one bot at a time) plays the tiered match the native coast plays (%d kills, %d)" % [coasted[1], tiered[1]])
	_coast_matches_script()


## gs-sim's GSSimBotCoast works the coasting views and recoil previews [method FcBots._coast] and
## [method FcBots.recoil_preview] work, to the bit, over random views, think rates and recoil states.
func _coast_matches_script() -> void:
	var coast := FcBotCoast.native()
	if coast == null:
		_check(true, "no gs-sim bot_coast module: only the script coast runs (bit comparison skipped)")
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var views := PackedFloat32Array()
	var steps := PackedInt64Array()
	var recoil := PackedFloat64Array()
	var want := PackedFloat64Array()
	var tick := 50000
	var mind := FcBots.Mind.new()
	mind.last_move = GSFpsCommand.new()
	mind.last_fire = GSWeaponCommand.new()
	for k in 400:
		mind.view_from = Vector2(rng.randf_range(-900.0, 900.0), rng.randf_range(-89.0, 89.0))
		mind.view_to = Vector2(rng.randf_range(-900.0, 900.0), rng.randf_range(-89.0, 89.0)) if k % 7 != 0 else mind.view_from
		mind.every = rng.randi_range(1, 6)
		mind.last_think_tick = tick - rng.randi_range(0, mind.every - 1)
		views.append_array([mind.view_from.x, mind.view_from.y, mind.view_to.x, mind.view_to.y])
		steps.append_array([tick - mind.last_think_tick, mind.every])
		var pair := FcBots._coast(mind, tick)
		want.append((pair[0] as GSFpsCommand).yaw)
		want.append((pair[0] as GSFpsCommand).pitch)
	for k in 400:
		var row := PackedFloat64Array([rng.randf_range(0.05, 1.0), rng.randf_range(0.0, 12.0), rng.randf_range(0.0, 2.0),
			rng.randf_range(0.0, 0.3), rng.randf_range(0.0, 2.0), rng.randf_range(0.0, 2.0), rng.randf_range(0.0, 3.0),
			rng.randf_range(0.0, 2.0), rng.randf_range(-2.0, 2.0), rng.randf_range(0.0, 2.0), rng.randf_range(0.0, 1.0),
			rng.randf_range(0.0, 1.0), rng.randi() & 0x7fffffff, tick - rng.randi_range(0, 60) if k % 9 != 0 else -1000000,
			rng.randi_range(0, 30), rng.randf_range(-4.0, 4.0), rng.randf_range(-4.0, 4.0), rng.randf_range(0.0, 1.0)])
		recoil.append_array(row)
		var offset := FcBots.recoil_preview(row, tick, float(TICK_RATE))
		want.append(offset.x)
		want.append(offset.y)
	var got: PackedFloat64Array = coast.call(&"step", views, steps, recoil, tick, float(TICK_RATE))
	var first := -1
	for i in mini(got.size(), want.size()):
		if var_to_bytes(got[i]) != var_to_bytes(want[i]):
			first = i
			break
	_check(got.size() == want.size() and first < 0, "GSSimBotCoast gives the script's 400 coasting views and 400 recoil previews to the bit (%d values, first difference at %d%s)" % [got.size(), first, "" if first < 0 else ": %s vs %s" % [got[first], want[first]]])


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


## `bot_native_refresh` 0 and 1 play the same seeded 31-bot match at 4 threads on each of [constant REFRESH_MAPS]: the contact
## table hashed every tick, the command and position digests, the kills and every player's score, all identical; and the
## native run really built its contacts in gs-sim while the script run never did. An imported map not linked is skipped.
func _refresh_parity() -> void:
	var available := FcBotContacts.refresh_available()
	for map_id: StringName in REFRESH_MAPS:
		if not available or (map_id != &"dm_box" and FcMap.by_id(map_id) == null):
			print("skip %s: %s" % [map_id, "not linked" if available else "this gs-sim has no native refresh"])
			for i in 3:
				_check(true, "(skipped: %s)" % map_id)
			continue
		var built := [0, 0]
		var runs: Array = []
		for on: bool in [false, true]:
			FcBotContacts.set_native_refresh(on)
			var before := FcBotContacts.built
			runs.append(await _play(4, &"" if map_id == &"dm_box" else map_id, REFRESH_BOTS, REFRESH_SECONDS, true))
			built[int(on)] = FcBotContacts.built - before
		FcBotContacts.set_native_refresh(true)
		var script: Array = runs[0]
		var native: Array = runs[1]
		var first := -1
		for i in mini(script[4].size(), native[4].size()):
			if script[4][i] != native[4][i]:
				first = i
				break
		print("%s refresh: first differing tick %d of %d; kills %d / %d; scores %s / %s; digests %s" % [map_id, first, script[4].size(), script[1], native[1], script[5], native[5], script[0] == native[0]])
		if first >= 0 and first < mini(script[6].size(), native[6].size()):
			print("  %s" % _table_diff(script[6][first], native[6][first]))
		_check(script[4] == native[4] and script[4].size() >= int(REFRESH_SECONDS * TICK_RATE) and script[0] == native[0],
			"%s: the contact table hashes the same on every one of %d ticks, and the match digests the same" % [map_id, script[4].size()])
		_check(script[1] == native[1] and script[5] == native[5], "%s: the same kills (%d) and every player's score (%s)" % [map_id, native[1], native[5]])
		_check(built[0] == 0 and built[1] >= int(REFRESH_SECONDS * TICK_RATE), "%s: gs-sim built the contacts of %d ticks, the script run of none (%d)" % [map_id, built[1], built[0]])


## Waits until [param world]'s routes are baked and its navigation map synced (an imported map).
func _routes_warm(world: FcBots.World) -> void:
	# The routes start when the mesh bake lands; start every run from there.
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


## Every one of [param players]' score on [param game]'s scoreboard (-1 for one it has no record of).
static func _scores(game: Node, players: Array) -> PackedInt32Array:
	var scores := PackedInt32Array()
	for p: Variant in players:
		var record: GSPlayerScore = game.get(&"match_node").scoreboard.find(str(p.player_id))
		scores.append(record.score if record != null else -1)
	return scores


## The hash of [param world]'s contacts this tick: gs-sim's table when it filled one, else the contact objects packed as one.
static func _table_hash(world: Object) -> int:
	return _table_of(world).digest()


static func _table_of(world: Object) -> GSBotContactTable:
	var t: GSBotContactTable = world.call(&"table")
	return t if t != null else GSBotContactTable.from_contacts(0, world.get(&"_contacts"))


const TABLE_COLUMNS: Array[String] = ["ids", "positions", "velocities", "floats", "teams", "flags", "points", "eyes", "alive"]


static func _table_copy(t: GSBotContactTable) -> GSBotContactTable:
	var copy := GSBotContactTable.new()
	for column in TABLE_COLUMNS:
		copy.set(column, t.get(column).duplicate())
	return copy


## The columns [method GSBotContactTable.digest] hashes, by name, where [param a] and [param b] first differ.
static func _table_diff(a: GSBotContactTable, b: GSBotContactTable) -> String:
	var out := PackedStringArray()
	for column in TABLE_COLUMNS:
		var x: Variant = a.get(column)
		var y: Variant = b.get(column)
		if x != y:
			out.append("%s %s / %s" % [column, str(x).left(400), str(y).left(400)])
	return "; ".join(out)


## [param world]'s contact table at [param tick], refreshed and hashed before any brain writes its own contact object (the
## script's objects are kept from tick to tick): its digest onto [param tables], a copy of the first 60 onto [param firsts].
static func _hash_tick(world: FcBots.World, tick: int, tables: PackedInt64Array, firsts: Array) -> void:
	world.refresh(tick, float(TICK_RATE))
	var t := _table_of(world)
	tables.append(t.digest())
	if firsts.size() < 60:
		firsts.append(_table_copy(t))


## One match with [param count] threads: [digests, kills, parallel ticks, the bots' FcBots.Mind, the contact table's hash every
## tick (with [param hashes]), every player's score]. [param bots] and [param seconds] default to the map kind's.
func _play(count: int, map_id: StringName = &"", bots: int = 0, seconds: float = 0.0, hashes: bool = false) -> Array:
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
	var players: Array[FcPlayer] = []
	var minds: Array[FcBots.Mind] = []
	if bots <= 0:
		bots = BOTS if map_id == &"" else IMPORTED_BOTS
	if seconds <= 0.0:
		seconds = SECONDS if map_id == &"" else IMPORTED_SECONDS
	for i in bots:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
			var mind := FcBots.Mind.new()
			mind.seed = 100 + i
			minds.append(mind)
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var world := FcBots.world_for(game)
	if map_id != &"":
		await _routes_warm(world)
	var digests := PackedStringArray()
	var window := PackedStringArray()
	var tables := PackedInt64Array()
	var firsts: Array = []
	for tick_index in int(seconds * TICK_RATE):
		var tick := game.current_tick()
		if hashes:
			_hash_tick(world, tick, tables, firsts)
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
	var scores := _scores(game, players)
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	FcBotThreads.threads = 0
	return [digests, kills[0], parallel, minds, tables, scores, firsts]


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


## `bot_native_contacts`: gs-sim's contact build writes every contact field and sight row the script loop writes, to the bit, over
## randomized player states (fractions no 32-bit float holds, both zeros, fractional and NaN modes, no max health, one player
## without a controller), and the script loop plays the match gs-sim's contacts played.
func _contacts_parity(expected: PackedStringArray) -> void:
	if not GSSim.has(&"contacts"):
		print("skip: this gs-sim has no contact build")
		for i in 7:
			_check(true, "(skipped: no gs-sim contact build)")
		return
	var players: Array = []
	var game := await _contacts_game(players)
	var world := FcBots.world_for(game)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var rounds := 40
	var same := [0, 0]
	var first := -1
	var built := 0  # the object rounds' gs-sim builds; the table round's fill counts too and is left out
	var tabled := [0, 0]
	var table_first := -1
	var has_table := false
	var armed := 0
	for round_index in rounds:
		var held: Variant = _scramble(players, rng, round_index == rounds - 1)
		FcBotContacts.table = false
		FcBotContacts.enabled = false
		world.refresh(1000 + 3 * round_index, float(TICK_RATE))
		var script := _snapshot(world)
		var packed := GSBotContactTable.from_contacts(0, world.get(&"_contacts")).digest()
		FcBotContacts.enabled = true
		var built_before := FcBotContacts.built
		var armed_before := FcBotContacts.armed
		world.refresh(1001 + 3 * round_index, float(TICK_RATE))
		built += FcBotContacts.built - built_before
		armed += FcBotContacts.armed - armed_before
		var native := _snapshot(world)
		var row := _table_round(world, 1002 + 3 * round_index, packed, script[0])
		has_table = row >= 0
		if has_table and row & 1:
			tabled[0] += 1
		elif has_table and table_first < 0:
			table_first = round_index
		if has_table and row & 2:
			tabled[1] += 1
		if held != null:
			players[0].controller = held
		for k in 2:
			if script[k] == native[k]:
				same[k] += 1
			elif first < 0:
				first = round_index
	var native_contacts: Object = world.get(&"_native_contacts")
	var delta_rounds := 30
	FcBotContacts.table = false
	var delta_same := _delta_rounds(world, players, rng, delta_rounds)
	FcBotContacts.table = true
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	print("contacts: first differing round %d" % first)
	_check(same[0] == rounds and built == rounds, "every contact field equals the script's to the bit in %d of %d randomized rounds (%d built in gs-sim)" % [same[0], rounds, built])
	_check(same[1] == rounds, "and the sight rows handed to the native scan, in %d of %d" % [same[1], rounds])
	FcBotContacts.enabled = false
	var played := await _play(0)
	FcBotContacts.enabled = true
	_check(played[0] == expected, "bot_native_contacts 0 (the script loop) plays the match gs-sim's contacts play (%d kills)" % played[1])
	_check(bool(native_contacts.get(&"_has_delta")) and delta_same == delta_rounds,
		"bot_native_contacts_delta: writing only changed kept fields leaves every field and row of a full write in %d of %d rounds" % [delta_same, delta_rounds])
	FcBotContacts.delta = false
	FcBotContacts.table = false
	played = await _play(0)
	FcBotContacts.delta = true
	_check(played[0] == expected, "bot_native_contacts_delta 0 (every field every tick) plays the same match (%d kills)" % played[1])
	await _table_checks(expected, tabled, rounds, table_first, has_table)
	await _arms_checks(expected, native_contacts, armed, rounds)


## `bot_native_contact_arms`: gs-sim wrote the weapons in hand of every object round (the rounds above compare them with the
## script's, to the bit, over random slots, rounds and no weapon), and the match plays the same with it off.
func _arms_checks(expected: PackedStringArray, native_contacts: Object, armed: int, rounds: int) -> void:
	if not bool(native_contacts.get(&"_has_arms")):
		print("skip: this gs-sim has no fill_arms")
		for i in 2:
			_check(true, "(skipped: no gs-sim fill_arms)")
		return
	_check(armed == rounds, "bot_native_contact_arms: gs-sim wrote the weapon in hand (interned class, magazine) in %d of %d randomized rounds" % [armed, rounds])
	FcBotContacts.arms = false
	var played: Array = await _play(0)
	FcBotContacts.arms = true
	_check(played[0] == expected, "bot_native_contact_arms 0 (one script call per player) plays the same match (%d kills)" % played[1])

## The match [method _contacts_parity] refreshes, started and ticked once; its players appended to [param players].
func _contacts_game(players: Array) -> FcGame:
	FcBotThreads.threads = 0
	var game := FcGame.new()
	game.name = "Contacts"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var _setup := game.setup(FcMap.dm_box())
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	for i in BOTS:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	return game


## `bot_contact_table`: one refresh at [param tick] with gs-sim filling the columns. -1 without a table; else bit 1 when they
## digest as the script's contacts pack ([param packed]), bit 2 when every view read from them is the script's ([param script]).
func _table_round(world: Object, tick: int, packed: int, script: Variant) -> int:
	FcBotContacts.table = true
	world.refresh(tick, float(TICK_RATE))
	var t: GSBotContactTable = world.call(&"table")
	if t == null:
		return -1
	var _all: Array = world.call(&"contacts")
	return (1 if t.digest() == packed else 0) | (2 if _snapshot(world)[0] == script else 0)


## The `bot_contact_table` checks of [method _contacts_parity]'s rounds, and the match with it off.
func _table_checks(expected: PackedStringArray, tabled: Array, rounds: int, table_first: int, has_table: bool) -> void:
	print("contact table: first differing round %d" % table_first)
	if not has_table:
		print("skip: this gs-sim has no fill_table")
		for i in 3:
			_check(true, "(skipped: no gs-sim contact table)")
		FcBotContacts.table = true
		return
	_check(tabled[0] == rounds, "bot_contact_table: gs-sim's columns digest as the script's contacts pack in %d of %d randomized rounds" % [tabled[0], rounds])
	_check(tabled[1] == rounds, "and every view read from them equals the script's contact field for field, in %d of %d" % [tabled[1], rounds])
	var tabled_before := FcBotContacts.tabled
	var played: Array = await _play(0)
	FcBotContacts.table = true
	_check(played[0] == expected and FcBotContacts.tabled == tabled_before,
		"bot_contact_table 0 (the objects) plays the match the table plays (%d kills)" % played[1])


## `bot_native_contacts_delta`: the kept fields written only when they change. Each round builds with it on (against what the
## last native build wrote, or after a script tick), then again with it off on the same states. Returns the rounds whose
## contacts and sight rows came out the same.
func _delta_rounds(world: Object, players: Array, rng: RandomNumberGenerator, rounds: int) -> int:
	var same := 0
	for round_index in rounds:
		if round_index % 3 != 2:
			_scramble(players, rng, false)
		FcBotContacts.enabled = round_index % 5 != 4
		world.refresh(2000 + 3 * round_index, float(TICK_RATE))
		FcBotContacts.enabled = true
		if round_index % 2 == 0:
			_scramble(players, rng, false)
		world.refresh(2001 + 3 * round_index, float(TICK_RATE))
		var changed: Array = _snapshot(world)
		FcBotContacts.delta = false
		world.refresh(2002 + 3 * round_index, float(TICK_RATE))
		FcBotContacts.delta = true
		if changed == _snapshot(world):
			same += 1
	return same


## Gives every player a random state; with [param bare], takes player 0's controller away. Returns that controller, to put back, or null.
func _scramble(players: Array, rng: RandomNumberGenerator, bare: bool) -> Variant:
	var modes := [0.0, -0.0, 0.5, -0.5, 1.0, 2.0, 3.0, NAN]
	var times := [-1.0, -0.0, 0.0, 0.25, -0.25]
	for p: Object in players:
		var state: GSFpsState = p.get(&"controller").state
		var f := state.columns()
		for k in 3:
			f[k] = rng.randf_range(-500.0, 500.0) + rng.randf() * 1e-7
			f[3 + k] = rng.randf_range(-20.0, 20.0) + rng.randf() * 1e-7
		f[9] = modes[rng.randi() % modes.size()]
		f[12] = rng.randf_range(-720.0, 720.0) + rng.randf() * 1e-7
		f[17] = times[rng.randi() % times.size()]
		f[19] = times[rng.randi() % times.size()]
		f[22] = times[rng.randi() % times.size()]
		state.set(&"_f", f)
		state.pitch = rng.randf_range(-89.0, 89.0) + rng.randf() * 1e-7
		var health: GSHealth = p.get(&"health")
		if health != null:
			health.health = rng.randf_range(-10.0, 120.0) + rng.randf() * 1e-7
			health.max_health = 0.0 if rng.randi() % 8 == 0 else 100.0
			health.alive = rng.randi() % 4 != 0
		_scramble_arms(p.get(&"arsenal"), rng)
	if not bare:
		return null
	var held: Variant = players[0].get(&"controller")
	players[0].set(&"controller", null)
	(players[0] as Node3D).global_position = Vector3(1.5 + 1e-7, -2.25, 3.0)
	return held


## Puts a random slot of [param arsenal] in hand (one in six: a slot with nothing in it) with a random number of rounds.
func _scramble_arms(arsenal: Object, rng: RandomNumberGenerator) -> void:
	if arsenal == null:
		return
	var slots: Array = (arsenal.get(&"_slots") as Dictionary).keys()
	if slots.is_empty() or rng.randi() % 6 == 0:
		arsenal.set(&"_current", 99)
		return
	arsenal.set(&"_current", slots[rng.randi() % slots.size()])
	var slot: GSWeaponSlot = arsenal.call(&"current")
	if slot != null and slot.def != null:
		slot.magazine = rng.randi_range(0, maxi(slot.def.magazine, 1))


## [param world]'s contacts, every field, and its sight row table, as bytes.
func _snapshot(world: Object) -> Array:
	var fields := PackedByteArray()
	for c: GSBotContact in world.get(&"_contacts"):
		fields.append_array(var_to_bytes([c.id, c.eye_height, c.aim_height, c.alive, c.team, c.position, c.velocity, c.view_yaw,
				c.view_pitch, c.grounded, c.sliding, c.wall_running, c.air_jump_ready, c.health, c.loadout,
				c.get(&"weapon_class"), c.get(&"magazine")]))
	var rows: Object = world.get(&"_bot_rows")
	var table := PackedByteArray()
	for key: StringName in [&"_ids", &"_points", &"_teams", &"_alive", &"_eyes", &"_positions"]:
		table.append_array(var_to_bytes(rows.get(key)))
	for c: Object in rows.get(&"_sensed"):
		table.append_array(var_to_bytes(c.get_instance_id()))
	return [fields, table]
