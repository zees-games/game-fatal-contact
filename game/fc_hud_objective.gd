@tool
extends "fc_hud_base.gd"

## The HUD's objective line. Split out of fc_hud.gd for file size.


## One line about the objectives, or nothing at all. Reads the mirroring manager on a client and the real one on a listen server, which
## is the same object either way: `FcObjectives` holds a `DotObjectiveManager` whose `authoritative` decides whether it simulates, and a HUD asking it for a fraction does
## not care which.
func _objective_line() -> String:
	if game.objectives == null or game.objectives.manager == null:
		return ""

	var manager := game.objectives.manager

	if not manager.has_objectives():
		return ""

	# Capture the flag says it all in the strip: the captures on each side's plate, its flag's state in the tag.
	if game.objectives.ctf != null:
		return ""

	var parts := PackedStringArray()

	for objective in manager.objectives.objectives:
		var label := objective.def.label if objective.def.label != "" \
			else String(objective.id())

		if objective is DotObjectiveHoldout:
			var holdout := objective as DotObjectiveHoldout
			var lead := holdout.leader()
			if lead <= 0:
				parts.append("%s --" % label)
			else:
				var left := holdout.remaining_for(lead)
				parts.append(
					"%s %d:%02d" % [
						label,
						left / (60 * game.tick_rate),
						(left / game.tick_rate) % 60,
					]
				)
		elif objective is DotObjectiveFlag:
			var flag := objective as DotObjectiveFlag
			parts.append(
				"%s %s" % [
					label,
					DotObjectiveFlag.State.keys()[flag.state].substr(0, 4),
				]
			)
		elif objective.owner_team > 0:
			parts.append("%s:%d" % [label, objective.owner_team])
		else:
			parts.append("%s %d%%" % [label, int(objective.progress() * 100.0)])

	return "  ".join(parts)
