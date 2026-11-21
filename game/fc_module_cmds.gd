extends "fc_module_players_and_commands.gd"

const FcMap := preload("../maps/fc_map.gd")
const FcMaps := preload("fc_maps.gd")
const FcModes := preload("fc_modes.gd")

func _cmd_modes(ctx: GSCmdContext) -> void:
	ctx.reply_lines(PackedStringArray(FcModes.describe_lines()))
	ctx.reply("Playing: %s" % String(game.mode.id))


func _cmd_net(ctx: GSCmdContext) -> void:
	if net == null:
		ctx.reply("The netcode is not running.")
		return

	for line in net.describe_lines():
		ctx.reply(line)

	if bridge != null:
		ctx.reply(str(bridge.describe()))


func _cmd_status(ctx: GSCmdContext) -> void:
	for line in game.describe_lines():
		ctx.reply(line)


## What `fc_maps` prints. [b]It lists and does not change.[/b] `FcGame.setup` is not re-entrant (it builds the combat trace, the match node and every spawn point as children in one pass),
## so a `changelevel` that called it twice would leave two matches and two sets of spawns in one tree; doing it properly means tearing that down and telling every client.
## Until then an operator restarts with `-- --map <id>`, and this is how they find out what to type.
func _cmd_maps(ctx: GSCmdContext) -> void:
	var current := game.map.display_name if game.map != null else "?"

	for id in FcMap.ids():
		ctx.reply("%s %s%s" % [
			"*" if String(id) == current else " ", String(id),
			"" if _in_rotation(id) else "  (not in rotation)",
		])

	# The imported maps, with their author (somebody else's work, and the credit travels
	# with it) and whether the rotation offers them.
	for id in FcMap.imported_ids():
		var author := str(FcMap.FcImportedMaps.manifest(id).get("author", "?"))
		ctx.reply("%s %s  (%s by %s%s)" % [
			"*" if String(id) == current else " ", String(id),
			FcMaps.imported_label(id).to_lower(), author,
			"" if FcMaps.in_rotation(id) and _in_rotation(id) else ", not in rotation",
		])

	# The maps the server names as packs: fetched the first time one is changed to.
	if maps != null and maps.session != null and maps.session.catalogue != null:
		for def in maps.session.catalogue.maps:
			if not FcMaps.is_delivered(def):
				continue

			ctx.reply("%s %s  (delivered: %s%s%s)" % [
				"*" if game.map != null and game.map.id == def.id else " ", String(def.id),
				str(def.meta.get("key", "")),
				", mounted" if FcMap.FcImportedMaps.is_mounted(def.id) else ", fetched on change",
				"" if def.enabled and def.in_rotation else ", not in rotation",
			])

	ctx.reply("`map <id>` changes it under the players. `maps` is gs-map's list; this one also credits the imported maps' authors.")


## Whether maps.yml's active rotation plays [param id]. A map the catalogue lacks is not.
func _in_rotation(id: StringName) -> bool:
	if maps == null or maps.session == null or maps.session.catalogue == null:
		return true

	var def := maps.session.catalogue.get_map(id)

	return def != null and def.in_rotation


func _cmd_score(ctx: GSCmdContext) -> void:
	for line in game.match_node.scoreboard.describe_lines():
		ctx.reply(line)


## Disconnects a peer whose message schema this server cannot play with, with gs-net's
## sentence as the reason. See `peer_schema_refused` above.
func _refuse_peer(peer_id: int, error: GSError) -> void:
	var session: GSClientSession = server.session_of(peer_id) if server != null else null
	if session != null:
		server.kick(session, error.message, error)
