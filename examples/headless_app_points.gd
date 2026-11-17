extends DotGameCheckSuite

## FC's per-app customisation (game/fc_app_wiring.gd) with fakes: every part off with no
## config, the avatars settings turning into rules and back, the earn events and who earns them,
## the site's points on the player and the HUD label hidden and shown.
##
## [codeblock]
## godot --headless --path . res://examples/headless_app_points.tscn
## [/codeblock]

const FcAppWiring := preload("../game/fc_app_wiring.gd")
const FcHudAppPoints := preload("../game/fc_hud_app_points.gd")
const FcTeamBodies := preload("../game/fc_team_bodies.gd")
const FcEvents := preload("../game/fc_events.gd")
const CHECKS := 37
const BOT := 900_000_001
const HUMAN := 7
const OTHER := 8
const SEAT := 9


class FakeIdentity extends RefCounted:
	func key_of(id: int) -> String:
		if id == HUMAN or id == OTHER:
			return "user:%d" % id
		return "arena-player-%08d" % id


class FakeConfig extends RefCounted:
	var team_bodies := "fc_swat,fc_military"


class FakeMode extends RefCounted:
	var team := true

	func is_team_mode() -> bool:
		return team


class FakeMatch extends RefCounted:
	signal round_ended(round_number: int, winner: int, outcome: Variant)
	signal match_ended(winner: int, outcome: Variant)
	var scoreboard: Object = null


class FakePlayer extends RefCounted:
	var app_points_on := false
	var app_points := 0


class FakeGame extends RefCounted:
	signal player_killed(entry: Object)
	signal map_changed(map: Variant)
	var config := FakeConfig.new()
	var mode := FakeMode.new()
	var match_node: Object = null
	var loadout_identity := FakeIdentity.new()
	var rules := {"team_avatars": 0.0, "team_body_a": -1.0, "team_body_b": -1.0}
	var teams := {HUMAN: 2, OTHER: 1, BOT: 2}
	var players := {HUMAN: FakePlayer.new(), OTHER: FakePlayer.new()}

	func rule(key: String) -> float:
		return float(rules.get(key, 0.0))

	func set_movement_rules(changed: Dictionary) -> void:
		rules.merge(changed, true)

	func player_ids() -> Array[int]:
		return [HUMAN, OTHER, BOT]

	func team_of(id: int) -> int:
		return int(teams.get(id, 0))

	func player_for(id: int) -> Object:
		return players.get(id)


class FakeClient extends RefCounted:
	var body := {}

	func get_integration(_path: String, _query: Dictionary) -> DotResult:
		return DotResult.success(body)


class FakeReporter extends Node:
	var sent: Array = []

	func report(key: String, event_key: String, count: int, meta: Dictionary) -> DotResult:
		sent.append({"key": key, "event": event_key, "count": count, "meta": meta})
		return DotResult.success()

	func flush() -> void:
		pass


class FakeKill extends RefCounted:
	var killer_key := ""
	var victim_key := ""
	var suicide := false
	var team_kill := false
	var headshot := false


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	await _config_off()
	await _settings()
	_events()
	_points()
	_hud()
	_rules_codec()
	_report(CHECKS)


func _wiring(game: FakeGame, client: Object) -> FcAppWiring:
	var w := FcAppWiring.new()
	w.follow_settings = false
	w.call(&"setup", game, client, DotPointsReporterConfig.new(), DotLoadoutConfig.new())
	return w


func _config_off() -> void:
	print("config off")
	var game := FakeGame.new()
	var w := _wiring(game, RefCounted.new())
	var parts := w.describe()
	_check(not parts["events"], "no app_id or key: earn events off")
	_check(not parts["settings"], "no client with get_integration: settings off")
	_check(not parts["points"], "no client: points off")
	var refused: DotResult = w.report_event(HUMAN, FcAppWiring.EVENT_KILL, false)
	_check(not refused.ok, "a report while off is refused, not sent")
	w.player_joined(HUMAN)
	w.player_left(HUMAN)
	w.refresh_all()
	game.player_killed.emit(FakeKill.new())
	_check(not game.players[HUMAN].app_points_on, "join, leave, kill and refresh while off change nothing")
	w.free()
	await get_tree().process_frame


func _settings() -> void:
	print("avatars settings")
	var game := FakeGame.new()
	var client := FakeClient.new()
	var w := _wiring(game, client)
	_check(w.describe()["settings"], "a client with get_integration: settings on")
	_check(not w.describe()["points"], "no pinned site key: points off (nothing granted)")
	client.body = {"appId": "1", "sections": {"avatars": {"version": 2, "values": {
		"appOnly": true,
		"slots": [
			{"slotKey": "team:swat:a", "avatarId": "fc_military"},
			{"slotKey": "team:military:b", "avatarId": "not_ours"},
			{"slotKey": "lobby", "avatarId": "fc_swat"},
		],
	}}}}
	var read: DotResult = await w.settings.refresh()
	_check(read.ok, "the settings read", str(read.error) if not read.ok else "")
	_check(game.rules["team_avatars"] == 1.0, "appOnly forces team avatars on")
	_check(game.rules["team_body_a"] == 1.0, "slot team:*:a binds side a to fc_military (index 1)",
		str(game.rules["team_body_a"]))
	_check(game.rules["team_body_b"] == -1.0, "an avatar FC lacks leaves side b in config order")
	_check(FcTeamBodies._pick(game, 0) == 1, "side a wears the bound body")
	_check(FcTeamBodies._pick(game, 1) == 1, "side b keeps its own place")
	client.body = {"appId": "1", "sections": {"avatars": {"version": 3, "values": {"appOnly": false, "slots": []}}}}
	read = await w.settings.refresh()
	_check(read.ok and game.rules["team_avatars"] == 0.0, "appOnly off puts team avatars back")
	_check(game.rules["team_body_a"] == -1.0 and FcTeamBodies._pick(game, 0) == 0, "no slots: side a back to config order")
	read = await w.settings.refresh()
	_check(read.ok and (read.value as PackedStringArray).is_empty(), "the same version again changes nothing")
	w.free()


func _events() -> void:
	print("earn events")
	var game := FakeGame.new()
	var w := _wiring(game, RefCounted.new())
	var fake := FakeReporter.new()
	w.reporter = fake
	var kill := FakeKill.new()
	kill.killer_key = str(HUMAN)
	kill.victim_key = str(BOT)
	kill.headshot = true
	game.player_killed.emit(kill)
	_check(fake.sent.size() == 2, "a headshot kill sends kill and headshot", str(fake.sent))
	if fake.sent.size() == 2:
		_check(fake.sent[0]["event"] == "kill" and fake.sent[1]["event"] == "headshot", "event keys kill, headshot")
		_check(fake.sent[0]["key"] == "user:%d" % HUMAN and fake.sent[0]["count"] == 1, "by platform key, count 1")
		_check(fake.sent[0]["meta"] == {"humans": 2, "vsBot": true}, "meta: humans 2, vsBot", str(fake.sent[0]["meta"]))
	else:
		for _i in 3:
			_check(false, "kill events (skipped)")
	fake.sent.clear()
	var suicide := FakeKill.new()
	suicide.killer_key = str(HUMAN)
	suicide.victim_key = str(HUMAN)
	suicide.suicide = true
	game.player_killed.emit(suicide)
	var team := FakeKill.new()
	team.killer_key = str(HUMAN)
	team.victim_key = str(OTHER)
	team.team_kill = true
	game.player_killed.emit(team)
	_check(fake.sent.is_empty(), "suicide and team kill earn nothing")
	var by_bot := FakeKill.new()
	by_bot.killer_key = str(BOT)
	by_bot.victim_key = str(HUMAN)
	game.player_killed.emit(by_bot)
	_check(fake.sent.is_empty(), "a bot earns nothing")
	_check(not w.report_event(SEAT, "kill", false).ok, "a bare seat (no platform key) earns nothing")
	var fight := FakeMatch.new()
	game.match_node = fight
	game.map_changed.emit(null)
	fight.round_ended.emit(1, 2, null)
	_check(fake.sent.size() == 1 and fake.sent[0]["event"] == "round_win" and fake.sent[0]["key"] == "user:%d" % HUMAN,
		"round won by team 2: only its human earns round_win", str(fake.sent))
	fake.sent.clear()
	fight.match_ended.emit(1, null)
	_check(fake.sent.size() == 1 and fake.sent[0]["event"] == "match_win" and fake.sent[0]["key"] == "user:%d" % OTHER
		and fake.sent[0]["meta"]["vsBot"] == true, "match won by team 1: match_win, vsBot with a bot present", str(fake.sent))
	fake.sent.clear()
	var moved := FakeMatch.new()
	game.match_node = moved
	game.map_changed.emit(null)
	fight.round_ended.emit(2, 2, null)
	_check(fake.sent.is_empty(), "the old match node is let go after a map change")
	fake.free()
	w.free()


func _points() -> void:
	print("points and items")
	var game := FakeGame.new()
	var client := FakeClient.new()
	var w := _wiring(game, client)
	var source := DotLoadoutSiteSource.with_client(client)
	var key := "user:%d" % HUMAN
	source._cache[key] = {"ids": [], "points": {"enabled": true, "balance": 120, "label": "Coins"},
		"loadout": [{"slot": "hat", "store": "s1", "key": "red_hat"}], "at": 0.0,
		"exp": Time.get_unix_time_from_system() + 3600.0}
	w.use_site(source)
	_check(w.describe()["points"], "a site source: points on")
	w._key_of_id[HUMAN] = key
	w._id_of_key[key] = HUMAN
	var player: FakePlayer = game.players[HUMAN]
	source.refreshed.emit(key)
	_check(player.app_points_on and player.app_points == 120, "a verified grant puts the balance on the player",
		"%s %d" % [player.app_points_on, player.app_points])
	_check(w.apply_player(HUMAN, key) == 0, "a store item for a slot FC lacks is ignored")
	source._cache[key]["points"] = {"enabled": false, "balance": null, "label": ""}
	source.refreshed.emit(key)
	_check(not player.app_points_on and player.app_points == 0, "points off for the app: hidden")
	source._cache[key]["points"] = {"enabled": true, "balance": 5, "label": ""}
	source.refreshed.emit(key)
	source.rejected.emit(key, "signature")
	_check(not player.app_points_on, "a refused grant hides the balance")
	w.player_left(HUMAN)
	_check(not w._key_of_id.has(HUMAN) and source.points_of(key).is_empty(), "leaving forgets the key and the grant")
	w.free()


func _hud() -> void:
	print("hud label")
	var label := Label.new()
	_check(not FcHudAppPoints.present(label, null) and not label.visible, "no player: hidden")
	var player := FakePlayer.new()
	player.app_points = 30
	_check(not FcHudAppPoints.present(label, player) and not label.visible, "points off: hidden")
	player.app_points_on = true
	player.app_points = 42
	_check(FcHudAppPoints.present(label, player) and label.visible and label.text == "App points 42",
		"points on: shown with the balance", label.text)
	label.free()


func _rules_codec() -> void:
	print("rules codec")
	var many := {}
	for i in 70:
		many["rule_%d" % i] = float(i)
	var read := FcEvents.read_rules(DotNetReader.new(FcEvents.write_rules(many)))
	_check(read["ok"] and (read["rules"] as Dictionary).size() == 70, "70 rules round-trip: no key cap",
		str((read["rules"] as Dictionary).size()))
	var short := FcEvents.write_rules(many).slice(0, 40)
	var cut := FcEvents.read_rules(DotNetReader.new(short))
	_check(not cut["ok"], "a short packet stops and says so")
