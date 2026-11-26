extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcBotThreads := preload("../game/fc_bot_threads.gd")
const FcBotRows := preload("../game/fc_bot_rows.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcSimServer := preload("../game/fc_sim_server.gd")
const FcBotContacts := preload("../game/fc_bot_contacts.gd")

## `bot_threads`: the bots' brains on worker threads play exactly what they play on one. The same
## 24 bots on dm_box play a deathmatch at threads 0, 0 again, 1, 4 and 8; every bot's position,
## view, health and commands, hashed every few ticks, are identical in all of them, and with bot_native_think's
## reused command pair off (new commands every tick).

const TICK_RATE := 33
const BOTS := 24
const SECONDS := 20.0
const THREADS := [0, 0, 1, 4, 8]

const SECTIONS := 6
const CHECKS := 27

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
	# bot_native_think 0: gs-bot packs the contacts, new commands every tick, tricks in script; the same match to the digest.
	FcBotRows.set_native_think(false)
	var fresh := await _play(0)
	FcBotRows.set_native_think(true)
	_check(fresh[0] == digests[0], "bot_native_think 0 (script contacts, new commands, script tricks) plays the match its reused pair plays (%d kills)" % fresh[1])
	_done()

	_section("bot_native_contacts: gs-sim builds the script's contacts")
	await _contacts_parity(digests[0])
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


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


## One match with [param count] threads: [digests, kills, parallel ticks].
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
	return [digests, kills[0], parallel]


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
		for i in 5:
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
	var built := FcBotContacts.built
	var tabled := [0, 0]
	var table_first := -1
	var has_table := false
	for round_index in rounds:
		var held: Variant = _scramble(players, rng, round_index == rounds - 1)
		FcBotContacts.table = false
		FcBotContacts.enabled = false
		world.refresh(1000 + 3 * round_index, float(TICK_RATE))
		var script := _snapshot(world)
		var packed := GSBotContactTable.from_contacts(0, world.get(&"_contacts")).digest()
		FcBotContacts.enabled = true
		world.refresh(1001 + 3 * round_index, float(TICK_RATE))
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
	built = FcBotContacts.built - built
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
	if not bare:
		return null
	var held: Variant = players[0].get(&"controller")
	players[0].set(&"controller", null)
	(players[0] as Node3D).global_position = Vector3(1.5 + 1e-7, -2.25, 3.0)
	return held


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
