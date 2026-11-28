extends Node

const FcPlayer := preload("fc_player.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcFlagView := preload("fc_flag_view.gd")
const FcFlagCarry := preload("fc_flag_carry.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")
const FcControlPoints := preload("fc_control_points.gd")

## What the round is about, when the mode says it is about something.
##
## [b]Fatal Contact's first mode that is not "kill people".[/b] Free-for-all, team
## deathmatch and siege are all scored on kills, which means [GSMatch] alone has always
## been enough. Capture the flag and king of the hill are not, and every hand-written
## version of either gets the same things wrong — see gs-objective's notes.
##
## [b]The layout comes from the map's own numbers.[/b] `FcMap` is built from
## constants — an extent, a floor height, a list of boxes — which is what lets a
## dedicated server that has never drawn the level still know where everything is. So
## the flags sit at the ends of its longest axis and the hill sits at its centre,
## derived rather than authored: a map added later gets a working layout without
## anybody remembering to place two more things in it.
##
## [codeblock]
## var objectives := FcObjectives.new()
## objectives.game = game
## add_child(objectives)
## objectives.setup()
## [/codeblock]

const CHANNEL := "arena.objectives"

## Anything a kind wants to say: a flag taken, a point contested. A HUD connects here.
signal objective_event(id: StringName, what: StringName, data: Dictionary)

## Layout ids a mode names.
const CTF := &"ctf"
const KOTH := &"koth"
const CP := &"cp"

const RED := 1
const BLUE := 2
## The gs-objective level that has `GSObjectivePresence.living_fn`.
const LIVING_LEVEL := 2

## Typed as its native base on purpose: a typed reference back to fc_game.gd closes a
## preload cycle, and GDScript never frees the parser trees of scripts in a cycle (CI perf-smoke mem_mb).
var game: Node = null

var manager: GSObjectiveManager = null

## The capture-the-flag mechanic when the layout is `ctf`; its manager is [member manager].
var ctf: GSObjectiveCtf = null

## The drawn flags when the game draws at all (never headless); null otherwise.
var flag_view: FcFlagView = null
## A dropped flag in flight: {team: velocity}, INF once it rests. A client only knows which fly.
var flag_motion := {}

var _last_wire := ""
## The players marked one-handed last tick ([method FcFlagCarry.mark_carriers] unmarks only them).
var one_hand_ids: Array[int] = []
## `str(id)` of every player, made once per roster ([method _player_keys]), and the `player_ids()` array it was made for.
var _keys := PackedStringArray()
var _keys_for: Array[int] = []
var _wire_tick := -1000000

## Which layout is running. Empty when the mode has none.
var layout: StringName = &""


func setup() -> GSResult:
	if game == null:
		return GSResult.fail(GSError.CODE_STATE, "FcObjectives needs a game.")
	if game.mode == null:
		return GSResult.fail(GSError.CODE_STATE, "There is no mode.")

	# The mode being played: on a networked client the server's (RULES mode_index), whose own `mode` stays the default.
	var played = game.displayed_mode()
	layout = played.objective_layout
	if layout == &"":
		return GSResult.fail(
			GSError.CODE_STATE, "This mode has no objectives."
		)

	if layout == CTF:
		return _setup_ctf()

	var defs := build(layout, game.map, game.tick_rate)
	if defs.is_empty():
		return GSResult.fail(
			GSError.CODE_INVALID, "Unknown objective layout '%s'." % layout
		)

	manager = GSObjectiveManager.new()
	manager.name = "ObjectiveManager"
	manager.authoritative = game.is_authority
	manager.rules = _rules()
	manager.presence = _presence()
	add_child(manager)

	var res := manager.setup(defs)
	if not res.ok:
		return res.wrap("arena objectives")

	manager.score_fn = _score
	manager.objective_completed.connect(_on_completed)
	manager.objective_event.connect(_on_event)
	manager.round_objective_met.connect(_on_round_met)
	if layout == CP:
		_connect_cp()

	# A flag carrier who dies drops it. Connected rather than left to the kill handler,
	# because there are three ways to stop being alive here — shot, fell, disconnected —
	# and a carrier who dies still carrying is a flag nobody can take and that never
	# comes home. gs-objective re-tests it every tick as a second lock on the door.
	if not game.player_killed.is_connected(_on_player_killed):
		game.player_killed.connect(_on_player_killed)

	# The layout is derived from the map's own extent, so a new map is a new layout.
	# Without this a flag stays where the previous map's wall was and a hill sits
	# outside the room — with every objective still ticking, still capturable and
	# still scoring, which is the version of this bug nothing errors on.
	if not game.map_changed.is_connected(_on_map_changed):
		game.map_changed.connect(_on_map_changed)

	GSLog.info(CHANNEL, "layout ready", {"layout": str(layout), "count": defs.size()})
	return GSResult.success(null)


func _setup_ctf() -> GSResult:
	if manager != null and ctf == null:
		remove_child(manager)
		manager.queue_free()
		manager = null
	ctf = GSObjectiveCtf.new()
	ctf.name = "Ctf"
	ctf.rules = game.ctf_rules
	ctf.authoritative = game.is_authority
	ctf.tick_rate = game.tick_rate
	ctf.presence = _presence()
	add_child(ctf)

	var res := ctf.setup(ctf_bases(), _score)
	if not res.ok:
		return res.wrap("arena ctf")

	manager = ctf.manager
	_build_flag_view()
	manager.objective_completed.connect(_on_completed)
	manager.objective_event.connect(_on_event)
	ctf.flag_event.connect(_announce_flag)
	ctf.ended.connect(_on_ctf_ended)
	if not game.player_killed.is_connected(_on_player_killed):
		game.player_killed.connect(_on_player_killed)
	if not game.map_changed.is_connected(_on_map_changed):
		game.map_changed.connect(_on_map_changed)

	GSLog.info(CHANNEL, "ctf ready", {"teams": ctf.flags().size()})
	return GSResult.success(null)


## True when this process has a screen. `game.headless` must not be asked: it is the collision backend and is true on every client, which hid the flags.
static func draws_flags(platform_headless: bool) -> bool:
	return not platform_headless


## Forces the flag view on, for a check that runs without a screen.
var draw_flags := false


## The flags are drawn wherever the game draws (a client, a listen server, a solo game); a dedicated or headless server has no eyes for them.
func _build_flag_view() -> void:
	if flag_view != null or ctf == null or not (draw_flags or draws_flags(GSPlatform.is_headless())):
		return
	flag_view = FcFlagView.new()
	flag_view.name = "FlagView"
	flag_view.game = game
	flag_view.ctf = ctf
	add_child(flag_view)


## Where each team's flag stands (team id -> position): a flag spawn the map or the workbench placed, else the middle of the team's own spawns, else a cluster of all spawns, else the ends of the map's longest axis.
func ctf_bases() -> Dictionary:
	var team_ids: Array[int] = []
	for team in game.displayed_mode().teams():
		team_ids.append(team.id)

	var sites: Array[GSSpawnSite] = []
	var stack = game.player_stack
	if stack != null and stack.spawns != null:
		var playing: Array[StringName] = stack.teams.teams.playing_ids() if stack.teams != null else []
		for site in stack.spawns.sites():
			var copy := GSSpawnSite.point(site.id, site.position, site.yaw, &"")
			copy.enabled = site.enabled
			copy.meta = site.meta
			if GSSpawnFlags.is_flag(site):
				copy.team = site.team
			else:
				var at := playing.find(site.team)
				if at >= 0 and at < team_ids.size():
					copy.team = StringName(str(team_ids[at]))
			sites.append(copy)

	var by_index := {}
	for i in team_ids.size():
		by_index[i + 1] = team_ids[i]

	# Authored flag stands name a team by its place in the mode (1..N), the same numbers the workbench offers.
	for site in sites:
		if GSSpawnFlags.is_flag(site):
			var wanted := GSSpawnFlags.team_id(site)
			site.team = StringName(str(by_index.get(wanted, 0)))

	var found := GSSpawnFlags.bases(sites, team_ids.max() if not team_ids.is_empty() else 2)
	var out := {}
	for id in team_ids:
		if found.has(id):
			out[id] = (found[id] as GSSpawnSite).position

	# A map that placed its flags (imported `flag_spawns`) keeps them where it put them: first team red, second blue.
	var homes: Dictionary = game.map.flag_homes
	if team_ids.size() == 2 and homes.has("red") and homes.has("blue"):
		out[team_ids[0]] = (homes["red"] as Vector3) + Vector3.UP
		out[team_ids[1]] = (homes["blue"] as Vector3) + Vector3.UP

	if out.size() == team_ids.size():
		return out

	# No usable spawns at all: the old derived ends of the map, two teams only.
	var reach: float = maxf(game.map.extent - 4.0, 4.0)
	var floor_y: float = game.map.floor_y
	for i in team_ids.size():
		if not out.has(team_ids[i]):
			var angle := TAU * float(i) / float(team_ids.size())
			out[team_ids[i]] = Vector3(-cos(angle) * reach * 0.8, floor_y + 1.0, sin(angle) * reach * 0.8)
	return out


func _announce_flag(team: int, what: StringName, data: Dictionary) -> void:
	if not game.is_authority:
		return
	var who := str(data.get("by", ""))
	var text := ""
	match what:
		&"taken":
			text = "Team %d's flag was taken" % team
		&"dropped":
			text = "Team %d's flag was dropped" % team
		&"returned":
			text = "Team %d's flag was returned" % team
		&"captured":
			text = "Team %d captured a flag" % int(data.get("team", 0))
	if who != "" and what != &"captured":
		var player: FcPlayer = game.player_for(int(who)) if who.is_valid_int() else null
		if player != null:
			text += " by " + String(player.display_name)
	if text != "":
		game.ctf_announced.emit(text)


func _on_ctf_ended(winner: int, reason: StringName) -> void:
	GSLog.info(CHANNEL, "ctf ended", {"winner": winner, "reason": str(reason)})


## The replicated state as JSON text when it changed (or every two seconds), else "". The bridge sends it.
func ctf_wire_text(tick: int, force: bool = false) -> String:
	if layout == CP:
		return _cp_wire_text(tick, force)
	if ctf == null or not game.is_authority:
		return ""
	if not force and tick - _wire_tick < maxi(game.tick_rate / 8, 1):
		return ""
	var wire: Dictionary = ctf.to_json_wire()
	wire["view"] = {"i": 1 if game.ctf_view.indicator else 0, "x": 1 if game.ctf_view.see_through else 0}
	FcFlagCarry.write_wire(self, wire)
	var text := JSON.stringify(wire)
	if not force and text == _last_wire and tick - _wire_tick < game.tick_rate * 2:
		return ""
	_last_wire = text
	_wire_tick = tick
	return text


## A client applies what the server sent.
func apply_ctf_text(text: String) -> void:
	if layout == CP:
		_apply_cp_text(text)
		return
	if ctf == null or game.is_authority:
		return
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		ctf.apply_wire(parsed)
		var view: Variant = (parsed as Dictionary).get("view")
		if view is Dictionary:
			game.ctf_view.indicator = int(view.get("i", 1)) != 0
			game.ctf_view.see_through = int(view.get("x", 1)) != 0
		FcFlagCarry.read_wire(self, parsed)


# --- Control point ----------------------------------------------------------

## Who made the last capture: the player a sweep is credited to.
var _cp_last_by := ""

## Each point's owner as this end last saw it, to raise `cp_seen` once per change.
var _cp_owners := {}


## The control point hooks, each connected once: the capture, the sweep, and the match going live.
func _connect_cp() -> void:
	if not manager.objective_completed.is_connected(_on_cp_captured):
		manager.objective_completed.connect(_on_cp_captured)
	if not manager.all_captured.is_connected(_on_cp_swept):
		manager.all_captured.connect(_on_cp_swept)
	if not game.match_state_changed.is_connected(_on_cp_match_state):
		game.match_state_changed.connect(_on_cp_match_state)
	_cp_owners = _cp_owners_now()


func _cp_owners_now() -> Dictionary:
	var out := {}
	for obj in FcControlPoints.line_of(manager):
		out[obj.id()] = obj.owner_team
	return out


## A point changed hands: counted for the capper (no points, the sweep is the score), announced, and heard.
func _on_cp_captured(id: StringName, team: int, by: String) -> void:
	if layout != CP:
		return
	_cp_last_by = by
	if by != "" and game.match_node != null:
		game.match_node.report_objective(by, &"cp_captures", game.current_tick(), 0)
	var obj := manager.objective(id)
	var point := obj.def.display_name if obj != null else String(id)
	var text := "%s captured %s" % [_side_name(team), point]
	var player: FcPlayer = game.player_for(int(by)) if by.is_valid_int() else null
	if player != null:
		text += " (%s)" % String(player.display_name)
	game.ctf_announced.emit(text)
	_cp_owners[id] = team
	game.cp_seen.emit(&"captured", id, team)


## One side holds every point: the round's one point, credited to the last capper when they are on that side.
func _on_cp_swept(team: int) -> void:
	if layout != CP or not game.is_authority:
		return
	GSLog.info(CHANNEL, "control points swept", {"team": team, "by": _cp_last_by})
	game.ctf_announced.emit("%s holds every point" % _side_name(team))
	game.cp_seen.emit(&"swept", &"", team)
	var by := _cp_last_by if _cp_last_by.is_valid_int() and game.team_of(int(_cp_last_by)) == team else ""
	if by != "":
		_score(&"cp_sweeps", team, by, 1, 1)
	elif game.match_node != null:
		game.match_node.scoreboard.add_team_score(team, 1)


## Every point back to its starting owner when a match goes live (the first one and each after an intermission).
func _on_cp_match_state(_from: GSMatch.State, to: GSMatch.State) -> void:
	if layout != CP or manager == null or not game.is_authority or to != GSMatch.State.LIVE:
		return
	manager.reset_round()
	_cp_last_by = ""
	_cp_owners = _cp_owners_now()
	_last_wire = ""


static func _side_name(team: int) -> String:
	match team:
		RED:
			return "Red"
		BLUE:
			return "Blue"
	return "Team %d" % team


## The points' state for clients, through the CTF event (the two layouts never run together).
func _cp_wire_text(tick: int, force: bool) -> String:
	if manager == null or not game.is_authority:
		return ""
	if not force and tick - _wire_tick < maxi(game.tick_rate / 8, 1):
		return ""
	var text := JSON.stringify({"cp": manager.to_wire()})
	if not force and text == _last_wire and tick - _wire_tick < game.tick_rate * 2:
		return ""
	_last_wire = text
	_wire_tick = tick
	return text


func _apply_cp_text(text: String) -> void:
	if manager == null or game.is_authority:
		return
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("cp") is Dictionary):
		return
	manager.apply_wire((parsed as Dictionary)["cp"])
	for obj in FcControlPoints.line_of(manager):
		var was := int(_cp_owners.get(obj.id(), obj.owner_team))
		if was != obj.owner_team and obj.owner_team > 0:
			game.cp_seen.emit(&"captured", obj.id(), obj.owner_team)
	_cp_owners = _cp_owners_now()


## A client has no effects layer, so the slowdown it predicts with is applied here, from the same base the effects layer uses.
func _apply_carrier_speed() -> void:
	for id in game.player_ids():
		var player: FcPlayer = game.player_for(id)
		if player == null or player.controller == null or player.controller.tunables == null:
			continue
		var tunables = player.controller.tunables
		if not tunables.has_meta("fc_base_speed"):
			tunables.set_meta("fc_base_speed", tunables.max_speed)
		# Only on a change: a write bumps the tunables' revision and drops the motor's cached native settings.
		var speed := float(tunables.get_meta("fc_base_speed")) * speed_scale(id)
		if tunables.max_speed != speed:
			tunables.max_speed = speed


## Movement multiplier for a player: the carrier slowdown, else 1.
func speed_scale(id: int) -> float:
	return ctf.speed_scale(str(id)) if ctf != null else 1.0


## The ids carrying a flag: the flags walked once, for a per-tick pass that asked [method speed_scale] per player.
func carrier_ids() -> Array[int]:
	var out: Array[int] = []
	if ctf == null:
		return out
	for f in ctf.flags():
		if f.state == GSObjectiveFlag.State.CARRIED:
			out.append(int(f.carrier))
	return out


func _rules() -> GSObjectiveRules:
	var rules := GSObjectiveRules.new()
	rules.live = false  # Warmup. The match turns it on.
	rules.block_style = 1
	rules.deteriorate_ticks = 60 * game.tick_rate
	return rules


func _presence() -> GSObjectivePresence:
	var presence := GSObjectivePresence.of(
		func() -> PackedStringArray:
			return _player_keys(),
		func(key: String) -> Vector3:
			var player: FcPlayer = game.player_for(int(key))
			if player == null or player.controller == null:
				return Vector3(1e9, 1e9, 1e9)
			return player.controller.state.position,
		func(key: String) -> int:
			return game.team_of(int(key)),
		func(key: String) -> bool:
			var player: FcPlayer = game.player_for(int(key))
			return player != null and player.is_alive()
	)
	# An invulnerable player may not capture and may still block, which is the whole
	# reason gs-objective asks those two questions separately.
	presence.may_capture_fn = func(key: String) -> bool:
		if game.effects == null:
			return true
		return game.effects.may_capture(int(key))
	# gs-objective 2 asks for the living in one call per tick (the CTF flag poll and
	# counts_in) instead of three callables per player; same answer as the above.
	if GSAddonApi.build_level("gs_objective") >= LIVING_LEVEL:
		presence.set(&"living_fn", _living)
	return presence


## gs-objective's `living_fn`: `[keys, positions]` of every living player with a body.
func _living() -> Array:
	var keys := PackedStringArray()
	var at := PackedVector3Array()
	var names := _player_keys()
	for i in _keys_for.size():
		var player: FcPlayer = game.player_for(_keys_for[i])
		if player == null or player.controller == null or not player.is_alive():
			continue
		keys.append(names[i])
		at.append(player.controller.state.position)
	return [keys, at]


## `str(id)` for every id of `player_ids()`, in its order. Made again only when the roster changes (a change
## replaces that array), where the presence asked for one string per player per tick.
func _player_keys() -> PackedStringArray:
	var ids: Array[int] = game.player_ids()
	if is_same(ids, _keys_for) and _keys.size() == ids.size():
		return _keys
	_keys_for = ids
	_keys = PackedStringArray()
	for id in ids:
		_keys.append(str(id))
	return _keys


## A layout, from a map's own geometry.
##
## Static and public so a suite can build one without a game, and so
## `FcModes.describe_lines` could one day say how many points a mode has.
static func build(
	which: StringName, map: FcMap, rate: int
) -> Array[GSObjectiveDef]:
	if map == null:
		return []

	var reach := maxf(map.extent - 4.0, 4.0)
	var floor_y := map.floor_y

	match which:
		CP:
			return FcControlPoints.build(map, rate)
		KOTH:
			var hill := GSObjectiveDef.capture(
				&"hill",
				GSObjectiveArea.cylinder(
					Vector3(0.0, floor_y + 1.5, 0.0), reach * 0.3, 3.0
				),
				8 * rate
			)
			hill.display_name = "The Hill"
			hill.label = "H"
			hill.capture_required = 1
			hill.score_points = 0

			var clock := GSObjectiveDef.holdout(&"koth_clock", 90 * rate)
			clock.display_name = "Hold"
			clock.holdout_owner_of = &"hill"
			clock.area = hill.area
			clock.wins_round = true
			clock.score_points = 1
			clock.player_points = 1
			return [hill, clock]

		CTF:
			var red_home := Vector3(-reach * 0.8, floor_y + 1.0, 0.0)
			var blue_home := Vector3(reach * 0.8, floor_y + 1.0, 0.0)

			# A map that placed its flags (imported `flag_spawns`) keeps them where it put them.
			if map.flag_homes.has("red") and map.flag_homes.has("blue"):
				red_home = (map.flag_homes["red"] as Vector3) + Vector3.UP
				blue_home = (map.flag_homes["blue"] as Vector3) + Vector3.UP

			var red := GSObjectiveDef.flag(
				&"red_flag", GSObjectiveArea.sphere(red_home, 2.0), RED
			)
			red.display_name = "Red Flag"
			red.label = "R"
			red.flag_capture_area = GSObjectiveArea.sphere(blue_home, 3.0)
			red.flag_return_ticks = 30 * rate
			red.flag_requires_own_at_home = true
			red.score_points = 1
			red.player_points = 1

			var blue := GSObjectiveDef.flag(
				&"blue_flag", GSObjectiveArea.sphere(blue_home, 2.0), BLUE
			)
			blue.display_name = "Blue Flag"
			blue.label = "B"
			blue.flag_capture_area = GSObjectiveArea.sphere(red_home, 3.0)
			blue.flag_return_ticks = 30 * rate
			blue.flag_requires_own_at_home = true
			blue.score_points = 1
			blue.player_points = 1
			return [red, blue]

	return []


# --- The tick -----------------------------------------------------------------

func tick(delta: float) -> void:
	if manager == null:
		return

	if ctf != null:
		# Sub-spans of the sim host's w_objectives (`--sim_sections 2`): 0 and one test each outside a recording.
		var t_lap := FcFrameProbe.lap_start()
		ctf.advance(game.current_tick(), game.match_node != null and game.match_node.is_live())
		t_lap = FcFrameProbe.lap(&"ob_advance", t_lap)
		if game.is_authority:
			FcFlagCarry.step(self, delta)
		else:
			_apply_carrier_speed()
		t_lap = FcFrameProbe.lap(&"ob_step", t_lap)
		FcFlagCarry.mark_carriers(self)
		t_lap = FcFrameProbe.lap(&"ob_carriers", t_lap)
		return

	# Live exactly while the match is being played. A capture made during warmup is one
	# nobody was allowed to make, and warmup is when everybody is standing on
	# everything.
	if game.match_node != null:
		manager.set_live(game.match_node.is_live())

	manager.advance(game.current_tick())
	_touch_flags()


## A player standing on a flag takes it, or sends it home.
##
## Polled rather than driven by a trigger, because this game has no triggers: every
## other test in it is analytic geometry against `FcMap`, for the reason the map is
## constants in the first place — a dedicated server has never drawn the level.
func _touch_flags() -> void:
	if manager.objectives == null:
		return
	for flag in manager.objectives.flags():
		for id in game.player_ids():
			var player: FcPlayer = game.player_for(id)
			if player == null or not player.is_alive():
				continue
			var at := player.controller.state.position
			if at.distance_to(flag.at) > flag.def.flag_touch_radius:
				continue
			var res := flag.touch(str(id), manager.presence)
			if res.ok:
				break


# --- Events -------------------------------------------------------------------

## Where a completion becomes a score.
##
## [b]Through `report_objective` and not through `add_team_score`, whenever there is a
## player to name.[/b] gs-match's scoreboard credits the player's team from their own
## record, and `report_objective` runs the win check afterwards — which in a mode scored
## by objectives is what ends the round. Adding to the team directly skips both, so the
## capture that wins the game does not end it until somebody happens to get a kill.
##
## The fallback exists for the one completion with nobody to credit — a holdout clock
## running out with the whole team dead — and deliberately does NOT invent a key for it.
## Inventing one is this family's own "report_kill was handed any entity id" bug: a
## scoreboard row keyed on a number no player has ever had.
func _score(
	id: StringName, team: int, by: String, points: int, player_points: int
) -> void:
	if game.match_node == null:
		return
	if by != "" and player_points > 0:
		game.match_node.report_objective(by, id, game.current_tick(), player_points)
		return
	if team > 0 and points > 0:
		game.match_node.scoreboard.add_team_score(team, points)


func _on_completed(id: StringName, team: int, by: String) -> void:
	GSLog.info(
		CHANNEL, "objective completed",
		{"id": str(id), "team": team, "by": by}
	)


func _on_event(id: StringName, what: StringName, data: Dictionary) -> void:
	GSLog.debug(CHANNEL, "objective event", {"id": str(id), "what": str(what)})
	objective_event.emit(id, what, data)


## gs-objective announces and never ends a round. This is where the announcement
## becomes a decision, and it is in the game rather than in the addon.
##
## The scoring already happened in [method _score], which ran the win check with it —
## so this only has to say so. Adding a point here as well would score a capture twice,
## which is the "announce exactly once" bug this family found in gs-vote's play
## history and again in gs-objective's own sweep.
func _on_round_met(id: StringName, team: int, by: String) -> void:
	GSLog.info(
		CHANNEL, "the round objective was met",
		{"id": str(id), "team": team, "by": by}
	)


func _on_player_killed(entry: GSKillFeed.Entry) -> void:
	if manager == null or manager.objectives == null:
		return
	var key := entry.victim_key
	if ctf != null:
		ctf.player_died(key)
		return
	for flag in manager.objectives.flags():
		if flag.carrier != key:
			continue
		var _res := flag.drop(flag.at)


## Rebuild the layout for a new map, keeping the manager and its connections.
func _on_map_changed(new_map: FcMap) -> void:
	if manager == null:
		return

	var wanted: StringName = game.displayed_mode().objective_layout if game.displayed_mode() != null else &""
	if wanted == &"":
		# The new mode has no objectives. Emptying the set is right and freeing the
		# layer is not: `FcGame.objectives` is read by the HUD and by the net
		# bridge, and a freed node behind a live reference is an error at the next
		# access rather than at the free.
		layout = &""
		var _cleared := manager.setup([] as Array[GSObjectiveDef])
		return

	layout = wanted
	if layout == CTF:
		_rebuild_ctf()
		return
	if ctf != null:
		# Leaving capture the flag: its manager goes with it, and the plain path builds its own.
		remove_child(ctf)
		ctf.queue_free()
		ctf = null
		manager = null
		if flag_view != null:
			remove_child(flag_view)
			flag_view.queue_free()
			flag_view = null
		var _again := setup()
		return
	var defs := build(layout, new_map, game.tick_rate)
	var res := manager.setup(defs)
	if layout == CP and res.ok:
		_connect_cp()
		_last_wire = ""
	if not res.ok:
		GSLog.warn(
			CHANNEL, "the new map has no objective layout",
			{"why": res.error.message}
		)


func on_round_reset() -> void:
	if ctf != null:
		ctf.reset_match()
	elif manager != null:
		manager.reset_round()


## Flags back on stands read afresh from the spawns, scores to nought.
func _rebuild_ctf() -> void:
	if ctf == null:
		var res := _setup_ctf()
		if not res.ok:
			GSLog.warn(CHANNEL, "ctf would not build", {"why": res.error.message})
		return
	var res := ctf.setup(ctf_bases(), _score)
	if not res.ok:
		GSLog.warn(CHANNEL, "ctf would not rebuild", {"why": res.error.message})
	_last_wire = ""


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["objectives: none"])
	return manager.describe_lines()
