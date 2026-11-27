extends RefCounted

## The bots' finish over gs-bot's intent table (API 52, [code]GSBotIntentTable[/code]): after the brains ran,
## [method run] packs every pending bot's intent into one table and makes the command columns in one call (gs-sim's
## [code]GSSimBotFinish.write[/code] when the library has it, else gs-bot's script twin); [method write] then copies a
## row into the bot's commands instead of [method FcBots._write]'s six button calls. The same commands to the bit:
## headless_botthreads plays the table off and on to one digest. Off (cvar `bot_intent_table` 0) or on an older
## gs-bot, [method FcBots._write] runs as before. See gs-bot's docs/native-bot-brain.md, step 3.

## gs-bot API level of [code]GSBotIntentTable[/code].
const LEVEL := 52
## By path, so this parses on an older gs-bot.
const TABLE_PATH := "res://addons/gs_bot/core/gs_bot_intent_table.gd"

## Cvar `bot_intent_table`.
static var enabled := true
## Whether gs-bot's table may finish natively (cvar `bot_native_think`, by name; FcBotRows.set_native_think).
static var native := true

## The table's script, null on a gs-bot without it; asked once.
static var _script: Script = null
static var _asked := false

## Per intent bit (fire, crouch, jump, walk, air jump, throw, use, stranded) the command bit it sets: [method FcBots._write]'s buttons.
static var _move_map := PackedInt32Array([0, GSFpsCommand.BUTTON_CROUCH, GSFpsCommand.BUTTON_JUMP, GSFpsCommand.BUTTON_WALK, GSFpsCommand.BUTTON_USER_0, 0, 0, 0])
static var _fire_map := PackedInt32Array([GSWeaponCommand.BUTTON_ATTACK, 0, 0, 0, 0, 0, GSWeaponCommand.BUTTON_USE, 0])

var _table: RefCounted = null
var _yaw := PackedFloat64Array()
var _pitch := PackedFloat64Array()
var _move := PackedVector2Array()
var _move_buttons := PackedInt32Array()
var _fire_buttons := PackedInt32Array()


## Whether this tick's finish goes through a table.
static func on() -> bool:
	if not enabled:
		return false
	if not _asked:
		_asked = true
		if GSAddonApi.build_level("gs_bot") >= LEVEL:
			_script = load(TABLE_PATH) as Script
	return _script != null


## The table of [param minds]' intents at [param pending], in that order: row k is pending[k].
func run(pending: Array[int], minds: Array) -> void:
	if _table == null:
		_table = _script.new()
	var intents: Array = []
	intents.resize(pending.size())
	for k in pending.size():
		intents[k] = minds[pending[k]].t_intent
	_table.call(&"pack", intents, false)
	_table.call(&"finish", _move_map, _fire_map, native)
	_yaw = _table.get(&"yaw")
	_pitch = _table.get(&"pitch")
	_move = _table.get(&"cmd_move")
	_move_buttons = _table.get(&"move_buttons")
	_fire_buttons = _table.get(&"fire_buttons")


## Row [param k] into cleared commands, as [method FcBots._write] writes its intent.
func write(k: int, move: GSFpsCommand, fire: GSWeaponCommand) -> void:
	var yaw := _yaw[k]
	var pitch := _pitch[k]
	move.yaw = yaw
	move.pitch = pitch
	move.move = _move[k]
	move.buttons = _move_buttons[k]
	fire.yaw = yaw
	fire.pitch = pitch
	fire.buttons = _fire_buttons[k]
