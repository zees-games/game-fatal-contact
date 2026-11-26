extends RefCounted
## The bots' contact build in gs-sim ([code]GSSimBotContacts[/code], cvar `bot_native_contacts`): [method build] packs one record per
## player on the main thread (flags, team, pitch, health, then the [GSFpsState] columns as they are), and gs-sim writes every per-tick
## [GSBotContact] field and the native sight scan's rows from them in one call. The loadout and the weapon in hand stay here.
## The same contacts and rows as [method FcBots.World.refresh]'s script loop, to the bit (`headless_botthreads` compares them over
## randomized player states). Off, without the library (the web) or when the records do not fit, the script loop builds them.

const FcFrameProbe := preload("fc_frame_probe.gd")
const FcPlayer := preload("fc_player.gd")

## Head flags of a record (gs-sim-contacts' CONTROLLER, ALIVE and HEALTH).
const CONTROLLER := 1
const ALIVE := 2
const HEALTH := 4
## Head floats before the state columns.
const HEAD := 6

## Whether the bots' worlds build contacts in gs-sim (cvar `bot_native_contacts`).
static var enabled: bool = true
## Ticks whose contacts gs-sim built, for the suites.
static var built: int = 0

var _sim: Object = null
var _tried: bool = false
var _head := PackedFloat64Array()
## The state columns of a player without a controller: its position, then zeros.
var _bare := PackedFloat64Array()


## gs-sim's contact build, or null (off, or no library).
func sim() -> Object:
	if not enabled:
		return null
	if not _tried:
		_tried = true
		if GSSim.has(&"contacts"):
			_sim = ClassDB.instantiate(&"GSSimBotContacts")
			_head.resize(HEAD)
			_bare.resize(int(_sim.call(&"stride")) - HEAD)
	return _sim


## Builds [param world]'s contacts for [param players] in gs-sim, as [method FcBots.World.refresh]'s loop does, and hands the sight
## rows to its row table when [param rows]. False, with the contacts and players cleared again, when gs-sim is off or the records do
## not fit it (a state of another stride): the caller's script loop builds them.
func build(world: Object, players: Array, tick: int, eye: float, aim: float, teams: bool, rows: bool) -> bool:
	var native := sim()
	if native == null:
		return false
	var contacts: Array = world.get(&"_contacts")
	var by_id: Dictionary = world.get(&"_by_id")
	var by_player: Dictionary = world.get(&"_players")
	var records := PackedFloat64Array()
	var ids := PackedInt64Array()
	var head := _head
	var controlled := false
	for p: FcPlayer in players:
		var c: GSBotContact = by_id.get(p.player_id)
		if c == null:
			c = GSBotContact.new()
			c.id = p.player_id
			by_id[c.id] = c
		contacts.append(c)
		by_player[c.id] = p
		ids.append(c.id)
		var health := p.health
		var controller := p.controller
		head[0] = (CONTROLLER if controller != null else 0) | (ALIVE if p.is_alive() else 0) | (HEALTH if health != null else 0)
		head[1] = p.team if teams else 0
		if health != null:
			head[3] = health.health
			head[4] = health.max_health
		if controller != null:
			var state := controller.state
			head[2] = state.pitch
			records.append_array(head)
			records.append_array(state.columns())
			controlled = true
		else:
			var at := p.global_position
			_bare[0] = at.x
			_bare[1] = at.y
			_bare[2] = at.z
			records.append_array(head)
			records.append_array(_bare)
		var t_c := FcFrameProbe.lap_start()
		c.loadout = world.call(&"_loadout_of", p, tick)
		t_c = FcFrameProbe.lap(&"brc_loadout", t_c)
		world.call(&"_weapon_of", c, p)
		FcFrameProbe.lap(&"brc_weapon", t_c)
	var launch := false
	if controlled:
		var tunables: Variant = world.get(&"_tunables")
		if tunables == null:
			tunables = world.call(&"_body_tunables")
			world.set(&"_tunables", tunables)
		launch = tunables != null and (tunables as GSFpsTunables).launch_enabled
	if not bool(native.call(&"fill", contacts, records, eye, aim, launch)):
		push_error("bot contacts: gs-sim's contact build does not fit these players' state; the script builds them from now on")
		_sim = null
		contacts.clear()
		by_player.clear()
		return false
	built += 1
	if rows:
		(world.get(&"_bot_rows") as Object).call(&"take", contacts.duplicate(), ids, native)
	return true
