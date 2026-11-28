extends "fc_client_vars.gd"

## The load gate's weapon model reads and loadout pictures (and the timeline and late-view constants the prewarm shares);
## split out of fc_client_prewarm.gd for file size.


const FcLoadTimeline := preload("fc_load_timeline.gd")

## A late view stage runs only while the player is away (dead, or spectating), after a frame this quick (msec), and at
## most one every [constant LATE_VIEW_GAP] frames: a stage is one 70-400 ms frame, which in play is a hitch.
const LATE_VIEW_QUICK_MSEC := 25.0
const LATE_VIEW_GAP := 2


## True: a web client holds the cover only for the models of the weapons somebody in the match carries now (and the default
## loadout's), and reads every other weapon's after the cover drops ([method _models_late]). On staging02 the 27 reads held the
## web cover 25.2-31.95 s, beside the sounds. A desktop client reads them all under the cover, on the loader's threads, as before.
static var defer_models_on_web := true
## True: every client defers them and reads them inline, as the web does (perf_bench `--lazy-models 1`, to price the first equips after the cover).
static var defer_models_everywhere := false
var _previews_wait := false
## Whether the loadout pictures wait for the threaded model reads under the cover: a picture's plain load of a file still in a read
## waits for it, one 0.3-1.25 s frame on staging (dm_box). `cl_previews_after_reads 0` (launch argument) starts them with the views.
func _previews_after_reads() -> bool:
	return _model_reads_threaded() and FcFrameProbe.launch_value("cl_previews_after_reads") != "0"

## Starts drawing the loadout screen's weapon pictures, once: a frame each beside the rest of the cover's work.
func _warm_previews() -> void:
	if not _previews_wait or loadout_menu == null:
		return
	_previews_wait = false
	weapon_previews().warmed.connect(func() -> void: FcLoadTimeline.mark("prewarm: %d weapon pictures, own work %d ms" % [weapon_previews().cached_count(), int(weapon_previews().warm_msec())]), CONNECT_ONE_SHOT)
	weapon_previews().warm()

## Reads weapon model files once, a few ms a frame under the loading cover (also headless: it is only file reads), so the first equip of each - a bot picking one up, a pickup, a drop - does not pay 90-110 ms for the load in the middle of a fight.
## Those [method _cover_weapon_ids] names come first and hold the gate; where models are deferred the rest are read after it opens, see [method _models_late].
func _prewarm_models() -> void:
	if _model_paths_next >= 0 or gate == null or gate.is_open():
		return
	var wanted := _cover_weapon_ids(player if is_instance_valid(player) else null, true)
	var defer := defer_models_everywhere or (defer_models_on_web and GSPlatform.is_web())
	var now: Array = []
	var late: Array = []
	for art: Variant in AwWeaponArtTable.table().values():
		if art is AwWeaponVisual and (art as AwWeaponVisual).has_model():
			var path := (art as AwWeaponVisual).model_path
			if not defer or wanted.has((art as AwWeaponVisual).id):
				now.append(path)
			else:
				late.append(path)
	_model_paths = now + late
	_model_paths_cover = now.size()
	_model_paths_next = 0
	_model_late_gap = 0
	# The reads run on the loader's own threads: a big model read inline held one frame for seconds (7455 ms on a slow disk), and the tick below only takes a file once it has landed. Not headless: the dummy renderer's mesh storage is not safe against a loader thread creating
	# meshes beside the main thread (RID errors, a mesh leaked at exit, an odd viewarms failure), and there the tick below simply loads each file itself, a few ms a frame. No loader threads either on the web build: a request reads the file inline, so the 27 requests
	# were one 2074-2426 ms frame on staging02. There the tick reads them itself, one or two a frame.
	if _model_reads_threaded():
		for path: Variant in _model_paths:
			var real := AwModelCache.resolve(str(path))
			if ResourceLoader.exists(real):
				ResourceLoader.load_threaded_request(real)
	FcLoadTimeline.mark("model reads start: %d files, %d under the cover" % [_model_paths.size(), _model_paths_cover])
	if _model_paths_cover > 0:
		gate.hold(&"weapon_models", "Preparing weapon models")
	get_tree().process_frame.connect(_prewarm_models_tick)

## Whether the model reads run on the loader's threads (see [method _prewarm_models]). Not with [member defer_models_everywhere]:
## that stands in for the web build, whose reads are inline.
static func _model_reads_threaded() -> bool:
	return DisplayServer.get_name() != "headless" and loader_threads_usable() and not defer_models_everywhere

## Whether a threaded resource read really runs beside the frame: [method FcFrameProbe.loader_threads_usable].
static func loader_threads_usable() -> bool:
	return FcFrameProbe.loader_threads_usable()

## The weapon ids whose views or models are made under the cover where the rest wait for it to drop: the default loadout's,
## those [param body] carries and, with [param everyone] (models: their world models are built at once), those every other
## player in the match carries now.
func _cover_weapon_ids(body: FcPlayer, everyone: bool) -> Dictionary:
	var wanted: Dictionary = {}
	for id: StringName in FcContent.default_loadout():
		wanted[id] = true
	var bodies: Array = [body]
	if everyone and game != null:
		bodies.append_array(game.players())
	for p: Variant in bodies:
		if p is FcPlayer and (p as FcPlayer).arsenal != null:
			var arsenal: Variant = (p as FcPlayer).arsenal
			for slot: int in arsenal.slots():
				var held: Variant = arsenal.slot_at(slot)
				if held != null:
					wanted[held.id()] = true
	return wanted

## True while the shell is still fetching the addon groups a web start left out (gs_cloud/late_groups/pending, set by the shell and cleared
## when they are mounted): the late builds and reads wait, or they would find those models missing and remember that.
static func _late_groups_pending() -> bool:
	return bool(ProjectSettings.get_setting("gs_cloud/late_groups/pending", false))

## True while the local player is away (dead, or spectating): a long frame then is not a hitch in play.
func player_away() -> bool:
	if not is_instance_valid(player):
		return true
	return not player.is_alive() or (game != null and game.spectate != null and game.spectate.is_spectating(str(player.player_id)))

## A client freed mid-read takes what the loader holds for it, or those scenes outlive the run: every
## requested file (not only those the tick has not reached), the tick disconnected so it cannot take
## one after this, and the model cache emptied so no scene or mesh outlives the renderer at exit.
func _drain_model_reads() -> void:
	if is_inside_tree() and get_tree().process_frame.is_connected(_prewarm_models_tick):
		get_tree().process_frame.disconnect(_prewarm_models_tick)
	if _model_paths_next < 0:
		return
	for path: Variant in _model_paths:
		var real := AwModelCache.resolve(str(path))
		if ResourceLoader.load_threaded_get_status(real) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			var _dropped := ResourceLoader.load_threaded_get(real)
	_model_paths_next = _model_paths.size()
	AwModelCache.clear()

func _prewarm_models_tick() -> void:
	if _model_paths_next >= _model_paths_cover:
		_models_late()
		return
	var until := Time.get_ticks_msec() + (int(gate.call(&"slice_msec", 8)) if gate != null and gate.has_method(&"slice_msec") else 8)
	while _model_paths_next < _model_paths_cover and Time.get_ticks_msec() < until:
		if not _read_next_model():
			break
	if _model_paths_next >= _model_paths_cover:
		FcLoadTimeline.mark("model reads under the cover done: %d files" % _model_paths_cover)
		_warm_previews()
		if gate != null:
			gate.release(&"weapon_models")
		if _model_paths_next >= _model_paths.size():
			_models_end()

## Takes the next model into AwModelCache; false while its threaded read is still in flight.
func _read_next_model() -> bool:
	var real := AwModelCache.resolve(str(_model_paths[_model_paths_next]))
	if ResourceLoader.load_threaded_get_status(real) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return false
	# Landed (or never requested). Taking it from the loader frees the loader's hold on it; kept in
	# `landed` while the cache loads it, that load is a cache hit, a few ms at most.
	var landed: Resource = ResourceLoader.load_threaded_get(real) if ResourceLoader.load_threaded_get_status(real) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE else null
	var read_began := Time.get_ticks_msec()
	AwModelCache.warm([_model_paths[_model_paths_next]])
	if Time.get_ticks_msec() - read_began >= 50:
		FcLoadTimeline.mark("model read %s" % str(_model_paths[_model_paths_next]).get_file(), Time.get_ticks_msec() - read_began)
	landed = null
	_model_paths_next += 1
	# Each read is progress, so the gate's timeout counts from here: a slow box reading all 19 inline (PH) still gets them all.
	if gate != null and gate.has_method(&"advance"):
		gate.call(&"advance", &"weapon_models")
	return true

## After the cover drops, the deferred models: a threaded read is taken once it has landed (a cache hit, a few ms), in any frame. An inline read (the web) is one 50-400 ms frame, so it runs as a late view does: only while the player is away,
## after a frame quicker than [constant LATE_VIEW_QUICK_MSEC], at most one every [constant LATE_VIEW_GAP] frames. A weapon equipped before its turn loads its model on that equip; the read here is then a cache hit.
func _models_late() -> void:
	if _model_paths_next >= _model_paths.size():
		_models_end()
		return
	if gate == null or not gate.is_open() or _late_groups_pending():
		return
	if not _model_reads_threaded():
		_model_late_gap += 1
		if _model_late_gap < LATE_VIEW_GAP or get_process_delta_time() * 1000.0 > LATE_VIEW_QUICK_MSEC or not player_away():
			return
		_model_late_gap = 0
	var _read := _read_next_model()
	if _model_paths_next >= _model_paths.size():
		FcLoadTimeline.mark("model reads after the cover done: %d files" % (_model_paths.size() - _model_paths_cover))
		_models_end()

func _models_end() -> void:
	if get_tree().process_frame.is_connected(_prewarm_models_tick):
		get_tree().process_frame.disconnect(_prewarm_models_tick)
