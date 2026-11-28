extends GSGameCheckSuite

## A long offline bot match lived the way the VRAM growth was seen (fc-vram-growth-1): bots fight, the local player switches weapons and is
## killed again and again (kill view, respawn, equip). After a warm-up the counts that grow with leaked resources must stay flat:
## Performance.OBJECT_COUNT, RESOURCE_COUNT, orphan nodes, the RENDER_* resource counts (zero under the headless dummy renderer, still read),
## and the decal, particle, SubViewport and kill-view nodes in the tree. Headless builds no scope glass (AwScopeGlass returns null), so the
## lens ports are bounded by construction and by fc_scope_glass_cap, not here.

const FcContent := preload("../game/fc_content.gd")
const Presentation := preload("../game/fc_presentation.gd")

const EXPECTED_CHECKS := 11
const BOTS := 8
## Seconds of play before the first sample: every weapon drawn once, the kill view built, the pools full.
const WARMUP_SEC := 45.0
## Seconds between the two samples.
const WINDOW_SEC := 60.0
## The most each count may grow over the window. Objects and resources breathe with corpses, shots and drops in flight; a leak of one
## weapon build, kill screen or material per death or switch grows by hundreds to thousands a minute (the profile showed +1187 objects/min).
const OBJECTS_SLACK := 600
const RESOURCES_SLACK := 120
const ORPHANS_SLACK := 40
const NODES_SLACK := 300
const KIND_SLACK := 8

var _client: Node = null


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _press(action: StringName, down: bool) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = down
	Input.parse_input_event(e)


func _run() -> void:
	Presentation.use_scratch_settings("headless_vram_flat")
	_client = (load("res://game/fc.tscn") as PackedScene).instantiate()
	_client.set("force_offline", true)
	_client.set("mouse_capture_override", true)
	_client.set("offline_bots", BOTS)
	add_child(_client)
	var gm: Object = null
	while gm == null or gm.match_node == null:
		await _wait(0.1)
		gm = _client.get("game")
	var rules: Object = gm.match_node.rules
	rules.warmup_sec = 0.0
	rules.countdown_sec = 0.0
	rules.min_players = 1
	rules.score_limit = 0
	rules.time_limit_sec = 0.0
	rules.respawn_delay_sec = 1.0
	var live := false
	for i in 1200:
		await _wait(0.1)
		var me: Object = _client.get("player")
		if me != null and me.is_alive() and gm.match_node.state == GSMatch.State.LIVE:
			live = true
			break
	if not _check(live, "the offline match goes live with %d bots" % BOTS):
		_report(EXPECTED_CHECKS)
		return
	await _churn(gm, WARMUP_SEC)
	var a := _sample()
	print("  vram_flat warm: %s" % str(a))
	var deaths := await _churn(gm, WINDOW_SEC)
	var b := _sample()
	print("  vram_flat end:  %s" % str(b))
	_check(deaths >= 4, "the local player died and came back through the window (kill view and equip churn)", str(deaths))
	_flat(a, b, &"objects", OBJECTS_SLACK, "Performance.OBJECT_COUNT")
	_flat(a, b, &"resources", RESOURCES_SLACK, "Performance.OBJECT_RESOURCE_COUNT")
	_flat(a, b, &"orphans", ORPHANS_SLACK, "orphan nodes (stowed weapons, parked rigs)")
	_flat(a, b, &"nodes", NODES_SLACK, "nodes")
	_flat(a, b, &"render", 0, "RENDER_* resources (texture + buffer + video bytes)")
	_flat(a, b, &"decals", KIND_SLACK, "Decal nodes")
	_flat(a, b, &"particles", KIND_SLACK, "particle nodes")
	_flat(a, b, &"ports", 0, "SubViewport nodes")
	_flat(a, b, &"screens", 0, "kill view and killcam screens")
	_report(EXPECTED_CHECKS)


func _flat(a: Dictionary, b: Dictionary, key: StringName, slack: int, what: String) -> void:
	var grew := int(b[key]) - int(a[key])
	_check(grew <= slack, "%s stays flat after warm-up (grew %d over %.0f s, at most %d)" % [what, grew, WINDOW_SEC, slack],
		"%d -> %d" % [int(a[key]), int(b[key])])


## Plays [param sec]: the local player cycles weapons and, when alive and not just spawned, is killed by a bot. Returns the deaths seen.
func _churn(gm: Object, sec: float) -> int:
	var deaths := 0
	var t := 0.0
	var alive_for := 0.0
	var was_alive := true
	while t < sec:
		var me: Object = _client.get("player")
		var alive: bool = me != null and me.is_alive()
		if was_alive and not alive:
			deaths += 1
		was_alive = alive
		alive_for = alive_for + 0.25 if alive else 0.0
		if alive and int(t * 4.0) % 6 == 0:
			_press(&"arena_weapon_next", true)
			await get_tree().process_frame
			_press(&"arena_weapon_next", false)
		if alive and alive_for >= 5.0:
			_kill(gm, me)
		await _wait(0.25)
		t += 0.25
	return deaths


func _kill(gm: Object, me: Object) -> void:
	var bots: Dictionary = _client.get("_bots")
	if bots.is_empty():
		return
	var killer: Object = bots.values()[randi() % bots.size()]
	var damage := GSDamage.make(killer.player_id, me.player_id, 1000.0, gm.combat.damage_type(FcContent.DAMAGE_BULLET))
	damage.weapon_id = &"rifle"
	damage.tick = gm.current_tick()
	gm.combat.apply_damage(damage)


func _sample() -> Dictionary:
	var out := {
		&"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		&"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		&"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		&"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		&"render": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) + Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)
			+ Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)),
		&"decals": 0, &"particles": 0, &"ports": 0, &"screens": 0,
	}
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is Decal:
			out[&"decals"] += 1
		elif n is GPUParticles3D or n is CPUParticles3D:
			out[&"particles"] += 1
		elif n is SubViewport:
			out[&"ports"] += 1
		if n.name in [&"KillViewScreen", &"KillcamScreen"]:
			out[&"screens"] += 1
	return out
