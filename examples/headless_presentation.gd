extends "headless_presentation_bodies_and_map_menu.gd"

const FcFlashlight := preload("../game/fc_flashlight.gd")
const FcTeamBodies := preload("../game/fc_team_bodies.gd")
const FcMapPaint := preload("../maps/fc_map_paint.gd")
const FcNewerApi := preload("../game/fc_newer_api.gd")
const FcConfigScript := preload("../game/fc_config.gd")


func _ready() -> void:
	# Before anything builds a presentation layer: every settings document this suite writes
	# goes to a scratch directory emptied first, never this machine's real one.
	_player_file_was = _player_file_stamp()
	var _scratch := FcPresentation.use_scratch_settings("headless_presentation")
	GSLog.set_level(
		GSLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else GSLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact: the presentation layer")

	_test_schema()
	_test_the_weapon_art_is_vendored()
	_test_audio_is_a_firefight()
	_test_ambience_is_quiet_and_obeys_settings()
	_test_effects_and_the_player_who_asked_for_none()
	await _test_a_shot_is_drawn()
	_test_shake_is_computed_not_applied()
	await _test_blood()
	_test_console()
	await _test_console_stops_movement()
	_test_the_escape_menu()
	_test_every_key_is_an_action()
	_test_party_is_sandboxed()
	await _test_party_over_http()
	_test_chat_box()
	_test_look_and_crosshair()
	_test_mouse_drives_view()
	_test_vote_is_heard()
	_test_blind_and_beacon()
	_test_a_respawn_faces_its_spawn()
	_test_the_final_killcam()
	await _test_the_kill_view()
	_test_the_view_turns_every_frame()
	_test_remote_beams_follow_the_light()
	_test_own_body()
	_test_criticals_and_the_body()
	await _test_bodies_fall()
	_test_feedback_from_the_wire()
	_test_stock_avatars_differ()
	_test_team_bodies_fall_back()
	_test_team_bodies_from_pack()
	await _test_hud_fits_the_frame()
	_test_hud_makes_room_for_a_ballot()
	await _test_the_map_menu()
	await _test_the_loadout_menu()
	_test_click_keeps_modal_pointer()
	await _test_the_hud_follows_the_theme()
	_test_texture_quality_reaches_the_map_art()

	print("")
	_check(
		_player_file_stamp() == _player_file_was,
		"the player's own settings file was not touched",
		FcPresentation.PLAYER_SETTINGS
	)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


## The levels of the addons the live shell ships, `requires.pins.json` (refresh it when a shell ships; same shape as requires.floor.json), so a floor is judged against what the shell has, not the linked head. Where gs-server-deploy's addons.lock is reachable it must pin at least these levels, or the file claims more than any shell will have.
func _pinned_levels() -> Dictionary:
	var read := GSAddonApi.parse(FileAccess.get_file_as_string("res://requires.pins.json"), "requires.pins.json")
	return read.value as Dictionary if read.ok else {}


func _lock_covers(pins: Dictionary) -> String:
	for root in [OS.get_environment("GS_REPOS_ROOT"), "/home/gamedev/godot", "/home/gamedev/projects/godot"]:
		var lock := str(root).path_join("gs-server-deploy/addons.lock")
		if str(root) != "" and FileAccess.file_exists(lock):
			var locked := GSAddonApi.pinned_levels(lock, str(root))
			for addon in pins:
				if locked.has(addon) and int(locked[addon]) < int(pins[addon]):
					return "%s is %d in requires.pins.json, %d in addons.lock" % [addon, pins[addon], locked[addon]]
	return ""


## Every key `FcClient` reads is a row in `FcBindings`; the action names are written out here
## so a missing row fails the check rather than shrinking the table.
func _test_every_key_is_an_action() -> void:
	_section("Every key the client reads is an action in the table, rebound live and kept")

	var p := _make(false)
	var expected := {
		&"arena_fire": "Mouse 1", &"arena_aim": "Mouse 2", &"arena_bash": "X", &"arena_flashlight": "F",
		&"arena_reload": "R", &"arena_inspect": "L", &"arena_slot_1": "1", &"arena_slot_2": "2", &"arena_slot_3": "3",
		&"arena_slot_4": "4", &"arena_slot_5": "5", &"arena_weapon_previous": "Wheel up",
		&"arena_weapon_next": "Wheel down", &"arena_weapon_last": "Z", &"arena_launch": "E",
		&"arena_launch_props": "P", &"arena_punt": "G", &"gs_voice_talk": "V",
		&"gs_fps_walk": "Alt", &"arena_fire_mode": "N",
	}
	var wrong: Array[String] = []
	for action: StringName in expected:
		if p.bindings.row_for_action(action).is_empty() \
				or GSInputBinding.describe_action(action) != str(expected[action]):
			wrong.append("%s=%s" % [action, GSInputBinding.describe_action(action)])
	_check(wrong.is_empty(), "each is a row and on its default key in the InputMap", str(wrong))

	_check_mode_label()

	# The wheel rows by name: a pack asks for gs-ui 4, which names the wheel (level 2).
	var named := FcBindings.make().row_for_action(&"arena_weapon_previous")
	_check(
		str(named["label"]) == "Previous weapon" and str(named["default"]) == "Wheel up",
		"the wheel rows say Wheel up / Wheel down", str(named)
	)

	_check_floors()

	# One key, one meaning: V is push to talk and nothing else; the sampler reads no noclip.
	var sampler := FcClient.make_sampler()
	_check(
		str(sampler.actions.get("noclip", &"")) == "" and not InputMap.has_action(&"gs_fps_noclip"),
		"the sampler has no noclip key, so V is not gs_fps_noclip's",
		str(sampler.actions.get("noclip"))
	)
	var on_v: Array[String] = []
	for row in p.bindings.rows:
		if p.bindings.stored(row, p.settings) == "V":
			on_v.append(str(row["action"]))
	_check(on_v == ["gs_voice_talk"], "and V is on one row, push to talk (gs-voice's action)", str(on_v))

	# A client with this presentation and a stand-in player, not in the tree (see
	# `_test_mouse_drives_view`); the pointer counts as captured.
	var client := FcClient.new()
	var stand_in := FcPlayer.new()
	client.player = stand_in
	client.presentation = p
	client._sampler = sampler
	client.mouse_capture_override = true

	# Fire, moved to K: K fires and Mouse 1 no longer does.
	var res := p.bindings.rebind(p.bindings.row_for_action(&"arena_fire"), "K", p.settings)
	_check(res.ok and p.settings.get_string(&"bind_fire") == "K", "Fire rebinds to K and is stored", str(res))
	_press(GSInputBinding.from_text("K"), true)
	client._read_fire(GSFpsCommand.new())
	var k_fires := client._fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK)
	_press(GSInputBinding.from_text("K"), false)
	_press(GSInputBinding.from_text("Mouse 1"), true)
	client._read_fire(GSFpsCommand.new())
	var mouse_fires := client._fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK)
	_press(GSInputBinding.from_text("Mouse 1"), false)
	_check(k_fires and not mouse_fires, "then K pulls the trigger and Mouse 1 does not",
		"K %s, Mouse 1 %s" % [k_fires, mouse_fires])

	# Reload, through the same polling path.
	res = p.bindings.rebind(p.bindings.row_for_action(&"arena_reload"), "Z", p.settings)
	_press(GSInputBinding.from_text("Z"), true)
	client._read_fire(GSFpsCommand.new())
	var z_reloads := client._fire.is_pressed(GSWeaponCommand.BUTTON_RELOAD)
	_press(GSInputBinding.from_text("Z"), false)
	_check(res.ok and z_reloads, "Reload rebound to Z reloads on Z")

	# F is the flashlight and X the melee, through the same polling path.
	client._unhandled_input(_key_event("F", true))
	client._read_fire(GSFpsCommand.new())
	var f_lights := client._fire.is_pressed(FcFlashlight.BUTTON)
	client._flash_ticks = 0
	_press(GSInputBinding.from_text("X"), true)
	client._read_fire(GSFpsCommand.new())
	var x_bashes := client._fire.is_pressed(GSWeaponCommand.BUTTON_ALT)
	_press(GSInputBinding.from_text("X"), false)
	_check(f_lights and x_bashes, "F sends the flashlight button and X the melee",
		"F %s, X %s" % [f_lights, x_bashes])

	# A slot, through `_unhandled_input`: J asks for slot 3, and 3 asks for nothing.
	res = p.bindings.rebind(p.bindings.row_for_action(&"arena_slot_3"), "J", p.settings)
	client._wanted_slot = 0
	client._unhandled_input(_key_event("J", true))
	var j_slot := client._wanted_slot
	client._wanted_slot = 0
	client._unhandled_input(_key_event("3", true))
	_check(res.ok and j_slot == 3 and client._wanted_slot == 0,
		"Slot 3 rebound to J: J asks for slot 3 and 3 asks for nothing",
		"J %d, 3 %d" % [j_slot, client._wanted_slot])

	# The props-mode remap: in Siege the Launch key grabs, the Bash key freezes and the
	# launch moves to its own row; anywhere else the Launch key launches and grabs nothing.
	var g := FcGame.new()
	client.game = g
	g.shown_mode = FcMode.free_for_all()
	client.last_prop_asked = -1
	client._unhandled_input(_key_event("E", true))
	_check(client.launch_action() == &"arena_launch" and client.last_prop_asked == -1,
		"outside a props mode E is the launch and asks the prop tool for nothing")
	g.shown_mode = FcMode.siege()
	client._holding = false
	client._unhandled_input(_key_event("E", true))
	var e_grabs := client.last_prop_asked == FcEvents.PropAct.GRAB
	client._unhandled_input(_key_event("X", true))
	var f_freezes := client.last_prop_asked == FcEvents.PropAct.FREEZE
	client._unhandled_input(_key_event("G", true))
	var g_punts := client.last_prop_asked == FcEvents.PropAct.PUNT
	_check(e_grabs and f_freezes and g_punts and client.launch_action() == &"arena_launch_props",
		"in Siege E grabs, X freezes, G punts and the launch is P's",
		"grab %s freeze %s punt %s launch %s" % [e_grabs, f_freezes, g_punts, client.launch_action()])
	res = p.bindings.rebind(p.bindings.row_for_action(&"arena_launch"), "T", p.settings)
	client._holding = false
	client.last_prop_asked = -1
	client._unhandled_input(_key_event("E", true))
	var e_after := client.last_prop_asked
	client._unhandled_input(_key_event("T", true))
	_check(res.ok and e_after == -1 and client.last_prop_asked == FcEvents.PropAct.GRAB,
		"and with Launch moved to T, the grab moves with it",
		"E %d, T %d" % [e_after, client.last_prop_asked])
	client.game = null
	_test_every_key_rest(p, client, stand_in, g)


## requires.floor.json and requires.pins.json are sound, and what a pack asks a shell for.
func _check_floors() -> void:
	# A branch only matters if an older shell gets to run it.
	var floors := GSAddonApi.parse(FileAccess.get_file_as_string("res://" + GSAddonApi.FLOOR_FILE), GSAddonApi.FLOOR_FILE)
	var derived := GSAddonApi.derive()
	var unsound := GSAddonApi.floor_audit(floors.value if floors.ok else {}, derived, GSAddonApi.guarded(), {}, _pinned_levels()) \
		if floors.ok else PackedStringArray([str(floors.error)])
	_check(unsound.is_empty(), "requires.floor.json is sound: every floor has a guard behind it", str(unsound))
	var pins := _pinned_levels()
	var behind := _lock_covers(pins)
	_check(not pins.is_empty() and behind == "", "requires.pins.json is read and addons.lock pins nothing lower", behind)
	# A floor with no pin is judged against the linked head, not the shell: gs-weapon 42 and fc-weapons 31 went in that way
	# (2026-11-16), the pack asked for levels no shell had, and on Gamespice the bot brain and the HUD did not compile.
	var unpinned: Array[String] = []
	for addon in (floors.value as Dictionary if floors.ok else {}):
		if not pins.has(addon):
			unpinned.append(str(addon))
	_check(unpinned.is_empty(), "every floored addon has the shell's level in requires.pins.json", str(unpinned))
	var asked := GSAddonApi.apply_floors(derived, floors.value if floors.ok else {})
	_check(
		asked.get("gs_ui") == 23 and asked.get("gs_lighting") == derived.get("gs_lighting") \
			and int(asked.get("gs_lighting", 0)) >= 3,
		"so a pack asks a shell for gs-ui 23 (the health tag) and the gs-lighting it was built on (3+, painted())", str(asked)
	)


## The ammo line names the fire mode and its key only on a gun with a selector.
func _check_mode_label() -> void:
	var two := GSWeaponDef.new()
	two.display_name = "Rifle"
	two.fire_modes = GSWeaponDef.selector_modes(GSWeaponDef.Fire.AUTO, true)
	var one := GSWeaponDef.new()
	one.display_name = "Pistol"
	var two_slot := GSWeaponSlot.new()
	two_slot.def = two
	var one_slot := GSWeaponSlot.new()
	one_slot.def = one
	_check(
		FcHud.mode_label(two_slot, "N") == "Rifle  AUTO [N]" and FcHud.mode_label(one_slot, "N") == "Pistol",
		"the ammo line names the fire mode and its key on a gun with a selector, and only then",
		"%s / %s" % [FcHud.mode_label(two_slot, "N"), FcHud.mode_label(one_slot, "N")]
	)


func _test_every_key_rest(p: FcPresentation, client: FcClient, stand_in: FcPlayer, g: FcGame) -> void:
	g.free()

	# Kept: what was rebound is in the document, and a new presentation reading it puts it back on
	# the InputMap. The InputMap is put on the default first, so only the load can have moved it.
	var flushed := p.settings.flush()
	GSInputBinding.apply(&"arena_reload", "R")
	var p2 := _make(false)
	_check(
		flushed.ok and p2.settings.get_string(&"bind_reload") == "Z"
			and GSInputBinding.describe_action(&"arena_reload") == "Z",
		"a saved binding is read back and applied by the next start",
		"stored %s, bound %s" % [p2.settings.get_string(&"bind_reload"), GSInputBinding.describe_action(&"arena_reload")]
	)

	p2.bindings.reset_all(p2.settings)
	var _flushed := p2.settings.flush()
	_check(GSInputBinding.describe_action(&"arena_fire") == "Mouse 1", "and Reset puts Fire back on Mouse 1")

	client.player = null
	client.presentation = null
	stand_in.free()
	client.free()
	p.queue_free()
	p2.queue_free()
	_done()


func _test_party_is_sandboxed() -> void:
	_section("A private match files nothing anywhere")

	GSP2PSignallerLoopback.reset_all()

	var party := FcParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	# The decision this game makes and the lobby does not: Fatal Contact reports to gs-stats, unlocks gs-
	# achievements and files to gs-leaderboard.
	_check(
		party.session.config.trust == GSP2PConfig.Trust.SANDBOXED,
		"a private arena match is sandboxed, because a host who can cheat and a "
		+ "leaderboard are one exploit rather than two features"
	)
	_check(
		not party.session.config.migrate_host,
		"and does not migrate: the host holds the match clock, the score and every hitbox, "
		+ "and handing that over mid-round produces a round nobody can agree about"
	)

	_check(party.reporting_allowed(), "an ordinary match files what it likes")
	party.session.lobby.add_member(&"me", "Me", 0)
	party.session.lobby.host_id = &"me"
	party.session._state = &"hosting"
	_check(
		not party.reporting_allowed(),
		"and a live private match files nothing, asked in one place rather than by four reporters"
	)

	party.queue_free()
	_done()


## `[p2p-await-games]`: a private match over the HTTP rendezvous, host and join, each awaited end to
## end — through `FcParty`, `GSP2PSession` and `GSP2PSignallerHttp` to a socket and back.
func _test_party_over_http() -> void:
	_section("A private match that meets over HTTP waits for the answer")

	var stub := RendezvousStub.new()
	stub.name = "Rendezvous"
	add_child(stub)
	var listening := stub.start()
	_check(listening, "a stand-in rendezvous listens on a local port", str(stub.port))

	if not listening:
		stub.queue_free()
		_done()
		return

	var url := "http://127.0.0.1:%d/p2p" % stub.port
	var ada := FcParty.new()
	ada.name = "PartyAda"
	ada.signalling_url = url
	add_child(ada)
	var bob := FcParty.new()
	bob.name = "PartyBob"
	bob.signalling_url = url
	add_child(bob)

	_check(
		ada.setup().ok and bob.setup().ok
			and ada.session.signaller is GSP2PSignallerHttp
			and bob.session.signaller is GSP2PSignallerHttp,
		"two parties set up with a URL, and both meet over HTTP rather than the loopback"
	)

	var opened: Array[String] = []
	ada.open.connect(func(code: String) -> void: opened.append(code))

	var before := Engine.get_process_frames()
	var hosted: GSResult = await ada.host("Ada")
	var took := Engine.get_process_frames() - before
	var code := str(hosted.value) if hosted != null and hosted.ok else ""

	_check(
		hosted != null and hosted.ok and GSP2PLobby.is_code_shaped(code, ada.session.config.code_length),
		"host() hands back a join code",
		str(hosted.error.message) if hosted != null and not hosted.ok else "null"
	)
	_check(took >= stub.delay,
		"only once the rendezvous has answered: %d frames, the stub waits %d" % [took, stub.delay])
	_check(
		stub.seen.size() >= 1 and stub.seen[0]["route"] == "host"
			and str((stub.seen[0]["body"] as Dictionary).get("code", "")) == code
			and str(((stub.seen[0]["body"] as Dictionary).get("info", {}) as Dictionary).get("name", "")) == "Ada",
		"and it is the code the rendezvous was told, under the host's name",
		str(stub.seen)
	)
	_check(ada.active() and ada.session.is_host() and opened == [code],
		"the match is open, hosted, and says so once",
		"state %s, opened %s" % [ada.session.state(), str(opened)])
	_check(not ada.reporting_allowed(),
		"and a private match that met over a real rendezvous files nothing either")

	before = Engine.get_process_frames()
	var joined: GSResult = await bob.join(code.to_lower(), "Bob")
	took = Engine.get_process_frames() - before

	_check(joined != null and joined.ok and took >= stub.delay,
		"join() waits for the rendezvous too (%d frames) and succeeds" % took,
		str(joined.error.message) if joined != null and not joined.ok else "null")
	_check(
		stub.seen.size() >= 2 and stub.seen[1]["route"] == "join"
			and str((stub.seen[1]["body"] as Dictionary).get("code", "")) == code,
		"under the code as the host has it, not as it was typed",
		str(stub.seen)
	)
	_check(
		bob.session.lobby.has(ada.session.local_id) and not bob.session.is_host(),
		"and the joiner learns who is already there from the answer, and does not elect itself",
		str(bob.session.lobby.member_ids())
	)

	# A refusal arrives as a failure the caller can read, not as null and not as success.
	bob.leave()
	var carol := FcParty.new()
	carol.name = "PartyCarol"
	carol.signalling_url = url
	add_child(carol)
	var _set := carol.setup()
	stub.refuse = 403
	var refused: GSResult = await carol.host("Carol")
	_check(refused != null and not refused.ok and not carol.active(),
		"and a rendezvous that refuses leaves the match closed with a reason",
		"null" if refused == null else ("ok" if refused.ok else refused.error.message))

	ada.leave()
	for node: Node in [ada, bob, carol, stub]:
		node.queue_free()
	_done()


## A team body that is not on this machine leaves that side its own looks, and off a team mode nobody wears one.
func _test_team_bodies_fall_back() -> void:
	_section("Team avatars fall back to the player's own look")
	var key := StringName(FcGame.storage_key(140))
	var own := FcAvatars.look_of(null, key)
	var got := FcTeamBodies.register("fc_no_such_body,", "user://no_such_dir")
	_check(got.size() == 2 and got[0] == &"" and got[1] == &"", "a missing body registers nothing", str(got))
	_check(FcTeamBodies.wear_key(1) == "" and FcTeamBodies.wear_key(2) == "", "no side wears a body off a team mode")
	var worn := FcTeamBodies.look_of(null, key, 1)
	_check(worn.body == own.body and worn.top == own.top, "a side without a body keeps the player's look",
		"%s/%s vs %s/%s" % [worn.body, worn.top, own.body, own.top])
	var _reset := FcTeamBodies.register("", "")
	if FcTeamBodies.has_bodies():
		var assets := FcNewerApi.script_of(&"GSHumanoidAssets")
		var was: Variant = assets.get(&"team_tint")
		assets.set(&"team_tint", 0.5)
		_check(is_equal_approx(float(assets.get(&"team_tint")), 0.5), "gs-player-char's team tint is set through its class found by name", str(assets.get(&"team_tint")))
		assets.set(&"team_tint", was)
	_done()


## The team bodies arrive from the fc-player-classes pack (content.lock.json store entry into res://assets/team_bodies),
## not from a private folder: the default search path names that folder, a web build prefers the pack's WebP body, and
## the fetched files (when fetched) are found and registered.
func _test_team_bodies_from_pack() -> void:
	_section("Team bodies come from the fc-player-classes pack")
	var dirs := String(FcConfigScript.new().team_body_dirs)
	_check(dirs.contains("res://assets/team_bodies") and not dirs.contains("private"), "the default dirs name the fetched pack folder, no private one", dirs)
	_check(FcTeamBodies.file_names("fc_swat", false) == PackedStringArray(["fc_swat.glb"]), "a desktop build wants <id>.glb")
	_check(FcTeamBodies.file_names("fc_swat", true) == PackedStringArray(["fc_swat.webp.glb", "fc_swat.glb"]), "a web build wants <id>.webp.glb first, then <id>.glb")
	var lock: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://content.lock.json"))
	var pinned := false
	if lock is Dictionary:
		for entry: Dictionary in lock.get("packs", []):
			if entry.get("id") == "gamemann/fc-player-classes" and entry.get("kind") == "store" and entry.get("into") == "assets/team_bodies":
				pinned = true
				_check(String(entry.get("version")) == FcTeamBodies.PACK_VERSION, "the runtime fetch (web, shell, packed game) wants the version content.lock.json pins", "%s vs %s" % [entry.get("version"), FcTeamBodies.PACK_VERSION])
	_check(FcTeamBodies.PACK_MOUNT == "res://gs_cloud/%s/%s" % [FcTeamBodies.PACK_ID, FcTeamBodies.PACK_VERSION], "the pack mounts at gs-cloud's prefix for its id and version", FcTeamBodies.PACK_MOUNT)
	_check(pinned, "content.lock.json pins gamemann/fc-player-classes as a store into assets/team_bodies")
	if not FileAccess.file_exists("res://assets/team_bodies/fc_swat.glb"):
		print("  SKIP: res://assets/team_bodies is not fetched here (gs-bootstrap tools/fetch_lock.sh content.lock.json)")
		_done()
		return
	for id in ["fc_swat", "fc_military"]:
		_check(FcTeamBodies._find(id, dirs, false) == "res://assets/team_bodies/%s.glb" % id, "%s is found as a fetched .glb" % id)
		_check(FcTeamBodies._find(id, dirs, true) == "res://assets/team_bodies/%s.webp.glb" % id, "%s is found as the fetched WebP body on the web" % id)
	if FcTeamBodies.has_bodies():
		var got := FcTeamBodies.register("fc_swat,fc_military", dirs)
		_check(got.size() == 2 and got[0] == &"fc_swat" and got[1] == &"fc_military", "both fetched bodies register with gs-player-char", str(got))
		var _reset := FcTeamBodies.register("", "")
	_done()


func _test_texture_quality_reaches_the_map_art() -> void:
	_section("The video setting's texture quality caps the map art")
	var p := _make(false)
	GSMapTextureTier.current_quality = -1
	p.settings.set_value(&"texture_quality", 3)
	var q: int = int(p.settings.get_value(&"texture_quality"))
	GSMapTextureTier.follow(p.settings)
	_check(GSMapTextureTier.current_quality == int(q), "the presentation's settings drive the tier", str(GSMapTextureTier.current_quality))
	p.settings.set_value(&"texture_quality", 0)
	var s := GSMapSurfaces.new()
	var applied: Dictionary = GSMapTextureTier.apply_current(s)
	_check(GSMapTextureTier.current_quality == 0 and s.max_texture_size == 512 and not applied.is_empty(), "low texture quality caps the map's surfaces at 512", str(s.max_texture_size))
	p.settings.set_value(&"texture_quality", 3)
	var u := GSMapSurfaces.new()
	GSMapTextureTier.apply_current(u)
	_check(u.max_texture_size == 0, "ultra leaves them unlimited", str(u.max_texture_size))
	GSMapTextureTier.current_quality = 1
	var painter := FcMapPaint.Painter.new()
	painter.role_box(FcMapPaint.Role.WALL, Color.WHITE)
	var lib: Object = painter._surfaces
	_check(lib != null and int(lib.get(&"max_texture_size")) == 1024, "the built-in maps' photographs take the medium cap", str(lib.get(&"max_texture_size")) if lib != null else "no library")
	GSMapTextureTier.current_quality = -1
	p.queue_free()
	_done()
