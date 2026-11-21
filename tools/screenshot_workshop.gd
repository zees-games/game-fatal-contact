extends SceneTree

const FcMaps := preload("../game/fc_maps.gd")
const FcMenus := preload("../game/fc_menus.gd")
const FcModes := preload("../game/fc_modes.gd")
const FcPresentation := preload("../game/fc_presentation.gd")

## The solo map menu (M) with a Workshop map in it, to screenshots/menu_maps_workshop.png.
##
## The map is a fixture in a [GSContentIndex] this script fills, so the rows are the ones
## `FcMaps.menu_rows` makes from a catalogue that followed it; nothing is drawn by hand.
## Run: `xvfb-run -a godot --path . --resolution 1280x800 --script tools/screenshot_workshop.gd`.
## Not `--headless`: a null renderer saves empty frames.

const OUT := "res://screenshots/menu_maps_workshop.png"
const SETTLE := 6

var _menu: GSMenu = null
var _presentation: FcPresentation = null
var _wait := SETTLE
var _opened := false
## Frame sequence after the still (GS_SHOT_FRAMES); see GSShotSeq.
var _seq := GSShotSeq.new()
var _seq_active := false


func _process(_delta: float) -> bool:
	if _menu == null:
		GSLog.set_level(GSLog.Level.ERROR)
		var _scratch := FcPresentation.use_scratch_settings("screenshot_workshop")
		DirAccess.make_dir_recursive_absolute("res://screenshots")
		DirAccess.make_dir_recursive_absolute("user://workshop_shot")
		var doc := FileAccess.open("user://workshop_shot/hill.json", FileAccess.WRITE)
		doc.store_string(JSON.stringify({"schema": 1, "id": "fixture_hill", "name": "Fixture Hill",
			"boxes": [[-4, 0, -4, 8, 1, 8]], "spawns": [{"at": [-14, 0.1, 0], "yaw": 270}]}))
		doc.close()
		var index := GSContentIndex.new()
		index.set_session(GSContentIndex.SESSION_SOLO)
		var _added := index.add_pack({
			"content_id": "fixture/hills", "version": "1.0.0", "prefix": "user://workshop_shot/",
			"session": GSContentIndex.SESSION_SOLO, "source": &"subscription",
			"provides": {"schema": 1, "title": "Hilltop Pack", "kinds": ["map"], "entries": [
				{"kind": "map", "id": "fixture_hill", "name": "Fixture Hill", "scene": "hill.json", "map_kind": "arena"},
				{"kind": "map", "id": "fixture_run", "name": "Fixture Run", "scene": "run.json", "map_kind": "surf"},
			]},
		})
		var catalogue := FcMaps.catalogue(index)
		_presentation = FcPresentation.new()
		root.add_child(_presentation)
		var _set_up := _presentation.setup()
		_menu = FcMenus.build(root, _presentation, null)
		var rows := FcMaps.menu_rows(catalogue, &"dm_box", null, FcModes.all())
		var _maps := _menu.use_maps(func() -> Array: return rows, func(_id: StringName) -> GSResult: return GSResult.success(null))
		return false
	if not _opened:
		_menu.open_maps()
		# The game's own maps come first, so a pack's are at the end of the maps, one page before the modes.
		_menu.picker.turn(99)
		_menu.picker.turn(-1)
		_opened = true
	if _wait > 0:
		_wait -= 1
		return false
	if _seq_active:
		return not _seq.step(root)
	var image := root.get_texture().get_image()
	image.save_png(OUT)
	print("wrote %s (%d x %d)" % [OUT, image.get_width(), image.get_height()])
	if _seq.enabled():
		_seq.begin(OUT)
		_seq_active = true
		return false
	return true
