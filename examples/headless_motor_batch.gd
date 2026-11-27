extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcGame := preload("../game/fc_game.gd")
const FcHullGrid := preload("../game/fc_hull_grid.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcModTools := preload("../game/fc_mod_tools.gd")

## `fc_motor_batch`: the players' motors ticked in runs of one gs-sim call play exactly the
## match the loop one player after another plays. A recorded bot match is replayed through both
## loops and every player's state, hashed every few ticks, is identical, on box, pit, imported and surf maps.

const TICK_RATE := 33
const BOTS := 24
const SECONDS := 15.0
const SMALL_BOTS := 16
const SMALL_SECONDS := 8.0
const IMPORTED_MAPS: Array[StringName] = [&"dm-morpheus", &"surf_ski_2"]

## A player is changed every this many ticks, each of these ways in turn.
const MEDDLE_EVERY := 5
const MEDDLES: Array[StringName] = [&"slay", &"slap", &"push"]
const PUSH := Vector3(3.0, 6.0, -2.0)

const SECTIONS := 6
const CHECKS := 33


## Kills, slaps and pushes players: between two ticks as the admin tools do, or in the place of the demo's statistics,
## which the loop calls after each player's turn, to a player whose turn that tick is over or still to come.
class Meddler extends RefCounted:
	var game: FcGame = null
	## &"between", &"earlier" or &"later".
	var where: StringName = &""
	var done := 0

	func process(_delta: float) -> void:
		pass

	func release() -> void:
		pass

	func between(tick: int) -> void:
		if where != &"between" or tick % MEDDLE_EVERY != 0:
			return
		var ids: Array[int] = game.player_ids()
		var turn := tick / MEDDLE_EVERY
		_change(ids[turn % ids.size()], turn)

	func after(id: int, _player: Object, _move: Object, _fire: Object, tick: int) -> void:
		if where == &"between" or tick % MEDDLE_EVERY != 0:
			return
		var ids: Array[int] = game.player_ids()
		var n := ids.size()
		var turn := tick / MEDDLE_EVERY
		var from := 3 + turn % (n - 6)
		if ids[from] != id:
			return
		var step := 1 + (turn / 3) % 3
		_change(ids[from - step if where == &"earlier" else from + step], turn)

	func _change(id: int, turn: int) -> void:
		var victim: Object = game.player_for(id)
		if victim == null or not victim.is_alive():
			return
		done += 1
		match MEDDLES[turn % MEDDLES.size()]:
			&"slay":
				var _slain := FcModTools.slay(game, StringName(str(id)))
			&"slap":
				var _slapped := FcModTools.slap(game, StringName(str(id)), 0.0)
			&"push":
				victim.controller.apply_external_velocity(PUSH)

## In the place of the demo's statistics while they do not record: reads nothing and says so (`after_reads`), so the
## batched loop keeps the idle weapon ticks waiting past each turn (cvar `fc_demo_flush_gate`).
class Passive extends RefCounted:
	var asked := 0
	var done := 0

	func process(_delta: float) -> void:
		pass

	func release() -> void:
		pass

	func after_reads(_player: Object) -> bool:
		asked += 1
		return false

	func after(_id: int, _player: Object, _move: Object, _fire: Object, _tick: int) -> void:
		done += 1


var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: fc_motor_batch plays the same match")
	FcBots.tiers.above = -1
	var was := FcHullGrid.batch
	if not GSFpsMotorBatch.available() or not ClassDB.class_exists(&"GSSimHullWorld"):
		# Natives older than the batch: the cvar changes nothing and there is nothing to compare.
		print("skip: the loaded gs-sim has no motor batch")
		for i in CHECKS:
			_check(true, "(skipped: no motor batch in gs-sim)")
		_report_sections(SECTIONS, SECTIONS, SECTIONS, CHECKS)
		return

	_section("a box of walkers: recorded, replayed through both loops")
	# Every idle posture row the batched loop hands gs-sim is checked against the script's from the state.
	FcPlayer.posture_verify = true
	FcPlayer.posture_batched_rows = 0
	FcPlayer.posture_misses = 0
	var streams: Array = []
	var thought := await _play(false, &"", BOTS, SECONDS, streams, true)
	var off := await _play(false, &"", BOTS, SECONDS, streams, false)
	var on := await _play(true, &"", BOTS, SECONDS, streams, false)
	var live := await _play(true, &"", BOTS, SECONDS, [], true)
	# The lean loop (FcPlayer.lean_tick) only skips calls that change nothing: the long way must play the same match.
	FcPlayer.lean_tick = false
	var long_way := await _play(true, &"", BOTS, SECONDS, streams, false)
	FcPlayer.lean_tick = true
	_check(thought[0].size() > 10 and thought[1] > 0, "the match was played (%d digests, %d kills)" % [thought[0].size(), thought[1]])
	_check(off[0] == thought[0], "the recorded commands replay the match (%s)" % _first_diff(thought[0], off[0]))
	_check(on[0] == off[0], "the batched loop plays the recording to the bit (%s)" % _first_diff(off[0], on[0]))
	_check(live[0] == thought[0], "and the bots' own match, thinking on what it gives them (%s)" % _first_diff(thought[0], live[0]))
	_check(on[1] == off[1], "as many kills (%d, batched %d)" % [off[1], on[1]])
	_check(long_way[0] == on[0], "the lean players' loop plays it to the bit as the long way (%s)" % _first_diff(long_way[0], on[0]))
	_check(off[2] == 0, "and none with the cvar off")
	_check(on[3] == 0 and live[3] == 0, "no player was changed by another's turn (%d, %d faults)" % [on[3], live[3]])
	_check(not GSSim.has(&"players") or (FcPlayer.posture_batched_rows > 0 and FcPlayer.posture_misses == 0),
			"the batched idle posture rows are the script's (%d rows, %d differ)" % [FcPlayer.posture_batched_rows, FcPlayer.posture_misses])
	await _check_demo_gate(on, streams)

	_section("a pit: players die and respawn in their own turn")
	streams = []
	off = await _play(false, &"dm_pit", SMALL_BOTS, SECONDS, streams, true)
	on = await _play(true, &"dm_pit", SMALL_BOTS, SECONDS, streams, false)
	_check(on[0] == off[0] and off[0].size() > 10, "the batched loop plays the pit's match to the bit (%s; %d kills)" % [_first_diff(off[0], on[0]), off[1]])
	_check(on[3] == 0, "no player was changed by another's turn (%d faults)" % on[3])
	_done()

	_section("imported maps: a deathmatch and surf ramps")
	var rows := 0
	var ran := 0
	var kept: StringName = &""
	var kept_streams: Array = []
	var lean_diffs: PackedStringArray = []
	for id in IMPORTED_MAPS:
		if FcMap.by_id(id) == null:
			print("skip %s: not linked" % id)
			_check(true, "(skipped: %s is not linked)" % id)
			continue
		streams = []
		off = await _play(false, id, SMALL_BOTS, SMALL_SECONDS, streams, true)
		var again: Array = await _play(false, id, SMALL_BOTS, SMALL_SECONDS, streams, false)
		on = await _play(true, id, SMALL_BOTS, SMALL_SECONDS, streams, false)
		FcPlayer.lean_tick = false
		var long_map: Array = await _play(true, id, SMALL_BOTS, SMALL_SECONDS, streams, false)
		FcPlayer.lean_tick = true
		if long_map[0] != on[0]:
			lean_diffs.append("%s: %s" % [id, _first_diff(long_map[0], on[0])])
		if kept == &"":
			kept = id
			kept_streams = streams
		rows += on[2]
		ran += 1
		print("%s: %d digests, %d kills, %d rows, %d faults" % [id, off[0].size(), again[1], on[2], on[3]])
		# A map with moving things may not replay its recording; the two loops are held to the same replay.
		print("%s: replay against the recording: %s" % [id, _first_diff(off[0], again[0])])
		_check(on[0] == again[0] and again[0].size() > 5, "the batched loop plays %s to the bit (%s)" % [id, _first_diff(again[0], on[0])])
	_check(ran == 0 or rows > 0, "through the batch (%d rows)" % rows)
	_check(lean_diffs.is_empty(), "the lean players' loop (surf rides once a tick) plays every map as the long way (%s)" % ", ".join(lean_diffs))
	_done()

	await _run_part2(was, off, on, rows, kept, kept_streams)


## fc_hull_grid_native: the players filed in gs-sim's hull world cells play the script grid's match, and with
## FcHullGrid.verify every native answer is checked against the script cells'.
func _check_native_grid(on: Array, streams: Array) -> void:
	FcHullGrid.grid_native = false
	var script_grid := await _play(true, &"", BOTS, SECONDS, streams, false)
	FcHullGrid.grid_native = true
	FcHullGrid.verify = true
	FcHullGrid.grid_native_verified = 0
	FcHullGrid.grid_native_mismatches = 0
	var checked := await _play(true, &"", BOTS, SECONDS, streams, false)
	FcHullGrid.verify = false
	_check(script_grid[0] == on[0] and checked[0] == on[0],
			"filed in gs-sim's cells or the script's, the same match to the bit (%s; %s)" % [_first_diff(on[0], script_grid[0]), _first_diff(on[0], checked[0])])
	var native := ClassDB.class_has_method(&"GSSimHullWorld", &"near")
	print("native hull grid: %s, %d answers checked, %d differ" % [native, FcHullGrid.grid_native_verified, FcHullGrid.grid_native_mismatches])
	_check(not native or (FcHullGrid.grid_native_verified > 0 and FcHullGrid.grid_native_mismatches == 0),
			"gs-sim's cells answer every gather as the script's (%d answers, %d differ)" % [FcHullGrid.grid_native_verified, FcHullGrid.grid_native_mismatches])


## [method _check_native_grid], then demo statistics that read nothing this turn ([Passive]): played with
## fc_demo_flush_gate off and on; ends the section.
func _check_demo_gate(on: Array, streams: Array) -> void:
	await _check_native_grid(on, streams)
	FcHullGrid.demo_flush_gate = false
	FcHullGrid.post_flushes = 0
	var each := await _play(true, &"", BOTS, SECONDS, streams, false, {passive = true})
	var each_flushes := FcHullGrid.post_flushes
	FcHullGrid.demo_flush_gate = true
	FcHullGrid.post_flushes = 0
	var gated := await _play(true, &"", BOTS, SECONDS, streams, false, {passive = true})
	var gated_flushes := FcHullGrid.post_flushes
	print("demo stats in place: %d idle flushes flushing every turn, %d gated (%d turns)" % [each_flushes, gated_flushes, gated[5]])
	_check(each[0] == on[0] and gated[0] == on[0], "with demo statistics in place both ways play the recording to the bit (%s; %s)" % [_first_diff(on[0], each[0]), _first_diff(on[0], gated[0])])
	_check(gated[5] > BOTS and gated[5] == each[5], "their after ran each turn (%d, flushing every turn %d)" % [gated[5], each[5]])
	# A turn that fires still flushes (its shot reads the posture), so the gate saves the idle ones: about 40% here.
	_check(not GSSim.has(&"players") or (gated_flushes > 0 and gated_flushes * 3 < each_flushes * 2),
			"and the idle ticks waited past them: %d gs-sim posture calls, %d flushing every turn" % [gated_flushes, each_flushes])
	_done()


func _run_part2(was, off, on, rows, kept: StringName, kept_streams: Array) -> void:
	_section("lag compensation: shots judged against the past, lagged movers colliding with it")
	if kept == &"":
		for i in 4:
			_check(true, "(skipped: no imported map is linked)")
	else:
		off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true})
		on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true})
		print("%s, shots rewound: %d hits, %d rewound places, %d rows, %d faults" % [kept, off[4], off[5], on[2], on[3]])
		_check(off[4] > 0 and off[5] > 0, "shots hit players stood back where the shooter saw them (%d hits, %d places)" % [off[4], off[5]])
		_check(on[0] == off[0] and off[0].size() > 5, "the same rewound places and hits in both loops (%s)" % _first_diff(off[0], on[0]))
		var rewound_rows: int = on[2]
		off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true, collide = true})
		on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {lag = true, collide = true})
		print("%s, lagged movers: %d hits, %d rewound places, %d rows, %d faults" % [kept, off[4], off[5], on[2], on[3]])
		_check(on[0] == off[0] and off[0].size() > 5, "and with the lagged movers colliding with the past (%s)" % _first_diff(off[0], on[0]))
		_check(rewound_rows > 0 and on[2] > 0, "through the batch (%d and %d rows)" % [rewound_rows, on[2]])
	_done()

	_section("killed, slapped or pushed: between two ticks, after the player's own turn, before it")
	if kept == &"":
		for i in 5:
			_check(true, "(skipped: no imported map is linked)")
	else:
		for where: StringName in [&"between", &"earlier"]:
			off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = where})
			on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = where})
			print("%s, %s: %d changed (batched %d), %d kills, %d rows, %d faults" % [kept, where, off[5], on[5], off[1], on[2], on[3]])
			_check(on[0] == off[0] and off[0].size() > 5, "%s: both loops play the same match (%s)" % [where, _first_diff(off[0], on[0])])
			_check(off[5] > 3 and on[2] > 0 and on[3] == 0, "%s: %d players changed, through the batch with no fault" % [where, off[5]])
		# Before its turn the player's tick has started in the batched loop and not in the other: not the same match, and counted.
		off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = &"later"})
		on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, kept_streams, false, {meddle = &"later"})
		print("%s, later: %d changed, %d faults, %s" % [kept, on[5], on[3], _first_diff(off[0], on[0])])
		_check(on[5] > 3 and on[3] >= on[5], "before its turn: the batched loop counts each (%d changed, %d faults)" % [on[5], on[3]])
	_done()

	_section("body tiers: far coasting bots tick their motor every few ticks, the time made up")
	if kept == &"":
		for i in 4:
			_check(true, "(skipped: no imported map is linked)")
	else:
		# The bots think once with the tiers on; each tick's motor period is recorded with its commands and replayed.
		FcBots.tiers.above = 0
		FcBots.tiers.body_above = 0
		FcBots.tiers.body_near_every = 2
		FcBots.tiers.body_far_every = 3
		var stepped: Array = []
		var _thought: Array = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, stepped, true)
		FcBots.tiers.body_near_every = 1
		FcBots.tiers.body_far_every = 1
		FcBots.tiers.body_above = 24
		FcBots.tiers.above = -1
		var sat := FcPlayer.body_skipped
		off = await _play(false, kept, SMALL_BOTS, SMALL_SECONDS, stepped, false)
		var sat_off := FcPlayer.body_skipped - sat
		on = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, stepped, false)
		var sat_on := FcPlayer.body_skipped - sat - sat_off
		print("%s, body tiers: %d and %d bodies sat out, %d kills, %d rows, %d faults" % [kept, sat_off, sat_on, off[1], on[2], on[3]])
		_check(sat_off > SMALL_BOTS and sat_on == sat_off, "bodies sat out ticks (%d, batched %d)" % [sat_off, sat_on])
		_check(on[0] == off[0] and off[0].size() > 5, "both loops play the same stepped match (%s)" % _first_diff(off[0], on[0]))
		_check(on[2] > 0 and on[3] == 0, "through the batch with no fault (%d rows)" % on[2])
		# cvar ctl_native 0: body_delta and the collider sizing through the properties, not the columns and engine getters.
		var cols := FcPlayer.body_cols
		FcPlayer.body_cols = false
		(GSFpsController as Script).set(&"direct_getters", false)
		var sat_props := FcPlayer.body_skipped
		var props: Array = await _play(true, kept, SMALL_BOTS, SMALL_SECONDS, stepped, false)
		sat_props = FcPlayer.body_skipped - sat_props
		FcPlayer.body_cols = cols
		(GSFpsController as Script).set(&"direct_getters", true)
		_check(props[0] == on[0] and sat_props == sat_on, "ctl_native 0 plays the same stepped match, %d bodies sat out (%s)" % [sat_props, _first_diff(on[0], props[0])])
	_done()
	FcHullGrid.batch = was
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _first_diff(a: PackedStringArray, b: PackedStringArray) -> String:
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			return "first differing window %d of %d" % [i, a.size()]
	return "%d windows" % a.size() if a.size() == b.size() else "%d and %d windows" % [a.size(), b.size()]


## One match, the bots thinking ([param think], commands appended to [param streams]) or
## [param streams] replayed: [digests, kills, batch rows, batch faults, hits, rewound changes].
## [param opts]: `lag`, `collide`, `meddle` (where a [Meddler] acts), `passive` (a [Passive] in the demo statistics' place).
func _play(batched: bool, map_id: StringName, bots: int, seconds: float, streams: Array, think: bool, opts: Dictionary = {}) -> Array:
	FcHullGrid.batch = batched
	FcHullGrid.batch_rows = 0
	FcHullGrid.batch_faults = 0
	var game := _new_game(batched, think, map_id)
	var kills := [0]
	game.player_killed.connect(func(_entry: GSKillFeed.Entry) -> void: kills[0] += 1)
	var hits: Array = []
	var counts := [0, 0]
	game.hit_confirmed.connect(func(attacker: int, victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool) -> void:
		hits.append([attacker, victim, amount, point, headshot, lethal])
		counts[0] += 1)
	var lagging: bool = opts.get("lag", false)
	if opts.get("collide", false):
		game.remote_lags_fn = func(mover_id: int) -> bool: return _lag_of(mover_id) > 0.0
		game.remote_feet_fn = func(other_id: int, mover_id: int, tick: int) -> Variant:
			var lag := _lag_of(mover_id)
			return game.unlag_position_at(other_id, float(tick) - lag) if lag > 0.0 else null
	var meddler: Meddler = null
	var passive: Passive = null
	if opts.get("passive", false):
		passive = Passive.new()
		game.demo_stats = passive
	if opts.has("meddle"):
		meddler = Meddler.new()
		meddler.game = game
		meddler.where = opts.meddle
		game.demo_stats = meddler
	var players: Array = []
	var minds: Array = []
	for i in bots:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
			var mind := FcBots.Mind.new()
			mind.seed = 100 + i
			minds.append(mind)
	game.start(0)
	game.tick({})
	# The map's collision reaches the physics space in a physics frame; every run starts after it.
	for _i in 3:
		await get_tree().physics_frame
	if think and map_id != &"" and map_id != &"dm_pit":
		await _warm_routes(game)
	var digests := PackedStringArray()
	var window := PackedByteArray()
	for tick_index in int(seconds * TICK_RATE):
		var commands := _commands_for(game, players, minds, streams, tick_index, think, lagging)
		var now := game.current_tick()
		game.tick(commands)
		if meddler != null:
			meddler.between(now)
		window.append_array(_players_chunk(game, players, lagging, now, counts))
		window.append_array(var_to_bytes(hits))
		hits.clear()
		if tick_index % 10 == 9:
			var hashing := HashingContext.new()
			var _started := hashing.start(HashingContext.HASH_MD5)
			var _fed := hashing.update(window)
			digests.append(hashing.finish().hex_encode())
			window.clear()
		# Exactly one physics step every 8 ticks, never "a frame": a frame runs as many steps as the wall clock owes, so a loaded box
		# moved the weapon drops' rigid bodies a different number of steps, the space's broadphase with them, and the motor's
		# space queries settled a contact a tenth of a millimetre apart (dm-morpheus, 1 run in 20 on PH). Same in every run here.
		if tick_index % 8 == 0:
			await get_tree().physics_frame
	var out := [digests, kills[0], FcHullGrid.batch_rows, FcHullGrid.batch_faults, counts[0], meddler.done if meddler != null else (passive.done if passive != null else counts[1])]
	game.demo_stats = null
	game.remote_feet_fn = Callable()
	game.remote_lags_fn = Callable()
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	return out


func _new_game(batched: bool, think: bool, map_id: StringName) -> FcGame:
	var game := FcGame.new()
	game.name = "Arena_%d_%d" % [int(batched), int(think)]
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
	return game


func _warm_routes(game: FcGame) -> void:
	# The routes start when the mesh bake lands; start every run from there.
	var world := FcBots.world_for(game)
	var _first := world.route(Vector3.ZERO, Vector3.ONE)
	var frames := 0
	while world.is_route_pending() and frames < 3000:
		await get_tree().process_frame
		frames += 1
	var _warm := world.warm()


## This tick's commands: the bots' own thinking (recorded into `streams`) or the recorded stream replayed.
func _commands_for(game: FcGame, players: Array, minds: Array, streams: Array, tick_index: int, think: bool, lagging: bool) -> Dictionary:
	var commands := {}
	if think:
		var recorded := {}
		var tick := game.current_tick()
		for i in players.size():
			var pair: Array = FcBots.think(game, players[i], minds[i], tick, float(TICK_RATE))
			var move: GSFpsCommand = pair[0]
			var fire: GSWeaponCommand = pair[1]
			commands[players[i].player_id] = pair
			recorded[players[i].player_id] = [move.duplicate_command(), fire.duplicate_command(), players[i].body_every]
		streams.append(recorded)
	else:
		var recorded: Dictionary = streams[tick_index]
		for id: int in recorded:
			var move: GSFpsCommand = recorded[id][0]
			var fire: GSWeaponCommand = recorded[id][1]
			commands[id] = [move.duplicate_command(), fire.duplicate_command()]
			# The motor period the bot's think chose (body tiers); 1 when it was not recorded.
			var body: Object = game.player_for(id)
			if body != null:
				body.body_every = recorded[id][2] if recorded[id].size() > 2 else 1
			if lagging and _lag_of(id) > 0.0:
				commands[id].append(_lag_of(id))
	return commands


## The bytes one tick adds to the run's window: every player's state, and where a lagged viewer saw them.
func _players_chunk(game: FcGame, players: Array, lagging: bool, now: int, counts: Array) -> PackedByteArray:
	var chunk := PackedByteArray()
	for player: Object in players:
		var state: GSFpsState = player.controller.state if player.controller != null else null
		if state != null:
			chunk.append_array(var_to_bytes([state.position, state.velocity, state.mode, state.move_flags(), state.ground_id != 0,
				state.yaw, state.pitch, player.health.health, player.health.alive]))
		if lagging:
			var then: Variant = game.unlag_position_at(player.player_id, float(now) - _lag_of(player.player_id))
			chunk.append_array(var_to_bytes(then))
			if then is Vector3 and state != null and not (then as Vector3).is_equal_approx(state.position):
				counts[1] += 1
	return chunk


## The view lag, in ticks, of the player's commands in a lagged run: none for one player in four, as a bot has none.
func _lag_of(id: int) -> float:
	return float(id % 4) * 1.5
