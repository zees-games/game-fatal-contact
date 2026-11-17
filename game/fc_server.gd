extends Node

const FcConfig := preload("fc_config.gd")
const FcGame := preload("fc_game.gd")
const FcMaps := preload("fc_maps.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcTickBudget := preload("fc_tick_budget.gd")

## What a [DotServer] loads as its game scene. Never a client.
##
## [b]Small on purpose.[/b] Everything a dedicated server does is in [FcModule];
## this exists because `DotGameManager` loads a SCENE and the game needs one, and
## because [method FcGame.setup] is explicit — it takes a map, it can fail, and a
## game that built itself in `_ready` would have no way to report that it had not.
##
## [b]It lives in `game/`, not beside its own scene in `scenes/`.[/b] That is a
## deployment constraint rather than a preference: `dot-server-deploy/setup.sh`
## vendors a game by copying its `game/` wholesale and its `scenes/*.tscn` — only the
## `.tscn` — so a script under `scenes/` is a script that never reaches the build. The
## scene then fails to load with "referenced non-existent resource", the module refuses
## to load because no game registered itself, and the server reports "the game loaded
## but its module did not". Every other game in this family already keeps its server
## scene's script in `game/`; this one now does too.
##
## The order matters and is the only interesting thing here: the game registers itself
## in [DotRegistry] under [constant FcGame.SERVICE] during `setup`, and
## `FcModule._module_load` refuses to load if it cannot find it. dot-server loads the
## scene before the module for exactly that reason.

const CHANNEL := "arena.server"

var game: FcGame = null

## The module's map director ([code]FcMapDirector[/code], under `server.modules`), set by
## [method attach_maps]. Null before the module loads and after it unloads.
var maps: Node = null

## A `--map` id this scene could not build at boot but the server's map list names as a delivered pack: the
## game boots on the default and the director fetches and changes to it once it is attached.
var deferred_map: StringName = &""

var _startup_id: StringName = &""
var _startup_running := false
var _startup_result: DotResult = null
signal _startup_done(result: DotResult)


func _ready() -> void:
	# Only a server here: sv_max_physics_steps may set the engine's step cap (FcTickBudget).
	FcTickBudget.server_process = true
	game = FcGame.new()
	game.name = "Game"
	game.is_authority = true
	game.stats_file = "user://arena_stats.json"
	# HEADLESS: analytic geometry from the box list rather than a physics space. Not a
	# degraded mode — it is exact, it needs no physics server, and it gives the same
	# answer as a client replaying the same tick, which is what makes reconciliation
	# converge at all.
	game.headless = true
	game.tick_rate = host_tick_rate()

	# Strict on a dedicated server: a typo in a config file or an unknown --map stops the boot.
	var binder := FcConfig.make_binder(game.config, "user://cfg/arena.json")
	var loaded := binder.load_layers()
	if loaded.ok:
		var built_ids := FcMap.ids() + FcMap.imported_ids()
		loaded = binder.check_map(asked_map(), built_ids + delivered_ids())
		if loaded.ok and asked_map() != "" and not built_ids.has(StringName(asked_map())):
			deferred_map = StringName(asked_map())
			DotLog.info(CHANNEL, "the asked map is a delivered pack: booting the default, the map director fetches it", {"map": asked_map()})
	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return
	game.config_binder = binder
	add_child(game)
	_start_workbench(binder)

	var built := game.setup(FcMap.dm_box() if deferred_map != &"" else startup_map())

	DotLog.result(CHANNEL, "the arena was built", built)

	if built.ok:
		game.start(0)


## Which map to boot on, from `-- --map <id>`.
##
## [b]A launch argument and not a cvar, because a cvar is read after the game is
## built.[/b] `FcGame.setup` builds the combat trace, the match and every spawn point
## out of the map in one pass and is not re-entrant, so by the time a module has added a
## cvar for an operator to set, the map it would name is already the one running. A
## hot `changelevel` is a real feature and a real amount of work; until it exists, the
## honest interface is the one that is read before anything is built.
##
## An unknown id is refused rather than silently falling back: an operator who typed
## `dm_atruim` and got `dm_box` has no way to tell that from a map that failed to build.
## The rate a server game declares: the host's (sv_tickrate), never the export. The module
## runs one tick per physics frame, so a declared 64 on a 60 Hz host put every client's
## clock 4 ticks a second ahead of the snapshots.
static func host_tick_rate() -> int:
	var rate := maxi(1, Engine.physics_ticks_per_second)
	var clamped := clampi(rate, FcGame.MIN_TICK_RATE, FcGame.MAX_TICK_RATE)
	if clamped != rate:
		DotLog.error(CHANNEL, "sv_tickrate is outside the structural range the sim is tuned for; running at the nearest bound", {
			"rate": rate, "used": clamped, "min": FcGame.MIN_TICK_RATE, "max": FcGame.MAX_TICK_RATE})
		Engine.physics_ticks_per_second = clamped
	return clamped


## The id after `--map`, or "".
static func asked_map() -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--map")
	return args[index + 1] if index >= 0 and index + 1 < args.size() else ""


static func startup_map() -> FcMap:
	var asked := asked_map()

	if asked == "":
		return FcMap.dm_box()

	var id := StringName(asked)
	var map: FcMap = FcMap.by_id(id)

	if map == null:
		DotLog.warn(CHANNEL, "no such map, booting the default instead", {
			"asked": String(id),
			"known": FcMap.ids() + FcMap.imported_ids(),
		})
		return FcMap.dm_box()

	return map


## dot-workbench: the F9 panel in the editor and debug builds, the loopback page when `workbench.enabled` is set in cfg/server.yml.
func _start_workbench(binder: DotGameConfigBinder) -> void:
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.dedicated = DisplayServer.get_name() == "headless"
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var _fl := game.flashlight_conf()
	for set: DotProfileSet in game.flashlight_binder.profile_sets():
		wb.add_set(set, "Flashlight")
	add_child(wb)
	# Started by FcModule once the fc_ambient* cvars exist, so they are a set beside the config.
	game.workbench = wb



## Ids of the delivered packs the server's map list names (`DotGameManager.current_maps`, from cfg/content.yml): known
## to `--map` though not on the disk yet. Empty outside a dot-server host.
func delivered_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	var manager := get_parent()
	if manager == null or not manager.has_method(&"current_maps"):
		return out
	for key: Variant in manager.call(&"current_maps"):
		var def := FcMaps.delivered_def(str(key))
		if def != null and not out.has(def.id):
			out.append(def.id)
	return out


# --- The map changer a host finds under server.games -------------------------
#
# dot-server-deploy starts a server on `map:` (server.yml) / `--map` by searching `server.games` for the first node with
# `change_to` + `change_to_map` (and `ensure_map_content` for the fetch). FC's director lives with its module under
# `server.modules`, so without these the owner's `map: cp_orange_x3` was skipped with "this game has no maps". They
# forward to the director, which is the path `map`, `fc_map`, the vote and the rotation take: sync host, FC's state
# reset, map_changed (map config, the map list's `mode:`/`cfg:`, a pending `fc_mode`).

## Called by the module once its director is set up (null when it unloads). Starts a [member deferred_map].
func attach_maps(director: Node) -> void:
	maps = director
	if maps != null and deferred_map != &"":
		_change_to_deferred.call_deferred()


## The director's catalogue, for an admin menu that lists the maps. Null before the module loads.
var catalogue: Object:
	get:
		var session: Variant = maps.get(&"session") if maps != null else null
		return (session as Object).get(&"catalogue") if session is Object else null


## The map the director is on, or null.
var current: Object:
	get:
		return maps.get(&"current") if maps != null else null


## Changes the map through the module's director. Fails (it does not wait) before the module has attached it.
func change_to(id: StringName) -> DotResult:
	if maps == null:
		return DotResult.fail(DotError.CODE_STATE, "The game has no map director yet (its module is not loaded).")
	# The host asking for the startup map before the deferred call got to it: that call is this change.
	if id != &"" and id == deferred_map and maps != null:
		await _change_to_deferred()
	# The host asks again for the `--map` this scene already handed the director: the same change, not a second one.
	if id == _startup_id and id != &"":
		if _startup_running:
			return await _startup_done
		if _startup_result != null:
			var r := _startup_result
			_startup_result = null
			_startup_id = &""
			return r
	return await maps.call(&"change_to", id)


## [method change_to] for a def in hand.
func change_to_map(map: DotMapDef) -> DotResult:
	if maps == null:
		return DotResult.fail(DotError.CODE_STATE, "The game has no map director yet (its module is not loaded).")
	return await maps.call(&"change_to_map", map)


## The host's fetch step: FC's session fetches a delivered map when it is changed to, so this only says whether
## the catalogue holds [param id] (so the host does not mount the pack a second way).
func ensure_map_content(id: StringName) -> DotResult:
	var cat := catalogue
	if cat == null:
		return DotResult.fail(DotError.CODE_STATE, "The game has no map director yet (its module is not loaded).")
	if cat.call(&"get_map", id) == null:
		return DotResult.fail(DotError.CODE_INVALID, "No map '%s' in this server's catalogue." % String(id))
	return DotResult.success(id)


func _change_to_deferred() -> void:
	if maps == null or deferred_map == &"":
		return
	_startup_id = deferred_map
	deferred_map = &""
	_startup_running = true
	var r: DotResult = await maps.call(&"change_to", _startup_id)
	_startup_running = false
	_startup_result = r
	if r.ok:
		DotLog.info(CHANNEL, "started on the map --map asked for", {"map": String(_startup_id)})
	else:
		DotLog.error(CHANNEL, "could not start on the map --map asked for", {"map": String(_startup_id), "why": r.error.message})
	_startup_done.emit(r)
