extends RefCounted
## The bots' begin pass ([method FcBots.think_begin]) with the coasting bots in one gs-sim call ([code]GSSimBotCoast[/code]): each coasting
## view carried on and each firing coaster's recoil turn, bit for bit [method FcBots._coast] and [method FcBots.recoil_preview]
## (headless_botthreads). Off, or without the library, every bot takes [method FcBots.think_begin].

const FcBots := preload("fc_bots.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")
const FcPlayer := preload("fc_player.gd")
const CHANNEL := "fc.bots"
static var _EMPTY_VIEWS := PackedFloat32Array()
static var _EMPTY_STEPS := PackedInt64Array()

## Whether the coasting bots go through gs-sim in one call a tick (cvar [code]bot_coast_native[/code]).
static var enabled := true
## Coasting bots worked natively since start (the suites read it to know the native path ran).
static var batched := 0
## Whether the finish pass's recoil turns go through gs-sim in one call a tick (cvar [code]bot_finish_recoil_native[/code]).
static var finish_native := true
## Firing bots whose finish recoil gs-sim worked since start (the suites read it to know the native path ran).
static var finish_batched := 0

static var _native: Object
## [method begin_all]'s coasting and firing bot indices and its fault fields, reused call to call (main thread).
static var _coasting: Array[int] = []
static var _firing: Array[int] = []
## [method finish_all]'s firing bot indices and recoil rows, reused tick to tick (main thread).
static var _finish_firing: Array[int] = []
static var _finish_rows := PackedFloat64Array()
static var _fault: Dictionary[String, int] = {}


## The native coaster, or null (off, or no gs-sim with the [code]bot_coast[/code] module).
static func native() -> Object:
	if not enabled or not GSSim.has(&"bot_coast"):
		return null
	if _native == null:
		_native = ClassDB.instantiate(GSSim.MODULES[&"bot_coast"])
	return _native


## [method FcBots.think_begin] for each of [param players]: commands into [param out] for the bots that coast (or
## have no body), the index into [param pending] for the ones whose brain runs. Bots that do not coast are set up in
## turn as the script does; the coasting ones are gathered and worked by [param coast] in one call.
static func begin_all(coast: Object, game: Object, players: Array[FcPlayer], minds: Array[FcBots.Mind], tick: int,
		tick_rate: float, out: Array[Array], pending: Array[int]) -> void:
	var t_gate := FcFrameProbe.lap_start()
	var world := FcBots.world_this_tick(game, tick)
	var coasting := _coasting
	var firing := _firing
	coasting.clear()
	firing.clear()
	var views := PackedFloat32Array()
	var steps := PackedInt64Array()
	var recoil := PackedFloat64Array()
	for i in players.size():
		var bot: FcPlayer = players[i]
		var mind: FcBots.Mind = minds[i]
		if bot == null or not FcBots.coasts_now(world, bot, mind, tick):
			var early := FcBots.think_begin(game, bot, mind, tick, tick_rate) if bot == null \
					else FcBots.think_setup(game, bot, mind, tick, tick_rate, world)
			if early.is_empty():
				pending.append(i)
			else:
				out[i] = early
			continue
		coasting.append(i)
		views.append(mind.view_from.x)
		views.append(mind.view_from.y)
		views.append(mind.view_to.x)
		views.append(mind.view_to.y)
		steps.append(tick - mind.last_think_tick)
		steps.append(mind.every)
		mind.recoil_comp = Vector2.ZERO
		if FcBots.recoil_compensation and bot.arsenal != null and mind.last_fire != null \
				and mind.last_fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK):
			var row := FcBots.recoil_row(bot, FcBots.recoil_share(mind))
			if not row.is_empty():
				firing.append(i)
				recoil.append_array(row)
	FcFrameProbe.lap(&"bt_gate", t_gate)
	if coasting.is_empty():
		return
	var t_coast := FcFrameProbe.lap_start()
	var got: PackedFloat64Array = coast.step(views, steps, recoil, tick, tick_rate)
	if got.size() != (coasting.size() + firing.size()) * 2:
		_fault["values"] = got.size()
		_fault["bots"] = coasting.size()
		_fault["recoil_rows"] = firing.size()
		GSLog.error(CHANNEL, "FcBotCoast: GSSimBotCoast.step gave the wrong number of values; these bots coast in script", _fault)
		for i in coasting:
			out[i] = FcBots.think_begin(game, players[i], minds[i], tick, tick_rate)
		return
	for k in coasting.size():
		var i := coasting[k]
		out[i] = FcBots.coast_pair(minds[i], got[k * 2], got[k * 2 + 1])
	var base := coasting.size() * 2
	for k in firing.size():
		var i := firing[k]
		FcBots.recoil_turn(minds[i], out[i], Vector2(got[base + k * 2], got[base + k * 2 + 1]))
	batched += coasting.size()
	FcFrameProbe.lap(&"bt_coast", t_coast)


## [method FcBots.think_finish] for each bot in [param pending], with every firing bot's recoil turn worked by [param coast] in one call
## (no coasting views, only the recoil rows): the same turns to the bit as [method FcBots._recoil_comp] (headless_botthreads). The
## turn is the finish's last step, after the commands are kept for the coast, so working it after the loop changes nothing else.
static func finish_all(coast: Object, game: Object, players: Array[FcPlayer], minds: Array[FcBots.Mind], pending: Array[int],
		tick: int, tick_rate: float, out: Array[Array]) -> void:
	FcBots.defer_recoil = true
	for i in pending:
		out[i] = FcBots.think_finish(game, players[i], minds[i], tick, tick_rate)
	FcBots.defer_recoil = false
	var firing := _finish_firing
	var rows := _finish_rows
	firing.clear()
	rows.clear()
	for i in pending:
		var mind: FcBots.Mind = minds[i]
		mind.recoil_comp = Vector2.ZERO
		var bot: FcPlayer = players[i]
		if not FcBots.recoil_compensation or bot == null or bot.arsenal == null:
			continue
		var fire: GSWeaponCommand = out[i][1]
		if not fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK):
			continue
		var row := FcBots.recoil_row(bot, FcBots.recoil_share(mind))
		if not row.is_empty():
			firing.append(i)
			rows.append_array(row)
	_finish_rows = rows
	if firing.is_empty():
		return
	var got: PackedFloat64Array = coast.step(_EMPTY_VIEWS, _EMPTY_STEPS, rows, tick, tick_rate)
	if got.size() != firing.size() * 2:
		_fault["values"] = got.size()
		_fault["recoil_rows"] = firing.size()
		GSLog.error(CHANNEL, "FcBotCoast: GSSimBotCoast.step gave the wrong number of finish recoil values; these turns are worked in script", _fault)
		for i in firing:
			out[i] = FcBots._recoil_comp(players[i], minds[i], out[i], tick, tick_rate)
		return
	for k in firing.size():
		var i := firing[k]
		FcBots.recoil_turn(minds[i], out[i], Vector2(got[k * 2], got[k * 2 + 1]))
	finish_batched += firing.size()
