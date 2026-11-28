extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPlayer := preload("../game/fc_player.gd")

## `sv_activity_every`: noting a player's activity every few ticks (offset by id) instead of every tick plays the same
## match, keeps every active player's note within the stride, and the idle check names the same silent player on the
## same tick. A short idle time shrinks the stride to a quarter of it.

const TICK_RATE := 33
const BOTS := 8
const SECONDS := 4.0
const SILENT := 999

const SECTIONS := 1
const CHECKS := 6

var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: a strided activity note plays the same match and idles the same player")
	FcBots.tiers.above = -1
	_entered += 1
	var every_tick := await _play(1, 1.0)
	var strided := await _play(8, 1.0)
	var short := await _play(8, 0.5)
	_check(every_tick[0].size() > 5, "the match was played (%d digests)" % every_tick[0].size())
	_check(strided[0] == every_tick[0], "the strided note plays the match the every-tick note plays")
	_check(every_tick[1] <= 1 and strided[1] < every_tick[1] + 8, "active players' notes lag at most the stride (%d, %d ticks)" % [every_tick[1], strided[1]])
	_check(short[1] < every_tick[1] + 4, "a 0.5 s idle time (16 ticks) shrinks the stride to 4 (lag %d ticks)" % short[1])
	_check(not every_tick[2].is_empty() and strided[2] == every_tick[2],
		"the idle check names the same players on the same ticks (%s / %s)" % [every_tick[2], strided[2]])
	_check(str(SILENT) in ",".join(strided[2]) and not ",".join(strided[2]).contains("10"),
		"only the silent player idles, never a bot")
	_completed += 1
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## One match: [digests, worst note lag of an active player, idle signals as "key@tick"].
func _play(every: int, idle_seconds: float) -> Array:
	var game := FcGame.new()
	game.name = "Arena_%d_%d" % [every, int(idle_seconds * 10.0)]
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var _setup := game.setup(FcMap.dm_box())
	game.activity_every = every
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.config.idle_seconds = idle_seconds
	var idles := PackedStringArray()
	game.match_node.player_idle.connect(func(key: String) -> void: idles.append("%s@%d" % [key, game.current_tick()]))
	var players: Array = []
	var minds: Array = []
	for i in BOTS:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
			var mind := FcBots.Mind.new()
			mind.seed = 100 + i
			minds.append(mind)
	var _silent := game.add_player(SILENT, "Silent")
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var digests := PackedStringArray()
	var window := PackedStringArray()
	var lag := 0
	for tick_index in int(SECONDS * TICK_RATE):
		var tick := game.current_tick()
		var commands := {}
		for i in players.size():
			var pair: Array = FcBots.think(game, players[i], minds[i], tick, float(TICK_RATE))
			commands[players[i].player_id] = pair
			var state: GSFpsState = players[i].controller.state if players[i].controller != null else null
			if state != null:
				window.append("%d:%.4f,%.4f,%.4f" % [i, state.position.x, state.position.y, state.position.z])
		# A command that never came: the silent player sends nothing a tick, so only it may idle.
		commands[SILENT] = [null, null]
		game.tick(commands)
		if tick_index > 2 * TICK_RATE * idle_seconds:
			for p: FcPlayer in players:
				var record := game.match_node.scoreboard.find(str(p.player_id))
				if record != null:
					lag = maxi(lag, game._tick - record.last_active_tick)
		if tick_index % 10 == 9:
			digests.append(" ".join(window).md5_text())
			window.clear()
		if tick_index % 8 == 0:
			await get_tree().physics_frame
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	return [digests, lag, idles]
