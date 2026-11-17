extends RefCounted
## How the FC HUD feedback is drawn: fonts, icons, colours, outlined text. Its own file (it was an
## inner class of arena_hud_base.gd) because the HUD's own functions called it, and an outer script
## naming its inner class from a function body made the parser depend on itself: a cycle GDScript
## never frees (CI perf-smoke mem_mb). The HUD and its widgets reach it as `Look`.

const ArenaAwards := preload("arena_awards.gd")
const ArenaHudGlance := preload("arena_hud_glance.gd")
const ArenaPaths := preload("arena_paths.gd")


## Where the medal icons are (Kenney's CC0 icons, `assets/medals/`), through the rebase.
const MEDAL_ICON_DIR := "res://assets/medals"

static var _icons: Dictionary = {}
static var _fonts: Dictionary = {}


## The fallback font, bold, and slanted when [param italic]: what every feedback line is
## drawn in. The genre's medal names and streak count are bold italic, and the theme's
## regular weight read as a debug overlay beside them (first render).
static func feedback_font(italic: bool = false) -> Font:
	if not _fonts.has(italic):
		var font := FontVariation.new()
		font.base_font = ThemeDB.fallback_font
		font.variation_embolden = 0.9
		if italic:
			font.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(-0.22, 1.0), Vector2.ZERO)
		_fonts[italic] = font
	return _fonts[italic]


## A medal icon by file name, or null when the art is missing: the badge still draws.
static func medal_icon(file: String) -> Texture2D:
	if not _icons.has(file):
		var at := ArenaPaths.rebase("%s/%s.png" % [MEDAL_ICON_DIR, file])
		_icons[file] = load(at) as Texture2D if ResourceLoader.exists(at) else null
	return _icons[file]


## What each medal looks like: an icon file and a colour. The server's [ArenaAwards] says
## what a medal is called and what it is worth; this is only how it is drawn.
static func medal_look(medal: int) -> Array:
	match medal:
		ArenaAwards.Medal.FIRST_BLOOD: return ["splat", Color(0.86, 0.12, 0.18)]
		ArenaAwards.Medal.HEADSHOT: return ["target", Color(1.0, 0.33, 0.2)]
		ArenaAwards.Medal.DOUBLE_KILL: return ["skull", Color(1.0, 0.62, 0.1)]
		ArenaAwards.Medal.TRIPLE_KILL: return ["skull", Color(1.0, 0.45, 0.1)]
		ArenaAwards.Medal.MULTI_KILL: return ["skull", Color(0.95, 0.25, 0.55)]
		ArenaAwards.Medal.REVENGE: return ["sword", Color(0.78, 0.1, 0.32)]
		ArenaAwards.Medal.SHUTDOWN: return ["fire", Color(0.2, 0.52, 1.0)]
		ArenaAwards.Medal.POINT_BLANK: return ["arrows", Color(0.55, 0.36, 1.0)]
		ArenaAwards.Medal.NO_SCOPE: return ["zoom_out", Color(0.0, 0.7, 0.62)]
		ArenaAwards.Medal.LONG_SHOT: return ["arrow", Color(0.16, 0.7, 0.96)]
		ArenaAwards.Medal.NEMESIS: return ["skull_tile", Color(0.42, 0.12, 0.6)]
	return ["", Color(0.5, 0.5, 0.5)]


## Text with a dark outline, the way every piece of feedback is drawn over a bright map.
static func draw_outlined(
	canvas: CanvasItem, font: Font, at: Vector2, text: String, font_size: int, colour: Color,
	outline: int = 6, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0
) -> void:
	var ink := ArenaHudGlance.Ink.c(canvas, &"ink")
	canvas.draw_string_outline(
		font, at, text, align, width, font_size, outline, Color(ink, ink.a * colour.a)
	)
	canvas.draw_string(font, at, text, align, width, font_size, colour)
