extends RefCounted
## The bots' contact build in gs-sim ([code]GSSimBotContacts[/code], `bot_native_contacts`): one packed record per player, and gs-sim writes
## every per-tick [GSBotContact] field and the sight rows in one call, to the bit the script loop's (`headless_botthreads`). [member delta],
## [member table] and [member arms] narrow what it writes; off, without the library or when the records do not fit, the script loop builds them.

const CHANNEL := "fc.bots"
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
## Whether gs-sim writes only the kept fields that changed (cvar `bot_native_contacts_delta`; needs a gs-sim with fill_changed).
static var delta: bool = true
## Ticks whose contacts gs-sim built, for the suites.
static var built: int = 0
## Whether gs-sim fills the contact table instead of the objects (cvar `bot_contact_table`; needs fill_table).
static var table: bool = true
## Ticks whose contacts gs-sim filled as a table, for the suites.
static var tabled: int = 0
## Whether gs-sim writes the weapon in hand (cvar `bot_native_contact_arms`; needs fill_arms).
static var arms: bool = true
## Ticks whose weapons in hand gs-sim wrote, for the suites.
static var armed: int = 0
## Whether gs-sim reads the think tiers' rows and the near grid's cells off the table it filled (cvar `bot_native_world_rows`;
## needs world_rows). Off, or without a table this tick, the script walks the table for each.
static var world_rows: bool = true
## Ticks whose tier and near rows gs-sim read, for the suites.
static var world_rowed: int = 0
## What [method read_world_rows] hands back when the script reads the rows: one empty array, never written.
static var _NO_ROWS: Array = []  # perf-lint: allow all one empty untyped array for the life of the server, shaped as the seven rows
## Whether [method FcBots.World.par_begin] packs this tick's drop table on the main thread (cvar `bot_drops_warm`), so the
## brains on workers read it instead of the first one packing it while the rest wait on gs-bot's drop lock.
static var drops_warm: bool = true
## Ticks whose drop table was packed on the main thread, for the suites.
static var drops_warmed: int = 0
## Whether this gs-bot's world has drop_table (asked once a process); -1 until asked.
static var _has_drop_table: int = -1
## The bots' main-thread refresh in gs-sim (cvar `bot_native_refresh`): off, the script builds the contacts whatever
## [member enabled] says, and the brains hear in script ([code]GSBotBrain.native_hear[/code]). See [method set_native_refresh].
static var native_refresh: bool = true
## Whether a missing native half of the refresh was reported (once a process).
static var _refresh_warned: bool = false
## The rows [method tier_rows] last filled, reused tick to tick.
static var tier_eyes := PackedVector3Array()
static var tier_looks := PackedVector3Array()
static var tier_ids := PackedInt32Array()
static var tier_at := PackedVector3Array()

var _sim: Object = null
var _tried: bool = false
## Whether gs-sim has fill_changed.
var _has_delta: bool = false
## Whether gs-sim has fill_table.
var _has_table: bool = false
var _table: GSBotContactTable = null
## Whether gs-sim has fill_arms.
var _has_arms: bool = false
## Whether gs-sim has world_rows.
var _has_world_rows: bool = false
## The tick whose table gs-sim filled last, and that table's player ids.
var _tabled_tick: int = -1
var _tabled_ids := PackedInt64Array()
## Whether the last build's weapons in hand were gs-sim's, so what it remembers writing is what the contacts hold.
var _arms_fresh: bool = false
## gs-sim's interned style class index by weapon definition.
var _class_ids: Dictionary[GSWeaponDef, int] = {}
var _arm_classes := PackedInt32Array()
var _arm_rounds := PackedInt64Array()
## Whether the last build was gs-sim's, so what it remembers writing is what the contacts hold.
var _fresh: bool = false
var _head := PackedFloat64Array()
## The state columns of a player without a controller: its position, then zeros.
var _bare := PackedFloat64Array()


## `bot_native_refresh`: [param on] builds the contacts (with [member enabled]) and hears in gs-sim, off both in script; the same
## contacts, sounds and match to the bit (`headless_botthreads` plays seeded 31-bot matches both ways). A library without one of
## them warns once and that half stays in script.
static func set_native_refresh(on: bool) -> void:
	native_refresh = on
	GSBotBrain.native_hear = on
	if on and not _refresh_warned and not refresh_available():
		_refresh_warned = true
		GSLog.warn(CHANNEL, "bot_native_refresh: this gs-sim has no GSSimBotContacts or GSSimBotMind.hear; that half of the bots' refresh runs in script")


## Whether gs-sim has both halves of the refresh (the contact build and the hearing).
static func refresh_available() -> bool:
	return GSSim.has(&"contacts") and ClassDB.class_exists(GSBotAim.MIND_CLASS) and ClassDB.class_has_method(GSBotAim.MIND_CLASS, &"hear")


## gs-sim's contact build, or null (off, or no library).
func sim() -> Object:
	if not enabled or not native_refresh:
		return null
	if not _tried:
		_tried = true
		if not GSSim.has(&"contacts") and not _refresh_warned:
			_refresh_warned = true
			GSLog.warn(CHANNEL, "bot contacts: this gs-sim has no GSSimBotContacts; the script builds the bots' contacts")
		if GSSim.has(&"contacts"):
			_create_sim()
	return _sim


## Makes gs-sim's contact build once and notes which of its fills this library has.
func _create_sim() -> void:
	_sim = ClassDB.instantiate(&"GSSimBotContacts")
	_has_delta = _sim.has_method(&"fill_changed")
	_has_table = _sim.has_method(&"fill_table")
	_has_arms = _sim.has_method(&"fill_arms")
	_has_world_rows = _sim.has_method(&"world_rows")
	_head.resize(HEAD)
	_bare.resize(int(_sim.stride()) - HEAD)


## Builds [param world]'s contacts for [param players] in gs-sim, as [method FcBots.World.refresh]'s loop does, and hands the sight
## rows to its row table when [param rows]. False, with the contacts and players cleared again, when gs-sim is off or the records do
## not fit it (a state of another stride): the caller's script loop builds them.
func build(world: Object, players: Array[FcPlayer], tick: int, eye: float, aim: float, teams: bool, rows: bool) -> bool:
	_tabled_tick = -1
	var native := sim()
	if native == null:
		_fresh = false
		_arms_fresh = false
		return false
	var contacts: Array = world._contacts  # perf-lint: allow untyped_array gs-sim takes a plain VarArray; a typed array fails the call (error 1337, gate 1127)
	var by_id: Dictionary[int, GSBotContact] = world._by_id
	var by_player: Dictionary[int, FcPlayer] = world._players
	var records := PackedFloat64Array()
	var ids := PackedInt64Array()
	var head := _head
	var controlled := false
	var arming := arms and _has_arms and bool(world.get(&"_styled"))
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
		if arming:
			continue
		var t_c := FcFrameProbe.lap_start()
		c.loadout = world._loadout_of(p, tick)
		t_c = FcFrameProbe.lap(&"brc_loadout", t_c)
		world._weapon_of(c, p)
		FcFrameProbe.lap(&"brc_weapon", t_c)
	var launch := controlled and _launch_enabled(world)
	var tabling := table and _has_table
	var changed_only := delta and _has_delta and not tabling
	if changed_only and not _fresh:
		native.call(&"forget")
	_fresh = false
	var fits: bool
	if tabling:
		fits = native.call(&"fill_table", records, eye, aim, launch)
	else:
		fits = native.call(&"fill_changed" if changed_only else &"fill", contacts, records, eye, aim, launch)
	if not fits:
		push_error("bot contacts: gs-sim's contact build does not fit these players' state; the script builds them from now on")
		_sim = null
		_arms_fresh = false
		contacts.clear()
		by_player.clear()
		return false
	built += 1
	_arms_fresh = arming and _arm(world, native, players, contacts, tick)
	if tabling:
		_take_table(world, native, tick, contacts, ids)
	else:
		_fresh = true
	if rows:
		(world.get(&"_bot_rows") as Object).call(&"take", contacts.duplicate(), ids, native)
	return true


## Whether [param world]'s bodies may air-jump (its tunables, made once a tick).
static func _launch_enabled(world: Object) -> bool:
	var tunables: GSFpsTunables = world._tunables
	if tunables == null:
		tunables = world._body_tunables()
		world._tunables = tunables
	return tunables != null and tunables.launch_enabled


## The loadouts, then the weapons in hand of [param contacts] through gs-sim's fill_arms (each style class interned once per definition);
## a gs-sim that declines them leaves it to the world's [code]_weapon_of[/code] from now on. Whether gs-sim wrote them.
func _arm(world: Object, native: Object, players: Array[FcPlayer], contacts: Array, tick: int) -> bool:  # perf-lint: allow untyped_array gs-sim takes a plain VarArray; a typed array fails the call (error 1337, gate 1127)
	var t_c := FcFrameProbe.lap_start()
	var n := players.size()
	for i in n:
		contacts[i].loadout = world._loadout_of(players[i], tick)
	t_c = FcFrameProbe.lap(&"brc_loadout", t_c)
	_arm_classes.resize(n)
	_arm_rounds.resize(n * 2)
	for i in n:
		var p: FcPlayer = players[i]
		var slot: GSWeaponSlot = p.arsenal.current() if p.arsenal != null else null
		if slot == null or slot.def == null:
			_arm_classes[i] = -1
			_arm_rounds[i * 2] = 0
			_arm_rounds[i * 2 + 1] = 0
			continue
		var def := slot.def
		var k: int = _class_ids.get(def, -1)
		if k < 0:
			k = native.intern_class(world._class_of(def))
			_class_ids[def] = k
		_arm_classes[i] = k
		_arm_rounds[i * 2] = slot.magazine
		_arm_rounds[i * 2 + 1] = def.magazine
	var wrote: bool = native.fill_arms(contacts, _arm_classes, _arm_rounds, delta and _arms_fresh)
	if wrote:
		armed += 1
	else:
		push_error("bot contacts: gs-sim's fill_arms declined these weapons; the script writes them from now on")
		_has_arms = false
		for i in n:
			world._weapon_of(contacts[i], players[i])
	FcFrameProbe.lap(&"brc_weapon", t_c)
	return wrote


## Hands gs-sim's filled columns to [param world] as its [GSBotContactTable]. The objects hold only what a read of their row
## wrote, so the next delta build writes every field again (_fresh stays false).
func _take_table(world: Object, native: Object, tick: int, contacts: Array, ids: PackedInt64Array) -> void:  # perf-lint: allow untyped_array gs-sim takes a plain VarArray; a typed array fails the call (error 1337, gate 1127)
	if _table == null:
		_table = GSBotContactTable.new()
	_table.take(tick, contacts, ids, native.positions(), native.velocities(), native.floats(),
		native.teams(), native.flags(), native.points(), native.eyes(), native.alive())
	world.set_table(_table)
	tabled += 1
	_tabled_tick = tick
	_tabled_ids = ids


## gs-sim's read of [param world]'s tier rows into [member tier_eyes], [member tier_looks], [member tier_ids], [member tier_at] (empty
## when not [param applies]) and its near cells (none when [param cell] is 0), off the table it filled at [param tick], to the bit
## [method tier_rows] and [code]_near_refresh[/code]. Empty when off, without world_rows or without this tick's table: the script reads them.
## Else gs-sim's seven rows: the four tier rows, then the near cells as [code]keys, starts, rows[/code] (at 4, 5, 6;
## [code]rows[starts[k]..starts[k + 1]][/code] in cell [code]keys[k][/code]).
func read_world_rows(brains: Dictionary[int, GSBotBrain], tick: int, applies: bool, cell: float) -> Array:  # perf-lint: allow untyped_array seven packed arrays of different types, as gs-sim returns them
	if not world_rows or not _has_world_rows or _sim == null or tick != _tabled_tick:
		return _NO_ROWS
	var rows: Array = _sim.call(&"world_rows", _tabled_ids, PackedInt64Array(brains.keys()), applies, cell)  # perf-lint: allow all gs-sim is loaded by name (one call a tick) and hands back seven packed arrays of different types
	if rows.size() != 7:
		push_error("bot contacts: gs-sim's world_rows does not fit this table; the script reads the tier and near rows from now on")
		_has_world_rows = false
		return _NO_ROWS
	tier_eyes = rows[0]
	tier_looks = rows[1]
	tier_ids = rows[2]
	tier_at = rows[3]
	world_rowed += 1
	return rows


## Fills the tiers' rows [member tier_eyes], [member tier_looks], [member tier_ids], [member tier_at]: the live people's eyes and views
## and the live bots' ids and positions, from [param t] when there is a table, else from [param all]; empty when not [param applies].
static func tier_rows(t: GSBotContactTable, all: Array, brains: Dictionary[int, GSBotBrain], applies: bool) -> void:  # perf-lint: allow untyped_array gs-sim takes a plain VarArray; a typed array fails the call (error 1337, gate 1127)
	var eyes := tier_eyes
	var looks := tier_looks
	var ids := tier_ids
	var at := tier_at
	eyes.clear()
	looks.clear()
	ids.clear()
	at.clear()
	if applies and t != null:
		for i in t.size():
			if t.flags[i] & GSBotContactTable.ALIVE == 0:
				continue
			if brains.has(int(t.ids[i])):
				ids.append(t.ids[i])
				at.append(t.positions[i])
			else:
				eyes.append(t.eyes[i])
				looks.append(GSBotIntent.direction(t.floats[i * GSBotContactTable.FLOATS + 2], t.floats[i * GSBotContactTable.FLOATS + 3]))
	elif applies:
		for c: GSBotContact in all:
			if brains.has(c.id):
				if c.alive:
					ids.append(c.id)
					at.append(c.position)
			elif c.alive:
				eyes.append(c.eye())
				looks.append(GSBotIntent.direction(c.view_yaw, c.view_pitch))
	tier_eyes = eyes
	tier_looks = looks
	tier_ids = ids
	tier_at = at
