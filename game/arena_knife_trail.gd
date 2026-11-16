extends Node3D
## A thrown knife's streak: a fading ribbon behind it while it flies, so a spinning knife (a Boomerang above all) reads
## from across the map instead of as a dark sliver. Put under the knife's model; it draws in world space, follows its
## parent and empties itself once the knife stops (lying or stuck). Presentation only.

## How long a point of the streak lasts (seconds) and how wide it starts (metres).
@export var life: float = 0.28
@export var width: float = 0.07
## Below this speed (m/s) no new points are laid, so a knife lying, stuck or riding a running body lets its streak fade out.
@export var min_speed: float = 10.0
@export var color: Color = Color(1.0, 0.86, 0.6, 0.55)

var _points: Array[Vector3] = []
var _ages: PackedFloat32Array = PackedFloat32Array()
var _last: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _mesh: ImmediateMesh = null
var _drawn: MeshInstance3D = null
var _material: StandardMaterial3D = null


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY


## Built on the first frame, not in [method _ready]: the knives layer measures the model's mesh extent as it is made,
## and an empty ribbon there would stretch that box to the world origin.
func _build() -> void:
	_mesh = ImmediateMesh.new()
	_drawn = MeshInstance3D.new()
	_drawn.name = "Streak"
	_drawn.mesh = _mesh
	_drawn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_drawn.extra_cull_margin = 16384.0
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.vertex_color_use_as_albedo = true
	_material.no_depth_test = false
	add_child(_drawn)


func _process(delta: float) -> void:
	if _drawn == null:
		_build()
	var parent := get_parent() as Node3D
	if parent == null:
		return
	# The knife's centre: the parent spins about it, so its origin would draw a corkscrew.
	var holder := parent.get_parent() as Node3D
	var at := (holder if holder != null else parent).global_position
	for i in _ages.size():
		_ages[i] += delta
	while not _ages.is_empty() and _ages[0] >= life:
		_ages.remove_at(0)
		_points.remove_at(0)
	var speed := (at - _last).length() / maxf(delta, 0.0001) if _has_last else 0.0
	if _has_last and speed >= min_speed:
		_points.append(at)
		_ages.append(0.0)
	_last = at
	_has_last = true
	_redraw()


func _redraw() -> void:
	_mesh.clear_surfaces()
	if _points.size() < 2:
		return
	var camera := get_viewport().get_camera_3d() if get_viewport() != null else null
	var eye := camera.global_position if camera != null else Vector3.UP * 1000.0
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _material)
	var count := _points.size()
	for i in count:
		var p := _points[i]
		var along := (_points[mini(i + 1, count - 1)] - _points[maxi(i - 1, 0)])
		var side := along.cross(eye - p)
		side = side.normalized() if side.length_squared() > 1e-8 else Vector3.UP
		var fresh := 1.0 - clampf(_ages[i] / life, 0.0, 1.0)
		var half := width * 0.5 * fresh
		var c := Color(color, color.a * fresh * fresh)
		_mesh.surface_set_color(c)
		_mesh.surface_add_vertex(p - side * half)
		_mesh.surface_set_color(c)
		_mesh.surface_add_vertex(p + side * half)
	_mesh.surface_end()
