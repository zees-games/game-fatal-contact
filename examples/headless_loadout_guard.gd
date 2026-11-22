extends DotGameCheckSuite

## A living player is never left with an empty arsenal: the guard every loadout path ends in repairs it, and leaves
## a knife-only kit, a dead player and a stocked arsenal alone.

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const Content := preload("../game/fc_content.gd")
const Guard := preload("../game/fc_loadout_guard.gd")


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("arena: no living player has an empty arsenal")
	var game := FcGame.new()
	game.name = "G"
	game.headless = true
	game.register_service = false
	game.mode = FcMode.team_deathmatch()
	add_child(game)
	_check(game.setup(FcMap.dm_atrium()).ok, "a game sets up")
	game.start(0)
	var _a := game.add_player(31, "A")
	game.tick({})
	var player := game.player_for(31)
	_check(player != null and player.is_alive(), "the player is alive")

	player.arsenal.clear()
	_check(player.arsenal.slots().is_empty(), "an emptied arsenal is empty")
	_check(Guard.ensure_armed(player), "the guard repairs it")
	_check(not player.arsenal.slots().is_empty() and player.arsenal.current() != null, "the player holds a weapon again", str(player.arsenal.slots()))
	_check(player.arsenal.slots().size() >= 2, "from the default loadout, not one stray gun", str(player.arsenal.slots()))

	var before: Array = player.arsenal.slots()
	_check(not Guard.ensure_armed(player) and player.arsenal.slots() == before, "a stocked arsenal is left alone")

	player.arsenal.clear()
	var _knife := player.arsenal.give(Content.melee_id())
	_check(not Guard.ensure_armed(player) and player.arsenal.slots().size() == 1, "a knife alone is a kit, not a gap")

	player.arsenal.clear()
	player.health.alive = false
	_check(not Guard.ensure_armed(player) and player.arsenal.slots().is_empty(), "a dead player is left alone")
	player.health.alive = true

	game.queue_free()
	_report()
	get_tree().quit(0 if _failed == 0 else 1)

