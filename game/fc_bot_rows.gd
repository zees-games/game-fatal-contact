extends RefCounted

## The bots' contact table (gs-bot API 37, [code]GSBotWorld.set_rows[/code]): the columns the native sight scan loads, filled in
## [method FcBots.World.refresh]'s own contact loop, so gs-bot's senses() does not walk every contact a second time on the main thread.
## Off (cvar `bot_native_think` 0) or on an older gs-bot the world hands nothing and gs-bot packs the contacts itself, as before.
## The columns are what gs-bot's [code]GSBotWorld.rows_of[/code] makes of the same contacts, to the bit: the aim point and eye are
## written as [code]GSBotContact.aim_point()[/code] and [code]eye()[/code] write them. See gs-bot's docs/native-bot-brain.md.

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


## Hands the table to [param world] for [param version] (its contacts_version). By call: FC parses on gs-bot 26.
func hand(world: GSBotWorld, version: int) -> void:
	if _on:
		world.call(&"set_rows", version, _sensed, _ids, _points, _teams, _alive, _eyes, _positions)
