extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPresentation := preload("../game/fc_presentation.gd")
const FcFrameProbe := preload("../game/fc_frame_probe.gd")

## Bytes per second, snapshot size, rtt and rate-limiter starvation for one real client
## against a dual-stack server with N hunting bots, over real loopback ENet (no relay, so
## nothing but the game's own limiter can queue a packet).
##
## [codeblock]
## godot --headless --path . res://tools/net_probe.tscn -- --bots 12 --seconds 20 [--budget 0] [--pps 0]
## [/codeblock]
##
## `--budget` and `--pps` override `per_client_budget` / `per_client_packet_rate` on the
## server's GSNetConfig after boot, so a before/after is one flag. Prints one line a second
## and a summary; it asserts nothing.

const PORT := 27196
const DATA := "user://fc_net_probe"

## --port N: the server port (the ENet one follows it), so probes can run side by side; its data folder is per port too.
var _port := PORT
var _data := DATA

var _bots := 8
## --sections: the server's FcFrameProbe sections per tick (fine level) and SERVER_TICK p50/p95 (sim + send, ms per tick),
## and the client's STAGES line (predict and each remote-draw stage, ms per client frame; FcFrameProbe.stages_line).
var _sections := false
var _seconds := 20.0
var _budget := -1
var _pps := -1
## --aoi players,radius,far_distance,far_every,far_tiers[,coherent[,aim_cone]]: the relevance rings (fc_net_aoi.gd); unset is the shipped defaults.
var _aoi: PackedStringArray = PackedStringArray()

## --fake N: N extra synthetic peers (unreliable sends dropped, acks 2 snapshots late) on the server, to measure per-peer snapshot cost without N full clients.
## Each sees from an "eye" riding on a player (see [method _install_fakes]), so relevance applies to it as to a player there.
var _fake := 0
## --map <id>: the map the server plays (FcMap.by_id: box, atrium, pit or an imported one). Relevance needs room to matter.
var _map_id := "box"
## The fake peers' eyes and the player each rides on.
var _eyes: Array[Node3D] = []
var _eye_on: Array[Node3D] = []
var _eye_laps := 1
## --workers N: GSNetConfig.snapshot_workers; unset keeps the server's own (sv_snapshot_workers' default).
var _workers := -2
var _native := 1
var _noshort := false
var _fake_sent := [0, 0]
## --control N: N more fake peers without an eye, sent everything: the same run's bytes with no relevance, so a before/after of the rings is one run, not two runs of different fights.
var _control := 0
var _control_sent := [0, 0]
## --fields: per snapshot, which observer-visible properties changed since the last snapshot (what an in-step watcher is
## owed, before interest), summed per property and per behaviour script with its declared size, printed as FIELDS lines.
var _fields := false
## --no-skip-hooks: the client calls every remote behaviour's _net_state_applied each snapshot (GSNetConfig.skip_unchanged_state_applied off), the before of that skip.
var _no_skip_hooks := false
var _field_last := {}
var _field_bits := {}
var _field_count := {}
var _field_entities := {}
var _wire_bits: Dictionary = {}
var _distance_bands: Dictionary = {}
var _field_snaps := 0
var _server: GSServer = null
var _game: FcGame = null
var _module = null
var _net: GSNetManager = null
var _client: Node = null
var _cnet: GSNetManager = null
var _link: GSClientLink = null
var _config: GSServerConfig = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		match args[i]:
			"--bots": _bots = int(args[i + 1])
			"--seconds": _seconds = float(args[i + 1])
			"--budget": _budget = int(args[i + 1])
			"--pps": _pps = int(args[i + 1])
			"--workers": _workers = int(args[i + 1])
			"--native": _native = int(args[i + 1])
			"--noshort": _noshort = true
			"--fake": _fake = int(args[i + 1])
			"--aoi": _aoi = String(args[i + 1]).split(",")
			"--map": _map_id = args[i + 1]
			"--port": _port = int(args[i + 1])
			"--control": _control = int(args[i + 1])
	if args.has("--no-snapshot-batch"):
		GSNetSnapshotBatch.enabled = false
	_fields = args.has("--fields")
	_sections = args.has("--sections")
	_no_skip_hooks = args.has("--no-skip-hooks")
	if _port != PORT:
		_data = "%s_%d" % [DATA, _port]
	GSLog.set_level(GSLog.Level.ERROR)
	var _scratch := FcPresentation.use_scratch_settings("net_probe")
	_run.call_deferred()


func _run() -> void:
	await _boot_server()
	_tune_server()
	await _connect_client()
	await _wait_alive()
	await _install_fakes()
	await _measure_and_report()
	_link.disconnect_from_server("done")
	await get_tree().create_timer(0.3).timeout
	GSPaths.remove_tree(_data)
	get_tree().quit()


func _boot_server() -> void:
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), server_side.get_path())

	_game = FcGame.new()
	_game.name = "Arena"
	_game.tick_rate = 64
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.warmup_sec = 0.0
	_game.headless = true
	_game.register_service = true
	server_side.add_child(_game)
	_setup_game()

	_config = GSServerConfig.new()
	_config.hostname = "net probe"
	_config.port = _port
	_config.max_players = 256
	_config.bind_address = "127.0.0.1"
	_config.transport_mode = "dual"
	_config.rcon_password = ""
	_config.admins_path = "%s/admins.json" % _data
	_config.bans_path = "%s/bans.json" % _data
	_config.audit_log_path = "%s/audit.jsonl" % _data
	_config.hibernate_when_empty = false
	_config.startup_config = ""
	_config.autoexec_config = ""
	_config.query_enabled = false
	_config.enet_share_udp_port = false
	_config.stdin_console_enabled = false
	_config.log_level = "error"
	_server = GSServer.new()
	_server.name = "Server"
	_server.config = _config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)
	await _server.boot()
	await _server.modules.load_module("res://game/fc_module.gd")


## The map (and mode) the server plays; a probe built on this one overrides it.
func _setup_game() -> void:
	var m: FcMap = FcMap.by_id(StringName(_map_id))
	if m == null:
		push_error("net_probe: no map '%s'" % _map_id)
		get_tree().quit(2)
		return
	_game.setup(m)


func _tune_server() -> void:
	_module = _server.modules.get_module("arena")
	var quota: GSBotQuota = _module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		# "off" is wanted = 0: the quota removes every bot a second later (arena-128-scale-1).
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(_bots))
		quota.empty_cvar.force_set("1")
	_net = _module.net
	if _game.match_node.state == GSMatch.State.IDLE:
		_game.start(0)
	GSNetBehaviour.native_encode_shortcuts = not _noshort
	if _workers >= -1:
		_net.config.snapshot_workers = _workers
	_net.config.native = _native != 0
	if _budget >= 0:
		_net.config.per_client_budget = _budget
	if _pps >= 0:
		_net.config.per_client_packet_rate = _pps
	if _aoi.size() >= 5 and _module.get("net_aoi") != null:
		var cv: Dictionary = _module.net_aoi._cvars
		var keys := ["min_players", "radius", "far_distance", "far_every", "far_tiers", "far_coherent", "aim_cone_deg"]
		if _aoi.size() > keys.size():
			push_error("net_probe: --aoi wants 5 to 7 fields, got %d" % _aoi.size())
			get_tree().quit(2)
			return
		for k in _aoi.size():
			(cv[keys[k]] as GSConVar).force_set(_aoi[k])
	elif not _aoi.is_empty():
		push_error("net_probe: --aoi wants 5 to 7 fields, got %d" % _aoi.size())
		get_tree().quit(2)
		return
	for i in range(_bots):
		_module.bridge.add_bot("Probe%d" % i)


func _connect_client() -> void:
	var client_side := Node.new()
	client_side.name = "ClientSide"
	add_child(client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), client_side.get_path())
	_link = GSClientLink.new()
	_link.name = "Server"
	_link.player_name = "Probe"
	_link.transport_preference = "udp"
	_link.udp_address = "127.0.0.1:%d" % _config.effective_enet_port()
	client_side.add_child(_link)
	_link.connect_to_server("127.0.0.1:%d" % _port)
	var spawned := [false]
	_link.spawned.connect(func() -> void: spawned[0] = true)
	var joined := 0.0
	while not (spawned[0] or _link.is_playing()) and joined < 30.0:
		await get_tree().create_timer(0.1).timeout
		joined += 0.1
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	client_side.add_child(_client)

	var waited := 0.0
	while waited < 40.0:
		var cnet: GSNetManager = _client.get("net")
		if cnet != null and cnet.clock.is_synced() and _client.get("player") != null:
			break
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	_cnet = _client.get("net")
	if _no_skip_hooks and "skip_unchanged_state_applied" in _cnet.config:
		_cnet.config.skip_unchanged_state_applied = false
	print("connected after %.1fs, %d players, budget=%d pps=%d" % [
		waited, -1,
		_net.config.per_client_budget, _net.config.per_client_packet_rate])


## Let the match come alive, then reset the windows so warm-up is not averaged in.
func _wait_alive() -> void:
	var alive := 0
	var spin := 0.0
	while spin < 20.0:
		alive = 0
		for other in _game.players():
			if other.is_alive():
				alive += 1
		if alive >= _bots + 1:
			break
		await get_tree().create_timer(0.25).timeout
		spin += 0.25
	print("alive on the server: %d of %d after %.1fs" % [alive, _bots + 1, spin])
	var cg = _client.get("game")
	var seen := 0
	var live_state := -1
	if cg != null:
		seen = cg.players().size()
		live_state = int(cg.match_node.state) if cg.match_node != null else -2
	print("client sees %d players, match state %d; server match state %d" % [seen, live_state, int(_game.match_node.state)])
	_net.stats.roll()
	_cnet.stats.roll()
	_module.call("_refresh_aoi")


func _install_fakes() -> void:
	if _fake <= 0:
		return
	var net := _net
	var schema := net.messages.schema_payload()
	var orig_send: Callable = net.send_fn
	var fakes := {}
	var riders: Array = _game.players()
	_eye_laps = maxi(1, riders.size())
	# An eye per fake peer: an identity the fake owns, with no state and a tag no peer is
	# sent (radius 0), so the fake has an observer where its player stands and nothing else changes.
	if net.interest is GSNetInterestDistance:
		(net.interest as GSNetInterestDistance).radius_by_tag["probe_eye"] = 0.0
	else:
		GSLog.warn("net_probe", "the interest is not a distance interest; fakes see everything")
	for i in _fake:
		var fid := 5000 + i
		net.add_peer(fid)
		var _r := net.receive(schema, fid)
		fakes[fid] = true
		var eye := Node3D.new()
		eye.name = "ProbeEye%d" % i
		var identity := GSNetIdentity.new()
		identity.owner_peer_id = fid
		identity.interest_tags = PackedStringArray(["probe_eye"])
		eye.add_child(identity)
		get_node("ServerSide").add_child(eye)
		var reg := net.registry.register(identity, 0, 0, net.config)
		if not reg.ok:
			push_error("net_probe: eye %d not registered: %s" % [i, str(reg.error)])
		_eyes.append(eye)
		_eye_on.append(riders[i % riders.size()] if not riders.is_empty() else null)
	var controls := {}
	for i in _control:
		var cid := 6000 + i
		net.add_peer(cid)
		var _c := net.receive(schema, cid)
		controls[cid] = true
	_move_eyes()
	get_tree().physics_frame.connect(_move_eyes)
	net.send_fn = func(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
		if fakes.has(peer_id):
			_fake_sent[0] += 1
			_fake_sent[1] += payload.size()
			return
		if controls.has(peer_id):
			_control_sent[0] += 1
			_control_sent[1] += payload.size()
			return
		orig_send.call(peer_id, payload, delivery)
	var acks: Array = []
	net.snapshot_sent.connect(func(tick: int, _n: int) -> void:
		acks.append(tick)
		if acks.size() > 2:
			var acked: int = acks.pop_front()
			for fid: int in fakes:
				var _a := net.receive_ack(fid, acked)
			for cid: int in controls:
				var _b := net.receive_ack(cid, acked))
	await get_tree().create_timer(2.0).timeout


## Counts the observer-visible properties that changed since the previous snapshot (--fields), with gs-net's own
## [method GSNetVar.differs] and [method GSNetVar.estimated_bits] plus the 6-bit property index; an entity with any
## change adds its 36-bit header (id, behaviour count, property count) under "<script>.header".
func _count_fields(_tick: int, _peers: int) -> void:
	_field_snaps += 1
	if _field_snaps % 8 == 0:
		var spots: Array[Vector3] = []
		for identity in _net.registry.all():
			for b in identity.behaviours:
				if &"net_position" in b:
					spots.append(b.get(&"net_position"))
		for i in spots.size():
			for j in spots.size():
				if i != j:
					var band := mini(int(spots[i].distance_to(spots[j]) / 10.0), 15)
					_distance_bands[band] = int(_distance_bands.get(band, 0)) + 1
	for identity in _net.registry.all():
		for b in identity.behaviours:
			var script_name: String = b.get_script().resource_path.get_file().get_basename() if b.get_script() != null else "?"
			var key := b.get_instance_id()
			var last: Dictionary = _field_last.get(key, {})
			var changed := false
			var wire_changed := false
			for v: GSNetVar in b.net_vars:
				if v.audience == GSNetVar.Audience.OWNER:
					continue
				var value: Variant = b.get(v.property)
				if not last.has(v.property) or v.differs(last[v.property], value):
					changed = true
					var field := "%s.%s" % [script_name, v.property]
					_field_bits[field] = int(_field_bits.get(field, 0)) + 6 + v.estimated_bits()
					_field_count[field] = int(_field_count.get(field, 0)) + 1
				if not last.has(v.property) or v.wire_value(last[v.property]) != v.wire_value(value):
					wire_changed = true
					var wfield := "%s.%s" % [script_name, v.property]
					_wire_bits[wfield] = int(_wire_bits.get(wfield, 0)) + 6 + v.estimated_bits()
				last[v.property] = value
			_field_last[key] = last
			if wire_changed:
				var wh := "%s.header" % script_name
				_wire_bits[wh] = int(_wire_bits.get(wh, 0)) + 36
			_field_entities[script_name] = int(_field_entities.get(script_name, 0)) + 1
			if changed:
				var h := "%s.header" % script_name
				_field_bits[h] = int(_field_bits.get(h, 0)) + 36
				_field_count[h] = int(_field_count.get(h, 0)) + 1


func _report_fields() -> void:
	var snaps := maxf(float(_field_snaps), 1.0)
	var fields: Array = _field_bits.keys()
	fields.sort_custom(func(a, b) -> bool: return int(_field_bits[a]) > int(_field_bits[b]))
	var total := 0
	for f in fields:
		total += int(_field_bits[f])
	print("FIELDS snapshots=%d changed_bytes_per_snapshot=%.0f (no interest, all entities)" % [_field_snaps, total / 8.0 / snaps])
	for s in _field_entities:
		print("FIELDS entities %s=%.1f" % [s, _field_entities[s] / snaps])
	for f in fields:
		print("FIELDS %-40s bytes=%6.1f changes=%5.1f" % [f, int(_field_bits[f]) / 8.0 / snaps, int(_field_count[f]) / snaps])
	var pairs := 0
	for k in _distance_bands:
		pairs += int(_distance_bands[k])
	var line := "FIELDS pair distances (10 m bands, share):"
	for k in 16:
		line += " %d=%.2f" % [k * 10, int(_distance_bands.get(k, 0)) / maxf(float(pairs), 1.0)]
	print(line)
	var wire_total := 0
	for f in _wire_bits:
		wire_total += int(_wire_bits[f])
	print("FIELDS wire_changed_bytes_per_snapshot=%.0f (only changes that survive quantisation)" % (wire_total / 8.0 / snaps))
	for f in fields:
		print("FIELDS wire %-40s bytes=%6.1f" % [f, int(_wire_bits.get(f, 0)) / 8.0 / snaps])


## Each eye onto its player, a centimetre up per lap so two eyes on one player are never at zero distance,
## aimed where the player aims.
func _move_eyes() -> void:
	for i in _eyes.size():
		var on := _eye_on[i]
		if on != null and is_instance_valid(on):
			_eyes[i].global_position = on.global_position + Vector3.UP * 0.01 * (floorf(float(i) / _eye_laps) + 1.0)
			# And looks where its player looks, for gs-net's aim cone (FcNetAoi.aim_cone_deg).
			var identity := _eyes[i].get_child(0)
			if &"interest_aim" in identity and on.has_method(&"aim_direction"):
				identity.set(&"interest_aim", on.call(&"aim_direction"))


func _measure_and_report() -> void:
	var net := _net
	var cnet := _cnet
	var perf0: Dictionary = net.perf_counters()
	if _fields:
		net.snapshot_sent.connect(_count_fields)
	# The client's own sections (arena.net_snapshot is its whole snapshot apply), with a report interval no run reaches.
	FcFrameProbe.set_interval(1.0e9)
	FcFrameProbe.fine = _sections
	if _sections:
		AwWeaponRig.phase_timers = true
		GSWeaponArsenal.phase_timers = true
	var tick_ms := PackedFloat64Array()
	var tick_last := PackedInt64Array([int(perf0[&"server_sim_usec"]) + int(perf0[&"server_send_usec"]), int(perf0[&"server_ticks"])])
	var sum_down := 0.0
	var n_down := 0
	var t := 0.0
	var peak_rtt := 0.0
	var peak_down := 0.0
	var worst_frame := 0.0
	var frames := 0
	var last := Time.get_ticks_usec()
	var next_print := 1.0
	while t < _seconds:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst_frame = maxf(worst_frame, (now - last) / 1000.0)
		last = now
		frames += 1
		if _sections:
			tick_last = _sample_tick(tick_ms, t, tick_last)
		t += get_process_delta_time()
		if t >= next_print:
			next_print += 1.0
			var peers := net.budget.peer_ids()
			var d: Dictionary = net.budget.describe_peer(peers[0]) if peers.size() > 0 else {}
			var rtt := cnet.stats.rtt_percentile(0.95)
			peak_rtt = maxf(peak_rtt, rtt)
			peak_down = maxf(peak_down, float(d.get("bytes_per_sec", 0)))
			sum_down += float(d.get("bytes_per_sec", 0))
			n_down += 1
			print("t=%2d down=%6d B/s %3d pkt/s use=%s starved=%d | client rtt p50=%d p95=%d recv=%d B/s avg_pkt=%d" % [
				int(t), int(d.get("bytes_per_sec", 0)), int(d.get("packets_per_sec", 0)),
				str(d.get("utilisation", "?")), int(d.get("starved", 0)),
				int(cnet.stats.rtt_percentile(0.5)), int(rtt),
				int(cnet.stats.bytes_received_per_sec), int(cnet.stats.average_packet_bytes())])
	print("SUMMARY bots=%d peak_down=%d B/s peak_rtt_p95=%d ms starved=%d fps=%.0f worst_frame=%.1f ms lost=%d" % [
		_bots, int(peak_down), int(peak_rtt), int(net.budget.describe_peer(net.budget.peer_ids()[0]).get("starved", 0)),
		frames / maxf(t, 0.001), worst_frame, cnet.stats.snapshots_lost])
	var perf1: Dictionary = net.perf_counters()
	var nticks := maxi(1, int(perf1[&"server_ticks"]) - int(perf0[&"server_ticks"]))
	print("AOI active=%s players=%d mean_down=%d B/s send_ms_per_tick=%.3f sim_ms_per_tick=%.3f ticks=%d entities=%d" % [
		str(_module.net_aoi.active), _game.players().size(), int(sum_down / maxf(n_down, 1)),
		(int(perf1[&"server_send_usec"]) - int(perf0[&"server_send_usec"])) / 1000.0 / nticks,
		(int(perf1[&"server_sim_usec"]) - int(perf0[&"server_sim_usec"])) / 1000.0 / nticks,
		nticks, net.registry.all().size()])
	var applied: PackedInt64Array = FcFrameProbe._sections.get(&"net_snapshot", PackedInt64Array([0, 0, 0]))
	# tracks_only: remote samples live only in gs-sim's interpolator (GSNetConfig.sim_interp_tracks_only took effect).
	var tracks_only: bool = cnet.interpolator != null and bool(cnet.interpolator.get(&"_native_only"))
	print("CLIENT net_snapshot_ms=%.3f max=%.3f snapshots=%d tracks_only=%s skip_hooks=%s" % [
		applied[0] / 1000.0 / maxf(applied[1], 1), applied[2] / 1000.0, applied[1], "on" if tracks_only else "off",
		cnet.config.get("skip_unchanged_state_applied")])
	if _sections:
		print(FcFrameProbe.stages_line(frames, cnet.interpolator))
		_print_sections(tick_ms)
		_print_engine()
	FcFrameProbe.set_interval(0.0)
	var snaps := maxi(1, int(perf1[&"snap_snapshots"]) - int(perf0[&"snap_snapshots"]))
	var ph := ""
	for k in ["prepare", "reads", "interest", "build", "thaw", "begin", "nint", "submit", "join", "apply"]:
		ph += " %s=%.3f" % [k, (int(perf1[StringName("snap_%s_usec" % k)]) - int(perf0[StringName("snap_%s_usec" % k)])) / 1000.0 / snaps]
	if _control > 0:
		print("CONTROL eyed_bytes_per_snapshot=%d control_bytes_per_snapshot=%d" % [
			int(_fake_sent[1] / maxf(float(_fake_sent[0]), 1.0)), int(_control_sent[1] / maxf(float(_control_sent[0]), 1.0))])
	if _fields:
		_report_fields()
	print("PHASES clients=%d native=%s workers=%d ms/snapshot:%s fake_bytes_per_snapshot=%d" % [
		1 + _fake, net._native_note, net.config.snapshot_workers, ph,
		int(_fake_sent[1] / maxf(float(snaps) * maxf(_fake, 1), 1.0))])


## One process hosts the server and the probe's one real client, so the sections hold both. These are only the client's
## (the dedicated server never runs them): chasing "physics" or "predict" here cuts nothing from a server's tick.
const CLIENT_SECTIONS := ["physics", "predict", "present", "bodies", "interpolate", "net_snapshot", "net_event", "w_spectate", "draw", "audio"]


func _is_client_section(name: String) -> bool:
	return name in CLIENT_SECTIONS or name.begins_with("c_") or name.begins_with("r_")


## SERVER_TICK percentiles over the per-frame mean tick cost, and every probe section as ms per tick (sum over calls / ticks).
func _print_sections(tick_ms: PackedFloat64Array) -> void:
	tick_ms.sort()
	var n := tick_ms.size()
	if n > 0:
		print("SERVER_TICK bots=%d p50=%.2f p95=%.2f max=%.2f samples=%d" % [
			_bots, tick_ms[n / 2], tick_ms[mini(n - 1, int(n * 0.95))], tick_ms[n - 1], n])
	var perf: Dictionary = _net.perf_counters()
	var ticks := maxi(1, int(perf[&"server_ticks"]))
	var rows: Array = []
	for k in FcFrameProbe._sections:
		var row: PackedInt64Array = FcFrameProbe._sections[k]
		rows.append([String(k), row[0] / 1000.0 / ticks, row[1] / float(ticks)])
	rows.sort_custom(func(a, b): return a[1] > b[1])
	for r in rows:
		print("SECTION %-22s %7.3f ms/tick %6.2f calls/tick%s" % [r[0], r[1], r[2], "  [probe's client]" if _is_client_section(r[0]) else ""])
	for w in [["pw_", AwWeaponRig], ["pa_", GSWeaponArsenal]]:
		var names: Array = (w[1] as GDScript).get(&"PHASES")
		var us: PackedInt64Array = (w[1] as GDScript).get(&"phase_us")
		for i in names.size():
			print("PHASE %s%-20s %7.3f ms/tick" % [w[0], names[i], us[i] / 1000.0 / ticks])
	print("PHASE_CALLS idle=%d full=%d" % [AwWeaponRig.phase_calls[0], AwWeaponRig.phase_calls[1]])

## Godot's own physics step and tree, which no FcFrameProbe section sees (last frame's values; the client's bodies included).
func _print_engine() -> void:
	print("ENGINE physics_process_ms=%.3f process_ms=%.3f active3d=%d pairs3d=%d islands3d=%d nodes=%d" % [
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)), int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)), int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])


## One frame's mean server tick cost (sim + send) into [param tick_ms], after 2 s of warm-up; returns [cost usec, ticks] to pass next frame.
func _sample_tick(tick_ms: PackedFloat64Array, t: float, last: PackedInt64Array) -> PackedInt64Array:
	var pc: Dictionary = _net.perf_counters()
	var cost := int(pc[&"server_sim_usec"]) + int(pc[&"server_send_usec"])
	var ticks := int(pc[&"server_ticks"])
	if ticks > last[1] and t > 2.0:
		tick_ms.append((cost - last[0]) / 1000.0 / (ticks - last[1]))
	return PackedInt64Array([cost, ticks])
