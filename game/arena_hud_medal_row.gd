extends Control
## The medals of the followed player's last kills: icon, name, scale in, hold, fade. Its own file
## (it was an inner class of arena_hud_base.gd) because the HUD's functions named it, and an outer
## script naming its inner class from a function body made the parser depend on itself: a cycle
## GDScript never frees (CI perf-smoke mem_mb). The HUD reaches it as `MedalRow`.

const ArenaAwards := preload("arena_awards.gd")
const ArenaHudGlance := preload("arena_hud_glance.gd")
const Look := preload("arena_hud_look.gd")

const IN_SEC := 0.22
const HOLD_SEC := 2.4
const OUT_SEC := 0.5
const STAGGER_SEC := 0.14
const SPACING := 134.0
const RADIUS := 30.0
const MAX_SHOWN := 6
var shown: Array[Dictionary] = []

func add(medal: int, label: String, delay: float = 0.0) -> void:
	var look := Look.medal_look(medal)
	shown.append({
		"medal": medal, "label": label, "icon": Look.medal_icon(String(look[0])),
		"colour": look[1], "age": -delay, "x": NAN,
	})
	while shown.size() > MAX_SHOWN:
		shown.remove_at(0)

## Every medal still on screen, in order: what a check reads.
func labels() -> PackedStringArray:
	var out := PackedStringArray()
	for m in shown:
		out.append(String(m["label"]))
	return out

func advance(delta: float) -> void:
	if shown.is_empty():
		return
	var life := IN_SEC + HOLD_SEC + OUT_SEC
	for i in range(shown.size() - 1, -1, -1):
		shown[i]["age"] = float(shown[i]["age"]) + delta
		if float(shown[i]["age"]) >= life:
			shown.remove_at(i)
	# Slots for the ones that have appeared; each slides to its own.
	var visible_now: Array[Dictionary] = []
	for m in shown:
		if float(m["age"]) >= 0.0:
			visible_now.append(m)
	for i in range(visible_now.size()):
		var target := (float(i) - float(visible_now.size() - 1) * 0.5) * SPACING
		var m := visible_now[i]
		m["x"] = target if is_nan(float(m["x"])) else lerpf(float(m["x"]), target, minf(1.0, delta * 12.0))
	queue_redraw()

## Every medal on screen at full size, its badge and its name under it.
func footprint() -> Rect2:
	var centre := Vector2(size.x * 0.5, size.y * 0.27)
	var out := Rect2()
	for m in shown:
		if float(m["age"]) < 0.0 or is_nan(float(m["x"])):
			continue
		var w := maxf((RADIUS + 4.0) * 2.0,
			Look.feedback_font(true).get_string_size("%s!" % String(m["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 20).x + 6.0)
		var one := Rect2(centre.x + float(m["x"]) - w * 0.5, centre.y - RADIUS - 4.0, w, RADIUS * 2.0 + 38.0)
		out = one if not out.has_area() else out.merge(one)
	return out

func _draw() -> void:
	var centre := Vector2(size.x * 0.5, size.y * 0.27)
	var font := Look.feedback_font(true)
	for m in shown:
		var age := float(m["age"])
		if age < 0.0 or is_nan(float(m["x"])):
			continue
		var grow: float
		if age < IN_SEC:
			# Overshoot: in from nothing past full size and back, the genre's pop.
			var t := age / IN_SEC
			grow = lerpf(0.2, 1.3, t / 0.6) if t < 0.6 else lerpf(1.3, 1.0, (t - 0.6) / 0.4)
		else:
			grow = 1.0
		var fade := clampf((IN_SEC + HOLD_SEC + OUT_SEC - age) / OUT_SEC, 0.0, 1.0)
		var at := centre + Vector2(float(m["x"]), 0.0)
		var r := RADIUS * grow
		var colour: Color = m["colour"]
		draw_circle(at + Vector2(0.0, 3.0), r + 4.0, Color(0.0, 0.0, 0.0, 0.35 * fade))
		# The dark HUD: a deep disc rimmed in the medal's colour, the icon in it lit in the
		# colour. The bright theme ("Arcade"): the first HUD's white-ringed coloured badge.
		var dark := ArenaHudGlance.Ink.bright(self) < 0.5
		var icon: Texture2D = m["icon"]
		if dark:
			draw_circle(at, r + 3.5, Color(colour.lightened(0.2), fade))
			draw_circle(at, r, Color(ArenaHudGlance.Ink.c(self, &"plate"), 0.94 * fade))
			draw_circle(at, r * 0.86, Color(colour.darkened(0.55), 0.55 * fade))
		else:
			draw_circle(at, r + 3.5, Color(1.0, 1.0, 1.0, 0.92 * fade))
			draw_circle(at, r, Color(colour.darkened(0.25), fade))
			draw_circle(at - Vector2(0.0, r * 0.12), r * 0.86, Color(colour, fade))
		if icon != null:
			var side := r * 1.4
			draw_texture_rect(icon, Rect2(at - Vector2(side, side) * 0.5, Vector2(side, side)), false,
				Color(colour.lightened(0.45), fade) if dark else Color(1.0, 1.0, 1.0, fade))
		var medal := int(m["medal"])
		var tally := (
			"2" if medal == ArenaAwards.Medal.DOUBLE_KILL
			else "3" if medal == ArenaAwards.Medal.TRIPLE_KILL
			else "4+" if medal == ArenaAwards.Medal.MULTI_KILL else ""
		)
		if tally != "":
			var badge := at + Vector2(r * 0.72, r * 0.62)
			draw_circle(badge, 12.0 * grow, Color(colour.lightened(0.2), fade) if dark else Color(1.0, 1.0, 1.0, fade))
			draw_circle(badge, 10.0 * grow, Color(colour.darkened(0.35), fade))
			draw_string(
				Look.feedback_font(), badge + Vector2(-20.0, 5.0 * grow), tally, HORIZONTAL_ALIGNMENT_CENTER,
				40.0, int(14.0 * grow), Color(1.0, 1.0, 1.0, fade)
			)
		Look.draw_outlined(
			self, font, at + Vector2(-90.0, r + 26.0), "%s!" % String(m["label"]),
			int(20.0 * minf(grow, 1.15)), Color(1.0, 1.0, 1.0, fade), 6, HORIZONTAL_ALIGNMENT_CENTER, 180.0
		)
