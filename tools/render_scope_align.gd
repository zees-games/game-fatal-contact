extends SceneTree

## Where a scoped weapon's optic sits on screen at the window's size: for each scoped role the aimed frame
## (screenshots/scope_align/<role>_<W>x<H>.png) and one line of numbers (ring centre and radius, the overlay's size,
## the offset of the ring's centre from the screen's middle) in screenshots/scope_align/<W>x<H>.csv.
## tools/render_scope_align.sh runs it at several window sizes. SCOPE_ROLES=sniper,marksman,charge_rifle narrows the roles.

const FcPresentation := preload("../game/fc_presentation.gd")
const OUT_DIR := "screenshots/scope_align"

var client: Node = null


func _initialize() -> void:
	preload("../game/fc_weapon_roles.gd").ensure()
	var _scratch := FcPresentation.use_scratch_settings("render_scope_align")
	var scene: PackedScene = load("res://game/fc.tscn")
	client = scene.instantiate()
	client.set("force_offline", true)
	client.set("mouse_capture_override", true)
	root.add_child(client)
	_run.call_deferred()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	await _wait(16.0)
	var gate: Variant = client.get("gate")
	for i in 240:
		if gate == null or (gate as Object).call(&"is_open"):
			break
		await _wait(0.5)
	await _wait(14.0)
	var wanted := OS.get_environment("SCOPE_ROLES")
	var roles := wanted.split(",") if wanted != "" else PackedStringArray(["sniper", "marksman", "charge_rifle"])
	var win := root.get_visible_rect().size
	var tag := "%dx%d" % [int(win.x), int(win.y)]
	var lines := PackedStringArray(["role,window,overlay,ring_centre,ring_radius,offset_px,offset_share"])
	for role in roles:
		var id := StringName(role)
		var def: DotWeaponDef = AwWeaponCatalogue.table().get(id)
		if def == null:
			print("no def %s" % role)
			continue
		# A warmup ending respawns the player with the default loadout (the knife in hand), so hand the weapon over again
		# until it is held.
		var held: StringName = &""
		for attempt in 4:
			var me = client.get("player")
			me.health.invulnerable = true
			# The carry weight would refuse a heavy gun on top of the spawn loadout and leave the knife in hand.
			if me.arsenal.carry != null:
				me.arsenal.carry.enabled = false
			var given: DotResult = me.arsenal.give(id)
			if not given.ok:
				print("scope_align ERROR: cannot give %s: %s" % [role, given.error.message if given.error != null else "?"])
				break
			# The game pins a slot by kind, so take the one it gave.
			var slot: int = (given.value as DotWeaponSlot).def.slot
			if me.arsenal.current_slot() == slot:
				for other in range(1, me.arsenal.max_slots + 1):
					if other != slot and me.arsenal.equip(other):
						break
				await _wait(0.6)
			var _up: bool = me.arsenal.equip(slot)
			await _wait(1.0)
			me = client.get("player")
			var in_hand: DotWeaponDef = me.arsenal.current_def()
			held = in_hand.id if in_hand != null else &""
			if held == id:
				break
			print("scope_align retry %d: %s asked, %s in hand (slot %d, current %d)" % [attempt, role, held, slot, me.arsenal.current_slot()])
		if held != id:
			print("scope_align ERROR: %s asked, %s in hand" % [role, held])
			continue
		Input.action_press(&"arena_aim")
		await _wait(2.0)
		await process_frame
		await RenderingServer.frame_post_draw
		var overlay := _overlay()
		var row := "%s,%s" % [role, tag]
		if overlay != null:
			var lens: Dictionary = overlay._body_lens()
			var centre: Vector2 = lens.get("centre", Vector2(-1, -1))
			var off := centre - overlay.size * 0.5
			row += ",%s,%s,%.1f,%.1f,%.3f" % [str(overlay.size), str(centre), float(lens.get("radius", -1.0)), off.length(), off.length() / overlay.size.y]
		lines.append(row)
		var _s := root.get_viewport().get_texture().get_image().save_png("%s/%s_%s.png" % [OUT_DIR, role, tag])
		Input.action_release(&"arena_aim")
		await _wait(1.0)
	var f := FileAccess.open("%s/%s.csv" % [OUT_DIR, tag], FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("scope_align ", "\n".join(lines))
	quit(0)


func _overlay() -> AwScopeOverlay:
	var o := client.find_children("*", "AwScopeOverlay", true, false)
	return o[0] as AwScopeOverlay if not o.is_empty() else null


func _wait(sec: float) -> void:
	await create_timer(sec, true, false, true).timeout
