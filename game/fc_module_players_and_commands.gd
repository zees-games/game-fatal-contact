extends "fc_module_cvars.gd"

const FcBoards := preload("fc_boards.gd")


const FcAmbience := preload("fc_ambience.gd")
## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"
## The workbench kind of the wall-move cvar set (fc_wall*).
const WALL_KIND := "wallmoves"
const SPEED_KIND := "speeds"
const SPEED_CVARS: PackedStringArray = ["fc_speed_scale", "fc_run_speed", "fc_walk_scale", "fc_sprint_scale", "fc_crouch_scale"]
const FcMapConfig := preload("fc_map_config.gd")
const FcIdentity := preload("fc_identity.gd")


const FcBspMap := preload("../maps/fc_bsp_map.gd")


const FcMapDirector := preload("fc_map_director.gd")


const FcNetBridge := preload("fc_net_bridge.gd")
const FcServices := preload("fc_services.gd")
const FcStats := preload("fc_stats.gd")


const FcVote := preload("fc_vote.gd")
const FcContentGroups := preload("fc_content_groups.gd")

## Binds an [FcGame] to a [GSServer].


const CHANNEL := "arena.module"


## gs-combat's cvars (mp_teammate_passthrough), kept to put on each map's new combat manager.
var _combat_cvars: Array = []


var bridge: FcNetBridge = null
## Carries the workbench's profile runtime (rows down) over this manager; null without a workbench.
var profile_link: GSNetProfileLink = null


## Chat, voice and moderation. See [FcServices] for why it is not this file.
var services: FcServices = null

## Per-app customisation from Gamespice: avatars settings, earn events, the HUD balance, store
## items. Every part off until configured (fc_app_wiring.gd); null when it could not be built.
const FcAppWiring := preload("fc_app_wiring.gd")
var app_wiring: Node = null


## Content, profiles, avatars and admission.
var identity: FcIdentity = null


## Maps as content: a catalogue, a rotation, a clock and a change that reaches clients.
var maps: FcMapDirector = null


## The per-map cvars a map's `cfg/.../gs_map/map/<name>.yml` sets, put back on the next map.
var map_config: GSGameMapConfig = null
## The active rotation entry's profile cvars (`GSMapDef.profile.values`), put back on the next map.
var profile_config: Object = null


## What plays next, decided by the players.
var vote: FcVote = null


## gs-server session id -> whether we have put them in the match.
var _joined: Dictionary = {}


## Who is still behind their loading cover, from gs-game's roster used for that alone: this module
## is not on GSGameModule, so it seats people itself and only borrows the bookkeeping (loading from
## the spawn event until the client says its cover lifted, again from a map change).
var loading: GSGameRoster = null
var _handles_cover: bool = false


func _on_player_spawned_for_tools(player: FcPlayer) -> void:
	if services != null and services.mod_tools != null:
		services.mod_tools.respawned(StringName(str(player.player_id)))


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func _rotation_commands() -> Dictionary:
	return maps.rotation_file.commands() if maps != null and maps.rotation_file != null else {}


## `fc_scorelimit`, `fc_timelimit` and `fc_warmup`: the server's numbers over the mode's, live and kept across map changes ([member FcGame.score_limit]). A cvar writes the game's export, which every match built after it reads,
## and the live match through `_apply_match_limits`, because a server's config is applied after this module loads, when the first match is already running.
## Zero, for the two limits, is "the mode's own"; a negative warmup is too.
func _add_match_cvars() -> void:
	add_cvar(
		"fc_scorelimit", str(game.score_limit),
		"Kills to win the match (a side's in a team mode); 0 for the mode's own. Gun game ends at its last gun",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.score_limit = maxi(new_value.to_int(), 0)
			_apply_match_limits()
			log_info("score limit changed", {"score_limit": game.match_node.rules.score_limit})
	)
	add_cvar(
		"fc_timelimit", str(int(game.time_limit_sec)),
		"Seconds a match lasts; 0 for the mode's own",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	).with_min(0.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.time_limit_sec = maxf(new_value.to_float(), 0.0)
			_apply_match_limits()
			log_info("time limit changed", {"time_limit_sec": game.match_node.rules.time_limit_sec})
	)
	add_cvar(
		"fc_warmup", str(game.warmup_sec),
		"Seconds of warmup before a match; -1 for the mode's own",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	).with_min(-1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.warmup_sec = new_value.to_float()
			_apply_match_limits()
			log_info("warmup changed", {"warmup_sec": game.match_node.rules.warmup_sec})
	)
	add_cvar(
		"mp_freezetime", str(game.freeze_sec),
		"Seconds everyone is frozen at their spawn before a round; 0 for none, -1 for the mode's own",
		GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY
	).with_min(-1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			game.freeze_sec = new_value.to_float()
			_apply_match_limits()
			log_info("freeze time changed", {"countdown_sec": game.match_node.rules.countdown_sec})
	)


## Puts the game's limits on the running match and tells every client: MATCH carries the
## score limit the HUD divides by and the clock, which a new time limit has just moved.
func _apply_match_limits() -> void:
	game.apply_match_limits()
	if bridge != null:
		bridge.note_score_limit_changed()


## Puts gs-combat's cvars on the world's current combat manager: after a change, and after a
## map change built a new manager the cvar knows nothing about.
func _reapply_combat_cvars() -> void:
	if game == null or not is_instance_valid(game) or game.combat == null:
		return
	for cv in _combat_cvars:
		if cv is GSConVar and is_instance_valid(cv) and game.combat.has_method(&"set_cvar"):
			var _applied: Variant = game.combat.call(&"set_cvar", (cv as GSConVar).name, (cv as GSConVar).get_string())


## The loading roster and the handler for the client's cover report on gs-server's envelope.
## A kind on the existing envelope because the RPC set is frozen; a client that predates it is
## released by the roster's timeout. Duck-typed so an older gs-server still loads this.
func _build_loading() -> void:
	loading = GSGameRoster.new()
	loading.server = server

	if game != null:
		game.loading_fn = loading.is_loading

	if server == null or not ("envelope" in server):
		return

	var env: Object = server.get(&"envelope")

	if env != null and env.has_method("register"):
		env.call("register", GSGameRoster.COVER_KIND, Callable(self, "_on_cover_report"), false)
		_handles_cover = true


func _on_cover_report(peer_id: int, payload: Dictionary) -> void:
	var covered: Variant = payload.get("covered")

	if loading != null and covered is bool:
		loading.report_cover(peer_id, covered)


## Starts the workbench the server scene built: the config files, noblock and the fc_ambient* cvars as sets.
func _start_workbench() -> void:
	var wb := game.workbench
	if wb == null:
		return
	if game.player_stack != null and game.player_stack.spawn_overrides != null:
		wb.add_set(game.player_stack.spawn_overrides, "Spawn points (per map)")
	var ambient_set := GSGameWorkbench.cvar_set(console, FcAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		wb.add_set(ambient_set, "Ambience (fc_ambient*)")
	var wall_types := {}
	for cvar: String in MOVEMENT_CVARS:
		if cvar.begins_with("fc_wall"):
			wall_types[cvar] = "float"
	var wall_set := GSGameWorkbench.cvar_set(console, wall_types, WALL_KIND)
	if wall_set != null:
		wb.add_set(wall_set, "Wall moves (fc_wall*)")
	var speed_types := {}
	for cvar in SPEED_CVARS:
		speed_types[cvar] = "float"
	var speed_set := GSGameWorkbench.cvar_set(console, speed_types, SPEED_KIND)
	if speed_set != null:
		wb.add_set(speed_set, "Speeds (fc_speed_scale, fc_run_speed, ...)")
	var started := wb.start()
	if not started.ok:
		GSLog.result(CHANNEL, "the workbench", started)
		return
	if wb.api == null:
		return
	var rt := wb.api.runtime as GSProfileRuntime
	if rt == null:
		return
	if game.config_binder != null:
		game.config_binder.attach(rt)
	if game.flashlight_binder != null:
		game.flashlight_binder.attach(rt)
	if ambient_set != null:
		var _applied := GSGameWorkbench.bind_cvar_set(ambient_set, rt, console)
	if wall_set != null:
		var _wall_applied := GSGameWorkbench.bind_cvar_set(wall_set, rt, console)


func _module_unload() -> void:
	if game != null:
		game.tick_gate.disarm()
		var scene := game.get_parent() if is_instance_valid(game) else null
		if scene != null and scene.has_method(&"attach_maps"):
			scene.call(&"attach_maps", null)
	if team_menu != null:
		team_menu.release()
		team_menu = null
	# The link and the runtime hold each other through broadcast.
	if profile_link != null:
		profile_link.release()
		profile_link = null
	if _handles_cover and server != null:
		var env: Object = server.get(&"envelope")

		if env != null and env.has_method("handle"):
			env.call("handle", GSGameRoster.COVER_KIND, Callable())

		_handles_cover = false

	if game != null and is_instance_valid(game):
		game.loading_fn = Callable()

	if loading != null:
		loading.clear()
		loading = null

	if profile_config != null:
		profile_config.call(&"restore")
		profile_config = null

	if map_config != null:
		map_config.restore()
		map_config = null

	if net != null and is_instance_valid(net):
		net.stop()

	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	if game != null and is_instance_valid(game):
		if game.player_killed.is_connected(_on_player_killed):
			game.player_killed.disconnect(_on_player_killed)

		if game.player_spawned.is_connected(_on_player_spawned_for_tools):
			game.player_spawned.disconnect(_on_player_spawned_for_tools)

		for connection in game.map_changed.get_connections():
			var callable: Callable = connection["callable"]
			if callable.get_object() == self:
				game.map_changed.disconnect(callable)

		# Every player this module put in the match comes back out. A module that
		# unloaded and left them there would leave the game holding bodies whose
		# sessions no longer exist, and the next kill would credit a ghost.
		for userid in _joined.keys():
			var session := server.session_by_userid(int(userid)) if server != null else null

			if session != null and bridge != null and is_instance_valid(bridge):
				bridge.remove_peer(session.peer_id)
			else:
				game.remove_player(int(userid))

	_joined.clear()

	# The platform module is loaded by this one and has to go with it. Left behind, it
	# holds admissions for a game that no longer exists and its commands answer about
	# a hub nothing is feeding.
	if server != null and server.modules != null and server.modules.has_module("platform"):
		var unloaded := server.modules.unload_module("platform")
		GSLog.result(CHANNEL, "unloading the platform module", unloaded)


## [b]Admission finishes AFTER a player is seated[/b], so the name and figure they are seated with are a guest's whenever the profile store is slower than the join. `player_admitted` is the moment the real ones exist;
## a new avatar and an operator's `platform_name` are the same thing later. All three end in a JOIN to every client, which a client already applies to a player it has.
func _wire_identity() -> void:
	if bridge == null:
		return

	bridge.avatar_fn = _avatar_for
	if game.progress != null:
		game.progress.session_fn = server.session_by_userid
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what gs-platform resolved for them, or null for the stock
## figure. Through `player_for`, because the hub keys a player by their scoped profile key.
func _avatar_for(session_id: int) -> GSAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session == null or platform == null or not platform.has_method("player_for"):
		return null

	var held: Variant = platform.call("player_for", session)

	if held is Object and (held as Object).get("avatar") is GSAvatar:
		return (held as Object).get("avatar") as GSAvatar

	return null


func _on_profile(event: GSEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null

	if session == null or bridge == null:
		return

	bridge.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## A client finished the signon and is in the world. [b]`client_spawn`, not `client_connected`.[/b] A connected client has a socket and nothing else (no identity, no content, no confirmation it can load the map),
## so adding them to the match there produces a body for someone who may still fail to join.
func _on_client_spawn(event: GSEvent) -> void:
	# [b]`client_spawn` carries `userid` and `name`, not `peer_id`.[/b] Reading `event.get_int("peer_id")` gives 0 on every event, so `session_of(0)` returned null and nobody ever joined a dedicated Fatal Contact server, silently;
	# a null session is legitimate, so nothing errored, and `dedicated.tscn` never connects a client. The family's notes carry this bug, found in game-hungario.
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	# gs-moderation's records, checked here rather than at connect. [b]gs-server has its own ban list and this is not it.[/b] Its mute is two booleans on a session that dies with its connection, so a muted player reconnects and talks;
	# gs-moderation's records are durable, expiring and scoped. Both are consulted: gs-server's admission runs first and this is the second gate.
	if services != null:
		var admitted := services.check_admission(session)

		if not admitted.ok:
			server.kick(session, admitted.error.message)
			return

	_add(session)


func _add(session: GSClientSession) -> void:
	if _joined.has(session.userid):
		return

	# The session id, not the peer id: a peer id is reassigned when someone reconnects, and the scoreboard, combat entity and damage attribution would go to the next player to join. gs-server's userid is stable for the session.
	# Through the bridge, which adds them to the game AND registers them as a replicated entity owned by their peer. `game.add_player` alone gives the server a player nothing is sent about:
	# the manager only builds snapshots and input buffers for peers it knows, so the server would simulate them perfectly and alone.
	game.loadout_identity.bind(session)
	var added := bridge.add_player(
		session.peer_id, session.userid, session.display_name
	)

	if not added.ok:
		log_warn("could not add a player to the match", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true

	var loadouts := GSGameAvatarActionRelay.loadouts_of(net)
	if loadouts != null:
		loadouts.add_peer(session.peer_id)

	if loading != null:
		var _seated := loading.add(session)

	# Chat, voice and map changes, all keyed on the PEER because all three are about a
	# connection rather than about a person: a chat backlog goes to a socket, a voice
	# frame is relayed to a socket, and a map change waits on a socket.
	if services != null:
		services.add_peer(session.peer_id)

	if app_wiring != null:
		app_wiring.call(&"player_joined", session.userid)

	# Not the map sync: that admits the peer when it says READY (`bridge.peer_ready_fn`),
	# because admitting tells it the current map and nothing reaches a client before then.

	log_info("player joined the match", {
		"userid": session.userid, "name": session.display_name
	})


func _on_client_disconnected(session: GSClientSession, _reason: String) -> void:
	if not _joined.has(session.userid):
		return

	# Through the bridge again: it releases the peer's entities, its input buffer and
	# its acknowledgement record as well as taking the player out of the match.
	bridge.remove_peer(session.peer_id)
	_joined.erase(session.userid)
	# Before the identity lets go: the app wiring finds the player's platform key through it.
	if app_wiring != null:
		app_wiring.call(&"player_left", session.userid)
	game.loadout_identity.release(session.userid)

	var loadouts := GSGameAvatarActionRelay.loadouts_of(net)
	if loadouts != null:
		loadouts.remove_peer(session.peer_id)

	if loading != null:
		loading.remove(session)

	if services != null:
		services.remove_peer(session.peer_id)

		# Who they were frozen or noclipped by, and where a bring would return them to.
		# The next player given this userid must not inherit any of it.
		if services.mod_tools != null:
			services.mod_tools.forget(StringName(str(session.userid)))

	if maps != null:
		# Otherwise the next map change waits out its whole timeout for somebody who
		# left — `swap_without_stragglers` saves it, but only after five minutes of
		# everybody standing on a map the vote already replaced.
		maps.remove_peer(session.peer_id)

	if vote != null:
		# Their rock-the-vote and their nominations. `rtv_forgets_leavers` is what
		# decides whether the tally shrinks with them, and it cannot do its job if
		# nothing tells it they went.
		vote.forget_voter(StringName(str(session.userid)))


func _on_player_killed(entry: GSKillFeed.Entry) -> void:
	# The server log, not chat: every client draws the kill feed top-right, so a chat
	# line repeated it. A headless operator still reads kills here.
	log_info("kill", {"line": str(entry)})


## A player typed `!something`. [b]Claimed, or it is broadcast as chat.[/b] gs-chat holds a command until somebody says they handled it;
## an unclaimed one with `broadcast_unknown_commands` off is dropped, so a player typing `!rtv` on a server where the vote failed to load gets silence rather than "there is no vote here".
func _on_chat_command(peer: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer)

	if session == null:
		return

	# [b]The vote's own commands are not here.[/b] `!rtv`, `!nominate`, `!vote`, `!nextmap` and `!timeleft` are gs-vote's, registered on the console by `FcVote.install_commands` with `.with_chat()`, and an unclaimed `!` line carries on to the console.
	# Answering them here as well made two paths to one director, one without `setnextmap`. Only a server whose vote did not load answers them here, so a player gets "no vote" rather than silence.
	if vote == null:
		match command:
			"rtv", "nominate", "vote":
				_reply_chat(peer, "There is no vote on this server.")
				services.claim_command()
				return
			"nextmap":
				_reply_chat(
					peer, "Next: %s" % (maps.next_map_hint() if maps != null else "-")
				)
				services.claim_command()
				return
			"timeleft":
				_reply_chat(peer, _timeleft_line())
				services.claim_command()
				return

	match command:
		"score":
			for line in game.match_node.scoreboard.describe_lines():
				_reply_chat(peer, line)
			services.claim_command()
		"stats":
			for line in _stat_lines(session.userid):
				_reply_chat(peer, line)
			services.claim_command()


func _timeleft_line() -> String:
	if vote != null:
		return vote.director.clock.timeleft_line()

	if maps == null or maps.session == null:
		return "This map has no time limit."

	return maps.session.time_limit.timeleft_line()


func _stat_lines(userid: int) -> PackedStringArray:
	var out := PackedStringArray()

	if game.progress == null:
		out.append("This server keeps no statistics.")
		return out

	var values := game.progress.session_values(userid)

	out.append("This session: %d kills, %d deaths, %.0f%% accuracy" % [
		int(values.get_value(FcStats.KILLS, 0.0)),
		int(values.get_value(FcStats.DEATHS, 0.0)),
		FcStats.accuracy_of(values) * 100.0,
	])
	out.append("Achievement points: %d" % game.progress.points_of(userid))

	return out


func _reply_chat(peer: int, text: String) -> void:
	if services != null:
		services.notice(peer, text)
		return

	var session := server.session_of(peer)

	if session != null and server.chat != null:
		server.chat.send_system_to(session, text)


## The map changed, whatever caused it: a vote, a rotation, or an admin typing it. [b]This is the one call site that tells the vote what is running, and having two is the bug.[/b]
## `GSVoteDirector.begin_on_apply` is off so this signal is the only source: it fires for an operator's `map` as well as a voted change,
## and both firing means two play-history entries for one play, a "not in the last five" cooldown that is quietly two or three.
func _on_map_changed(map: GSMapDef) -> void:
	# The profile's cvars went on last, so they come off first: a key both set gets the file's value back right.
	if profile_config == null and console != null:
		profile_config = FcMapConfig.build_profile(console)
	if profile_config != null:
		profile_config.call(&"restore")
	if map_config == null and console != null:
		map_config = FcMapConfig.build(console)
	if map_config != null:
		map_config.apply(String(map.id))
	if profile_config != null:
		FcMapConfig.apply_profile(profile_config, console, map)
	_follow_mode()

	# Every client covers for the new map and says so when it lifts; until it does nobody is
	# harmed, and one that never re-covers is released after the roster's grace.
	if loading != null:
		loading.mark_reloading()

	if vote != null:
		vote.note_changed()

	# [b]Every `return` point is a place on the map that just went.[/b] GSModTools keeps a stack of positions per player; without this `return Ada` after a change put her where she had stood on the previous map,
	# inside whatever the new one has there (`[modtools-return-1]`; Playlot, hungario and the lobby do the same).
	if services != null and services.mod_tools != null:
		services.mod_tools.clear_history()

	if services != null:
		services.announce("Now playing %s." % map.name_or_id())

	_report_map(String(map.id))
	_attach_visibility(map)

	log_info("map changed", {"map": String(map.id)})


## The `fc_mode` cvar shows what is played after a rotation profile changed the mode; overridden where the cvar lives.
func _follow_mode() -> void:
	pass


## The converted world's PVS as the snapshot visibility (cvar net_visibility); a built-in map clears it.
## [param map] is untyped: FcMap is not a GSMapDef subclass (as in arena_map_io).
func _attach_visibility(map) -> void:
	if game != null:
		game.set_meta(FcBotPvs.META, null)
	if net == null or map == null or GSAddonApi.build_level("gs_game") < 52:
		return
	var mesh: Object = null
	if map.has_method(&"is_imported") and map.is_imported():
		var prefix := FcBspMap.world_prefix(String(map.id), String(map.manifest_path).get_base_dir())
		var got: GSResult = GSMapBspMesh.load_prefix(prefix) if not prefix.is_empty() else null
		mesh = got.value if got != null and got.ok else null
	var on: bool = (GSGameNetcode as GDScript).call(&"attach_visibility", net, mesh)
	# The same set before each bot sight ray (FcBotPvs, cvar `fc_bot_pvs`): the bots' world has the game, not the netcode.
	if game != null and on:
		game.set_meta(FcBotPvs.META, net.interest.get(&"visibility"))
	log_info("snapshot visibility", {"map": String(map.id), "in_force": on})


## Tells gs-server which map this is, so A2S and DQP print it in their map field (and
## the backbone report does too) rather than this game's content id.
func _report_map(map_id: String) -> void:
	if server == null or server.games == null:
		return
	# gs-server 19 sends the map's download group to joining clients with the pack's own groups.
	# By name, so a build with an older gs-server still parses this file.
	if GSAddonApi.build_level("gs_server") >= 19:
		server.games.call(&"set_current_map", map_id, FcContentGroups.groups_for(StringName(map_id)))
	else:
		server.games.set_current_map(map_id)


## The map's clock ran out. The director deliberately does not act on it: on a server with a vote the answer is "open the ballot" and on one without it is "next in rotation",
## and only this file knows which this server is.
func _on_map_over(_map: GSMapDef, reason: StringName) -> void:
	if vote != null:
		var opened := vote.director.open_vote(reason)

		if opened.ok:
			return

		log_info("the map is over and a vote could not open", {
			"why": opened.error.message
		})

	if maps != null:
		var changed: GSResult = await maps.change_to_next(game.players().size())
		GSLog.result(CHANNEL, "changing to the next map", changed)


## The commands that only exist once the optional halves loaded. Registered after them rather than beside the others,
## because a command that reports on a subsystem that failed to load can only answer "that is not running", and an operator reading the command list should see what this server has.
func _add_extra_commands() -> void:
	if maps != null:
		add_command(
			"fc_nextmap", _cmd_nextmap, "What plays next", ""
		)

		# `map`, `maps` and `mapinfo` come from gs-map itself (gs-server's `map` changed the GAME, which is not what an operator typing `map` means); gs-server's game change is `changelevel`, `game` and `gamechange`.
		# The map change is gs-map's `map` (CHANGEMAP, like Airdrift's): a map change ends every round in progress, which is about who may do it, not where they typed it. `sv_chat_commands 0` makes it console-only.
		# `allow_chat_change` stays at its default, ON: CHANGEMAP decides who may end a round in progress, wherever typed. A relayed website command arrives as `Source.CHAT`;
		# `GSChatRelayConfig.command_source` can promote a relay to RCON. The SYNC HOST is the changer, not the session: `FcMapDirector.session` alone swaps the world in this process and tells nobody.
		var map_commands := GSMapCommands.new()
		map_commands.session = maps.session
		map_commands.changer = maps.sync
		map_commands.player_count_fn = func() -> int:
			return game.players().size() if game != null else 0
		map_commands.rotation_file_fn = func() -> GSMapRotationFile:
			return maps.rotation_file if maps != null else null
		map_commands.spec_fn = _rotation_commands
		map_commands.bind(self)

		# FC's own name for the same change: `fc_map <id>` runs `map <id>` with the caller's context, so it is the same
		# sync-host change (map_changed: map config, profile, vote, report) under the same changemap flag, not a second path.
		add_command(
			"fc_map", _cmd_fc_map, "Change the map (the same as map): fc_map <id>", GSAdminFlags.CHANGEMAP
		)

	if vote != null:
		add_command(
			"fc_vote", _cmd_vote, "Open a vote now", GSAdminFlags.VOTE
		)

		var commanded := vote.install_commands(self)
		GSLog.result(CHANNEL, "the vote's commands", commanded)

	if services != null:
		add_command(
			"fc_services", _cmd_services,
			"Show chat, voice and moderation", GSAdminFlags.GENERIC
		)

	if identity != null:
		add_command(
			"fc_identity", _cmd_identity,
			"Show the platform layer", GSAdminFlags.GENERIC
		)

	if game.progress != null:
		add_command(
			"fc_boards", _cmd_boards, "Show a leaderboard: fc_boards [id]", ""
		)

	if game.horde != null:
		add_command(
			"fc_horde", _cmd_horde,
			"Show or clear the monsters: fc_horde [clear]", GSAdminFlags.GENERIC
		)


func _cmd_fc_map(ctx: GSCmdContext) -> void:
	var line := "map"
	for arg: String in ctx.args:
		line += " " + (arg if not (arg.contains(" ") or arg.contains(";") or arg.is_empty()) else "\"%s\"" % arg)
	var _ran := server.console.execute(line, ctx)


func _cmd_nextmap(ctx: GSCmdContext) -> void:
	ctx.reply("Next: %s" % maps.next_map_hint())
	ctx.reply(_timeleft_line())


func _cmd_vote(ctx: GSCmdContext) -> void:
	var opened := vote.director.open_vote(GSVoteClock.REASON_MANUAL)
	ctx.reply("Vote opened." if opened.ok else opened.error.message)


func _cmd_services(ctx: GSCmdContext) -> void:
	for line in services.describe_lines():
		ctx.reply(line)


func _cmd_identity(ctx: GSCmdContext) -> void:
	for line in identity.describe_lines():
		ctx.reply(line)


func _cmd_boards(ctx: GSCmdContext) -> void:
	# A remote board takes a moment; say so rather than leave the console silent.
	if game.progress.boards.backend == "backbone":
		ctx.reply("Fetching the board...")

	var board_id: StringName = (
		StringName(ctx.args[0]) if not ctx.args.is_empty() else FcBoards.KILLS
	)
	var scope := FcBoards.scope_for(game.mode.id if game.mode != null else &"ffa")
	var page := await game.progress.boards.page_async(board_id, scope, 0, 10)

	if not page.ok:
		ctx.reply(page.error.message)
		return

	var board := game.progress.boards.board_for(board_id, scope)
	var rank := 0

	for entry in (page.value as Array):
		rank += 1
		ctx.reply("%2d. %-20s %s" % [
			rank,
			(entry as GSLeaderboardEntry).player_name,
			board.format_value((entry as GSLeaderboardEntry).value),
		])

	if rank == 0:
		ctx.reply("Nobody is on that board yet.")


func _cmd_horde(ctx: GSCmdContext) -> void:
	if not ctx.args.is_empty() and ctx.args[0] == "clear":
		ctx.reply("Removed %d monster(s)." % game.horde.clear())
		return

	for line in game.horde.describe_lines():
		ctx.reply(line)
