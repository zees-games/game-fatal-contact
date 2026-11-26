extends RefCounted

const FcPaths := preload("fc_paths.gd")
const FcWeaponIcons := preload("fc_weapon_icons.gd")

## The HUD laid out for a glance: the pieces [FcHud] places round the edge of the screen.
##
## [b]Where a player looks for each thing is the layout, and the genre has settled it:[/b]
## the score, the clock and who is winning at the top centre; who killed whom, with what, at
## the top right; your health bottom left; your magazine and reserve bottom right with the
## weapons you carry stacked up the right edge; your abilities bottom centre with the key
## under each; the keys that matter on the right. A player who has played one of these
## games finds every number here without looking for it.
##
## [b]Each piece draws itself from plain values it is handed[/b] (`show_*`), and knows
## nothing about a player or a match, so a suite can drive one without a game and a render
## tool can put up a frame with chosen numbers. [FcHud] reads the game and hands them
## over once a frame.
##
## [b]Readable over a pale map[/b]: every number is bold with a dark outline, and every
## group sits on a dark translucent plate. The first HUD drew thin regular-weight text
## straight over white prototype tiles, and health, ammunition and the key hints all but
## disappeared (`screenshots/dm_box_feel_kill_compat.png`).
##
## [b]Only Fatal Contact's own pieces are here[/b]: the ranked portraits, the kill feed with its
## weapon silhouettes, the carried weapons, the ability bar. Health, ammunition, the scores
## and clock, the key prompt and hints, the hit marker and the damage numbers were drawn here
## too and moved to gs-ui once other games needed them (`GSVitals`, `GSAmmoCounter`,
## `GSScoreStrip`, `GSKeyPrompt`, `GSKeyHints`, `GSHitMarker`, `GSDamageNumbers`; gs-ui
## `docs/hud.md`, "The glance pieces"); [FcHud] places them beside these. The colours
## below are the same as `GSHudPiece.DEFAULTS`, so the two sets read as one HUD.
##
## Art: the weapon pictures are Jestan's CC0 sprites ([FcWeaponIcons]); the older silhouettes are rendered from the weapon models by
## `tools/build_weapon_icons.sh` (Kenney's CC0 blaster and tool kits); the ability icons are
## Kenney's CC0 game and mobile-control icons (`assets/hud_icons/`). A missing file draws
## the words instead.

const WEAPON_ICON_DIR := "res://assets/weapon_icons"
const HUD_ICON_DIR := "res://assets/hud_icons"

## Fatal Contact's accent: your own ring, row and slot. The rest of every piece's colours are the
## theme's ([method Ink.c]), so the menu's theme restyles these pieces with gs-ui's.
const GOLD := Color(1.0, 0.8, 0.22)
## The two sides' colours when the teams give none, and the free-for-all plates.
const BLUE := Color(0.22, 0.5, 0.95)
const RED := Color(0.9, 0.24, 0.32)


## Fonts, outlined text, plates and keycaps, shared by every piece. An inner class so the
## pieces (themselves inner classes) can reach it.
class Ink:
	extends RefCounted

	static var _fonts: Dictionary = {}
	static var _textures: Dictionary = {}

	## The fallback font, emboldened, slanted when [param italic].
	static func font(italic: bool = false) -> Font:
		if not _fonts.has(italic):
			var f := FontVariation.new()
			f.base_font = ThemeDB.fallback_font
			f.variation_embolden = 0.85
			if italic:
				f.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(-0.2, 1.0), Vector2.ZERO)
			_fonts[italic] = f
		return _fonts[italic]

	## A HUD colour by gs-ui's name for it (`plate`, `text`, `dim`, `keycap`, ...): the theme's on
	## [constant GSHudPiece.THEME_TYPE] as [param canvas] sees it (the menu sets one on the HUD),
	## else gs-ui's default. Read when drawing, so a theme change shows next frame.
	static func c(canvas: CanvasItem, key: StringName) -> Color:
		var control := canvas as Control
		if control != null and control.has_theme_color(key, &"GSHudPiece"):
			return control.get_theme_color(key, &"GSHudPiece")
		# `keycap_edge` is gs-ui 6's; on an older shell's gs-ui it is not in DEFAULTS.
		return GSHudPiece.DEFAULTS.get(key, Color(1.0, 1.0, 1.0, 0.3) if key == &"keycap_edge" else Color.WHITE)

	## How bright the theme's HUD is, 0 to 1: gs-ui's `team_fill` (38 in the dark default,
	## 100 in the bright "Arcade" theme). What a piece with its own saturated colour (the
	## ability buttons, a medal's ring) blends its dark and its bright look by.
	static func bright(canvas: CanvasItem) -> float:
		var control := canvas as Control
		var n := 38
		if control != null and control.has_theme_constant(&"team_fill", &"GSHudPiece"):
			n = control.get_theme_constant(&"team_fill", &"GSHudPiece")
		return clampf((float(n) - 38.0) / 62.0, 0.0, 1.0)

	static func width(text: String, size: int) -> float:
		return font().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x

	## [param text] with its baseline at [param at], outlined dark.
	static func text(
		canvas: CanvasItem, at: Vector2, words: String, size: int, colour: Color,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, box: float = -1.0, outline: int = 6
	) -> void:
		var f := font()
		if outline > 0:
			var ink := c(canvas, &"ink")
			canvas.draw_string_outline(f, at, words, align, box, size, outline, Color(ink, ink.a * colour.a))
		canvas.draw_string(f, at, words, align, box, size, colour)

	## A rounded plate; [param fill] and [param edge] default (alpha below 0) to the theme's
	## `plate` and `plate_edge`.
	static func plate(canvas: CanvasItem, rect: Rect2, fill: Color = Color(0, 0, 0, -1), radius: int = 7, edge: Color = Color(0, 0, 0, -1), edge_width: int = 1) -> void:
		if fill.a < 0.0:
			fill = c(canvas, &"plate")
		if edge.a < 0.0:
			edge = c(canvas, &"plate_edge")
		var box := StyleBoxFlat.new()
		box.bg_color = fill
		box.set_corner_radius_all(radius)
		box.anti_aliasing = true
		if edge.a > 0.0 and edge_width > 0:
			box.border_color = edge
			box.set_border_width_all(edge_width)
		canvas.draw_style_box(box, rect)

	## A key drawn as a key: a cap in the theme's `keycap` with the key's name, its left edge at
	## [param at].x and its centre at [param at].y. Returns its width.
	static func keycap(canvas: CanvasItem, at: Vector2, key: String, size: int = 13, alpha: float = 1.0) -> float:
		var w := maxf(width(key, size) + 12.0, float(size) + 10.0)
		var h := float(size) + 10.0
		var rect := Rect2(at.x, at.y - h * 0.5, w, h)
		plate(canvas, Rect2(rect.position + Vector2(0.0, 2.0), rect.size), Color(0.0, 0.0, 0.0, 0.45 * alpha), 5, Color(0, 0, 0, 0), 0)
		var cap := c(canvas, &"keycap")
		var edge := c(canvas, &"keycap_edge")
		plate(canvas, rect, Color(cap, cap.a * alpha), 5, Color(edge, edge.a * alpha), 1 if edge.a > 0.0 else 0)
		canvas.draw_string(font(), Vector2(rect.position.x, rect.end.y - 6.0), key, HORIZONTAL_ALIGNMENT_CENTER, w, size, Color(c(canvas, &"keycap_text"), alpha))
		return w

	static func keycap_width(key: String, size: int = 13) -> float:
		return maxf(width(key, size) + 12.0, float(size) + 10.0)

	## A texture under `res://` by path, through the pack rebase; null when missing.
	static func texture(path: String) -> Texture2D:
		if not _textures.has(path):
			var at := FcPaths.rebase(path)
			_textures[path] = load(at) as Texture2D if ResourceLoader.exists(at) else null
		return _textures[path]

	static func weapon_icon(id: StringName) -> Texture2D:
		var sprite := FcWeaponIcons.shared.texture(id)
		if sprite != null:
			return sprite
		return texture("%s/%s.png" % [WEAPON_ICON_DIR, String(id)]) if id != &"" else null

	## [param icon] scaled to [param height], its left edge at [param at].x and centred on
	## [param at].y. Returns the width drawn.
	static func icon(canvas: CanvasItem, tex: Texture2D, at: Vector2, height: float, tint: Color = Color.WHITE, max_width: float = 9999.0) -> float:
		if tex == null:
			return 0.0
		var s := tex.get_size()
		var w := minf(s.x * height / maxf(s.y, 1.0), max_width)
		var h := w * s.y / maxf(s.x, 1.0)
		canvas.draw_texture_rect(tex, Rect2(at.x, at.y - h * 0.5, w, h), false, tint)
		return w


## The score strip with any number of sides: gs-ui's two plates for two, and for more a plate
## each, yours next to the clock and the rest alternating outwards, narrowed to fit this
## control's width (the tag goes first, then the plate shrinks to its number).
class TeamStrip extends GSScoreStrip:
	## Narrowest plate: a two-digit score still reads.
	const MIN_PLATE_W := 44.0
	## Below this a plate drops its tag.
	const TAG_PLATE_W := 80.0

	## `{tag, score, colour}` per side, yours first; empty, or two, is gs-ui's own strip.
	var teams: Array[Dictionary] = []

	## [param p_teams] as [member teams]; two or fewer go to [method GSScoreStrip.show_scores].
	func show_teams(p_teams: Array[Dictionary]) -> void:
		if p_teams.size() <= 2:
			if p_teams.size() == 2:
				show_scores(int(p_teams[0]["score"]), int(p_teams[1]["score"]), str(p_teams[0]["tag"]),
					str(p_teams[1]["tag"]), p_teams[0]["colour"], p_teams[1]["colour"])
			return
		if p_teams == teams and sides:
			return
		teams = p_teams.duplicate(true)
		sides = true
		queue_redraw()

	func show_scores(p_left: int, p_right: int, p_left_tag: String, p_right_tag: String, p_left_colour: Color, p_right_colour: Color) -> void:
		teams = []
		super(p_left, p_right, p_left_tag, p_right_tag, p_left_colour, p_right_colour)

	func hide_scores() -> void:
		teams = []
		super()

	## Each plate's width for [member teams]: what half this control's width leaves beside the clock, per plate on the fuller side.
	func plate_width() -> float:
		var per_side := ceili(float(teams.size()) * 0.5)
		var room := size.x * 0.5 - CLOCK_W * 0.5
		return clampf(room / float(per_side) - GAP, MIN_PLATE_W, PLATE_W)

	## Where the plate for [member teams] index [param i] goes: 0 left of the clock, 1 right, 2 outside 0, and on.
	func plate_rect(i: int) -> Rect2:
		var w := plate_width()
		var out := floorf(float(i) * 0.5)
		var mid := size.x * 0.5
		var x := mid - CLOCK_W * 0.5 - (GAP + w) * (out + 1.0) if i % 2 == 0 \
			else mid + CLOCK_W * 0.5 + GAP + (GAP + w) * out
		return Rect2(x, 0.0, w, H)

	func footprint() -> Rect2:
		var base := super()
		if not sides or teams.size() <= 2:
			return base
		# Either side of the clock as wide as the fuller one, as gs-ui's is: the line under it is centred too.
		var half := CLOCK_W * 0.5 + (GAP + plate_width()) * ceilf(float(teams.size()) * 0.5)
		var left := minf(size.x * 0.5 - half, base.position.x)
		return Rect2(left, 0.0, size.x - 2.0 * left, H + 28.0)

	func _draw() -> void:
		if teams.size() <= 2:
			super()
			return
		var narrow := plate_width() < TAG_PLATE_W
		for i in teams.size():
			var t: Dictionary = teams[i]
			_side(plate_rect(i), t["colour"], "" if narrow else str(t["tag"]), int(t["score"]))
		var keep := sides
		# The clock and the line under it are gs-ui's: drawn with the two plates switched off.
		sides = false
		super()
		sides = keep
		if clock == "":
			var clock_rect := Rect2(size.x * 0.5 - CLOCK_W * 0.5, 0.0, CLOCK_W, H)
			var plate := colour(&"plate")
			ink_plate(clock_rect, Color(plate, minf(plate.a + 0.2, 1.0)), 8, colour(&"plate_edge"), 1)

	func describe() -> Dictionary:
		var out := super()
		if teams.size() > 2:
			var scores: Array[int] = []
			for t in teams:
				scores.append(int(t["score"]))
			out["teams"] = scores
		return out


## Under the scores: every player ranked, a portrait each with their rank over it and their
## kills under it. Your own ring is gold; in a team mode the others are their side's colour.
## In a mode scored by objectives each face has two smaller numbers under it, an icon left of
## each: captures (a flag) over kills (a skull). Faces that do not fit the screen are dropped
## from the end, yours last.
class Portraits extends Control:
	const MAX_SHOWN := 10
	const SPACING := 50.0
	const RADIUS := 19.0
	const FLAG_ICON := "res://assets/medals/flag.png"
	const KILL_ICON := "res://assets/medals/skull.png"

	## `{texture, name, rank, kills, ring, me}` per player, best first; `objectives` too when
	## [member objective] is on.
	var entries: Array[Dictionary] = []
	## The mode is scored by objectives: show captures and kills, not kills alone.
	var objective: bool = false

	func show_players(p_entries: Array[Dictionary], p_objective: bool = false) -> void:
		entries = p_entries.slice(0, MAX_SHOWN)
		objective = p_objective
		queue_redraw()

	## How many faces fit across what the viewport shows of this control.
	func fits() -> int:
		var room := size.x
		if is_inside_tree():
			var inverse := get_global_transform().affine_inverse()
			var left := (inverse * Vector2.ZERO).x
			var right := (inverse * Vector2(get_viewport_rect().size.x, 0.0)).x
			room = minf(room, 2.0 * minf(size.x * 0.5 - left, right - size.x * 0.5))
		return clampi(int(floor((room - 60.0) / SPACING)) + 1, 1, MAX_SHOWN)

	## The entries drawn: the first that fit, with yours kept in the last place when it would fall off.
	func shown() -> Array[Dictionary]:
		var count := mini(entries.size(), fits())
		var out := entries.slice(0, count)
		if count < entries.size() and count > 0:
			for e in entries.slice(count):
				if bool(e.get("me", false)):
					out[count - 1] = e
					break
		return out

	func _height() -> float:
		# 25, not more: at 1280x720 the medal row starts at 152, a pixel under this row.
		return 14.0 + RADIUS * 2.0 + (25.0 if objective else 21.0)

	## The rank over the first face to the numbers under the last.
	func footprint() -> Rect2:
		var count := shown().size()
		if count == 0:
			return Rect2()
		var first := size.x * 0.5 - SPACING * float(count - 1) * 0.5
		return Rect2(first - 30.0, 0.0, SPACING * float(count - 1) + 60.0, _height())

	func _draw() -> void:
		var drawn := shown()
		var count := drawn.size()
		if count == 0:
			return
		var first := size.x * 0.5 - SPACING * float(count - 1) * 0.5
		for i in range(count):
			var e: Dictionary = drawn[i]
			var c := Vector2(first + SPACING * float(i), 14.0 + RADIUS)
			var me := bool(e.get("me", false))
			var ring: Color = Ink.c(self, &"highlight") if me else e.get("ring", Color(1, 1, 1, 0.85))
			Ink.text(self, Vector2(c.x - 30.0, 11.0), "#%d" % int(e.get("rank", i + 1)), 11,
				Ink.c(self, &"highlight") if me else Color(Ink.c(self, &"text"), 0.95), HORIZONTAL_ALIGNMENT_CENTER, 60.0, 3)
			draw_circle(c + Vector2(0.0, 2.0), RADIUS + 3.0, Color(0, 0, 0, 0.35))
			draw_circle(c, RADIUS + 2.5, ring)
			var back: Color = e.get("colour", Color(0.3, 0.34, 0.45))
			draw_circle(c, RADIUS, back.darkened(0.25))
			var tex: Texture2D = e.get("texture", null)
			if tex != null:
				var side := RADIUS * 2.0
				draw_texture_rect(tex, Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side)), false)
			else:
				var initials := str(e.get("name", "?")).substr(0, 2).to_upper()
				Ink.text(self, c + Vector2(-RADIUS, 6.0), initials, 15, Ink.c(self, &"text"), HORIZONTAL_ALIGNMENT_CENTER, RADIUS * 2.0, 4)
			var ink: Color = Ink.c(self, &"highlight") if me else Ink.c(self, &"text")
			if objective:
				_stat(Vector2(c.x, c.y + RADIUS + 9.0), Ink.texture(FLAG_ICON), int(e.get("objectives", 0)), ink)
				_stat(Vector2(c.x, c.y + RADIUS + 20.0), Ink.texture(KILL_ICON), int(e.get("kills", 0)), Color(ink, 0.85))
			else:
				Ink.text(self, Vector2(c.x - 30.0, c.y + RADIUS + 17.0), str(int(e.get("kills", 0))), 14,
					ink, HORIZONTAL_ALIGNMENT_CENTER, 60.0, 4)

	## A small icon and its number, centred together on [param mid].x with [param mid].y the middle of the line.
	func _stat(mid: Vector2, tex: Texture2D, value: int, ink: Color) -> void:
		const ICON_H := 10.0
		var words := str(value)
		var w := ICON_H + 3.0 + Ink.width(words, 11)
		var x := mid.x - w * 0.5
		if tex != null:
			# A dark copy a pixel down and right: a white icon over a pale wall.
			draw_texture_rect(tex, Rect2(x + 1.0, mid.y - ICON_H * 0.5 + 1.0, ICON_H, ICON_H), false, Color(0, 0, 0, 0.7 * ink.a))
			Ink.icon(self, tex, Vector2(x, mid.y), ICON_H, Color(1, 1, 1, ink.a))
		Ink.text(self, Vector2(x + ICON_H + 3.0, mid.y + 4.0), words, 11, ink, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 3)


## Top right: who killed whom, with the weapon's silhouette between the names, on a plate
## per line. A line you are in has a gold edge. Newest at the top; each fades after
## [member lifetime_sec].
class KillFeed extends Control:
	# 28 + 3, not 30 + 4: three rows from a 16 px inset end at 106, above the client shell's
	# column at 110 (`FcHud.feed_lines_clear`); at 34 a row the third ran 4 px under it.
	const ROW_H := 28.0
	const ROW_GAP := 3.0
	const ICON_H := 20.0
	const NAME_SIZE := 15
	const FADE_SEC := 0.6

	var max_lines: int = 5
	var lifetime_sec: float = 6.0
	var entries: Array[Dictionary] = []

	func add_kill(
		killer: String, killer_colour: Color, weapon_id: StringName, weapon_text: String,
		victim: String, victim_colour: Color, headshot: bool = false, involved: bool = false
	) -> void:
		entries.push_front({
			"killer": killer, "killer_colour": killer_colour, "weapon": weapon_id,
			"weapon_text": weapon_text, "victim": victim, "victim_colour": victim_colour,
			"headshot": headshot, "involved": involved, "age": 0.0,
		})
		while entries.size() > max_lines:
			entries.pop_back()
		queue_redraw()

	func line_count() -> int:
		return entries.size()

	func clear() -> void:
		entries.clear()
		queue_redraw()

	func advance(delta: float) -> void:
		if lifetime_sec <= 0.0 or entries.is_empty():
			return
		# Redraw only while a row fades or leaves: a steady feed was redrawn every frame (0.32 ms).
		var changed := false
		for i in range(entries.size() - 1, -1, -1):
			var age := float(entries[i]["age"]) + delta
			entries[i]["age"] = age
			if age >= lifetime_sec:
				entries.remove_at(i)
				changed = true
			elif age > lifetime_sec - FADE_SEC:
				changed = true
		if changed:
			queue_redraw()

	func _draw() -> void:
		FcWeaponIcons.shared.filter(self)
		var y := 0.0
		for e in entries:
			var fade := 1.0 if lifetime_sec <= 0.0 else clampf((lifetime_sec - float(e["age"])) / FADE_SEC, 0.0, 1.0)
			_row(e, y, fade)
			y += ROW_H + ROW_GAP

	## Names longer than this are cut with an ellipsis, so a line never reaches the portraits
	## at the top centre on a 1280-wide screen.
	const NAME_MAX := 14

	static func _short(name: String) -> String:
		return name if name.length() <= NAME_MAX else name.substr(0, NAME_MAX - 1) + "…"

	## Every row's plate, right-aligned, newest at the top.
	func footprint() -> Rect2:
		var out := Rect2()
		var y := 0.0
		for e in entries:
			var w := _inner(e) + PAD * 2.0
			var row := Rect2(size.x - w, y, w, ROW_H)
			out = row if not out.has_area() else out.merge(row)
			y += ROW_H + ROW_GAP
		return out

	const PAD := 10.0

	## A row's width inside its padding: killer, weapon, headshot mark, victim.
	static func _inner(e: Dictionary) -> float:
		var tex := Ink.weapon_icon(e["weapon"])
		var killer := _short(str(e["killer"]))
		var killer_w := Ink.width(killer, NAME_SIZE) if killer != "" else 0.0
		var victim_w := Ink.width(_short(str(e["victim"])), NAME_SIZE)
		var icon_w := 0.0
		if tex != null:
			icon_w = minf(tex.get_size().x * ICON_H / maxf(tex.get_size().y, 1.0), 64.0)
		else:
			icon_w = Ink.width("[%s]" % str(e["weapon_text"]), 13)
		var head_w := 22.0 if bool(e["headshot"]) else 0.0
		return killer_w + (10.0 if killer != "" else 0.0) + icon_w + head_w + 10.0 + victim_w

	func _row(e: Dictionary, y: float, fade: float) -> void:
		var tex := Ink.weapon_icon(e["weapon"])
		var killer := _short(str(e["killer"]))
		var victim := _short(str(e["victim"]))
		var killer_w := Ink.width(killer, NAME_SIZE) if killer != "" else 0.0
		var head := Ink.texture("res://assets/medals/target.png") if bool(e["headshot"]) else null
		var pad := PAD
		var inner := _inner(e)
		var rect := Rect2(size.x - inner - pad * 2.0, y, inner + pad * 2.0, ROW_H)
		var involved := bool(e["involved"])
		Ink.plate(self, rect, Color(Ink.c(self, &"plate"), Ink.c(self, &"plate").a * fade), 6,
			Color(Ink.c(self, &"highlight"), 0.95 * fade) if involved else Color(Ink.c(self, &"plate_edge"), Ink.c(self, &"plate_edge").a * fade), 2 if involved else 1)
		var x := rect.position.x + pad
		var base := y + ROW_H * 0.5 + NAME_SIZE * 0.36
		if killer != "":
			Ink.text(self, Vector2(x, base), killer, NAME_SIZE, Color(e["killer_colour"], fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)
			x += killer_w + 10.0
		if tex != null:
			FcWeaponIcons.shared.halo(self, e["weapon"], Vector2(x, y + ROW_H * 0.5), ICON_H, fade, 64.0)
			x += Ink.icon(self, tex, Vector2(x, y + ROW_H * 0.5), ICON_H, Color(1, 1, 1, fade), 64.0)
		else:
			Ink.text(self, Vector2(x, base), "[%s]" % str(e["weapon_text"]), 13, Color(Ink.c(self, &"dim"), fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 3)
			x += Ink.width("[%s]" % str(e["weapon_text"]), 13)
		if head != null:
			draw_texture_rect(head, Rect2(x + 4.0, y + ROW_H * 0.5 - 8.0, 16.0, 16.0), false, Color(1.0, 0.45, 0.3, fade))
			x += 22.0
		x += 10.0
		Ink.text(self, Vector2(x, base), victim, NAME_SIZE, Color(e["victim_colour"], fade), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 4)


## The right edge: one silhouette per weapon carried, with the number that selects it.
## The one in hand is bright and larger; the rest wait dimmed.
class WeaponSlots extends GSLoadoutBar:
	const ROW_H := 40.0
	## The tightest pitch a row is drawn at under a ballot: a 24 px plate, which the 22 px
	## keycap and the 24 px current-weapon icon still fit in.
	const MIN_ROW_H := 30.0
	## Between a row's plate and the next one, at every pitch.
	const PLATE_GAP := 6.0
	## Between the top plate and whatever covers the box above it.
	const COVER_GAP := 6.0

	## `{slot, id, name, key}` per carried slot, in slot order; `key` is the key it is bound
	## to (the slot's number when absent).
	var rows: Array[Dictionary] = []
	var current: int = 0

	## [b]Where something on top of this box ends[/b], in this box's own coordinates: the
	## client shell's ballot down the right edge, which a seven-row map ballot carries over
	## the top slots at 1280x720. -INF while nothing covers it. Written by
	## [method FcHud.make_room] every frame; the rows tighten from [constant ROW_H] towards
	## [constant MIN_ROW_H] to stay under it, and past that only the rows around the current
	## one are drawn, which is the one a player is looking for.
	var cover_bottom: float = -INF

	## A picture that had not loaded when the rows were handed over; the bar is rebuilt until it has.
	var _icons_pending := false

	## The slot dictionaries handed to the bar, reused: the bar copies them, so a rebuild allocates no array.
	var _scratch: Array = []

	func _init() -> void:
		super._init()
		set_layout(GSLoadoutBar.Layout.STACK)
		stack_foot = ROW_H * 0.5

	func show_slots(p_rows: Array[Dictionary], p_current: int) -> void:
		if p_current != current or p_rows.size() != rows.size() or str(p_rows) != str(rows):
			rows.assign(p_rows)
			current = p_current
			_sync()

	## Moves the top of the room the rows have; a redraw only on a change.
	func set_cover_bottom(y: float) -> void:
		if not is_equal_approx(y, cover_bottom) and not (is_inf(y) and is_inf(cover_bottom)):
			cover_bottom = y
			_sync()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_sync()

	func _process(delta: float) -> void:
		super._process(delta)
		if _icons_pending:
			_sync()

	## Hands the generic bar the rows [method layout] picked, at the pitch it picked.
	func _sync() -> void:
		var laid := layout()
		_icons_pending = false
		_scratch.clear()
		for r in laid["rows"]:
			var tex := Ink.weapon_icon(r["id"])
			_icons_pending = _icons_pending or tex == null
			_scratch.append({"key": r["key"] if r.has("key") else r["slot"], "icon": tex, "name": r["name"], "id": r["id"], "selected": int(r["slot"]) == current})
		set_stack_pitch(float(laid["pitch"]))
		set_slots(_scratch)

	func _draw() -> void:
		FcWeaponIcons.shared.filter(self)
		super._draw()

	## FC's white-gun halo, behind the picture the generic bar draws.
	func _stack_backdrop(slot: Dictionary, at: Vector2, height: float, alpha: float, max_width: float) -> void:
		FcWeaponIcons.shared.halo(self, slot["id"], at, height, alpha, max_width)

	## `{rows, pitch}`: the rows drawn, bottom-most last, and the pitch they are drawn at. All
	## of them at [constant ROW_H] while nothing covers the box; the bottom row's centre never
	## moves (it sits on the ammunition counter).
	func layout() -> Dictionary:
		var count := rows.size()
		if count == 0 or is_inf(cover_bottom):
			return {"rows": rows, "pitch": ROW_H}
		# The top plate (pitch - PLATE_GAP tall) has to end above the bottom row's centre by
		# no more than `room`: (count - 1) * pitch + (pitch - PLATE_GAP) / 2 <= room.
		var room := (size.y - ROW_H * 0.5) - (cover_bottom + COVER_GAP)
		var pitch := minf(ROW_H, (room + PLATE_GAP * 0.5) / (float(count) - 0.5))
		if pitch >= MIN_ROW_H:
			return {"rows": rows, "pitch": pitch}
		# Not even at the tightest pitch: the run of rows that fits, with the current one in it.
		var fit := mini(int(floor((room + PLATE_GAP * 0.5) / MIN_ROW_H + 0.5)), count)
		if fit <= 0:
			return {"rows": [] as Array[Dictionary], "pitch": MIN_ROW_H}
		var at := 0
		for i in count:
			if int(rows[i]["slot"]) == current:
				at = i
		var first := clampi(at - int(float(fit) / 2.0), 0, count - fit)
		return {"rows": rows.slice(first, first + fit), "pitch": MIN_ROW_H}


## Bottom centre: one button per movement ability, its key under it. A charging one is
## darkened from the top by what is left and says the seconds; a ready one is bright; one
## in use (a slide, a wall run) has a gold edge. The wall jump shows its jumps left in the
## air as pips.
class AbilityBar extends GSLoadoutBar:
	## `{id, label, icon, key, left, total, active, pips, pips_max}`, left to right.
	var buttons: Array[Dictionary] = []

	func _init() -> void:
		super._init()
		set_layout(GSLoadoutBar.Layout.BUTTONS)

	func show_buttons(p_buttons: Array[Dictionary]) -> void:
		# Called every frame with a fresh array: redraw only when a button's state differs.
		if p_buttons == buttons:
			return
		buttons = p_buttons
		var slots: Array = []
		for b in buttons:
			slots.append({"key": str(b["key"]), "icon": b.get("icon", null), "name": str(b["label"]).substr(0, 5).to_upper(),
				"left": b["left"], "total": b["total"], "active": b["active"], "pips": b.get("pips", 0), "pips_max": b.get("pips_max", 0)})
		set_slots(slots)

	## One button as a line of words: "E  LAUNCH" when ready, "E  5.5" while it charges.
	## What a suite reads.
	func line(id: StringName) -> String:
		for b in buttons:
			if b["id"] == id:
				var left := float(b["left"])
				return "%s  %s" % [b["key"], str(b["label"]).to_upper() if left <= 0.0 else "%.1f" % left]
		return ""

	func has(id: StringName) -> bool:
		return line(id) != ""


## The ranked row's avatar heads (in `fc_hud_portrait_cache.gd`).
const PortraitCache := preload("fc_hud_portrait_cache.gd")
