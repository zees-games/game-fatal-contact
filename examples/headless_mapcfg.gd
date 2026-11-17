extends DotGameCheckSuite

const FcMapConfig := preload("../game/fc_map_config.gd")

## A surf map gets the shipped `surf_%.yml` and a map that is not a surf map does not.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]
##
## The cvars start away from the file's values, so "got them" cannot be the default showing through.

const CHECKS := 8


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC: per-map cvars from cfg/game/game-arena/dot_map/map")
	var console := DotConsole.new()
	add_child(console)
	console.cvar("fc_surf", "0", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("fc_surf_airaccelerate", "90", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("fc_other", "5", "", DotConVar.FLAG_ARCHIVE)
	var cfg := FcMapConfig.build(console)

	var got := cfg.apply("surf_beginner")
	_check(got.size() == 2, "a surf map applies both keys (%s)" % [got])
	_check(console.find_cvar("fc_surf_airaccelerate").get_float() == 150.0, "fc_surf_airaccelerate is 150 on a surf map")
	_check(console.find_cvar("fc_surf").get_int() == 1, "fc_surf is 1 on a surf map")

	cfg.apply("dm_plain")
	_check(console.find_cvar("fc_surf_airaccelerate").get_float() == 90.0, "the next, non-surf map has the previous value back")
	_check(console.find_cvar("fc_surf").get_int() == 0, "fc_surf is back too")
	_check(cfg.applied().is_empty(), "a non-surf map applies nothing")

	cfg.apply("surf_other")
	_check(console.find_cvar("fc_surf_airaccelerate").get_float() == 150.0, "another surf map gets the same wildcard file")
	_check(console.find_cvar("fc_other").get_int() == 5, "a cvar outside the whitelist is untouched")

	_report(CHECKS)
