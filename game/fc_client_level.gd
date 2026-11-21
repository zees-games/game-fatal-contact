extends "fc_client_prewarm.gd"

const FcContentGroups := preload("fc_content_groups.gd")
## Frames a menu map change traces (FcLoadTimeline.trace_frames): its ticks, steps and draws, to the level's first frames.
const CHANGE_TRACE_FRAMES := 40
## Milliseconds of level building between frames while the map loads ([method _enter_level]).
const LEVEL_SLICE_MS := 10
## Most proxies one warm-up round places (each a material and vertex format): [member GSRenderWarmup.batch_size].
const LEVEL_WARM_BATCH := 4
## Milliseconds a round of the new level's warm-up may cost its frame ([method _warm_level]): a map change's bare
## frame is about 18 ms on staging02, so a round leaves room for a compile or two and stays near 33 ms.
const LEVEL_WARM_BUDGET_MSEC := 30.0

## The level half of the client's boot: entering a map, classifying it and warming its shaders in frame-sized slices. Split out of fc_client_hud_and_camera.gd for file size.


## Puts the drawn level on the layout's `world` layer.
func _classify_level() -> void:
	if _level == null or game == null or game.player_stack == null:
		return

	var done := game.player_stack.classify_tree(_level, &"world")
	GSLog.debug(CHANNEL, "level classified", {"bodies": done})


## The world and prop shader warm-up of [method _enter_level]; sets `done` in [param state] when both finished.
func _warm_boot_shaders(state: Dictionary) -> void:
	await GSMapSurfaces.warm_shaders_async(get_tree())
	await GSMapBspMesh.warm_prop_shaders_async(get_tree())
	FcLoadTimeline.mark("world shaders warmed")
	state["done"] = true


## Builds the movers and the drawn level in slices behind the cover, then optionally lifts the map hold.
func _enter_level(release: bool) -> void:
	_level_busy = true
	# 10 ms between yields, not the 40 ms default: the cover is up, but bots and the
	# network keep ticking behind it, and a 40 ms build frame is a hitch they feel.
	var slice := GSFrameSlice.new(LEVEL_SLICE_MS)
	# The converted worlds' and their props' shaders compile under the boot cover, one per frame: compiled at a later map change, the first world material held one frame for 85 ms on staging02 and the first textured prop 89 ms. They run
	# beside the map-io build (their frames are mostly waits on loader threads, ~130 ms of wall time in series) and are joined before the level is drawn.
	var warm := {"done": true}
	if _level == null and not GSPlatform.is_headless():
		warm["done"] = false
		_warm_boot_shaders(warm)
	await game.build_map_io_async(slice)
	FcLoadTimeline.mark("map_io_built")
	while not warm["done"]:
		await get_tree().process_frame
	var drawn := game.map
	var made: Node3D = await game.map.to_scene_async(slice)
	FcLoadTimeline.mark("map_scene_built")
	var lit := false
	if _level != null and is_instance_valid(_level):
		# The new map's sun and sky first: its fog, ambient and shadow mode are part of every pipeline the warm-up compiles,
		# and warmed under the old map's, the level's first frame still compiled 26 on staging02.
		_light()
		lit = true
		# The sky and environment rebuild in a frame of their own, not in the warm-up's first (a 191 ms frame together).
		FcLoadTimeline.mark("level lit")
		await get_tree().process_frame
		await _warm_level(made)
	if _level != null and is_instance_valid(_level):
		remove_child(_level)
		# free(), not queue_free(): a deferred free leaves two levels drawn for a frame.
		_level.free()
	_level = made
	_level_map = drawn
	_classify_level()
	add_child(_level)
	if not lit:
		_light()
	_level_busy = false
	if release:
		gate.release(&"map")


## Draws [param made]'s surfaces once, out of sight in budgeted rounds, before it replaces the shown level. Its first draw compiled every pipeline in one frame (634 ms with a cold shader cache on staging02, 18 ms warm), under a cover
## but with the match ticking behind it. Meshes only: each is drawn as one triangle per (material, vertex format), the variants the level's draw uses; a material alone would be drawn on a quad, a format the level never has.
func _warm_level(made: Node3D) -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null or GSPlatform.is_headless():
		return
	var meshes: Array = []
	for item: Variant in GSRenderWarmup.collect(made):
		if item is Mesh:
			meshes.append(item)
	var warm := GSRenderWarmup.new()
	warm.name = "LevelWarmup"
	warm.budget_msec = LEVEL_WARM_BUDGET_MSEC
	# Few per round: a round's first draw also uploads its props' textures, and the warm-up's first 16 were 34 pipelines
	# and +39 MB in one 191 ms frame on staging02.
	warm.batch_size = LEVEL_WARM_BATCH
	# The camera is often under a frozen body, and a disabled warm-up never times out.
	warm.process_mode = Node.PROCESS_MODE_ALWAYS
	warm.add_items(meshes)
	var done := [false]
	var _c := warm.finished.connect(func(_count: int) -> void: done[0] = true)
	cam.add_child(warm)
	warm.start()
	FcLoadTimeline.mark("level warm-up: %d meshes" % meshes.size())
	# Polled, not awaited on the signal: a camera freed mid-warm-up takes the warm-up with it, and finished never comes.
	while not done[0] and is_instance_valid(warm):
		await get_tree().process_frame
	FcLoadTimeline.mark("level warmed")


## The world was replaced under this client.
func _on_map_changed(map: GSMapDef) -> void:
	# Cover and stop the frozen body until the new level is in (released below).
	gate.hold(&"map", "Loading the map")
	if _trace_hosted_change:
		_trace_hosted_change = false
		var timeline := get_node_or_null(^"LoadTimeline") as FcLoadTimeline
		if timeline != null:
			timeline.trace_frames(CHANGE_TRACE_FRAMES)
	while _level_busy:
		await get_tree().process_frame
	# The new map's own files (its bake, its rides) are a download group of their own; fetch them first.
	var _topped: GSResult = await FcContentGroups.top_up(map.id)
	FcLoadTimeline.mark("change: groups topped up")
	# **The client has to ADOPT the map it was handed, and this is where that was missing.**
	# `FcGame.map` is assigned in exactly three places — `setup`, the module's mode change, and
	# `change_map` — and every one of them runs on the SERVER.
	var adopted := (
		game.map if game.map != null and game.map.id == map.id else FcMap.by_id(map.id)
	)

	if adopted != null:
		game.map = adopted
		# **And every player already here moves with it**.
		for player in game.players():
			if player != null and player.map_in_hand() != adopted:
				player.apply_map_movement(game.map_movement())
				player.rebind_map(adopted)
	else:
		# A delivered map this build has no geometry for. The level cannot be drawn,
		# and drawing the OLD one is what this whole comment is about — so say so
		# rather than silently showing a world that is not there.
		GSLog.warn(CHANNEL, "the announced map has no local geometry", {
			"map": String(map.id),
		})

	if _level_map != null and _level_map == game.map:
		# The game was not rebuilt (FcMapSession: the client was set up on this map; a rebuild makes a
		# new FcMap), so the drawn level and the drop pool are still this map's. A map with no movers has no map_io.
		gate.release(&"map")
	else:
		# The rebuilt game's drop layer is empty; fill it before the cover lifts (the hold must precede the map's release).
		_repool_drops()
		FcLoadTimeline.mark("change: repool armed")
		await _enter_level(true)

	# A mirroring client's combat manager is never rebuilt — `change_map` is the server's —
	# and its trace is what the copies of every rocket and grenade bounce off. Left alone,
	# a grenade on the new map bounces off the walls of the old one.
	if not _offline and game.combat != null:
		game.combat.trace = game.map.shot_trace()
	if game.projectiles != null:
		game.projectiles.clear()
	if ragdolls != null:
		# A body lying on the old map's floor would hang in the new one's air.
		ragdolls.clear()

	if presentation != null:
		# Everything drawn for the old map is meaningless now -- a decal is a hole in a
		# wall that no longer exists, and a decal ring that survives a map change is one
		# that survives the map it was about.
		presentation.on_map_changed(game.map.id if game.map != null else &"")

	if hud != null:
		# An imported map is somebody else's work, and its author is named where it starts.
		var by := (
			", by %s" % game.map.author
			if game.map != null and game.map.is_imported() and game.map.author != "" else ""
		)
		hud.notice("Now playing %s%s." % [map.name_or_id(), by])
