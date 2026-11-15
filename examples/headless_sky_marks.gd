extends DotGameCheckSuite

const ArenaBspMap := preload("../maps/arena_bsp_map.gd")
const ArenaPresentationB1 := preload("../game/arena_presentation_b1.gd")

const EXPECTED_CHECKS := 14

## A shot that ends on a sky-marked brush draws no hole: the sky brush is a body (it stops the shot) with an Area3D copy in
## ArenaBspMap.SKY_GROUP, and `on_sky` / `without_sky` read that area. Built by hand, so it needs no map pack.


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


func _run() -> void:
	print("arena - sky marks: no decal on sky brushes")
	var root := Node3D.new()
	add_child(root)
	# A wall at x = 10 (solid, ordinary) and a sky slab at z = -10; the slab is also a body, so shots stop on it.
	var wall := StaticBody3D.new()
	var wall_shape := CollisionShape3D.new()
	wall_shape.shape = _box_shape(Vector3(1, 20, 20))
	wall.add_child(wall_shape)
	wall.position = Vector3(10.5, 0, 0)
	root.add_child(wall)
	var sky_body := StaticBody3D.new()
	var sky_body_shape := CollisionShape3D.new()
	sky_body_shape.shape = _box_shape(Vector3(40, 40, 1))
	sky_body.add_child(sky_body_shape)
	sky_body.position = Vector3(0, 0, -10.5)
	root.add_child(sky_body)
	var sky := Area3D.new()
	sky.collision_layer = ArenaBspMap.SKY_BIT
	sky.collision_mask = 0
	sky.add_to_group(ArenaBspMap.SKY_GROUP)
	var sky_shape := CollisionShape3D.new()
	sky_shape.shape = _box_shape(Vector3(40, 40, 1))
	sky.add_child(sky_shape)
	sky.position = Vector3(0, 0, -10.5)
	root.add_child(sky)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := root.get_world_3d().direct_space_state

	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3(0, 0, -30)))
	_check(not hit.is_empty() and hit.collider == sky_body, "a shot at the sky slab still stops on its body")
	var end: Vector3 = hit.position
	_check(ArenaBspMap.on_sky(space, end, Vector3.FORWARD), "its end reads as sky")
	# A grazing shot (almost along the face) still reads as sky.
	var graze_dir := Vector3(1, 0, -0.02).normalized()
	var graze := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(-19, 0, -9.9), Vector3(-19, 0, -9.9) + graze_dir * 80.0, 0xFFFFFFFF ^ ArenaBspMap.SKY_BIT))
	_check(not graze.is_empty() and ArenaBspMap.on_sky(space, graze.position, graze_dir), "a grazing hit on the slab reads as sky")
	var wall_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3(30, 0, 0)))
	_check(not wall_hit.is_empty() and not ArenaBspMap.on_sky(space, wall_hit.position, Vector3.RIGHT), "an ordinary wall is not sky")
	_check(not ArenaBspMap.on_sky(null, end, Vector3.FORWARD), "no physics space is not sky")

	var marks := [
		{"entry": wall_hit.position, "entry_normal": Vector3.LEFT, "exit": wall_hit.position + Vector3(1, 0, 0), "exit_normal": Vector3.RIGHT},
		{"entry": end, "entry_normal": Vector3.BACK, "exit": end + Vector3(0, 0, -1), "exit_normal": Vector3.FORWARD},
	]
	var kept := ArenaPresentationB1.without_sky(space, marks, Vector3.FORWARD)
	_check(kept.size() == 1 and kept[0] == marks[0], "a penetration touching the sky is dropped, a wall's kept", str(kept.size()))
	var bounces := [{"point": wall_hit.position, "normal": Vector3.LEFT}, {"point": end, "normal": Vector3.BACK}]
	var kept_b := ArenaPresentationB1.without_sky(space, bounces, Vector3.FORWARD)
	_check(kept_b.size() == 1 and kept_b[0] == bounces[0], "a ricochet on the sky is dropped, a wall's kept", str(kept_b.size()))
	_check(sky_body.collision_layer & ArenaBspMap.SKY_BIT == 0, "the sky body itself is not on the sky layer (shots unchanged)")

	# A brick brush whose top side alone is TOOLSSKYBOX: the manifest's sky_faces names that side (units, as the importer writes), the
	# brush is no sky hull, so a shot at the cap reads as sky and a shot at its brick wall does not.
	var brick := StaticBody3D.new()
	var brick_shape := CollisionShape3D.new()
	brick_shape.shape = _box_shape(Vector3(2, 2, 2))
	brick_shape.position = Vector3(40, 0, 0)  # the body stays at the origin, as the world body does: the area under it takes its transform
	brick.add_child(brick_shape)
	root.add_child(brick)
	var u := 1.0 / ArenaBspMap.METRES_PER_UNIT
	var cap := []
	for corner: Vector3 in [Vector3(-1, 1, -1), Vector3(1, 1, -1), Vector3(1, 1, 1), Vector3(-1, 1, 1)]:
		cap.append([(corner.x + 40.0) * u, corner.y * u, corner.z * u])
	var info := {"hull_kinds": {}, "sky_faces": [{"normal": [0.0, 1.0, 0.0], "points": cap}]}
	_check(ArenaBspMap.sky_face_shapes(info).size() == 1 and ArenaBspMap.sky_face_shapes({"hull_kinds": {}}).is_empty(), "one slab per manifest sky face, none without")
	ArenaBspMap._mark_sky(brick, "mixed", "", info)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var cap_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(40, 5, 0.3), Vector3(40, -5, 0.3), 0xFFFFFFFF ^ ArenaBspMap.SKY_BIT))
	_check(not cap_hit.is_empty() and cap_hit.collider == brick and ArenaBspMap.on_sky(space, cap_hit.position, Vector3.DOWN), "a shot at the sky cap of a mixed brush reads as sky")
	var brick_hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(30, 0.3, 0.3), Vector3(50, 0.3, 0.3), 0xFFFFFFFF ^ ArenaBspMap.SKY_BIT))
	_check(not brick_hit.is_empty() and brick_hit.collider == brick and not ArenaBspMap.on_sky(space, brick_hit.position, Vector3.RIGHT), "a shot at the same brush's wall face does not")
	var steep := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(40, 5, 0.3), Vector3(40.4, -5, 0.3), 0xFFFFFFFF ^ ArenaBspMap.SKY_BIT))
	_check(not steep.is_empty() and ArenaBspMap.on_sky(space, steep.position, (Vector3(40.4, -5, 0.3) - Vector3(40, 5, 0.3)).normalized()), "a slanted shot at the cap reads as sky too")
	var mixed_marks := [{"point": cap_hit.position, "normal": Vector3.UP}, {"point": brick_hit.position, "normal": Vector3.LEFT}]
	var mixed_kept := ArenaPresentationB1.without_sky(space, mixed_marks, Vector3.DOWN)
	_check(mixed_kept.size() == 1 and mixed_kept[0] == mixed_marks[1], "the cap's decal is dropped, the brick wall's decal is made", str(mixed_kept.size()))
	_check(brick.collision_layer & ArenaBspMap.SKY_BIT == 0, "the brick body is not on the sky layer, its wall still stops shots")

	_report(EXPECTED_CHECKS)
