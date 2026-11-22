## The server cvars for the name tags and health bars over players.
extends GSModule

const FcGame := preload("fc_game.gd")
const TagRules := preload("fc_name_tag_rules.gd")

var game: FcGame = null

## cvar -> the rule key whose value is a TagRules mask, and what it means.
const TAG_CVARS := {
	"mp_nametags": ["nametags", "Who gets a name tag over their head for players: always, team, hover (cursor on the body), hurt, off, or a list like team,hover. A player's own choice can only narrow it"],
	"mp_hpbars": ["hpbars", "Who gets a health bar over their head: always, team, hover, hurt, smart, off, or a list like team,hover. A player's own choice can only narrow it"],
}


## cvar -> [rule key, what it means, lowest, highest, 0 = off/unlimited noted in the text]; NAN is no bound. Out of range or not a number is refused with an error, the old value kept.
const TAG_LOOK_CVARS := {
	"mp_enemy_bar_mode": ["enemy_bar_mode", "Health bar over an ENEMY: 0 never (the default), 1 while the cursor is on them, 2 always. A player's health_bars setting can only narrow it", 0.0, 2.0],
	"mp_enemy_name_mode": ["enemy_name_mode", "Name over an ENEMY: 0 never, 1 while the cursor is on them (the default), 2 always. A player's name_tags setting can only narrow it", 0.0, 2.0],
	"mp_hover_range": ["hover_range", "Metres at which the cursor still counts as on a body (0 = unlimited; 80 is the default)", 0.0, NAN],
	"mp_hover_hold": ["hover_hold", "Seconds an enemy's hover tag stays after the cursor leaves, before it fades (0 = it goes at once)", 0.0, NAN],
	"mp_hover_fade": ["hover_fade", "Seconds an enemy's hover tag takes to fade out after the hold (0 = a hard cut)", 0.0, NAN],
	"mp_team_bar_offset_y": ["team_bar_offset_y", "Metres a team-mate's bar and name hang from the head anchor: negative is lower (-0.3 is the default), positive higher", -10.0, 10.0],
	"mp_team_bar_width": ["team_bar_width", "Width of a team-mate's health bar, metres (0.8 is the default)", 0.01, NAN],
	"mp_team_bar_height": ["team_bar_height", "Height of a team-mate's health bar, metres (0.065 is the default)", 0.005, NAN],
	"mp_team_bar_style": ["team_bar_style", "A team-mate's bar: 0 the classic glass pill, 1 modern (slim, soft backing, flat fill; the default)", 0.0, 1.0],
	"mp_show_team_names": ["show_team_names", "Team-mates' names float over their bars (1, the default) or only the bar shows (0). The server's mp_nametags and the player's name_tags still apply", 0.0, 1.0],
	"mp_tag_fade_start": ["tag_fade_start", "Metres from the eye where tags start to fade out (25 is the default)", 0.0, NAN],
	"mp_tag_fade_end": ["tag_fade_end", "Metres where tags are gone (0 = no distance fade; 60 is the default)", 0.0, NAN],
}


func _add_tag_look_cvars() -> void:
	for cvar in TAG_LOOK_CVARS:
		var row: Array = TAG_LOOK_CVARS[cvar]
		var key: String = row[0]
		var start := float(FcGame.SHOW_DEFAULTS[key])
		var cv := add_cvar(
			cvar, str(start), row[1], GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED)
		if not is_nan(float(row[2])):
			cv.with_min(float(row[2]))
		if not is_nan(float(row[3])):
			cv.with_max(float(row[3]))
		cv.changed.connect(
			func(_old: String, new_value: String) -> void:
				game.set_movement_rules({key: new_value.to_float()})
				log_info("tag look changed", {"rule": key, "value": new_value})
		)


func _add_tag_cvars() -> void:
	_add_tag_look_cvars()
	for cvar in TAG_CVARS:
		var key: String = TAG_CVARS[cvar][0]
		var start := int(FcGame.SHOW_DEFAULTS[key])
		add_cvar(
			cvar, TagRules.describe(start), TAG_CVARS[cvar][1],
			GSConVar.FLAG_ARCHIVE | GSConVar.FLAG_NOTIFY | GSConVar.FLAG_REPLICATED
		).changed.connect(
			func(old: String, new_value: String) -> void:
				var mask := TagRules.parse(new_value)
				if mask < 0:
					log_info("tag rule refused", {"rule": key, "value": new_value, "kept": old})
					return
				game.set_movement_rules({key: float(mask)})
				log_info("tag rule changed", {"rule": key, "value": TagRules.describe(mask)})
		)
