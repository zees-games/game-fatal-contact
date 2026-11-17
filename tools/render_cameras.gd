extends DotCameraTool

## Fatal Contact's cameras against its real maps: the third-person view, and the spectator's
## chase camera (the one the play test found inside a wall). See dot-core's DotCameraTool.
##
##   tools/render_cameras.sh [map]        # dm_box by default; frames in screenshots/cameras/
##   godot --headless --path . --script tools/render_cameras.gd -- --no-render --map dm_atrium

const FcMap := preload("../maps/fc_map.gd")
const FcMapLighting := preload("../maps/fc_map_lighting.gd")
const FcBspMap := preload("../maps/fc_bsp_map.gd")
const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcPlayer := preload("../game/fc_player.gd")

var _map: FcMap = null


func _map_now() -> FcMap:
	if _map == null:
		var args := OS.get_cmdline_user_args()
		var at := args.find("--map")
		_map = FcMap.by_id(StringName(args[at + 1]) if at >= 0 and at + 1 < args.size() else &"dm_box")
		_name = "arena_%s" % String(_map.id)
	return _map


func _build_level() -> Node3D:
	var level := _map_now().to_scene()

	# An imported map's to_scene() is the drawn world only (its solid is the game's, see FcMap.movement_body), so the cameras flew through every wall and the check read
	# "unprotected camera in or behind the level on 0 frames" as an unarmed FAIL. Give the level the convex-hull solid the game collides with.
	if _map_now().is_imported():
		var manifest := FcImportedMaps.manifest(_map_now().id)
		var solid := FcBspMap.build_collision(manifest, _map_now().manifest_path.get_base_dir())
		level.add_child(solid)
		_map_now().collision_root = solid

	return level


func _build_lighting() -> Node3D:
	return FcMapLighting.build(_map_now())


func _pivots() -> Array[Vector3]:
	var out: Array[Vector3] = []
	# From where the game spawns somebody: a mapper's spawn can sit in a stair or a slab, and the
	# game lifts it clear at load (FcGame, `settle_spawns`). Flying from the raw point puts the
	# camera's pivot, the player's eye, inside solid, which no camera can answer for.
	if _map_now().is_imported():
		var _lifted := _map_now().settle_spawns(_map_now().movement_body(), FcPlayer.fc_tunables())
	var space := root.get_world_3d().direct_space_state
	var skipped := 0
	for spawn in _map_now().spawns:
		var eye: Vector3 = spawn.origin + Vector3.UP * FcPlayer.eye_height()
		# A spawn the game cannot clear (a mapper's spawn in a stair) leaves
		# the eye in solid; DotCameraProbe wants a clear pivot, so that one is not a camera case.
		if DotCameraProbe.is_inside(space, eye, 0.18, _level_mask()):
			skipped += 1
			continue
		out.append(eye)
	if skipped > 0:
		print("camera tool: %d of %d spawns have the eye in solid even after the game's lift; not flown" % [skipped, _map_now().spawns.size()])
	return out


## Fatal Contact's player is 1.37 m tall with its eye at FcPlayer.eye_height() (about 1.2 m), not the
## 1.8 m figure the base tool draws: a spawn under a 1.5 m slab has the game's eye clear and a 1.6 m one inside.
func _eye_height() -> float:
	return FcPlayer.eye_height()


func _offsets() -> Dictionary:
	# The spectator's chase camera is dot-spectate's: 3.5 m behind the eye and 0.9 up (the
	# Fatal Contact's rules), along the watched player's view.
	return {"third_person": FcPlayer.THIRD_PERSON_OFFSET, "chase": Vector3(0.0, 0.9, 3.5)}
