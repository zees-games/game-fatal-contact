extends GSGameCheckSuite

## Solo's lazy map packs (FcMaps.mount_delivered / FcMaps.predownload) against a file-served catalogue: a fake
## gs-cloud copies pack folders from a source directory, as the CDN would serve them, and counts every fetch.
## Picking a map fetches only its pack; the other packs are not asked for; a pack that is not published fails
## loudly, names the map, and is never replaced by another map; the `predownload_maps` override fetches the rest.
## The web and native paths share GSMapLoader.ensure_content, so this one suite covers both.
##
## [codeblock]
## ./game.sh test headless_solo_lazy_packs
## [/codeblock]

const FcImportedMaps := preload("../maps/fc_imported_maps.gd")
const FcMaps := preload("../game/fc_maps.gd")

const EXPECTED_CHECKS := 25
const SOURCE := "user://headless_solo_lazy_packs"
const IDS: Array[StringName] = [&"lazy-a", &"lazy-b", &"lazy-c"]
const GONE: Array[StringName] = [&"lazy-gone", &"lazy-gone2"]


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	FcMaps.clear_dead()
	_clean()
	for id in IDS:
		_write_pack(id)

	var cdn := _FileCdn.new()
	cdn.source = SOURCE
	GSRegistry.register(GSMapLoader.CLOUD_SERVICE, cdn)

	print("-- listing the maps fetches nothing")
	var cat := GSMapCatalogue.new()
	var keys := PackedStringArray()
	for id in IDS + GONE:
		keys.append("gamemann/%s@1.0.0" % id)
	var _adopted := FcMaps.adopt_delivered(cat, keys)
	for id in IDS + GONE:
		_check(cat.get_map(id) != null and FcMaps.is_delivered(cat.get_map(id)), "%s is listed as a delivered map" % id)
	_check(cdn.asked.is_empty(), "no pack is asked for by listing", ", ".join(cdn.asked))

	print("-- picking one map fetches only its pack")
	var picked := await FcMaps.mount_delivered(cat.get_map(&"lazy-a"), GSMapLoader.new(), cat, true)
	_check(picked.ok, "lazy-a is fetched and mounted", picked.error.message if not picked.ok else "")
	_check(cdn.asked == PackedStringArray(["gamemann/lazy-a@1.0.0"]), "only lazy-a's pack was asked for", ", ".join(cdn.asked))
	_check(FcImportedMaps.is_mounted(&"lazy-a") and not FcImportedMaps.is_mounted(&"lazy-b") and not FcImportedMaps.is_mounted(&"lazy-c"),
		"only lazy-a is mounted")
	var again := await FcMaps.mount_delivered(cat.get_map(&"lazy-a"), GSMapLoader.new(), cat, true)
	_check(again.ok and cdn.asked.size() == 1, "picking it again fetches nothing more")

	print("-- a missing pack fails loudly and falls back to nothing")
	var before := cdn.asked.size()
	var gone := await FcMaps.mount_delivered(cat.get_map(&"lazy-gone"), GSMapLoader.new(), cat, true)
	_check(not gone.ok and gone.error.message.contains("could not fetch the map lazy-gone"), "the failure names the map",
		gone.error.message if not gone.ok else "ok")
	_check(cat.get_map(&"lazy-gone") == null, "the missing map leaves the list")
	_check(cat.get_map(&"lazy-b") != null and cat.get_map(&"lazy-c") != null and cat.get_map(&"lazy-a") != null,
		"the other maps stay listed")
	_check(not FcImportedMaps.is_mounted(&"lazy-b") and not FcImportedMaps.is_mounted(&"lazy-c"),
		"no other map was mounted in its place")
	_check(cdn.asked.size() > before and not cdn.asked.has("gamemann/lazy-b@1.0.0") and not cdn.asked.has("gamemann/lazy-c@1.0.0"),
		"only the missing pack was asked for", ", ".join(cdn.asked))

	print("-- the pre-download override fetches every pack not here yet")
	cdn.asked = PackedStringArray()
	var seen: Array[StringName] = []
	var progress := func(id: StringName, _done: int) -> void:
		seen.append(id)
	var out: Dictionary = await FcMaps.predownload(cat, GSMapLoader.new(), true, progress)
	var fetched: Array = out["fetched"]
	var failed: Dictionary = out["failed"]
	_check(fetched.has(&"lazy-b") and fetched.has(&"lazy-c") and fetched.size() == 2, "lazy-b and lazy-c are fetched", str(fetched))
	_check(FcImportedMaps.is_mounted(&"lazy-b") and FcImportedMaps.is_mounted(&"lazy-c"), "both are mounted")
	_check(failed.has(&"lazy-gone2") and str(failed[&"lazy-gone2"]).length() > 0, "the unpublished pack is reported", str(failed))
	_check(cat.get_map(&"lazy-gone2") == null and cat.get_map(&"lazy-b") != null, "the failed pack leaves the list, the rest stay")
	_check(not cdn.asked.has("gamemann/lazy-a@1.0.0"), "the already mounted pack is not fetched again")
	_check(seen.size() == 3 and seen.has(&"lazy-b") and seen.has(&"lazy-c"), "progress is reported before each fetch", str(seen))
	cdn.asked = PackedStringArray()
	var second: Dictionary = await FcMaps.predownload(cat, GSMapLoader.new(), true)
	_check((second["fetched"] as Array).size() == 3 and (second["failed"] as Dictionary).is_empty() and cdn.asked.is_empty(),
		"a second pre-download fetches nothing and fails nothing")

	print("-- the setting is declared, off by default")
	var setup := FileAccess.get_file_as_string("res://game/fc_presentation_setup.gd")
	_check(setup.contains("GSSettingsDef.boolean(&\"predownload_maps\", false"), "predownload_maps is a boolean setting, default off")
	var view := FileAccess.get_file_as_string("res://game/fc_client_view.gd")
	_check(view.contains("predownload_wanted()") and view.contains("FcMaps.predownload("), "the client view runs the override")

	GSRegistry.unregister(GSMapLoader.CLOUD_SERVICE)
	for id in IDS:
		FcImportedMaps.remove_mounted(id)
	_clean()
	FcMaps.clear_dead()
	_report_sections(5, 5, 5, EXPECTED_CHECKS)


func _write_pack(id: StringName) -> void:
	var dir := SOURCE.path_join(String(id))
	var _m := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var doc := FileAccess.open(dir.path_join("%s.json" % id), FileAccess.WRITE)
	doc.store_string(JSON.stringify({"id": String(id), "kind": "arena", "surfaces": []}))
	doc.close()
	var mesh := FileAccess.open(dir.path_join("%s.bin" % id), FileAccess.WRITE)
	mesh.store_8(0)
	mesh.close()


func _clean() -> void:
	for root in [SOURCE, "res://gs_cloud/gamemann"]:
		for id in IDS + GONE:
			var dirs: Array[String] = [root.path_join(String(id)), root.path_join(String(id)).path_join("1.0.0")]
			for dir in dirs:
				for file in DirAccess.get_files_at(dir):
					var _r := DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(file)))
				var _d := DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


## A gs-cloud stand-in serving pack folders from a directory: copies `<source>/<id>` to the version's mount, or
## answers 404 when the directory is not there (an unpublished pack). Counts every ask.
class _FileCdn extends RefCounted:
	var source := ""
	var asked := PackedStringArray()

	func latest_version(_id: String) -> String:
		return ""

	func ensure(id: StringName, version: String, _groups: Variant = null, _url: String = "") -> GSResult:
		asked.append("%s@%s" % [id, version])
		var from := source.path_join(String(id).get_file())

		if DirAccess.open(from) == null:
			return GSResult.failure(GSError.from_http(404)).wrap("Could not download the content manifest.")

		var to := "res://gs_cloud/%s/%s" % [id, version]
		var _m := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(to))

		for file in DirAccess.get_files_at(from):
			var _c := DirAccess.copy_absolute(from.path_join(file), to.path_join(file))

		return GSResult.success(to)
