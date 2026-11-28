extends "headless_hitreg_hosted.gd"

## headless_hitreg_hosted against a server the client did not start: the same server scene in its own process
## (GSServer + FcModule, 31 bots, dm_atrium snipers, 66 tick), and the client a plain online client that finds the
## link in the registry and joins it as it would join any dedicated server (no sim host, no local link, its own map
## load). The same taps must register the same way as on the hosted solo game.

var _host: FcSimHost = null


func _suite() -> String:
	return "headless_hitreg_dedicated"


func _start_client() -> bool:
	# Nobody else starts a server: the client below must find this one's link and join it.
	FcSimHost.forced = 0
	_host = FcSimHost.new()
	_host.name = "DedicatedServer"
	add_child(_host)
	var started: GSResult = await _host.start(BOTS)
	_check(started.ok, "the dedicated server process boots and the link joins it", str(started.error) if not started.ok else str(started.value))
	if not started.ok:
		return false
	_check(GSRegistry.get_service(&"gs_client_link") == _host.link, "the joined link is the registry's client link")
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("mouse_capture_override", true)
	add_child(_client)
	var platform: Object = _client.get("platform")
	_check(platform != null and not bool(platform.get("offline")) and not bool(platform.get("local_link")),
		"the client joined online, not as the hosted solo game")
	return true


func _end() -> void:
	if _host != null and is_instance_valid(_host):
		_host.stop()
	await super()
