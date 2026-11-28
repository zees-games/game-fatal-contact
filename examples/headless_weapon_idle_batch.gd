extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPlayerIdle := preload("../game/fc_player_idle.gd")

## `fc_weapon_idle_batch`: the idle weapons' native calls joined into one gs-sim call per tick (`GSSimWeaponIdleBatch`) play exactly the
## match one call per weapon plays: 16 bots on box hash identically with the batch off, off again, on, and with `fc_weapon_idle_lean` 0.
## Without the library only the script lane runs, and the suite says so.

const TICK_RATE := 33
const BOTS := 16
const SECONDS := 15.0

const SECTIONS := 1
const CHECKS := 5

var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: the idle weapon batch plays the same match")
	FcBots.tiers.above = -1
	_entered += 1
	var native := GSSim.has(&"weapon_idle")
	if not native:
		print("gs-sim has no weapon_idle module: only the script lane is exercised")
	FcPlayerIdle.weapon_idle_batch = false
	var off := await _play()
	var again := await _play()
	FcPlayerIdle.weapon_idle_batch = true
	var on := await _play()
	# fc_weapon_idle_lean 0, written the way the cvar writes it: the joins go through the rig's idle helpers.
	var rig_script: Script = AwWeaponRig
	rig_script.set(&"idle_batch_lean", false)
	var unlean := await _play()
	var flag_seen: bool = AwWeaponRig.idle_batch_lean
	rig_script.set(&"idle_batch_lean", true)
	_check(off[0].size() > 10, "the match was played (%d digests, %d kills)" % [off[0].size(), off[1]])
	_check(off[0] == again[0], "two runs with the batch off are identical (the match is deterministic)")
	_check(on[0] == off[0], "the batch on plays the match the batch off plays (%d kills, %d batched weapon ticks)" % [on[1], on[2]])
	if native:
		_check(on[2] > 100 and off[2] == 0, "the weapons really ran through the batch (%d weapon ticks), and never with it off" % on[2])
	else:
		_check(on[2] == 0, "(skipped: no weapon_idle module) nothing batched")
	_check(not flag_seen and AwWeaponRig.idle_batch_lean and unlean[0] == on[0] and unlean[2] == on[2],
		"the lean batch join plays the match the helper join plays (%d batched weapon ticks)" % unlean[2])
	_completed += 1
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## One match: [digests, kills, batched weapon ticks].
func _play() -> Array:
	var game := FcGame.new()
	game.name = "Arena_%d" % int(FcPlayerIdle.weapon_idle_batch)
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	var _setup := game.setup(FcMap.box())
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.match_node.rules.respawn_delay_sec = 1.0
	var kills := [0]
	game.player_killed.connect(func(_entry: GSKillFeed.Entry) -> void: kills[0] += 1)
	var players: Array = []
	var minds: Array = []
	for i in BOTS:
		var made := game.add_player(100 + i, "Bot%d" % i)
		if made.ok:
			players.append(made.value)
			var mind := FcBots.Mind.new()
			mind.seed = 100 + i
			minds.append(mind)
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var digests := PackedStringArray()
	var window := PackedStringArray()
	var batched := 0
	for tick_index in int(SECONDS * TICK_RATE):
		var tick := game.current_tick()
		var commands := {}
		for i in players.size():
			var pair: Array = FcBots.think(game, players[i], minds[i], tick, float(TICK_RATE))
			var move: GSFpsCommand = pair[0]
			var fire: GSWeaponCommand = pair[1]
			commands[players[i].player_id] = pair
			window.append("%d:%.4f,%.4f,%d,%d" % [i, move.yaw, move.pitch, move.buttons, fire.buttons])
			var state: GSFpsState = players[i].controller.state if players[i].controller != null else null
			if state != null:
				window.append("%.4f,%.4f,%.4f" % [state.position.x, state.position.y, state.position.z])
			if players[i].health != null:
				window.append("%.3f" % players[i].health.health)
		game.tick(commands)
		batched += game._idle_owners.size()
		game._idle_owners.clear()
		if tick_index % 10 == 9:
			digests.append(" ".join(window).md5_text())
			window.clear()
		# One physics step every 8 ticks, never "a frame" (headless_botthreads says why).
		if tick_index % 8 == 0:
			await get_tree().physics_frame
	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	return [digests, kills[0], batched]
