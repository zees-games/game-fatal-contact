extends Node



const FcPlayer := preload("fc_player.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")
const FcBspMap := preload("../maps/fc_bsp_map.gd")
const FcSpawnDirector := preload("fc_spawn_director.gd")
const FcSpawnPick := preload("fc_spawn_pick.gd")

## The player-facing addons, stood up once and bound to the game. Seven addons that each know
## nothing about Fatal Contact, met here: session roster, sides, classes, spawns and physics settings.


## Typed as its native base on purpose: a typed reference back to fc_game.gd closes a
## preload cycle, and GDScript never frees the parser trees of scripts in a cycle (CI perf-smoke mem_mb).
var game: Node = null


var physics: GSPhysicsWorld = null
var roster: GSPlayerRoster = null
var teams: GSTeamRoster = null
var spawns: GSSpawnDirector = null
## [method _can_see_site]'s answers this tick, keyed by [code][from, to][/code], and the tick.
var _seen := {}
var _seen_tick := -1


## The gs-team side for one of gs-match's team ids. [b]An id, not an index[/b]: gs-match's `standard_pair()` is Red `1` and Blue `2`, a spectator team `31`; treating `team_of()`'s answer as a position would put team 1 on gs-team's first side by luck and a spectator nowhere.
## So the id is looked up in the match's own ordered team list and the POSITION crosses over: the nth playing side there is the nth playing side here.
func _side_of_id(team_id: int) -> StringName:
	if game.match_node.teams == null or team_id <= 0:
		return &""

	var playing := teams.teams.playing_ids()
	var listed: Array[GSTeam] = game.teams()

	for i in range(listed.size()):
		if listed[i] != null and listed[i].id == team_id:
			return playing[i] if i < playing.size() else &""

	return &""


## The roster side whose match team claims a spawn point with one of [param tags], or
## empty for a point any side may use — which is every point outside a team mode.
func _side_of_tags(tags: Array[StringName]) -> StringName:
	if tags.is_empty():
		return &""

	for team in game.teams():
		if team != null and team.spawn_tag != &"" and tags.has(team.spawn_tag):
			return _side_of_id(team.id)

	return &""


func _alive_of_key(key: String) -> bool:
	var player: FcPlayer = game.player_for(int(key))
	return player != null and player.is_alive()


func _joined_tick_of_key(key: String) -> int:
	var record := roster.get_record(key)
	return record.joined_tick if record != null else 0


func _score_of_key(key: String) -> float:
	var score: GSPlayerScore = game.match_node.scoreboard.find(key)
	return float(score.score) if score != null else 0.0


## Where a player's EYES are, which is not where their feet are. gs-spectate's documentation is explicit: a chase camera derived from a capsule's origin sits in the floor and a first-person one is at the knees.
## The controller answers it, because it knows the eye height and the pitch.
func _pose_of_key(key: String) -> Transform3D:
	var player: FcPlayer = game.player_for(int(key))

	if player == null or player.controller == null:
		return Transform3D.IDENTITY

	return player.controller.eye_transform()


## Everybody alive who is an enemy of the spawning player: in a free-for-all everybody but them, in a team mode the other sides.
## The spawning player is never their own enemy: one respawned while alive (a map change, an admin) stood on the site being scored and scored it as the most dangerous place on the map.
func _enemy_positions(team: StringName, key: String = "") -> Array:
	var out: Array = []
	# The MODE says whether there are sides, not gs-match's team manager: that exists in a free-for-all too, and the roster keeps whatever side a team mode left everybody on,
	# which told a free-for-all respawner its old team-mates were friends.
	var sided: bool = game.mode != null and game.mode.is_team_mode() and team != &""

	for player in game.players():
		if not player.is_alive() or player.controller == null or str(player.player_id) == key:
			continue

		if sided and teams != null and teams.team_of(str(player.player_id)) == team:
			continue

		out.append(player.controller.state.position)

	return out


## The spawning player's side, alive, in a team mode; nobody in a free-for-all.
func _friend_positions(team: StringName, key: String = "") -> Array:
	var out: Array = []

	if game.mode == null or not game.mode.is_team_mode() or team == &"" or teams == null:
		return out

	for player in game.players():
		if player.is_alive() and player.controller != null and str(player.player_id) != key \
				and teams.team_of(str(player.player_id)) == team:
			out.append(player.controller.state.position)

	return out


## Whether an enemy at [param from] can see a site (eye height to head height) [b]through the map's own trace, the one shots use[/b]: a headless game's physics space holds no built-in map.
## Props are not in the trace (not cover a spawn should count on); the physics query is the fallback for a game with no combat yet.
## Answers are kept for the tick: a round start respawns everybody at once and the map and players do not move inside a tick.
func _can_see_site(from: Vector3, to: Vector3) -> bool:
	var tick: int = game.current_tick() if game != null else -1
	if tick != _seen_tick or tick < 0:
		_seen_tick = tick
		_seen.clear()
	var key := [from, to]
	var known: Variant = _seen.get(key)
	if known != null:
		return bool(known)
	var t_lap := FcFrameProbe.lap_start()
	var sees := _traced_sight(from, to)
	FcFrameProbe.lap(&"sp_see", t_lap)
	_seen[key] = sees
	return sees


## Whether any of [param enemies] can see a site at [param at]: [method _can_see_site]'s answer for each, the same
## memo, but on a flat trace every pair not yet known this tick asked in one native call (`world_rays_raw`). Any other
## trace (an imported map's brushes) asks pair by pair and stops at the first enemy that sees: tracing them all cost 4x.
func _site_seen_by_any(at: Vector3, enemies: Array) -> bool:
	if not (game != null and game.combat != null and game.combat.trace is GSTraceFlat):
		for e: Variant in enemies:
			if _can_see_site(e as Vector3, at):
				return true
		return false
	var tick: int = game.current_tick() if game != null else -1
	if tick != _seen_tick or tick < 0:
		_seen_tick = tick
		_seen.clear()
	var unknown: Array[Vector3] = []
	for e: Variant in enemies:
		var known: Variant = _seen.get([e, at])
		if known == null:
			unknown.append(e as Vector3)
		elif bool(known):
			return true
	if unknown.is_empty():
		return false
	var t_lap := FcFrameProbe.lap_start()
	var seen := _traced_sights(unknown, at)
	FcFrameProbe.lap(&"sp_see", t_lap)
	var any := false
	for k in unknown.size():
		_seen[[unknown[k], at]] = seen[k] != 0
		any = any or seen[k] != 0
	return any


## [method _traced_sight] from each of [param froms] to [param to] (1 seen, 0 not), in one call on a native flat trace.
## The same rays as its `line_of_sight`: the end 5 cm short, the direction and length taken the same way, and a world
## ray that met nothing (neither the ground nor a box) is a clear sight.
func _traced_sights(froms: Array[Vector3], to: Vector3) -> PackedByteArray:
	var n := froms.size()
	var out := PackedByteArray()
	out.resize(n)
	var trace: GSTrace = game.combat.trace if game != null and game.combat != null else null
	if trace is GSTraceFlat:
		var head := to + Vector3(0, FcPlayer.eye_height(), 0)
		var eyes := PackedVector3Array()
		var dirs := PackedVector3Array()
		var limits := PackedFloat64Array()
		var ray_of := PackedInt32Array()
		ray_of.resize(n)
		for k in n:
			var eye := froms[k] + Vector3(0, FcPlayer.eye_height(), 0)
			var span := head - eye
			var length := span.length()
			ray_of[k] = -1
			out[k] = 1
			if length <= 0.05:
				continue
			var offset := (eye + span * ((length - 0.05) / length)) - eye
			var distance := offset.length()
			if distance <= 0.0001:
				continue
			ray_of[k] = eyes.size()
			eyes.append(eye)
			dirs.append(offset / distance)
			limits.append(distance)
		if eyes.is_empty():
			return out
		var raw: Dictionary = (trace as GSTraceFlat).world_rays_raw(eyes, dirs, limits)
		if not raw.is_empty():
			var kind: PackedByteArray = raw["kind"]
			for k in n:
				if ray_of[k] >= 0:
					out[k] = 1 if kind[ray_of[k]] == 0 else 0
			return out
	for k in n:
		out[k] = 1 if _traced_sight(froms[k], to) else 0
	return out


func _traced_sight(from: Vector3, to: Vector3) -> bool:
	var eye := from + Vector3(0, FcPlayer.eye_height(), 0)
	var head := to + Vector3(0, FcPlayer.eye_height(), 0)
	var trace: GSTrace = game.combat.trace if game != null and game.combat != null else null

	if trace != null:
		var span := head - eye
		var length := span.length()
		if length <= 0.05:
			return true
		# A flat trace's line_of_sight is the same world ray, native and with no hit built; shortened by the 5 cm a hit at the very end was always forgiven.
		# Not the physics trace's: FcGlassTrace's sight query lets the jail glass through, which ray() does not, and spawns have always used ray().
		if trace is GSTraceFlat:
			return trace.line_of_sight(eye, eye + span * ((length - 0.05) / length))
		var hit := trace.ray(eye, span / length, length)
		return not hit.ok() or hit.distance >= length - 0.05

	if physics == null or not is_inside_tree():
		return false

	return physics.query().line_of_sight_3d(get_viewport().find_world_3d(), eye, head)


## Puts [param node] on the layout's [param layer_id] layer, with that layer's mask.
func classify(node: Node, layer_id: StringName) -> GSResult:
	if physics == null or physics.layout == null:
		return GSResult.fail(GSError.CODE_STATE, "No collision layout.")

	return physics.classify(node, layer_id)


## Puts every collision object under [param root] on [param layer_id]: one call for a level, so
## `FcMap` keeps physics decisions out of its box list. Non-collision nodes are skipped.
## Returns how many were classified.
func classify_tree(root: Node, layer_id: StringName) -> int:
	if root == null or physics == null or physics.layout == null:
		return 0

	var done := 0

	# Importer hull bodies (clip, fence, glass) and the sky mark keep their layers, or shots and sight could not tell them from a wall.
	if GSMapGlassSight.is_exempt(root) or root.is_in_group(FcBspMap.SKY_GROUP):
		return 0

	if root is CollisionObject3D or root is CollisionObject2D:
		if classify(root, layer_id).ok:
			done += 1

	for child in root.get_children():
		done += classify_tree(child, layer_id)

	return done


## Spawn sites closer than this to a living player count as occupied, in metres.
const SPAWN_OCCUPIED_RADIUS := 1.5


## Tells gs-spawn who stands on which site; only needed for the strict `one_per_spawn` rule, which refuses an occupied site. The spawning player does not occupy a site against themselves.
func _push_spawn_occupancy(director: GSSpawnDirector, except_key: String) -> void:
	var t_lap := FcFrameProbe.lap_start()
	var standing: Array[Vector3] = []

	for player in game.players():
		if player.is_alive() and player.controller != null and str(player.player_id) != except_key:
			standing.append(player.controller.state.position)

	# Written onto the sites, not through `set_occupancy`: that walks every site to find the id, so pushing all of them was sites squared
	# id compares a spawn (32 sites, 32 spawns at a round start: 32k a tick). Same result: a shared id gets the count of its last site, as the last call gave it.
	var sites := director.sites()
	var by_id := {}
	var counts := PackedInt32Array()

	if FcSpawnPick.native and FcSpawnPick.has_kernel():
		var site_at := PackedVector3Array()
		site_at.resize(sites.size())
		for i in sites.size():
			site_at[i] = sites[i].position
		counts = FcSpawnPick.occupancy(site_at, PackedVector3Array(standing), SPAWN_OCCUPIED_RADIUS)

	for i in sites.size():
		var site: GSSpawnSite = sites[i]
		var count := 0

		if counts.size() == sites.size():
			count = counts[i]
		else:
			for at in standing:
				if at.distance_to(site.position) <= SPAWN_OCCUPIED_RADIUS:
					count += 1

		by_id[site.id] = count

	for site in sites:
		site.occupants = maxi(0, by_id[site.id])
	FcFrameProbe.lap(&"sp_occupancy", t_lap)
