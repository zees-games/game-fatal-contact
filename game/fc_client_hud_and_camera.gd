extends "fc_client_level.gd"

const FcProfilerContext := preload("fc_profiler_context.gd")
const FcObjectives := preload("fc_objectives.gd")
const FcFlagView := preload("fc_flag_view.gd")

## Whether E is the prop tool's key here: only in a mode where players use props. Anywhere
## else E is the launch, which is what most of Fatal Contact's modes want it for.
func props_on_e() -> bool:
	if game == null:
		return false
	# The mode the server says, not the one this client was built with: a client's own
	# `mode` is never replaced, and in Siege it read free-for-all and E launched.
	var shown := game.displayed_mode()
	return shown != null and shown.player_props

## The launch's action: the Launch row (E), or its own row (X) in a mode where the Launch
## key is the prop tool's grab.
func launch_action() -> StringName:
	return FcBindings.LAUNCH_PROPS if props_on_e() else FcBindings.LAUNCH

## The keys the HUD's buttons, hints and prompts name, from the key table as the player
## has it bound. Slide says C while Duck is on its default, because that is where C slides.
func _hud_keys() -> void:
	if hud == null or presentation == null or presentation.bindings == null:
		return
	var table: GSMenuBindings = presentation.bindings
	hud.keys[&"jump"] = table.key_for(&"gs_fps_jump")
	hud.keys[&"dash"] = table.key_for(FcBindings.DASH)
	hud.keys[&"chat"] = table.key_for(FcBindings.CHAT)
	hud.keys[&"scoreboard"] = table.key_for(FcBindings.SCOREBOARD)
	hud.keys[&"reload"] = table.key_for(FcBindings.RELOAD)
	hud.keys[&"fire_mode"] = table.key_for(FcBindings.FIRE_MODE)
	hud.keys[&"use"] = table.key_for(FcBindings.USE)
	hud.keys[&"help"] = table.key_for(GSMenuBindings.HELP_ACTION)
	hud.keys[&"maps"] = table.key_for(&"gs_menu_maps")
	hud.keys[&"loadout"] = table.key_for(&"gs_menu_loadout") if loadout_menu != null else ""
	hud.keys[&"launch"] = table.key_for(launch_action())
	hud.keys[&"roam"] = table.key_for(FcBindings.ROAM)
	for i in range(FcBindings.SLOTS.size()):
		hud.keys[StringName("slot_%d" % (i + 1))] = table.key_for(FcBindings.SLOTS[i])
	hud.keys[&"slide"] = "C" if _slide_on_c() else table.key_for(FcBindings.DUCK)

## Adds [param key] to [param action] if neither is missing and it is not bound already.
static func _add_key(action: StringName, key: Key) -> void:
	if action == &"" or not InputMap.has_action(action):
		return

	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and (existing as InputEventKey).physical_keycode == key:
			return

	var event := InputEventKey.new()
	event.physical_keycode = key
	InputMap.action_add_event(action, event)

## C slides as well as Duck, while Duck is on its default key and no other row has been
## given C. A slide IS a duck at a run, and C is where the genre puts it. Deferred after a
## rebind: the table applies the row after the setting changes, and that apply would take
## C off again.
##
## [b]Taken off again when another row gets C.[/b] C is not a stored binding, so the
## table's swap cannot see it: binding Last weapon to C would otherwise have one press
## switch weapons and slide.
func _add_slide_key() -> void:
	if _sampler == null:
		return
	var duck := _sampler.actions.get("crouch", &"") as StringName
	if _slide_on_c():
		_add_key(duck, KEY_C)
	elif presentation != null and presentation.bindings != null:
		var row := presentation.bindings.row_for_action(duck)
		if not row.is_empty():
			var _bound := presentation.bindings.apply_row(row, presentation.bindings.stored(row, presentation.settings))

func _build_interface_rest() -> void:
	_add_slide_key()
	_hud_keys()


## Solo: a map (`map:<id>`) or a mode on this map (`mode:<id>`), now. The game changes and the
## level is rebuilt as a server's change would have it rebuilt ([method _on_map_changed]).
func change_from_menu(id: StringName, picked_mode: StringName = &"") -> GSResult:
	if host_console == null and not _offline:
		return GSResult.fail(GSError.CODE_STATE, "The server changes the map.")
	var timeline := get_node_or_null(^"LoadTimeline") as FcLoadTimeline
	if timeline != null:
		timeline.rearm("map change %s to playable" % String(id))
	if host_console != null:
		_trace_hosted_change = timeline != null and not GSPlatform.is_headless()
		var hosted: GSResult = await _change_on_host(String(id), String(picked_mode))
		FcLoadTimeline.mark("change: host answered")
		if not hosted.ok:
			_trace_hosted_change = false
		return hosted
	if timeline != null:
		if not GSPlatform.is_headless():
			timeline.trace_frames(CHANGE_TRACE_FRAMES)
	# The cover goes up before any of the work, under a reason of its own: the fetch and the level each hold and
	# release &"map", and a gap between them would draw the half-changed game for a frame.
	gate.hold(&"change", "Loading the map")
	_changing = true
	Engine.max_physics_steps_per_frame = 1
	var changed: GSResult = await _change_covered(id, picked_mode)
	_changing = false
	gate.release(&"change")
	return changed


## [method change_from_menu] behind its cover, one heavy step a frame: the menu's map list, the game's
## [code]change_map[/code], then the level in slices ([method _on_map_changed]).
func _change_covered(id: StringName, picked_mode: StringName) -> GSResult:
	var text := String(id)
	var map := game.map
	var mode: FcMode = null
	var _listed := await _catalogue_sliced()
	FcLoadTimeline.mark("change: maps listed")
	if text.begins_with("map:"):
		var fetched := await _fetch_picked(StringName(text.substr(4)))
		FcLoadTimeline.mark("change: map fetched")
		if not fetched.ok:
			return fetched
		var built := _build_map(StringName(text.substr(4)))
		FcLoadTimeline.mark("change: map read")
		if not built.ok:
			return built
		map = built.value
		if String(picked_mode).begins_with("mode:"):
			mode = FcModes.by_id(StringName(String(picked_mode).substr(5)))
	elif text.begins_with("mode:"):
		mode = FcModes.by_id(StringName(text.substr(5)))
		if mode == null:
			return GSResult.fail(GSError.CODE_INVALID, "There is no mode called '%s'." % text.substr(5))
		var rebuilt := _build_map(game.map.id)
		if not rebuilt.ok:
			return rebuilt
		map = rebuilt.value
	if map == null:
		return GSResult.fail(GSError.CODE_INVALID, "There is no map called '%s'." % text)
	# The imported solid in slices first: built inside change_map it was 40-70 ms of the swap frame.
	await map.to_collision_async(GSFrameSlice.new(LEVEL_SLICE_MS))
	FcLoadTimeline.mark("change: solid built")
	# The flag views' first build, in a frame of its own: built in the swap frame it was 143 ms of it.
	var played := mode if mode != null else game.displayed_mode()
	if played != null and played.objective_layout == FcObjectives.CTF:
		await FcFlagView.warm(self)
		FcLoadTimeline.mark("change: flag views warmed")
	await get_tree().process_frame
	var changed := game.change_map(map, mode)
	map.drop_prebuilt_collision()
	FcLoadTimeline.mark("change: game changed")
	if not changed.ok:
		return changed
	var def := _catalogue().get_map(map.id)
	if def != null:
		await get_tree().process_frame
		await _on_map_changed(def)
	return GSResult.success(id)

## The cursor, from one place. A screen that wants the mouse gets it; otherwise the game does, subject to the
## browser having been clicked at least once.
func _apply_mouse() -> void:
	if _menu_open():
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	if _awaiting_click:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## The hit drawn on the body the server says was hit: the pack's red burst at [param point].
func _draw_body_hit(point: Vector3) -> void:
	if not weapon_draws_shots():
		return
	var fx: Object = player.weapons.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = player.global_position + Vector3(0.0, FcPlayer.eye_height(), 0.0)
	fx.call(&"play_body_hit", point, point - from)

## Where the camera actually is, or the origin when there is none.
func camera_position() -> Vector3:
	return player.camera.global_position if player != null and player.camera != null \
		else Vector3.ZERO

## The server confirmed this player's damage landed. The hit marker, the number and the
## sound; nothing about a hit is drawn from the client's own prediction of its shot.
func _on_hit(info: Dictionary) -> void:
	if hud == null:
		return
	var point: Vector3 = info.get("point", Vector3.ZERO)
	var victim := game.player_for(int(info.get("victim_id", 0))) if game != null else null
	# Near zero rather than zero: the wire quantises, and "no point" comes back as a few
	# millimetres off the origin.
	if point.length() < 0.05 and victim != null:
		# A hit with no point (world damage passed on): the chest of who took it.
		point = victim.global_position + Vector3(0.0, 1.3, 0.0)
	var lethal := bool(info.get("lethal", false))
	hud.note_hit(int(info.get("victim_id", 0)), float(info.get("amount", 0.0)), point, bool(info.get("headshot", false)), lethal)
	if presentation != null:
		presentation.on_hit_confirmed(lethal)
		presentation.on_body_hit(int(info.get("victim_id", 0)), point, camera_position())
	_draw_body_hit(point)

## A stomp landed somewhere: its sound and puff where it happened.
func _on_stomp(info: Dictionary) -> void:
	if presentation != null:
		presentation.on_stomp(info["point"], StringName(info["sound"]), StringName(info["effect"]))

func _on_grenade_fx(info: Dictionary) -> void:
	if presentation != null:
		presentation.on_grenade_fx(info, player.player_id if player != null else 0)

## A kill's medals and points, as the server judged them. Every client hears every
## award; the HUD draws only the followed player's own and the nemesis line on their death.
func _on_award(info: Dictionary) -> void:
	if hud == null or game == null:
		return
	var own := player.player_id if player != null else 0
	var killer := game.player_for(int(info.get("killer_id", 0)))
	var victim := game.player_for(int(info.get("victim_id", 0)))
	hud.note_award(
		info, own,
		victim.display_name if victim != null else "?",
		killer.display_name if killer != null else "?"
	)
	if presentation != null and int(info.get("killer_id", 0)) == own and own != 0:
		presentation.on_medals(info.get("medals", []))

## The server sent the replay of the view that killed this player. Not over the final killcam.
## A kill view that arrived while this client still showed its player alive: the kill
## event leaves the server with the shot, the health that says dead comes a snapshot later.
## Played from [method _on_local_died]; dropped on respawn.
var _pending_killview: Array = []

func _on_killview(clip: Dictionary, info: Dictionary) -> void:
	if killview == null or (killcam != null and killcam.is_playing()):
		return
	# A living body owns the camera: playing now would throw the view to the killer's eye
	# for the snapshot interval before death is known here.
	if player != null and player.is_alive():
		_pending_killview = [clip, info]
		return
	_pending_killview = []
	var shown := info.merged({})
	shown["killer"] = String(info.get("killer", ""))
	shown["victim_id"] = player.player_id if player != null else 0
	var weapon := String(info.get("weapon", ""))
	var def: GSWeaponDef = FcPlayer.weapon_catalogue().get_def(StringName(weapon)) if weapon != "" else null
	shown["weapon"] = def.display_name if def != null and def.display_name != "" else weapon.capitalize()
	# Stamped before the play, so its watch holds the frame the play's own setup lands in.
	FcLoadTimeline.first_use("killview")
	var _started := killview.play(clip, shown)

## Where a roster row's player stands, for gs-game's look-to-gag key (J, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: FcPlayer in game.players():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null

## The level's layers: what the third-person and spectator cameras stop against.
func _level_mask() -> int:
	var stack := game.player_stack if game != null else null
	if stack != null and stack.physics != null and stack.physics.layout != null:
		return stack.physics.layout.mask_of([&"world", &"prop"])
	return 1

## Everybody else's drawn figure, for the camera fade.
func _other_figures() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.player_ids():
		var other := game.player_for(id)
		# During a replay our own body is posed like everybody else's, and can stand at its lens.
		if other != null and (other != player or _replay_lens() != null) and other.body_mesh != null:
			out.append(other.body_mesh)
	return out

## The camera a kill view or final killcam is drawing through, or null when neither plays.
func _replay_lens() -> Camera3D:
	if killview != null and killview.is_active() and killview.camera != null and killview.camera.current:
		return killview.camera
	if killcam != null and killcam.is_playing() and killcam.camera != null and killcam.camera.current:
		return killcam.camera
	return null

## The camera fade follows the camera on screen. It hangs off the player's camera, which a dead player's death camera keeps moving while a replay plays: left to itself it faded whoever the
## replay had posed near that unseen camera (a figure gone see-through mid-replay) and nothing at the replay's own lens (a torso filling the screen). Called after the replay has posed the bodies.
func _fade_for_replay(delta: float) -> void:
	var fade := player.camera.get_node_or_null(^"Fade") as GSCameraFade if player != null and player.camera != null else null
	if fade == null:
		return
	var lens := _replay_lens()
	if lens == null:
		if not fade.is_processing():
			fade.set_process(true)
		return
	fade.set_process(false)
	# Focus on the lens itself: the near test only, so a body inside the lens is hidden outright, and
	# at once: the replay steps at the killer's speed, and an eased fade left a torso solid for a frame.
	var _n := fade.update(lens.global_position, lens.global_position, maxf(delta, 1.0))

func _set_third_person(on: bool) -> void:
	if player == null:
		return
	player.third_person = on
	var fade := player.camera.get_node_or_null(^"Fade") as GSCameraFade if player.camera != null else null
	if fade != null:
		fade.focus = player.view if on else null

## The server changed `mp_forceview`: the view it now allows.
func _on_view_rules_changed() -> void:
	if player != null:
		_set_third_person(game.view_rules.resolve(player.third_person))

## The camera's two guards from gs-core, once a player is adopted.
func _guard_camera(p: FcPlayer) -> void:
	if p == null or p.camera == null:
		return
	p.third_person_mask = _level_mask()
	# Seen from behind, a player with no site avatar is the stock figure everybody else
	# already sees them as (the same document, from the same key), not a plain capsule.
	if p.avatar == null:
		p.rewear(FcAvatars.stock_avatar(StringName(FcGame.storage_key(p.player_id))))
	if p.camera.get_node_or_null(^"Fade") == null:
		var fade := GSCameraFade.new()
		fade.name = "Fade"
		fade.bodies_fn = _other_figures
		p.camera.add_child(fade)
	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	_set_third_person(game.view_rules.resolve(p.third_person))

## The hands under the camera, and the player's rig rebuilt to draw them.
func _arm(body: FcPlayer) -> void:
	if not _arm_begin(body):
		return
	_arm_mount(body)
	_arm_rig(body)
	_arm_end(body)

## [method _arm] with a frame between its three parts (an offline start's arming was 123 ms of one
## 460 ms frame on staging02), for a client that builds in frames; headless the frames are nothing.
func _arm_stepped(body: FcPlayer) -> void:
	if not _arm_begin(body):
		return
	await _setup_frame()
	_arm_mount(body)
	await _setup_frame()
	_arm_rig(body)
	_arm_end(body)

func _arm_begin(body: FcPlayer) -> bool:
	if body == null or body.camera == null or view_model != null:
		return false
	FcLoadTimeline.mark("arming")
	var started := Time.get_ticks_usec()
	view_model = AwViewModel.new()
	view_model.name = "Hands"
	view_model.feel_rules = game.feel_rules
	view_model.hands_depth_comp = FcViewArms.hold_depth_comp
	body.ads_rules = game.ads_rules
	view_model.ads_rules = game.ads_rules
	body.camera.add_child(view_model)
	FcLoadTimeline.mark("arming: view model, %d ms" % ((Time.get_ticks_usec() - started) / 1000))
	return true

func _arm_mount(body: FcPlayer) -> void:
	var started := Time.get_ticks_usec()
	view_arms = FcViewArms.mount(self, view_model, body, FcAvatars.look_of(body.avatar, StringName("arena-player-%08d" % body.player_id)), game)
	FcLoadTimeline.mark("arming: arms mounted, %d ms" % ((Time.get_ticks_usec() - started) / 1000))

func _arm_rig(body: FcPlayer) -> void:
	var started := Time.get_ticks_usec()
	body.arm_first_person(view_model, _offline)
	if body.weapons != null:
		_wrap_suppressed(body.weapons.shot_fx())
	FcLoadTimeline.mark("arming: first-person rig, %d ms" % ((Time.get_ticks_usec() - started) / 1000))

func _arm_end(body: FcPlayer) -> void:
	FcLoadTimeline.mark("hands armed")
	if _builds_in_frames():
		# Each in a frame of its own: the arming and both starts shared one frame with the joins.
		get_tree().process_frame.connect(_prewarm_weapons_next_frame, CONNECT_ONE_SHOT)
	else:
		_prewarm_weapons.call_deferred(body)
		_prewarm_models.call_deferred()

## A frame boundary between setup steps, under the cover, in a client that draws. The build was one
## 2.7 s frame on staging02 (setup 1012 ms, then the first draw 672 ms, the 32 players 320 ms and the
## arming): a window that stops drawing that long reads as hung. The client's own frame and tick stay off
## until setup ends, and the tree's multiplayer is not polled across the boundary: a link can already be
## joined (the sim host, a shell's server) and its messages would reach the game's net node before the
## netcode builds it, and be dropped. They wait in the peer instead, as they did behind the one long frame.
## Headless (suites, servers) builds in one go, as before.
func _setup_frame() -> void:
	if not _builds_in_frames():
		return
	_set_client_processing(false)
	var tree := get_tree()
	var polling := tree.multiplayer_poll
	tree.multiplayer_poll = false
	await tree.process_frame
	tree.multiplayer_poll = polling

## The client's own frame, tick and keys, off while `_ready` waits part-built (the sim host's boot, `_setup_frame`).
func _set_client_processing(on: bool) -> void:
	set_process(on)
	set_physics_process(on)
	set_process_input(on)
	set_process_unhandled_input(on)

## Whether setup is spread over frames: in a client that draws, and not headless (see `_setup_frame`).
func _builds_in_frames() -> bool:
	return not GSPlatform.is_headless() and is_inside_tree()

func _prewarm_weapons_next_frame() -> void:
	_prewarm_weapons(player)
	get_tree().process_frame.connect(_prewarm_models, CONNECT_ONE_SHOT)

## One tick of weapon use, predicted. An outcome rather than a shot, because a use is
## not always one: a rocket produces a spawn and no shot at all, and a burst produces
## several shots that are all one trigger pull.
func _on_local_used(outcome: GSWeaponOutcome) -> void:
	if presentation == null or outcome == null or not outcome.used:
		return

	presentation.on_used(outcome, weapon_draws_shots())

func _on_local_wall_run(running: bool) -> void:
	if presentation != null:
		var _voice := presentation.on_wall_run(running)

## The jump-started run turns the look input along the wall.
func _on_local_view_turned(degrees: float) -> void:
	_view_turn_left += degrees

func _on_local_wall_jumped() -> void:
	if presentation != null:
		var _voice := presentation.on_wall_jumped()

func _on_local_damaged(damage: GSDamage) -> void:
	if player != null and player.controller != null:
		var held := player.weapons.current_def() if player.weapons != null else null
		var scale := game.ads_rules.hit_flinch_for(held.id) if held != null and game != null else 1.0
		_aim_break.note_hit(Time.get_ticks_msec() * 0.001, player.controller.tunables, damage.amount, scale)
	_note_hit_direction(damage)
	if presentation != null:
		presentation.on_hurt(damage.amount, player != null and player.health != null and not player.health.alive)

## Points the HUD at what hurt the local player: the attacker's body, else back along the shot. Fall and world damage have neither.
func _note_hit_direction(damage: GSDamage) -> void:
	if hud == null or hud.damage_dirs == null or player == null or damage.attacker == player.player_id:
		return
	var source: Vector3 = Vector3.INF
	var shooter: FcPlayer = game.player_for(damage.attacker) if game != null and damage.attacker != 0 else null
	if shooter != null and shooter != player:
		source = shooter.global_position
	elif damage.direction.length_squared() > 0.0001:
		source = player.global_position - damage.direction.normalized() * 10.0
	if source != Vector3.INF:
		hud.damage_dirs.note_hit(source)


func _on_local_died(_damage: GSDamage) -> void:
	if presentation == null or player == null:
		return
	FcLoadTimeline.first_use("death")
	var where := Transform3D.IDENTITY
	where.origin = player.global_position
	presentation.on_died(where)
	if not _pending_killview.is_empty():
		var held: Array = _pending_killview
		_pending_killview = []
		_on_killview(held[0], held[1])

## Connects the local player's own noises and pictures.
##
## [b]Only the local player's.[/b] Somebody else being hurt is their business: a damage
## tint for every player in the match would be a screen that is permanently red, and a
## shake for somebody else's rifle would make a crowded room unplayable. What everybody
## hears is the positional half -- the shot, the impact -- which comes from the world.
func _hear_the_local_player() -> void:
	if presentation == null or player == null:
		return

	presentation.on_spawned()
	_pending_killview = []

	if player.health != null and not player.health.damaged.is_connected(_on_local_damaged):
		player.health.damaged.connect(_on_local_damaged)
		player.health.died.connect(_on_local_died)

	# The wall moves, predicted like the shot below and for the same reason: a sound never
	# changes the simulation. The controller does not emit either during a replay, so a
	# corrected tick is never heard twice.
	var controller := player.controller
	if controller != null and not controller.wall_run_changed.is_connected(_on_local_wall_run):
		controller.wall_run_changed.connect(_on_local_wall_run)
		controller.wall_jumped.connect(_on_local_wall_jumped)
		controller.view_turned.connect(_on_local_view_turned)

	if not player.used.is_connected(_on_local_used):
		# The PREDICTED use, on the client that made it. Waiting for the server's
		# confirmation would put the bang a round trip after the click, which is the one
		# piece of feedback a player judges the whole game's responsiveness by -- and it
		# is safe to predict for exactly the reason gs-fx is built the way it is: a sound
		# never changes the simulation, so a shot the server later refuses cost a noise.
		#
		# FcPlayer.used rather than arsenal.used, because FcPlayer already forwards
		# it and is the one node this client is handed. Going through the arsenal means
		# reaching two levels into somebody else's addon for a signal the player above it
		# re-emits unchanged.
		player.used.connect(_on_local_used)

func _on_beacon_pulsed(at: Vector3) -> void:
	if presentation != null:
		var _voice := presentation.on_beacon(at)

## Plays a beacon's ping wherever its ripple goes out, for [param body] — every player,
## this client's own included: somebody who has been beaconed should hear it too.
##
## From both [method _on_player_added] and [method _adopt], because a player found by
## `_watch` is adopted without passing through the first, and the connection is guarded so
## the two never make it twice.
func _hear_beacon(body: FcPlayer) -> void:
	if body == null or body.beacon_pulsed.is_connected(_on_beacon_pulsed):
		return

	body.beacon_pulsed.connect(_on_beacon_pulsed)

## The field of view to use: the player's own, under any cap a server has applied.
func _field_of_view() -> float:
	if presentation == null:
		return FIELD_OF_VIEW
	return float(presentation.settings.get_int(&"field_of_view", int(FIELD_OF_VIEW)))

func _build_interface() -> void:
	hud = FcHud.new()
	hud.name = "Hud"
	add_child(hud)
	hud.build(game)
	# The hit pulse at the screen's edge is gs-fx's hurt flash, drawn: so it obeys the
	# player's "no flashes" and the flash rate limit like every other flash.
	if presentation != null:
		hud.flash_source = presentation.fx

	# The server browser: the one page that is about something other than this game.
	browser = FcBrowser.new()
	browser.name = "Browser"
	add_child(browser)
	var listed := browser.setup()
	GSLog.result(CHANNEL, "the server browser", listed)
	browser.join_requested.connect(_on_join_requested)

	# [b]gs-menu's menu, and the client still owns the pointer.[/b] The menu is told not to manage
	# it: pointer lock needs a click in a browser, which only this client knows about.
	game_menu = FcMenus.build(self, presentation, browser if listed.ok else null)
	# The help card lists the server's commands only when it knows it is on a server; _offline is set before this runs.
	FcMenus.set_help_online(game_menu.help, not _offline)
	# The HUD in the menu's theme and at the player's HUD size, switched live (gs-menu 7). By
	# name, so a client shell older than that still runs the game in gs-ui's dark default.
	if game_menu.has_method(&"follow_hud"):
		game_menu.call(&"follow_hud", hud, FcHud.accent_theme())
	_touch = FcTouch.build(self, hud, _sampler, game.mobile_rules, game_menu.menu_button) as FcTouch
	if GSPlatform.has_touch() and _touch.get(&"buttons") != null and platform.has_method(&"fit_touch_buttons"):
		platform.call(&"fit_touch_buttons", _touch.buttons, FcTouch.LAYOUT)
	# M: the maps and the modes (gs-menu's map menu).
	if game_menu.has_method(&"use_maps"):
		var maps: Variant = game_menu.call(&"use_maps", map_menu_rows, change_from_menu)
		if maps is Object:
			(maps as Object).set(&"noun", "maps and modes")
			# The server's rows say "Mode" or "Map" on their mode line; a mode pick is kept and the next map pick carries it.
			if &"mode_group" in maps:
				(maps as Object).set(&"mode_group", "Mode")
	_use_loadout_menu()
	# Solo: a converted map dragged onto the window joins M as "(local)".
	watch_map_drops()
	if game_menu.has_method(&"use_teams"):
		var offer := Callable()
		var choose := Callable()
		if _offline:
			_local_team_menu = FcTeamMenu.new()
			var pair := _local_team_menu.bind_local(game, func() -> int: return player.player_id if player != null else 0)
			offer = pair[0]
			choose = pair[1]
		var teams: Variant = game_menu.call(&"use_teams", offer, choose)
		if teams is Object:
			_link_menu(teams as Object)
	platform.add_store_panel(game_menu, func() -> String:
		var key := loadout_account_key(GSRegistry.get_node_service(AUTH_SERVICE))
		return "" if key == "local" else key)
	game_menu.action_requested.connect(func(id: StringName) -> void:
		if id != FcMenus.LEAVE:
			return
		# Closed first, so a client that cannot actually leave (an embedded one, a
		# single-process test) is not left showing a menu over a game that carried on.
		game_menu.close()
		leave_requested.emit())
	# The menu, its help or the console opening or closing: the pointer and the sampler.
	game_menu.overlays_changed.connect(func(_open: bool) -> void:
		_apply_mouse())

	_build_interface_part2()


func _build_interface_part2() -> void:
	board = FcMenus.Board.new(
		game_menu.scoreboard, game.match_node.scoreboard,
		link if not _offline else null, game.match_node.teams, game
	)

	if presentation != null:
		applier = GSMenuApplier.new()
		applier.name = "Applier"
		applier.settings = presentation.settings
		add_child(applier)
		applier.bind_audio(presentation.audio)
		applier.bind_fx(presentation.fx)
		GSLog.result(CHANNEL, "the settings applier", applier.setup())
		presentation.settings.changed.connect(func(key: StringName, value: Variant, _w: StringName) -> void:
			if key == &"hud_safe_area" and hud != null:
				hud.set_safe_area(float(value))
			elif presentation.bindings.row_for_setting(key).size() > 0:
				# Deferred: the table applies a rebound row after the setting changes. Any
				# row, not only Duck's: one given C takes C off the slide.
				_add_slide_key.call_deferred()
				_hud_keys.call_deferred())
		hud.set_safe_area(presentation.settings.get_float(&"hud_safe_area", 16.0))
	_build_interface_rest()

func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if presentation != null and presentation.audio != null:
		var _played := presentation.audio.play_at(id, at, clampf(volume, 0.3, 1.0))

## The dead bodies' yard: the game's ragdoll rules, the world's collision layers, and the
## presentation's sound. Built once; cleared on a map change.
func _build_ragdolls() -> void:
	ragdolls = GSPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	var stack := game.player_stack
	if stack != null and stack.physics != null and stack.physics.layout != null:
		# The level is classified onto `world` (see `_classify_level`); props are on `prop`.
		game.ragdoll_rules.collision_mask = stack.physics.layout.mask_of([&"world", &"prop"])
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)
	# The map's toys are heard the same way: a bounce, a knock, a barrel's roll.
	if not game.toy_sound.is_connected(_ragdoll_sound):
		var _toys := game.toy_sound.connect(_ragdoll_sound)


## The profiler's game context and native timers, now if it is up and when it arrives if not.
func _install_profiler_context() -> void:
	var prof: Object = GSRegistry.get_service(&"gs_profiler")
	if prof != null:
		FcProfilerContext.install(prof, game, _bot_host(), presentation)
		return
	# Not one-shot: that would spend the connection on whichever service registers next, usually not the profiler.
	if not GSRegistry.signals().service_registered.is_connected(_on_profiler_registered):
		var _c := GSRegistry.signals().service_registered.connect(_on_profiler_registered)


func _on_profiler_registered(svc_name: StringName, inst: Object) -> void:
	if svc_name != &"gs_profiler":
		return
	GSRegistry.signals().service_registered.disconnect(_on_profiler_registered)
	FcProfilerContext.install(inst, game, _bot_host(), presentation)


## Opens the attachments menu on the local player's gun in hand (the Attachments key); false when it has
## nothing to fit. A pick is a request to the server, which alone fits (`FcAttach.serve`).
func open_attachments() -> bool:
	if player == null or not player.is_alive() or player.arsenal == null:
		return false
	if attach_panel == null:
		attach_panel = FcAttachPanel.new()
		attach_panel.name = "AttachPanel"
		attach_panel.arsenal_fn = func() -> GSWeaponArsenal:
			return player.arsenal if player != null and player.is_alive() else null
		attach_panel.send_fn = func(body: PackedByteArray) -> void:
			if bridge != null and not _offline:
				bridge.send_request(FcEvents.Ask.ATTACH, body)
		add_child(attach_panel)
		attach_panel.open_changed.connect(func(open: bool) -> void:
			if platform != null and open:
				platform.hold_pointer(&"attach")
			elif platform != null:
				platform.release_pointer(&"attach")
			_apply_mouse())
	# Offline the panel fits the arsenal itself: there is no server to ask.
	if _offline:
		attach_panel.send_fn = Callable()
	return attach_panel.open()


## Wraps [param fx]'s report so a gun with a suppressor on plays the suppressed set (`FcAttach.wrap_report`).
func _wrap_suppressed(fx: AwShotFx) -> void:
	FcAttach.wrap_report(fx, func(at: Vector3) -> bool: return FcAttach.play_suppressed(presentation, at))


## Offline, before the first map is read: a solo start map that is a delivered pack not yet mounted is fetched and mounted under the boot cover, with its progress, so [method _startup_map] finds it and the game is built on
## it directly, with no dm_box built first only to be replaced. A failed fetch is logged and leaves dm_box to [method _start_on_solo_map], which says the failure on the cover the way M would.
func _fetch_solo_start_map() -> void:
	var start := StringName(_solo_start_map())
	if not _offline or start == &"" or FcMap.by_id(start) != null:
		return
	if not FcMaps.is_delivered(_catalogue().get_map(start)):
		return
	var fetched: GSResult = await _fetch_picked(start)
	GSLog.result(CHANNEL, "solo start map %s fetched before the first map" % start, fetched)


## A solo start map this build does not hold is a delivered pack: once the first level is up, it
## changes to it the way M would, so the download shows on the load cover. A built-in one, or a pack
## [method _fetch_solo_start_map] already mounted, was the first map ([method _startup_map]).
func _start_on_solo_map() -> void:
	var start := StringName(_solo_start_map())
	if not _offline or start == &"" or game == null or (game.map != null and game.map.id == start):
		return
	if _catalogue().get_map(start) == null:
		GSLog.warn(CHANNEL, "the solo start map is not a map this game lists", {"map": start})
		return
	GSLog.result(CHANNEL, "solo start map %s" % start, await change_from_menu(StringName("map:%s" % start)))
