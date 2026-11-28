extends "headless_presentation_console_and_menus.gd"

const FcWeaponRoles := preload("../game/fc_weapon_roles.gd")


## Records 9.5 s of the killer running down +x with the victim standing down its aim, and a kill at 8 s.
func _record_kill_run(kc: GSKillcamHost, killer: FcPlayer, victim: FcPlayer, clock: Array, at: Callable) -> void:
	var step := 1.0 / 60.0
	var start := killer.controller.state.position
	killer.controller.state.pitch = 0.0
	var aim := -Basis(Vector3.UP, deg_to_rad(killer.controller.state.yaw)).z
	victim.controller.state.position = start + Vector3(8.0, 0.0, 0.0) + aim * 10.0
	victim.global_position = victim.controller.state.position
	while clock[0] < 9.5:
		clock[0] += step
		killer.controller.state.position = at.call(clock[0])
		killer.global_position = at.call(clock[0])
		kc.frame()
		if absf(clock[0] - 8.0) < step * 0.5:
			kc.note_kill(41, 42, "rifle")


## A killcam host over [param players] and the game's rules, driven by hand from [param clock].
func _killcam_host(g: FcGame, players: Array, clock: Array) -> GSKillcamHost:
	var kc := GSKillcamHost.new()
	FcKillcamBodies.configure(kc)
	kc.players_fn = func() -> Array: return players
	kc.player_for_fn = g.player_for
	kc.now_fn = func() -> float: return clock[0]
	kc.seconds_fn = func() -> float: return g.rule("killcam")
	add_child(kc)
	kc.killcam.auto_process = false
	return kc


func _check_banner_icon(kc: GSKillcamHost) -> void:
	var icon_tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGBA8))
	kc.weapon_icon_fn = func(id: String) -> Texture2D: return icon_tex if id == "rifle" else null
	kc.killcam.banner.present({"killer": "Killer", "weapon": "Rifle", "weapon_id": "rifle"})
	_check(kc.killcam.banner.icon_rect.visible and kc.killcam.banner.icon_rect.texture == icon_tex,
		"the banner shows the weapon's icon from weapon_icon_fn")


## Christian's first play test: B opens the loadout (primary, secondary, melee, grenades), a choice
## applies at once in warmup or spawn protection and otherwise on the next spawn.
func _test_the_loadout_menu() -> void:
	_section("B is the loadout menu, and the crosshair fades down the sights")
	var client := FcClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: GSMenu = client.game_menu
	var keys: GSMenuBindings = menu.bindings if menu != null else null
	_check(keys != null and keys.key_for(GSMenuBindings.LOADOUT_ACTION) == "B" and keys.defaults_on("B").size() == 1,
		"the loadout menu is on B, and nothing else in the table is",
		str(keys.defaults_on("B").map(func(r: Dictionary) -> String: return str(r["label"]))) if keys != null else "no menu")
	await _check_loadout_accounts(client)
	var game: FcGame = client.game
	var me := client.player
	if not _check(game.loadout_command != null and me != null, "the game has the menu's server half, and a player"):
		remove_child(client)
		client.free()
		_done()
		return
	var offer: Dictionary = await client.loadout_offer()
	var slot_ids: Array = (offer.get("slots", []) as Array).map(func(sl: Dictionary) -> String: return str(sl["id"]))
	_check(slot_ids == ["primary", "secondary", "melee", "thrown", "gear"], "primary, secondary, melee, grenades and gear, in that order", str(slot_ids))
	var decorated: Dictionary = client.decorate_loadout_choice("primary", {"id": "rifle"})
	_check(decorated.get("icon") is Texture2D and (decorated.get("stats", []) as Array).size() >= 4 and str(decorated.get("detail", "")) != "",
		"a card has the weapon's picture, a line and its numbers")

	var b := InputEventKey.new()
	b.physical_keycode = KEY_B
	b.keycode = KEY_B
	b.pressed = true
	menu.close_all()
	_check(menu.handle_event(b), "B is the menu's")
	for _i in 2:
		await get_tree().process_frame
	_check(menu.loadout_screen != null and menu.loadout_screen.is_open() and menu.loadout_screen.slots().size() == 5,
		"and opens the loadout screen on the five slots")
	menu.loadout_screen.cancel()

	game.match_node.state = GSMatch.State.WARMUP
	var now: Dictionary = await client.choose_loadout({"primary": "marksman", "thrown": "sticky"})
	_check(bool(now.get("ok", false)) and bool(now.get("now", false)) and me.arsenal.carries(&"marksman") and me.arsenal.carries(&"sticky"),
		"in warmup a choice is in the player's hands at once", str(now))

	game.match_node.state = GSMatch.State.LIVE
	me.health.spawn_protection_ticks = 0
	me.health.invulnerable_until_tick = -1
	# A joiner is spawned in the warmup now, and the instant-swap rule's window runs from that spawn: they are past it.
	var spawned: Dictionary = game.get("_spawned_tick")
	spawned.erase(me.player_id)
	var later: Dictionary = await client.choose_loadout({"primary": "carbine"})
	_check(bool(later.get("ok", false)) and not bool(later.get("now", true)) and not me.arsenal.carries(&"carbine"),
		"mid-round it waits for the next spawn", str(later))
	var _back := game.respawn_player(me.player_id)
	for _i in 3:
		await get_tree().process_frame
	_check(me.arsenal.carries(&"carbine") and me.arsenal.carries(&"sticky"), "and the next spawn carries it")

	await _check_loadout_rules(client, me, game)

	await _check_crosshair_sights(client, me, game)
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


func _check_loadout_rules(client: FcClient, me, game: FcGame) -> void:
	var snipers: GSResult = game.loadout_command.call(&"apply_strings", true, "primary=tag:scoped", "")
	var limited: Dictionary = await client.loadout_offer()
	var primaries: Array = ((limited["slots"] as Array)[0]["choices"] as Array).map(func(c: Dictionary) -> String: return str(c["id"]))
	_check(snipers.ok and not primaries.is_empty() and not primaries.has("rifle") and primaries.has("marksman"),
		"an owner's 'snipers only' is what the menu offers", str(primaries))
	var refused: Dictionary = await client.choose_loadout({"primary": "rifle"})
	_check(not bool(refused.get("ok", true)), "and a rifle is refused by the game, not only hidden", str(refused))
	var active: GSResult = await game.loadouts.active_for(FcGame.storage_key(me.player_id))
	_check(primaries.has(str((active.value as GSLoadout).item_in(&"primary"))),
		"a saved carbine spawns as a scoped gun while the rule is on", str((active.value as GSLoadout).item_in(&"primary")))
	var locked: GSResult = game.loadout_command.call(&"apply_strings", false, "", "primary=sniper")
	var fixed_offer: Dictionary = await client.loadout_offer()
	_check(locked.ok and fixed_offer["choose"] == false and str((fixed_offer["slots"] as Array)[0]["current"]) == "sniper",
		"an owner can lock the loadout: nothing to choose, and the fixed slot is what everybody gets")
	var _open: Variant = game.loadout_command.call(&"apply_strings", true, "", "")

	var was_mode := game.mode
	game.mode = FcMode.only_snipers()
	var closed: Dictionary = await client.loadout_offer()
	_check(closed["choose"] == false and str(closed["note"]).contains("hands out the weapons"),
		"a mode that hands out the weapons says so, and lets nothing be picked", str(closed.get("note", "")))
	game.mode = was_mode


## Christian's first play test: a darker HUD by default, which follows the menu's theme so a player
## can change it.
func _test_the_hud_follows_the_theme() -> void:
	_section("The HUD is dark by default and follows the menu's theme live")
	var client := FcClient.new()
	client.force_offline = true
	add_child(client)
	for _i in 6:
		await get_tree().process_frame
	var menu: GSMenu = client.game_menu
	var hud: FcHud = client.hud
	var piece: GSHudPiece = null
	# The kill feed: one of the pieces Fatal Contact keeps, drawn with its own `Ink`.
	var own: Control = hud.feed
	for n in hud.find_children("*", "Control", true, false):
		if n is GSHudPiece:
			piece = n
			break
	_check(menu != null and piece != null and own != null and menu.followed_huds().has(hud), "the client hands the menu its HUD",
		"menu %s, piece %s, own %s" % [menu, piece, own])
	if menu == null or piece == null or own == null:
		remove_child(client)
		client.free()
		_done()
		return
	var Ink = FcHud.FcHudGlance.Ink
	var _m := menu.settings.set_value(&"ui_theme", &"midnight")
	var plate := piece.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7 and piece.colour(&"keycap").get_luminance() < 0.3,
		"the default HUD is dark: deep plates and dark key caps", str(plate))
	_check(Ink.c(own, &"plate") == plate and Ink.bright(own) < 0.5, "and this game's own pieces draw in the same theme")
	_check(piece.colour(&"highlight") == FcHud.GOLD, "with arena's gold as its accent")
	var _a := menu.settings.set_value(&"ui_theme", &"arcade")
	_check(piece.number(&"team_fill") == 100 and piece.colour(&"keycap").get_luminance() > 0.8 and Ink.bright(own) > 0.99,
		"the bright first HUD is a theme a player can pick, and both kinds of piece follow it")
	var _p := menu.settings.set_value(&"ui_theme", &"contrast")
	var contrast := menu.themes.named(&"contrast")
	_check(piece.colour(&"plate") == contrast.hud_plate and Ink.c(own, &"plate_edge") == contrast.hud_edge
		and piece.colour(&"highlight") == FcHud.GOLD, "another theme reaches every piece at once, the accent kept")
	var _s := menu.settings.set_value(&"hud_scale", 1.2)
	_check(is_equal_approx(hud.user_scale, 1.2), "and the HUD size setting resizes the HUD")
	_s = menu.settings.set_value(&"hud_scale", 1.0)
	_m = menu.settings.set_value(&"ui_theme", &"midnight")
	_check(piece.colour(&"plate") == plate, "and back")
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_done()


## The pack carries its art (a delivered game has only what is vendored in assets/), so every model
## the weapons table names must exist here. v0.1.13 shipped without low-poly-guns/ and ammo/: eleven
## weapons were invisible in production and nothing failed.
func _test_the_weapon_art_is_vendored() -> void:
	_section("Every model the weapon art table names is vendored in this game")
	# The table holds only registered packs; the suite's order must not decide whether it is empty.
	FcWeaponRoles.ensure()
	var count := AwWeaponArtTable.model_paths().size()
	_check(count > 20, "the table names models (%d)" % count)
	var models := AwWeaponArtTable.validate_models()
	_check(models.ok, "no weapon model is missing", "" if models.ok else models.error.message)
	_done()


func _test_the_final_killcam() -> void:
	_section("The final killcam replays the last kill from behind the killer (or its eye), and 0 turns it off")
	var g := FcGame.new()
	g.is_authority = true
	add_child(g)
	var _set := g.setup(FcMap.box())
	var killer: FcPlayer = g.add_player(41, "Killer").value
	var victim: FcPlayer = g.add_player(42, "Victim").value
	_check(is_equal_approx(g.match_node.rules.match_end_sec, g.mode.rules.match_end_sec + 7.0),
		"the end of the match waits the killcam's 7 s on top of the mode's")
	var clock := [0.0]
	var kc := _killcam_host(g, [killer, victim], clock)
	kc.camera_mode_fn = func() -> int: return GSKillViewRules.Camera.BEHIND
	var ended: Array = []
	kc.over.connect(func(skipped: bool) -> void: ended.append(skipped))
	var start := killer.controller.state.position
	var step := 1.0 / 60.0
	var at := func(t: float) -> Vector3: return start + Vector3(t, 0.0, 0.0)
	_record_kill_run(kc, killer, victim, clock, at)
	_check(kc.buffer.frame_count() > 400 and int(kc.buffer.last_event(&"kill")["data"]["killer"]) == 41,
		"every frame drawn and the kill went into the buffer")
	var drawn: Array = []
	kc.killcam.frame_drawn.connect(func(s: Dictionary) -> void:
		var kb: Node3D = killer.body_mesh
		drawn.append([float(s["time"]), kc.camera.global_transform, kb.global_position if kb != null else Vector3.INF, kb != null and kb.visible]))
	_check(kc.match_ended() and kc.is_playing(), "the match's end starts it")
	kc.killcam.advance(step)
	_check(not drawn.is_empty() and absf(float(drawn[0][0]) - 4.5) < 0.05, "from 3.5 s before the kill (%.2f)" % (float(drawn[0][0]) if not drawn.is_empty() else NAN))
	var first: Array = drawn[0] if not drawn.is_empty() else [0.0, Transform3D(), Vector3.INF, false]
	var want: Vector3 = at.call(4.5)
	var cam: Transform3D = first[1]
	var gap := cam.origin.distance_to(want + Vector3(0.0, 1.6, 0.0))
	_check(gap > 1.5 and gap < 8.0 and cam.origin.y > want.y + 1.0, "with the camera a few metres behind and above the killer (%.2f m)" % gap)
	_check(first[3] and (first[2] as Vector3).distance_to(want) < 0.1, "and the killer's body drawn where it was recorded", "%s vs %s" % [first[2], want])
	var chest := victim.global_position + Vector3(0.0, 1.2, 0.0)
	var look := (-cam.basis.z).dot((chest - cam.origin).normalized())
	_check(look > 0.95, "looking at the victim (%.3f)" % look)
	for _i in 60:
		kc.killcam.advance(step)
	var later: Array = drawn[-1]
	_check(float(later[0]) > float(first[0]) + 0.2 and (later[2] as Vector3).x > (first[2] as Vector3).x + 0.2,
		"time advances and the killer's body moves with the recording", "t %.2f -> %.2f, x %.2f -> %.2f" % [first[0], later[0], (first[2] as Vector3).x, (later[2] as Vector3).x])
	_check(kc.killcam.banner != null and kc.killcam.banner.killer_label.text == "Killer", "under a banner naming the killer")
	_check_banner_icon(kc)
	var n := 0
	while kc.is_playing() and n < 1000:
		kc.killcam.advance(step)
		n += 1
	_check(ended == [false] and n * step < 7.0, "it ends by itself inside the budget (%.2f s)" % (n * step))
	_check(killer.body_mesh == null or not killer.body_mesh.visible, "a body attached only for the replay goes back hidden")

	kc.camera_mode_fn = func() -> int: return GSKillViewRules.Camera.EYE
	drawn.clear()
	ended.clear()
	var _again := kc.match_ended()
	kc.killcam.advance(step)
	var eye: Vector3 = (drawn[0][1] as Transform3D).origin if not drawn.is_empty() else Vector3.INF
	_check(absf(eye.x - want.x) < 0.1 and eye.y > want.y + 0.5 and not (drawn[0][3] if not drawn.is_empty() else true),
		"mp_killview_camera 0: the camera at the killer's eye, its body not drawn (%s, feet %s)" % [eye, want])
	kc.skip()
	_check(ended == [true], "and a skip ends it")

	g.set_movement_rules({"killcam": 0.0})
	ended.clear()
	_check(not kc.match_ended() and ended == [false] and not kc.is_playing(),
		"mp_killcam_time 0: nothing plays and the end goes straight on")
	_check(is_equal_approx(g.match_node.rules.match_end_sec, g.mode.rules.match_end_sec),
		"and the end of the match is the mode's again")
	kc.queue_free()
	g.queue_free()
	_done()


## Every piece of the HUD put up at once, as `screenshot.sh --glance` stages it, on five frames, and
## no piece's drawn rect may meet another's.
func _test_hud_fits_the_frame() -> void:
	_section("No piece of the HUD lies over another, from a phone to a desktop frame")

	var hud := FcHud.new()
	hud.config = GSUiConfig.new()
	add_child(hud)
	hud.build(null)
	# Nothing reads a player here: the pieces draw what they are handed, and `_process`
	# would hand them a dead player's nothing.
	hud.set_process(false)
	hud._build_feedback()

	_fill_hud(hud)

	# The chat box, scaled with the HUD as FcPresentation scales it: unscaled, a full log
	# at 854x480 reached the killstreak meter and the key hints.
	var chat_screen := Control.new()
	add_child(chat_screen)
	var chat := FcPresentation.make_chat_window()
	chat_screen.add_child(chat)
	var chat_met := PackedStringArray()

	var frames := [Vector2(854, 480), Vector2(960, 720), Vector2(720, 1280), Vector2(1280, 720), Vector2(1600, 900)]
	for frame: Vector2 in frames:
		hud.fit_to_frame(frame)
		hud.notice("Vote: Smash Copter, Hide & Seek, Dangerous Delivery, Playlot, Airdrift (20s)")
		# The labels take their text's size on the next frame.
		await get_tree().process_frame
		var rects := hud.footprints()
		var keys: Array = rects.keys()
		var met := PackedStringArray()
		var outside := PackedStringArray()
		var bounds := Rect2(Vector2.ZERO, frame)
		for i in range(keys.size()):
			var a: Rect2 = rects[keys[i]]
			if not bounds.encloses(a):
				outside.append("%s %s" % [keys[i], a])
			for j in range(i + 1, keys.size()):
				if a.intersects(rects[keys[j]]):
					met.append("%s/%s" % [keys[i], keys[j]])
		var size_name := "%dx%d" % [int(frame.x), int(frame.y)]
		_check(met.is_empty() and keys.size() == 11,
			"at %s, none of the %d pieces meets another" % [size_name, keys.size()], ", ".join(met))
		_check(outside.is_empty(), "and every one is inside the frame", ", ".join(outside))

		FcPresentation.fit_chat_screen(chat_screen, frame)
		var fit := chat_screen.scale.x
		var rows := float(chat.max_lines) * (chat.line_height + chat.line_gap)
		var log_top := frame.y / fit - chat.margin_bottom - chat.entry_height - rows
		var log_box := chat_screen.get_global_transform() * Rect2(chat.margin_left, log_top, chat.width, rows)
		for key: String in rects:
			if log_box.intersects(rects[key]):
				chat_met.append("%s: %s %s vs log %s" % [size_name, key, rects[key], log_box])

	_check(chat_met.is_empty(), "a full chat log meets no HUD piece at any of those frames",
		", ".join(chat_met))
	chat_screen.queue_free()

	# 1280x720 and up are laid out exactly as gs-ui's full-rect inset laid them out.
	var same := true
	for frame: Vector2 in [Vector2(1280, 720), Vector2(1600, 900), Vector2(1920, 1080)]:
		hud.fit_to_frame(frame)
		same = same and hud.scale == Vector2.ONE and hud.position == Vector2(16, 16) and hud.size == frame - Vector2(32, 32)
	_check(same, "from 1280x720 up the HUD is not scaled, and sits where it always did")
	_check(is_equal_approx(FcHud.fit_scale(Vector2(854, 480)), 480.0 / 720.0)
			and is_equal_approx(FcHud.fit_scale(Vector2(960, 720)), 0.75)
			and is_equal_approx(FcHud.fit_scale(Vector2(720, 1280)), 0.5625)
			and FcHud.fit_scale(Vector2(200, 100)) == hud.fit_min
			and hud.fit_design == FcHud.DESIGN_FRAME and hud.fit_min == 0.5,
		"below it, it is scaled by the short side's share of 1280x720, never under half")

	await _check_crowded_frames(hud)

	hud.queue_free()
	_done()

func _check_crowded_frames(hud: FcHud) -> void:
	# Four sides' plates and a capture-ranked row with two stats a card still fit, the row
	# dropping players where the frame is too narrow.
	var sides: Array[Dictionary] = []
	for s in [["RED · TAKEN", Color.RED], ["BLUE", Color.BLUE], ["GREEN · 12s", Color.GREEN], ["GOLD", Color.GOLD]]:
		sides.append({"tag": s[0], "score": sides.size() * 3, "colour": s[1]})
	hud.strip.show_teams(sides)
	hud.strip.show_clock("9:37", false, "First to 3 captures", "Capture the flag")
	var cards: Array[Dictionary] = []
	for i in range(10):
		cards.append({"name": "P%d" % i, "rank": i + 1, "kills": 20 - i, "objectives": 3 - int(i / 3.0), "me": i == 9})
	hud.portraits.show_players(cards, true)
	var crowded := PackedStringArray()
	for frame: Vector2 in [Vector2(854, 480), Vector2(960, 720), Vector2(1280, 720)]:
		hud.fit_to_frame(frame)
		hud.notice("Vote: Smash Copter, Hide & Seek, Dangerous Delivery, Playlot, Airdrift (20s)")
		await get_tree().process_frame
		var rects := hud.footprints()
		var keys: Array = rects.keys()
		for i in range(keys.size()):
			if not Rect2(Vector2.ZERO, frame).encloses(rects[keys[i]]):
				crowded.append("%s outside at %s" % [keys[i], frame])
			for j in range(i + 1, keys.size()):
				if (rects[keys[i]] as Rect2).intersects(rects[keys[j]]):
					crowded.append("%s/%s at %s" % [keys[i], keys[j], frame])
	_check(crowded.is_empty() and hud.strip.teams.size() == 4 and hud.portraits.objective,
		"four sides' plates and the capture row fit every frame, meeting nothing", ", ".join(crowded))
	var kept: Array = hud.portraits.shown()
	_check(not kept.is_empty() and bool((kept.back() as Dictionary).get("me", false)),
		"a card row cut short still ends with your own card", "%d shown" % kept.size())
	hud.strip.show_scores(1, 2, "RED", "BLUE", Color.RED, Color.BLUE)
	_check(hud.strip.teams.is_empty() and hud.strip.left_score == 1 and hud.strip.right_score == 2,
		"two sides go back to the plain two plates")
	# The clock is gs-ui's `GSScoreStrip.clock_text`, which rounds up: a clock never says
	# 0:00 with time left. Fatal Contact's own rounded down (9:37.4 read 9:37).
	_check(GSScoreStrip.clock_text(577.4) == "9:38" and GSScoreStrip.clock_text(0.3) == "0:01"
			and GSScoreStrip.clock_text(0.0) == "0:00" and GSScoreStrip.clock_text(600.0) == "10:00",
		"the clock rounds the seconds left up (%s, %s)" % [GSScoreStrip.clock_text(577.4), GSScoreStrip.clock_text(0.3)])


## Every piece of the HUD at its busiest.
func _fill_hud(hud: FcHud) -> void:
	hud.strip.visible = true
	hud.strip.show_scores(4, 4, "YOU", "2ND  GAMEMANN", Color.BLUE, Color.RED)
	hud.strip.show_clock("9:37", false, "First to 25", "Free-For-All")
	hud.portraits.visible = true
	var faces: Array[Dictionary] = []
	for i in range(8):
		faces.append({"name": "P%d" % i, "rank": i + 1, "kills": 8 - i, "me": i == 0})
	hud.portraits.show_players(faces)
	hud.feed.add_kill("gamemann", Color.WHITE, &"launcher", "launcher", "Rocket", Color.WHITE)
	hud.feed.add_kill("You", Color.WHITE, &"marksman", "marksman", "quiet_one", Color.WHITE, false, true)
	hud.feed.add_kill("a_very_long_display_name", Color.WHITE, &"sniper", "sniper", "Viper", Color.WHITE, true)
	hud.vitals.show_vitals(64.0, 100.0, 35.0)
	hud.ammo.show_ammo("Marksman rifle", 3, 240, false)
	var carried: Array[Dictionary] = []
	for slot in range(1, 6):
		carried.append({"slot": slot, "id": &"rifle", "name": "Rifle", "key": str(slot)})
	hud.slots.show_slots(carried, 3)
	var buttons: Array[Dictionary] = []
	for b in [["slide", "C"], ["launch", "E"], ["dash", "Shift"], ["walljump", "Space"]]:
		buttons.append({"id": StringName(b[0]), "label": b[0], "icon": null, "key": b[1],
			"left": 0.0, "total": 1.0, "active": false, "pips": 2, "pips_max": 3 if b[0] == "walljump" else 0})
	hud.abilities.show_buttons(buttons)
	hud.hints.show_hints([["Scoreboard", "Tab"], ["Menu", "Esc"], ["Chat", "Y"], ["Slide", "C"]])
	hud.slide_label.show_prompt("Cancel slide", "C")
	hud.vitals.show_streak(3, FcHud.STREAK_FULL)
	hud.medal_row.add(FcAwards.Medal.HEADSHOT, "Headshot")
	hud.medal_row.add(FcAwards.Medal.DOUBLE_KILL, "Double Kill")
	hud.medal_row.advance(1.0)


func _test_chat_box() -> void:
	_section("A chat box, and the three answers to whether it is drawn")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds one at all")

	if window == null:
		_completed += 1
		return

	_check(
		GSInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)
	_check(
		GSInputBinding.describe_action(window.team_action) == "U",
		"and team chat by U"
	)
	_check(window.enabled, "drawn by default, on a server that said nothing")

	# `auto`: the server is carrying chat somewhere the player can already see it.
	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes the box away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	# `on`: both halves at once, which is the configuration the relay does not preclude.
	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.set_chat_relayed(false)
	_check(not window.enabled, "not even on a server with no relay at all")

	p.settings.set_value(&"chat_window", &"auto")
	_check(window.enabled, "and auto gives it back")

	_check_rebind(p, window)

	# The console and the chat box are the same question: does something on screen own the keyboard?
	# A client that keeps reading movement while somebody types walks them across the map.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	_check_join_notice(p, window)

	p.settings.reset_value(&"chat_open_key")
	p.settings.reset_value(&"chat_window")

	_check_log_over_streak(window)

	_completed += 1


func _check_rebind(p: FcPresentation, window: GSChatWindow) -> void:
	# The binding is a setting, so changing the setting has to move the key — and move
	# it, not add a second one.
	p.settings.set_value(&"chat_open_key", "T")
	_check(
		GSInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	# A field somebody cleared must not unbind chat with no way back from inside the game.
	p.settings.set_value(&"chat_open_key", "")
	_check(
		GSInputBinding.describe_action(window.open_action) == "T",
		"an empty binding in the document is ignored rather than applied"
	)


func _check_join_notice(p: FcPresentation, window: GSChatWindow) -> void:
	# A join notice is a name and NO text (gs-chat's `_presence`). Drawn as name and text it was a
	# bare "Guest 435:" in the box, which read as a chat command echoed with its text stripped.
	var extras_script := preload("../game/fc_client_extras.gd")
	var join := GSChatMessage.make(GSChatMessage.Kind.JOIN, &"all", "k2", "Guest 435", "")
	var said_client := FcClient.new()
	said_client.presentation = p
	said_client._on_said(extras_script.speaker_of(join), extras_script.text_of(join), join.kind_name())
	var said_rows := window.history()
	var said_line := ""
	for part in (said_rows[said_rows.size() - 1] if not said_rows.is_empty() else []):
		said_line += str((part as Dictionary).get("text", ""))
	_check(
		said_line.contains("Guest 435 joined") and not said_line.contains(":"),
		"a join notice is drawn as a sentence, not as a bare name",
		"'%s'" % said_line
	)
	said_client.free()


func _check_log_over_streak(window: GSChatWindow) -> void:
	# A full log, at the frame the client shell always draws on, must stay under the
	# killstreak meter's words: at a 250-tall meter the sixth line wrote over them.
	var hud := FcHud.new()
	hud.config = GSUiConfig.new()
	add_child(hud)
	hud.build(null)
	hud._build_feedback()
	hud.fit_to_frame(Vector2(1280, 720))
	hud.vitals.show_streak(3, FcHud.STREAK_FULL)
	var streak: Rect2 = hud.vitals.get_global_transform() * hud.vitals.footprint()
	var rows := float(window.max_lines) * (window.line_height + window.line_gap)
	var log_box := Rect2(window.margin_left, 720.0 - window.margin_bottom - window.entry_height - rows, window.width, rows)
	_check(not log_box.intersects(streak), "a full chat log stays under the killstreak meter at 1280x720",
		"log %s, meter's words %s" % [log_box, streak])
	hud.queue_free()
