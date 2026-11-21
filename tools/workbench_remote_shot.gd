extends SceneTree

const FcConfig := preload("../game/fc_config.gd")
const FcGame := preload("../game/fc_game.gd")

## Renders the remote admin's tuning panel (what an admin sees on a server that allows `sv_workbench_remote`) to
## res://screenshots/workbench_remote.png. Run under xvfb-run: tools/workbench_remote_shot.sh


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var net := GSNetManager.new()
	net.is_server = false
	net.local_peer_id = 5
	net.config_file = ""
	var _s := net.setup()
	var client := GSGameWorkbenchRemoteClient.attach(net)
	var wb := GSGameWorkbench.new()
	wb.remote_client = client
	wb.remote_fn = func() -> bool: return true
	var binder := FcConfig.make_binder(FcGame.new().config)
	var _l := binder.load_layers()
	for set: GSProfileSet in binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	root.add_child(wb)
	var started := wb.start(GSProfileRuntime.new())
	var told := GSGameWorkbenchMessage.new()
	told.kind = GSGameWorkbenchMessage.KIND_ACCESS
	told.allowed = true
	told.flags = "cvar,root"
	client.handle_message(told)
	await _frames(3)
	wb.toggle()
	await _frames(6)
	var img := root.get_viewport().get_texture().get_image()
	var saved := img.save_png(ProjectSettings.globalize_path("res://screenshots/workbench_remote.png"))
	print("started=%s panel=%s open=%s saved=%d" % [started.ok, wb.overlay != null, wb.is_open(), saved])
	quit(0 if started.ok and wb.overlay != null and wb.is_open() else 1)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame
