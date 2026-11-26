extends "fc_map_imported.gd"

const FcLoadTimeline := preload("../game/fc_load_timeline.gd")
const FcFrameProbe := preload("../game/fc_frame_probe.gd")

## One box as a static body, with a mesh when there is a material to draw it with.
##
## A null material means collision only. Not a separate function, because two functions
## that each build a box out of one [AABB] is two descriptions of a box — which is the
## exact drift this class exists to prevent, one level down.
static func _make_box(box: AABB, material: Material, node_name: String, bake_floor_y: float = INF) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.position = box.position + box.size * 0.5

	if material != null:
		var mesh := MeshInstance3D.new()
		mesh.name = "Mesh"

		if bake_floor_y != INF:
			mesh.mesh = lightmap_box(box.size, box.position.y <= bake_floor_y + 0.01)
		else:
			var box_mesh := BoxMesh.new()
			box_mesh.size = box.size
			mesh.mesh = box_mesh

		mesh.material_override = material
		body.add_child(mesh)

	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = box.size
	shape.shape = box_shape
	body.add_child(shape)

	return body

## The visible and collidable level, for a client or a listen server.
##
## Returns a [Node3D] holding one [StaticBody3D] per box plus a floor. Built rather
## than loaded from a scene so that the geometry cannot drift from
## [method to_fps_body] and [method to_trace] — which is the whole point of the class.
func to_scene() -> Node3D:
	if is_imported():
		# The drawn map only. Its solid is the game's (see [method movement_body]), so a
		# client that drew colliders here as well would have two of every brush.
		var dir := manifest_path.get_base_dir()
		# A world replaces every legacy mesh, so building them first only to free them
		# was most of a multi-second frame on the biggest maps.
		if use_worlds or local_prefix != "":
			var bare := Node3D.new()
			bare.name = "Level"
			if FcBspMap.draw_world(bare, String(id), dir):
				return bare
			bare.free()
		if local_prefix != "":
			# A local copy has no legacy meshes to fall back on; its solid still plays.
			var empty := Node3D.new()
			empty.name = "Level"
			return empty
		var drawn := FcBspMap.build_visual(FcImportedMaps.manifest(id), dir)
		drawn.name = "Level"
		return drawn

	var root := Node3D.new()
	root.name = "Level"
	var bake_floor := floor_y if can_bake() else INF

	# Colour by role and zone, worked out from the box list and never stored in it: see
	# `fc_map_paint.gd`.
	var painter := FcMapPaint.Painter.new()

	root.add_child(_level_floor(painter, bake_floor))
	for index in range(boxes.size()):
		root.add_child(_level_box(painter, index, bake_floor))

	_add_contact_shade(root)

	if bake_floor != INF and use_bakes:
		_attach_bake(root)

	return root

func _level_floor(painter: FcMapPaint.Painter, bake_floor: float) -> StaticBody3D:
	return _make_box(
		AABB(
			Vector3(-extent - 2.0, floor_y - 1.0, -extent - 2.0),
			Vector3(extent * 2.0 + 4.0, 1.0, extent * 2.0 + 4.0)
		),
		painter.photo_ground(),
		"Floor",
		bake_floor
	)

func _level_box(painter: FcMapPaint.Painter, index: int, bake_floor: float) -> StaticBody3D:
	return _make_box(
		boxes[index],
		painter.role_box(FcMapPaint.role_of(boxes[index], extent), FcMapPaint.colour_of(self, index)),
		"Box%02d" % index,
		bake_floor
	)

## [method to_scene] built in slices behind a loading cover. A headless process keeps the one-shot build.
func to_scene_async(slice: GSFrameSlice) -> Node3D:
	if is_imported():
		if use_worlds or local_prefix != "":
			var bare := Node3D.new()
			bare.name = "Level"
			if await FcBspMap.draw_world_async(bare, String(id), manifest_path.get_base_dir(), slice):
				return bare
			bare.free()
		return to_scene()
	if GSPlatform.is_headless():
		return to_scene()

	# The photographs and the bake read on loader threads first: read in-frame, they were
	# most of a 420 ms startup frame on the bench. Held here so the Painter's load() hits the cache.
	var bake_floor := floor_y if can_bake() else INF
	var paths := FcMapPaint.texture_paths()
	if bake_floor != INF and use_bakes:
		paths.append(FcPaths.rebase(BAKE_PATH % id))
	var held := await _read_threaded(paths, slice)
	FcLoadTimeline.mark("level: %d textures read" % held.size())

	var root := Node3D.new()
	root.name = "Level"
	var painter := FcMapPaint.Painter.new()
	root.add_child(_level_floor(painter, bake_floor))
	for index in range(boxes.size()):
		if slice.due():
			await slice.pause()
		root.add_child(_level_box(painter, index, bake_floor))
	FcLoadTimeline.mark("level: boxes built")

	await slice.pause()
	_add_contact_shade(root)
	if bake_floor != INF and use_bakes:
		await slice.pause()
		_attach_bake(root)
	FcLoadTimeline.mark("level: bake attached")
	held.clear()
	return root

## Reads [param paths] on loader threads, a frame at a time, and returns what loaded. Missing paths are skipped.
## Nothing where loader threads do not run beside the frame ([method FcFrameProbe.loader_threads_usable]:
## not on the threaded web engine either), so the Painter reads them inline as on the single-threaded build.
static func _read_threaded(paths: PackedStringArray, slice: GSFrameSlice) -> Array[Resource]:
	var held: Array[Resource] = []
	if not FcFrameProbe.loader_threads_usable():
		return held
	var asked: PackedStringArray = []
	for path in paths:
		if ResourceLoader.exists(path) and ResourceLoader.load_threaded_request(path) == OK:
			asked.append(path)
	for path in asked:
		while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await slice.pause()
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			var got := ResourceLoader.load_threaded_get(path)
			if got != null:
				held.append(got)
	return held

## The level as collision only: static bodies, no meshes, no material.
##
## [b]This exists for one reason, and it is gs-props.[/b] Everything else in this game
## is analytic — the player's movement, the shot tracing, the navigation — precisely so
## a headless server needs no physics space. A physics prop is the exception: a rigid
## body has to have something to land on, and on a dedicated server nothing has ever
## instantiated the level, because there is nothing to draw it to.
##
## So this is [method to_scene] with the meshes left out. Same boxes, same list, same
## invariant — a fourth representation generated from the one description rather than a
## fifth one written by hand.
##
## [b]A client should NOT add this as well as [method to_scene].[/b] Two sets of static
## bodies in one space is every prop resting on whichever the solver reached first, and
## a shot that stops at a wall the player can walk through. [FcProps] builds one or
## the other, never both.
func to_collision() -> Node3D:
	if is_imported():
		if prebuilt_collision != null:
			var built := prebuilt_collision
			prebuilt_collision = null
			if is_instance_valid(built):
				return built
		if local_prefix != "":
			return FcLocalMaps.build_collision(local_prefix)
		return FcBspMap.build_collision(
			FcImportedMaps.manifest(id), manifest_path.get_base_dir()
		)

	var root := Node3D.new()
	root.name = "Collision"

	root.add_child(_make_box(
		AABB(
			Vector3(-extent - 2.0, floor_y - 1.0, -extent - 2.0),
			Vector3(extent * 2.0 + 4.0, 1.0, extent * 2.0 + 4.0)
		),
		null,
		"Floor"
	))

	for index in range(boxes.size()):
		root.add_child(_make_box(boxes[index], null, "Box%02d" % index))

	return root

## Builds an imported map's solid in slices for the next [method to_collision], so a client changing map does
## not build it in the frame that swaps the world. Other maps are a few boxes and keep the one-shot build.
func to_collision_async(slice: GSFrameSlice) -> void:
	if not is_imported() or local_prefix != "" or prebuilt_collision != null:
		return
	prebuilt_collision = await FcBspMap.build_collision_async(
		FcImportedMaps.manifest(id), manifest_path.get_base_dir(), slice
	)

## Frees a [member prebuilt_collision] nothing took.
func drop_prebuilt_collision() -> void:
	if prebuilt_collision != null and is_instance_valid(prebuilt_collision) and not prebuilt_collision.is_inside_tree():
		prebuilt_collision.free()
	prebuilt_collision = null

# --- Dev texture -----------------------------------------------------------

## A grid texture, generated rather than shipped.
##
## What an imported map draws on a surface whose texture it did not carry
## (`fc_bsp_map.gd`). The built-in maps wear Kenney's prototype grid instead, tinted per
## zone (`fc_map_paint.gd`); a grid either way, because a grid makes distance and scale
## readable, which is the entire function a dev texture performs.
static func dev_texture(
	size: int = 128,
	line_every: int = 32,
	base: Color = Color(0.32, 0.34, 0.38),
	line: Color = Color(0.20, 0.21, 0.24)
) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	image.fill(base)

	for x in range(size):
		for y in range(size):
			if x % line_every == 0 or y % line_every == 0:
				image.set_pixel(x, y, line)
			elif (x % line_every == 1) or (y % line_every == 1):
				image.set_pixel(x, y, line.lerp(base, 0.5))

	return ImageTexture.create_from_image(image)

func describe() -> Dictionary:
	var out := {
		"name": display_name,
		"boxes": boxes.size(),
		"spawns": spawns.size(),
		"tagged_spawns": spawn_tags.size() - Array(spawn_tags).count(""),
		"extent": extent,
	}

	if is_imported():
		out["imported"] = manifest_path
		out["movement"] = String(movement_profile)
		out["pits"] = pits.size()
		out["author"] = author

		if mechanics != null:
			out["mechanics"] = mechanics.describe_lines()[0]

	return out
