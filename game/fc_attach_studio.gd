extends "fc_attach_studio_state.gd"
## The attachments screen (docs/client.md, the Attachments key): the gun in hand large in its own little studio, a chip per
## mount on a leader line to its socket, the choices of the chosen mount in a column on the right and six stat bars at the
## bottom left. Moving onto a choice (mouse, keys or pad) dresses the studio's gun with it and slides the bars to what it
## would do; a press asks for it through [signal requested]. Like DotWeaponAttachMenu it changes nothing itself: the panel
## sends the request and calls [method show_fitting] with the server's answer.
## Everything but the 3D studio is drawn in two `_draw` passes: about ten nodes beside the model, nothing rebuilt per pick.

const FcAttachIcons := preload("fc_attach_icons.gd")


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	_font = ThemeDB.fallback_font
	var bold := FontVariation.new()
	bold.base_font = _font
	bold.variation_embolden = 0.8
	_font_bold = bold
	for _i in STATS.size():
		_bars_now.append(0.0)
		_bars_then.append(0.0)
		_bars_now_to.append(0.0)
		_bars_then_to.append(0.0)


func _ready() -> void:
	_port_box = SubViewportContainer.new()
	_port_box.name = "Studio"
	_port_box.stretch = true
	_port_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_port_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_port_box)
	_port = SubViewport.new()
	_port.own_world_3d = true
	_port.transparent_bg = true
	_port.msaa_3d = Viewport.MSAA_4X
	_port.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_port_box.add_child(_port)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.58, 0.66)
	env.environment.ambient_light_energy = 1.4
	env.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Metal reflects its surroundings, and a flat ambient colour gives it nothing to reflect, so the steel guns (the
	# marksman, the rifle's receiver) read dark. A soft studio sky, never drawn (the background stays clear), is what they mirror.
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.78, 0.82, 0.9)
	sky_material.sky_horizon_color = Color(0.62, 0.64, 0.68)
	sky_material.ground_horizon_color = Color(0.34, 0.35, 0.38)
	sky_material.ground_bottom_color = Color(0.16, 0.17, 0.19)
	sky_material.sun_angle_max = 0.0
	env.environment.sky = Sky.new()
	env.environment.sky.sky_material = sky_material
	env.environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_port.add_child(env)
	_pivot = Node3D.new()
	_port.add_child(_pivot)
	_camera = Camera3D.new()
	_camera.fov = 30.0
	_camera.near = 0.01
	_camera.far = 50.0
	_port.add_child(_camera)
	# Lights ride on the camera, so spinning the gun shows it lit the same way from every side.
	for row: Array in [[Vector3(-40, -35, 0), 2.2, Color(1.0, 0.96, 0.9)], [Vector3(-10, 60, 0), 0.5, Color(0.7, 0.8, 1.0)], [Vector3(25, 160, 0), 1.1, Color(1.0, 0.85, 0.6)]]:
		var light := DirectionalLight3D.new()
		light.rotation_degrees = row[0]
		light.light_energy = row[1]
		light.light_color = row[2]
		light.shadow_enabled = false
		_camera.add_child(light)
	_camera.current = true
	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)
	_overlay.draw.connect(_draw_overlay)
	set_process(false)


## Fills the screen for [param base] (the catalogue definition, unfitted) and its [param fitting]; [param peers] are the
## guns the stat bars are measured against (every gun in the catalogue).
func open(catalogue: DotWeaponAttachments, base: DotWeaponDef, fitting: DotWeaponFitting, peers: Array[DotWeaponDef] = []) -> void:
	var same_gun := _model != null and _base != null and base != null and _base.id == base.id
	_catalogue = catalogue
	_base = base
	_peers = peers
	_choices = catalogue.choices_for(base)
	_mounts.clear()
	for m: StringName in AwAttachmentSockets.MOUNTS:
		if _choices.has(m):
			_mounts.append(m)
	for m: StringName in _choices.keys():
		if not _mounts.has(m):
			_mounts.append(m)
	_pending.clear()
	_shown = [&"", &""]
	if not same_gun:
		_build_model()
		_slot = 0
		_yaw_to = -0.45
		_yaw = _yaw_to + 0.9
		_pitch_to = -0.16
		_pitch = _pitch_to
		_user_zoom = 1.0
		_fit = 1.0
		_lift = 0.0
	_open_t = 0.0
	show_fitting(fitting)
	_pick_slot(_slot, true)
	show()
	grab_focus()
	set_process(true)


## Hides the screen; the gun stays built for the next open on the same gun.
func close() -> void:
	hide()
	set_process(false)
	_dragging = false


## Takes [param fitting] (the server's answer, or the replicated one) without rebuilding anything: the rows, chips, gun and
## bars follow it in place.
func show_fitting(fitting: DotWeaponFitting) -> void:
	_fitting = fitting
	for m: StringName in _pending.keys():
		if fitting.attachment_on(m) == _pending[m]:
			_pending.erase(m)
	_redress()
	_measure()


## Shows [param id] on [param mount] on the studio's gun and in the bars, as moving onto its row does.
func preview(mount: StringName, id: StringName) -> void:
	var at := _mounts.find(mount)
	if at < 0:
		return
	if at != _slot:
		_pick_slot(at, false)
	var row := _options().find(id)
	if row >= 0:
		_set_row(row)


## The choices of the chosen mount, "nothing" first.
func _options() -> Array[StringName]:
	_option_list.clear()
	_option_list.append(&"")
	if _slot < _mounts.size():
		for id: StringName in _choices.get(_mounts[_slot], []):
			_option_list.append(id)
	return _option_list


func _mount() -> StringName:
	return _mounts[_slot] if _slot < _mounts.size() else &""


func _pick_slot(index: int, keep_row: bool) -> void:
	if _mounts.is_empty():
		return
	index = posmod(index, _mounts.size())
	if index != _slot or not keep_row:
		_slot_t = 0.0
	_slot = index
	var on := _fitting.attachment_on(_mount()) if _fitting != null else &""
	_set_row(maxi(0, _options().find(on)))


func _set_row(row: int) -> void:
	var options := _options()
	_row = clampi(row, 0, options.size() - 1)
	var id: StringName = options[_row]
	_shown = [_mount(), id]
	_redress()
	_measure()
	_aim_camera()


## The fitting the studio shows: the real one with the row under the cursor put on.
func _shown_fitting() -> DotWeaponFitting:
	if _fitting == null:
		return null
	if _shown[0] == &"" or _fitting.attachment_on(_shown[0]) == _shown[1]:
		return _fitting
	var res := _catalogue.toggle(_base, _fitting.duplicate_fitting(), _shown[0], _shown[1])
	return res.value if res.ok else _fitting


func _build_model() -> void:
	if _model != null:
		Dress.clear(_dress)
		_model.queue_free()
		_model = null
	_dress = {}
	_art = AwWeaponArtTable.get_art(_base.id)
	if _art == null:
		return
	_model = AwModelCache.instantiate(_art.model_path)
	if _model == null:
		return
	_pivot.add_child(_model)
	var forward := _art.model_forward.normalized()
	if forward.is_equal_approx(Vector3.LEFT):
		_model.basis = Basis(Vector3.UP, PI)
	elif not forward.is_equal_approx(Vector3.RIGHT):
		_model.basis = Basis(Quaternion(forward, Vector3.RIGHT))
	_box = Transform3D(_model.basis, Vector3.ZERO) * AwModelCache.bounds(_art.model_path)
	_model.position = -_box.get_center()
	_box.position -= _box.get_center()
	AwAttachmentSockets.ensure(_model)
	_focus = Vector3.ZERO
	_focus_to = Vector3.ZERO


func _redress() -> void:
	if _model == null or _art == null:
		return
	_dress = Dress.apply(_model, _shown_fitting(), _art.model_forward, _dress)


## Leans the camera toward the chosen mount's socket and closes in a little.
func _aim_camera() -> void:
	var socket := _socket(_mount())
	_focus_to = Vector3.ZERO
	_zoom_to = _user_zoom
	if socket != null and _pivot.is_inside_tree():
		_focus_to = _pivot.global_transform.affine_inverse() * socket.global_position * 0.3
		_zoom_to = _user_zoom * 0.88


func _socket(mount: StringName) -> Node3D:
	if _model == null or mount == &"":
		return null
	return _model.find_child(String(AwAttachmentArt.socket_name(mount)), true, false) as Node3D


# --- stats -------------------------------------------------------------------------------------------------------------

## The six bar values (0..1) of [param def] against the catalogue.
func _scores(def: DotWeaponDef) -> Array[float]:
	var out: Array[float] = []
	for row: Array in STATS:
		out.append(_score(row[1], def))
	return out


func _raw(stat: StringName, def: DotWeaponDef) -> float:
	var t: Object = def.tuning
	match stat:
		&"damage":
			return _num(t, &"damage") * maxf(1.0, _num(t, &"pellets"))
		&"accuracy":
			return _num(t, &"spread")
		&"recoil":
			return _num(t, &"recoil_pitch") + _num(t, &"recoil_yaw")
		&"range":
			return maxf(_num(t, &"falloff_start"), _num(t, &"max_range"))
		&"handling":
			return _num(t, &"spread_moving") + _num(def, &"reload_ticks") / 64.0
		&"ammo":
			return _num(def, &"magazine")
	return 0.0


static func _num(o: Object, field: StringName) -> float:
	if o == null:
		return 0.0
	var v: Variant = o.get(field)
	return float(v) if v is float or v is int else 0.0


func _score(stat: StringName, def: DotWeaponDef) -> float:
	var lo := INF
	var hi := -INF
	for peer in _peers:
		if peer == null or peer.tuning == null:
			continue
		var v := _raw(stat, peer)
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var v := _raw(stat, def)
	lo = minf(lo, v)
	hi = maxf(hi, v)
	if hi - lo < 0.000001:
		return 0.6
	var f := clampf((v - lo) / (hi - lo), 0.0, 1.0)
	if stat in [&"accuracy", &"recoil", &"handling"]:
		# Less is better and zero is the best there is: measured from zero, so a cut on the best gun still shows.
		f = 1.0 - clampf(v / hi, 0.0, 1.0) if hi > 0.0 else 1.0
		f = pow(f, 2.0)
	# Range and magazine run over two orders of magnitude; a square root keeps a pistol's bar visible beside an LMG's.
	if stat in [&"ammo", &"range", &"damage"]:
		f = sqrt(f)
	return 0.08 + 0.92 * f


func _measure() -> void:
	if _catalogue == null or _base == null or _fitting == null:
		return
	var now := _catalogue.apply(_base, _fitting)
	var then := _catalogue.apply(_base, _shown_fitting())
	if not now.ok or not then.ok:
		return
	_bars_now_to = _scores(now.value)
	_bars_then_to = _scores(then.value)


## "Vertical recoil −25%" lines for what the shown row changes against the fitting, best first.
func _delta_lines() -> Array:
	var out: Array = []
	if _catalogue == null or _shown_fitting() == _fitting:
		return out
	var now := _catalogue.apply(_base, _fitting)
	var then := _catalogue.apply(_base, _shown_fitting())
	if not now.ok or not then.ok:
		return out
	var delta := DotWeaponAttachments.stat_delta(now.value, then.value)
	for field: String in delta.keys():
		if field.begins_with(DotWeaponAttachment.PARAMS_PREFIX):
			continue
		var pair: Array = delta[field]
		var a := float(pair[0])
		var b := float(pair[1])
		var look: Array = FIELDS.get(field, [field.capitalize(), false])
		var text := "%+d%%" % roundi((b - a) / absf(a) * 100.0) if absf(a) > 0.000001 else "%+.2f" % (b - a)
		var better := (b < a) == bool(look[1])
		out.append([String(look[0]), text, better])
	out.sort_custom(func(x: Array, y: Array) -> bool: return x[2] and not y[2])
	return out


func _name_of(id: StringName) -> String:
	if id == &"":
		return "None"
	var att := _catalogue.get_attachment(id) if _catalogue != null else null
	return att.display_name if att != null and att.display_name != "" else String(id).capitalize()


# --- frame -------------------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_time += delta
	var k := 1.0 - exp(-delta * 3.0 / maxf(0.01, ease_seconds))
	var slow := 1.0 - exp(-delta * 1.5 / maxf(0.01, ease_seconds))
	_open_t = move_toward(_open_t, 1.0, delta / 0.28)
	_slot_t = move_toward(_slot_t, 1.0, delta / 0.22)
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > 0.2:
		_yaw_to += stick.x * spin_speed * delta
		_pitch_to = clampf(_pitch_to + stick.y * spin_speed * 0.5 * delta, -0.9, 0.9)
	_yaw = lerpf(_yaw, _yaw_to, slow)
	_pitch = lerpf(_pitch, _pitch_to, slow)
	_zoom = lerpf(_zoom, _zoom_to, slow)
	_focus = _focus.lerp(_focus_to, slow)
	for i in STATS.size():
		_bars_now[i] = lerpf(_bars_now[i], _bars_now_to[i], k)
		_bars_then[i] = lerpf(_bars_then[i], _bars_then_to[i], k)
	var rows := _options().size()
	_row_glow.resize(rows)
	for i in rows:
		var want := 1.0 if i == _row else (0.5 if i == _hover_row else 0.0)
		_row_glow[i] = lerpf(_row_glow[i], want, k)
	_place_camera()
	_layout(k)
	_overlay.queue_redraw()
	queue_redraw()


func _ui() -> float:
	return size.y / 900.0


## A font size at this scale, never below one pixel: a tiny window (a headless run) would
## otherwise ask the text server for a zero size, which is an engine error.
func _px(points: float, u: float) -> int:
	return maxi(1, roundi(points * u))


## The gun's middle on screen, left of centre so the right column has room.
func _place_camera() -> void:
	if _camera == null:
		return
	var length := maxf(0.05, maxf(_box.size.x, _box.size.y * 1.6))
	var aspect := size.x / maxf(1.0, size.y)
	var half_h := tan(deg_to_rad(_camera.fov) * 0.5) * aspect
	var dist := length * 0.5 / (half_h * 0.4) * _zoom * _fit
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	var bob := Vector3(0.0, sin(_time * 0.9) * length * 0.004, 0.0)
	_camera.transform = Transform3D(basis, _focus + bob + basis * Vector3(0, 0, dist))
	_camera.h_offset = dist * half_h * 0.26
	_camera.v_offset = -dist * tan(deg_to_rad(_camera.fov) * 0.5) * 0.06 + _lift


func _project(p: Vector3) -> Vector2:
	if _camera == null or not _camera.is_inside_tree() or _camera.is_position_behind(p):
		return Vector2(-1000, -1000)
	return _camera.unproject_position(p) * (size / Vector2(maxf(1, _port.size.x), maxf(1, _port.size.y)))


## Eases the framing so the gun's projected box ([param top] to [param bottom], screen pixels) sits between the chip
## rows in use: a tall gun (a bipod, a long magazine) is drawn smaller and moved, not covered by a row of chips.
func _fit_rows(k: float, top: float, bottom: float, chip: Vector2, has_top: bool, has_bottom: bool) -> void:
	var u := _ui()
	var low := 128.0 * u + chip.y + 64.0 * u if has_top else 96.0 * u
	var high := size.y * 0.62 - chip.y - 56.0 * u if has_bottom else size.y * 0.62
	var span := bottom - top
	if span <= 1.0 or high - low <= 1.0 or _camera == null:
		return
	# Further away by the share the box overflows the room; back toward the plain framing when it has room to spare.
	var fit_to := maxf(1.0, _fit * span / (high - low)) if span > high - low or _fit > 1.0 else 1.0
	_fit = lerpf(_fit, fit_to, k)
	# The box's middle into the room's band; v_offset up moves the picture down, one pixel being this many world units.
	var middle := (top + bottom) * 0.5
	var want := clampf(middle, low + span * 0.5, high - span * 0.5) if span < high - low else (low + high) * 0.5
	var dist := _camera.position.distance_to(_focus)
	var per_px := 2.0 * dist * tan(deg_to_rad(_camera.fov) * 0.5) / maxf(1.0, size.y)
	_lift += (want - middle) * per_px * k


## Where the chips and sockets are this frame.
func _layout(k: float) -> void:
	var u := _ui()
	var top := INF
	var bottom := -INF
	for i in 8:
		var p := _project(_pivot.global_transform * _box.get_endpoint(i))
		top = minf(top, p.y)
		bottom = maxf(bottom, p.y)
	var chip := Vector2(184, 52) * u
	var right_edge := _column_rect().position.x - 24.0 * u
	_lane_top.clear()
	_lane_low.clear()
	_sockets.clear()
	for m in _mounts:
		var socket := _socket(m)
		if socket == null:
			continue
		_sockets[m] = _project(socket.global_position)
		(_lane_top if TOP_LANE.has(m) else _lane_low).append(m)
	_fit_rows(k, top, bottom, chip, not _lane_top.is_empty(), not _lane_low.is_empty())
	for up in 2:
		var lane: Array = _lane_top if up == 0 else _lane_low
		lane.sort_custom(func(a: StringName, b: StringName) -> bool: return _sockets[a].x < _sockets[b].x)
		var y := clampf(top - 64.0 * u - chip.y, 128.0 * u, size.y * 0.42) if up == 0 else clampf(bottom + 56.0 * u, size.y * 0.36, size.y * 0.62 - chip.y)
		var x := 40.0 * u
		_placed.clear()
		var placed := _placed
		for m: StringName in lane:
			var want := clampf(_sockets[m].x - chip.x * 0.5, x, right_edge - chip.x)
			placed.append(want)
			x = want + chip.x + 14.0 * u
		# Pushed off the right edge: walk back left.
		var limit := right_edge - chip.x
		for i in range(placed.size() - 1, -1, -1):
			placed[i] = minf(placed[i], limit)
			limit = placed[i] - chip.x - 14.0 * u
		for i in lane.size():
			var target := Rect2(Vector2(placed[i], y), chip)
			var was: Rect2 = _chips.get(lane[i], target)
			_chips[lane[i]] = Rect2(was.position.lerp(target.position, k), chip)
	for m: StringName in _chips.keys():
		if not _sockets.has(m):
			_chips.erase(m)
	# A mount whose gun model has no socket still gets a chip, in a row at the top.
	var free_x := 40.0 * u
	for m in _mounts:
		if not _chips.has(m):
			_chips[m] = Rect2(Vector2(free_x, 128.0 * u), chip)
			free_x += chip.x + 14.0 * u


func _column_rect() -> Rect2:
	var u := _ui()
	return Rect2(Vector2(size.x - 548.0 * u, 112.0 * u), Vector2(500.0 * u, size.y * 0.69 - 112.0 * u))


func _row_rect(i: int) -> Rect2:
	var u := _ui()
	var col := _column_rect()
	return Rect2(col.position + Vector2(0, 74.0 * u + i * 60.0 * u), Vector2(col.size.x, 52.0 * u))


func _stats_rect() -> Rect2:
	var u := _ui()
	return Rect2(Vector2(40.0 * u, size.y * 0.635), Vector2(440.0 * u, size.y * 0.835 - size.y * 0.635))


# --- drawing -----------------------------------------------------------------------------------------------------------

func _draw() -> void:
	# The backdrop: dark over the game, falling away over the bottom so the health and ammo stay readable.
	var a := _open_t
	var w := size.x
	var h := size.y
	var top := Color(0.03, 0.035, 0.05, 0.97 * a)
	var mid := Color(0.05, 0.06, 0.08, 0.95 * a)
	var low := Color(0.05, 0.06, 0.08, 0.5 * a)
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, h * 0.8), Vector2(0, h * 0.8)]), PackedColorArray([top, top, mid, mid]))
	draw_polygon(PackedVector2Array([Vector2(0, h * 0.8), Vector2(w, h * 0.8), Vector2(w, h), Vector2(0, h)]), PackedColorArray([mid, mid, low, low]))
	# A soft pool of light behind the gun.
	var at := Vector2(w * 0.37, h * 0.42)
	for i in 10:
		draw_circle(at, h * (0.46 - i * 0.04), Color(0.3, 0.36, 0.46, 0.022 * a))
	# A floor line.
	var floor_y := h * 0.6
	draw_line(Vector2(w * 0.06, floor_y), Vector2(w * 0.66, floor_y), Color(1, 1, 1, 0.05 * a), 1.0)


func _draw_overlay() -> void:
	if _base == null:
		return
	var u := _ui()
	var a := _open_t
	var o := _overlay
	# Header.
	o.draw_string(_font_bold, Vector2(40, 52) * u, "GUNSMITH", HORIZONTAL_ALIGNMENT_LEFT, -1, _px(13, u), Color(ACCENT, a))
	var title := _base.display_name if _base.display_name != "" else String(_base.id).capitalize()
	o.draw_string(_font_bold, Vector2(40, 92) * u, title.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, _px(36, u), Color(INK, a))
	_draw_hints(o, u, a)
	# Leader lines and chips.
	for m: StringName in _chips.keys():
		_draw_chip(o, m, u, a)
	# Right column.
	_draw_column(o, u, a)
	_draw_stats(o, u, a)


func _draw_hints(o: Control, u: float, a: float) -> void:
	var hints: Array = [["LB RB", "Slot"], ["D-pad", "Choose"], ["A", "Equip"], ["R-stick", "Rotate"], ["B", "Back"]] if _pad \
		else [["Q E", "Slot"], ["↑ ↓", "Choose"], ["Enter", "Equip"], ["Drag", "Rotate"], ["Esc", "Back"]]
	var size_px := _px(14, u)
	var x := size.x - 40.0 * u
	var y := 60.0 * u
	for i in range(hints.size() - 1, -1, -1):
		var label: String = hints[i][1]
		var key: String = hints[i][0]
		var lw := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
		x -= lw
		o.draw_string(_font, Vector2(x, y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, Color(DIM, a))
		var kw := _font_bold.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, _px(12, u)).x + 14.0 * u
		x -= kw + 8.0 * u
		var box := Rect2(Vector2(x, y - 17.0 * u), Vector2(kw, 23.0 * u))
		_rounded(o, box, Color(1, 1, 1, 0.1 * a), 4.0 * u)
		o.draw_string(_font_bold, Vector2(x + 7.0 * u, y - 1.0 * u), key, HORIZONTAL_ALIGNMENT_LEFT, -1, _px(12, u), Color(INK, a))
		x -= 22.0 * u


func _draw_chip(o: Control, m: StringName, u: float, a: float) -> void:
	var rect: Rect2 = _chips[m]
	var i := _mounts.find(m)
	var chosen := i == _slot
	var hot := i == _hover_chip
	if _sockets.has(m):
		var s: Vector2 = _sockets[m]
		var end := Vector2(clampf(s.x, rect.position.x + 12.0 * u, rect.end.x - 12.0 * u), rect.end.y if rect.get_center().y < s.y else rect.position.y)
		var line := Color(ACCENT if chosen else INK, (0.9 if chosen else 0.35) * a)
		o.draw_line(s, end, line, (2.0 if chosen else 1.2) * u, true)
		o.draw_circle(s, 4.0 * u, line)
		if chosen:
			var pulse := 0.5 + 0.5 * sin(_time * 4.0)
			o.draw_arc(s, (8.0 + pulse * 4.0) * u, 0.0, TAU, 32, Color(ACCENT, (0.7 - pulse * 0.5) * a), 1.5 * u, true)
	var fill := PLATE_HI if chosen or hot else PLATE
	_rounded(o, rect, Color(fill, fill.a * a), 6.0 * u)
	if chosen:
		_rounded_outline(o, rect, Color(ACCENT, a), 6.0 * u, 2.0 * u)
	var on := _fitting.attachment_on(m) if _fitting != null else &""
	var head := "%d  %s" % [i + 1, String(MOUNT_NAMES.get(m, String(m).capitalize())).to_upper()]
	o.draw_string(_font_bold, rect.position + Vector2(12, 20) * u, head, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 20.0 * u, _px(11, u), Color(ACCENT if chosen else DIM, a))
	var label := _name_of(on) if on != &"" else "Empty"
	if on != &"" and FcAttachIcons.has(on):
		FcAttachIcons.draw(o, on, Rect2(rect.end - Vector2(40.0, 36.0) * u, Vector2(30.0, 28.0) * u), Color(INK, a))
	o.draw_string(_font_bold if on != &"" else _font, rect.position + Vector2(12, 42) * u, label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 20.0 * u, _px(16, u), Color(INK if on != &"" else FAINT, a))


func _draw_column(o: Control, u: float, a: float) -> void:
	var col := _column_rect()
	var m := _mount()
	var slide := (1.0 - _ease_out(_slot_t)) * 24.0 * u
	var fade := a * _ease_out(_slot_t)
	o.draw_string(_font_bold, col.position + Vector2(slide, 22.0 * u), String(MOUNT_NAMES.get(m, String(m).capitalize())).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, _px(26, u), Color(INK, fade))
	o.draw_string(_font, col.position + Vector2(0, 22.0 * u), "%d / %d" % [_slot + 1, _mounts.size()], HORIZONTAL_ALIGNMENT_RIGHT, col.size.x, _px(14, u), Color(DIM, a))
	# Slot dots: where this mount is among the gun's.
	for i in _mounts.size():
		var c := Vector2(col.position.x + 5.0 * u + i * 16.0 * u, col.position.y + 46.0 * u)
		o.draw_circle(c, (4.0 if i == _slot else 3.0) * u, Color(ACCENT if i == _slot else FAINT, a))
	var options := _options()
	var on := _fitting.attachment_on(m) if _fitting != null else &""
	for i in options.size():
		var rect := _row_rect(i)
		rect.position.x += slide * (1.0 + i * 0.25)
		var glow: float = _row_glow[i] if i < _row_glow.size() else 0.0
		var equipped := options[i] == on
		_rounded(o, rect, Color(PLATE.lerp(PLATE_HI, glow), fade * (0.85 + glow * 0.15)), 6.0 * u)
		if i == _row:
			o.draw_rect(Rect2(rect.position + Vector2(0, 8.0 * u), Vector2(4.0 * u, rect.size.y - 16.0 * u)), Color(ACCENT, fade))
			_rounded_outline(o, rect, Color(1, 1, 1, 0.18 * fade), 6.0 * u, 1.0 * u)
		var label := _name_of(options[i])
		var text_x := 20.0 * u
		if FcAttachIcons.has(options[i]):
			var lit := i == _row or glow > 0.3
			FcAttachIcons.draw(o, options[i], Rect2(rect.position + Vector2(16.0, 6.0) * u, Vector2(44.0 * u, rect.size.y - 12.0 * u)), Color(INK if lit else DIM, fade))
			text_x = 70.0 * u
		o.draw_string(_font_bold if i == _row else _font, rect.position + Vector2(text_x, rect.size.y * 0.5 + 7.0 * u), label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 150.0 * u - (text_x - 20.0 * u), _px(19, u), Color(INK if i == _row or glow > 0.3 else DIM, fade))
		var tag := ""
		var tag_ink := ACCENT
		if _pending.get(m, null) == options[i]:
			tag = "EQUIPPING"
			tag_ink = DIM
		elif equipped and options[i] != &"":
			tag = "EQUIPPED"
		elif equipped:
			tag = "CURRENT"
			tag_ink = FAINT
		if tag != "":
			var tw := _font_bold.get_string_size(tag, HORIZONTAL_ALIGNMENT_LEFT, -1, _px(11, u)).x + 16.0 * u
			var box := Rect2(Vector2(rect.end.x - tw - 14.0 * u, rect.get_center().y - 11.0 * u), Vector2(tw, 22.0 * u))
			_rounded_outline(o, box, Color(tag_ink, fade), 4.0 * u, 1.2 * u)
			o.draw_string(_font_bold, box.position + Vector2(8.0 * u, 15.5 * u), tag, HORIZONTAL_ALIGNMENT_LEFT, -1, _px(11, u), Color(tag_ink, fade))
		var zoom := float(AwAttachmentArt.of(options[i]).get("zoom", 0.0))
		if zoom > 0.0:
			var zt := _zoom_text(zoom)
			var right := rect.end.x - (130.0 if tag != "" else 18.0) * u
			o.draw_string(_font, Vector2(right - 60.0 * u, rect.get_center().y + 6.0 * u), zt, HORIZONTAL_ALIGNMENT_RIGHT, 60.0 * u, _px(14, u), Color(DIM, fade))
	# What the shown row does, under the rows.
	var y := _row_rect(options.size()).position.y + 14.0 * u
	var lines := _delta_lines()
	var shown_zoom := float(AwAttachmentArt.of(_shown[1]).get("zoom", 0.0)) if _shown[1] != &"" else 0.0
	if shown_zoom > 0.0 and _shown[0] == m:
		lines.push_front(["Aim zoom", _zoom_text(shown_zoom), true])
	if lines.is_empty() and _shown[1] != on:
		lines = [["Removes the attachment", "", true]] if _shown[1] == &"" else [["No stat change", "", true]]
	for row: Array in lines:
		if y > col.end.y:
			break
		var ink: Color = GOOD if row[2] else BAD
		o.draw_string(_font_bold, Vector2(col.position.x + 4.0 * u, y), String(row[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, _px(15, u), Color(ink, fade))
		o.draw_string(_font, Vector2(col.position.x + 64.0 * u, y), String(row[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, _px(15, u), Color(DIM if row[1] != "" else ink, fade))
		y += 24.0 * u


func _draw_stats(o: Control, u: float, a: float) -> void:
	var r := _stats_rect()
	_rounded(o, r, Color(PLATE, PLATE.a * a), 8.0 * u)
	o.draw_string(_font_bold, r.position + Vector2(18, 28) * u, "STATS", HORIZONTAL_ALIGNMENT_LEFT, -1, _px(12, u), Color(DIM, a))
	var row_h := (r.size.y - 44.0 * u) / STATS.size()
	var label_w := 132.0 * u
	var bar_w := r.size.x - label_w - 36.0 * u
	for i in STATS.size():
		var y := r.position.y + 44.0 * u + i * row_h
		o.draw_string(_font, Vector2(r.position.x + 18.0 * u, y + row_h * 0.5 + 5.0 * u), String(STATS[i][0]), HORIZONTAL_ALIGNMENT_LEFT, label_w, _px(14, u), Color(INK, a))
		var bar := Rect2(Vector2(r.position.x + 18.0 * u + label_w, y + row_h * 0.5 - 3.0 * u), Vector2(bar_w, 6.0 * u))
		o.draw_rect(bar, Color(1, 1, 1, 0.08 * a))
		var now := _bars_now[i]
		var then := _bars_then[i]
		var base := minf(now, then)
		o.draw_rect(Rect2(bar.position, Vector2(bar.size.x * base, bar.size.y)), Color(INK, 0.85 * a))
		if absf(then - now) > 0.002:
			var from := bar.position.x + bar.size.x * base
			var span := bar.size.x * absf(then - now)
			o.draw_rect(Rect2(Vector2(from, bar.position.y), Vector2(span, bar.size.y)), Color(GOOD if then > now else BAD, a))
		# Ticks every quarter.
		for q in [0.25, 0.5, 0.75]:
			o.draw_line(Vector2(bar.position.x + bar.size.x * q, bar.position.y), Vector2(bar.position.x + bar.size.x * q, bar.end.y), Color(0, 0, 0, 0.5 * a), 1.0)


func _rounded(o: Control, rect: Rect2, color: Color, radius: float) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(int(radius))
	box.anti_aliasing = true
	o.draw_style_box(box, rect)


func _rounded_outline(o: Control, rect: Rect2, color: Color, radius: float, width: float) -> void:
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.border_color = color
	box.set_border_width_all(maxi(1, roundi(width)))
	box.set_corner_radius_all(int(radius))
	box.anti_aliasing = true
	o.draw_style_box(box, rect)


## "6x" for a 6x scope, "1.3x" for a holographic sight.
static func _zoom_text(zoom: float) -> String:
	var times := 1.0 / zoom
	return "%dx" % roundi(times) if absf(times - roundf(times)) < 0.15 else "%.1fx" % times


static func _ease_out(t: float) -> float:
	return 1.0 - pow(1.0 - clampf(t, 0.0, 1.0), 3.0)


# --- input -------------------------------------------------------------------------------------------------------------

func _equip() -> void:
	var options := _options()
	var id: StringName = options[_row]
	var m := _mount()
	if _fitting != null and _fitting.attachment_on(m) == id:
		return
	_pending[m] = id
	requested.emit(m, id)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_pad = false
		var at := (event as InputEventMouseMotion).position
		if _dragging:
			var rel := (event as InputEventMouseMotion).relative
			_drag_moved += rel.length()
			_yaw_to -= rel.x * 0.008
			_pitch_to = clampf(_pitch_to - rel.y * 0.006, -0.9, 0.9)
			accept_event()
			return
		_hover_row = -1
		for i in _options().size():
			if _row_rect(i).has_point(at):
				_hover_row = i
		_hover_chip = -1
		for m: StringName in _chips.keys():
			if (_chips[m] as Rect2).has_point(at):
				_hover_chip = _mounts.find(m)
		if _hover_row >= 0 and _hover_row != _row:
			_set_row(_hover_row)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _hover_row >= 0 or _hover_chip >= 0 else Control.CURSOR_DRAG
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_user_zoom = clampf(_user_zoom * 0.9, 0.45, 1.6)
			_aim_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_user_zoom = clampf(_user_zoom / 0.9, 0.45, 1.6)
			_aim_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _hover_row >= 0:
				_set_row(_hover_row)
				_equip()
			elif _hover_chip >= 0:
				_pick_slot(_hover_chip, false)
			else:
				_dragging = true
				_drag_moved = 0.0
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_dragging = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_dragging = true
		elif mb.button_index == MOUSE_BUTTON_RIGHT and not mb.pressed:
			_dragging = false
		accept_event()


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event.is_pressed() or event.is_echo() and not _is_nav(event):
		return
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		_pad = true
	elif event is InputEventKey:
		_pad = false
	var handled := true
	if event.is_action_pressed(&"ui_cancel") or (InputMap.has_action(DotWeaponAttachMenu.ACTION) and event.is_action_pressed(DotWeaponAttachMenu.ACTION)):
		closed.emit()
	elif event.is_action_pressed(&"ui_up", true):
		_set_row(posmod(_row - 1, _options().size()))
	elif event.is_action_pressed(&"ui_down", true):
		_set_row(posmod(_row + 1, _options().size()))
	elif event.is_action_pressed(&"ui_left", true) or _key(event, KEY_Q) or _button(event, JOY_BUTTON_LEFT_SHOULDER):
		_pick_slot(_slot - 1, false)
	elif event.is_action_pressed(&"ui_right", true) or _key(event, KEY_E) or _button(event, JOY_BUTTON_RIGHT_SHOULDER):
		_pick_slot(_slot + 1, false)
	elif event.is_action_pressed(&"ui_accept"):
		_equip()
	elif event is InputEventKey and (event as InputEventKey).keycode >= KEY_1 and (event as InputEventKey).keycode < KEY_1 + mini(9, _mounts.size()):
		_pick_slot((event as InputEventKey).keycode - KEY_1, false)
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _is_nav(event: InputEvent) -> bool:
	return event.is_action(&"ui_up") or event.is_action(&"ui_down")


static func _key(event: InputEvent, code: Key) -> bool:
	return event is InputEventKey and (event as InputEventKey).physical_keycode == code


static func _button(event: InputEvent, button: JoyButton) -> bool:
	return event is InputEventJoypadButton and (event as InputEventJoypadButton).button_index == button
