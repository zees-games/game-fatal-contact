extends RefCounted

## Fatal Contact's per-map settings: gs-game's [GSGameMapConfig] (gs-map's files) over the cvars a map may change.
##
## `cfg/game/game-fatal-contact/gs_map/map/<name>.yml` (a glob such as `surf_%.yml` covers a class of maps), overridable from `cfg/server/...`. Only the keys in [constant KEYS] are accepted; anything else a file says is logged and ignored.

const GAME_ID := "game-fatal-contact"

## cvar -> its constraint. Add a cvar here to let a map or an operator's per-map file set it.
const KEYS := {
	"fc_surf": {"type": "int", "min": 0, "max": 1},
	"fc_surf_airaccelerate": {"type": "float", "min": 0.0},
	"fc_spawn_mode": {"type": "string"},
}


## The applier over [param console]'s cvars (gs-game's [GSGameMapConfig]). Call `apply(map_id)` on every map load.
static func build(console: GSConsole) -> GSGameMapConfig:
	return GSGameMapConfig.for_console(GAME_ID, console, KEYS)


static var _refused: Dictionary = {}


## A rotation profile's cvars (`GSMapDef.profile.values`, from a maps.yml `mode:`/`cfg:` file) for one map, put
## back on the next. Any existing cvar but `fc_mode` (the profile's `mode` does that) and protected ones.
## Null when the linked gs-map predates `GSMapConfig.apply_values`: profiles then change no cvars.
static func build_profile(console: GSConsole) -> Object:
	var script: Variant = load(GSGameMapConfig.SCRIPT_PATH) if ResourceLoader.exists(GSGameMapConfig.SCRIPT_PATH) else null
	if script == null:
		return null
	var out: Object = script.new()
	if not out.has_method(&"apply_values"):
		return null
	var base := GSGameMapConfig.for_console(GAME_ID, console, {})
	out.set(&"game", GAME_ID)
	out.set(&"get_fn", base.get_fn)
	out.set(&"set_fn", base.set_fn)
	return out


## Applies [param map]'s profile cvars through [param applier] (from [method build_profile]), after putting the last
## map's back. Returns the keys applied.
static func apply_profile(applier: Object, console: GSConsole, map: GSMapDef) -> PackedStringArray:
	if applier == null:
		return PackedStringArray()
	var prof: Variant = map.get(&"profile") if map != null else null
	var values: Dictionary = (prof as Dictionary).get("values", {}) if prof is Dictionary else {}
	var allowed := {}
	for k: Variant in values:
		var key := String(k).strip_edges().to_lower()
		# The pre-Fatal-Contact names: applied under the new name, with an ERR naming it.
		if key.begins_with("arena_") and console.find_cvar("fc_" + key.substr(6)) != null:
			GSLog.error("arena.map.config", "a rotation profile uses %s, renamed to fc_%s; update the file" % [key, key.substr(6)], {
				"map": String(map.id) if map != null else ""})
			key = "fc_" + key.substr(6)
		var cv := console.find_cvar(key)
		if key == "fc_mode" or cv == null or cv.has_flag(GSConVar.FLAG_PROTECTED):
			if _refused.has(key):
				continue
			_refused[key] = true
			GSLog.warn("arena.map.config", "a rotation profile names a cvar it may not set", {
				"map": String(map.id), "cvar": key})
			continue
		allowed[key] = values[k]
	applier.call(&"allow_all", PackedStringArray(allowed.keys()))
	var res: GSResult = applier.call(&"apply_values", String(map.id) if map != null else "", allowed)
	return res.value if res.ok else PackedStringArray()
