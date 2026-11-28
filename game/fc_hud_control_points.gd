extends Control
## The control point row under the score strip: one disc per point in line order, filled in
## its owner's side colour, an arc of the capturing side's colour for its progress, a bar
## across a point neither side may start. Draws handed rows (`present`), reads no game state.

const FcHudGlance := preload("fc_hud_glance.gd")
const Look := preload("fc_hud_look.gd")

const RADIUS := 17.0
const SPACING := 50.0
const RED := 1
const BLUE := 2

## One row per point: `label` String, `owner` and `capturing` team ids, `progress` 0..1,
## `locked` bool (neither side may start it now).
var rows: Array[Dictionary] = []


func present(p_rows: Array[Dictionary]) -> void:
	if p_rows == rows:
		return
	rows = p_rows
	visible = not rows.is_empty()
	queue_redraw()


## The discs at full size, centred on the top of the box.
func footprint() -> Rect2:
	if rows.is_empty():
		return Rect2()
	var w := float(rows.size() - 1) * SPACING + (RADIUS + 4.0) * 2.0
	return Rect2(size.x * 0.5 - w * 0.5, 0.0, w, (RADIUS + 4.0) * 2.0)


static func _side(team: int) -> Color:
	return FcHudGlance.RED if team == RED else FcHudGlance.BLUE


func _draw() -> void:
	var font := Look.feedback_font(true)
	var plate := FcHudGlance.Ink.c(self, &"plate")
	var text := FcHudGlance.Ink.c(self, &"text")
	var dim := FcHudGlance.Ink.c(self, &"dim")
	for i in rows.size():
		var row: Dictionary = rows[i]
		var at := Vector2(size.x * 0.5 + (float(i) - float(rows.size() - 1) * 0.5) * SPACING, RADIUS + 4.0)
		var owner := int(row.get("owner", 0))
		draw_circle(at, RADIUS + 3.0, plate)
		draw_circle(at, RADIUS, _side(owner) if owner > 0 else dim)
		var progress := clampf(float(row.get("progress", 0.0)), 0.0, 1.0)
		var by := int(row.get("capturing", 0))
		if by > 0 and progress > 0.0:
			draw_arc(at, RADIUS + 1.5, -PI * 0.5, -PI * 0.5 + TAU * progress, 32, _side(by).lightened(0.25), 4.0, true)
		var label := String(row.get("label", ""))
		var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18)
		draw_string(font, at + Vector2(-label_size.x * 0.5, 6.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18, text)
		if bool(row.get("locked", false)):
			draw_line(at + Vector2(-RADIUS * 0.7, RADIUS * 0.7), at + Vector2(RADIUS * 0.7, -RADIUS * 0.7), plate, 3.0, true)
