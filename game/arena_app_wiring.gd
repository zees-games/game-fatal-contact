extends Node

## FC's per-app customisation from Gamespice, on the dedicated server: the app's avatars settings,
## the earn events that feed the app's points, the balance the HUD shows, and the store items a
## player equipped. Built by the module on the authority ([code]_build_app[/code] in
## arena_module_b2.gd); a client never builds one and never holds a balance of its own.
##
## [b]Every part is off until its operator configures it, and off is quiet:[/b] one log line, no
## crash, nothing sent.
## [codeblock]
## earn events    DotPointsReporter        user://app_points.json, DOT_POINTS_*, --points-*
##                                         (app_id, server_id, private_key_path)
## settings       DotLoadoutSiteSettings   a backbone client (dot_backbone_client)
## points, items  DotLoadoutSiteSource     user://app_loadout.json, DOT_LOADOUT_*, --loadout-*
##                                         (site_public_key_path, site_audience)
## [/codeblock]
##
## [b]No amounts here.[/b] The game names what happened ([constant EVENT_KEYS]); the app's points
## rules decide what each is worth, its caps, and whether play against bots counts (`vsBot`).
##
## [b]Reached by name, not by class.[/b] The web client shell and the server pin older addons that
## lack these classes, and a script naming one does not compile there (arena_newer_api.gd). So every
## new addon class is looked up at run time, and a build without one leaves that part off.

const ArenaNewerApi := preload("arena_newer_api.gd")
const ArenaLoadoutIdentity := preload("arena_loadout_identity.gd")

const CHANNEL := &"arena.app"

## The operator's files under `user://`: absent is the normal case (that part is off), and the
## environment and command line layers still apply without them.
const POINTS_CONFIG_PATH := "user://app_points.json"
const LOADOUT_CONFIG_PATH := "user://app_loadout.json"

## The earn events FC reports, one per player per moment (count 1). The keys are the contract with
## the app's points rules (`eventKey`); append, never rename. See docs/services.md.
## kill       killed an opponent (not themself, not a team mate); meta.vsBot when the victim is a bot
## headshot   that kill was a headshot (sent beside `kill`)
## round_win  on the winning side (or the leader, in a free-for-all) when a round ended
## match_win  the same when the match ended
const EVENT_KILL := "kill"
const EVENT_HEADSHOT := "headshot"
const EVENT_ROUND_WIN := "round_win"
const EVENT_MATCH_WIN := "match_win"
const EVENT_KEYS: PackedStringArray = [EVENT_KILL, EVENT_HEADSHOT, EVENT_ROUND_WIN, EVENT_MATCH_WIN]

## Server bot session ids start here (ArenaGame.BOT_SESSION_BASE); a bot earns nothing.
const BOT_SESSION_BASE := 900_000_000

## The avatars-section slot keys FC has a place for: `team:<name>:a` and `team:<name>:b`, the first
## and second playing side, bound through the `team_body_a` / `team_body_b` rules (arena_team_bodies.gd).
const SIDE_SUFFIXES: PackedStringArray = [":a", ":b"]
const SIDE_RULES: PackedStringArray = ["team_body_a", "team_body_b"]

## The game: anything with `rule`, `set_movement_rules`, `config`, `player_for`, `player_ids`,
## `team_of`, `mode`, `match_node`, `loadout_identity` and the `player_killed` / `map_changed` signals.
var game: Object = null
## The backbone client (dot-auth's DotBackboneClient); `dot_backbone_client` when none is given.
var client: Object = null
## Whether [method setup] starts polling the settings (tests drive [method apply_avatars] themselves).
var follow_settings := true

## The parts, null while off.
var reporter: Node = null
var settings: RefCounted = null
var site: RefCounted = null

var _match: Object = null
var _key_of_id: Dictionary = {}
var _id_of_key: Dictionary = {}
var _logged: Dictionary = {}
## The `team_avatars` rule before appOnly forced it, put back when the app turns appOnly off.
var _forced := false
var _team_avatars_before := 1.0


## Builds whatever is configured. [param points_config] / [param loadout_config] replace the layered
## files (tests). A part that is not configured is logged once and left off; the value is
## [method describe].
func setup(p_game: Object, p_client: Object = null, points_config: Object = null, loadout_config: Object = null) -> DotResult:
	game = p_game
	client = p_client if p_client != null else DotRegistry.get_service(&"dot_backbone_client")
	_setup_reporter(points_config)
	var loadout: Object = loadout_config if loadout_config != null else _loadout_config()
	_setup_settings(loadout)
	_setup_site(loadout)
	if game != null:
		if game.has_signal(&"player_killed") and not game.is_connected(&"player_killed", _on_killed):
			game.connect(&"player_killed", _on_killed)
		if game.has_signal(&"map_changed") and not game.is_connected(&"map_changed", _bind_match):
			game.connect(&"map_changed", _bind_match)
		_bind_match()
	DotLog.info(CHANNEL, "app customisation", describe())
	return DotResult.success(describe())


## Which parts are on.
func describe() -> Dictionary:
	return {"events": reporter != null, "settings": settings != null, "points": site != null}


func _exit_tree() -> void:
	if settings != null:
		settings.call(&"stop")
	if reporter != null:
		reporter.call(&"flush")


# --- Earn events ---------------------------------------------------------------------

func _setup_reporter(cfg: Object) -> void:
	var script := ArenaNewerApi.script_of(&"DotPointsReporter")
	var cfg_script := ArenaNewerApi.script_of(&"DotPointsReporterConfig")
	if script == null or cfg_script == null:
		_once(&"no_reporter", "app points events are off: this build has no DotPointsReporter (dot-achievements)")
		return
	if cfg == null:
		cfg = cfg_script.new()
		var loaded: DotResult = cfg.call(&"load_layered", POINTS_CONFIG_PATH)
		if _points_unset(cfg):
			_once(&"points_off", "app points events are off: no app_id or signing key (%s, DOT_POINTS_*)" % POINTS_CONFIG_PATH)
			return
		if not loaded.ok:
			DotLog.result(CHANNEL, "app points events are off: the points config is invalid", loaded)
			return
	elif _points_unset(cfg):
		_once(&"points_off", "app points events are off: no app_id or signing key (%s, DOT_POINTS_*)" % POINTS_CONFIG_PATH)
		return
	var made: Node = script.new()
	made.name = "AppPointsReporter"
	if client != null:
		made.set(&"client", client)
	add_child(made)
	var configured: DotResult = made.call(&"configure", cfg)
	if not configured.ok:
		# configure logged why; the reporter stays off rather than queue what it cannot sign.
		remove_child(made)
		made.queue_free()
		return
	reporter = made


static func _points_unset(cfg: Object) -> bool:
	return int(cfg.get(&"app_id")) <= 0 and String(cfg.get(&"private_key_path")).strip_edges() == "" \
		and String(cfg.get(&"private_key_pem")).strip_edges() == ""


## Queues [param event_key] for player [param player_id]. Refused for a bot, a player with no
## platform key (a bare seat) and while events are off.
func report_event(player_id: int, event_key: String, vs_bot: bool) -> DotResult:
	if reporter == null:
		return DotResult.fail(DotError.CODE_STATE, "App points events are off.")
	if player_id >= BOT_SESSION_BASE:
		return DotResult.fail(DotError.CODE_INVALID, "A bot earns nothing.")
	var key := player_key(player_id)
	if key == "":
		return DotResult.fail(DotError.CODE_STATE, "This player has no platform key.")
	return reporter.call(&"report", key, event_key, 1, {"humans": humans(), "vsBot": vs_bot})


## The player's platform key (the durable stats key), or "" for a bare seat that has none.
func player_key(player_id: int) -> String:
	if _key_of_id.has(player_id):
		return _key_of_id[player_id]
	var identity: Variant = game.get(&"loadout_identity") if game != null else null
	if identity == null:
		return ""
	var key := String(identity.call(&"key_of", player_id))
	return key if ArenaLoadoutIdentity.is_durable(key) else ""


## Players who are not bots, right now.
func humans() -> int:
	var count := 0
	for id: int in _player_ids():
		if id < BOT_SESSION_BASE:
			count += 1
	return count


func _has_bots() -> bool:
	for id: int in _player_ids():
		if id >= BOT_SESSION_BASE:
			return true
	return false


func _player_ids() -> Array:
	if game == null or not game.has_method(&"player_ids"):
		return []
	return Array(game.call(&"player_ids"))


func _on_killed(entry: Object) -> void:
	if reporter == null:
		return
	var killer_key := String(entry.get(&"killer_key"))
	if killer_key == "" or bool(entry.get(&"suicide")) or bool(entry.get(&"team_kill")):
		return
	var killer := killer_key.to_int()
	var vs_bot := String(entry.get(&"victim_key")).to_int() >= BOT_SESSION_BASE
	report_event(killer, EVENT_KILL, vs_bot)
	if bool(entry.get(&"headshot")):
		report_event(killer, EVENT_HEADSHOT, vs_bot)


## The match node does not survive a map change, so this follows `map_changed` as ArenaProgress does.
func _bind_match(_map: Variant = null) -> void:
	if _match != null and is_instance_valid(_match):
		if _match.is_connected(&"round_ended", _on_round_ended):
			_match.disconnect(&"round_ended", _on_round_ended)
		if _match.is_connected(&"match_ended", _on_match_ended):
			_match.disconnect(&"match_ended", _on_match_ended)
	_match = game.get(&"match_node") if game != null else null
	if _match != null and _match.has_signal(&"round_ended"):
		_match.connect(&"round_ended", _on_round_ended)
		_match.connect(&"match_ended", _on_match_ended)


func _on_round_ended(_round_number: int, winner: int, _outcome: Variant) -> void:
	_report_winners(EVENT_ROUND_WIN, winner)
	# A round is when balances move: read them again so the HUD follows what was earned.
	refresh_all()


func _on_match_ended(winner: int, _outcome: Variant) -> void:
	_report_winners(EVENT_MATCH_WIN, winner)


func _report_winners(event_key: String, winner: int) -> void:
	if reporter == null:
		return
	var vs_bot := _has_bots()
	for id: int in _player_ids():
		if id < BOT_SESSION_BASE and _won(id, winner):
			report_event(id, event_key, vs_bot)


## The same rule as ArenaProgress: the winning side in a team mode, the scoreboard leader otherwise.
func _won(player_id: int, winner: int) -> bool:
	var mode: Variant = game.get(&"mode")
	if mode != null and bool(mode.call(&"is_team_mode")):
		return winner != 0 and int(game.call(&"team_of", player_id)) == winner
	if _match == null:
		return false
	var leader: Variant = _match.get(&"scoreboard").call(&"leader")
	return leader != null and String(leader.get(&"key")) == str(player_id)


# --- Avatars settings ------------------------------------------------------------------

func _loadout_config() -> DotLoadoutConfig:
	var cfg := DotLoadoutConfig.new()
	var loaded := cfg.load_layered(LOADOUT_CONFIG_PATH)
	if not loaded.ok:
		# An unset site key fails validation too; the site part reports that itself.
		DotLog.result(CHANNEL, "the app loadout config", loaded, DotLog.Level.INFO)
	return cfg


func _setup_settings(cfg: Object) -> void:
	var script := ArenaNewerApi.script_of(&"DotLoadoutSiteSettings")
	if script == null:
		_once(&"no_settings", "app avatars settings are off: this build has no DotLoadoutSiteSettings (dot-loadout)")
		return
	if client == null or not client.has_method(&"get_integration"):
		_once(&"settings_no_client", "app avatars settings are off: no backbone client")
		return
	settings = script.call(&"from_config", cfg, client)
	settings.connect(&"section_changed", _on_section_changed)
	if follow_settings and is_inside_tree():
		settings.call(&"follow", get_tree())


func _on_section_changed(section: String, values: Dictionary, _version: int) -> void:
	if section == "avatars":
		apply_avatars(values)


## Applies the app's `avatars` section. `appOnly` forces every side into its team body (the
## `team_avatars` rule, put back when it goes off), and the `team:<name>:a` / `:b` slots bind an
## avatar to each side by its place in the config's `team_bodies`. A slot or an avatar FC has no
## place for is logged once and ignored. Returns the rules it set.
func apply_avatars(values: Dictionary) -> Dictionary:
	var rules := {}
	if bool(values.get("appOnly", false)):
		if not _forced:
			_team_avatars_before = float(game.call(&"rule", "team_avatars"))
			_forced = true
		rules["team_avatars"] = 1.0
	elif _forced:
		_forced = false
		rules["team_avatars"] = _team_avatars_before
	var bound := [-1.0, -1.0]
	var bodies := _body_ids()
	var slots: Variant = values.get("slots", [])
	for slot: Variant in (slots if slots is Array else []):
		if not slot is Dictionary:
			continue
		var slot_key := String(slot.get("slotKey", ""))
		var side := -1
		for i in SIDE_SUFFIXES.size():
			if slot_key.begins_with("team:") and slot_key.ends_with(SIDE_SUFFIXES[i]):
				side = i
		if side < 0:
			_once(StringName("slot:" + slot_key), "app avatar slot FC has no place for; ignored", {"slot": slot_key})
			continue
		var avatar := String(slot.get("avatarId", ""))
		if avatar == "":
			continue
		var at := bodies.find(avatar)
		if at < 0:
			_once(StringName("avatar:" + avatar), "app avatar is not one of FC's team bodies; that side keeps the config order",
				{"slot": slot_key, "avatar": avatar, "team_bodies": ",".join(bodies)})
			continue
		bound[side] = float(at)
	for i in SIDE_RULES.size():
		rules[SIDE_RULES[i]] = bound[i]
	game.call(&"set_movement_rules", rules)
	return rules


func _body_ids() -> PackedStringArray:
	var out := PackedStringArray()
	var config: Variant = game.get(&"config")
	if config == null:
		return out
	for raw in String(config.get(&"team_bodies")).split(","):
		out.append(raw.strip_edges())
	return out


# --- Points and store items ------------------------------------------------------------

func _setup_site(cfg: Object) -> void:
	var script := ArenaNewerApi.script_of(&"DotLoadoutSiteSource")
	if script == null or not script.get_script_method_list().any(
			func(m: Dictionary) -> bool: return m.get("name") == "points_of"):
		_once(&"no_site", "app points on the HUD are off: this build's DotLoadoutSiteSource has no points (dot-loadout)")
		return
	if client == null or not client.has_method(&"get_integration"):
		_once(&"site_no_client", "app points on the HUD are off: no backbone client")
		return
	var made: DotResult = script.call(&"from_config", cfg, client)
	if not made.ok:
		_once(&"site_off", "app points on the HUD are off: no pinned site key (%s site_public_key_path, DOT_LOADOUT_*)" % LOADOUT_CONFIG_PATH,
			{"why": made.error.message})
		return
	use_site(made.value)


## Uses [param source] (a DotLoadoutSiteSource) for points and items. [method setup] calls it; a
## test hands it one with a filled cache.
func use_site(source: RefCounted) -> void:
	site = source
	site.connect(&"refreshed", _on_refreshed)
	site.connect(&"rejected", _on_rejected)


## A player joined: remember their key and read their points and items. Server side.
func player_joined(player_id: int) -> void:
	var key := player_key(player_id)
	if key == "":
		return
	_key_of_id[player_id] = key
	_id_of_key[key] = player_id
	if site != null:
		site.call(&"refresh", key)


## A player left: forget their key and their cached grant. Call before the identity releases them.
func player_left(player_id: int) -> void:
	var key: String = _key_of_id.get(player_id, "")
	_key_of_id.erase(player_id)
	_id_of_key.erase(key)
	if site != null and key != "":
		site.call(&"forget", key)


## Reads every known player's points and items again.
func refresh_all() -> void:
	if site == null:
		return
	for key: String in _id_of_key.keys():
		site.call(&"refresh", key)


func _on_refreshed(key: String) -> void:
	if _id_of_key.has(key):
		apply_player(int(_id_of_key[key]), key)


func _on_rejected(key: String, reason: String) -> void:
	_once(StringName("rejected:" + reason), "the site's grant was refused; app points stay hidden", {"why": reason})
	if not _id_of_key.has(key):
		return
	var player: Object = game.call(&"player_for", int(_id_of_key[key]))
	if player != null:
		player.set(&"app_points_on", false)
		player.set(&"app_points", 0)


## Puts [param key]'s live points and items on player [param player_id]. Returns the items applied.
func apply_player(player_id: int, key: String) -> int:
	var player: Object = game.call(&"player_for", player_id)
	if player == null or site == null:
		return 0
	var points: Dictionary = site.call(&"points_of", key)
	var on := bool(points.get("enabled", false)) and points.get("balance") != null
	player.set(&"app_points_on", on)
	player.set(&"app_points", int(points.get("balance")) if on else 0)
	var applied := 0
	for item: Variant in site.call(&"loadout_of", key):
		if item is Dictionary and apply_item(player, item):
			applied += 1
	return applied


## Applies one equipped store item ({slot, store, key}) where FC has a slot for it. FC declares no
## per-player store slots yet (team bodies are per side, from the settings), so every item is
## logged once and ignored; a slot FC gains is handled here.
func apply_item(_player: Object, item: Dictionary) -> bool:
	var slot := String(item.get("slot", ""))
	_once(StringName("item:%s:%s" % [slot, item.get("key", "")]), "store item for a slot FC does not have; ignored",
		{"slot": slot, "key": str(item.get("key", ""))})
	return false


func _once(id: StringName, message: String, data: Dictionary = {}) -> void:
	if _logged.has(id):
		return
	_logged[id] = true
	DotLog.info(CHANNEL, message, data)
