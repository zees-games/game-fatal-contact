extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcBotLoadouts := preload("../game/fc_bot_loadouts.gd")
const FcBotsWorld := preload("../game/fc_bots_world.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")

## Bot play styles by weapon: the gun in a bot's hand sets its style class (dot-bot's table), so
## snipers take cover and peek. Run: [code]./game.sh test headless_bot_styles[/code].

const TICK_RATE := 64
const MAP := &"dm_atrium"
const BOTS := 8
const FIGHT_SECONDS := 90.0
## Of the sniper phases, those that are cover, a peek or a move to another angle.
const SNIPER_PHASES: Array[String] = ["hide", "return", "move", "hold"]

const SECTIONS := 3
const CHECKS := 13

var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless bot styles")
	FcBotLoadouts.seed = 0
	_classes()
	await _fight("sniper", "snipers take cover, peek and move, and do not all play one way", _sniper_checks)
	await _fight("shotgun", "shotgun bots play the shotgun styles, and not all one", _shotgun_checks)
	FcBotLoadouts.mode = FcBotLoadouts.ALL
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _classes() -> void:
	_section("every FC weapon has a style class in dot-bot's table")
	var unmapped: Array[String] = []
	var unknown: Array[String] = []
	for id: StringName in AwWeaponPack.IDS:
		var klass: Variant = FcBotsWorld.STYLE_CLASS.get(id)
		if klass == null:
			unmapped.append(String(id))
		elif not GSBotStyle.DEFAULTS.has(String(klass)):
			unknown.append("%s=%s" % [id, klass])
	_check(unmapped.is_empty(), "every weapon id has a class", ", ".join(unmapped))
	_check(unknown.is_empty(), "every class has styles in the shipped table", ", ".join(unknown))
	var def := GSWeaponDef.new()
	def.id = &"aw_sniper"
	var prefixed := FcBotsWorld.World._class_of(def)
	def.id = &"other_pack_scope"
	def.tags = [&"scoped"]
	_check(prefixed == &"sniper" and FcBotsWorld.World._class_of(def) == &"sniper", "a pack's prefixed id and a scoped gun from another pack are snipers")
	_done()


## [param kit] for every bot, [param seconds] of their fight, then [param checks] on the minds.
func _fight(kit: String, title: String, checks: Callable) -> void:
	_section(title)
	FcBotLoadouts.mode = kit
	var game := _boot()
	game.match_node.rules.respawn_delay_sec = 1.0
	var ids: Array[int] = []
	var minds := {}
	for i in BOTS:
		var id := FcGame.BOT_SESSION_BASE + 1 + i
		ids.append(id)
		var _a := game.add_player(id, "Bot%d" % i)
		minds[id] = FcBots.Mind.new()
		minds[id].seed = 3 + i
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var states := {}
	var labels := {}
	for i in range(int(FIGHT_SECONDS * TICK_RATE)):
		var tick := game.current_tick()
		var commands := {}
		for id in ids:
			commands[id] = FcBots.think(game, game.player_for(id), minds[id], tick, float(TICK_RATE))
			var brain: GSBotBrain = minds[id].brain
			if brain != null and brain.last != null:
				states[brain.last.state] = true
		game.tick(commands)
		if i % 32 == 0:
			for id in ids:
				var brain: GSBotBrain = minds[id].brain
				if brain != null and brain.style.active:
					labels[brain.style.label()] = true
		if i % 8 == 0:
			await get_tree().process_frame
	checks.call(minds.values(), states, labels)
	_free(game)
	await get_tree().process_frame
	_done()


func _sniper_checks(minds: Array, states: Dictionary, labels: Dictionary) -> void:
	var styled := 0
	var covered := 0
	var entered := {}
	for mind in minds:
		var style: GSBotStyle = mind.brain.style if mind.brain != null else null
		if style == null:
			continue
		var any := false
		for phase in SNIPER_PHASES:
			var n := int(style.entered.get(phase, 0))
			entered[phase] = int(entered.get(phase, 0)) + n
			any = any or n > 0
		styled += 1 if any else 0
		covered += 1 if int(style.entered.get("hide", 0)) + int(style.entered.get("hold", 0)) > 0 else 0
	var snipers := labels.keys().filter(func(l: String) -> bool: return l.begins_with("sniper/"))
	_check(snipers.size() * 2 >= labels.size(), "the bots' class is mostly the sniper in their hands", str(labels.keys()))
	_check(styled * 2 >= BOTS, "at least half the snipers take cover, peek or move to an angle", "%d of %d, %s" % [styled, BOTS, entered])
	_check(covered >= 2, "at least two of them sit in cover or hold an angle", "%d" % covered)
	_check(states.has(&"cover") or states.has(&"peek") or states.has(&"vantage") or states.has(&"sneak") or states.has(&"reposition"), "and say so in their intent's state", str(states.keys()))
	_check(snipers.size() >= 2, "the snipers do not all play one style", str(snipers))


func _shotgun_checks(_minds: Array, states: Dictionary, labels: Dictionary) -> void:
	var shotguns := labels.keys().filter(func(l: String) -> bool: return l.begins_with("shotgun/"))
	_check(shotguns.size() * 2 >= labels.size(), "the bots play mostly shotgun styles", str(labels.keys()))
	_check(shotguns.size() >= 2, "and not all the same one", str(shotguns))
	_check(states.has(&"rush"), "some rush in", str(states.keys()))


func _boot() -> FcGame:
	var game := FcGame.new()
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	_check(game.setup(FcMap.by_id(MAP)).ok, "the game sets up on %s" % MAP)
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	return game


func _free(game: FcGame) -> void:
	remove_child(game)
	game.queue_free()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1
