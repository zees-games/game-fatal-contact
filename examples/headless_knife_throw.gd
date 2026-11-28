extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcEvents := preload("../game/fc_events.gd")
const FcEvent := preload("../game/fc_event.gd")
const FcKnifeEvents := preload("../game/fc_knife_events.gd")
const FcKnifeFollow := preload("../game/fc_knife_follow.gd")
const FcThrowMeter := preload("../game/fc_throw_meter.gd")
const FcAttach := preload("../game/fc_attach.gd")
const FcContent := preload("../game/fc_content.gd")

## Knife throwing through the whole game: the aim key throws the knife in hand, a miss bounces
## and settles, an enemy hit kills and the knife stays in the body, walking over either picks
## it up, a team-mate is not killed; plus the MORE/KNIFE wire record. Run `headless_knife_throw`.

const TICK_RATE := 64
## One second of aim at the 64 Hz tick, with a few ticks over: the throw meter is full.
const HOLD_FULL := 70
## The throws the layer announced, newest last: {"id", "speed", "glide", "turn"}, read at the moment of the throw.
var _throws: Array = []
const EXPECTED_SECTIONS := 4
const EXPECTED_CHECKS := 52

var _checks := 0
var _failed := 0
var _entered := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _first_on_team(game: FcGame, ids: Array, thrower: int, same: bool) -> int:
	for id in ids.slice(1):
		if (game.team_of(id) == game.team_of(thrower)) == same:
			return id
	return 0


## Puts each of [param where]'s ids at its spot and everybody else 30 m off, held there for three ticks.
func _place(game: FcGame, ids: Array, where: Dictionary) -> void:
	for _k in 3:
		for id in ids:
			var p = game.player_for(id)
			if p != null:
				p.controller.state.position = where.get(id, Vector3(30.0 + float(id), where.values()[0].y, 30.0))
				p.controller.state.velocity = Vector3.ZERO
		game.tick({})


## The knife back in [param id]'s hand, or false when they have none.
func _knife_in_hand(game: FcGame, id: int) -> bool:
	var arsenal: GSWeaponArsenal = game.player_for(id).arsenal
	var home := arsenal.catalogue.get_def(&"knife").slot
	for _try in 4:
		var held := arsenal.slot_at(home)
		if held != null and held.id() == &"knife":
			break
		if held != null:
			var _gone := arsenal.drop_from_slot(home)
		elif not arsenal.carries(&"knife"):
			var _given := arsenal.give(&"knife", true)
	arsenal.bring_to_hand(home)
	var now := arsenal.current_def()
	if now == null or now.id != &"knife":
		print("knife not in hand: slot %d holds %s, in hand %s" % [home, arsenal.weapons_in(home).map(func(w): return w.id()), now.id if now != null else &""])
	return now != null and now.id == &"knife"


## Holds the aim key down along yaw/pitch for [param hold_ticks] ticks (a throw winds up while the aim key is
## held; the default is past full power at one second), then lets go: the release throws.
func _press_aim(game: FcGame, id: int, yaw: float, pitch: float, hold_ticks: int = HOLD_FULL) -> void:
	_hold_aim(game, id, yaw, pitch, hold_ticks)
	game.tick({})


## The aim key down for [param hold_ticks] ticks and one tick up, without the empty tick after.
func _hold_aim(game: FcGame, id: int, yaw: float, pitch: float, hold_ticks: int) -> void:
	var open := GSWeaponCommand.new()
	game.tick({id: [GSFpsCommand.new(), open]})
	for _t in hold_ticks:
		# A fresh command each tick: the knife layer clears the aim button on the one it reads.
		var fire := GSWeaponCommand.new()
		fire.yaw = yaw
		fire.pitch = pitch
		fire.set_button(GSWeaponCommand.BUTTON_AIM, true)
		game.tick({id: [GSFpsCommand.new(), fire]})
	var up := GSWeaponCommand.new()
	up.yaw = yaw
	up.pitch = pitch
	game.tick({id: [GSFpsCommand.new(), up]})


## Ticks until the only knife stops flying (or [param seconds] pass); returns it, or null if none.
func _settle(game: FcGame, seconds: float, hold: Dictionary = {}) -> GSWeaponKnives.Knife:
	for _k in int(seconds * TICK_RATE):
		var all := game.knives.entries()
		if all.is_empty() or (all[0] as GSWeaponKnives.Knife).phase != GSWeaponKnives.Phase.FLY:
			break
		for id in hold:
			game.player_for(id).controller.state.position = hold[id]
		game.tick({})
		await get_tree().physics_frame
	var left := game.knives.entries()
	return left[0] if not left.is_empty() else null


func _run() -> void:
	_test_wire()

	var game := FcGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = FcMode.team_deathmatch()
	add_child(game)
	var ready := game.setup(FcMap.atrium())
	_check(ready.ok, "a team game sets up", str(ready.error))
	game.start(0)
	# The charged throws hold the key for a second each, so the match clock runs past the warmup into a round's
	# countdown: no freeze there, or the arsenal would be disabled mid-throw.
	game.match_node.rules.freeze_during_countdown = false
	var ids: Array = []
	for i in 6:
		var _added := game.add_player(10 + i, "P%d" % i)
		ids.append(10 + i)
	game.tick({})
	_entered += 1
	var thrower := int(ids[0])
	var mate := _first_on_team(game, ids, thrower, true)
	var enemy := _first_on_team(game, ids, thrower, false)
	_check(game.knives != null and mate > 0 and enemy > 0, "the game builds the knives layer; a mate and an enemy", "%d %d" % [mate, enemy])
	var events: Array = []
	game.knives.changed.connect(func(id: int, _o: int, phase: int, _v: int, _a: Vector3, _m: Vector3) -> void: events.append([id, phase]))

	var floor_y: float = game.player_for(thrower).controller.state.position.y
	var here := Vector3(0.0, floor_y, 0.0)

	await _miss_and_pickup(game, ids, thrower, here, floor_y)

	_check_throw_disabled(game, ids, thrower, here)

	# At an enemy 6 m ahead: dead outright, the knife stays in them.
	var target := here + Vector3(0.0, 0.0, -6.0)
	_place(game, ids, {thrower: here, enemy: target})
	var hp_before: float = game.combat.health_of(enemy).health
	_check(hp_before > 50.0 and game.combat.health_of(enemy).alive, "the enemy stands there unhurt", str(hp_before))
	var eye: Vector3 = game.player_for(thrower).muzzle_position()
	var chest := target + Vector3(0.0, 1.1, 0.0)
	var pitch := rad_to_deg(atan2(chest.y - eye.y, eye.distance_to(Vector3(chest.x, eye.y, chest.z))))
	var _held := _knife_in_hand(game, thrower)
	events.clear()
	_press_aim(game, thrower, 0.0, pitch)
	var stuck: GSWeaponKnives.Knife = await _settle(game, 2.0, {enemy: target})
	_check(not game.combat.health_of(enemy).alive, "the thrown knife kills the enemy outright", str(game.combat.health_of(enemy).health))
	_check(stuck != null and stuck.phase == GSWeaponKnives.Phase.STUCK and stuck.victim == enemy, "and stays stuck in them", str(stuck.phase if stuck != null else -1))
	_check(stuck != null and stuck.at.distance_to(target) < 1.5, "at the body", str(stuck.at if stuck != null else Vector3.ZERO))
	_check(events.any(func(e: Array) -> bool: return int(e[1]) == GSWeaponKnives.Phase.STUCK), "the layer said so (a STUCK change for the wire)")
	for _k in 4:
		game.tick({})
	_check(game.knives.count() == 1, "the embedded knife stays while nobody comes for it")

	_check_pickup_rule(game, ids, thrower, stuck, target, floor_y, events)

	await _throw_at_mate_and_slow(game, ids, thrower, mate, here, floor_y, pitch)
	_finished += 1

	await _charge_and_boomerang(game, ids, thrower, here)
	_finished += 1
	_test_pieces()

	_report()


func _miss_and_pickup(game: FcGame, ids: Array, thrower: int, here: Vector3, floor_y: float) -> void:
	# A throw at the floor ahead: gone from the hand, bounces, and settles on the floor.
	_place(game, ids, {thrower: here})
	_check(_knife_in_hand(game, thrower), "the thrower has the knife in hand")
	_press_aim(game, thrower, 0.0, -35.0)
	var thrown := game.knives.count()
	_check(thrown == 1 and not game.player_for(thrower).arsenal.carries(&"knife"), "the aim key throws it: one knife out, none in the arsenal", str(thrown))
	var miss: GSWeaponKnives.Knife = await _settle(game, 6.0, {thrower: here})
	_check(miss != null and miss.phase == GSWeaponKnives.Phase.REST, "the miss comes to rest", str(miss.phase if miss != null else -1))
	_check(miss != null and miss.bounces >= 1, "after bouncing", str(miss.bounces if miss != null else -1))
	_check(miss != null and absf(miss.at.y - floor_y) < 0.4, "on the floor", "%s vs %s" % [miss.at if miss != null else Vector3.ZERO, floor_y])

	# Walking over it picks it up.
	var lying: Vector3 = miss.at if miss != null else here
	_place(game, ids, {thrower: Vector3(lying.x, floor_y, lying.z) + Vector3(0.4, 0.0, 0.0)})
	_check(game.player_for(thrower).arsenal.carries(&"knife") and game.knives.count() == 0, "walking over the knife on the floor picks it up")


func _report() -> void:
	print("%d sections entered, %d finished" % [_entered, _finished])
	var ok := _failed == 0 and _entered == EXPECTED_SECTIONS and _finished == EXPECTED_SECTIONS and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _check_throw_disabled(game: FcGame, ids: Array, thrower: int, here: Vector3) -> void:
	# Disabled: the aim key does not throw.
	game.knife_rules["enabled"] = false
	_place(game, ids, {thrower: here})
	var _again := _knife_in_hand(game, thrower)
	_press_aim(game, thrower, 0.0, -35.0)
	_check(game.knives.count() == 0 and game.player_for(thrower).arsenal.carries(&"knife"), "fc_knife_throw 0 keeps the knife in hand")
	game.knife_rules["enabled"] = true


func _check_pickup_rule(game: FcGame, ids: Array, thrower: int, stuck: GSWeaponKnives.Knife, target: Vector3, floor_y: float, events: Array) -> void:
	# Pickup off for the moment: walking over the body leaves it there.
	game.knife_rules["pickup"] = 0.0
	var body: Vector3 = stuck.at if stuck != null else target
	_place(game, ids, {thrower: Vector3(body.x, floor_y, body.z)})
	_check(game.knives.count() == 1 and not game.player_for(thrower).arsenal.carries(&"knife"), "fc_knife_throw_pickup 0 leaves it in the body")
	game.knife_rules["pickup"] = 1.0
	_place(game, ids, {thrower: Vector3(body.x, floor_y, body.z)})
	_check(game.knives.count() == 0 and game.player_for(thrower).arsenal.carries(&"knife"), "walking over the body takes the knife out of it")
	_check(events.any(func(e: Array) -> bool: return int(e[1]) == GSWeaponKnives.Phase.GONE), "and the layer said it went")


func _throw_at_mate_and_slow(game: FcGame, ids: Array, thrower: int, mate: int, here: Vector3, floor_y: float, pitch: float) -> void:
	# A team-mate: friendly fire is off, so the knife bounces off and they live.
	var mate_at := here + Vector3(0.0, 0.0, -6.0)
	_place(game, ids, {thrower: here, mate: mate_at})
	var _held2 := _knife_in_hand(game, thrower)
	_press_aim(game, thrower, 0.0, pitch)
	var off: GSWeaponKnives.Knife = await _settle(game, 6.0, {mate: mate_at})
	_check(game.combat.health_of(mate).alive, "a thrown knife does not kill a team-mate")
	_check(off != null and off.phase != GSWeaponKnives.Phase.STUCK, "it bounces off instead of sticking", str(off.phase if off != null else -1))

	# The speed rule: a slow throw is still flying where a fast one would have landed.
	if off != null:
		_place(game, ids, {thrower: Vector3(off.at.x, floor_y, off.at.z)})
	game.knife_rules["speed"] = 10.0
	game.knives.clear()
	_throws.clear()
	_place(game, ids, {thrower: here})
	var _held3 := _knife_in_hand(game, thrower)
	_press_aim(game, thrower, 0.0, 0.0)
	var slow: GSWeaponKnives.Knife = game.knives.entries()[0] if game.knives.count() == 1 else null
	_check(slow != null and absf(slow.velocity.length() - 10.0) < 1.0, "fc_knife_throw_speed sets the throw speed", str(slow.velocity.length() if slow != null else -1.0))
	game.knife_rules["speed"] = 40.0


## Settles the layer back to nothing in flight, the knife back in [param id]'s hand at [param here].
func _on_knife_changed(id: int, _owner: int, phase: int, _victim: int, _at: Vector3, motion: Vector3, game: FcGame) -> void:
	if phase == GSWeaponKnives.Phase.FLY and game.knives.get_knife(id) != null:
		_throws.append({"id": id, "speed": motion.length(), "glide": game.knives.glides(id), "turn": game.knives.turn_of(id)})


func _last_throw() -> Dictionary:
	return _throws[-1] if not _throws.is_empty() else {"id": -1, "speed": -1.0, "glide": false, "turn": Vector3.ZERO}


func _reset_throw(game: FcGame, ids: Array, thrower: int, here: Vector3) -> void:
	game.knives.clear()
	_throws.clear()
	_place(game, ids, {thrower: here})
	var _held := _knife_in_hand(game, thrower)


## The charged throw (on by default, one second to full) and the Boomerang attachment through the whole game.
func _charge_and_boomerang(game: FcGame, ids: Array, thrower: int, here: Vector3) -> void:
	_entered += 1
	var fresh := FcGame.new()
	_check(bool(fresh.knife_rules["charge"]) and is_equal_approx(float(fresh.knife_rules["charge_sec"]), 1.0), "the charge is on by default, one second to full")
	fresh.free()
	game.knife_rules["speed"] = 40.0
	game.knives.changed.connect(_on_knife_changed.bind(game))

	# Held half a second: the meter is about half full, and the knife is still in hand.
	_reset_throw(game, ids, thrower, here)
	for _t in 33:
		var fire := GSWeaponCommand.new()
		fire.set_button(GSWeaponCommand.BUTTON_AIM, true)
		game.tick({thrower: [GSFpsCommand.new(), fire]})
	var fill: float = game.knives.charge_of(thrower)
	_check(absf(fill - 0.5) < 0.08 and game.knives.count() == 0, "holding aim winds up: the meter reads about half at half a second", str(fill))
	var wound := game.player_for(thrower)
	_check(absf(wound.windup - fill) < 0.05, "the player carries the server's wind-up for the figure and the snapshot", str(wound.windup))
	var up := GSWeaponCommand.new()
	game.tick({thrower: [GSFpsCommand.new(), up]})
	_check(wound.windup < 0.0, "and it is below zero once the knife is away", str(wound.windup))
	var want := 40.0 * lerpf(0.35, 1.0, fill)
	_check(absf(float(_last_throw()["speed"]) - want) < 1.5, "released at half it leaves at half power", "%s vs %s" % [_last_throw()["speed"], want])

	# Tapped: the minimum; held a second: the full speed.
	_reset_throw(game, ids, thrower, here)
	_press_aim(game, thrower, 0.0, 0.0, 1)
	_check(absf(float(_last_throw()["speed"]) - 14.0) < 1.0, "a tap throws at charge_min (0.35) of the speed", str(_last_throw()["speed"]))
	_reset_throw(game, ids, thrower, here)
	_hold_aim(game, thrower, 0.0, 60.0, HOLD_FULL)
	_check(absf(float(_last_throw()["speed"]) - 40.0) < 1.0, "held a second it throws at full speed", str(_last_throw()["speed"]))

	# Charge off (fc_knife_throw_charge 0): the press throws at once, at full speed.
	game.knife_rules["charge"] = false
	_reset_throw(game, ids, thrower, here)
	game.tick({thrower: [GSFpsCommand.new(), GSWeaponCommand.new()]})
	var press := GSWeaponCommand.new()
	press.pitch = 60.0
	press.set_button(GSWeaponCommand.BUTTON_AIM, true)
	game.tick({thrower: [GSFpsCommand.new(), press]})
	_check(absf(float(_last_throw()["speed"]) - 40.0) < 1.0, "with the charge off the press throws at once at full speed", str(_last_throw()["speed"]))
	game.knife_rules["charge"] = true
	game.tick({})

	# The Boomerang: the knife carries the mount, the catalogue the attachment, and a fitted knife glides.
	var arsenal: GSWeaponArsenal = game.player_for(thrower).arsenal
	var def := arsenal.catalogue.get_def(&"knife")
	_check(def.mounts.has(FcContent.KNIFE_MOUNT), "the knife has the grip mount")
	var boom := FcAttach.catalogue().get_attachment(FcAttach.BOOMERANG)
	_check(boom != null and boom.fits(def) and GSWeaponKnives.PARAM_BOOMERANG in boom.params_set, "the catalogue has a Boomerang that fits it")
	_reset_throw(game, ids, thrower, here)
	var fitting := GSWeaponFitting.make(&"knife")
	fitting.fit(FcContent.KNIFE_MOUNT, FcAttach.BOOMERANG)
	var fitted := arsenal.fit(def.slot, fitting)
	_check(fitted.ok, "the Boomerang fits the knife in hand", str(fitted.error))
	_hold_aim(game, thrower, 0.0, 60.0, HOLD_FULL)
	var boomerang := _last_throw()
	_check(bool(boomerang["glide"]), "a fitted knife is thrown as a boomerang, gliding")
	# gs-weapon 46+: the thrower waits for the catch with an empty hand, not on the pistol the knife's going would select.
	var bare := not arsenal.has_method(&"empty_hand") or (arsenal.current_slot() == 0 and not arsenal.slots().is_empty())
	_check(bare, "the thrower waits for the catch bare-handed, not on the pistol", "slot %d" % arsenal.current_slot())
	# gs-weapon 43+: the turn is zero on the straight leg and only set while circling, so send a circling-leg turn.
	var circling := Vector3(0.0, 4.0, 0.0)
	var body := FcKnifeEvents.write_knife(int(boomerang["id"]), thrower, GSWeaponKnives.Phase.FLY, 0, here, Vector3(0.0, 0.0, -20.0), bool(boomerang["glide"]), circling)
	var reader := GSNetReader.new(body)
	var _kind := FcKnifeEvents.read_more(reader)
	var back := FcKnifeEvents.read_knife(reader)
	_check(bool(back["glide"]) and (back["turn"] as Vector3).distance_to(circling) < 0.05, "its curve (glide and turn) goes over the KNIFE record", str(back["turn"]))
	_reset_throw(game, ids, thrower, here)
	var _cleared := arsenal.fit(def.slot, GSWeaponFitting.make(&"knife"))


## The client's pieces without a game: the meter, the rules follower, the wire's curve.
func _test_pieces() -> void:
	_entered += 1
	var rules := GSWeaponKnives.DEFAULT_RULES.duplicate()
	rules["charge"] = true
	var meter := FcThrowMeter.new()
	_check(meter.advance(0.5, false, rules) == -1.0, "the meter is hidden while aim is not held")
	var half := meter.advance(0.5, true, rules)
	_check(absf(half - 0.5) < 0.001, "half a second of aim is half the meter", str(half))
	_check(meter.advance(2.0, true, rules) == 1.0 and absf(meter.power(rules) - 1.0) < 0.001, "it stops at full")
	_check(meter.advance(0.1, false, rules) == -1.0 and meter.held == 0.0, "letting go resets it")
	rules["charge"] = false
	_check(meter.advance(0.5, true, rules) == -1.0, "with the charge off there is no meter")
	rules["charge"] = true
	rules["charge_sec"] = 2.0
	_check(absf(meter.advance(1.0, true, rules) - 0.5) < 0.001, "charge_sec 2 takes two seconds to fill")

	var followed := GSWeaponKnives.DEFAULT_RULES.duplicate()
	_check(FcKnifeFollow.apply(followed, "fc_knife_throw_charge", "1") and bool(followed["charge"]), "a replicated fc_knife_throw_charge lands in the rules")
	_check(FcKnifeFollow.apply(followed, "fc_knife_throw_charge_sec", "2.5") and is_equal_approx(float(followed["charge_sec"]), 2.5), "and a number")
	_check(not FcKnifeFollow.apply(followed, "mp_something", "1"), "another cvar is ignored")
	_check(not FcKnifeFollow.follow(followed, null), "no source, no follow")

	var bytes := FcKnifeEvents.write_knife(3, 1, GSWeaponKnives.Phase.FLY, 0, Vector3.ONE, Vector3(0.0, 0.0, -20.0), true, Vector3(0.0, -2.0, 0.0))
	var reader := GSNetReader.new(bytes)
	var _kind := FcKnifeEvents.read_more(reader)
	var back := FcKnifeEvents.read_knife(reader)
	_check(bool(back["glide"]) and (back["turn"] as Vector3).distance_to(Vector3(0.0, -2.0, 0.0)) < 0.1, "a gliding knife's turn round-trips over the wire", str(back["turn"]))
	var plain := FcKnifeEvents.write_knife(4, 1, GSWeaponKnives.Phase.FLY, 0, Vector3.ONE, Vector3(0.0, 0.0, -20.0))
	var reader2 := GSNetReader.new(plain)
	var _kind2 := FcKnifeEvents.read_more(reader2)
	_check(not bool(FcKnifeEvents.read_knife(reader2)["glide"]), "a plain knife does not glide")
	_finished += 1


func _test_wire() -> void:
	_entered += 1
	var bytes := FcKnifeEvents.write_knife(7, 12, GSWeaponKnives.Phase.STUCK, 13, Vector3(12.5, 1.25, -30.0), Vector3(0.0, -0.6, 0.8))
	var reader := GSNetReader.new(bytes)
	_check(FcKnifeEvents.read_more(reader) == FcKnifeEvents.More.KNIFE, "MORE leads with the KNIFE sub-kind")
	var back := FcKnifeEvents.read_knife(reader)
	_check(bool(back["ok"]) and int(back["id"]) == 7 and int(back["owner"]) == 12 and int(back["victim"]) == 13, "KNIFE round-trips its id, owner and victim")
	_check(int(back["phase"]) == GSWeaponKnives.Phase.STUCK and (back["at"] as Vector3).distance_to(Vector3(12.5, 1.25, -30.0)) < 0.05, "and its phase and position")
	_check((back["motion"] as Vector3).distance_to(Vector3(0.0, -0.6, 0.8)) < 0.05, "and its motion")
	_check(FcEvents.Kind.MORE == FcEvents.Kind.TEAM + 1 and FcEvent.fits(), "MORE is appended after TEAM and the kinds still fit")
	_finished += 1
