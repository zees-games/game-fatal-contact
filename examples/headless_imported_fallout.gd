extends "headless_imported_rides.gd"

## Set by `-- --fallout=<map id>`: the one map the walk-off check visits.
var _fallout_only := ""

## The imported-map suite's fall-out checks over every map. Split out of headless_imported_worlds.gd for file size.


func _test_fallout_all_part2(sealed: Array[String], report: Array[String], player: FcPlayer) -> void:
	for id in FcMap.imported_ids():
		if _fallout_only != "" and String(id) != _fallout_only:
			continue
		var changed := _game.change_map(FcMap.by_id(id))
		if not changed.ok:
			sealed.append("%s (does not load)" % id)
			continue

		var order: Array[int] = []
		for index in range(_game.map.pits.size()):
			order.append(index)
		order.sort_custom(func(a: int, b: int) -> bool:
			return (_game.map.pits[a]["box"] as AABB).get_volume() > (_game.map.pits[b]["box"] as AABB).get_volume())

		var tried: Array[Vector3] = []
		for index in order:
			if tried.size() >= FALLOUT_PER_MAP:
				break
			var cell: Vector3 = _game.map.pits[index]["to"]
			var fresh := true
			for seen in tried:
				if seen.distance_to(cell) < 1.0:
					fresh = false
			if not fresh:
				continue
			tried.append(cell)

			var best := 0.0
			var best_yaw := 0.0
			var tries: Array[String] = []
			for heading in range(8):
				var yaw := heading * 45.0
				# A respawn, not just a teleport: crouch, modifiers and loadout left by earlier
				# sections change the walking speed and so the reach.
				_game.respawn_player(2)
				player = _game.player_for(2)
				player.controller.teleport(cell, yaw, 0.0)
				_game.tick({})
				var start := player.controller.state.position
				var reach := 0.0
				var lowest := start.y
				for tick in range(int(TICK_RATE * FALLOUT_WALK)):
					var move := DotFpsCommand.new()
					move.yaw = yaw
					move.move = Vector2(0.0, 1.0)
					move.sanitise()
					_game.tick({player.player_id: [move, DotWeaponCommand.new()]})
					var here := player.controller.state.position
					# Only ground counts: a body walked off a ledge keeps its sideways
					# speed through the whole fall, which is not a way out of a cell.
					if player.controller.state.is_grounded():
						reach = maxf(reach, Vector2(here.x - start.x, here.z - start.z).length())
					lowest = minf(lowest, here.y)
					if reach >= FALLOUT_OUT_AT:
						break
				# An edge to walk off is out as well: what a cell has is walls all round and a roof,
				# and a platform open to the sky has a fall, which the map's catch-all makes a
				# drop back into the fight.
				if reach < FALLOUT_OUT_AT and start.y - lowest >= 3.0:
					reach = FALLOUT_OUT_AT
				if reach > best:
					best = reach
					best_yaw = yaw
				tries.append("heading %d: reach %.1f, fell %.1f m, end %s, mode %s" % [heading, reach, start.y - lowest, player.controller.state.position.snapped(Vector3.ONE * 0.1), player.controller.state.mode])
				if best >= FALLOUT_OUT_AT:
					break
			report.append("%s pit %d -> (%.0f, %.0f, %.0f): got %.1f m (yaw %.0f)" % [
				id, index, cell.x, cell.y, cell.z, best, best_yaw])
			if best < FALLOUT_OUT_AT:
				sealed.append("%s pit %d" % [id, index])
				for line in tries:
					_line("       " + line)

	for line in report:
		_line("     " + line)

	_check(sealed.is_empty(), "no destination seals its faller in (%s)" % [sealed])

	_done()
