extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcNetBridge := preload("../game/fc_net_bridge.gd")
const FcNetNativeCore := preload("../game/fc_net_native_core.gd")
const FcPlayer := preload("../game/fc_player.gd")

## gs-sim's snapshot core (GSSimNetCore, cvar `sv_native_snapshots`) against gs-net's GDScript snapshots: two servers in
## lockstep, the same seeded round of bots on each, one building its snapshots natively (on worker threads) and one in
## GDScript, and every payload each fake client is sent compared byte for byte, tick by tick. 6 and 31 players, a map
## change, bots and clients joining and leaving, acks two snapshots late, distance interest. Without gs-sim the suite says so.

const TICKS := 480
const FAKES_MAX := 12
const PEER_BASE := 5000

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
	if FcNetNativeCore.make_core() == null:
		print("gs-sim has no GSSimNetCore: nothing to compare")
		_check(true, "the GDScript path stands alone")
		_finish(1)
		return
	for players: int in [6, 31]:
		_round(players)
	FcNetNativeCore.enabled = was
	_finish(12)


func _finish(expected: int) -> void:
	var ok := _failed == 0 and _checks == expected
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, expected])
	get_tree().quit(0 if ok else 1)


## One seeded round of [param players] bots on two lockstep servers, native and GDScript.
func _round(players: int) -> void:
	var lanes := [_lane(true, players), _lane(false, players)]
	_check(lanes[0].native_on and not lanes[1].native_on, "%d players: one server native (gs-sim), one GDScript" % players,
		"%s / %s" % [lanes[0].net._native_note, lanes[1].net._native_note])
	var compared := 0
	var bytes := 0
	var differ := 0
	var world_differ := 0
	var first := ""
	var changed_map := true
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
			(lane.net as GSNetManager).server_tick(t)
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
	_check(lanes[0].net._native != null and lanes[0].net.config.native, "%d players: the native core was never dropped" % players)
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


func _sizes(payloads: Array) -> String:
	var out := PackedStringArray()
	for p: PackedByteArray in payloads:
		out.append(str(p.size()))
	return "[%s]" % ", ".join(out)
