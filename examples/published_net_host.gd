extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcModule := preload("../game/fc_module.gd")

## The server half of `published_net`: a real dedicated FC server, in its own process, whose game
## names one published combat surf pack and which changes to that map before anybody joins.
##
## [codeblock]
## godot --headless --path . res://examples/published_net_host.tscn -- --port=27500 --status=user://x.json
## [/codeblock]
##
## Started by `published_net.tscn`, not by hand: it writes what it did to `--status` (JSON:
## `{ok, map, manifest_path, mounted, error}`) and quits after `--seconds` (default 240) or when
## the status file is removed. Its own [GSCloudClient] (side "both", its own cache), so the pack a
## client later builds is not the one this process fetched.

const MAP := &"surf_10x_reloaded_fixed"
const OWNER := "gamemann"
const PACK := "fc-surf-dm-maps-surf_10x_reloaded_fixed"
const VERSION := "1.2.3"

var _port := 0
var _status := ""
var _seconds := 240.0
var _root := "user://fc_published_net_host_%d" % OS.get_process_id()
var _server: GSServer = null


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			_port = a.get_slice("=", 1).to_int()
		elif a.begins_with("--status="):
			_status = a.get_slice("=", 1)
		elif a.begins_with("--seconds="):
			_seconds = a.get_slice("=", 1).to_float()
	if _port <= 0 or _status == "":
		printerr("published_net_host: needs --port=N and --status=<file>")
		get_tree().quit(2)
		return
	get_tree().create_timer(_seconds).timeout.connect(_stop)
	_run.call_deferred()


func _host_cloud(config: GSCloudConfig, settings: Dictionary) -> GSCloudClient:
	var cloud := GSCloudClient.new()
	cloud.name = "Cloud"
	cloud.config = config
	cloud.config_file = ""
	cloud.register_service = false
	cloud.http_base_urls = settings["urls"]
	add_child(cloud)
	GSRegistry.register(&"gs_cloud_client", cloud)
	await get_tree().process_frame
	return cloud


func _name_the_pack() -> void:
	# What cfg/content.yml's `maps:` gives a real server (gs-server-deploy's game-fatal-contact block): the game names
	# the published pack. A scene path with `://` in it, so a joining client is not asked to sync the game itself.
	var descriptor := GSGameDescriptor.new()
	descriptor.game_id = "game-fatal-contact"
	descriptor.scene = "res://game/fc_server.tscn"
	descriptor.maps = PackedStringArray(["%s/%s@%s" % [OWNER, PACK, VERSION]])
	_server.games.set(&"_current", descriptor)


func _server_config() -> GSServerConfig:
	var server_config := GSServerConfig.new()
	server_config.hostname = "fc published net"
	server_config.port = _port
	server_config.bind_address = "127.0.0.1"
	server_config.transport_mode = "dual"
	server_config.rcon_password = ""
	server_config.admins_path = _root.path_join("admins.json")
	server_config.bans_path = _root.path_join("bans.json")
	server_config.audit_log_path = _root.path_join("audit.jsonl")
	server_config.hibernate_when_empty = false
	server_config.startup_config = ""
	server_config.autoexec_config = ""
	server_config.query_enabled = false
	server_config.enet_share_udp_port = false
	server_config.stdin_console_enabled = false
	server_config.log_level = "error"
	return server_config


func _run() -> void:
	GSPaths.remove_tree(_root)
	Engine.physics_ticks_per_second = 64
	var settings := GSGameStandaloneContent.settings()
	var shipped: Variant = JSON.parse_string(FileAccess.get_file_as_string(String(settings["config_file"])))
	if not (shipped is Dictionary and (shipped as Dictionary).has("trusted_keys")):
		_write({"ok": false, "error": "no trusted_keys in %s" % settings["config_file"]})
		return

	var config := GSCloudConfig.new()
	config.side = "both"
	config.cache_dir = _root.path_join("cache")
	config.require_signed_manifests = true
	config.trusted_keys = (shipped as Dictionary)["trusted_keys"]
	var cloud := await _host_cloud(config, settings)

	var side := Node.new()
	side.name = "ServerSide"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())

	var game := FcGame.new()
	game.name = "Arena"
	game.tick_rate = 64
	game.score_limit = 0
	game.time_limit_sec = 0.0
	game.headless = true
	game.register_service = true
	side.add_child(game)
	var ready := game.setup(FcMap.dm_box())
	if not ready.ok:
		_write({"ok": false, "error": "setup: %s" % ready.error})
		return

	var server_config := _server_config()

	_server = GSServer.new()
	_server.name = "Server"
	_server.config = server_config
	_server.config_file = ""
	_server.auto_boot = false
	side.add_child(_server)
	var booted: GSResult = await _server.boot()
	if not booted.ok:
		_write({"ok": false, "error": "boot: %s" % booted.error})
		return

	_name_the_pack()

	FcModule.punishments_file = _root.path_join("punishments.json")
	var loaded: GSResult = await _server.modules.load_module("res://game/fc_module.gd")
	if not loaded.ok:
		_write({"ok": false, "error": "module: %s" % loaded.error})
		return
	var module := _server.modules.get_module("arena") as FcModule
	var quota: GSBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("off")
	if module.maps == null:
		_write({"ok": false, "error": "the module has no map director"})
		return

	var changed: GSResult = await module.maps.change_to(MAP)
	var map := game.map
	_write({
		"ok": changed.ok and map != null and map.id == MAP,
		"error": "" if changed.ok else str(changed.error),
		"map": String(map.id) if map != null else "",
		"manifest_path": map.manifest_path if map != null else "",
		"mounted": cloud.is_mounted(StringName("%s/%s" % [OWNER, PACK]), VERSION),
		"enet_port": server_config.effective_enet_port(),
	})
	while FileAccess.file_exists(_status):
		await get_tree().create_timer(0.25).timeout
	_stop()


func _write(status: Dictionary) -> void:
	var f := FileAccess.open(_status, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(status))
		f.close()
	if not bool(status.get("ok", false)):
		printerr("published_net_host: %s" % status.get("error", ""))


func _stop() -> void:
	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
	GSPaths.remove_tree(_root)
	get_tree().quit(0)
