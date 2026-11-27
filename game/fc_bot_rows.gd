extends RefCounted

## The bots' contact table (gs-bot API 37, [code]GSBotWorld.set_rows[/code]), filled in [method FcBots.World.refresh]'s contact loop so senses() does not walk the contacts again.
## Off (cvar `bot_native_think` 0) or on an older gs-bot, gs-bot packs the contacts itself. The columns are, to the bit, what
## [code]GSBotWorld.rows_of[/code] makes of the same contacts. See gs-bot's docs/native-bot-brain.md.

## gs-bot API level of [code]GSBotWorld.set_rows[/code].
const LEVEL := 37

## Whether the world hands its contact table (cvar `bot_native_think`).
static var enabled: bool = true

## Whether this build's gs-bot takes a contact table; asked once.
static var _supported: int = -1

var _on: bool = false
var _sensed: Array = []
var _ids := PackedInt64Array()
var _points := PackedVector3Array()
var _teams := PackedInt32Array()
var _alive := PackedByteArray()
var _eyes := PackedVector3Array()
var _positions := PackedVector3Array()


## Cvar `bot_native_think`: the contact table, the reused pair of commands and gs-bot's native tricks
## ([code]GSBotTricks.native_enabled[/code], gs-bot 39; set by name, a no-op on an older gs-bot), all on or all off.
static func set_native_think(on: bool) -> void:
	enabled = on
	# By path: FcBots names this class, so naming FcBots here is a cycle the parser refuses.
	(load("res://game/fc_bots.gd") as Script).set(&"reuse_commands", on)
	(GSBotTricks as Script).set(&"native_enabled", on)


static func supported() -> bool:
	if _supported < 0:
		_supported = 1 if GSAddonApi.build_level("gs_bot") >= LEVEL else 0
	return _supported == 1


## Starts a tick's table, fresh arrays (the scan keeps the last ones it loaded); whether rows are filled this tick.
func begin() -> bool:
	_on = enabled and supported() and GSBotWorld.native_available()
	if _on:
		_sensed = []
		_ids = PackedInt64Array()
		_points = PackedVector3Array()
		_teams = PackedInt32Array()
		_alive = PackedByteArray()
		_eyes = PackedVector3Array()
		_positions = PackedVector3Array()
	return _on


## One contact's row, after every field of [param c] is written.
func add(c: GSBotContact) -> void:
	var at := c.position
	_sensed.append(c)
	_ids.append(c.id)
	_points.append(at + Vector3.UP * c.aim_height)
	_teams.append(c.team)
	_alive.append(1 if c.alive else 0)
	_eyes.append(at + Vector3.UP * c.eye_height)
	_positions.append(at)


## The whole table at once, from gs-sim's contact build ([code]GSSimBotContacts[/code]): [param sensed] and [param ids] in its
## order, the rows from [param sim]'s last fill.
func take(sensed: Array, ids: PackedInt64Array, sim: Object) -> void:
	if not _on:
		return
	_sensed = sensed
	_ids = ids
	_points = sim.points()
	_teams = sim.teams()
	_alive = sim.alive()
	_eyes = sim.eyes()
	_positions = sim.positions()


## Hands the table to [param world] for [param version] (its contacts_version). By call: FC parses on gs-bot 26.
func hand(world: GSBotWorld, version: int) -> void:
	if _on:
		world.call(&"set_rows", version, _sensed, _ids, _points, _teams, _alive, _eyes, _positions)
