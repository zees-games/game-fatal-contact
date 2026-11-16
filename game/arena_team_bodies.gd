extends RefCounted

## FC's team avatars: in a team mode every player on a side is drawn as that side's own body
## (dot-player-char's registered bodies, `DotHumanoidAssets.register_body`), tinted the side's colour.
##
## The bodies are other people's art prepared on the kit rig (dot-player-char docs/avatar-prep.md) and are
## not in this repository: each is a `<id>.glb` in one of [member ArenaConfig.team_body_dirs], registered
## the first time a look asks. A side whose body is missing, a free-for-all, or the server's
## `team_avatars` rule at 0 draw each player's own look ([method ArenaAvatars.look_of]), the library people.
##
## Static, like the name tags' rules: the client follows the server's rules and sides once a frame
## ([method follow]) and every look built after asks here, the own view's arms and the portraits included.

const ArenaAvatars := preload("arena_avatars.gd")
const ArenaNewerApi := preload("arena_newer_api.gd")

## The dot-player-char level with registered bodies and the team tint. Below it (the shell's older dot-player-char)
## nobody wears a team body and every side keeps its own looks.
const BODIES_LEVEL := 26

const CHANNEL := &"arena.team_bodies"

## The server rules that bind a registered body to the first and second playing side (the app's
## `team:<body>:a` / `team:<body>:b` avatar slots); -1 keeps the config order.
const SIDE_RULES: PackedStringArray = ["team_body_a", "team_body_b"]

## Who made each team body, for the Credits page ([method ArenaMenus.add_pages]): body id -> lines.
## Both are CC BY 4.0 from Sketchfab, which requires the credit wherever the art is shown. The
## SWAT model is built from other people's CC BY parts, and each of those is credited too.
const CREDITS := {
	&"fc_military": [
		"\"Game Ready Military Character\" by jayb3e (sketchfab.com/jayb3e), CC BY 4.0, via Sketchfab.",
	],
	&"fc_swat": [
		"\"S.W.A.T. Operator - 4k Followers Special Remaster\" by SpatialNeglect (sketchfab.com/jeandiz), CC BY 4.0, via Sketchfab.",
		"Built from CC BY 4.0 parts by bobeer (gloves), VassKacsoHunor (night-vision goggles), Simon Coenen (helmet), Bzovius (uniform), Albin (boots), Shedmon (balaclava) and h1ggs (KRSV Vector).",
	],
}

## Whether the server forces the team bodies (its `team_avatars` rule, `fc_team_avatars`).
static var forced := true
## Team id -> [body id, side colour] for the sides that have a registered body; empty off a team mode.
static var _sides: Dictionary = {}
## The body list and directories the last registration was for, and what it registered, in team order.
static var _registered_for := ""
static var _bodies: Array[StringName] = []
## Changes whenever what a team look depends on changed, so a drawn body knows to be rebuilt.
static var version := 0
## The tint followed from the server's `team_tint` rule; dot-player-char's `DotHumanoidAssets.team_tint` follows it.
static var _tint := 0.35


## Registers the bodies [param ids] names (comma list, one per side in team order; an empty entry
## leaves that side its own looks) from the first of [param dirs] (comma list) holding `<id>.glb`.
## Returns the ids it registered; a missing file is logged once and that side falls back.
static func register(ids: String, dirs: String) -> Array[StringName]:
	var key := ids + "|" + dirs
	if key == _registered_for:
		return _bodies
	_registered_for = key
	_bodies.clear()
	for raw in ids.split(","):
		var id := StringName(raw.strip_edges())
		if id == &"":
			_bodies.append(&"")
			continue
		var path := _find(String(id), dirs)
		if path == "":
			DotLog.warn(CHANNEL, "team body not found; that side wears its own looks", {"id": String(id), "dirs": dirs})
			_bodies.append(&"")
			continue
		_bodies.append(id if has_bodies() and bool(ArenaNewerApi.call_static(&"DotHumanoidAssets", &"register_body", [id, path])) else &"")
	version += 1
	return _bodies


## Whether this build's dot-player-char draws registered bodies ([constant BODIES_LEVEL]).
static func has_bodies() -> bool:
	return DotAddonApi.build_level("dot_player_char") >= BODIES_LEVEL


## The first `<dir>/<id>.glb` that exists, else "".
static func _find(id: String, dirs: String) -> String:
	for raw in dirs.split(",", false):
		var dir := raw.strip_edges()
		if dir == "":
			continue
		var path := dir.path_join(id + ".glb")
		if FileAccess.file_exists(path):
			return path
	return ""


## Follows [param game]'s rules and sides; called once a frame by the client. Cheap when nothing changed.
static func follow(game: Object) -> void:
	if game == null:
		return
	var config: Variant = game.get(&"config")
	if config != null:
		var _ids := register(String(config.get(&"team_bodies")), String(config.get(&"team_body_dirs")))
	var on := float(game.call(&"rule", "team_avatars")) != 0.0
	var tint := float(game.call(&"rule", "team_tint"))
	var sides := {}
	var shown: Variant = game.call(&"displayed_mode")
	if on and shown != null and bool(shown.call(&"is_team_mode")):
		var at := 0
		for t in game.call(&"teams"):
			if t.is_spectator:
				continue
			var pick := _pick(game, at)
			if pick < _bodies.size() and _bodies[pick] != &"":
				sides[t.id] = [_bodies[pick], t.colour]
			at += 1
	if on != forced or not is_equal_approx(tint, _tint) or sides != _sides:
		forced = on
		_tint = tint
		if has_bodies():
			ArenaNewerApi.script_of(&"DotHumanoidAssets").set(&"team_tint", tint)
		_sides = sides
		version += 1


## Which registered body (index into the config's `team_bodies`) the [param at]th playing side wears:
## the server's `team_body_a` / `team_body_b` rule when the app's avatars settings bound one
## (`ArenaAppWiring`), else the side's own place in the list. A rule past the list is logged by the
## server when it is set and draws the side's own looks here.
static func _pick(game: Object, at: int) -> int:
	if at < SIDE_RULES.size():
		var bound := int(float(game.call(&"rule", SIDE_RULES[at])))
		if bound >= 0:
			return bound
	return at


## The registered body [param team] wears, or &"" for its own looks.
static func body_of(team: int) -> StringName:
	return _sides[team][0] if forced and _sides.has(team) else &""


## What [param team]'s players wear, as a key a drawn body compares: "" for their own looks, else the body,
## the side's colour and the tint (each one material, so any change is a rebuild).
static func wear_key(team: int) -> String:
	var body := body_of(team)
	if body == &"":
		return ""
	return "%s|%s|%.3f" % [body, (_sides[team][1] as Color).to_html(), _tint]


## [param avatar]'s look ([method ArenaAvatars.look_of]), worn as [param team]'s body in its colour when
## that side has one: the face, hair and trousers stay the player's, only the body and the top are the side's.
static func look_of(avatar: DotAvatar, player_key: StringName, team: int) -> DotHumanoidLook:
	var look := ArenaAvatars.look_of(avatar, player_key)
	var body := body_of(team)
	if body == &"" or not has_bodies() or not (ArenaNewerApi.script_of(&"DotHumanoidLook").get(&"registered") as Dictionary).has(body):
		return look
	look.body = body
	look.top = _sides[team][1]
	return look
