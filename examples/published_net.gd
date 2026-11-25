extends GSGameCheckSuite

const FcClientExtras := preload("../game/fc_client_extras.gd")
const FcEvents := preload("../game/fc_events.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcNetBridge := preload("../game/fc_net_bridge.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcTestPorts := preload("test_ports.gd")

## A real FC server on a published combat surf map, and a real client that joins it over ENet and builds that map from the pack it fetched itself. [codeblock] godot --headless --path . res://examples/published_net.tscn [/codeblock]
## Two processes, because gs-cloud's registry entry and its `res://gs_cloud/` mount are process-wide. This one starts `published_net_host.tscn` (a dedicated server whose game names `gamemann/fc-surf-dm-maps-surf_10x_reloaded_fixed@1.2.3`, as cfg/content.yml's `maps:` does, and which changes to that map before anybody joins), then joins it as `FcClient` does: a `GSClientLink` on ENet and `FcClientExtras`' map sync. The server's READY admit announces its map; the client fetches the pack from the CDN a standalone client uses, checks it against the shipped trust list, mounts it in its own cache and builds the level, with no `maps/imported` link.
## Not in `game.sh test`: it needs the network and the published packs. Skips (exit 0), saying so, when the CDN is unreachable.

const MAP := &"surf_10x_reloaded_fixed"
const OWNER := "gamemann"
const PACK := "fc-surf-dm-maps-surf_10x_reloaded_fixed"
const VERSION := "1.2.3"
const SECTIONS := 2
const CHECKS := 12

## How long the host may take to fetch, mount and change to the map; and the client after joining.
const HOST_SECONDS := 180.0
const CLIENT_SECONDS := 180.0

var ROOT := "user://fc_published_net_%d" % OS.get_process_id()
var _host_pid := -1
var _status := ""
var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _build_client_net(side: Node, link: GSClientLink) -> Array:
	# What `FcClient._build_netcode` builds, minus everything that draws (as lossy_base does).
	var game := FcGame.new()
	game.name = "Game"
	game.is_authority = false
	game.headless = true
	game.register_service = false
	side.add_child(game)
	game.setup(FcMap.dm_box())
	var _following := game.follow_server_cvars(link)
	var net := GSNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.service_scope = &"published_net"
	net.local_peer_id = side.multiplayer.get_unique_id()
	net.auto_tick = false
	net.config_file = ""
	var cfg := GSNetConfig.new()
	cfg.tick_rate = game.tick_rate
	cfg.snapshot_rate = FcGame.NET_SNAPSHOT_RATE
	cfg.enable_prediction = true
	cfg.enable_lag_compensation = false
	cfg.max_entities_per_snapshot = 64
	cfg.world_extent = FcGame.NET_WORLD_EXTENT
	net.config = cfg
	side.add_child(net)
	net.setup()
	var bridge := FcNetBridge.new()
	bridge.name = "Bridge"
	side.add_child(bridge)
	bridge.attach(game, net)
	bridge.open_link(link)
	net.messages.seal()
	bridge.rtt_source = func() -> float: return FcNetBridge.link_rtt_ms(link)
	return [game, net, bridge]


func _client_cloud(settings: Dictionary, shipped: Variant) -> GSCloudClient:
	var config := GSCloudConfig.new()
	config.side = "client"
	config.cache_dir = ROOT.path_join("client_cache")
	config.require_signed_manifests = true
	config.trusted_keys = (shipped as Dictionary)["trusted_keys"] if shipped is Dictionary else []
	# What GSGameStandaloneContent.install builds, with a cache of its own.
	var cloud := GSCloudClient.new()
	cloud.name = "Cloud"
	cloud.host_role = "client"
	cloud.config = config
	cloud.config_file = ""
	cloud.register_service = false
	cloud.http_base_urls = settings["urls"]
	cloud.manifest_url_template = "{base}/{id}/{version}/manifest.json"
	cloud.manifest_url_fallbacks = PackedStringArray(["{base}/{id}/manifest.json"])
	add_child(cloud)
	GSRegistry.register(&"gs_cloud_client", cloud)
	await get_tree().process_frame
	return cloud


func _check_client_map(game: FcGame, bridge: FcNetBridge, cloud: GSCloudClient, mounted_before: bool, session: Array, gone: Array) -> void:
	var map := game.map
	_check(map != null and map.id == MAP and map.is_imported(), "the server's announce puts the client on %s" % MAP,
		"on %s%s" % [String(map.id) if map != null else "nothing", (", link ended: " + gone[0]) if gone[0] != "" else ""])
	_check(not mounted_before and cloud.is_mounted(StringName("%s/%s" % [OWNER, PACK]), VERSION),
		"the client's own gs-cloud fetched and mounted the signed pack")
	var cached := DirAccess.get_files_at(cloud.config.cache_dir).size() + DirAccess.get_directories_at(cloud.config.cache_dir).size()
	_check(cached > 0, "into the client's own cache (%d entries)" % cached)
	_check(map != null and map.manifest_path.begins_with("res://gs_cloud/") and map.manifest_path.find("maps/imported") < 0,
		"built from the mount, nothing from the maps/imported link (%s)" % (map.manifest_path if map != null else "none"))
	var solid := map.collision_root if map != null else null
	_check(solid != null and solid.is_inside_tree() and solid.get_child_count() > 100,
		"with its brushes in the client's tree (%d)" % (solid.get_child_count() if solid != null else -1))
	_check(map != null and map.movement_profile == &"surf" and map.spawns.size() > 0, "on the surf profile, with spawns")
	var surf_gravity := float(FcPlayer.SURF_TUNABLES["gravity"])
	var on_surf := func() -> bool:
		var b: Variant = bridge.behaviour_for(int(session[0])) if int(session[0]) != 0 else null
		return b != null and b.player != null and is_equal_approx(b.player.controller.tunables.gravity, surf_gravity)
	await _until(on_surf, 10.0)
	_check(on_surf.call(), "and the client's own player moves on surf air control there", "session %d" % int(session[0]))


func _cdn_up(origin: String) -> bool:
	var probe := HTTPRequest.new()
	add_child(probe)
	probe.request("%s/%s/%s/%s/manifest.json" % [origin, OWNER, PACK, VERSION])
	var answer: Array = await probe.request_completed
	probe.queue_free()
	if int(answer[0]) != HTTPRequest.RESULT_SUCCESS or int(answer[1]) != 200:
		print("CDN unreachable (result %d, HTTP %d): nothing to check" % [int(answer[0]), int(answer[1])])
		return false
	return true


func _connect_client(port: int, enet_port: int) -> Array:
	var side := Node.new()
	side.name = "Client"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := GSClientLink.new()
	link.name = "Server"
	link.player_name = "Surfer"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % enet_port
	side.add_child(link)
	var spawned := [false]
	var gone := [""]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.disconnected.connect(func(reason: String) -> void: gone[0] = reason)
	link.connect_to_server("127.0.0.1:%d" % port)
	return [side, link, spawned, gone]


func _run() -> void:
	print("FC: a real client joins a server on a published combat surf map and builds it from the pack")
	var settings := GSGameStandaloneContent.settings()
	var origin := String((settings["urls"] as PackedStringArray)[0])
	if not await _cdn_up(origin):
		get_tree().quit(0)
		return

	GSPaths.remove_tree(ROOT)
	DirAccess.make_dir_recursive_absolute(ROOT)
	_status = ProjectSettings.globalize_path(ROOT.path_join("host.json"))
	var port := FcTestPorts.free_port()

	_entered += 1
	print("\n-- a dedicated server in its own process names the pack and changes to it")
	_host_pid = OS.create_process(OS.get_executable_path(), [
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/published_net_host.tscn", "--",
		"--port=%d" % port, "--status=%s" % _status, "--seconds=%d" % int(HOST_SECONDS + CLIENT_SECONDS + 60.0),
	])
	if not _check(_host_pid > 0, "the server process starts", "create_process returned %d" % _host_pid):
		await _finish()
		return
	await _until(func() -> bool: return FileAccess.file_exists(_status), HOST_SECONDS)
	# One frame more: the host writes the file in one call, but the check should not race its close.
	await get_tree().create_timer(0.2).timeout
	var host: Variant = JSON.parse_string(FileAccess.get_file_as_string(_status)) if FileAccess.file_exists(_status) else null
	if not _check(host is Dictionary and bool((host as Dictionary).get("ok", false)),
			"it fetched, mounted and changed to %s" % MAP, str(host)):
		await _finish()
		return
	var h := host as Dictionary
	_check(bool(h.get("mounted", false)) and String(h.get("manifest_path", "")).begins_with("res://gs_cloud/"),
		"from its own mount (%s)" % h.get("manifest_path", ""))
	_completed += 1

	_entered += 1
	print("\n-- a client with its own gs-cloud joins over ENet and follows it onto the map")
	var shipped: Variant = JSON.parse_string(FileAccess.get_file_as_string(String(settings["config_file"])))
	var cloud: GSCloudClient = await _client_cloud(settings, shipped)
	var config := cloud.config
	var mounted_before := cloud.is_mounted(StringName("%s/%s" % [OWNER, PACK]), VERSION)

	var joined := _connect_client(port, int(h.get("enet_port", port)))
	var side: Node = joined[0]
	var link: GSClientLink = joined[1]
	var spawned: Array = joined[2]
	var gone: Array = joined[3]
	await _until(func() -> bool:
		return spawned[0] or gone[0] != "" or link.phase == GSClientLink.Phase.FAILED, 30.0)
	if not _check(spawned[0], "the client joins over ENet",
			"%s %s" % [gone[0], str(link.last_error) if link.last_error != null else ""]):
		await _finish()
		return
	GSGameClient.report_cover(link, false)

	var built := _build_client_net(side, link)
	var game: FcGame = built[0]
	var net: GSNetManager = built[1]
	var bridge: FcNetBridge = built[2]
	var session := [0]
	bridge.hello_received.connect(func(info: Dictionary) -> void: session[0] = int(info["session_id"]))
	# FcClient's map sync, before READY: the server announces its map when it admits the peer.
	var extras := FcClientExtras.new()
	extras.name = "Extras"
	extras.voice_enabled = false
	side.add_child(extras)
	var attached: GSResult = extras.attach(bridge, game)
	_check(attached.ok, "FcClientExtras attaches its map sync", str(attached.error))
	net.start()
	bridge.send_request(FcEvents.Ask.READY)

	await _until(func() -> bool:
		return (game.map != null and game.map.id == MAP) or gone[0] != "", CLIENT_SECONDS)
	await _check_client_map(game, bridge, cloud, mounted_before, session, gone)

	_completed += 1

	link.disconnect_from_server("test over")
	await _finish()


func _finish() -> void:
	if FileAccess.file_exists(_status):
		DirAccess.remove_absolute(_status)
	if _host_pid > 0:
		# The host quits on its own once its status file is gone; this is for one that hung.
		await _until(func() -> bool: return not OS.is_process_running(_host_pid), 10.0)
		if OS.is_process_running(_host_pid):
			OS.kill(_host_pid)
	GSPaths.remove_tree(ROOT)
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _until(cond: Callable, seconds: float) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return bool(cond.call())
