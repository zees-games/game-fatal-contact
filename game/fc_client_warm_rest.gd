extends "fc_client_hud_and_camera.gd"

## The cover's render warm-up: milliseconds a round's frame may cost, the bare load frame included; see setup's use.
const GATE_WARM_BUDGET_MSEC := 100.0
## The art ids every spawn carries; the other models load after the cover lifts ([method _warm_rest_tick]).
const SPAWN_ARTS: Array[StringName] = [&"pistol", &"knife"]
## The load gate's give-up time in a browser (GSLoadGate's default is 20 s); see setup's use.
const WEB_GATE_TIMEOUT_SEC := 60.0
## The per-frame slice a desktop client's warm-up steps take under the cover ([method GSLoadGate.slice_msec]), against gs-core's 8 ms
## where threads exist: a load frame is also the match's ticks and a draw (~30 ms on staging), so 8 ms slices stretched the
## view-model prewarm over 218 frames. `cl_cover_slice_msec N` (launch argument) sets it; -1 keeps gs-core's default, as before.
const NATIVE_COVER_SLICE_MSEC := 32
var _rest_paths: Array[String] = []

## The client's platform build and the warm-up of what the gate does not cover (spawn models, weapons) after it lifts. Split out of fc_client_session_events.gd for file size.


func _spawn_model_paths() -> Array[String]:
	var arts: Array[AwWeaponVisual] = []
	for id in SPAWN_ARTS:
		var art := AwWeaponArtTable.get_art(id)
		if art != null:
			arts.append(art)
	return AwWeaponArtTable.Listing.model_paths(arts, false)


## Loads the models the cover did not wait for, one a frame, so the first draw of any gun is a cache hit.
func _warm_rest_tick() -> void:
	if _rest_paths.is_empty():
		get_tree().process_frame.disconnect(_warm_rest_tick)
		return
	AwModelCache.scene(_rest_paths.pop_back())


## Frames between two arm-rig builds, and between looks at who joined since: one build is 25-33 ms native, 145 on the web.
const KILLER_ARMS_FRAMES := 24


## Builds the arm rigs for the players who may kill the local one, one every [constant KILLER_ARMS_FRAMES] frames, so the
## first death by each does not build one in its frame (146-149 ms spikes in the first minute of a web match).
func _warm_killer_arms_tick() -> void:
	if not is_instance_valid(_killer_arms_pov):
		get_tree().process_frame.disconnect(_warm_killer_arms_tick)
		return
	_killer_arms_wait += 1
	if _killer_arms_wait < KILLER_ARMS_FRAMES:
		return
	_killer_arms_wait = 0
	var _done: bool = _killer_arms_pov.call(&"warm_killers")


func _begin_warm_rest() -> void:
	var first := _spawn_model_paths()
	for path in AwWeaponArtTable.model_paths():
		if not first.has(path):
			_rest_paths.append(path)
	if not _rest_paths.is_empty() and not get_tree().process_frame.is_connected(_warm_rest_tick):
		get_tree().process_frame.connect(_warm_rest_tick)
	if not GSPlatform.is_headless() and is_instance_valid(_killer_arms_pov) and not get_tree().process_frame.is_connected(_warm_killer_arms_tick):
		get_tree().process_frame.connect(_warm_killer_arms_tick)


func _weapon_warm_items() -> Array:
	var out: Array = []
	for path in _spawn_model_paths():
		var model := AwModelCache.instantiate(path)
		if model == null:
			continue
		var stack: Array[Node] = [model]
		while not stack.is_empty():
			var node: Node = stack.pop_back()
			stack.append_array(node.get_children())
			var mi := node as MeshInstance3D
			if mi == null or mi.mesh == null:
				continue
			if not out.has(mi.mesh):
				out.append(mi.mesh)
			for i in mi.mesh.get_surface_count():
				var m := mi.get_active_material(i)
				if m != null and not out.has(m):
					out.append(m)
		model.free()
	return out


## gs-game's platform layer, added first so the cover is the first thing drawn. [b]Only the pieces that remove duplicate code without moving a documented rule.[/b] Taken: the gate (with the map hold and the weapon warm-up on it), the link and the offline answer, the browser flush, and the input-blocked signal. Left off, each for a reason:
## [code]use_settings[/code] and [code]use_console[/code], because the settings document is [FcPresentation]'s plain manager with a menu built round it by [FcMenus] (the Servers page, the camera rows) and the console must be built after that menu; [code]capture_pointer[/code], because Escape releases and then opens, and "Click to play"
## is Fatal Contact's ([method _unhandled_input]); the Tab board, because [FcMenus].Board merges gs-match's records with the roster.
func _build_platform() -> void:
	platform = GSGameClient.new()
	platform.name = "Platform"
	# A solo game hosted beside this process is joined like any server, whatever asked for offline.
	platform.force_offline = force_offline and _sim_host == null
	if _sim_host != null:
		# `--offline` means no remote server; the link to this machine's own server survives it.
		platform.link = _sim_host.link
		platform.local_link = true
	platform.use_settings = false
	platform.use_console = false
	platform.capture_pointer = false
	platform.scoreboard_action = &""
	platform.spawned_fn = func() -> bool: return player != null and player.camera != null
	add_child(platform)
	gate = platform.gate
	_widen_cover_slice()
	# A browser's first start compiles every shader while the weapons warm (slow frames of 0.3 to 3 s): the
	# "weapons" hold, progressing all along, ended 19.9 s after the gate closed, past the 20 s default.
	if GSPlatform.is_web():
		gate.timeout_sec = maxf(gate.timeout_sec, WEB_GATE_TIMEOUT_SEC)
		# The gate's warm-up keeps to the handed-in weapon and effect items: quad copies of the level's
		# own materials are variants the real draw never uses. On staging02 a return visit went from
		# 52.8 s to 35.7 s download-to-playable (median of 3), after-open worst frames no worse.
		if &"warm_game_root" in gate:
			gate.set(&"warm_game_root", false)
	# The warm-up sizes its rounds by what is left of this budget after a bare frame, and a load frame
	# here (the match's ticks and the view) is 56-100 ms on staging02: at gs-core's 40 nothing is
	# left, every round is 4 items over 2 frames, and the warm-up took 9-11 s of the cover.
	if &"warm_budget_msec" in gate:
		gate.set(&"warm_budget_msec", maxf(float(gate.get(&"warm_budget_msec")), GATE_WARM_BUDGET_MSEC))
	link = platform.link as Node
	gate.ready_to_show.connect(func() -> void: ready_to_show.emit())
	gate.hold(&"map", "Loading the map")
	# Headless draws nothing: loading every weapon model to warm its materials is 38 MB for no frame.
	if not GSPlatform.is_headless():
		gate.warm_up(_weapon_warm_items())
		gate.opened.connect(_begin_warm_rest, CONNECT_ONE_SHOT)
		gate.opened.connect(_prebuild_catalogue, CONNECT_ONE_SHOT)
	if FcFrameProbe.on() and GSWeb.available():
		# Lets a page script split its own frame log at the cover (window.gsWeb.publishedAt.arena_gate_open, ms).
		gate.opened.connect(func() -> void: GSWeb.publish("arena_gate_open", "1"))
	# The chat box and console have the keyboard, and so does the menu: the platform polls
	# this every frame, so there is no signal to forward from each of them.
	platform.busy_fn = _input_busy
	platform.input_blocked_changed.connect(_suspend_input)


## Sets the gate's cover slice on a desktop client (see [constant NATIVE_COVER_SLICE_MSEC]); the web keeps gs-core's 24 ms.
func _widen_cover_slice() -> void:
	if GSPlatform.is_web() or not (&"cover_slice_msec" in gate):
		return
	var asked := FcFrameProbe.launch_value("cl_cover_slice_msec")
	var slice := NATIVE_COVER_SLICE_MSEC if asked.is_empty() else int(asked)
	if slice >= 0:
		gate.set(&"cover_slice_msec", slice)
