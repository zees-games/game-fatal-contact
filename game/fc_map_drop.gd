extends RefCounted

## Maps handed to Fatal Contact outside the window: dropped on the executable (a path on the command line) or named by
## `--map-path=<path>`, through dot-map's DotMapDropIntake (API 26), the same intake a window drop goes through. The
## client (fc_client_view.gd) answers every drop on screen; a path that holds no converted map is refused out loud.

const CHANNEL := "arena.map_drop"
## dot-map's API level with DotMapDropIntake. Older builds keep the window drop (dot-map API 24) and take no exe drop.
const NEEDS_LEVEL := 26
const INTAKE_SCRIPT := "res://addons/dot_map/core/dot_map_drop_intake.gd"
## What the refusal says this game takes.
const TAKES := "a converted map folder (or a download holding one), its .zip, or its .json beside its .bin"
## Fatal Contact's own options whose next argument is their value (never read as a dropped path).
const VALUE_FLAGS := ["--map", "--mode", "--bots", "--port", "--cvar", "--ready", "--config", "--source-game"]


## A DotMapDropIntake that does not watch the window (the client's own handler does, to say "Importing…" first), with
## [param accept] (`func(path, into) -> Dictionary`) as its one acceptor. Null, with a warning, on dot-map older than API 26.
static func make(accept: Callable) -> Node:
	if DotAddonApi.build_level("dot_map") < NEEDS_LEVEL or not ResourceLoader.exists(INTAKE_SCRIPT):
		DotLog.warn(CHANNEL, "maps dropped on the executable are off: this build's dot-map is older than API %d" % NEEDS_LEVEL)
		return null
	var intake: Node = load(INTAKE_SCRIPT).new()
	intake.name = "MapDrop"
	intake.set(&"watch_window", false)
	var flags: PackedStringArray = intake.get(&"value_flags")
	flags.append_array(PackedStringArray(VALUE_FLAGS))
	intake.set(&"value_flags", flags)
	intake.call(&"add_acceptor", TAKES, accept)
	return intake


## The process's arguments, the engine's and the user's.
static func cmdline() -> PackedStringArray:
	var all := OS.get_cmdline_args()
	all.append_array(OS.get_cmdline_user_args())
	return all


## The dropped paths in [param args] (DotMapDropIntake.paths_in_args, with this game's config options taken out first):
## every path that exists, every `--map-path` value, and every absolute path that does not exist (said as not found).
static func paths_in(intake: Node, args: PackedStringArray) -> PackedStringArray:
	var found: Dictionary = intake.call(&"paths_in_args", drop_args(args), intake.get(&"value_flags"), intake.get(&"path_flag"))
	var paths: PackedStringArray = found["paths"]
	paths.append_array(found["missing"] as PackedStringArray)
	return paths


## [param args] without Fatal Contact's config options and their values: dot-core reads `--arena-<key> <value>`,
## `--<addon>.<key> <value>` and `--config <dir>`, and a value that happens to be a folder is not a dropped map.
static func drop_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while i < args.size():
		var a := args[i]
		i += 1
		if a.begins_with("--arena-") or (a.begins_with("--") and a.get_slice("=", 0).contains(".")):
			# `--arena-no-<thing>` is a switch (FcWeaponRoles.OFF_ARG): the argument after it is not its value.
			if not a.contains("=") and not a.begins_with("--arena-no-") and i < args.size() and not args[i].begins_with("--"):
				i += 1
			continue
		out.append(a)
	return out
