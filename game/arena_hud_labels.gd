@tool
extends "arena_hud_objective.gd"

## A side's name over its score, with what became of its flag in capture the flag: "RED", "RED · TAKEN", "RED · 12s" to its return.
func _side_tag(side: DotTeam) -> String:
	var tag := side.display_name.to_upper()
	var flag := game.objectives.ctf.flag_of(side.id) if game.objectives != null and game.objectives.ctf != null else null
	if flag == null:
		return tag
	match flag.state:
		DotObjectiveFlag.State.CARRIED:
			return "%s · TAKEN" % tag
		DotObjectiveFlag.State.DROPPED:
			var returns_in := ceili(float(flag.return_left) / float(maxi(game.objectives.ctf.tick_rate, 1)))
			return "%s · %ds" % [tag, returns_in] if returns_in > 0 else "%s · DROPPED" % tag
	return tag


## A side's score for the strip: captures in capture the flag (the CTF state every client mirrors at once), else the scoreboard's.
func _side_score(side: DotTeam) -> int:
	if game.objectives != null and game.objectives.ctf != null:
		return int(game.objectives.ctf.scores.get(side.id, 0))
	return game.match_node.scoreboard.team_score(side.id)


## `strip.show_scores` only when something it shows changed: it queues a redraw on every call, and this runs every frame.
func _show_scores(p_left: int, p_right: int, p_left_tag: String, p_right_tag: String, p_left_colour: Color, p_right_colour: Color) -> void:
	if strip.sides and strip.left_score == p_left and strip.right_score == p_right and strip.left_tag == p_left_tag \
			and strip.right_tag == p_right_tag and strip.left_colour == p_left_colour and strip.right_colour == p_right_colour:
		return
	strip.show_scores(p_left, p_right, p_left_tag, p_right_tag, p_left_colour, p_right_colour)


func _live() -> bool:
	return player != null and is_instance_valid(player)


## [param team]'s colour, or transparent when it is no side (a free-for-all, nobody).
func _team_colour(team: int) -> Color:
	if team <= 0 or game == null:
		return Color(0, 0, 0, 0)
	var mode := game.displayed_mode()
	if mode == null or not mode.is_team_mode():
		return Color(0, 0, 0, 0)
	var side := game.team_def(team)
	return side.colour if side != null else Color(0, 0, 0, 0)


## A name's colour in the feed: gold for you, the side's colour in a team mode, else white.
func _name_colour(key: String, team: int, me: String) -> Color:
	if key == me and me != "":
		return GOLD
	var side := _team_colour(team)
	return side.lightened(0.35) if side.a > 0.0 else Color(0.95, 0.96, 0.98)


## What the ammunition counter shows for [param who]: the magazine, or for a weapon that
## has none, what is left in its pool. Static so a suite can ask it without a HUD.
static func rounds_in_hand(who: ArenaPlayer) -> int:
	if who == null or who.arsenal == null:
		return 0

	var slot := who.arsenal.current()

	if slot == null:
		return 0

	if slot.def.magazine > 0:
		return slot.magazine

	if slot.def.ammo_type == &"":
		return 0

	return who.arsenal.ammo().count(slot.def.ammo_type)


## The line over the counter: the weapon's name and, for one with a magazine, the reserve.
## A melee weapon is its name alone.
static func weapon_line(who: ArenaPlayer) -> String:
	if who == null or who.arsenal == null or not who.is_alive():
		return ""

	var slot := who.arsenal.current()

	if slot == null:
		return ""

	if slot.def.magazine <= 0 or slot.def.ammo_type == &"":
		return slot.def.display_name

	return "%s   %d" % [slot.def.display_name, who.arsenal.ammo().count(slot.def.ammo_type)]
