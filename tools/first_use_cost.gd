extends Node

const FcPaths := preload("../game/fc_paths.gd")
const FcWeaponSkins := preload("../game/fc_weapon_skins.gd")

## What a weapon costs the frame that first equips it, with the cover's prewarm done or not: the first-person view and the third-person world model each, in ms,
## per weapon art. The cover builds view models only (`AwViewModel.prewarm`), so this shows what is left for the first real equip.
## `godot --headless --path . res://tools/first_use_cost.tscn -- [--prewarm view|both|none]`.

func _ready() -> void:
	AwModelCache.set_asset_root(FcPaths.root())
	FcWeaponSkins.apply()
	var mode := "view"
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--prewarm":
			mode = args[i + 1]
	var cam := Camera3D.new()
	add_child(cam)
	var spare := AwViewModel.new()
	cam.add_child(spare)
	var view := AwViewModel.new()
	cam.add_child(view)
	var world := AwWorldModel.new()
	add_child(world)
	await get_tree().process_frame
	var table := AwWeaponArtTable.table()
	var t_all := Time.get_ticks_usec()
	if mode != "none":
		for id in table:
			spare.prewarm(table[id])
			if mode == "both" and world.has_method(&"prewarm"):
				world.call(&"prewarm", table[id])
	print("FU prewarm(%s) took %.0f ms" % [mode, (Time.get_ticks_usec() - t_all) / 1000.0])
	await get_tree().process_frame
	if args.has("--rig"):
		_rig_flow(view, table)
		get_tree().quit()
		return
	var sum_v := 0.0
	var sum_w := 0.0
	var worst := 0.0
	for id in table:
		var art: AwWeaponVisual = table[id]
		if not art.has_model():
			continue
		var t0 := Time.get_ticks_usec()
		if OS.get_cmdline_user_args().has("--stages"):
			var head := view._equip_head(art, true)
			var line := "head %.1f" % ((Time.get_ticks_usec() - t0) / 1000.0)
			if head.ok and not view._reused:
				for stage in view.EQUIP_STAGES:
					var ts := Time.get_ticks_usec()
					view._equip_stage(view._art, stage)
					line += " s%d %.1f" % [stage, (Time.get_ticks_usec() - ts) / 1000.0]
			print("FUS %s %s" % [id, line])
		else:
			view.equip(art)
		var t1 := Time.get_ticks_usec()
		world.equip(art)
		var t2 := Time.get_ticks_usec()
		await get_tree().process_frame
		var v := (t1 - t0) / 1000.0
		var w := (t2 - t1) / 1000.0
		sum_v += v
		sum_w += w
		worst = maxf(worst, v + w)
		print("FU %s view %.1f world %.1f ms" % [id, v, w])
	print("FU total view %.0f world %.0f ms, worst weapon %.1f ms" % [sum_v, sum_w, worst])
	get_tree().quit()


## The rig's order for a switch: equip, then the fitting; a first pass builds each weapon, a second pass finds it kept (up to `equip_cache_limit`).
func _rig_flow(view: AwViewModel, table: Dictionary) -> void:
	view.equip_cache_limit = 64
	var ids: Array = []
	for id in table:
		if (table[id] as AwWeaponVisual).has_model():
			ids.append(id)
	for pass_no in 2:
		var sum := 0.0
		var eq := 0.0
		var worst := 0.0
		for id in ids:
			var t0 := Time.get_ticks_usec()
			view.equip(table[id])
			var t_eq := Time.get_ticks_usec()
			view.set_fitting(GSWeaponFitting.new())
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			eq += (t_eq - t0) / 1000.0
			sum += ms
			worst = maxf(worst, ms)
		print("FU rig pass %d: total %.0f ms (equip %.0f) worst %.1f ms over %d weapons" % [pass_no, sum, eq, worst, ids.size()])
