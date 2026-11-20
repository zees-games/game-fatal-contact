extends RefCounted

## Pictures of the attachments for the attachments screen: a side silhouette of each part drawn with canvas
## primitives into a rect, in one ink, so they need no texture and read the same on any renderer.
## `FcAttachIcons.draw(canvas, id, rect, ink)`; an id without a picture draws nothing and `has(id)` says so.

const IDS: Array[StringName] = [
	&"red_dot", &"holo", &"prism_3x", &"scope_6x", &"suppressor", &"compensator",
	&"vertical_grip", &"angled_grip", &"laser", &"extended_mag", &"rocketjump",
]


static func has(id: StringName) -> bool:
	return IDS.has(id)


static func draw(o: CanvasItem, id: StringName, rect: Rect2, ink: Color) -> void:
	var c := rect.get_center()
	var s := minf(rect.size.x, rect.size.y)
	var w := maxf(2.0, s * 0.07)
	var dim := Color(ink, ink.a * 0.55)
	match id:
		&"red_dot":
			_rail(o, c, s, 0.34, ink)
			o.draw_rect(Rect2(c + Vector2(-0.18, -0.20) * s, Vector2(0.36, 0.30) * s), ink, false, w)
			o.draw_circle(c + Vector2(0.0, -0.05) * s, s * 0.035, ink)
		&"holo":
			_rail(o, c, s, 0.40, ink)
			o.draw_rect(Rect2(c + Vector2(-0.22, -0.30) * s, Vector2(0.44, 0.42) * s), ink, false, w)
			o.draw_arc(c + Vector2(0.0, -0.10) * s, s * 0.08, 0.0, TAU, 20, ink, w * 0.7)
			o.draw_circle(c + Vector2(0.0, -0.10) * s, s * 0.02, ink)
		&"prism_3x":
			_rail(o, c, s, 0.34, ink)
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.30, -0.10) * s, c + Vector2(-0.30, 0.20) * s,
				c + Vector2(0.14, 0.20) * s, c + Vector2(0.14, -0.04) * s, c + Vector2(0.06, -0.20) * s,
				c + Vector2(-0.10, -0.20) * s, c + Vector2(-0.22, -0.10) * s]), dim)
			o.draw_rect(Rect2(c + Vector2(-0.34, -0.12) * s, Vector2(0.07, 0.34) * s), ink)
		&"scope_6x":
			o.draw_rect(Rect2(c + Vector2(-0.42, -0.06) * s, Vector2(0.84, 0.14) * s), dim)
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.42, -0.06) * s, c + Vector2(-0.50, -0.16) * s,
				c + Vector2(-0.50, 0.18) * s, c + Vector2(-0.42, 0.08) * s]), ink)
			o.draw_rect(Rect2(c + Vector2(0.36, -0.12) * s, Vector2(0.08, 0.26) * s), ink)
			for x: float in [-0.22, 0.20]:
				o.draw_rect(Rect2(c + Vector2(x, 0.08) * s, Vector2(0.07, 0.16) * s), ink)
		&"suppressor":
			o.draw_rect(Rect2(c + Vector2(-0.46, -0.11) * s, Vector2(0.92, 0.22) * s), dim)
			for x: float in [-0.24, 0.0, 0.24]:
				o.draw_line(c + Vector2(x, -0.11) * s, c + Vector2(x, 0.11) * s, ink, w)
			o.draw_rect(Rect2(c + Vector2(-0.46, -0.11) * s, Vector2(0.92, 0.22) * s), ink, false, w)
		&"compensator":
			o.draw_rect(Rect2(c + Vector2(-0.26, -0.13) * s, Vector2(0.52, 0.26) * s), dim)
			for x: float in [-0.12, 0.0, 0.12]:
				o.draw_rect(Rect2(c + Vector2(x - 0.025, -0.13) * s, Vector2(0.05, 0.08) * s), ink)
			o.draw_rect(Rect2(c + Vector2(-0.26, -0.13) * s, Vector2(0.52, 0.26) * s), ink, false, w)
		&"vertical_grip":
			o.draw_rect(Rect2(c + Vector2(-0.30, -0.30) * s, Vector2(0.60, 0.10) * s), ink)
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.07, -0.20) * s, c + Vector2(0.07, -0.20) * s,
				c + Vector2(0.11, 0.34) * s, c + Vector2(-0.11, 0.34) * s]), dim)
			for y: float in [0.0, 0.1, 0.2]:
				o.draw_line(c + Vector2(-0.09, y) * s, c + Vector2(0.09, y) * s, ink, w * 0.7)
		&"angled_grip":
			o.draw_rect(Rect2(c + Vector2(-0.30, -0.30) * s, Vector2(0.60, 0.10) * s), ink)
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.14, -0.20) * s, c + Vector2(-0.02, -0.20) * s,
				c + Vector2(0.30, 0.20) * s, c + Vector2(0.18, 0.26) * s]), dim)
			o.draw_line(c + Vector2(-0.08, -0.20) * s, c + Vector2(0.24, 0.23) * s, ink, w * 0.7)
		&"laser":
			o.draw_rect(Rect2(c + Vector2(-0.36, -0.14) * s, Vector2(0.42, 0.28) * s), dim)
			o.draw_rect(Rect2(c + Vector2(-0.36, -0.14) * s, Vector2(0.42, 0.28) * s), ink, false, w)
			o.draw_rect(Rect2(c + Vector2(0.06, -0.05) * s, Vector2(0.10, 0.10) * s), ink)
			o.draw_line(c + Vector2(0.16, 0.0) * s, c + Vector2(0.46, 0.0) * s, Color(1.0, 0.25, 0.25, ink.a), w)
		&"extended_mag":
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.14, -0.40) * s, c + Vector2(0.10, -0.40) * s,
				c + Vector2(0.20, 0.40) * s, c + Vector2(-0.04, 0.40) * s]), dim)
			for y: float in [-0.2, 0.0, 0.2]:
				o.draw_line(c + Vector2(-0.10 + y * 0.1, y) * s, c + Vector2(0.14 + y * 0.1, y) * s, ink, w * 0.7)
			o.draw_rect(Rect2(c + Vector2(-0.08, 0.36) * s, Vector2(0.30, 0.06) * s), ink)
		&"rocketjump":
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(0.44, 0.0) * s, c + Vector2(0.20, -0.12) * s,
				c + Vector2(-0.30, -0.12) * s, c + Vector2(-0.30, 0.12) * s, c + Vector2(0.20, 0.12) * s]), dim)
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.30, -0.12) * s, c + Vector2(-0.44, -0.24) * s,
				c + Vector2(-0.36, 0.0) * s]), ink)
			o.draw_colored_polygon(PackedVector2Array([c + Vector2(-0.30, 0.12) * s, c + Vector2(-0.44, 0.24) * s,
				c + Vector2(-0.36, 0.0) * s]), ink)
		_:
			pass


## The rail every optic sits on.
static func _rail(o: CanvasItem, c: Vector2, s: float, half: float, ink: Color) -> void:
	o.draw_rect(Rect2(c + Vector2(-half, 0.20) * s, Vector2(half * 2.0, 0.07) * s), ink)
