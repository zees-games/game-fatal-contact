extends "fc_client_session_events.gd"

## Every client draws the sun's shadow in one orthogonal map out to 60 m: each split is another depth pass over every body and gun.
## Built-in maps already use one split (see fc_map_lighting.gd); this covers imported ones. On staging02 with 32 players (n=3) a native frame was 1.1 ms faster with no visible change.
## `r_sun_shadow_splits` / `r_shadow_distance`, as a launch argument or URL query, still win.
const SUN_SHADOW_SPLITS := 1.0
const SUN_SHADOW_DISTANCE := 60.0
const _RenderQuality := preload("res://addons/gs_game/runtime/gs_game_render_quality.gd")
const _UserDir := preload("fc_user_dir.gd")
const _ClientRender := preload("res://addons/gs_game/runtime/gs_game_client_render.gd")

## The saved settings, read again before the presentation exists, that [method _apply_render_quality_early] follows until [method _follow_render_quality] hands the quality to the real ones.
var _early_settings: GSSettingsManager

func _render_defaults() -> void:
	if float(_RenderQuality.values[&"r_sun_shadow_splits"]) < 0.0:
		_RenderQuality.values[&"r_sun_shadow_splits"] = SUN_SHADOW_SPLITS
	if float(_RenderQuality.values[&"r_shadow_distance"]) < 0.0:
		_RenderQuality.values[&"r_shadow_distance"] = SUN_SHADOW_DISTANCE

func _ready() -> void:
	# The server a hosted game started runs this same main scene: an export takes no scene path.
	if FcSimHost.is_server_child():
		_become_sim_server()
		return
	# Before anything reads user://: the first run under game-fatal-contact copies the game-fatal-contact folder in.
	_UserDir.migrate()
	_apply_launch_art()
	_render_defaults()

	if FcSimHost.wanted(get_tree().current_scene == self):
		await _start_sim_host()

	# Closed before anything else is built, so no frame shows a half-made world.
	_build_platform()
	_offline = platform.offline
	# Solo only, before any catalogue is built: maps copied in by hand exist on this machine alone.
	FcMaps.list_local = _offline or _sim_host != null
	var timeline := FcLoadTimeline.new()
	timeline.name = "LoadTimeline"
	timeline.gate = gate
	add_child(timeline)
	_apply_render_quality_early()
	# Before the weapons, figures and world make their shaders: enabled later, the group loads for all of them in one frame.
	_arm_shader_group()
	# Names the process phase's untimed time in a recorded profile (arena.pf_head, pf_nodes, pf_tail).
	add_child(preload("fc_process_spans.gd").new())
	_request_figures()
	await _setup_frame()

	# A solo start map from a pack (the web's `?map=`) is fetched before the first map is read, under the boot
	# cover, so the game is built on it once instead of on dm_box and then again on it.
	await _fetch_solo_start_map()
	# Reading the map is a frame's work of its own on a big import (169 ms for cp-orange-x3 on staging02),
	# and it needs no game: read before the game exists, so no frame has a game without a map.
	var first := _first_map()
	FcLoadTimeline.mark("setup: map read")
	await _setup_frame()

	_make_game()

	# Offline, `-- --map <id>` picks the map, as it does for a dedicated server; a
	# connected client is told the server's map and rebuilds on it, unless it was built on that map
	# already: a sim host's map is known before the join, so the level is built once (_first_map).
	game.defer_map_io = true
	var built := await _setup_game(first)

	FcLoadTimeline.mark("setup: game built")
	if not built.ok:
		GSLog.result(CHANNEL, "Fatal Contact could not be built", built)
		_set_client_processing(true)
		return

	# The world, which the server does not need and a player cannot do without. Held, because a map
	# change has to take it away again — see `_on_map_changed`. A client of a remote server does not know the
	# map yet: it draws the level when the announcement comes (the "map" hold waits for it either way), rather
	# than drawing the dm_box placeholder only to throw it away.
	# Drawn after the frame setup ended, and waited for in a client that draws: its first slice and the rest
	# of setup shared frames of 514 and 736 ms on staging02. Headless builds alongside, as before.
	if (_offline or _sim_host != null) and _builds_in_frames():
		await _setup_frame()
		await _enter_level(_offline)
	elif _offline or _sim_host != null:
		_enter_level.call(_offline)
	await _setup_frame()

	await _setup_pieces(timeline)
	FcLoadTimeline.mark("setup: kill screens prepared")
	await _setup_interface_and_net()

	await _setup_finish(timeline)
	await _start_on_solo_map()


## Makes the game node, with headless collision, and connects its signals.
func _make_game() -> void:
	game = FcGame.new()
	game.name = "Game"
	game.is_authority = _offline
	game.stats_file = "user://arena_stats.json"

	# HEADLESS collision on a client with a screen: a predicting client must use the
	# server's analytic backend, or replays land differently and reconciliation corrects
	# a client that did nothing wrong. The visible level below is only what the player sees.
	game.headless = true
	game.register_service = _offline
	if _offline:
		_load_solo_config()
	add_child(game)

	_connect_game_signals()

## Part of [method _ready].
func _apply_launch_art() -> void:
	# fc-weapons' art is this game's copy of it, wherever this game is mounted. A
	# delivered pack sits under `res://gs_cloud/<id>/<version>/`, and the pack's art table
	# names `res://assets/...` — so without this every gun loads invisible, one WARN each.
	AwModelCache.set_asset_root(FcPaths.root())
	# Before anything reads the art table: the first read caches it.
	FcWeaponSkins.apply()
	FcFrameProbe.from_launch()
	# A map change respawns everybody in one tick, and every third-person gun was built
	# in that one frame (~66 ms of the 117 ms worst frame with 15 bots). Past ~4 ms a
	# frame the rest wait for the next frames; presentation only, the shot never reads it.
	# Set through the script so an fc-weapons before level 22 still parses.
	if GSAddonApi.build_level("fc_weapons") >= 22:
		(AwWorldModel as Script).set(&"equip_budget_usec", 4000)

## Part of [method _ready].
func _setup_pieces(timeline: FcLoadTimeline) -> void:
	projectile_view = FcProjectileView.new()
	projectile_view.name = "Projectiles"
	add_child(projectile_view)
	_share_fx_pools()

	FcLoadTimeline.mark("setup: projectiles")
	await _setup_frame()
	_build_ragdolls()
	FcLoadTimeline.mark("setup: ragdolls")
	await _setup_frame()
	_build_killcam()
	FcLoadTimeline.mark("setup: killcam")
	await _setup_frame()
	_build_killview()
	FcLoadTimeline.mark("setup: projectiles, ragdolls, killcam, kill view")
	if not GSPlatform.is_headless():
		# The first draw with a game camera, then the frames to the level's first draw traced (ticks, setup steps, draws).
		RenderingServer.frame_pre_draw.connect(func() -> void: FcLoadTimeline.mark("first draw begins"), CONNECT_ONE_SHOT)
		RenderingServer.frame_post_draw.connect(func() -> void:
			FcLoadTimeline.mark("first draw done")
			timeline.trace_frames(24), CONNECT_ONE_SHOT)
	_connect_solo_signals()
	await _setup_frame()
	await _warm_figures()
	# Each killer's screen's spare hands (about 125 ms each on staging02) in a frame of its own.
	# Headless, `mount` deferred them as before.
	for pov in _pov_spares:
		if is_instance_valid(pov) and _builds_in_frames():
			pov.call(&"prepare_spare")
			await _setup_frame()
	_pov_spares.clear()

## The pool other players' shot effects share their quads and flash lights from, in the tree before any of them fires.
## Headless never runs the weapon warm-up that made it, so each bot's effects built 24 quads and a light (perf smoke).
func _share_fx_pools() -> void:
	if fx_pool != null:
		return
	fx_pool = AwFxPool.new()
	fx_pool.name = "FxPool"
	if GSPlatform.is_headless():
		# Nothing is drawn, but the flashes still take lights up to the cap and quads by the burst: both are prewarmed to what
		# the bots use (the old per-shooter 24 quads each) and the quads are never trimmed below it, or bots firing later
		# (a loadout reopen, headless_loadout_open) grow the tree. Past it, spares go past cl_fx_pool_idle.
		fx_pool.shared_lights = GSFxLightBudget.config.effective_max_lights()
		fx_pool.shared_meshes = maxi(fx_pool.shared_meshes, fx_pool.shared_meshes * _launch_bots())
		fx_pool.shared_idle = 0 if FcPresentation.fx_pool_idle < 0 else maxi(FcPresentation.fx_pool_idle, fx_pool.shared_meshes)
	add_child(fx_pool)

## Part of [method _ready].
func _setup_interface_and_net() -> void:

	_sampler = make_sampler()
	# C slides as well as Duck: added once the key table has been applied, in
	# `_build_interface` (`_add_slide_key`), or applying it would take C off again.

	# Before the interface, because the field of view and the crosshair come out of the
	# settings document and a screen built first would have laid itself out from the
	# defaults.
	_build_presentation()
	FcLoadTimeline.mark("setup: presentation")
	await _setup_frame()
	_build_interface()
	FcLoadTimeline.mark("setup: interface")

	# The player's look and crosshair settings, onto the two things they shape. After both
	# exist, and pushed rather than waited for: a value loaded from disk has not changed,
	# so a binding that only listened would leave a saved sensitivity doing nothing.
	if presentation != null:
		presentation.bind_look(_sampler.tunables)
		if hud != null:
			presentation.bind_crosshair(hud.crosshair)
	await _setup_frame()

	if _offline:
		await _start_offline()
		# The netcode build installs it for a connected client; an offline one never builds netcode.
		_install_profiler_context()
	else:
		await _prepare_extras()
		var netted := _build_netcode()
		GSLog.result(CHANNEL, "netcode", netted)
		if netted.ok and link != null:
			_start_remote_workbench()
		if netted.ok and _sim_host != null:
			_bind_host_console()
	FcLoadTimeline.mark("setup: netcode built")

	# The server's fc_ambient* (a link tells them) drive the quiet layer; the player's sliders multiply on top.
	if presentation != null and presentation.ambient != null:
		presentation.ambient.follow_settings(presentation.settings, game.ambient_rules)
	if presentation != null:
		presentation.use_shot_rules(game.shot_rules)
	# The first draw's pipeline compile and the netcode share the frame above; the platform gets its own.
	await _setup_frame()

## Chat and the map layer a frame each before the netcode, in a client that draws (they were 302 + 259 ms of
## the netcode's one frame on dm_box). `cl_slice_extras 0` (launch argument or URL query) builds them inside it, as before.
func _prepare_extras() -> void:
	if not _builds_in_frames() or FcFrameProbe.launch_value("cl_slice_extras") == "0":
		return
	extras = _new_extras()
	var prepared: Variant = extras
	await prepared.prepare(game, _setup_frame)

## Part of [method _ready].
func _setup_finish(timeline: FcLoadTimeline) -> void:
	_grab_mouse()
	platform.slide_settings = presentation.settings
	var platform_up: GSResult = await _setup_platform()
	GSLog.result(CHANNEL, "the platform", platform_up)
	# The quality piece, the menu's quality settings and the first processed frame each in a frame of their own:
	# together with the bodies they were one 1.15 s frame on staging (dm_box). `cl_platform_split 0` runs them in one.
	var split := _builds_in_frames() and FcFrameProbe.launch_value("cl_platform_split") != "0"
	if split:
		await _setup_frame()
	_follow_render_quality()
	if split:
		FcLoadTimeline.mark("setup: render quality followed")
		await _setup_frame()
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	GSLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	_suspend_input(platform.is_input_blocked())
	FcLoadTimeline.mark("setup: platform")
	if not GSPlatform.is_headless():
		# The first draw of the built level and HUD compiles their pipelines (672 ms on staging02): marked, so it is not mistaken for setup.
		RenderingServer.frame_pre_draw.connect(func() -> void: FcLoadTimeline.mark("level draw begins"), CONNECT_ONE_SHOT)
		RenderingServer.frame_post_draw.connect(func() -> void:
			FcLoadTimeline.mark("level draw done")
			timeline.trace_frames(12), CONNECT_ONE_SHOT)
		# The first processed frame (the bodies' first pass, 420 ms) drawn a frame after that first level draw: together they were one 634 ms frame on staging02.
		if split:
			await _setup_frame()
		_set_client_processing(true)

## [method FcGame.setup], one step a frame in a client that draws (the steps shared one 222 ms frame on
## staging02; combat and loadouts were most of it). The game does not process between steps, so nothing
## of it runs half built. Headless (suites, servers) builds in one go.
func _setup_game(first: FcMap) -> GSResult:
	if not _builds_in_frames():
		return game.setup(first)
	var built := game.setup_begin(first)
	var was := game.process_mode
	game.process_mode = Node.PROCESS_MODE_DISABLED
	if built.ok:
		await _warm_weapon_table()
	while built.ok and not game.setup_done():
		await _setup_frame()
		var step := game.setup_next_step()
		var started := Time.get_ticks_usec()
		built = game.setup_step()
		FcLoadTimeline.mark("setup: game %s, %d ms" % [step, (Time.get_ticks_usec() - started) / 1000])
	game.process_mode = was
	return built

## The shared weapon table the combat step reads, built before it about 8 ms a frame.
func _warm_weapon_table() -> void:
	var held: Array = []
	var step := 0
	var going := true
	while going:
		await _setup_frame()
		var started := Time.get_ticks_usec()
		var first := step
		while going and Time.get_ticks_usec() - started < 8000:
			going = FcPlayer.warm_catalogue_step(step, held)
			step += 1
		FcLoadTimeline.mark("setup: weapon table %d-%d, %d ms" % [first, step - 1, (Time.get_ticks_usec() - started) / 1000])

## The first figure built paid for the stock body models and the clip set (249 ms, in the killcam's spare
## arms on staging02). The models start loading on the loader's threads here, at the start of setup. Not where
## loader threads stall on the frame (the threaded web engine, [method loader_threads_usable]).
func _request_figures() -> void:
	if not _builds_in_frames() or not loader_threads_usable():
		return
	var paths: Array[String] = [GSHumanoidAssets.real_clips_path()]
	for body: StringName in [GSHumanoidLook.stock(1).body, GSHumanoidAssets.CLIP_BODY]:
		paths.append(GSHumanoidAssets.body_path(body))
	for path in paths:
		if not _figure_loads.has(path) and ResourceLoader.exists(path) and ResourceLoader.load_threaded_request(path) == OK:
			_figure_loads.append(path)

## Takes the models [method _request_figures] started (waiting a frame at a time if they are still loading), then
## waits for the clip set and the stock body's retarget, built off the frame, before the kill screens' spare arms are the first figure.
func _warm_figures() -> void:
	if _figure_loads.is_empty():
		return
	var held: Array[Resource] = []
	for path in _figure_loads:
		while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await _setup_frame()
		var started := Time.get_ticks_usec()
		held.append(ResourceLoader.load_threaded_get(path))
		# The clip set's real clips are only held, so the build's own load of them (on a worker) finds them loaded.
		if path != GSHumanoidAssets.real_clips_path():
			var _scene := GSHumanoidAssets.scene(path)
		FcLoadTimeline.mark("setup: figure model %s, %d ms" % [path.get_file(), (Time.get_ticks_usec() - started) / 1000])
	_figure_loads.clear()
	var started := Time.get_ticks_usec()
	var frames := 0
	GSHumanoidAssets.prepare_libraries([GSHumanoidLook.stock(1).body])
	# The models are instanced for their skeletons in that call, on this thread; the rest runs on a worker.
	FcLoadTimeline.mark("setup: figure clips started, %d ms" % ((Time.get_ticks_usec() - started) / 1000))
	while not GSHumanoidAssets.poll_libraries():
		frames += 1
		await _setup_frame()
	FcLoadTimeline.mark("setup: figure clips, %d ms over %d frames" % [(Time.get_ticks_usec() - started) / 1000, frames])

## The platform's setup one piece a frame in a client that draws (all of it was one ~200 ms frame on staging02).
## By name: a linked gs-game older than API 57 has no setup_stepped, and sets up in one go, as headless does.
func _setup_platform() -> GSResult:
	if not _builds_in_frames() or not platform.has_method(&"setup_stepped"):
		return platform.setup()
	var between := func(piece: StringName) -> void:
		_mark_platform_piece(piece)
		await _setup_frame()
	var stepped: GSResult = await platform.call(&"setup_stepped", between)
	var usec: Dictionary = platform.get(&"setup_usec")
	if not usec.is_empty():
		_mark_platform_piece(usec.keys().back())
	return stepped

func _mark_platform_piece(piece: StringName) -> void:
	var usec: Dictionary = platform.get(&"setup_usec")
	FcLoadTimeline.mark("platform: %s, %d ms" % [piece, int(usec.get(piece, 0)) / 1000])

## The map the game is first built on: offline the command line's, under a sim host the one its server was
## started on (so the announcement finds the level already built), and otherwise the dm_box placeholder,
## whose level is not drawn (the announcement draws the real one).
func _first_map() -> FcMap:
	if _offline:
		return _startup_map()
	var asked := FcSimHost.asked_map_id() if _sim_host != null else ""
	var map: FcMap = FcMap.by_id(StringName(asked)) if asked != "" else null
	return map if map != null else FcMap.dm_box()

## What the game tells the client: a player joined, a flag event, the mode's banner.
func _connect_game_signals() -> void:
	# Connected here, before anything can create a player, rather than inside `_watch`.
	game.player_added.connect(_on_player_added)
	# The flag's sounds: from what the flag view draws, so a dedicated server's client hears them too.
	game.ctf_seen.connect(func(what: StringName, team: int, by: int) -> void:
		if presentation != null:
			presentation.on_flag_event(what, team, player != null and by == player.player_id, game.team_of(player.player_id) if player != null else 0)
	)
	# The mode's banner, the moment a client learns it: "Gun Game: every kill gives you a
	# different gun", the way the genre says it when you spawn into one.
	game.mode_shown.connect(func(shown: FcMode) -> void:
		if hud != null:
			hud.notice("%s  -  %s" % [shown.display_name, shown.description])
	)


## Solo only: a kill the game decided, and the loadout a roll gave.
func _connect_solo_signals() -> void:
	if not _offline:
		return
	# Solo, the world is this process's and there is no KILL message: the death the game
	# decided is on the kill's entry.
	game.player_killed.connect(_on_solo_kill)
	game.loadout_rolled.connect(func(id: int, text: String) -> void:
		if player != null and id == player.player_id and hud != null:
			hud.notice(text))


## The view key: the other view if the server's `mp_forceview` allows it, a line if not.
## gs-game's render quality follows `platform.settings`, which Fatal Contact leaves unset, so the menu's
## quality rows did nothing; the operator's `--render-*` cvars are read again after, as gs-game orders.
func _follow_render_quality() -> void:
	var quality := platform.render_quality
	if quality == null or presentation == null or not quality.has_method(&"follow"):
		return
	quality.call(&"follow", presentation.settings)
	quality.call(&"load_layers")
	if _early_settings != null:
		_early_settings.free()
		_early_settings = null


## GameSpice Core's [GSShaderGroupArm] (dm_box's first level draw went from ~1000 ms to 9 ms on staging), marked
## "shader group armed" on the timeline. Off with launch value `cl_shader_group_arm 0`: the group is then enabled at the
## level's first lightmapped frame, as before.
func _arm_shader_group() -> void:
	if FcFrameProbe.launch_value("cl_shader_group_arm") == "0":
		return
	var arm := GSShaderGroupArm.start(self)
	if arm != null:
		arm.armed.connect(func() -> void: FcLoadTimeline.mark("shader group armed"))


## The render quality from the saved settings and the `--render-*` cvars, applied before the shader-group arm and the warm-ups compile
## anything, so [method _follow_render_quality] finds the same values and no pipeline is compiled twice.
## `cl_early_render_quality 0` leaves it to the platform's quality piece.
func _apply_render_quality_early() -> void:
	if GSPlatform.is_headless() or not platform.use_render_quality or platform.gate_only:
		return
	if FcFrameProbe.launch_value("cl_early_render_quality") == "0":
		return
	_early_settings = GSSettingsManager.new()
	_early_settings.schema = FcPresentation.schema()
	_early_settings.local_store = GSSettingsStoreFile.new(FcPresentation.settings_directory)
	_early_settings.app_namespace = &"game_fatal_contact"
	_early_settings.persist = false
	_early_settings.register_as_service = false
	var read := _early_settings.setup()
	if not read.ok:
		GSLog.result(CHANNEL, "the saved render quality", read)
	platform.render_quality = _ClientRender.add(platform, _early_settings)
	# The quality piece would find this node and set the platform's reference to null.
	if platform.render_quality != null:
		platform.use_render_quality = false


func toggle_view() -> void:
	if player == null:
		return
	var wanted := game.view_rules.toggled(player.third_person)
	if wanted == player.third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.notice(game.view_rules.refusal())
		return
	_set_third_person(wanted)
	if hud != null:
		hud.notice("Third person" if wanted else "First person")

## Solo: the bridge's per-tick record and delivery, in this process. Only the local player's clip is played.
func _tick_solo_killview() -> void:
	if solo_killview != null:
		solo_killview.tick(game.current_tick())

## The kill view, the final killcam and the winner reveal each hide the HUD and put back what they found. When two overlap, the later one found it already hidden and restores it hidden, for the rest of the session; this is the one owner that says no screen is up, so the HUD returns.
func _restore_hud_if_orphaned() -> void:
	if hud == null or hud.visible or not _reveal_hid.is_empty():
		return
	if killcam != null and killcam.is_playing():
		return
	if killview != null and killview.is_active():
		return
	if winner_reveal != null and winner_reveal.is_active():
		return
	GSLog.warn(CHANNEL, "HUD was left hidden with no screen up; restored")
	hud.visible = true

## Records the frame for the killcam, or draws the replay over it. Solo has no MATCH message,
## so the end of a solo match is seen here.
func _killcam_frame() -> void:
	if killcam == null or game == null:
		return
	killcam.hide_while_playing = [hud, view_model]
	killcam.world_mask = _level_mask()
	var t_cam := Time.get_ticks_usec()
	# Recording is capped at cl_killcam_hz (cl_killcam_crowd_hz in a crowd); a replay playing is stepped every frame. A kill view
	# keeps bodies posed (the host's `_again`): that re-pose is every frame, but the recording (33 state reads) stays on its rate
	# (it ran every frame while a view played: 0.85 of the 0.95 ms a frame c_killcam cost at 32 bots).
	var bodies := game.players()
	var hz := FcKillcamBodies.hz_for(bodies.size())
	var record_gap := int(1.0e6 / hz) if hz > 0.0 else 0
	var again: Array = killcam.get(&"_again")
	if record_gap == 0 or killcam.is_playing() or t_cam - _killcam_recorded >= record_gap:
		_killcam_recorded = t_cam
		if killcam_shots != null and not killcam.is_playing():
			killcam_shots.record(float(killcam.now_fn.call()), bodies)
		killcam.frame()
	elif not again.is_empty():
		if killcam.has_method(&"repose"):  # gs_replay 11: skipped while the replay poses the bodies after this
			var _r: Variant = killcam.call(&"repose")
		else:
			var _posed: Dictionary = killcam.pose(again[0], again[1], again[2])
	_fade_for_replay(get_process_delta_time())
	FcFrameProbe.add(&"c_killcam", t_cam)
	_restore_hud_if_orphaned()
	var now := int(game.match_node.state) if game.match_node != null else -1
	if _offline and now != _seen_match_state and now == GSMatch.State.MATCH_END:
		_begin_match_end()
	_seen_match_state = now

func is_ready_to_show() -> bool:
	return gate != null and gate.is_open()

## What a shell draws once under its loading screen besides what is already in the tree: the meshes
## and materials of every weapon model the art table names, so the first time somebody draws a gun
## nobody has held yet is not also the first time its materials compile (in a browser.
func warm_up_items() -> Array:
	return gate.warm_items() if gate != null else []

## `cl_weapon_sprites 1`: the held weapon as a flat sprite under the camera in place of the hands.
func _present_sprite_view() -> void:
	if view_model == null or player == null or player.camera == null:
		return
	if not FcWeaponIcons.shared.sprites:
		if _sprite_view != null:
			_sprite_view.queue_free()
			_sprite_view = null
			view_model.visible = true
		return
	if _sprite_view == null:
		_sprite_view = FcSpriteWeapon.make(FcSpriteWeapon.Mode.VIEW)
		player.camera.add_child(_sprite_view)
	var def: Variant = player.arsenal.current_def() if player.arsenal != null else null
	_sprite_view.show_weapon(def.id if def != null else &"")
	view_model.visible = _sprite_view.texture == null

## Whether right mouse aims (the player's setting, on by default) rather than bashes.
func right_mouse_aims() -> bool:
	if presentation == null or presentation.settings == null:
		return true
	return bool(presentation.settings.get_value(&"right_mouse_aims"))

## Whether [param action] is held, and false for an action the InputMap does not have (a
## suite's client, built with no presentation, has applied no table).
static func _held(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)

const BOT_MOVE := &"bot_move"
const BOT_FIRE := &"bot_fire"

func _local_commands(move: GSFpsCommand) -> Dictionary:
	var out: Dictionary = {}

	if player != null:
		out[player.player_id] = [move, _fire]

	# The fresh commands are made only for a bot that has none yet: as `get_meta` defaults they were built for every
	# bot every tick and thrown away (two objects a bot, ~150 us a tick at 31 bots on the web build).
	for id in _bots:
		var bot: FcPlayer = _bots[id]
		var bot_move: Variant = bot.get_meta(BOT_MOVE) if bot.has_meta(BOT_MOVE) else GSFpsCommand.new()
		var bot_fire: Variant = bot.get_meta(BOT_FIRE) if bot.has_meta(BOT_FIRE) else GSWeaponCommand.new()
		out[int(id)] = [bot_move, bot_fire]

	return out

## The followed player's id as the string key spectate wants, rebuilt only when the id changes.
var _roam_id := -1
var _roam_key := ""


func is_roaming() -> bool:
	if game == null or game.spectate == null or player == null:
		return false
	if _roam_id != player.player_id:
		_roam_id = player.player_id
		_roam_key = String.num_int64(_roam_id)
	return game.spectate.is_roaming(_roam_key)

func _touch_held(id: StringName) -> bool:
	return _touch != null and bool(_touch.call(&"is_held", id))

## The overlay is up. Godot then turns every touch into a left click too, which must not read as the Fire key.
func _touch_on() -> bool:
	return _touch != null and bool(_touch.call(&"active"))


## Remembers the slot before the one in hand, for Q.
func _note_held_slot() -> void:
	if player == null or player.arsenal == null:
		return

	var now := player.arsenal.current_slot()

	if now != _held_slot:
		if _held_slot > 0:
			_last_slot = _held_slot
		_held_slot = now

## Whether the pointer is currently the player's aim rather than a pointer.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)

	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

## The fire command, from the keyboard and the mouse. [b]`GSWeaponCommand` is a button BITMASK, not
## a set of booleans.[/b] `set_button` is the accessor; assigning `.attack` creates nothing and
## errors at runtime with "Invalid assignment of property or key 'attack'".
func _read_fire(move: GSFpsCommand) -> void:
	var firing := mouse_drives_view() and ((_held(FcBindings.FIRE) and not _touch_on()) or _touch_held(&"fire"))

	_fire.set_button(GSWeaponCommand.BUTTON_ATTACK, firing)
	# The Aim key (right mouse) aims down the sights, by default; the Bash key (X) is the pack's
	# alt-fire ("quick melee"). A player who would rather bash with the Aim key turns the
	# `right_mouse_aims` setting off.
	var right := mouse_drives_view() and _held(FcBindings.AIM) \
		and not _aim_break.blocked(Time.get_ticks_msec() * 0.001)
	var aims := right_mouse_aims() and not props_on_e()
	var bash := (right and not aims) or (not props_on_e() and mouse_drives_view() and _held(FcBindings.BASH))
	_fire.set_button(GSWeaponCommand.BUTTON_ALT, bash)
	_fire.set_button(FcFlashlight.BUTTON, _flash_ticks > 0)
	_flash_ticks = maxi(_flash_ticks - 1, 0)
	if player != null:
		player.aim_held = right and aims
	if _sampler != null:
		_sampler.look_scale = player.aim_zoom() if player != null else 1.0
	# On the wire as well, for the server's No Scope medal; nothing simulated reads it.
	_fire.set_button(FcPlayer.BUTTON_AIM, right and aims)
	# And on the move command, where the motor slows an aimed player (sv_ads_speed_mult) the same in prediction and on the server.
	move.set_button(FcPlayer.MOVE_BUTTON_AIM, right and aims and not is_roaming())
	_fire.set_button(GSWeaponCommand.BUTTON_RELOAD, mouse_drives_view() and (_held(FcBindings.RELOAD) or _touch_held(&"reload")))
	_fire.set_button(GSWeaponCommand.BUTTON_FIRE_MODE, mouse_drives_view() and _held(FcBindings.FIRE_MODE))
	_fire.set_button(GSWeaponCommand.BUTTON_DROP, mouse_drives_view() and _held(FcBindings.WEAPON_DROP))
	_fire.set_button(GSWeaponCommand.BUTTON_USE, mouse_drives_view() and _held(FcBindings.USE))
	_note_held_slot()
	_fire.yaw = move.yaw
	_fire.pitch = move.pitch

	# `GSArsenal` reads `command.slot > 0` as "switch to this" and 0 as "leave it alone", so this
	# is a REQUEST that is cleared once made rather than a mirror of the current slot.
	_fire.slot = _wanted_slot
	_wanted_slot = 0

const FcJumpGate := preload("fc_jump_gate.gd")
const TagRules := preload("fc_name_tag_rules.gd")
const KillPovRules := preload("fc_kill_pov.gd")

var _jump_gate := FcJumpGate.new()

## `cl_respawn_jump_gate` (default 1): see [FcJumpGate].
func _gate_jump_after_death(move: GSFpsCommand) -> void:
	var on := presentation == null or presentation.settings == null \
		or presentation.settings.get_bool(&"respawn_jump_gate", true)
	var away := player != null and (not player.is_alive() \
		or (killcam != null and killcam.is_playing()) \
		or (killview != null and killview.is_active()))
	_jump_gate.filter(move, away, on and player != null)

func _physics_step(delta: float) -> void:
	var move := _sampler.sample(delta) if _sampler != null else GSFpsCommand.new()
	_gate_jump_after_death(move)
	if hud != null and presentation != null and presentation.bindings != null:
		hud.launch_key_text = presentation.bindings.key_for(launch_action())

	# The launch: the movement command's first user bit, which the motor reads when the
	# server's rules have the launch on. Same guard as the trigger, so typing in the chat
	# box does not throw anybody into the air.
	move.set_button(
		GSFpsCommand.BUTTON_USER_0, mouse_drives_view() and _held(launch_action())
	)
	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead player about.
		move.move = Vector2.ZERO
		move.buttons = 0
	_read_fire(move)

	if _offline:
		if game != null:
			var t_bots := Time.get_ticks_usec()
			_drive_bots()
			FcFrameProbe.add(&"bots", t_bots)
			var t_tick := Time.get_ticks_usec()
			game.tick(_local_commands(move))
			FcFrameProbe.add(&"game_tick", t_tick)
			_tick_solo_killview()
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# The clock says how many ticks this frame is worth, which on a client whose engine
	# runs at the server's rate is almost always exactly one.
	bridge.advance_latency(delta)
	var ticks := net.clock.advance(delta)

	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of them, so
	# `input_tick()` is the LAST one on every pass: a frame worth two ticks sent the second twice
	# and the first never, the server repeated a stale command for the one it never got.
	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		var tick := net.clock.input_tick() - (ticks - 1 - i)
		bridge.client_tick(tick, move, _fire)

		bridge.send_input(tick, move, _fire)

# --- The loop --------------------------------------------------------------

## Hands this process over to the loopback server scene; nothing of the client is built.
func _become_sim_server() -> void:
	set_process(false)
	set_physics_process(false)
	set_process_input(false)
	set_process_unhandled_input(false)
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file.call_deferred(FcSimHost.server_scene())
		return
	# Loaded by a shell: changing its scene would free the shell and the solo session that mounted this pack.
	var packed := load(FcSimHost.server_scene()) as PackedScene
	if packed == null:
		push_error("the sim server scene would not load: %s" % FcSimHost.server_scene())
		get_tree().quit(1)
		return
	var server := packed.instantiate()
	server.name = FcSimHost.ANCHOR
	get_tree().root.add_child.call_deferred(server)
	queue_free()

func _physics_process(delta: float) -> void:
	var t := Time.get_ticks_usec()
	_physics_step(delta)
	FcFrameProbe.add(&"physics", t)
	if _offline and _tick_budget != null:
		_tick_budget.note_tick()
		# Catch up with wall-clock time as far as ticks are cheap enough to (FcTickBudget).
		Engine.max_physics_steps_per_frame = _tick_budget.steps_for((Time.get_ticks_usec() - t) / 1000000.0)
		if _changing:
			# Behind a map change's cover one tick a frame: the new map's first ticks cost 30-80 ms each (staging02) and
			# catching up 3-4 of them made 200-500 ms frames. The ticks are the same; the dropped wall time is the cover's.
			Engine.max_physics_steps_per_frame = 1
		# Ticks dearer than their length cannot keep real time: the thinning bots think less often (FcBots.tiers).
		FcBots.tiers.load_scale = _tick_budget.load_scale(1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0))

## A connected client's respawn faces the way its spawn faces. [b]Only the client can turn the
## view[/b]: the server teleports the player facing the spawn, then applies the next command, whose
## angles are this client's sampler's -- the look the mouse left before the death.
func _face_a_respawn() -> void:
	if _offline or player == null or player.controller == null or _sampler == null or game == null:
		return

	var alive := player.is_alive()
	var came_back := alive and not _was_alive
	_was_alive = alive

	if not came_back or game.map == null:
		return

	var at := player.controller.state.position
	var nearest := INF
	var yaw := NAN

	for spawn: Transform3D in game.map.spawns:
		var d := spawn.origin.distance_to(at)
		if d < nearest:
			nearest = d
			yaw = rad_to_deg(spawn.basis.get_euler().y)

	if nearest < SPAWN_FACE_REACH:
		_sampler.look_at_angles(yaw, 0.0)
