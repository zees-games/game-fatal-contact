extends "arena_net_bridge_b1.gd"

## The bridge's world events and score mirroring. Split out of arena_net_bridge_b2.gd for file size.


## The events about the world (bullets, toys, drops, the jail and the rules), split from [method _on_event].
func _on_world_event(event: ArenaEvent, reader: DotNetReader) -> void:
	match event.kind:
		ArenaEvents.Kind.BULLET:
			var bullet := ArenaEvents.read_bullet(reader)
			if bool(bullet["ok"]):
				game.mirror_bullet(int(bullet["id"]), ArenaContent.weapon_at(int(bullet["weapon"])),
					bullet["origin"], bullet["velocity"], int(bullet["owner"]))
		ArenaEvents.Kind.BULLET_END:
			var ended := ArenaEvents.read_bullet_end(reader)
			if bool(ended["ok"]):
				game.end_bullet_mirror(int(ended["id"]))
		ArenaEvents.Kind.TOYS:
			var told := ArenaEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		ArenaEvents.Kind.DROP:
			var drop := ArenaEvents.read_drop(reader)
			if bool(drop["ok"]) and game.drops != null:
				game.drops.mirror_drop(
					int(drop["id"]), int(drop["kind"]), drop["at"], drop["from"], int(drop["value"])
				)
		ArenaEvents.Kind.TAKEN:
			var took := ArenaEvents.read_taken(reader)
			if bool(took["ok"]) and game.drops != null:
				game.drops.mirror_taken(int(took["id"]), int(took["taker"]))
		ArenaEvents.Kind.WEAPON_DROP, ArenaEvents.Kind.WEAPON_SETTLED, ArenaEvents.Kind.WEAPON_GONE:
			_apply_weapon_drop_event(event.kind, reader)
		ArenaEvents.Kind.PANE_BROKEN:
			_apply_pane_broken(reader)
		ArenaEvents.Kind.MORE:
			_apply_more_event(reader)
		ArenaEvents.Kind.PROP_BROKEN:
			_apply_prop_broken(reader)
		ArenaEvents.Kind.MAP_STATE:
			var told_state: Variant = null
			if not event.body.is_empty():
				told_state = JSON.parse_string(event.body.get_string_from_utf8())
			if told_state is Dictionary and game != null and game.map_io != null:
				game.map_io.receive(told_state)
		ArenaEvents.Kind.CTF:
			if game != null and game.objectives != null:
				game.objectives.apply_ctf_text(event.body.get_string_from_utf8())
		ArenaEvents.Kind.TEAM:
			if game != null:
				game.apply_teams_text(event.body.get_string_from_utf8())
		ArenaEvents.Kind.SCORE:
			var told_scores := ArenaEvents.read_scores(reader)
			if bool(told_scores["ok"]) and game != null:
				_apply_scores(told_scores)
		ArenaEvents.Kind.JAIL:
			var told_jail := ArenaEvents.read_jail(reader)
			if bool(told_jail["ok"]) and game != null:
				game.apply_jail_state(told_jail)
		ArenaEvents.Kind.RULES:
			var rules := ArenaEvents.read_rules(reader)
			if bool(rules["ok"]) and game != null:
				game.set_movement_rules(rules["rules"])
		_:
			pass


## The server's counters over this client's scoreboard, whose records JOIN made with names and nothing else.
## Whole values, not deltas, so a missed event or a round reset is mended by the next one.
func _apply_scores(told: Dictionary) -> void:
	if game.is_authority or game.match_node == null or game.match_node.scoreboard == null:
		return
	var board: DotScoreboard = game.match_node.scoreboard
	for row: Dictionary in told["rows"]:
		var record := board.find(str(int(row["session_id"])))
		if record == null:
			continue
		record.kills = int(row["kills"])
		record.deaths = int(row["deaths"])
		record.assists = int(row["assists"])
		record.score = int(row["score"])
		record.extra = {&"objectives": int(row["objectives"])} if int(row["objectives"]) > 0 else {}
		board.score_changed.emit(record)
	var teams: Dictionary = told["teams"]
	for team: int in teams:
		board.add_team_score(team, int(teams[team]) - board.team_score(team))
	for team in board.team_scores():
		if not teams.has(team):
			board.add_team_score(int(team), -board.team_score(int(team)))
