extends RefCounted

const FcBindings := preload("fc_bindings.gd")
const FcBrowser := preload("fc_browser.gd")
const FcEvents := preload("fc_events.gd")
const FcModes := preload("fc_modes.gd")
const FcTeamBodies := preload("fc_team_bodies.gd")

## The Escape menu and the Tab board: gs-menu's, with this game's pages on it.
##
## [b]gs-menu's since 2026-10-10, like every other game here.[/b] It was gs-ui's
## `GSPauseScreen` (Resume, Settings, Interface, Controls, Servers, Leave) over two generated
## `GSSettingsScreen`s, a `GSBindingsPanel` rebinder and a browser screen, each a different
## look. Now it is the one menu: gs-menu's stock General, Video, Audio, Controls and
## Advanced pages as views of this game's settings document ([FcPresentation]), plus
## this game's own:
##
## - **Interface**: the theme, the frame-rate counter, the crosshair and the HUD's margin.
## - **Controls**: the stock mouse card, this game's look switches and every key from
##   [FcBindings], each a key button (rebindable, swapping on a conflict).
## - **Servers**: gs-browser's list, drawn as a page ([method _servers_page]).
## - **Credits**: who made the team bodies ([method credits_page]); the rest of the art is
##   credited in the README and licence.json.
##
## **Leave** is gs-menu's stock one ([member GSMenu.leave_on_its_own]): off the server when
## connected, which hands the player back to whatever loaded the client, and a quit when solo
## on a desktop. Until 2026-10-11 Leave only emitted `FcClient.leave_requested`, which
## nothing listened to, so the button did nothing; the signal is still emitted for an
## embedder. **H opens help** ([method _fill_help]: the goal and every mode), and the HUD's
## own key hints list it, so gs-menu's corner plate is off here.

const CHANNEL := "arena.menus"

## The action id Leave sends.
const LEAVE := &"leave"


## Builds the menu under [param host], with its pages, and the console as one of its
## overlays. [param browser] null leaves the Servers page out of the sidebar.
static func build(host: Node, presentation: Node, browser: FcBrowser = null) -> GSMenu:
	var settings: GSSettingsManager = presentation.settings if presentation != null else null

	var menu := GSMenu.new()
	menu.name = "GameMenu"
	# Under the HUD's clock, mode label and portraits (to y 160) and its notice line (182..): the
	# default 64 drew "Loadout equipped." over the mode label. By name: the web shell pinned
	# 2026-10-17 has gs-menu 0.1.3, older than `toast_top`, and assigning it there stopped
	# this function with a script error, so that shell's client had no menu at all.
	if &"toast_top" in menu:
		menu.set(&"toast_top", 236.0)
	menu.settings = settings
	menu.bindings = presentation.bindings if presentation != null else FcBindings.make()
	var config := GSMenuConfig.new()
	config.brand_name = "Zee's Fatal Contact"
	# The kill feed owns the top right, where the touch Menu button defaults. By name: older
	# gs-menu has no such property, and assigning it would stop this function.
	if &"menu_button_corner" in config:
		config.set(&"menu_button_corner", &"top_left")
	var _layered := config.load_layered()
	menu.config = config
	# Escape keeps its two steps here (the first releases the pointer, the second opens the
	# menu; see `FcClient._unhandled_input`), and the client is the one owner of the
	# pointer. Escape still closes the menu.
	menu.open_on_escape = false
	menu.manage_pointer = false
	menu.scoreboard_action = FcBindings.SCOREBOARD
	menu.leave_on_its_own = true
	# The HUD's key hints have H (`FcHud`), so gs-menu's corner plate would say it twice.
	config.help_hint = &"off"
	# The chat box or the console has the keyboard: Tab is a letter then, not the board.
	if presentation != null:
		menu.busy = func() -> bool: return presentation.swallows_input()
	host.add_child(menu)
	GSLog.result(CHANNEL, "the menu", menu.setup())

	add_pages(menu, browser)
	fill_help(menu.help)

	# The console after the menu, so GSConsoleKit registers it as one of the menu's
	# overlays: opening it frees the pointer and stops the player through
	# `overlays_changed`, which the client listens to.
	if presentation != null and presentation.has_method(&"build_console"):
		GSLog.result(CHANNEL, "the console", presentation.build_console(menu))
	return menu


static func _add_video_audio_controls(menu: GSMenu) -> void:
	var video := menu.page(&"video")
	if video != null:
		video.section("Image").add(GSMenuRow.toggle(&"view_model", "Weapon in view", "Your hands and gun. A server may turn them off.")) \
			.add(GSMenuRow.select(&"first_person_body", "My body", "What you see of yourself when you look down. Server default follows the server.",
				[[&"auto", "Server default"], [&"off", "None"], [&"legs", "Legs and feet"], [&"body", "Whole body"]])) \
			.add(GSMenuRow.toggle(GSOwnBodySetting.KEY, "Show legs", "Show your own legs and body when you look down. Off hides them whatever the server or the choice above says."))
		video.section("Players").add(GSMenuRow.select(&"name_tags", "Name tags", "Whose name floats over their head. The server may allow fewer.",
				[[&"always", "Everybody"], [&"team", "Team-mates"], [&"team_hover", "Team-mates and under cursor"], [&"hover", "Under cursor"], [&"off", "Off"]])) \
			.add(GSMenuRow.slider(&"nametag_min_scale", "Name tag, smallest", "Smallest a name tag looks, however far. 0 is no limit.")
				.formatted(func(v: float) -> String: return "off" if v <= 0.0 else "x%.1f" % v)) \
			.add(GSMenuRow.slider(&"nametag_max_scale", "Name tag, largest", "Largest a name tag looks, however close. 0 is no limit.")
				.formatted(func(v: float) -> String: return "off" if v <= 0.0 else "x%.1f" % v)) \
			.add(GSMenuRow.select(&"health_bar_colour", "Health bar colour", "Team: enemies red, team-mates light green, each side its own colour with more than two sides. Health: green to red by health left.",
				[[&"team", "Team"], [&"health", "Health"]])) \
			.add(GSMenuRow.select(&"health_bars", "Health bars", "Whose health bar floats over their head. Smart: team-mates, whoever the cursor is on, anybody just hurt. The server may allow fewer.",
				[[&"always", "Everybody"], [&"smart", "Smart"], [&"team", "Team-mates"], [&"team_hover", "Team-mates and under cursor"], [&"hover", "Under cursor"], [&"off", "Off"]]))
		GSMenuStock.add_gore_row(video)

	var audio := menu.page(&"audio")
	if audio != null:
		audio.section("Voice").add(GSMenuRow.toggle(&"push_to_talk", "Push to talk", "Hold the Push to talk key (Controls) to talk. Off: an open microphone."))

	var controls := menu.page(&"controls")
	if controls != null:
		# This game's invert is `invert_pitch`, stored before gs-menu's `invert_mouse`
		# existed; the stock row for the stock key is not drawn, because it is not declared.
		controls.section("Mouse") \
			.add(GSMenuRow.toggle(&"invert_pitch", "Invert vertical look")) \
			.add(GSMenuRow.toggle(&"right_mouse_aims", "Right mouse aims", "Off: the Aim key (right mouse) bashes with the weapon instead of aiming."))


## This game's rows and pages onto [param menu]'s stock ones. Public so a suite can build
## a menu without a client.
static func add_pages(menu: GSMenu, browser: FcBrowser = null) -> void:
	# Interface: the look of the screen. The theme and the counter move here from General.
	var general := menu.page(&"general")
	var interface := GSMenuPage.make(&"interface", "Interface", "The crosshair, the HUD and the colours of the menus.")
	var look := interface.section("Look")
	if general != null:
		for id in [&"ui_theme", &"show_fps"]:
			var row := general.take_row(id)
			if row != null:
				look.add(row)
		var _gone := general.remove_section(&"interface")
		general.blurb = "Comfort, camera motion, and whether there is a chat box."
	var theme_row := interface.find_row(&"ui_theme")
	if theme_row != null:
		theme_row.described("The colours of the menus and the scoreboard.")
	interface.section("HUD") \
		.add(GSMenuRow.select(&"crosshair", "Crosshair", "Circle draws the cross for now.",
			[[&"cross", "Cross"], [&"dot", "Dot"], [&"circle", "Circle"], [&"none", "None"]])) \
		.add(GSMenuRow.select(&"hud_key_hints", "Key list", "The key list at the left of the screen. It covers name tags, so it shows for the first seconds by default.",
			[[&"first", "First seconds"], [&"always", "Always"], [&"off", "Off"]])) \
		.add(GSMenuRow.slider(&"hud_safe_area", "Edge margin", "Room between the HUD and the edge of the screen, for a television or a notch.")
			.formatted(func(v: float) -> String: return "%d px" % roundi(v)))
	menu.add_page(interface, &"video")

	# Camera motion, beside Comfort on General: the dip, the roll, the wall lean and the widening,
	# each a slider to Off for a player whom motion makes sick.
	if general != null:
		var motion := general.section("Camera motion")
		for row: Array in [
			[&"camera_landing_dip", "Landing dip"],
			[&"camera_strafe_roll", "Strafe lean"],
			[&"camera_wall_lean", "Wall-run lean"],
			[&"camera_speed_fov", "Speed widening"],
		]:
			# The words are the setting's own (`FcPresentation.CAMERA_MOTION_KEYS`), read from the
			# schema: this file cannot preload the presentation without a cycle through the HUD.
			var def: GSSettingsDef = menu.settings.schema.find(row[0]) if menu.settings != null else null
			motion.add(GSMenuRow.slider(row[0], row[1], def.description if def != null else "")
				.formatted(func(v: float) -> String: return "Off" if v <= 0.0 else "%d%%" % roundi(v * 100.0)))
		var calm: GSSettingsDef = menu.settings.schema.find(&"reduce_motion") if menu.settings != null else null
		motion.add(GSMenuRow.toggle(&"reduce_motion", "Reduce motion", calm.description if calm != null else ""))

	# Solo bots: gs-bot's presets, saved. A server's bots follow the server's bot_difficulty.
	if general != null:
		general.section("Solo bots").add(GSMenuRow.select(&"solo_bot_difficulty", "Bot difficulty",
			"How well the bots play when you play alone. Easy misses and reacts late; nightmare does neither. A server sets its own.",
			[[&"easy", "Easy"], [&"medium", "Medium"], [&"hard", "Hard"], [&"nightmare", "Nightmare"]]))

	_add_local_maps_row(menu, general)

	_add_video_audio_controls(menu)

	if browser != null:
		menu.add_page(_servers_page(menu, browser), &"advanced")
	menu.add_page(credits_page())


## The Credits page: the team bodies' authors from [constant FcTeamBodies.CREDITS], one section
## per body, so a body added there is credited with nothing else edited.
static func credits_page() -> GSMenuPage:
	var page := GSMenuPage.make(&"credits", "Credits", "The people whose art this game uses.")
	var names := {&"fc_military": "Military team body", &"fc_swat": "SWAT team body"}
	for id: StringName in FcTeamBodies.CREDITS:
		var section := page.section(String(names.get(id, String(id))))
		for line: String in FcTeamBodies.CREDITS[id]:
			section.add(GSMenuRow.note(line))
	page.section("Everything else").add(GSMenuRow.note(
		"Maps, weapons, sounds and textures: each author and licence is in this game's README and licence.json."))
	return page


## Local maps: the Source game install path a dropped _orig map takes its stock textures from.
static func _add_local_maps_row(menu: GSMenu, general: GSMenuPage) -> void:
	# Local maps: where the player's own TF2 is, for the stock textures a dropped `<map>_orig` pack lacks (FcSourceInstall,
	# LOCAL ONLY). Enter saves the setting, which fills the local packs at once (FcClient._on_source_game_path).
	if general != null and menu.settings != null and menu.settings.schema.find(&"source_game_path") != null:
		var settings := menu.settings
		general.section("Local maps").add(GSMenuRow.custom("Source game install path",
			"Your own TF2 folder (Steam > Team Fortress 2 > Manage > Browse local files). A dropped _orig map takes the game's textures it lacks from there; they stay on this computer. Empty: Steam's usual folders.",
			func(_kit: Variant) -> Control:
				var field := LineEdit.new()
				field.text = settings.get_string(&"source_game_path")
				field.placeholder_text = "C:/Program Files (x86)/Steam/steamapps/common/Team Fortress 2"
				field.custom_minimum_size = Vector2(360, 0)
				field.text_submitted.connect(func(text: String) -> void:
					var _set := settings.set_value(&"source_game_path", text.strip_edges()))
				field.focus_exited.connect(func() -> void:
					if field.text.strip_edges() != settings.get_string(&"source_game_path"):
						var _set := settings.set_value(&"source_game_path", field.text.strip_edges()))
				return field))


## The chat commands a player may type on a server, as the help screen's Commands card lists them (name without the prefix, then what it does).
const SERVER_COMMANDS: Array = [
	["rtv", "Vote to change the map now"],
	["nominate", "Put a map on the next vote"],
	["vote", "Open the vote menu"],
	["nextmap", "What plays next"],
	["timeleft", "How long this map has left"],
	["score", "The scoreboard in chat"],
	["stats", "Your own totals"],
]


## Tells the help screen whether this client is on a server: its Commands card says "You are playing offline" until it is told, in a match on a server too.
static func set_help_online(help: GSMenuHelp, online: bool) -> void:
	if help == null:
		return
	help.online = online
	help.commands = SERVER_COMMANDS.duplicate(true)


## The help screen's goal and modes; the keys come from [FcBindings]. The modes are read
## from [FcModes], so a mode added there is on the help screen with nothing else edited.
static func fill_help(help: GSMenuHelp) -> void:
	if help == null:
		return
	help.about = "Fast deathmatch: run, slide, dash and shoot. Score by fragging, or by whatever the mode asks; the scoreboard (Tab) says who is ahead."
	var lines: Array = []
	for mode in FcModes.all():
		lines.append([mode.display_name, mode.description])
	help.add_section("Modes", lines, &"plain")
	help.add_text("Moving", "Duck while running to slide (C slides too), Shift dashes when the server allows dashing, and E launches you. In a props mode E grabs a prop and X freezes it. F is the flashlight; outside a props mode X is the quick melee.")


## gs-browser's list as a page: a card of servers, each with a Join, and a Refresh.
##
## [b]A page rather than a screen of its own[/b], so it is in the menu's sidebar, theme and
## pointer handling like everything else. It is drawn fresh each time it is shown, which is
## what a page is; the listing it draws is the browser's, so nothing is kept between draws.
static func _servers_page(menu: GSMenu, browser: FcBrowser) -> GSMenuPage:
	var page := GSMenuPage.make(&"servers", "Servers", "Other servers running this game. Join says where to go.")
	# What the last refresh said, kept across draws: empty once it finished cleanly.
	var state := {"status": ""}
	browser.listing_changed.connect(func() -> void:
		if menu.is_open() and menu.screen.current_page() == &"servers":
			menu.screen.refresh())
	page.build = func(kit: GSMenuKit, body: VBoxContainer) -> void:
		var top := HBoxContainer.new()
		top.add_theme_constant_override(&"separation", 12)
		var status := kit.paragraph(str(state["status"]), kit.size_small, kit.palette.dim)
		status.name = "Status"
		status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		top.add_child(status)
		var refresh := Button.new()
		refresh.name = "Refresh"
		refresh.text = "Refresh"
		refresh.pressed.connect(func() -> void:
			state["status"] = "Looking..."
			status.text = state["status"]
			var done: GSResult = await browser.refresh()
			state["status"] = "" if done.ok else done.error.message
			if menu.is_open():
				menu.screen.refresh())
		top.add_child(refresh)
		body.add_child(top)

		var listing := browser.listing()
		if listing.is_empty():
			if str(state["status"]) == "":
				status.text = "Nothing listed yet. Refresh to ask the servers this game knows."
			return
		var card := kit.card()
		card.name = "List"
		var rows := VBoxContainer.new()
		card.add_child(rows)
		for entry in listing:
			if rows.get_child_count() > 0:
				rows.add_child(HSeparator.new())
			var line := HBoxContainer.new()
			line.add_theme_constant_override(&"separation", 18)
			line.custom_minimum_size = Vector2(0, 52)
			var words := VBoxContainer.new()
			words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			words.alignment = BoxContainer.ALIGNMENT_CENTER
			words.add_child(kit.label(entry.name, kit.size_body, kit.palette.text))
			words.add_child(kit.label("%s  ·  %d/%d players  ·  %s" % [
				FcBrowser.game_field(entry, "map", entry.map),
				entry.players, entry.max_players,
				("%d ms" % entry.ping_ms) if entry.is_online() else "no answer",
			], kit.size_small, kit.palette.dim))
			line.add_child(words)
			var join := Button.new()
			join.text = "Join"
			join.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var chosen := entry
			join.pressed.connect(func() -> void:
				menu.close()
				browser.join_requested.emit(chosen))
			line.add_child(join)
			rows.add_child(line)
		body.add_child(card)
	return page


## The Tab board's rows from gs-match, with the server's roster merged in by key for what
## only the server knows (time connected and ping).
##
## [b]gs-menu's `GSMenuScoreboard` since 2026-10-09[/b]; it hung off a gs-ui screen until
## the Escape menu moved, and is the menu's own `scoreboard` now. Held on Tab
## ([constant FcBindings.SCOREBOARD]), never one of the menu's overlays, so holding it
## stops nobody moving.
class Board extends RefCounted:
	var board: GSMenuScoreboard = null
	var _records: GSScoreboard = null
	var _teams: GSTeamManager = null
	var _me: String = ""
	var _game: Object = null

	## With [param p_game] (an `FcGame`) the records and teams are read off its current
	## match each time, because [param records] cannot be trusted to last: a client builds its
	## board before the match node has entered the tree (`GSMatch` makes its scoreboard only
	## then, so a null was held for ever and the server's roster, the local player alone with
	## K and D dashes, was drawn in place of every record), and a change of mode builds a new
	## match node, leaving the old scoreboard to be freed.
	func _init(p_board: GSMenuScoreboard, records: GSScoreboard, link: Object = null, teams: GSTeamManager = null, p_game: Object = null) -> void:
		board = p_board
		_records = records
		_game = p_game
		_teams = teams
		board.title_text = "Zee's Fatal Contact"
		board.columns = [
			{"key": &"name", "title": "Player", "width": 3.0},
			{"key": &"kills", "title": "K", "kind": GSMenuScoreboard.KIND_NUMBER},
			{"key": &"deaths", "title": "D", "kind": GSMenuScoreboard.KIND_NUMBER},
			{"key": &"assists", "title": "A", "kind": GSMenuScoreboard.KIND_NUMBER},
			{"key": &"score", "title": "Score", "kind": GSMenuScoreboard.KIND_NUMBER},
			{"key": &"seconds", "title": "Time", "kind": GSMenuScoreboard.KIND_DURATION},
			{"key": &"ping", "title": "Ping", "kind": GSMenuScoreboard.KIND_PING},
		]
		# gs-match's own order: best score, then kills.
		board.sort_with = func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("rank", 0)) < int(b.get("rank", 0))
		board.prepare = _rows_from_match
		if link != null and link.has_signal(&"scoreboard_received"):
			board.feed_from(link)
		else:
			# Offline nothing sends a roster; an empty one pulled twice a second keeps the
			# rows from the match current while the board is held.
			board.source = func() -> Dictionary: return {}

	## Which record is this client's. The roster says so online; offline nobody else will.
	func follow(key: String) -> void:
		_me = key

	func _rows_from_match(snap: Dictionary) -> void:
		# Looked up every time, for the reasons at `_init`.
		if _game != null and is_instance_valid(_game):
			var match_node: GSMatch = _game.get(&"match_node")
			if match_node != null and match_node.scoreboard != null:
				_records = match_node.scoreboard
				_teams = match_node.teams
		if _records == null:
			return
		var roster := {}
		for r in (snap.get("players", []) as Array):
			if r is Dictionary:
				roster[str(r.get("id", ""))] = r
		var you := str(snap.get("you", ""))
		var rows: Array = []
		var rank := 1
		# The sides are the game's (a client's records carry no team), so a team mode run solo
		# still gets its columns; a mode scored by objectives ranks by them, then kills.
		var sides: Array[GSTeam] = []
		var objective := false
		if _game != null and is_instance_valid(_game):
			for side: GSTeam in _game.call(&"teams"):
				if not side.is_spectator:
					sides.append(side)
			var mode: Resource = _game.call(&"displayed_mode")
			var layout: StringName = StringName(mode.get(&"objective_layout")) if mode != null else &""
			objective = layout != &""
			if objective:
				board.add_column({"key": &"objectives", "title": "Caps" if layout == &"ctf" else "Obj",
					"kind": GSMenuScoreboard.KIND_NUMBER}, &"kills")
		elif _teams != null:
			for side: GSTeam in _teams.teams:
				if not side.is_spectator:
					sides.append(side)
		if not objective:
			var _gone := board.remove_column(&"objectives")
		for record in (FcEvents.ranked_by_objectives(_records) if objective else _records.ranked()):
			if not record.present:
				continue
			var known: Dictionary = roster.get(record.key, {})
			rows.append({
				"id": record.key, "rank": rank, "name": record.display_name, "team": _team_of(record),
				"kills": record.kills, "deaths": record.deaths, "assists": record.assists, "score": record.score,
				"objectives": FcEvents.objectives_of(record),
				"seconds": int(known.get("seconds", -1)), "ping": int(known.get("ping", -1)),
				"you": record.key == _me or (you != "" and record.key == you),
			})
			rank += 1
		snap["players"] = rows
		if sides.size() > 1:
			var ctf: Object = null
			var objectives: Object = _game.get(&"objectives") if _game != null and is_instance_valid(_game) else null
			if objectives != null:
				ctf = objectives.get(&"ctf")
			var listed: Array = []
			for side in sides:
				var score := int((ctf.get(&"scores") as Dictionary).get(side.id, 0)) if ctf != null else _records.team_score(side.id)
				listed.append({"id": side.id, "name": side.display_name, "color": side.colour, "score": score})
			snap["teams"] = listed
		if not snap.has("server"):
			snap["server"] = {"name": "Fatal Contact"}

	## A client's records carry no side; the game's own map (the server's TEAM event) does.
	func _team_of(record: GSPlayerScore) -> int:
		if _game != null and is_instance_valid(_game) and record.key.is_valid_int():
			return int(_game.call(&"team_of", int(record.key)))
		return record.team
