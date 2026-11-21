extends Node

## Paired in-run ablation of the process phase: the recording is cut into slices of `slice` frames that rotate
## base, lever 1, base, lever 2, ... A lever stops processing (PROCESS_MODE_DISABLED) or hides one group of nodes for
## its slice; its cost is its slice's time less the mean of the base slices on either side, so a box whose load drifts
## during the run still gives a fair difference. Reads tools/proc_split.gd's running sums (early_flush, process_pass,
## late_flush, to_pre_draw) and the wall clock. perf_bench.gd: `--proc-split 1 --proc-ablate fx,hud,... --proc-slice N`.
## Bench only: a group's state is wrong for its slice and is restored after it.

## Script file names (without .gd) per lever; a node matches when its script's file name is in the list.
const SCRIPTS := {
	"figures": ["dot_humanoid_figure"],
	"fx": ["aw_shot_fx", "aw_charge_fx", "aw_shot_layers", "aw_world_model", "dot_shot_player", "dot_weapon_tracers",
		"fc_projectile_view", "dot_spawn_bubble_3d", "dot_damage_numbers"],
	"hud": ["fc_hud", "dot_crosshair", "dot_hit_marker", "dot_vitals", "dot_ammo_counter", "dot_key_hints", "dot_key_prompt",
		"dot_feed_view", "aw_scope_overlay", "dot_menu_net_stat"],
	"menus": ["dot_menu", "dot_menu_layout_editor", "dot_menu_scoreboard", "dot_menu_screen", "dot_menu_team_screen", "dot_browser",
		"dot_settings_manager", "dot_mobile_buttons", "dot_mobile_controls", "dot_game_workbench", "dot_voice_manager",
		"dot_load_gate", "dot_camera_fade", "dot_map_visibility"],
	"audio": ["fc_audio_manager", "dot_audio_manager", "dot_ambience", "dot_audio_ambience", "dot_game_slide_sounds",
		"dot_audio_footsteps", "dot_audio_slide", "dot_audio_surf"],
	"view": ["fc_view_arms", "aw_view_model", "dot_flashlight", "dot_flashlight_crowd", "fc_flag_view", "fc_drops",
		"dot_killcam", "dot_player_body_break", "dot_prop_toy_box", "dot_weapon_knives", "dot_weapon_drops"],
	"pres": ["fc_presentation", "dot_game_avatar_action_client"],
}
## Engine classes per lever, disabled.
const CLASSES := {"skel": ["Skeleton3D"], "anim": ["AnimationPlayer", "AnimationTree"], "particles": ["GPUParticles3D", "CPUParticles3D"]}
## Engine classes per lever, hidden instead: what they draw and lay out, not what they run.
const HIDE := {"label3d": ["Label3D"], "controls": ["Control"]}
const PARTS := ["early_flush", "process_pass", "late_flush", "to_pre_draw"]
## Frames after each switch left out of the slice.
const SKIP := 3

var split: Node
var levers := PackedStringArray()
var slice := 40
var _order: Array[String] = []
var _i := 0
var _n := 0
var _saved := {}
var _us0 := PackedInt64Array()
var _frames0 := 0
var _t0 := 0
var _prev_base := {}
var _pending := {}
## lever -> {"n": slices, part: summed delta}
var _acc := {}
var _base_acc := {"n": 0}
var _matched := {}


func _ready() -> void:
	get_tree().process_frame.connect(_frame)
	for l in levers:
		_order.append("")
		_order.append(l)


func _frame() -> void:
	if _order.is_empty():
		return
	_n += 1
	if _n == SKIP:
		_us0 = split.us.duplicate()
		_frames0 = split.frames
		_t0 = Time.get_ticks_usec()
	if _n < slice:
		return
	_close()
	_i = (_i + 1) % _order.size()
	_n = 0
	_open(_order[_i])


func _close() -> void:
	var f: int = split.frames - _frames0
	_restore()
	if f <= 0 or _us0.is_empty():
		return
	var d := {"wall": float(Time.get_ticks_usec() - _t0) / 1000.0 / f}
	for k in PARTS.size():
		d[PARTS[k]] = float(split.us[k] - _us0[k]) / 1000.0 / f
	var lever := _order[_i]
	if lever != "":
		_pending = {"lever": lever, "d": d}
		return
	_add(_base_acc, d)
	# A lever's slice is judged against the base slices on both sides of it.
	if not _pending.is_empty() and not _prev_base.is_empty():
		var l: String = _pending.lever
		if not _acc.has(l):
			_acc[l] = {"n": 0}
		var delta := {}
		for k: String in d:
			delta[k] = float(_pending.d[k]) - (float(d[k]) + float(_prev_base[k])) / 2.0
		_add(_acc[l], delta)
	_pending = {}
	_prev_base = d


func _add(acc: Dictionary, d: Dictionary) -> void:
	acc.n += 1
	for k: String in d:
		acc[k] = float(acc.get(k, 0.0)) + float(d[k])


func _open(lever: String) -> void:
	if lever == "":
		return
	# "own:<script>" stops _process on that script's nodes only; "sub:<script>" on them and everything under them.
	# Neither cascades the way a process_mode does, so a root and its subtree are told apart.
	if lever.begins_with("own:") or lever.begins_with("sub:"):
		_open_own(lever.substr(4), lever.begins_with("sub:"))
		return
	var names: Array = SCRIPTS.get(lever, [])
	var classes: Array = CLASSES.get(lever, [])
	var hide: Array = HIDE.get(lever, [])
	for n in get_tree().root.find_children("*", "", true, false):
		if n == split or n == self or n == get_parent():
			continue
		var hit := false
		var s: Script = n.get_script()
		if s != null and s.resource_path.get_file().get_basename() in names:
			hit = true
		for c: String in classes:
			hit = hit or n.is_class(c)
		if hit:
			_saved[n] = n.process_mode
			n.process_mode = Node.PROCESS_MODE_DISABLED
			continue
		for c: String in hide:
			if n.is_class(c) and n.get("visible") == true:
				_saved[n] = -1
				n.set("visible", false)
	_matched[lever] = maxi(int(_matched.get(lever, 0)), _saved.size())


func _open_own(script: String, below: bool) -> void:
	for n in get_tree().root.find_children("*", "", true, false):
		var s: Script = n.get_script()
		if s == null or s.resource_path.get_file().get_basename() != script:
			continue
		var targets: Array = [n]
		if below:
			targets.append_array(n.find_children("*", "", true, false))
		for t: Node in targets:
			if t.is_processing() and not _saved.has(t):
				_saved[t] = -2
				t.set_process(false)
	_matched[("sub:" if below else "own:") + script] = maxi(int(_matched.get(("sub:" if below else "own:") + script, 0)), _saved.size())


func _restore() -> void:
	for n: Variant in _saved:
		if not is_instance_valid(n):
			continue
		if int(_saved[n]) == -2:
			(n as Node).set_process(true)
		elif int(_saved[n]) == -1:
			(n as Node).set("visible", true)
		else:
			(n as Node).process_mode = _saved[n]
	_saved.clear()


## Per lever: slices measured, nodes switched, and ms/frame of each part above (+) or below (-) its neighbouring
## base slices (a lever that saves time reads negative); "base" is the mean base slice.
func report() -> Dictionary:
	_restore()
	var out := {"slice": slice, "base": _mean(_base_acc)}
	for l: String in _acc:
		out[l] = _mean(_acc[l])
		out[l]["nodes"] = _matched.get(l, 0)
	return out


func _mean(acc: Dictionary) -> Dictionary:
	var r := {"n": acc.n}
	for k: String in acc:
		if k != "n":
			r[k] = snappedf(float(acc[k]) / maxf(acc.n, 1.0), 0.001)
	return r
