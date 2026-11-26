extends RefCounted
## The collision box of each weapon's dropped body, remembered so a server does not load every weapon model (80 to 1800 ms each,
## 9.5 s for the set on PH) to measure it. Kept for the process and in a file keyed by what the box depends on, so only a weapon whose
## art or model file changed is loaded again.

const PATH := "user://fc_drop_fits.json"
## Bump when the way a fit is measured changes: every saved box is then dropped.
## 2: boxes from a model that failed to load (the no-model default) were kept under a good signature; drop them all.
const FORMAT := 2

## StringName -> {sig, fit: [size, centre]}; loaded from the file once per process.
static var _book: Dictionary = {}
static var _loaded := false
static var _dirty := false


## What the box of [param id] was measured from: the art's saved fields and the model file's size and age (its import marker's, when the pack ships no source). "" when nothing says so.
static func signature(id: StringName) -> String:
	var art: Variant = AwWeaponArtTable.table().get(id)
	if not (art is AwWeaponVisual):
		return ""
	var text := "%d|" % FORMAT
	for prop: Dictionary in (art as AwWeaponVisual).get_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_STORAGE and int(prop["type"]) != TYPE_OBJECT:
			text += "%s=%s;" % [prop["name"], str((art as AwWeaponVisual).get(prop["name"]))]
	var path: String = AwModelCache.resolve((art as AwWeaponVisual).model_path)
	for file: String in [path, path + ".import"]:
		if FileAccess.file_exists(file):
			return (text + "%s|%d|%d" % [file, FileAccess.get_size(file), FileAccess.get_modified_time(file)]).md5_text()
	return ""


## The remembered fit [size, centre] of [param id] when its [param sig] still matches, else [].
static func recall(id: StringName, sig: String) -> Array:
	_load()
	var entry: Variant = _book.get(id)
	if sig != "" and entry is Dictionary and entry["sig"] == sig:
		return entry["fit"]
	return []


## Remembers a fit measured for [param id] under [param sig].
static func keep(id: StringName, sig: String, fit: Array) -> void:
	if sig == "" or fit.size() < 2:
		return
	_book[id] = {"sig": sig, "fit": fit}
	_dirty = true


## Writes the book when something was kept since the last write; a failed write only costs the next boot its measuring.
static func save() -> void:
	if not _dirty:
		return
	_dirty = false
	var out := {}
	for id: StringName in _book:
		var fit: Array = _book[id]["fit"]
		var size: Vector3 = fit[0]
		var centre: Vector3 = fit[1]
		out[str(id)] = {"sig": _book[id]["sig"], "size": [size.x, size.y, size.z], "centre": [centre.x, centre.y, centre.z]}
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(out))


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (parsed is Dictionary):
		return
	for id: String in parsed:
		var e: Variant = parsed[id]
		if e is Dictionary and e.get("size") is Array and e.get("centre") is Array and (e["size"] as Array).size() == 3 and (e["centre"] as Array).size() == 3:
			var s: Array = e["size"]
			var c: Array = e["centre"]
			_book[StringName(id)] = {"sig": str(e.get("sig", "")), "fit": [Vector3(s[0], s[1], s[2]), Vector3(c[0], c[1], c[2])]}
