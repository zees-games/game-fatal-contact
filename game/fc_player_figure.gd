@tool
extends "fc_player_build.gd"

## Tells the person how this player moves, and advances its clip. Client side. [b]From the drawn state[/b], the same one the body is placed from, so the stride matches the ground covered this frame.
## The weapon kind picks the arms: a gun, a melee weapon (a swing plays the slash over the legs), or empty hands.
func _animate_figure(drawn: GSFpsState, delta: float) -> void:
	if figure == null or body_mesh == null or not body_mesh.visible:
		return

	var v := drawn.velocity
	# One dictionary per player, rewritten in place: a fresh one per body per frame was 32 dictionaries a frame.
	var motion := _figure_motion
	motion["on_floor"] = drawn.mode == GSFpsState.Mode.GROUND
	motion["vertical"] = v.y
	motion["crouched"] = drawn.crouch_fraction > 0.5
	# The figure lerps its own crouch amount toward this (render side only), so a remote's crouch and slide ease in and out.
	motion["crouch"] = drawn.crouch_fraction
	motion["sliding"] = _drawn_sliding(drawn)
	motion["swimming"] = drawn.mode == swim.mode_id
	motion["climbing"] = drawn.mode == ladder.mode_id
	motion["alive"] = is_alive()
	motion["wall_running"] = drawn.is_wall_running()
	motion["velocity"] = v
	motion["wall"] = Plane(drawn.wall_normal, drawn.position - drawn.wall_normal * (controller.tunables.radius if controller != null else 0.35)) if drawn.wall_normal != Vector3.ZERO else Plane()
	# The view's pitch: the upper body, the arms and the gun follow it, so anybody watching
	# reads where this player is aiming.
	motion["aim"] = deg_to_rad(drawn.pitch)
	figure.set_motion(motion)

	var held_def: GSWeaponDef = arsenal.current_def() if arsenal != null else null
	var id := mirror_weapon if mirrored else (held_def.id if held_def != null else &"")
	# The hold follows the weapon: looked up (catalogue, slot tests) and set only when the weapon changes.
	if id != _figure_hold_id or _figure_hold_kind < 0:
		var def := weapon_catalogue().get_def(id) if id != &"" else null
		var picked := GSHumanoidFigure.Hold.NONE
		if def != null:
			picked = GSHumanoidFigure.Hold.MELEE if def.slot == AwWeaponIds.SLOT_MELEE else (
				GSHumanoidFigure.Hold.NONE if def.slot == AwWeaponIds.thrown_slot() else GSHumanoidFigure.Hold.GUN)
		_figure_hold_id = id
		_figure_hold_kind = picked
	var kind: int = _figure_hold_kind
	figure.set_hold(kind)
	# A blade or empty hands pump the free arm in a sprint: the figure reads the flag only when it is given.
	if kind != GSHumanoidFigure.Hold.GUN:
		motion["sprinting"] = drawn.sprinting
	else:
		motion.erase("sprinting")

	var seq := mirror_fire_seq if mirrored else (weapons.fire_seq % AwWeaponNet.FIRE_SEQ_WRAP if weapons != null else 0)
	if AwWeaponNet.uses_between(_figure_fire_seq, seq) > 0 and kind == GSHumanoidFigure.Hold.MELEE:
		figure.swing()
	_figure_fire_seq = seq

	_animate_windup()
	figure.animate(Vector2(v.x, v.z).length(), delta)


## The knife throw's wind-up on the figure and the view model, and the release when it ends with the knife away
## from the hand (a throw), not on a cancel (a death or a switch leaves it in hand or the figure's own reset).
func _animate_windup() -> void:
	figure.set_throw_charge(windup)
	var hands := weapons.view_model() as AwViewModel if weapons != null else null
	if hands != null:
		hands.on_windup(windup)
	if _windup_was >= 0.0 and windup < 0.0 and is_alive():
		figure.throw_release()
		# The owner's knife leaves on the server, so no throw outcome reaches the hands; the release plays from here.
		if hands != null and hands.has_method(&"on_throw"):
			hands.call(&"on_throw")
	_windup_was = windup


## Moves the camera from the eye to behind it, and draws the body where the eye is.
##
## [b]Swept from the eye, not set.[/b] dot-core's [GSCameraProbe] pulls the camera in ahead
## of a wall it is swinging toward and eases it back out; a camera simply placed 2.6 m back
## spends every corner inside the corner (the play test's death camera was exactly that).
## The body is placed on the drawn feet every frame, not left on this node: this node is
## moved by the tick, and a body drawn at the tick under a camera drawn per frame shakes.
func _place_third_person(drawn: GSFpsState, delta: float) -> void:
	if _tp_probe == null:
		_tp_probe = GSCameraProbe.new(camera.get_world_3d(), third_person_mask)
	_tp_probe.collision_mask = third_person_mask
	var pivot := view.global_position
	var wanted := pivot + camera.global_basis * THIRD_PERSON_OFFSET
	camera.global_position = _tp_probe.resolve(pivot, wanted, delta)

	if body_mesh != null:
		body_mesh.global_position = drawn.position
		_pose_body(drawn, drawn.yaw, delta)


## Whether the body is drawn sliding: the replicated slide timer (net_flags), for bots, humans and remote copies alike.
func _drawn_sliding(drawn: GSFpsState) -> bool:
	return (drawn.move_flags() & GSFpsState.Move.SLIDE) != 0 and drawn.mode == GSFpsState.Mode.GROUND
