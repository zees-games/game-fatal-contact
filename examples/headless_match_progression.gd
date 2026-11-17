extends "headless_match_wall_rules_and_interface.gd"

## dot-stats, dot-achievements and dot-leaderboard, over the match that just ran. Every check is against a number the match
## PRODUCED, not one this test filed: reading back one's own readings tests dot-stats, and what is untested elsewhere is
## whether a kill here reaches those three addons at all.
func _test_progression() -> void:
	_section("progression")

	var progress := _game.progress

	if not _check(progress != null, "the game keeps progress"):
		return

	_check(
		progress.stats != null and progress.achievements != null
			and progress.boards != null,
		"stats, achievements and boards are all up"
	)

	var bot_id: int = FcGame.BOT_SESSION_BASE + 1
	progress.begin(bot_id, "bot")
	progress.record(bot_id, &"kills", 1.0)
	_check(not progress.stats.has_player(StringName(FcGame.storage_key(bot_id))), "a bot never enters the stats")

	# The catalogue's validator refuses one stat read with two merge rules (a total and a personal best cannot be one number);
	# checked here because otherwise one achievement never unlocks for one player with nothing erroring.
	var catalogue_ok := progress.achievements.catalogue.validate()
	_check(catalogue_ok.ok, "the achievement catalogue validates", str(catalogue_ok.error))

	var schema_ok := progress.stats.schema.validate()
	_check(schema_ok.ok, "the stats schema validates", str(schema_ok.error))

	# Every stat an achievement reads must be declared by the schema. Neither addon can check this (each is unaware of
	# the other): two ends of one serialisation that never met, and one loop.
	var undeclared := PackedStringArray()

	for stat in progress.achievements.catalogue.watched_stats():
		if not progress.stats.schema.has(stat):
			undeclared.append(String(stat))

	_check(
		undeclared.is_empty(),
		"every stat an achievement watches is one the schema declares",
		", ".join(undeclared)
	)

	# --- What the match actually filed -----------------------------------

	var total_kills := 0.0
	var total_fired := 0.0
	var total_hit := 0.0
	var any_deaths := false
	var best_streak := 0.0

	for player in _game.players():
		var values := progress.session_values(player.player_id)
		total_kills += values.get_value(FcStats.KILLS, 0.0)
		total_fired += values.get_value(FcStats.SHOTS_FIRED, 0.0)
		total_hit += values.get_value(FcStats.SHOTS_HIT, 0.0)
		best_streak = maxf(best_streak, values.get_value(FcStats.BEST_STREAK, 0.0))

		if values.get_value(FcStats.DEATHS, 0.0) > 0.0:
			any_deaths = true

	# The kill feed is the independent witness. Suicides carry no killer, so the
	# stat total is the feed's count minus those — asserting equality against the
	# raw feed size would fail the moment a bot rocket-jumped into a wall.
	var credited := 0

	for entry in _kills:
		if entry.killer_key != "" and not entry.suicide:
			credited += 1

	_check(
		total_kills == float(credited),
		"every credited kill reached dot-stats",
		"feed %d, stats %d" % [credited, int(total_kills)]
	)

	_check(any_deaths, "deaths were counted too")

	_stats_event_check(progress)

	_check(
		total_fired > 0.0,
		"shots fired were counted",
		"%d" % int(total_fired)
	)

	# One shot is one shot whatever it fired. If this counted damage events instead,
	# a shotgun's nine pellets would make hits exceed shots and a shotgun player nine
	# times as accurate as a rifle player.
	_check(
		total_hit <= total_fired,
		"shots landed never exceed shots fired",
		"%d hit of %d fired" % [int(total_hit), int(total_fired)]
	)

	_check(
		best_streak >= 1.0,
		"a best streak was filed as a best rather than a sum",
		"%d" % int(best_streak)
	)

	# Achievements: First Blood is one kill and the match produced six, so this would pass even if dot-stats and
	# dot-achievements were wired straight through (the bug DotAchievementStatsLink prevents); it proves they connect at all.
	var unlocked_any := false

	for player in _game.players():
		if progress.achievements.is_unlocked(
			FcGame.storage_key(player.player_id), &"arena.first_blood"
		):
			unlocked_any = true

	_check(unlocked_any, "somebody unlocked First Blood")

	# The differencing itself. A player with N session kills must hold N lifetime
	# kills, not the running sum 1+2+...+N that a direct signal connection produces —
	# which for six kills is twenty-one and for a hundred is five thousand.
	var mismatched := PackedStringArray()

	for player in _game.players():
		var key := FcGame.storage_key(player.player_id)
		var held := progress.achievements.progress_of(key)

		if held == null:
			continue

		var session := progress.session_values(player.player_id).get_value(
			FcStats.KILLS, 0.0
		)

		if absf(held.value_of(FcStats.KILLS) - session) > 0.001:
			mismatched.append("%s: lifetime %.0f, session %.0f" % [
				key, held.value_of(FcStats.KILLS), session
			])

	_check(
		mismatched.is_empty(),
		"lifetime kills equal session kills, so the link differences rather than sums",
		", ".join(mismatched)
	)

	# Boards: filed when a player leaves, so this removes one. The only place `leave` is exercised, and it is a coroutine
	# (the achievement store may be remote), so it is awaited here.
	var leaver := _game.players()[0]
	var leaver_key := StringName(FcGame.storage_key(leaver.player_id))
	var leaver_kills := progress.session_values(leaver.player_id).get_value(
		FcStats.KILLS, 0.0
	)

	await progress.leave(leaver.player_id)

	var scope := FcBoards.scope_for(_game.mode.id)
	var entry := progress.boards.entry_for(FcBoards.KILLS, scope, leaver_key)

	if leaver_kills > 0.0:
		_check(
			entry.ok and entry.value is DotLeaderboardEntry,
			"a player who leaves lands on the kills board"
		)

		if entry.ok and entry.value is DotLeaderboardEntry:
			_check(
				absf((entry.value as DotLeaderboardEntry).value - leaver_kills) < 0.001,
				"with the number they actually scored",
				"board %s, session %d" % [
					str((entry.value as DotLeaderboardEntry).value), int(leaver_kills)
				]
			)
	else:
		# A zero is deliberately NOT filed: a SCORE board of zeroes is noise and a
		# zero on the PENALTY board would hold first place for ever.
		_check(
			not (entry.ok and entry.value is DotLeaderboardEntry),
			"a player who scored nothing is not put on a board"
		)

	await _test_boards_async(progress)

	# Every board this game defines has to be one the manager will accept. A
	# definition rejected at boot is a board that silently holds nothing.
	var defined := progress.boards.definitions().size()
	_test_progression_rest(defined)

## Which spawn of [param map] is nearest [param at], and how far: [index, metres].
func _nearest_spawn(map: FcMap, at: Vector3) -> Array:
	var best := -1
	var best_distance := INF

	for index in range(map.spawns.size()):
		var distance := map.spawns[index].origin.distance_to(at)

		if distance < best_distance:
			best = index
			best_distance = distance

	return [best, best_distance]

## The spawn tag of match team [param team_id], or empty outside a team mode.
func _spawn_tag_of_team(team_id: int) -> StringName:
	for team in _game.teams():
		if team.id == team_id:
			return team.spawn_tag

	return &""

func _test_map_change_rest(director: FcMapDirector, team: FcMode) -> void:
	if team != null:
		var to_team := _game.change_map(FcMap.by_id(_game.map.id), team)

		if _check(to_team.ok, "the game moves into a team mode", str(to_team.error)):
			# The respawn a map change now does is the round start's, so it has to
			# honour the sides the new mode just assigned: a side's spawn tag, or an
			# untagged point both may use.
			var wrong_side := PackedStringArray()

			for player in _game.players():
				var nearest := _nearest_spawn(_game.map, player.controller.state.position)
				var tag := _game.map.spawn_tag(int(nearest[0]))
				var wanted := _spawn_tag_of_team(_game.team_of(player.player_id))

				if float(nearest[1]) > 0.5 or (tag != &"" and tag != wanted):
					wrong_side.append("%d (%s) at a %s spawn, %.1f m" % [
						player.player_id, String(wanted), String(tag), float(nearest[1])
					])

			_check(
				wrong_side.is_empty(),
				"and the change puts each side at its own spawns",
				", ".join(wrong_side)
			)

			director.restrict_rotation()

			_check(
				not director.session.rotation.order.has(&"dm_pit"),
				"the rotation stops offering dm_pit while a team mode is played",
				str(director.session.rotation.order)
			)
			_check(
				director.session.rotation.order.has(&"dm_box")
					and director.session.rotation.order.has(&"dm_atrium"),
				"and still offers the two that can host it"
			)

			# Asked for by name, which is what an admin typing `changelevel` does and what a
			# rotation cannot be made to stop doing.
			var refused: DotResult = await director.change_to(&"dm_pit")

			_check(
				not refused.ok,
				"and changing to it by name is refused outright"
			)
			_check(
				_game.map.id != &"dm_pit",
				"with the game left on the map it was on",
				String(_game.map.id)
			)

			var back := _game.change_map(
				FcMap.by_id(_game.map.id), FcMode.free_for_all()
			)

			if _check(back.ok, "the game goes back to a free-for-all", str(back.error)):
				director.restrict_rotation()

				_check(
					director.session.rotation.order.has(&"dm_pit"),
					"and dm_pit is offered again",
					str(director.session.rotation.order)
				)

	director.queue_free()
	remove_child(director)
	_done()

## The two-metre box [method _test_map_change] builds on top of a player.
func _trap_at(standing: Vector3) -> AABB:
	return AABB(standing + Vector3(-1.0, -0.05, -1.0), Vector3(2.0, 2.4, 2.0))

## The first patch of bare floor, scanning in a fixed order, where a trap box would
## touch no other box and would sit at least four metres from every spawn — so the only
## way a player ends up inside it is by having been left there.
func _open_floor_away_from_spawns(map: FcMap) -> Variant:
	var reach := int(map.extent) - 3

	for x in range(-reach, reach + 1, 2):
		for z in range(-reach, reach + 1, 2):
			var at := Vector3(float(x), map.floor_y + 0.05, float(z))
			var trap := _trap_at(at)
			var clear := true

			for box in map.boxes:
				# The floor itself is the one box a trap stands on rather than in.
				if box.end.y <= map.floor_y + 0.01:
					continue

				if box.intersects(trap.grow(0.5)):
					clear = false
					break

			if not clear:
				continue

			if float(_nearest_spawn(map, at)[1]) < 4.0:
				continue

			return at

	return null

## Every player whose body is inside a box of [param map], by id. Two points up the
## body rather than the feet, because a player standing ON a box has their feet on its
## top face and is exactly where they should be.
func _players_inside_boxes(map: FcMap) -> Array[int]:
	var out: Array[int] = []

	for player in _game.players():
		var feet := player.controller.state.position

		for box in map.boxes:
			var solid := box.grow(-0.05)

			if solid.has_point(feet + Vector3.UP * 0.3) or solid.has_point(feet + Vector3.UP * 1.2):
				out.append(player.player_id)
				break

	return out

# --- Lag compensation and stance ---------------------------------------------

## A rewound shot meets the stance the shooter drew, not the server's present one: B crouched (or stood up) after the
## tick A saw, and the rewind used to move B's feet back but leave the hit zones at today's height, so a shot at the drawn
## standing head flew over the crouched zones, and one at the drawn crouched head met a standing chest (nightly
## bot-crouch-rewind-60m-1; footage 2026-11-15).
func _test_lag_compensation_stance() -> void:
	_section("lag compensation carries the crouch")
	var game := _weapon_mode_game(FcMode.free_for_all(25), [942, 943])
	if not _check(game != null, "a two-player game sets up"):
		return
	for _i in range(6):
		await get_tree().process_frame
	for id in [942, 943]:
		game.combat.health_of(id).invulnerable_until_tick = -1
	# Settled on the floor first, so the held spots do not fall: a fall would move the head by more than the crouch.
	_stand(game, 942, Vector3(0.0, game.player_for(942).controller.state.position.y, 0.0))
	_stand(game, 943, Vector3(0.0, game.player_for(942).controller.state.position.y, -8.0))
	for _k in range(30):
		game.tick({})
	var standing := _stance_hold(game, false, 20)
	var crouched := _stance_hold(game, true, 40)
	_check(game.player_for(943).controller.state.crouch_fraction > 0.99, "B crouches in place")
	var group: StringName = _stance_shot(game, standing)
	_check(group == DotHitGroup.HEAD, "a shot at B's drawn standing head, rewound to then, is a headshot",
		"met %s" % [group if group != &"" else &"nothing"])
	_check(absf(_stance_head(game).y - (crouched[1] as Vector3).y) < 0.01, "and B's zones are put back at the crouch",
		"head %.3f, crouched %.3f" % [_stance_head(game).y, (crouched[1] as Vector3).y])
	var _up := _stance_hold(game, false, 40)
	group = _stance_shot(game, crouched)
	_check(group == DotHitGroup.HEAD, "a shot at B's drawn crouched head, B standing since, is a headshot",
		"met %s" % [group if group != &"" else &"nothing"])
	_check(absf(_stance_head(game).y - (standing[1] as Vector3).y) < 0.01, "and B's zones are put back standing",
		"head %.3f, standing %.3f" % [_stance_head(game).y, (standing[1] as Vector3).y])
	var b := game.player_for(943)
	_check(b.global_position.distance_to(b.controller.state.position) < 0.01, "and B's feet where the server has them",
		"%s against %s" % [b.global_position, b.controller.state.position])
	remove_child(game)
	game.queue_free()
	_done()

## B held crouched (or not) eight metres in front of A for [param ticks]: `[the tick, B's head zone centre]` at the end.
func _stance_hold(game: FcGame, crouch: bool, ticks: int) -> Array:
	var a_at := game.player_for(942).controller.state.position
	var b_at := game.player_for(943).controller.state.position
	for _k in range(ticks):
		for id: int in [942, 943]:
			_stand(game, id, a_at if id == 942 else b_at)
			game.player_for(id).controller.state.velocity = Vector3.ZERO
		var move := DotFpsCommand.new()
		move.buttons = DotFpsCommand.BUTTON_CROUCH if crouch else 0
		game.tick({943: [move, DotWeaponCommand.new()]})
	return [game.current_tick(), _stance_head(game)]

func _stance_head(game: FcGame) -> Vector3:
	for box: DotHitbox in game.player_for(943).hitboxes.hitboxes():
		if box.group == DotHitGroup.HEAD:
			return box.global_position
	return Vector3.INF

## A's rifle at where [param seen] drew B's head, rewound to that tick: the zone group it met on B, or empty.
func _stance_shot(game: FcGame, seen: Array) -> StringName:
	var shot := DotShot.make(&"rifle", 942, game.current_tick(), 0)
	shot.origin = game.player_for(942).global_position + Vector3.UP * 1.5
	var aim: Vector3 = (seen[1] as Vector3) - shot.origin
	shot.pellets = [aim.normalized()] as Array[Vector3]
	shot.direction = aim.normalized()
	shot.damage = 1.0
	shot.damage_type = game.combat.damage_type(&"bullet")
	shot.max_range = 100.0
	game._unlag_shooter = 942
	var _r := game.combat.resolve_shot(shot, float(seen[0]))
	for d: DotDamage in shot.damages:
		if d.victim == 943:
			return d.hit_group
	return &""
