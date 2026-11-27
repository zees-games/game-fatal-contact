extends Node

## What a web client compiles before its first frame, measured natively: the set gs-cloud's warm compiles when the pack
## ships no warm.txt (every pack script outside tooling dirs + every addon class any of them names) against the scripts
## loading the client scene really compiles. Run each mode in a fresh process; the browser costs ~10x the native ms.
## `godot --headless --path . res://tools/script_warm_cost.tscn -- --mode warm|scene|scene_then_warm|list [--dump <file>]`
## `list` compiles what the cover waits for when the pack ships warm.txt (gs-cloud API 39: the rest compile at first use).
## `scene_then_warm` times the part of the warm the scene never needed; `--dump` writes the scripts cached after the
## scene in warm.txt form (GSCloudSliceLoader.cached_scripts); `--dump -` prints them as `WARM_LIST <path>` lines
## (a box hv offloads to keeps no files).

const SKIP_DIRS := ["tools", "examples", "tests", "ci", "addons"]
const CLIENT_SCENE := "res://game/fc.tscn"


func _ready() -> void:
	var mode := "warm"
	var dump := ""
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--mode":
				mode = args[i + 1]
			"--dump":
				dump = args[i + 1]
	var scene_ms := 0
	var warm_ms := 0
	var warm_count := 0
	if mode in ["scene", "scene_then_warm"]:
		var t0 := Time.get_ticks_msec()
		var scene := load(CLIENT_SCENE)
		scene_ms = Time.get_ticks_msec() - t0
		if scene == null:
			push_error("script_warm_cost: %s did not load" % CLIENT_SCENE)
	var at_scene := GSCloudSliceLoader.cached_scripts("res://", [".godot"]).size()
	if dump == "-":
		for path in GSCloudSliceLoader.cached_scripts("res://", SKIP_DIRS.slice(0, 4)):
			print("WARM_LIST ", path)
	elif dump != "":
		var f := FileAccess.open(dump, FileAccess.WRITE)
		for path in GSCloudSliceLoader.cached_scripts("res://", SKIP_DIRS.slice(0, 4)):
			f.store_line(path)
		f.close()
	if mode == "list":
		var t2 := Time.get_ticks_msec()
		for line in FileAccess.get_file_as_string("res://warm.txt").split("\n"):
			var path := "res://" + line.split("#", true, 1)[0].strip_edges()
			if path.get_extension() == "gd" and not ResourceLoader.has_cached(path) and ResourceLoader.exists(path):
				warm_count += 1
				load(path)
		warm_ms = Time.get_ticks_msec() - t2
	if mode in ["warm", "scene_then_warm"]:
		var pack := PackedStringArray()
		_walk("res://", pack)
		var order := GSCloudSliceLoader.named_class_scripts(pack) + pack
		var t1 := Time.get_ticks_msec()
		for path in order:
			if not ResourceLoader.has_cached(path):
				warm_count += 1
				load(path)
		warm_ms = Time.get_ticks_msec() - t1
	var total := GSCloudSliceLoader.cached_scripts("res://", [".godot"]).size()
	print("SCRIPT_WARM mode=%s scene_ms=%d scripts_after_scene=%d warm_ms=%d warm_compiled=%d scripts_total=%d" % [
		mode, scene_ms, at_scene, warm_ms, warm_count, total])
	get_tree().quit()


## Every .gd outside the tooling dirs and addons, as gs-cloud's warm walks a pack.
func _walk(dir: String, out: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "gd":
			out.append(dir + f)
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with(".") and not SKIP_DIRS.has(d):
			_walk(dir + d + "/", out)
