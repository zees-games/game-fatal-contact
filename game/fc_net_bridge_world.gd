extends "fc_net_bridge_b1.gd"

## The bridge's world events, score mirroring and a hitscan rewind's per-target pieces. Split out of fc_net_bridge_b2.gd for file size.


## The events about the world (bullets, toys, drops, the jail and the rules), split from [method _on_event].
func _on_world_event(event: FcEvent, reader: DotNetReader) -> void:
	match event.kind:
		FcEvents.Kind.BULLET:
			var bullet := FcEvents.read_bullet(reader)
			if bool(bullet["ok"]):
				game.mirror_bullet(int(bullet["id"]), FcContent.weapon_at(int(bullet["weapon"])),
					bullet["origin"], bullet["velocity"], int(bullet["owner"]))
		FcEvents.Kind.BULLET_END:
			var ended := FcEvents.read_bullet_end(reader)
			if bool(ended["ok"]):
				game.end_bullet_mirror(int(ended["id"]))
		FcEvents.Kind.TOYS:
			var told := FcEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		FcEvents.Kind.DROP:
			var drop := FcEvents.read_drop(reader)
			if bool(drop["ok"]) and game.drops != null:
				game.drops.mirror_drop(
					int(drop["id"]), int(drop["kind"]), drop["at"], drop["from"], int(drop["value"])
				)
		FcEvents.Kind.TAKEN:
			var took := FcEvents.read_taken(reader)
			if bool(took["ok"]) and game.drops != null:
				game.drops.mirror_taken(int(took["id"]), int(took["taker"]))
		FcEvents.Kind.WEAPON_DROP, FcEvents.Kind.WEAPON_SETTLED, FcEvents.Kind.WEAPON_GONE:
			_apply_weapon_drop_event(event.kind, reader)
		FcEvents.Kind.PANE_BROKEN:
			_apply_pane_broken(reader)
		FcEvents.Kind.MORE:
			_apply_more_event(reader)
		FcEvents.Kind.PROP_BROKEN:
			_apply_prop_broken(reader)
		FcEvents.Kind.MAP_STATE:
			var told_state: Variant = null
			if not event.body.is_empty():
				told_state = JSON.parse_string(event.body.get_string_from_utf8())
			if told_state is Dictionary and game != null and game.map_io != null:
				game.map_io.receive(told_state)
		FcEvents.Kind.CTF:
			if game != null and game.objectives != null:
				game.objectives.apply_ctf_text(event.body.get_string_from_utf8())
		FcEvents.Kind.TEAM:
			if game != null:
				game.apply_teams_text(event.body.get_string_from_utf8())
		FcEvents.Kind.SCORE:
			var told_scores := FcEvents.read_scores(reader)
			if bool(told_scores["ok"]) and game != null:
				_apply_scores(told_scores)
		FcEvents.Kind.JAIL:
			var told_jail := FcEvents.read_jail(reader)
			if bool(told_jail["ok"]) and game != null:
				game.apply_jail_state(told_jail)
		FcEvents.Kind.RULES:
			var rules := FcEvents.read_rules(reader)
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


## How far, in ticks, a shot's view tick may sit outside its bracket and still be blended in it.
const SHOT_BRACKET_SLACK := 0.2

## The resume ease a firing command says it drew a target off its samples by, when within `sv_shot_ease_max`; a larger one is refused, counted and logged, and the samples stand alone.
func _judged_ease(ease: Vector3, count: bool) -> Vector3:
	if ease == Vector3.ZERO:
		return ease
	if game.shot_ease_max > 0.0 and ease.length() > game.shot_ease_max:
		_count_shot(&"refused_ease", count)
		return Vector3.ZERO
	_count_shot(&"eased", count)
	return ease

## The source for a target's own sample pair [param pair] (absolute ticks), as the client's interpolator drew it at [param view_tick]: between the two, or past the newer by at most `max_extrapolation_sec`, then held there.
func _target_source(pair: Vector2i, view_tick: float, max_span: int, count: bool) -> Array:
	var span := pair.y - pair.x
	if span <= 0 or (max_span > 0 and span > max_span):
		_count_shot(&"refused_span", count)
		return []
	if view_tick < float(pair.x) - SHOT_BRACKET_SLACK:
		_count_shot(&"refused_view", count)
		return []
	if view_tick <= float(pair.y) + SHOT_BRACKET_SLACK:
		_count_shot(&"target", count)
		return [&"target", pair.x, pair.y, clampf(view_tick, float(pair.x), float(pair.y))]
	var max_ahead := net.config.max_extrapolation_sec * float(net.config.tick_rate) if net != null and net.config != null else 0.0
	if view_tick - float(pair.y) > max_ahead:
		_count_shot(&"target_held", count)
		return [&"target_held", pair.x, pair.y, float(pair.y)]
	_count_shot(&"target_ahead", count)
	return [&"target_ahead", pair.x, pair.y, view_tick]

func _count_shot(key: StringName, count: bool) -> void:
	if count:
		game.count_shot_rewind(key)
