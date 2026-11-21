extends GSGameCheckSuite
## Every attachment on every gun it fits, through the attachments menu of a real offline client: each one is
## hovered (its live preview and stat bars), picked, drawn on the view model, aimed down and fired, then taken off;
## last, every mount of the gun is filled at once. The engine must report no error and the process must live
## (the owner's client died picking the Laser Sight on the Marksman Rifle, 2026-11-16).
##   godot --headless --path . res://examples/headless_attach_all.tscn
## `-- --shard wN` plays every SHARDS-th gun of the sorted catalogue; `-- --merge LOG...` joins the shards.
## `-- --only=marksman,rifle` plays those guns; `-- --shots=DIR` (windowed, tools/attach_menu_shot.sh) saves a frame per pick.

const FcPresentation := preload("../game/fc_presentation.gd")
const FcAttach := preload("../game/fc_attach.gd")

const SHARDS := 2
## Guns with at least one attachment choice (the merge has no client to count them from): a new one says so here.
const GUNS := 20

var _client: Node = null
var _entered := 0
var _finished := 0
var _sections := 0
var _errors: EngineErrors = null
var _only := PackedStringArray()
var _shots := ""
var _shot := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	if GSGameShardArgs.is_merge():
		_merge.call_deferred()
		return
	var args := OS.get_cmdline_user_args()
	# One word each (`--only=a,b`, `--shots=DIR`): a bare path argument is a map drop to the client.
	for a: String in args:
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=").split(",", false)
		elif a.begins_with("--shots="):
			_shots = a.trim_prefix("--shots=")
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	var _dir := FcPresentation.use_scratch_settings("headless_attach_all")
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	add_child(_client)
	_run.call_deferred()


func _merge() -> void:
	var logs := GSGameShardArgs.merge_logs()
	var missing := GSGameShardArgs.missing(logs)
	_check(logs.size() == SHARDS and missing.is_empty(), "every shard's log is there (%d logs)" % logs.size(), "missing %s" % [missing])
	var entered := GSGameShardArgs.sections_entered(logs)
	_check(entered == GUNS, "the shards entered one section per gun with attachments (%d of %d)" % [entered, GUNS])
	_report_sections(1, 1, 1)


func _run() -> void:
	print("game-fatal-contact: every attachment on every gun, through the menu")
	_errors = EngineErrors.new()
	OS.add_logger(_errors)
	if not await _until(func() -> bool: return _client.get("player") != null and bool(_client.call(&"is_ready_to_show")), 90.0):
		_check(false, "the offline client arms its player and lifts the cover")
		_report_sections(0, 0, 1)
		return
	var me = _client.get("player")
	me.health.invulnerable = true
	var cat := FcAttach.catalogue()
	var ids: Array = []
	for id: StringName in AwWeaponCatalogue.table().keys():
		var base: GSWeaponDef = me.arsenal.catalogue.get_def(id)
		if base != null and not cat.choices_for(base).is_empty():
			ids.append(id)
	ids.sort()
	print("guns with attachments: %d %s" % [ids.size(), ids])
	if GSGameShardArgs.shard() == "" and _only.is_empty():
		_check(ids.size() == GUNS, "%d guns take attachments (GUNS says %d)" % [ids.size(), GUNS])
	var play: Array = []
	for i in ids.size():
		if not _only.is_empty() and not _only.has(String(ids[i])):
			continue
		if GSGameShardArgs.shard() == "" or GSGameShardArgs.shard() == "w%d" % (i % SHARDS):
			play.append(ids[i])
	_sections = play.size()
	for id: StringName in play:
		await _gun(me, id)
	OS.remove_logger(_errors)
	var seen := _errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run", "%d: %s" % [seen.size(), ", ".join(seen.slice(0, 5))])
	_report_sections(_entered, _finished, _sections)


func _gun(me: Node, id: StringName) -> void:
	_entered += 1
	print("")
	print(id)
	var _given = me.arsenal.give(id)
	me.arsenal.equip(me.arsenal.catalogue.get_def(id).slot)
	if not _check(await _until(func() -> bool: return me.arsenal.current() != null and me.arsenal.current().def.id == id and not me.arsenal.is_switching(), 4.0), "%s is in the hands" % id):
		_finished += 1
		return
	await _seconds(0.3)
	if not _check(bool(_client.call(&"open_attachments")), "%s: the attachments menu opens" % id):
		_finished += 1
		return
	var panel: Node = _client.get("attach_panel")
	var base: GSWeaponDef = me.arsenal.catalogue.get_def(id)
	var choices: Dictionary = FcAttach.catalogue().choices_for(base)
	var before := _errors.seen().size()
	for mount: StringName in choices:
		for att: StringName in choices[mount]:
			print("  %s %s" % [mount, att])
			await _fit(me, panel, id, mount, att)
			await _fit(me, panel, id, mount, &"")
	# Everything at once: the first choice of every mount.
	for mount: StringName in choices:
		var list: Array = choices[mount]
		if not list.is_empty():
			await _fit(me, panel, id, mount, list[0])
	await _shoot(me)
	for mount: StringName in choices:
		await _fit(me, panel, id, mount, &"")
	panel.call(&"close")
	var seen := _errors.seen()
	_check(seen.size() == before, "%s: every attachment fits, previews, aims and fires with no engine error" % id, ", ".join(seen.slice(before, before + 5)))
	_finished += 1


func _fit(me: Node, panel: Node, id: StringName, mount: StringName, att: StringName) -> void:
	await _hold(me, id)
	if not bool(panel.call(&"is_open")):
		var _reopened := bool(_client.call(&"open_attachments"))
	var menu: Object = panel.get(&"menu")
	if menu != null and menu.has_method(&"preview"):
		menu.call(&"preview", mount, att)
		await _frames(3)
	elif menu != null and menu.has_method(&"_on_focus"):
		menu.call(&"_on_focus", mount, att)
	await _snap("%s_%s_%s_hover" % [id, mount, att])
	panel.call(&"_on_requested", mount, att)
	var fitted := await _until(func() -> bool: return me.arsenal.fitting_at(me.arsenal.current_slot()).attachment_on(mount) == att, 2.0)
	_check(fitted, "%s: %s on %s" % [id, att if att != &"" else &"nothing", mount])
	await _frames(4)
	await _snap("%s_%s_%s_fitted" % [id, mount, att])
	if att != &"":
		await _shoot(me)


## The gun back in the hands: a thrown knife or boomerang leaves them until it returns or is given again.
func _hold(me: Node, id: StringName) -> void:
	if await _until(func() -> bool: return me.arsenal.current() != null and me.arsenal.current().def.id == id and not me.arsenal.is_switching(), 1.5):
		return
	var _given = me.arsenal.give(id)
	me.arsenal.equip(me.arsenal.catalogue.get_def(id).slot)
	var _held := await _until(func() -> bool: return me.arsenal.current() != null and me.arsenal.current().def.id == id and not me.arsenal.is_switching(), 4.0)


## A frame of the window into --shots, when asked (windowed only).
func _snap(label: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	_shot += 1
	var img := get_viewport().get_texture().get_image()
	if img != null:
		var _saved := img.save_png(_shots.path_join("%03d_%s.png" % [_shot, label]))


func _shoot(me: Node) -> void:
	if me.arsenal.current() == null:
		return
	me.arsenal.current().magazine = maxi(me.arsenal.current().magazine, 3)
	Input.action_press(&"arena_aim")
	await _seconds(0.25)
	Input.action_press(&"arena_fire")
	await _seconds(0.15)
	Input.action_release(&"arena_fire")
	Input.action_release(&"arena_aim")
	await _frames(3)


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame


func _seconds(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


## Counts the engine's own errors while installed (as headless_net_rounding): they change no exit code otherwise.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, file: String, line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s %s:%d)" % [code, function, file.get_file(), line])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out
