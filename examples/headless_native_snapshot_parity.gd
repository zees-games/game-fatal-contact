extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcNetBridge := preload("../game/fc_net_bridge.gd")
const FcNetNativeCore := preload("../game/fc_net_native_core.gd")
const FcNetPullBatch := preload("../game/fc_net_pull_batch.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcPlayerNet := preload("../game/fc_player_net.gd")

## gs-sim's snapshot core (`sv_native_snapshots`) and rest pull (GSSimNetRest) against gs-net's GDScript, two servers in
## lockstep: every payload each fake client is sent byte for byte, and every player's pulled fields, tick by tick.
## Scenarios and the owned-bot trick: docs/native-server-tick.md (Snapshot suites). Without gs-sim the suite says so.

const TICKS := 480
const FAKES_MAX := 12
const PEER_BASE := 5000
## Bots handed to a fake client (owner_peer_id), so their exact copy and carry mask are pulled.
const OWNED := 2

var _checks := 0
var _failed := 0
var _expected := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail := "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _run() -> void:
	print("FC — gs-sim's snapshot core sends the bytes gs-net's GDScript sends")
	var was := FcNetNativeCore.enabled
	var rest_was := FcNetPullBatch.rest_enabled
	FcNetPullBatch.rest_enabled = true
	if FcNetNativeCore.make_core() == null:
		print("gs-sim has no GSSimNetCore: nothing to compare")
		_check(true, "the GDScript path stands alone")
		_finish(1)
		return
	for players: int in [6, 31]:
		_round(players)
	FcNetNativeCore.enabled = was
	FcNetPullBatch.rest_enabled = rest_was
	_finish(18)


func _finish(expected: int) -> void:
	var ok := _failed == 0 and _checks == expected
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, expected])
	get_tree().quit(0 if ok else 1)


## One seeded round of [param players] bots on two lockstep servers, native and GDScript.
func _round(players: int) -> void:
	var lanes := [_lane(true, players), _lane(false, players)]
	_check(lanes[0].native_on and not lanes[1].native_on, "%d players: one server native (gs-sim), one GDScript" % players,
		"%s / %s" % [(lanes[0].net as GSNetManager).native_note(), (lanes[1].net as GSNetManager).native_note()])
	var compared := 0
	var bytes := 0
	var differ := 0
	var world_differ := 0
	var first := ""
	var changed_map := true
	var rest_differ := 0
	var rest_first := ""
	var rest_rows := 0
	var owned_exact := 0
	FcNetNativeCore.enabled = true
	_check(FcNetPullBatch.active() and FcNetPullBatch.rest_native() != null,
		"%d players: the native server pulls the rest in gs-sim (GSSimNetRest), the other in GDScript" % players)
	for t in range(1, TICKS + 1):
		if t == TICKS / 3:
			for lane: Dictionary in lanes:
				changed_map = changed_map and (lane.game as FcGame).change_map(FcMap.dm_box()).ok
		if t == TICKS / 2:
			for lane: Dictionary in lanes:
				_churn(lane, players)
		for lane: Dictionary in lanes:
			for peer: int in lane.sent:
				(lane.sent[peer] as Array).clear()
			_move_eyes(lane)
			# sv_native_snapshots is a static: each server ticks with its own.
			FcNetNativeCore.enabled = lane.native_on
			(lane.net as GSNetManager).server_tick(t)
		var rest_a := _rest(lanes[0])
		var rest_b := _rest(lanes[1])
		rest_rows += rest_a.size()
		for i in rest_a.size():
			if i < rest_b.size() and var_to_bytes(rest_a[i]) == var_to_bytes(rest_b[i]):
				continue
			rest_differ += 1
			if rest_first == "":
				rest_first = "tick %d row %d: %s vs %s" % [t, i, rest_a[i], rest_b[i] if i < rest_b.size() else "none"]
		if rest_b.size() != rest_a.size():
			rest_differ += 1
		for row: Array in rest_a:
			if row[1] and (row[2] as PackedFloat32Array).size() == FcPlayerNet.EXACT_FLOATS:
				owned_exact += 1
		if _world(lanes[0]) != _world(lanes[1]):
			world_differ += 1
			if first == "":
				first = "tick %d: the two worlds differ" % t
			continue
		var peers: Array = lanes[0].sent.keys()
		peers.sort()
		for peer: int in peers:
			var a: Array = lanes[0].sent.get(peer, [])
			var b: Array = lanes[1].sent.get(peer, [])
			if a.is_empty() and b.is_empty():
				continue
			compared += 1
			for p: PackedByteArray in a:
				bytes += p.size()
			if var_to_bytes(a) != var_to_bytes(b):
				differ += 1
				if first == "":
					first = "tick %d peer %d: %s vs %s" % [t, peer, _sizes(a), _sizes(b)]
	print("  %d players: %d payload sets compared, %d bytes" % [players, compared, bytes])
	_check(changed_map, "%d players: both servers changed map" % players)
	_check(world_differ == 0, "%d players: the two servers' worlds stayed in lockstep" % players, "%d ticks differ; %s" % [world_differ, first])
	_check(compared > TICKS, "%d players: every client was sent snapshots" % players, "%d" % compared)
	_check(differ == 0, "%d players: every client's bytes identical, native and GDScript" % players, "%d differ; %s" % [differ, first])
	_check((lanes[0].net as GSNetManager).native_core() != null and lanes[0].net.config.native,
		"%d players: the native core was never dropped" % players)
	_check(rest_differ == 0 and rest_rows > TICKS * players / 2,
		"%d players: every player's pulled rest identical, gs-sim and GDScript" % players,
		"%d rows, %d differ; %s" % [rest_rows, rest_differ, rest_first])
	_check(owned_exact >= TICKS * OWNED / 2, "%d players: owned bots' exact copies were pulled" % players, "%d" % owned_exact)
	for lane: Dictionary in lanes:
		(lane.root as Node).queue_free()


## A server: game, gs-net manager (gs-sim's core or GDScript), FC's bridge, [param players] bots and fake clients riding on them.
func _lane(native: bool, players: int) -> Dictionary:
	var root := Node3D.new()
	root.name = "Lane%s%d" % ["Native" if native else "Script", players]
	add_child(root)
	var game := FcGame.new()
	game.name = "G"
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = FcMode.team_deathmatch()
	root.add_child(game)
	var _set := game.setup(FcMap.dm_atrium())
	game.start(0)

	var net := GSNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.auto_tick = false
	net.config_file = ""
	var config := GSNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = FcGame.snapshot_rate_for(game.tick_rate)
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 0
	config.per_client_budget = 0
	config.per_client_packet_rate = 0
	config.world_extent = FcGame.NET_WORLD_EXTENT
	# Interest's cache and lingering expire on the tick, not the wall clock: the two servers tick at
	# different instants, and a wall-clock expiry gave one peer a full set a few ticks before the other.
	config.snapshot_clock_from_tick = true
	config.snapshot_workers = 4 if native else 0
	net.config = config
	root.add_child(net)
	var _started := net.setup()
	FcNetNativeCore.enabled = native
	var native_on := FcNetNativeCore.install(net)
	var interest := GSNetInterestDistance.new()
	interest.radius = 18.0
	interest.radius_by_tag["probe_eye"] = 0.0
	net.interest = interest

	var bridge := FcNetBridge.new()
	bridge.name = "Bridge"
	root.add_child(bridge)
	var _attached := bridge.attach(game, net)
	var lane := {"root": root, "game": game, "net": net, "bridge": bridge, "native_on": native_on,
		"sent": {}, "eyes": {}, "bots": [], "acks": []}
	for k in players:
		(lane.bots as Array).append(bridge.add_bot("B%d" % k))
	net.send_fn = func(peer_id: int, payload: PackedByteArray, _delivery: int) -> void:
		if lane.sent.has(peer_id):
			(lane.sent[peer_id] as Array).append(payload)
	net.snapshot_sent.connect(func(tick: int, _n: int) -> void:
		(lane.acks as Array).append(tick)
		if (lane.acks as Array).size() > 2:
			var acked: int = (lane.acks as Array).pop_front()
			for fid: int in lane.sent:
				var _a := net.receive_ack(fid, acked))
	for i in mini(players, FAKES_MAX):
		_add_fake(lane, PEER_BASE + i)
	for k in OWNED:
		(bridge.behaviour_for(int(lane.bots[k])).identity as GSNetIdentity).owner_peer_id = PEER_BASE + 1 + k
	return lane


## A fake client: a peer whose eye (an identity it owns, sent to nobody) rides on one bot.
func _add_fake(lane: Dictionary, fid: int) -> void:
	var net: GSNetManager = lane.net
	net.add_peer(fid)
	var _r := net.receive(net.messages.schema_payload(), fid)
	lane.sent[fid] = []
	var eye := Node3D.new()
	eye.name = "Eye%d" % fid
	var identity := GSNetIdentity.new()
	identity.owner_peer_id = fid
	identity.interest_tags = PackedStringArray(["probe_eye"])
	eye.add_child(identity)
	(lane.root as Node).add_child(eye)
	var _reg := net.registry.register(identity, 0, net.clock.tick, net.config)
	lane.eyes[fid] = eye


## Each eye onto its bot (by its place in the list, so both servers agree).
func _move_eyes(lane: Dictionary) -> void:
	var game: FcGame = lane.game
	var bots: Array = lane.bots
	var k := 0
	for fid: int in lane.eyes:
		var p: Variant = game.player_for(bots[k % bots.size()]) if not bots.is_empty() else null
		if p != null:
			(lane.eyes[fid] as Node3D).position = (p as FcPlayer).controller.state.position
		k += 1


## Joins and leaves: two bots and one client go, one bot and two clients come.
func _churn(lane: Dictionary, players: int) -> void:
	var bridge: FcNetBridge = lane.bridge
	var net: GSNetManager = lane.net
	var bots: Array = lane.bots
	for _i in 2:
		bridge.remove_bot(int(bots.pop_back()))
	bots.append(bridge.add_bot("Late"))
	var gone := PEER_BASE
	var eye: Node3D = lane.eyes[gone]
	var _left := net.remove_peer(gone)
	eye.queue_free()
	var _e: bool = (lane.eyes as Dictionary).erase(gone)
	var _s: bool = (lane.sent as Dictionary).erase(gone)
	for i in 2:
		_add_fake(lane, PEER_BASE + 100 + players + i)


## Every player's position and yaw, to tell a divergent world from a divergent encoder.
func _world(lane: Dictionary) -> PackedByteArray:
	var rows: Array = []
	for p: FcPlayer in (lane.game as FcGame).players():
		rows.append([p.player_id, p.controller.state.position, p.controller.state.velocity])
	return var_to_bytes(rows)


## Every player's fields FcPlayerNet._pull_rest writes, in session order: [session, owned, net_exact, then the rest].
func _rest(lane: Dictionary) -> Array:
	var bridge: FcNetBridge = lane.bridge
	var rows: Array = []
	for p: FcPlayer in (lane.game as FcGame).players():
		var b := bridge.behaviour_for(p.player_id)
		if b == null:
			continue
		var id: GSNetIdentity = b.identity
		rows.append([p.player_id, id != null and id.owner_peer_id != 0, b.net_exact, b.net_health, b.net_armour,
			b.net_alive, b.net_blind, b.net_challenge, b.net_challenge_value, b.net_app_points_on, b.net_app_points,
			b.net_beacon, b.net_flashlight, b.net_protected, b.net_carry,
			id.always_relevant if id != null else null, id.get(&"interest_aim") if id != null else null])
	return rows


func _sizes(payloads: Array) -> String:
	var out := PackedStringArray()
	for p: PackedByteArray in payloads:
		out.append(str(p.size()))
	return "[%s]" % ", ".join(out)
