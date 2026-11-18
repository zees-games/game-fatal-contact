extends RefCounted

## Maps handed to Fatal Contact outside the window: dropped on the executable (a path on the command line) or named by
## `--map-path=<path>`, through dot-map's DotMapDropIntake (API 30), the same intake a window drop goes through. The
## client (fc_client_view.gd) answers every drop on screen; a path that holds no converted map is refused out loud.

const CHANNEL := "arena.map_drop"
## dot-map's API level with DotMapDropIntake. Older builds take no exe drop, nor config options out of the paths.
const NEEDS_LEVEL := 30
const INTAKE_SCRIPT := "res://addons/dot_map/core/dot_map_drop_intake.gd"
## What the refusal says this game takes.
const TAKES := "a converted map folder (or a download holding one), its .zip, or its .json beside its .bin"
## Fatal Contact's own options whose next argument is their value (never read as a dropped path).
const VALUE_FLAGS := ["--map", "--mode", "--bots", "--port", "--cvar", "--ready", "--config", "--source-game"]
## dot-core reads `--arena-<key> <value>`: such an option and its value are never read as a dropped path.
const CONFIG_PREFIX := "--arena-"


## A DotMapDropIntake that does not watch the window (the client's own handler does, to say "Importing…" first), with
## [param accept] (`func(path, into) -> Dictionary`) as its one acceptor. Null, with a warning, on dot-map older than API 30.
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
	intake.set(&"config_prefixes", PackedStringArray([CONFIG_PREFIX]))
	# `--arena-no-<thing>` is a switch (FcWeaponRoles.OFF_ARG): the argument after it is not its value.
	intake.set(&"option_takes_value", func(_prefix: String, stem: String) -> bool: return not stem.begins_with("no-"))
	intake.call(&"add_acceptor", TAKES, accept)
	return intake


## The process's arguments, the engine's and the user's.
static func cmdline() -> PackedStringArray:
	var all := OS.get_cmdline_args()
	all.append_array(OS.get_cmdline_user_args())
	return all
