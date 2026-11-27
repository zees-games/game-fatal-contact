extends RefCounted
## The bots' contact build in gs-sim ([code]GSSimBotContacts[/code], cvar `bot_native_contacts`): [method build] packs one record per
## player on the main thread (flags, team, pitch, health, then the [GSFpsState] columns as they are), and gs-sim writes every per-tick
## [GSBotContact] field and the native sight scan's rows from them in one call. The loadout and the weapon in hand stay here.
## The same contacts and rows as [method FcBots.World.refresh]'s script loop, to the bit (`headless_botthreads` compares them over
## randomized player states). Off, without the library (the web) or when the records do not fit, the script loop builds them.
## With [member delta], gs-sim writes the fields a player keeps from tick to tick only when they change ([code]fill_changed[/code]);
## a tick the script loop built makes the next native build write every field again.
## With [member table] (gs-bot 41, a gs-sim with fill_table), gs-sim writes no contact object at all: it fills packed columns that
## become the world's [GSBotContactTable], and a contact object is written from its row only when something reads it.
## With [member arms] (a gs-sim with fill_arms), the weapon in hand ([code]weapon_class[/code], [code]magazine[/code]) is gathered
## here as an interned class and two ints per player and gs-sim writes it in one call (only what changed, with [member delta]),
## instead of one [code]_weapon_of[/code] call and two property writes per player.

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

var _sim: Object = null
var _tried: bool = false
## Whether gs-sim has fill_changed.
var _has_delta: bool = false
## Whether gs-sim has fill_table.
var _has_table: bool = false
var _table: GSBotContactTable = null
## Whether gs-sim has fill_arms.
var _has_arms: bool = false
## Whether the last build's weapons in hand were gs-sim's, so what it remembers writing is what the contacts hold.
var _arms_fresh: bool = false
## gs-sim's interned style class index by weapon definition.
var _class_ids: Dictionary = {}
var _arm_classes := PackedInt32Array()
var _arm_rounds := PackedInt64Array()
## Whether the last build was gs-sim's, so what it remembers writing is what the contacts hold.
var _fresh: bool = false
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
			_has_delta = _sim.has_method(&"fill_changed")
			_has_table = _sim.has_method(&"fill_table")
			_has_arms = _sim.has_method(&"fill_arms")
			_head.resize(HEAD)
			_bare.resize(int(_sim.call(&"stride")) - HEAD)
	return _sim


## Builds [param world]'s contacts for [param players] in gs-sim, as [method FcBots.World.refresh]'s loop does, and hands the sight
## rows to its row table when [param rows]. False, with the contacts and players cleared again, when gs-sim is off or the records do
## not fit it (a state of another stride): the caller's script loop builds them.
func build(world: Object, players: Array, tick: int, eye: float, aim: float, teams: bool, rows: bool) -> bool:
	var native := sim()
	if native == null:
		_fresh = false
		_arms_fresh = false
		return false
	var contacts: Array = world.get(&"_contacts")
	var by_id: Dictionary = world.get(&"_by_id")
	var by_player: Dictionary = world.get(&"_players")
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
		c.loadout = world.call(&"_loadout_of", p, tick)
		t_c = FcFrameProbe.lap(&"brc_loadout", t_c)
		world.call(&"_weapon_of", c, p)
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
	var tunables: Variant = world.get(&"_tunables")
	if tunables == null:
		tunables = world.call(&"_body_tunables")
		world.set(&"_tunables", tunables)
	return tunables != null and (tunables as GSFpsTunables).launch_enabled


## The loadouts, then the weapons in hand of [param contacts] (one per player of [param players]) through gs-sim's fill_arms: each
## player's style class interned once per weapon definition, its slot's rounds and the definition's magazine size. A gs-sim that
## declines them leaves it to the world's [code]_weapon_of[/code] from now on. Each half is one probe lap, not one per player.
## Whether gs-sim wrote them (so it knows what the contacts hold).
func _arm(world: Object, native: Object, players: Array, contacts: Array, tick: int) -> bool:
	var t_c := FcFrameProbe.lap_start()
	var n := players.size()
	for i in n:
		(contacts[i] as GSBotContact).loadout = world.call(&"_loadout_of", players[i], tick)
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
		var k: Variant = _class_ids.get(def)
		if k == null:
			k = int(native.call(&"intern_class", world.call(&"_class_of", def)))
			_class_ids[def] = k
		_arm_classes[i] = k
		_arm_rounds[i * 2] = slot.magazine
		_arm_rounds[i * 2 + 1] = def.magazine
	var wrote: bool = native.call(&"fill_arms", contacts, _arm_classes, _arm_rounds, delta and _arms_fresh)
	if wrote:
		armed += 1
	else:
		push_error("bot contacts: gs-sim's fill_arms declined these weapons; the script writes them from now on")
		_has_arms = false
		for i in n:
			world.call(&"_weapon_of", contacts[i], players[i])
	FcFrameProbe.lap(&"brc_weapon", t_c)
	return wrote


## Hands gs-sim's filled columns to [param world] as its [GSBotContactTable]. The objects hold only what a read of their row
## wrote, so the next delta build writes every field again (_fresh stays false).
func _take_table(world: Object, native: Object, tick: int, contacts: Array, ids: PackedInt64Array) -> void:
	if _table == null:
		_table = GSBotContactTable.new()
	_table.take(tick, contacts, ids, native.call(&"positions"), native.call(&"velocities"), native.call(&"floats"),
		native.call(&"teams"), native.call(&"flags"), native.call(&"points"), native.call(&"eyes"), native.call(&"alive"))
	world.call(&"set_table", _table)
	tabled += 1


## The tiers' rows [eyes, looks, ids, at]: the live people's eyes and views and the live bots' ids and positions, from
## [param t] when there is a table, else from [param all]; empty lists when not [param applies].
static func tier_rows(t: GSBotContactTable, all: Array, brains: Dictionary, applies: bool) -> Array:
	var eyes := PackedVector3Array()
	var looks := PackedVector3Array()
	var ids := PackedInt32Array()
	var at := PackedVector3Array()
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
	return [eyes, looks, ids, at]
