@tool
## The tag over a remote player's head: when it shows, where it hangs and what it is told.
extends "fc_player_ammo.gd"

## Builds a tag and frees it, so the loading screen's warm-up compiles the bar's shader before the first hit.
static func warm_health_tag() -> void:
	GSHealthTag.new().free()

## What the tag draws this frame as [bar, named, opacity]: nothing for a dead body, a replay camera or a hidden mesh,
## the player's and the server's rules for a team-mate, the server's modes for an enemy.
func _tag_shown(camera_now: Camera3D, friend: bool, delta: float) -> Array:
	# A replay camera shows a past moment: the live world's tags would hang over it, and a body
	# the replay hides (the killer's own, at the lens) has no head to float over.
	var show := health.alive and health.max_health > 0.0 and not FcKillPov.is_replay_camera(camera_now)
	show = show and (body_mesh == null or body_mesh.is_visible_in_tree())
	if not show:
		return [false, false, 1.0]
	var hurt := _hurt_age < HEALTH_TAG_SEC
	if friend:
		return [
			TagRules.shows(TagRules.client_bars, TagRules.server_bars, true, false, hurt),
			TagRules.shows(TagRules.client_names, TagRules.server_names, true, false, false) and TagRules.show_team_names,
			1.0,
		]
	# An enemy: the server's own modes (never / on hover / always) inside the ceilings of the masks. The cursor ray
	# runs only when a mode is "hover"; the reveal then lingers and fades with the age since the cursor left.
	var hover_mode := TagRules.enemy_bar_mode == 1 or TagRules.enemy_name_mode == 1
	if hover_mode and _under_cursor(camera_now):
		_hover_age = 0.0
	elif hover_mode:
		_hover_age += delta
	var linger := TagRules.hover_opacity(_hover_age) if hover_mode else 0.0
	var hovered := linger > 0.0
	var bar := TagRules.enemy_shows(TagRules.enemy_bar_mode, hovered) \
		and TagRules.shows(TagRules.client_bars, TagRules.server_bars, false, true, true)
	var named := TagRules.enemy_shows(TagRules.enemy_name_mode, hovered) \
		and TagRules.shows(TagRules.client_names, TagRules.server_names, false, true, true)
	var steady := (bar and TagRules.enemy_bar_mode >= 2) or (named and TagRules.enemy_name_mode >= 2)
	return [bar, named, 1.0 if steady else linger]


## The tag over a remote player's head: their name and a health bar, each drawn when the player's setting and
## the server's rule both allow it (see [code]fc_name_tag_rules.gd[/code]), facing the camera.
func _present_health_tag(delta: float) -> void:
	if health == null:
		return

	var now := health.health
	if _last_health >= 0.0 and now < _last_health - 0.01:
		_hurt_age = 0.0
	_last_health = now
	_hurt_age += delta

	var camera_now := get_viewport().get_camera_3d()
	var friend := TagRules.is_teammate(player_id, team)
	var shown := _tag_shown(camera_now, friend, delta)
	var bar: bool = shown[0]
	var named: bool = shown[1]
	var opacity: float = shown[2]
	if (bar or named) and camera_now != null and TagRules.fade_end > 0.0:
		opacity *= TagRules.distance_opacity(camera_now.global_position.distance_to(global_position))
	if opacity <= 0.003:
		bar = false
		named = false
	if not (bar or named):
		if _health_tag != null:
			_health_tag.visible = false
		_tag_told = false
		return

	if _health_tag == null:
		_health_tag = GSHealthTag.new()
		add_child(_health_tag)

	# Over the body as drawn, which an offline bot's is between ticks (`interpolate_body`).
	var over := body_mesh.global_position if body_mesh != null else global_position
	var tag_at := over + Vector3(0.0, TagRules.tag_height + (TagRules.team_offset_y if friend else 0.0), 0.0)
	_tag_draw_scale = TagRules.distance_scale(TagRules.tag_scale, camera_now.global_position.distance_to(tag_at) if camera_now != null else 0.0)
	_place_health_tag(tag_at, camera_now)
	var tone := TagRules.bar_tone(friend, team) if TagRules.bar_colour_mode == &"team" else Color(0, 0, 0, 0)
	var frac := now / health.max_health
	# Told again only when something it draws changed or its bar is still easing: the update writes four shader
	# parameters and the label every call, which is the same picture frame after frame for a settled tag.
	var tag_scale := _tag_draw_scale
	var settled := (
		_tag_told and frac == _tag_frac and bar == _tag_bar and named == _tag_named and friend == _tag_friend
		and tag_scale == _tag_scale and opacity == _tag_opacity and tone == _tag_tone and display_name == _tag_name
		and _health_tag.shown_fraction == clampf(frac, 0.0, 1.0) and _health_tag.trail_fraction == _health_tag.shown_fraction
		and _health_tag.visible and _name_ink_is_set(friend, opacity)
	)
	if settled:
		return
	# Older gs-ui builds (the shell's) have no configure: the classic bar stays.
	if _health_tag.has_method(&"configure"):
		_health_tag.configure(TagRules.team_bar_width, TagRules.team_bar_height, TagRules.team_bar_style == 1)
	_health_tag.update(frac, bar, named, display_name, friend, delta, tone, _tag_draw_scale, opacity)
	_ink_enemy_name(friend, named, opacity)
	_tag_told = true
	_tag_frac = frac
	_tag_bar = bar
	_tag_named = named
	_tag_friend = friend
	_tag_tone = tone
	_tag_scale = tag_scale
	_tag_opacity = opacity
	_tag_name = display_name


## The name label inside the health tag (GSHealthTag builds it as "Name"), or null.
func _name_label() -> Label3D:
	return _health_tag.get_node_or_null("Name") as Label3D if _health_tag != null else null


## An enemy's name is drawn red (their side's colour with more than two sides) so friend and enemy are told apart at a glance.
func _ink_enemy_name(friend: bool, named: bool, opacity: float) -> void:
	var label := _name_label()
	if friend or not named or label == null:
		return
	label.modulate = TagRules.enemy_name_ink(team, opacity)


## False when an enemy's name is not yet in its red ink, so the settled shortcut does not skip the repaint.
func _name_ink_is_set(friend: bool, opacity: float) -> bool:
	var label := _name_label()
	return friend or label == null or not label.visible or label.modulate == TagRules.enemy_name_ink(team, opacity)


## The tag at [param at], turned to [param camera_now] as [method GSHealthTag.face] turns it, in one transform write: a position
## then a look_at was three (position, transform, scale), each carried down to the bar and the label. Nothing is written when
## the tag is where it was left and the camera has not moved, which is the same picture.
func _place_health_tag(at: Vector3, camera_now: Camera3D) -> void:
	if camera_now == null or not _health_tag.is_inside_tree():
		_health_tag.global_position = at
		_tag_placed = false
		return
	var eye := camera_now.global_position
	if _tag_placed and eye == _tag_eye and at == _tag_xf.origin and _health_tag.global_transform == _tag_xf:
		return
	var to_eye := eye - at
	if to_eye.is_zero_approx():
		_health_tag.global_position = at
		_tag_placed = false
		return
	# Parallel to the screen, not turned to face the eye: facing the eye slants a tag that is off to the side or
	# above the camera (the owner's footage, "Hollow" skewed), and a tag the screen sees square cannot lean.
	var xf := Transform3D(camera_now.global_basis.orthonormalized().scaled_local(Vector3.ONE * _tag_draw_scale), at)
	_health_tag.global_transform = xf
	_tag_xf = _health_tag.global_transform
	_tag_eye = eye
	_tag_placed = true


## Whether the camera's crosshair is on this body and nothing solid is in between.
func _under_cursor(camera_now: Camera3D) -> bool:
	if camera_now == null:
		return false
	var eye := camera_now.global_position
	var forward := -camera_now.global_basis.z
	var feet := body_mesh.global_position if body_mesh != null else global_position
	if not TagRules.ray_hits_body(eye, forward, feet, FcPlayerTunables.stand_height_m(), TagRules.hover_range):
		return false
	if TagRules.occluder_mask == 0 or not is_inside_tree():
		return true
	var query := PhysicsRayQueryParameters3D.create(eye, feet + Vector3(0.0, FcPlayerTunables.stand_height_m() * 0.6, 0.0), TagRules.occluder_mask)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()
