extends Node3D
## A thrown knife's streak: a fading ribbon behind it while it flies, so a spinning knife (a Boomerang above all) reads
## from across the map instead of as a dark sliver. Put under the knife's model; it draws in world space, follows its
## parent and empties itself once the knife stops (lying or stuck). Presentation only.
##
## Three things make a flying knife readable from the overview or a third-person camera, where the blade is a few pixels:
## the streak is never thinner on screen than [member min_angle] (it widens with the camera's distance), a small glint rides
## the knife at a fixed screen size, and the model itself is drawn [member flight_scale] times larger while it flies.

## How long a point of the streak lasts (seconds) and how wide it starts (metres).
@export var life: float = 0.35
@export var width: float = 0.2
## The narrowest the streak's head is drawn, as an angle seen from the camera (radians): at 30 m, 0.015 is 0.45 m wide.
## 0 draws it at [member width] at any distance.
@export var min_angle: float = 0.015
## Below this speed (m/s) no new points are laid, so a knife lying, stuck or riding a running body lets its streak fade out.
@export var min_speed: float = 10.0
@export var color: Color = Color(1.0, 0.93, 0.7, 0.95)
## The glint riding a flying knife: its size as a share of the screen's height (0 draws none) and its colour.
@export var glint_size: float = 0.06
@export var glint_color: Color = Color(1.0, 0.97, 0.85, 1.0)
## The knife model's scale while it flies, eased back to 1 as it slows (1 leaves the model alone).
@export var flight_scale: float = 1.6

var _points: Array[Vector3] = []
var _ages: PackedFloat32Array = PackedFloat32Array()
var _last: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _mesh: ImmediateMesh = null
var _drawn: MeshInstance3D = null
var _material: StandardMaterial3D = null
var _glint: MeshInstance3D = null
## How much of the flight look is on, 0 to 1: up while the knife flies, down once it stops.
var _flying: float = 0.0
var _scaled: Node3D = null
var _rest_scale := Vector3.ONE


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
	# Mixed, not added: an added streak vanishes over the pale floors and skies most maps have.
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.vertex_color_use_as_albedo = true
	_material.no_depth_test = false
	# A bright core with a dark rim, so it reads over pale floors and dark walls alike.
	var across := Gradient.new()
	across.offsets = PackedFloat32Array([0.0, 0.18, 0.38, 0.5, 0.62, 0.82, 1.0])
	var rim := Color(0.12, 0.1, 0.08, 0.7)
	across.colors = PackedColorArray([Color(rim, 0.0), rim, Color.WHITE, Color.WHITE, Color.WHITE, rim, Color(rim, 0.0)])
	var soft := GradientTexture2D.new()
	soft.gradient = across
	soft.width = 64
	soft.height = 1
	_material.albedo_texture = soft
	add_child(_drawn)
	if glint_size > 0.0:
		_glint = _make_glint()
		add_child(_glint)


## A round soft spot, billboarded at a fixed screen size, so the knife is a point of light however far away it is.
func _make_glint() -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(glint_size, glint_size)
	var spot := Gradient.new()
	spot.offsets = PackedFloat32Array([0.0, 0.25, 0.55, 1.0])
	spot.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0.9), Color(1, 1, 1, 0.3), Color(1, 1, 1, 0)])
	var tex := GradientTexture2D.new()
	tex.gradient = spot
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 32
	tex.height = 32
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.fixed_size = true
	mat.albedo_texture = tex
	mat.albedo_color = glint_color
	quad.material = mat
	var glint := MeshInstance3D.new()
	glint.name = "Glint"
	glint.mesh = quad
	glint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glint.visible = false
	return glint


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
	var flying := _has_last and speed >= min_speed
	if flying:
		_points.append(at)
		_ages.append(0.0)
	_last = at
	_has_last = true
	_flying = move_toward(_flying, 1.0 if flying else 0.0, delta / maxf(life, 0.05))
	_show_flight(parent, at)
	_redraw()


## The glint and the larger model, faded in and out with [member _flying].
func _show_flight(parent: Node3D, at: Vector3) -> void:
	if _glint != null:
		_glint.visible = _flying > 0.01
		_glint.global_position = at
		_glint.transparency = 1.0 - _flying
	if flight_scale == 1.0 or not is_finite(flight_scale) or flight_scale <= 0.0:
		return
	if _scaled != parent:
		_scaled = parent
		_rest_scale = parent.scale
	parent.scale = _rest_scale * lerpf(1.0, flight_scale, _flying)


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
		var wide := maxf(width, eye.distance_to(p) * min_angle) if min_angle > 0.0 else width
		var half := wide * 0.5 * fresh
		var c := Color(color, color.a * fresh * fresh)
		_mesh.surface_set_color(c)
		_mesh.surface_set_uv(Vector2(0.0, 0.5))
		_mesh.surface_add_vertex(p - side * half)
		_mesh.surface_set_color(c)
		_mesh.surface_set_uv(Vector2(1.0, 0.5))
		_mesh.surface_add_vertex(p + side * half)
	_mesh.surface_end()
