extends "fc_client_warm_rest.gd"

## A drawing client's share of a frame for the server's events; the join backlog spreads over frames.
const EVENT_BUDGET_USEC := 8000

## Microseconds of events the networked client handles in a frame (the join backlog, then the arming, wait their turn
## across frames). The setting `event_budget_usec` or the launch option `--cl_event_budget_usec` sets it; 0 is no
## budget (everything on arrival, the arming in the adopting frame). Unset: 8000 in a client that draws, 0 headless.
func _event_budget_usec() -> int:
	var launched := FcFrameProbe.launch_value("cl_event_budget_usec")
	if launched.is_valid_int():
		return maxi(0, launched.to_int())
	var fallback := EVENT_BUDGET_USEC if _builds_in_frames() else 0
	if presentation != null and presentation.settings != null:
		return maxi(0, presentation.settings.get_int(&"event_budget_usec", fallback))
	return fallback

## Set by an offline start that builds in frames: [method _adopt] leaves the arming (and the loadout
## restore, which equips into the armed rig) to it, so the arming gets frames of its own.
var _arm_after_adopt := false

## [method _arm] for a client that joined a match, a frame between its parts and the loadout restore (which equips
## into the armed rig) after them. No [method _setup_frame]: this runs in play, where polling must not stop.
func _arm_adopted_in_frames(body: FcPlayer) -> void:
	if not _arm_begin(body):
		return
	await get_tree().process_frame
	if not is_instance_valid(body) or view_model == null:
		return
	_arm_mount(body)
	await get_tree().process_frame
	if not is_instance_valid(body):
		return
	_arm_rig(body)
	_arm_end(body)
	await get_tree().process_frame
	await _restore_loadout()

## How long the cover waits for the local player's first server state before it lets go anyway.
const FIRST_STATE_LIMIT_SEC := 8.0

## A joined client's own player is alive at the map origin until the server's first state moves it to its spawn, so
## the eye was drawn there and teleported ~18 m about 2 s after join (nightly fc-native-via-gs-app-1). The load gate's
## cover stays up until that state arrives. An offline game has no net behaviour and no wait.
func _hold_for_first_state(body: FcPlayer) -> void:
	var net := body.get_node_or_null("Net")
	if net == null or int(net.get("last_state_tick")) >= 0 or gate == null:
		return
	gate.hold(&"first_state", "Joining the match")
	var release := func() -> void:
		if gate != null and gate.is_holding(&"first_state"):
			gate.release(&"first_state")
	net.connect(&"first_state_applied", release, CONNECT_ONE_SHOT)
	get_tree().create_timer(FIRST_STATE_LIMIT_SEC).timeout.connect(release)

func _adopt(candidate: FcPlayer) -> void:
	if candidate == null or player != null:
		return

	player = candidate
	_hear_beacon(player)
	# The player's own field of view, capped by whatever the server clamped it to. A
	# server capping it is a legitimate competitive rule; the player's *choice* is what is
	# saved, so leaving the server gives it back rather than editing their settings.
	player.attach_camera(_field_of_view())
	_guard_camera(player)
	_hold_for_first_state(player)
	if presentation != null:
		presentation.bind_camera_motion(player)
	var spread := not _arm_after_adopt and _builds_in_frames() and bridge != null and bridge.event_budget_usec > 0
	if spread:
		# A joined client's arming (view model, arms, rig) was ~100 ms of the frame that delivered the join backlog.
		_arm_adopted_in_frames(player)
	elif not _arm_after_adopt:
		_arm(player)

	if hud != null:
		hud.follow(player)
		if board != null:
			board.follow(str(player.player_id) if "player_id" in player else "")

	if _sampler != null:
		_sampler.tunables = player.controller.tunables
		# A different tunables object, carrying the default sensitivity again.
		if presentation != null:
			presentation.bind_look(_sampler.tunables)

		# [b]A spawn faces the way its mapper faced it, and the look is the sampler's.[/b]
		# `GSFpsController.teleport` turns the controller's OWN sampler, and this client samples
		# with its own.
		player.spawned.connect(func(at: Transform3D) -> void:
			if FcLoadTimeline.seen("death"):
				FcLoadTimeline.first_use("respawn")
			if _sampler != null:
				_sampler.look_at_angles(rad_to_deg(at.basis.get_euler().y), 0.0)
		)

	_hear_the_local_player()
	if not _arm_after_adopt and not spread:
		_restore_loadout.call_deferred()
	gate.freeze(player)

	# Logged because this is the moment everything a person can see comes into existence — the
	# camera, the HUD's subject and every key below the `player == null` guard.
	GSLog.info(CHANNEL, "following the local player", {
		"id": player.player_id,
		"name": player.display_name,
		"health": player.health.health if player.health != null else -1.0,
		"alive": player.is_alive(),
	})

# --- Following the local player --------------------------------------------

## Follows a player: the camera, the HUD, and everything the keys act on.
func _watch(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.player_for(session_id))

func _on_hello(info: Dictionary) -> void:
	_watch(int(info["session_id"]))

	if hud != null:
		hud.notice("Connected to %s" % String(info["map_name"]))

func _in_match_end() -> bool:
	return game != null and game.match_node != null and game.match_node.state == GSMatch.State.MATCH_END

## The scoreboard up, and the MVP named: best score, then kills. Client side.
func _show_match_summary() -> void:
	var ranked := game.match_node.scoreboard.ranked() if game.match_node.scoreboard != null else []
	if hud != null and not ranked.is_empty():
		var best: GSPlayerScore = ranked[0]
		hud.notice(FcMatchText.mvp_notice(best))
	if game_menu != null and not game_menu.any_open():
		game_menu.scoreboard.open()
		_summary_board_open = true

func _on_reveal_finished(_skipped: bool) -> void:
	for n: Variant in _reveal_hid:
		if is_instance_valid(n):
			(n as Object).set(&"visible", _reveal_hid[n])
	_reveal_hid.clear()
	if _in_match_end():
		_show_match_summary()

## The podium is built at the first match end, not at start: about 22 nodes nobody sees before then.
func _ensure_winner_reveal() -> void:
	if winner_reveal != null:
		return
	winner_reveal = GSWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = FcKillcamBodies.SKIP_ACTIONS
	if not winner_reveal.finished.is_connected(_on_reveal_finished):
		winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)

## The winner named and the top three on a podium, after the killcam and before the scoreboard.
func _reveal_winner() -> void:
	if not _in_match_end():
		return
	var ranked: Array = game.match_node.scoreboard.ranked() if game.match_node.scoreboard != null else []
	if ranked.is_empty():
		_show_match_summary()
		return
	# Without a killcam there is no podium to build: a bare client keeps the summary notice.
	if killcam != null:
		_ensure_winner_reveal()
	if winner_reveal == null:
		_show_match_summary()
		return
	var entries := FcMatchText.reveal_entries(ranked)
	var team := game.mode != null and game.mode.is_team_mode()
	winner_reveal.reduced_motion = presentation != null and presentation.settings != null \
		and presentation.settings.get_bool(&"reduce_motion", false)
	var shown := winner_reveal.present(entries, {"title": "MATCH MVP" if team else "WINNER",
		"hint": "Jump or Fire to skip"})
	if not shown.ok:
		_show_match_summary()
		return
	for n: Variant in [hud, view_model]:
		if n is Object and is_instance_valid(n) and not _reveal_hid.has(n):
			_reveal_hid[n] = bool((n as Object).get(&"visible"))
			(n as Object).set(&"visible", false)

## The match ended: the final killcam if there is a kill to show, then the summary.
func _begin_match_end() -> void:
	if killcam == null:
		_reveal_winner()
	elif killcam.match_ended():
		GSLog.debug(CHANNEL, "the summary waits for the final killcam")

## The server's match state, put where the HUD already reads it.
##
## [b]The client's own `GSMatch` never runs.[/b] Nothing ticks it, it has no spawn
## points and its scoreboard is fed by replication, so every value on it is whatever it
## was constructed with — and `FcHud` reads `match_node.state` and
## `seconds_remaining()` directly. Before this, a connected browser client showed
## "IDLE" for ever while the server was playing a round: not a stale value, a value
## nothing had ever written.
##
## Written onto the node rather than into a parallel copy so the HUD stays one code
## path. A HUD that read one field on a server and another on a client would be two
## HUDs, and only one of them would ever be looked at.
func _on_match(info: Dictionary) -> void:
	if game == null or game.match_node == null:
		return

	var was := game.match_node.state
	game.match_node.state = int(info["state"]) as GSMatch.State
	game.match_node.round_number = int(info["round"])

	# The end of the match: the scoreboard comes up by itself, and the notice line names
	# the most valuable player, which is the summary the genre shows between matches.
	if game.match_node.state == GSMatch.State.MATCH_END and was != GSMatch.State.MATCH_END:
		_begin_match_end()
	elif was == GSMatch.State.MATCH_END and game.match_node.state != GSMatch.State.MATCH_END:
		if killcam != null:
			killcam.skip()
		if winner_reveal != null:
			winner_reveal.skip()
	# The summary board came up by itself, so nothing is holding Tab to close it: it goes
	# when the next match begins, else it covers the whole of the next round.
	if was == GSMatch.State.MATCH_END and game.match_node.state != GSMatch.State.MATCH_END and _summary_board_open:
		_summary_board_open = false
		if game_menu != null:
			game_menu.scoreboard.close()

	# What the HUD's "24 / 35" divides by. This match's rules are its own copy
	# (`FcGame` duplicates the mode's), so writing them touches nothing shared.
	if info.has("score_limit") and game.match_node.rules != null:
		game.match_node.rules.score_limit = int(info["score_limit"])

	# Ticks, divided by OUR rate — which HELLO set to the server's, so the two agree.
	# Sending seconds instead would have been a number derived from the sender's rate
	# and read as though it were derived from the receiver's.
	var ticks := int(info["remaining_ticks"])
	_match_seconds_remaining = (
		-1.0 if ticks < 0 else float(ticks) / float(maxi(game.tick_rate, 1))
	)

	if hud != null:
		hud.remaining_override = _match_seconds_remaining

# --- Offline ---------------------------------------------------------------

func _build_netcode() -> GSResult:
	# The server's `mp_teammate_passthrough` through the link (FcGame.follow_server_cvars).
	if link != null:
		var _following := game.follow_server_cvars(link)
		platform.map_config_game = "game-fatal-contact"
		GSLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "block_side")))
		game.noblock = platform.noblock

	net = GSNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var config := _client_net_config()
	net.config = config
	add_child(net)
	var started := net.setup()
	if not started.ok:
		return started
	FcLoadTimeline.mark("netcode: manager set up")

	bridge = FcNetBridge.new()
	bridge.name = "Bridge"
	bridge.event_budget_usec = _event_budget_usec()
	add_child(bridge)

	var attached := bridge.attach(game, net)
	if not attached.ok:
		return attached
	FcLoadTimeline.mark("netcode: bridge attached")

	# Under the link, and NAMED the same as the server's — the name is the routing.
	bridge.open_link(link)
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	GSLog.result(CHANNEL, "avatar action message", GSGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame and the profile rows.
	_workbench_remote = GSGameWorkbenchRemoteClient.attach(net)
	_profile_runtime = GSProfileRuntime.new()
	_profile_link = GSNetProfileLink.attach(net, _profile_runtime)
	net.messages.seal()
	FcLoadTimeline.mark("netcode: messages sealed")

	# The client halves, built here because each needs the bridge.
	extras = (load(FcPaths.rebase(FC_CLIENT_EXTRAS)) as GDScript).new()
	extras.name = "Extras"
	add_child(extras)

	var extra: GSResult = extras.attach(bridge, game)
	GSLog.result(CHANNEL, "the client's chat, voice and map layers", extra)
	FcLoadTimeline.mark("netcode: extras attached")
	_install_profiler_context()
	platform.look_voice = extras.voice
	platform.look_chat = extras.chat
	platform.look_gag_action = FcBindings.VOICE_GAG
	platform.look_mute_action = FcBindings.VOICE_MUTE
	platform.look_position_fn = _look_position
	platform.build_look_mute()

	# A map that cannot be had must not leave the cover up forever: let the hold go.
	if extras.maps != null:
		extras.maps.fetch_failed.connect(func(_map: GSMapDef, _error: GSError) -> void:
			gate.release(&"map"))
		extras.maps.change_aborted.connect(func(_id: StringName, _reason: String) -> void:
			gate.release(&"map"))
	elif _level_map == null and not _level_busy:
		# No map sync, so no announcement will draw the level: draw the one the game was set up on.
		_enter_level.call(true)
	else:
		gate.release(&"map")

	extras.said.connect(_on_said)
	# What the server says is carrying chat decides whether the box is drawn when the setting is `auto`.
	extras.chat_relay_changed.connect(func(relayed: bool) -> void:
		if presentation != null:
			presentation.set_chat_relayed(relayed)
	)

	# Chat arrives on `GSClientLink.chat_received`, not on anything gs-chat owns; unconnected
	# the client's GSChatClient is a history nothing feeds.
	if link != null and link.has_signal("chat_received"):
		link.connect("chat_received", extras.receive_wire)
	extras.map_changing.connect(_on_map_changing)
	extras.map_changed.connect(_on_map_changed)

	_connect_bridge_events()

	# The one thing that writes an RTT sample: without it the input lead omits flight time
	# and past ~30 ms every command arrives late.
	if link != null:
		bridge.rtt_source = func() -> float: return FcNetBridge.link_rtt_ms(link)
	# READY only once the scene exists, or what the server sent in between hits a missing node.
	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_announce()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _announce, CONNECT_ONE_SHOT)

	FcLoadTimeline.mark("netcode: wired")
	return net.start()


## The client's netcode settings: the server's rates, prediction on, rewinding left to the server.
func _client_net_config() -> GSNetConfig:
	var config := GSNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = FcGame.snapshot_rate_for(game.tick_rate)
	config.interpolation_buffer = FcGame.client_interp_buffer(config.snapshot_rate)
	config.enable_prediction = true
	config.enable_lag_compensation = false  # rewinding is a server's job
	config.max_entities_per_snapshot = 0
	# From the game: a quantised position decoded against the wrong range is a different position.
	config.world_extent = FcGame.NET_WORLD_EXTENT
	# A shorter ease back onto the blend the server rewinds to (FcGame.CLIENT_RESUME_EASE_SEC).
	config.resume_ease_sec = FcGame.CLIENT_RESUME_EASE_SEC
	# By name, as a pack runs on whatever gs-net its shell carries (docs/netcode.md, "A frame's cost").
	if &"reconcile_once_per_frame" in config:
		config.set(&"reconcile_once_per_frame", FcFrameProbe.launch_value("cl_reconcile_per_snapshot") != "1")
	# And no replay when the snapshot matches the prediction; `cl_replay_always 1` replays every one.
	if &"skip_matching_replays" in config:
		config.set(&"skip_matching_replays", FcFrameProbe.launch_value("cl_replay_always") != "1")
	# And no rewrite of a remote whose drawn values match last frame's (a player standing still):
	# every FC `_net_interpolated` only copies net_* onto the node. `cl_interp_always 1` writes every frame.
	if &"skip_settled_interp" in config:
		config.set(&"skip_settled_interp", FcFrameProbe.launch_value("cl_interp_always") != "1")
	# And remote samples kept only in gs-sim's interpolator, fed straight from the native snapshot decode (no GDScript track per
	# entity); every FC read goes through GSNetInterpolator.track_samples. `cl_interp_script_tracks 1` keeps the GDScript tracks.
	if &"sim_interp_tracks_only" in config:
		config.set(&"sim_interp_tracks_only", FcFrameProbe.launch_value("cl_interp_script_tracks") != "1")
	return config


## What the bridge relays from the wire, onto the handlers that draw it.
func _connect_bridge_events() -> void:
	bridge.hello_received.connect(_on_hello)
	bridge.notice_received.connect(_on_notice)
	bridge.vote_received.connect(_on_vote)
	bridge.kill_received.connect(_on_kill)
	bridge.hit_received.connect(_on_hit)
	bridge.killview_received.connect(_on_killview)
	bridge.award_received.connect(_on_award)
	bridge.stomp_received.connect(_on_stomp)
	bridge.grenade_fx_received.connect(_on_grenade_fx)
	bridge.match_received.connect(_on_match)


## READY, and the field of view setting the kill view of a victim of mine draws through.
func _announce() -> void:
	_say_ready()
	send_field_of_view()


## Tells the server the field of view setting.
func send_field_of_view() -> void:
	if bridge != null and not _offline:
		bridge.send_request(FcEvents.Ask.FOV, FcEvents.write_fov(_field_of_view()))

func _build_killview() -> void:
	killview = GSKillViewClient.new()
	killview.name = "KillView"
	add_child(killview)
	killview.setup(game.killview_rules)
	killview.hide_fn = func() -> Array: return [hud, view_model]
	killview.stage = killcam
	_pov_spares.append(KillPovView.mount(self, game, killview, "KillViewScreen", not _builds_in_frames()))
	killview.respawn_requested.connect(func() -> void:
		if bridge != null:
			bridge.send_request(FcEvents.Ask.RESPAWN)
		elif solo_killview != null:
			var _skipped := solo_killview.skip())
	if _offline and game.killview_rules.enabled:
		solo_killview = GSKillViewSolo.new(game.make_killview_server())
		solo_killview.local_id_fn = func() -> Variant: return player.player_id if player != null else null
		solo_killview.tick_fn = game.current_tick
		solo_killview.deliver_fn = _on_killview

func _build_killcam() -> void:
	killcam = GSKillcamHost.new()
	killcam_shots = FcKillcamShots.new()
	killcam_shots.parent = self
	FcKillcamBodies.configure(killcam, func() -> Variant: return ragdolls, killcam_shots)
	killcam.name = "FinalKillcam"
	killcam.rules = game.killview_rules if game != null else null
	killcam.players_fn = func() -> Array: return game.players() if game != null else []
	killcam.player_for_fn = func(id: int) -> Variant: return game.player_for(id) if game != null else null
	killcam.seconds_fn = func() -> float: return game.rule("killcam") if game != null else 0.0
	killcam.camera_mode_fn = func() -> int: return game.killview_rules.camera if game != null else GSKillViewRules.Camera.EYE
	killcam.weapon_name_fn = func(id: String) -> String:
		var def: GSWeaponDef = FcPlayer.weapon_catalogue().get_def(StringName(id)) if id != "" else null
		return def.display_name if def != null and def.display_name != "" else id.capitalize()
	killcam.weapon_icon_fn = func(id: String) -> Texture2D:
		return FcWeaponIcons.shared.menu_texture(StringName(id))
	_pov_spares.append(KillPovView.mount(self, game, killcam, "KillcamScreen", not _builds_in_frames()))
	killcam.over.connect(func(_skipped: bool) -> void: _reveal_winner())
	add_child(killcam)
	_scale_killcam_events()

## The kills the killcam buffer keeps, grown with the players: gs-replay's default 64 is a few
## seconds of kills at 128 bots, and a kill evicted before its view starts plays no bodies at all.
## A player dies at most a few times in the window, so this bounds what the window can hold.
func _scale_killcam_events() -> void:
	if killcam == null or game == null:
		return
	var wanted := game.players().size() * killcam_events_per_player
	killcam.buffer.max_events = maxi(killcam.buffer.max_events, wanted)

## A player exists. Ours is one of them; the rest need something to be seen as. [b]`player_added`,
## not `player_spawned`.[/b] `player_spawned` comes out of gs-match's respawn queue, which runs on
## the AUTHORITY — a mirroring client never fires it, so a client waiting on it waits for ever.
func _on_player_added(added: FcPlayer) -> void:
	if added == null:
		return
	_scale_killcam_events()

	_hear_beacon(added)

	if player == null and added.player_id == _watch_id:
		_adopt(added)
		return

	# Offline this game ticks everybody, and nothing but a tick moves a bot's node: its body
	# is drawn between ticks by the player itself (`FcPlayer.interpolate_body`). A mirror's
	# node is moved once a frame by gs-net's interpolator instead.
	if added != player:
		added.interpolate_body = _offline

	if added == player:
		return
	if added.body_mesh == null and _builds_in_frames():
		_queue_body(added)
		return
	if added.body_mesh == null:
		_attach_stock_body(added)
	_share_shots_of(added)

## Their guns' reports go through the presentation's one shot player, not one built per shooter.
func _share_shots_of(added: FcPlayer) -> void:
	if presentation != null and added.held != null:
		presentation.share_shots(added.held)
		# After the presentation's own handler, so the report it sets is the one wrapped.
		if not added.held.child_entered_tree.is_connected(_wrap_suppressed_child):
			added.held.child_entered_tree.connect(_wrap_suppressed_child)


func _wrap_suppressed_child(child: Node) -> void:
	if child is AwShotFx:
		_wrap_suppressed(child as AwShotFx)

## The players whose stock bodies are not built yet, oldest first (see [method _queue_body]).
var _bodies_due: Array[FcPlayer] = []

## Builds [param added]'s stock body in a later frame. A body is about 4 ms on staging02 and a sim host's
## 31 bots all arrive in one frame (130 ms of bodies on top of arming), so they are built a budget a frame
## instead, behind a `bodies` hold while the gate is still closed.
func _queue_body(added: FcPlayer) -> void:
	_bodies_due.append(added)
	if _bodies_due.size() > 1:
		return
	if gate != null and not gate.is_open():
		gate.hold(&"bodies", "Dressing the players")
	_build_due_bodies()

## Drains [member _bodies_due], at most [constant BODY_BUDGET_MS] of bodies a frame.
func _build_due_bodies() -> void:
	var slice := GSFrameSlice.new(BODY_BUDGET_MS)
	await slice.pause()
	while not _bodies_due.is_empty():
		var next: FcPlayer = _bodies_due.pop_front()
		if not is_instance_valid(next) or next == player:
			continue
		if next.body_mesh == null:
			_attach_stock_body(next)
		_share_shots_of(next)
		if slice.due() and not _bodies_due.is_empty():
			await slice.pause()
	# The replay builds the player's own body at its first frame (7 ms); build it hidden now, after the bots, in a slice of its own.
	if is_instance_valid(player) and player.body_mesh == null:
		await slice.pause()
		if is_instance_valid(player):
			FcKillcamBodies.prewarm_body(player)
	if gate != null and gate.is_holding(&"bodies"):
		gate.release(&"bodies")

## Milliseconds of stock bodies a frame (see [method _queue_body]).
const BODY_BUDGET_MS := 12
## Milliseconds of offline bots added a frame at a solo start (each is ~4 ms with its body).
const OFFLINE_BOT_BUDGET_MS := 8
## Kill events the killcam keeps per player (see [method _scale_killcam_events]); a tool may raise it.
static var killcam_events_per_player := 4

## A stock avatar until the server says otherwise.
func _attach_stock_body(added: FcPlayer) -> void:
	added.attach_body_mesh(
		Color.from_hsv(fmod(float(added.player_id) * 0.37, 1.0), 0.55, 0.85),
		added.avatar if added.avatar != null else FcAvatars.stock_avatar(
			StringName(FcGame.storage_key(added.player_id))
		)
	)

# --- Networked -------------------------------------------------------------

## Joins the chat box to the two things it needs: a way out, and a way to stop the player.
##
## [b]The sampler is the half that is easy to forget.[/b] `swallows_input` keeps typed keys
## out of `_unhandled_input`, but movement here is POLLED — `GSFpsSampler.sample` reads
## the device every physics frame and does not care what consumed an event. Without
## `suspended`, typing "sw" walks you backwards off whatever you were standing on.
## `GSFpsSampler.suspended` is documented "for a chat box or a menu" and until now
## nothing in this game had ever set it.
func _wire_chat_window() -> void:
	var window: GSChatWindow = presentation.chat_window if presentation != null else null

	if window == null:
		return

	window.submitted.connect(_on_chat_submitted)

## Settings, audio, effects and the console.
func _build_presentation() -> void:
	presentation = FcPresentation.new()
	presentation.name = "Presentation"
	presentation.client = self
	add_child(presentation)
	GSLog.result(CHANNEL, "the presentation layer", presentation.setup())
	if presentation.blood != null and game != null:
		presentation.blood.mask = game.ragdoll_rules.collision_mask
	# on_map(id) alone then finds a map definition's `meta.ambient` (or `meta.doc`).
	if presentation.ambient != null:
		presentation.ambient.map_lookup = func(id: StringName) -> Variant:
			if _menu_catalogue == null:
				_menu_catalogue = FcMaps.catalogue()
			return _menu_catalogue.get_map(id)

	_wire_chat_window()

	presentation.settings.changed.connect(func(key: StringName, _v: Variant, _w: StringName) -> void:
		# The field of view is the one setting that has to reach something already built.
		# A camera that keeps the value it was created with is exactly the "produced
		# correctly and consumed by nothing" this family keeps finding.
		if key == &"field_of_view" and player != null:
			player.attach_camera(_field_of_view())
		if key == &"field_of_view":
			send_field_of_view()
	)

# --- The mouse -------------------------------------------------------------

## Whether the cursor may be captured at load-in. A native window that is not focused (a game launched by the app shell while the shell keeps focus) must not capture: the OS recentres a captured cursor the player is not driving,
## and the stream of garbage motion became random yaw and pitch (nightly fc-native-via-gs-app-1). It waits for a click instead, like a browser.
static func mouse_capture_now(is_web: bool, window_focused: bool) -> bool:
	return not is_web and window_focused


## Asks a browser for the cursor rather than telling it. Pointer lock needs **transient user
## activation** — a real click — and `_ready()` is the one moment guaranteed not to have one.
func _grab_mouse() -> void:
	if mouse_capture_now(GSPlatform.is_web(), DisplayServer.window_is_focused()):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_awaiting_click = true

	if hud != null:
		hud.notice("Click to play")


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote).
func _start_remote_workbench() -> void:
	if _workbench_remote == null:
		return
	var wb := GSGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = _workbench_remote
	wb.remote_fn = func() -> bool: return true
	add_child(wb)
	var started := wb.start(_profile_runtime)
	GSLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	wb.open_changed.connect(func(open: bool) -> void:
		_workbench_open = open
		if open:
			platform.hold_pointer(&"workbench")
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			platform.release_pointer(&"workbench")
			_apply_mouse())
	_workbench = wb

## Solo: F9 opens gs-workbench over the config and noblock sets (nothing without the addon).
func _start_solo_workbench() -> void:
	var wb := GSGameWorkbench.new()
	wb.name = "Workbench"
	wb.lazy_panel = true
	wb.listen_host_fn = func() -> bool: return true
	for set: GSProfileSet in _solo_binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	if game.noblock != null:
		wb.add_set(game.noblock.binder.profile_set(), "Noblock")
	var _fl := game.flashlight_conf()
	for set: GSProfileSet in game.flashlight_binder.profile_sets():
		wb.add_set(set, "Flashlight")
	add_child(wb)
	var started := wb.start()
	GSLog.result(CHANNEL, "the workbench", started)
	if not started.ok or wb.api == null:
		return
	_solo_binder.attach(wb.api.runtime)
	if game.noblock != null:
		game.noblock.binder.attach(wb.api.runtime)
	game.flashlight_binder.attach(wb.api.runtime)
	wb.open_changed.connect(func(open: bool) -> void:
		_workbench_open = open
		if open:
			platform.hold_pointer(&"workbench")
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			platform.release_pointer(&"workbench")
			_apply_mouse())
	_workbench = wb

## `--sim_host 1`: the solo game in its own process, joined over loopback. Nothing of this client exists
## yet, so its callbacks stay off until the server answers; a failure plays the stock solo game.
func _start_sim_host() -> void:
	_set_client_processing(false)
	var host := FcSimHost.new()
	host.name = "SimHost"
	add_child(host)
	var started: GSResult = await host.start(_launch_bots())
	GSLog.result(CHANNEL, "sim host", started)
	if started.ok:
		_sim_host = host
	else:
		host.queue_free()
	_set_client_processing(true)

func _start_offline() -> void:
	# Offline catches up with wall-clock time only as far as a tick is cheap enough to
	# (`_physics_process` adjusts this from the measured cost, FcTickBudget); a flat
	# cap of 2 ran the whole simulation at half speed whenever a frame took over 30 ms.
	Engine.max_physics_steps_per_frame = FcTickBudget.MAX_STEPS
	var started := Time.get_ticks_usec()
	game.start(0)
	_start_solo_workbench()

	# Offline this game is the authority, so the confirmations come off it directly; the
	# same handlers a server's HIT, AWARD and KILL reach. The feed is the HUD's own
	# `player_killed` connection, so this one leaves the feed alone.
	game.hit_confirmed.connect(
		func(attacker: int, victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool) -> void:
			if player != null and attacker == player.player_id:
				_on_hit({
					"victim_id": victim, "amount": amount, "point": point,
					"headshot": headshot, "lethal": lethal,
				})
	)
	game.stomped.connect(
		func(_a: int, _v: int, _s: float, point: Vector3, sound: StringName, effect: StringName) -> void:
			_on_stomp({"point": point, "sound": String(sound), "effect": String(effect)})
	)
	game.grenade_effect.connect(_on_grenade_fx)
	game.medals_awarded.connect(
		func(killer: int, victim: int, medals: Array, points: int, streak: int) -> void:
			_on_award({
				"killer_id": killer, "victim_id": victim, "medals": medals,
				"points": points, "streak": streak,
			})
	)
	game.player_killed.connect(func(entry: GSKillFeed.Entry) -> void:
		if hud != null:
			hud.note_kill(
				{
					"killer_id": int(entry.killer_key) if entry.killer_key.is_valid_int() else 0,
					"victim_id": int(entry.victim_key) if entry.victim_key.is_valid_int() else 0,
					"weapon": FcHud.cause_label(entry.cause),
				},
				player.player_id if player != null else 0,
				entry.killer_name
			)
	)

	# [b]Named as ours BEFORE it exists.[/b] `add_player` emits `player_added`
	# synchronously, and `_on_player_added` gives every player it does not recognise as
	# ours a body to be seen as. With `_watch_id` still -1 that was this one: the local
	# player wore a capsule and a nose with the camera inside it, and the nose was a pale
	# slab across the bottom of every offline frame. A networked client never had it,
	# because HELLO names the session before JOIN creates it.
	_watch_id = 1
	FcLoadTimeline.mark("offline: match started, %d ms" % ((Time.get_ticks_usec() - started) / 1000))
	await _setup_frame()

	# In a client that draws, the match start, the player, its arming and the bots were one 460 ms
	# frame on staging02 (perf-bench 20261112-065900): each now gets frames of its own.
	_arm_after_adopt = _builds_in_frames()
	started = Time.get_ticks_usec()
	var added := game.add_player(1, "Player")

	if added.ok:
		_adopt(added.value as FcPlayer)
	FcLoadTimeline.mark("offline: player added, %d ms" % ((Time.get_ticks_usec() - started) / 1000))
	if _arm_after_adopt:
		_arm_after_adopt = false
		await _setup_frame()
		await _arm_stepped(player)
		_restore_loadout.call_deferred()
		await _setup_frame()

	# The line tools/browser_solo_overlay_check.mjs looks for: the start map (a built-in one writes no
	# "map changed") is built and the player is in it.
	GSLog.info(CHANNEL, "map loaded", {"map": String(game.map.id) if game.map != null else ""})

	_bind_bot_console()
	await _launch_offline_bots(_launch_bots())
	_run_launch_commands()

## A solo launch's bots: all at once headless, a few a frame in a client that draws, where 31 bots
## with their bodies were ~130 ms of one frame.
func _launch_offline_bots(count: int) -> void:
	if not _builds_in_frames():
		_keep_offline_bots(count)
		return
	var started := Time.get_ticks_usec()
	var frames := 0
	var slice := GSFrameSlice.new(OFFLINE_BOT_BUDGET_MS)
	for wanted in range(1, count + 1):
		var before := _bots.size()
		_keep_offline_bots(wanted)
		if _bots.size() <= before:
			break
		if slice.due() and wanted < count:
			await _setup_frame()
			frames += 1
			slice = GSFrameSlice.new(OFFLINE_BOT_BUDGET_MS)
	FcLoadTimeline.mark(
		"offline: %d bots, %d ms over %d frames"
		% [_bots.size(), (Time.get_ticks_usec() - started) / 1000, frames + 1]
	)
