extends "lossy_base.gd"

const FcAttach := preload("res://game/fc_attach.gd")
const FcPlayerNet := preload("res://game/fc_player_net.gd")
const EXPECTED_CHECKS := 26

## A knife thrown is out of the arsenal until picked up or caught; a death and respawn hands slot 1 back, on the SERVER and on the CLIENT's own predicted arsenal, over a real ENet link (as headless_net_attach).
## Three throw-and-respawn rounds, so a one-off cannot pass: the client must regain the knife, and its drawn weapon must be one its arsenal carries.


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL: watchdog, the suite took over 300 s")
		get_tree().quit(1))


func _run() -> void:
	print("game-fatal-contact: a thrown knife comes back with the respawn, on the client too")
	GSPaths.remove_tree(DATA)
	Engine.physics_ticks_per_second = TICK_RATE
	var ok := await _boot()
	var a: Dictionary = {}
	if ok:
		a = await _connect_client("A", _server.config.effective_enet_port())
		ok = _check(a.get("bridge") != null and int(a["session"]) != 0, "a client connects over ENet", str(a.get("error", "")))
	if ok:
		_clients["A"] = a
		ok = await _body(a)
	await _teardown()
	GSPaths.remove_tree(DATA)
	_report_sections(_entered, _completed, 8, EXPECTED_CHECKS)


func _teardown() -> void:
	for label in _clients:
		var link: GSClientLink = _clients[label]["link"]
		if link != null and is_instance_valid(link):
			link.disconnect_from_server("test over")
	await get_tree().process_frame
	for label in _clients:
		var side: Node = _clients[label]["side"]
		if side != null and is_instance_valid(side):
			remove_child(side)
			side.queue_free()
	_clients.clear()
	if _relay != null:
		_relay.stop()
	await get_tree().process_frame
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
	if _server_side != null and is_instance_valid(_server_side):
		remove_child(_server_side)
		_server_side.queue_free()
	await get_tree().process_frame


func _body(a: Dictionary) -> bool:
	var session := int(a["session"])
	var bridge: FcNetBridge = a["bridge"]
	var served := _game.player_for(session)
	var own: FcPlayerNet = bridge.behaviour_for(session)
	var knife := FcContent.melee_id()
	_section("the client carries the knife in the first place")
	var _first := _game.respawn_player(session)
	var start := await _until(func() -> bool: return own != null and own.player != null and own.player.arsenal.carries(knife), RELIABLE_SECONDS)
	if not _check(start and served != null and served.arsenal.carries(knife), "server and client both carry the knife at spawn", "own=%s player=%s server_has=%s client_slots=%s" % [own != null, own.player != null if own != null else false, served.arsenal.carries(knife) if served != null else "no served", own.player.arsenal.slot_at(AwWeaponIds.SLOT_MELEE) if own != null and own.player != null else "-"]):
		_done()
		return false
	_done()

	for round_number in range(1, 4):
		_section("round %d: throw, respawn" % round_number)
		var _state := served.arsenal.drop_from_slot(AwWeaponIds.SLOT_MELEE)
		var gone := await _until(func() -> bool: return not own.player.arsenal.carries(knife), RELIABLE_SECONDS)
		_check(not served.arsenal.carries(knife) and gone, "a thrown knife is out of both arsenals")
		var _r := _game.respawn_player(session)
		var back_server := await _until(func() -> bool: return served.arsenal.carries(knife), RELIABLE_SECONDS)
		_check(back_server, "the respawn hands the server's arsenal the knife back")
		var back_client := await _until(func() -> bool: return own.player.arsenal.carries(knife), RELIABLE_SECONDS)
		_check(back_client, "and the client's own arsenal carries it again", "client slot 1: %s" % [own.player.arsenal.slot_at(AwWeaponIds.SLOT_MELEE)])
		var def: GSWeaponDef = own.player.arsenal.current_def()
		_check(def != null and own.player.arsenal.carries(def.id), "the weapon the client holds is one it carries", str(def.id if def != null else &""))
		_done()

	await _drawn_follows_throw(served, own, knife)

	_section("a real throw, then a respawn while the knife is in the air")
	var aim := Vector3(0.0, 0.0, -1.0)
	var state := served.arsenal.drop_from_slot(AwWeaponIds.SLOT_MELEE)
	var flying := _game.knives.throw(session, served.muzzle_position(), aim, Vector3.ZERO, 1.0, false, state)
	_check(flying > 0 and not served.arsenal.carries(knife), "the throw takes the knife out of the hand")
	var _again := _game.respawn_player(session)
	var kept_server := served.arsenal.carries(knife)
	var kept_client := await _until(func() -> bool: return own.player.arsenal.carries(knife), RELIABLE_SECONDS)
	_check(kept_server and kept_client, "the respawn gives slot 1 a knife on the server and the client with another still flying", "server %s client %s" % [kept_server, kept_client])
	_done()

	_section("a boomerang flies out and is caught")
	var fitted := FcAttach.serve(served.arsenal, GSNetReader.new(FcAttach.write_request(AwWeaponIds.SLOT_MELEE, FcContent.KNIFE_MOUNT, FcAttach.BOOMERANG)))
	_check(fitted.ok, "the boomerang fits the knife")
	# A short loop that fits any spawn room; the respawn point is random, so four directions are tried and one must come home.
	_game.knives.rules["boomerang_distance"] = 4.0
	_game.knives.rules["boomerang_radius"] = 1.5
	var caught := false
	var left_hand := false
	for heading in [Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(-1, 0, 0)]:
		if served.arsenal.carries(knife):
			_game.knives.clear()
			var boomerang_state := served.arsenal.drop_from_slot(AwWeaponIds.SLOT_MELEE)
			var out := _game.knives.throw(session, served.muzzle_position(), heading, Vector3.ZERO, 1.0, true, boomerang_state)
			left_hand = left_hand or (out > 0 and not served.arsenal.carries(knife))
			caught = await _until(func() -> bool: return served.arsenal.carries(knife) and own.player.arsenal.carries(knife), 12.0)
		if caught:
			break
		var _reset := _game.respawn_player(session)
		await _until(func() -> bool: return served.arsenal.carries(knife) and own.player.arsenal.carries(knife), RELIABLE_SECONDS)
	_check(left_hand, "the boomerang leaves the hand")
	_check(caught, "it curves back and both arsenals carry the knife again", "server %s client %s knives %d" % [served.arsenal.carries(knife), own.player.arsenal.carries(knife), _game.knives.count()])
	_done()
	return true


## The armed client's drawn weapon after its knife leaves the hand: it must not stay the knife while the HUD reads PISTOL.
func _drawn_follows_throw(served: FcPlayer, own: FcPlayerNet, knife: StringName) -> void:
	_section("the client's drawn weapon follows a throw out of the hand")
	# This bare client draws nothing; arm it as the game's client does on adoption, so its rig is the LOCAL one that equips.
	var hands := AwViewModel.new()
	hands.name = "Hands"
	(own.player.camera if own.player.camera != null else own.player).add_child(hands)
	own.player.arm_first_person(hands, false)
	served.arsenal.bring_to_hand(AwWeaponIds.SLOT_MELEE)
	own.player.arsenal.bring_to_hand(AwWeaponIds.SLOT_MELEE)
	# This bare client sends no input, so nothing predicts: tick its player by hand as the predictor does, a fresh tick a frame.
	var ticking := [true, 100000]
	var drive := func() -> void:
		while ticking[0]:
			ticking[1] += 1
			var _o: Variant = own.player.simulate_tick(int(ticking[1]), 1.0 / float(TICK_RATE), GSFpsCommand.new(), GSWeaponCommand.new())
			await get_tree().physics_frame
	drive.call()
	var drawn_knife := await _until(func() -> bool: return StringName(own.player.weapons.get(&"_shown")) == knife, RELIABLE_SECONDS)
	_check(drawn_knife, "the client draws the knife in hand", "shown %s role %s replaying %s last tick %s" % [own.player.weapons.get(&"_shown"), own.player.weapons.describe().get("role"), own.player.weapons.get(&"_replaying"), own.player.weapons.get(&"_last_tick")])
	var _thrown := served.arsenal.drop_from_slot(AwWeaponIds.SLOT_MELEE)
	var out_of_hand := await _until(func() -> bool: return not own.player.arsenal.carries(knife), RELIABLE_SECONDS)
	for _i in range(20):
		await get_tree().physics_frame
	var held: GSWeaponDef = own.player.arsenal.current_def()
	var held_id: StringName = held.id if held != null else &""
	_check(out_of_hand and held_id != knife, "the client's arsenal holds the next weapon", str(held_id))
	_check(StringName(own.player.weapons.get(&"_shown")) == held_id, "and its view model draws that weapon, not the thrown knife",
		"shown %s held %s" % [own.player.weapons.get(&"_shown"), held_id])
	ticking[0] = false
	await get_tree().physics_frame
	_done()
