extends GSPelletTracer
## The combat manager's pellet tracer with the walk in GameSpice Sim (`GSSimShots`): walls, sheets, ricochets,
## bodies and the hitbox shapes run native, and the event rows that come back are applied here exactly as
## [code]GSPelletTracer._step_body[/code] would (`sv_native_shots`, on by default).
##
## The script tracer stays the specification and the fallback: with the switch off, the library missing, a
## hitbox set laid out other than player root > set > box, or a pane on the pellet's line, the pellet goes to
## [code]super[/code]. A posed unlag rewind (fc_game_unlag.gd) moves no node: it hands each target's rewound feet
## and crouch fit here with [method pose], and only a pellet sent to the script makes the game move the nodes
## after all ([member materialize_fn]), once a shot. Everything else is read where it stands once per shot.

const FcPlayer := preload("fc_player.gd")

const CHANNEL := "fc.native_shots"
const CLASS := &"GSSimShots"

## Set from `sv_native_shots`; false runs the script tracer.
var enabled := true

var _native: Object = null
var _stride := 20
var _missing_logged := false
## Pellets walked natively (not sent to the script): what a parity check reads to know the native path ran.
var native_pellets := 0

# The hitbox cache, in m._set_list order: the set and box nodes the rows name, and what built it.
var _sets: Array[GSHitboxSet] = []
var _roots: Array[Node3D] = []
var _players: Array[FcPlayer] = []
var _boxes: Array[GSHitbox] = []
var _box_base := PackedInt32Array()
var _entities := PackedInt64Array()
var _layout_ok := false

# Group names behind the group index of each box row, and the reverse.
var _groups: Array[StringName] = []
var _group_index: Dictionary[StringName, int] = {}

# Materials behind the material index of each world hit, and per index what this shot's round makes of it.
var _materials: Array[StringName] = []
var _material_index: Dictionary[StringName, int] = {}
var _mat_resistance := PackedFloat64Array()
var _mat_ricochet := PackedByteArray()
var _mat_sheet := PackedFloat64Array()
var _mat_known := PackedByteArray()

# Per shot.
var _synced_shot: GSShot = null
var _shot_ok := false
var _shot_pen: GSPenetration = null
var _poses := PackedFloat64Array()
var _set_rows := PackedFloat64Array()
var _box_rows := PackedFloat64Array()
var _pen_params := PackedFloat64Array()
var _zones := PackedFloat64Array()
var _skip_sets := PackedInt32Array()
var _row := PackedFloat64Array()
var _miss := PackedFloat64Array()
var _world_fn: Callable

# The posed rewind: player -> rewound feet and zone height scale, while [member _posing].
var _pose_feet: Dictionary[FcPlayer, Vector3] = {}
var _pose_k: Dictionary[FcPlayer, float] = {}
var _posing := false
## Moves the nodes to the poses (the game's rewind, done late): called once when a posed shot's pellet goes to the script tracer.
var materialize_fn: Callable


func _init(manager: GSCombatManager) -> void:
	super(manager)
	_world_fn = _world_row
	_row.resize(12)
	_pen_params.resize(12)
	if ClassDB.class_exists(CLASS):
		_native = ClassDB.instantiate(CLASS)
	if _native == null or not _native.has_method(&"walk"):
		_native = null
		return
	_stride = int(ClassDB.class_get_integer_constant(CLASS, &"STRIDE"))
	_native.call(&"set_world", _world_fn)


## Whether pellets are walked natively when [member enabled]: the library is loaded and has the class.
func is_native() -> bool:
	return _native != null


## Whether a rewind may [method pose] instead of moving nodes: this tracer walks the pellets natively.
func can_pose() -> bool:
	return enabled and _native != null


## The unlag rewind's answer for [param player]: traced with its feet at [param feet] and its zones at height scale [param k].
func pose(player: FcPlayer, feet: Vector3, k: float) -> void:
	_pose_feet[player] = feet
	_pose_k[player] = k
	_posing = true
	_synced_shot = null


## Forgets the poses (the rewind's restore).
func end_pose() -> void:
	if not _posing:
		return
	_pose_feet.clear()
	_pose_k.clear()
	_posing = false
	_synced_shot = null


## The script tracer reads the nodes: a posed rewind moves them now, and the held bounds are read again where they went.
func _script_pellet(shot: GSShot, pellet: int, type: GSDamageType, pen: GSPenetration, excluded: Array) -> void:  # perf-lint: allow untyped_array matches GSPelletTracer.trace_pellet
	if _posing and materialize_fn.is_valid():
		_posing = false
		_synced_shot = null
		materialize_fn.call()  # perf-lint: allow dynamic_call at most once a shot, only when it falls back to the script walk
		if m.bounds_cache:
			m.trace.hold_bounds(m._set_list)
	super.trace_pellet(shot, pellet, type, pen, excluded)


func trace_pellet(shot: GSShot, pellet: int, type: GSDamageType, pen: GSPenetration, excluded: Array) -> void:
	if not enabled:
		_script_pellet(shot, pellet, type, pen, excluded)
		return
	if _native == null:
		if not _missing_logged:
			_missing_logged = true
			GSLog.error(CHANNEL, "sv_native_shots is on but GameSpice Sim has no GSSimShots.walk; hitscan runs the script tracer", {})
		_script_pellet(shot, pellet, type, pen, excluded)
		return
	if shot != _synced_shot or pellet == 0:
		_synced_shot = shot
		_shot_ok = _sync(pen, excluded)
	if not _shot_ok:
		_script_pellet(shot, pellet, type, pen, excluded)
		return

	var rows: PackedFloat64Array = _native.call(&"walk", pellet, shot.origin, shot.pellets[pellet], shot.max_range, _skip_sets)
	var count := rows.size() / _stride
	for r in count:
		if rows[r * _stride] == 9.0:
			_script_pellet(shot, pellet, type, pen, excluded)
			return
	native_pellets += 1
	for r in count:
		_apply(rows, r * _stride, shot, pellet, type)


# --- Per shot ---------------------------------------------------------------

## Brings the cache, the poses, the round and the exclusions up to this shot. False sends the shot to the script.
func _sync(pen: GSPenetration, excluded: Array) -> bool:
	var sets: Array[GSHitboxSet] = m._set_list
	if not _cache_current(sets) and not _rebuild(sets):
		return false
	if not _layout_ok:
		return false

	var n := sets.size()
	_poses.resize(n * 14)
	_skip_sets.resize(0)
	for i in n:
		var set_node := sets[i]
		var at := i * 14
		var root := _roots[i]
		var live := set_node != null and is_instance_valid(set_node) and root != null and is_instance_valid(root)
		_poses[at] = 1.0 if live and set_node.enabled else 0.0
		if not live:
			continue
		var t := root.global_transform
		var player := _players[i]
		var k := -1.0
		if player != null:
			k = player._fit_k
			if _posing and _pose_feet.has(player):
				t.origin = _pose_feet[player]
				k = _pose_k[player]
		_put_basis(_poses, at + 1, t)
		_poses[at + 13] = k
		if _excluded(set_node, excluded):
			_skip_sets.append(i)
	if not bool(_native.call(&"set_poses", _poses)):
		return false

	_shot_pen = pen
	_mat_known.fill(0)
	if pen == null:
		_native.call(&"clear_pen")
		return true
	_pen_params[0] = pen.power
	_pen_params[1] = pen.max_depth
	_pen_params[2] = pen.body_cost
	_pen_params[3] = pen.speed
	_pen_params[4] = pen.reference_speed
	_pen_params[5] = pen.min_damage
	_pen_params[6] = pen.max_passes
	_pen_params[7] = pen.ricochet_angle
	_pen_params[8] = pen.ricochet_keep
	_pen_params[9] = pen.max_ricochets
	_pen_params[10] = 1.0 if m.ricochet_enabled else 0.0
	_pen_params[11] = 1.0 if m.penetration_players else 0.0
	_zones.resize(_groups.size())
	var fine: bool = m.rules.hitzones
	for g in _groups.size():
		var group := _groups[g] if fine else GSHitzone.coarse(_groups[g])
		_zones[g] = float(pen.body_zones.get(group, pen.body_zones.get(String(group), 1.0)))
	return bool(_native.call(&"set_pen", _pen_params, _zones))


## [code]GSTrace._is_excluded[/code]: the list holds the set or its entity.
func _excluded(set_node: GSHitboxSet, excluded: Array) -> bool:
	if excluded.is_empty():
		return false
	var entity := set_node.entity_owner()
	for node: Variant in excluded:
		if node == null:
			continue
		if node == entity or node == set_node:
			return true
	return false


static func _put_basis(out: PackedFloat64Array, at: int, t: Transform3D) -> void:
	# Basis rows, as the engine stores them: row i is (x[i], y[i], z[i]).
	var b := t.basis
	out[at] = b.x.x
	out[at + 1] = b.y.x
	out[at + 2] = b.z.x
	out[at + 3] = b.x.y
	out[at + 4] = b.y.y
	out[at + 5] = b.z.y
	out[at + 6] = b.x.z
	out[at + 7] = b.y.z
	out[at + 8] = b.z.z
	out[at + 9] = t.origin.x
	out[at + 10] = t.origin.y
	out[at + 11] = t.origin.z


# --- The hitbox cache -------------------------------------------------------

## Whether the cache still names these sets, their boxes and their entities.
func _cache_current(sets: Array[GSHitboxSet]) -> bool:
	if sets.size() != _sets.size():
		return false
	for i in sets.size():
		var set_node := sets[i]
		if set_node != _sets[i]:
			return false
		if set_node == null or not is_instance_valid(set_node):
			continue
		var boxes := set_node.hitboxes()
		if boxes.size() != _box_base[i + 1] - _box_base[i]:
			return false
		if _entities[i] != m._entity_id_of(_owner_of(set_node, boxes)):
			return false
	return true


func _owner_of(set_node: GSHitboxSet, boxes: Array[GSHitbox]) -> Node:
	return boxes[0].resolve_owner() if not boxes.is_empty() else set_node.entity_owner()


func _rebuild(sets: Array[GSHitboxSet]) -> bool:
	_sets = sets.duplicate()
	_roots.resize(sets.size())
	_players.resize(sets.size())
	_entities.resize(sets.size())
	_box_base.resize(sets.size() + 1)
	_boxes.clear()
	_set_rows.resize(sets.size() * 20)
	_set_rows.fill(0.0)
	_box_rows.resize(0)
	_layout_ok = true
	for i in sets.size():
		_box_base[i] = _boxes.size()
		_roots[i] = null
		_players[i] = null
		_entities[i] = 0
		var set_node := sets[i]
		if set_node == null or not is_instance_valid(set_node):
			continue
		var root := set_node.get_parent() as Node3D
		var boxes := set_node.hitboxes()
		if root == null:
			_layout_ok = false
			continue
		_roots[i] = root
		_players[i] = root as FcPlayer
		_entities[i] = m._entity_id_of(_owner_of(set_node, boxes))
		var at := i * 20
		_set_rows[at] = _entities[i]
		_set_rows[at + 1] = boxes.size()
		_set_rows[at + 2] = set_node.bounds_offset.x
		_set_rows[at + 3] = set_node.bounds_offset.y
		_set_rows[at + 4] = set_node.bounds_offset.z
		_set_rows[at + 5] = set_node.bounds_radius
		_put_basis(_set_rows, at + 7, set_node.transform)
		var player := _players[i]
		for box in boxes:
			# One level below the set, every box enabled: what the rows can say. Anything else is the script's.
			if box.get_parent() != set_node or not box.enabled:
				_layout_ok = false
			_boxes.append(box)
			var b := _box_rows.size()
			_box_rows.resize(b + 24)
			_box_rows[b] = box.shape
			_box_rows[b + 1] = box.radius
			_box_rows[b + 2] = box.height
			_box_rows[b + 3] = box.half_extents.x
			_box_rows[b + 4] = box.half_extents.y
			_box_rows[b + 5] = box.half_extents.z
			_box_rows[b + 6] = box.damage_scale
			_box_rows[b + 7] = box.precedence
			_box_rows[b + 8] = _group_of(box.effective_group())
			var fitted := player != null
			if fitted and not box.has_meta(&"stand_y"):
				# What fit_hitboxes_to_crouch records on its first fit, read before any fit has moved the box.
				box.set_meta(&"stand_y", box.position.y)
				box.set_meta(&"stand_h", box.height)
			_box_rows[b + 9] = float(box.get_meta(&"stand_y")) if fitted else NAN
			_box_rows[b + 10] = float(box.get_meta(&"stand_h")) if fitted else NAN
			_put_basis(_box_rows, b + 11, box.transform)
	_box_base[sets.size()] = _boxes.size()
	if not bool(_native.call(&"set_boxes", _set_rows, _box_rows)):
		_layout_ok = false
	return true


func _group_of(group: StringName) -> int:
	var at: int = _group_index.get(group, -1)
	if at < 0:
		at = _groups.size()
		_groups.append(group)
		_group_index[group] = at
	return at


# --- The world --------------------------------------------------------------

## The world ray the native walk asks for: [code]m.trace._world_ray[/code], with what this shot's round makes of the material.
func _world_row(from: Vector3, direction: Vector3, max_distance: float) -> PackedFloat64Array:
	var hit: GSHitbox.Hit = m.trace._world_ray(from, direction, max_distance)
	if not hit.ok():
		return _miss
	var mat := _material_of(hit.material)
	var pane := hit.collider as Node
	var is_pane := pane != null and pane.has_method(&"hurt") and pane.has_method(&"is_broken")
	_row[0] = hit.distance
	_row[1] = hit.point.x
	_row[2] = hit.point.y
	_row[3] = hit.point.z
	_row[4] = hit.normal.x
	_row[5] = hit.normal.y
	_row[6] = hit.normal.z
	_row[7] = mat
	_row[8] = _mat_resistance[mat]
	_row[9] = _mat_ricochet[mat]
	_row[10] = _mat_sheet[mat]
	_row[11] = 1.0 if is_pane else 0.0
	return _row


func _material_of(material: StringName) -> int:
	var at: int = _material_index.get(material, -1)
	if at < 0:
		at = _materials.size()
		_materials.append(material)
		_material_index[material] = at
		_mat_resistance.resize(at + 1)
		_mat_ricochet.resize(at + 1)
		_mat_sheet.resize(at + 1)
		_mat_known.resize(at + 1)
		_mat_known[at] = 0
	if _mat_known[at] == 0:
		_mat_known[at] = 1
		var pen := _shot_pen
		_mat_resistance[at] = pen.resistance_of(material) if pen != null else 0.0
		_mat_ricochet[at] = 1 if pen != null and pen.ricochet_materials.has(String(material)) else 0
		_mat_sheet[at] = float(m.sheet_thickness.get(material, m.sheet_thickness.get(String(material), 0.0)))
	return at


# --- Applying rows ----------------------------------------------------------

static func _v(rows: PackedFloat64Array, at: int) -> Vector3:
	return Vector3(rows[at], rows[at + 1], rows[at + 2])


func _apply(rows: PackedFloat64Array, at: int, shot: GSShot, pellet: int, type: GSDamageType) -> void:
	match int(rows[at]):
		1:
			shot.impacts.append(_v(rows, at + 2))
		2:
			_apply_body(rows, at, shot, type)
		3:
			shot.penetrations.append({
				"pellet": pellet, "material": _materials[int(rows[at + 14])], "thickness": rows[at + 15],
				"cost": rows[at + 16], "entry": _v(rows, at + 2), "exit": _v(rows, at + 5),
				"entry_normal": _v(rows, at + 8), "exit_normal": _v(rows, at + 11), "sheet": rows[at + 17] != 0.0,
			})
		4:
			shot.ricochets.append({
				"pellet": pellet, "material": _materials[int(rows[at + 14])], "point": _v(rows, at + 2),
				"normal": _v(rows, at + 5), "angle": rows[at + 15], "direction": _v(rows, at + 8),
			})


## [code]GSPelletTracer._step_body[/code]'s damage, from a body row.
func _apply_body(rows: PackedFloat64Array, at: int, shot: GSShot, type: GSDamageType) -> void:
	var set_index := int(rows[at + 8])
	var box := _boxes[_box_base[set_index] + int(rows[at + 9])]
	var hit := GSHitbox.Hit.new()
	hit.point = _v(rows, at + 2)
	hit.normal = _v(rows, at + 5)
	hit.hitbox = box
	hit.group = box.effective_group()
	hit.limb = box.limb
	hit.entity = box.resolve_owner()
	var passes := int(rows[at + 12])
	var walls := int(rows[at + 13])
	var bounces := int(rows[at + 14])
	var direction := shot.pellets[int(rows[at + 1])]
	if bounces > 0:
		# The pellet's direction after its last bounce: the ricochet row just before this one says it.
		direction = _last_direction(shot, int(rows[at + 1]), direction)
	var damage := GSDamage.make(shot.attacker, _entities[set_index], shot.damage * m.config.damage_scale * rows[at + 11], type)
	damage.hit_group = hit.group
	damage.limb = hit.limb
	var posed := _players[set_index]
	if _posing and posed != null and _pose_feet.has(posed):
		# The side is read against the body's centre where the pose put it; the node has not moved.
		var set_node: GSHitboxSet = m._set_list[set_index]
		var centre := set_node.bounds_centre() + _pose_feet[posed] - _roots[set_index].global_position
		damage.context[GSHitzone.CONTEXT_SIDE] = GSHitzone.side_of(hit.point, centre, direction, set_node.bounds_radius * 0.25)
	else:
		GSHitzone.annotate(damage, hit, direction)
	damage.context["entity"] = hit.entity
	if passes > 0:
		damage.context["penetrated"] = passes
		damage.context["wallbang"] = walls > 0
	if bounces > 0:
		damage.context["ricochet"] = bounces
	damage.point = hit.point
	damage.direction = direction
	damage.distance = rows[at + 10]
	damage.weapon_id = shot.weapon_id
	damage.tick = shot.tick
	damage.scale_by(box.damage_scale, "hitbox")
	shot.damages.append(m.resolver.resolve(damage))


func _last_direction(shot: GSShot, pellet: int, fallback: Vector3) -> Vector3:
	for i in range(shot.ricochets.size() - 1, -1, -1):
		var r: Dictionary = shot.ricochets[i]
		if int(r["pellet"]) == pellet:
			return r["direction"]
	return fallback
