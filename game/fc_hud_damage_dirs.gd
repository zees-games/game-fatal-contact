extends Control
## Red chevrons around the crosshair that point at whoever hurt you, turning as you turn. The full-screen red edge says THAT you were
## hit; this says from where, which matters most when the shooter is behind or beside you and nothing on screen shows it.

## Seconds a chevron takes to fade.
var life_sec: float = 1.6
## Pixels from the screen's middle to the chevron's tip, and its size.
var ring_radius: float = 150.0
var chevron_size: float = 26.0
var colour := Color(0.95, 0.12, 0.1, 1.0)

var _hits: Array[Dictionary] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


## A hit from [param source], a point in the world. Hits from nearly the same bearing share a chevron, which is refreshed.
func note_hit(source: Vector3) -> void:
	for hit in _hits:
		if (hit["source"] as Vector3).distance_to(source) < 1.0:
			hit["age"] = 0.0
			hit["source"] = source
			return
	_hits.append({"source": source, "age": 0.0})
	set_process(true)


func is_showing() -> bool:
	return not _hits.is_empty()


func clear() -> void:
	_hits.clear()
	set_process(false)
	queue_redraw()


func _process(delta: float) -> void:
	for hit in _hits:
		hit["age"] = float(hit["age"]) + delta
	for i in range(_hits.size() - 1, -1, -1):
		if float(_hits[i]["age"]) >= life_sec:
			_hits.remove_at(i)
	if _hits.is_empty():
		set_process(false)
	queue_redraw()


## The angle, in radians clockwise from straight up the screen, of [param source] as seen from [param camera].
static func bearing(camera: Transform3D, source: Vector3) -> float:
	var local := camera.affine_inverse() * source
	return atan2(local.x, -local.z)


func _draw() -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return
	var middle := size * 0.5
	for hit in _hits:
		var fade := clampf(1.0 - float(hit["age"]) / life_sec, 0.0, 1.0)
		var angle := bearing(camera.global_transform, hit["source"])
		var out := Vector2(sin(angle), -cos(angle))
		var side := Vector2(-out.y, out.x)
		var tip := middle + out * ring_radius
		var base := tip - out * chevron_size
		var points := PackedVector2Array([tip, base + side * chevron_size * 0.7, base - out * 0.0 - side * chevron_size * 0.7])
		var tint := Color(colour.r, colour.g, colour.b, colour.a * fade)
		draw_colored_polygon(points, tint)
