extends RefCounted
## Reaching addon API that is newer than the client shell's pinned addons, without naming it where the parser looks.
## The web shell carries its own addons (gs-server-deploy's addons.lock tags), usually some levels behind the linked
## heads. A script that names a newer static function, constant or class directly does not compile there, and every
## script that depends on it fails with it: on 2026-11-16 the bot brain and the HUD failed that way on Gamespice
## and bots stood still. Callers check `GSAddonApi.build_level(...)` first and reach the newer API through these.

static var _scripts: Dictionary = {}


## The script registered as global class [param class_id], or null when this build has no such class.
static func script_of(class_id: StringName) -> Script:
	if _scripts.has(class_id):
		return _scripts[class_id]
	var found: Script = null
	for entry in ProjectSettings.get_global_class_list():
		if StringName(entry.get("class", "")) == class_id:
			found = load(str(entry.get("path", ""))) as Script
			break
	_scripts[class_id] = found
	return found


## Calls static [param method] of global class [param class_id] with [param args]; null when the class is missing.
static func call_static(class_id: StringName, method: StringName, args: Array = []) -> Variant:
	var s := script_of(class_id)
	if s == null:
		push_error("FC: %s is not in this build (%s)" % [class_id, method])
		return null
	return s.callv(method, args)
