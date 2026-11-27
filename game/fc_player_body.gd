@tool
extends "fc_player_figure.gd"

const FcFlagCarry := preload("fc_flag_carry.gd")
const FcScopePrefs := preload("fc_scope_prefs.gd")
const FcScopeBody := preload("fc_scope_body.gd")
## How far above its origin a drawn body looks for the floor to stand on, metres ([member GSHumanoidFigure.floor_reach]).
const FIGURE_FLOOR_REACH := 0.6  # under the 0.69 m crouched hull: nothing it stands under is in reach

## Breaks this player's body apart on a death: [param rules] decides how much. Client
## side, drawing only. [param direction] is the way the killing hit travelled; the seed
## is the victim and the tick, so every client breaks the same body the same way.
func break_body(
	rules: GSPlayerBreakRules, direction: Vector3, p_seed: int, critical: bool
) -> GSPlayerBodyBreak:
	if body_mesh == null or rules == null:
		return null

	var before := GSPlayerBodyBreak.visible_meshes(body_mesh)
	var made := GSPlayerBodyBreak.break_apart(
		body_mesh, get_parent(), rules, global_position, direction, p_seed, true, critical
	)

	if made != null:
		_went_down()
		# A person's limbs are baked off its skin and its bones shrunk; the respawn mends them.
		_severed = figure != null
		for mesh in before:
			if not mesh.visible:
				_broken.append(mesh)
		if held != null and not body_mesh.visible:
			held.visible = false

	return made

## This player's body falls: a ragdoll copied from what is drawn, built in [param yard] as [param death] says.
## Client side, drawing only; the figure stays hidden until [method _mend_body] draws it on respawn. Null when the
## style hides bodies or there is no body to copy. [param gun_prop] false leaves the gun to a real dropped weapon.
func fall_body(yard: GSPlayerRagdolls, death: GSPlayerDeath, gun_prop: bool = true) -> GSPlayerRagdoll:
	if yard == null or body_mesh == null or not body_mesh.is_inside_tree():
		return null
	# Already down and hidden: copying it again would build a second ragdoll from hidden meshes.
	if _fell and not body_mesh.visible:
		return null
	# Your own body in first person has no head; the one that falls has.
	if figure != null:
		figure.hide_head = false
	# The gun leaves the body first: copied into the ragdoll it stays on end in the raised hand.
	var gun_shown := held != null and held.visible
	if gun_shown and gun_prop:
		var _dropped := yard.drop_prop(held, controller.state.velocity)
	if gun_shown:
		held.visible = false
	var made := yard.spawn(body_mesh, death, controller.state.velocity)
	_fell = made != null or not body_mesh.visible
	if _fell:
		_went_down()
	if held != null and not _fell:
		held.visible = gun_shown
	return made

func _went_down() -> void:
	_down_at_ms = Time.get_ticks_msec()
	_down_seen_dead = not is_alive()

## Puts a broken or fallen body back together once the player is alive again: after this client saw
## them dead, or after a grace in case that snapshot never came (a respawn inside one snapshot gap).
func _mend_body() -> void:
	if not is_alive():
		_down_seen_dead = true
	elif not _down_seen_dead and Time.get_ticks_msec() - _down_at_ms < DOWN_GRACE_MS:
		return
	if _severed and is_alive() and figure != null:
		_severed = false
		figure.mend()

	if _fell and is_alive() and body_mesh != null:
		_fell = false
		body_mesh.visible = true
		if held != null:
			held.visible = held_may_show()

	if _broken.is_empty() or not is_alive() or body_mesh == null:
		return

	for mesh in _broken:
		if is_instance_valid(mesh):
			mesh.visible = true

	_broken.clear()
	body_mesh.visible = true

	if held != null:
		held.visible = held_may_show()

## Whether the held gun may be drawn: a live, standing body drawn near enough, whose own skin is drawn. A gun
## shown while the figure's skin was hidden (a camera fade or a break hides the skin, not the body) hung in the air.
func held_may_show() -> bool:
	if not is_alive() or _fell or beyond_figure or FcWeaponIcons.shared.sprites:
		return false
	if body_mesh != null and not body_mesh.visible:
		return false
	# A respawned body still in its death pose (the figure keeps it while in the air) lays its hand on the floor.
	if figure != null and figure.state == GSPlayerAnimState.DEAD:
		return false
	var skin: MeshInstance3D = figure.mesh() if figure != null else null
	return skin == null or skin.visible

## The node a held weapon hangs from, by the name [AwWorldModel] asks for.
##
## [b]Duck-typed, which is the whole contract.[/b] `AwWorldModel.attach_to` takes any
## object answering `attachment(point)`, and Fatal Contact's avatar rig has a body, a head and
## a crest and no hand — so the player answers for it, with a hand placed where a figure
## this size holds a gun: chest high, right of centre, in front.
func attachment(point: StringName) -> Node3D:
	if figure != null:
		# The person's own hand, which moves with its clips.
		return figure.attachment(point)

	if point != &"right_hand" or body_mesh == null:
		return null

	if _hand == null:
		_hand = Node3D.new()
		_hand.name = "RightHand"
		_hand.position = HAND_POSITION
		body_mesh.add_child(_hand)

	return _hand

## Somebody else's gun: the one they are holding, kicking when they use it.
##
## [b]Two sources, one picture.[/b] A mirrored player is read from what the snapshot said
## ([member mirror_weapon], the counter); a player this machine simulates — an offline
## bot, or everybody on a listen server — from its own rig. Drawing the second from a
## counter as well is what keeps both on one code path.
## The optional flat held sprite (`cl_weapon_sprites 1`), on the hand the model hangs from.
func _present_held_sprite(id: StringName) -> void:
	if not FcWeaponIcons.shared.sprites:
		if _held_sprite != null:
			_held_sprite.queue_free()
			_held_sprite = null
		return
	if _held_sprite == null:
		var hand := attachment(&"right_hand")
		if hand == null:
			return
		_held_sprite = FcSpriteWeapon.make(FcSpriteWeapon.Mode.HELD)
		hand.add_child(_held_sprite)
	_held_sprite.show_weapon(id)
	_held_sprite.visible = _held_sprite.visible and is_alive() and not beyond_figure

## [param remote]: a body this client only draws, whose gun build may wait for [method held_equip_allowed].
func _present_held(remote: bool = false) -> void:
	if held == null:
		return

	var id := mirror_weapon
	var seq := mirror_fire_seq
	var kind := mirror_fire_kind
	var switching := mirror_switching
	var reloading := mirror_reloading

	if not mirrored and weapons != null and arsenal != null:
		var def := arsenal.current_def()
		id = def.id if def != null else &""
		seq = weapons.fire_seq % AwWeaponNet.FIRE_SEQ_WRAP
		kind = weapons.fire_kind
		switching = arsenal.is_switching()
		reloading = arsenal.is_reloading()

	var shown := held_may_show()
	held.visible = shown
	# Sub-spans only in a recording (FcFrameProbe.fine): this runs per drawn body per frame.
	var t_sprite := FcFrameProbe.lap_start()
	_present_held_sprite(id)
	FcFrameProbe.lap(&"r_held_sprite", t_sprite)

	# A remote body over this frame's budget keeps its old gun and tries again next frame.
	if id != held.equipped() and (not remote or id == &"" or held_equip_allowed()):
		var t_equip := Time.get_ticks_usec()
		var art: Variant = AwWeaponArtTable.table().get(id)
		_held_fitted = -1
		if art is AwWeaponVisual:
			var _drawn := held.equip(art as AwWeaponVisual)
		else:
			held.clear()
		FcFrameProbe.add(&"r_held_equip", t_equip)

	_present_fitting(id)

	var t_hooks := FcFrameProbe.lap_start()
	# The hooks are told what the snapshot said; a remote gun whose switching/reloading/aim/charge/shown are what it was last told
	# (and whose model is the same) is not told again except every HELD_RETELL frames (a person's carry can appear late).
	var charge := mirror_charge if mirrored else 0.0
	var alive := is_alive()
	var state := (int(switching) | (int(reloading and alive) << 1) | (int(aim_held and not mirrored and alive) << 2)
		| (int(shown) << 3))
	_held_told += 1
	if remote and _held_told < HELD_RETELL and state == _held_told_state and charge == _held_told_charge \
			and id == _held_told_id and held.equipped() == id:
		if (switching and held.hide_while_switching) or not shown:
			held.visible = false
	else:
		_held_told = 0
		_held_told_state = state
		_held_told_charge = charge
		_held_told_id = id
		held.on_switching(switching)
		# on_switching sets the model's own visible (hide_while_switching): it may hide the gun, never show one this hides.
		if not shown:
			held.visible = false
		if held.has_method(&"on_reloading"):
			held.call(&"on_reloading", reloading and alive)
		# Aiming is not replicated: only a body this client drives shoulders its gun for it (a shot does for all).
		if held.has_method(&"on_aiming"):
			held.call(&"on_aiming", aim_held and not mirrored and alive)
		if held.has_method(&"on_charge"):
			held.call(&"on_charge", charge)
	FcFrameProbe.lap(&"r_held_hooks", t_hooks)
	_present_inspect(alive)

	var fired := AwWeaponNet.uses_between(_seen_fire_seq, seq)
	_seen_fire_seq = seq

	# One kick however many uses the snapshot covered, the way `AwWeaponNet.apply` does:
	# a burst's worth of recoil in one frame reads as the gun jumping.
	if fired > 0 and is_alive():
		var t_fired := Time.get_ticks_usec()
		held.on_fired(WATCHED_RECOIL.get(kind, Vector2(0.6, 0.1)), kind)
		FcFrameProbe.add(&"r_held_fired", t_fired)

## Turns the held gun through the first-person inspect playing on this client's hands (fc-weapons API 42), so the
## third-person view and the lab's outside cameras see the gun looked over. Not replicated, like aiming: only a
## body this client drives has a view model to read, and a fraction not told again lets the held gun go.
func _present_inspect(alive: bool) -> void:
	if mirrored or weapons == null or not alive or not held.has_method(&"on_inspect"):
		return
	var hands: Variant = weapons.view_model()
	if hands is Object and (hands as Object).has_method(&"inspect_fraction"):
		held.call(&"on_inspect", float(hands.call(&"inspect_fraction")))


## Draws the held gun's attachments, and marks the hand (and the local rig) suppressed for FcAttach.wrap_report.
func _present_fitting(id: StringName) -> void:
	var code := mirror_fitted if mirrored else _held_code_cached()
	if held.equipped() != id:
		return
	if code == _held_fitted:
		return
	held.attachments = FcAttach.catalogue()
	held.on_fitted(code)
	_held_fitted = code
	_range_held()
	_held_suppressed = FcAttach.suppressed(id, code)
	held.set_meta(FcAttach.SUPPRESSED_META, _held_suppressed)
	if weapons != null:
		weapons.set_meta(FcAttach.SUPPRESSED_META, _held_suppressed)

## Gives every part of the held gun (attachments included) [member held_draw_range] as its draw distance.
func _range_held() -> void:
	if held_draw_range <= 0.0:
		return
	for part: Node in held.find_children("*", "GeometryInstance3D", true, false):
		(part as GeometryInstance3D).visibility_range_end = held_draw_range

## [method FcAttach.held_code] for this body's own arsenal, worked out again only when the held slot or its
## definition changes (`GSWeaponArsenal.fit` always puts a new definition in the slot). The code walks the whole
## attachments catalogue twice, and this runs per drawn body per frame: with varied bot guns it was ~0.6 ms a frame.
func _held_code_cached() -> int:
	var slot: GSWeaponSlot = arsenal.current() if arsenal != null else null
	var def: GSWeaponDef = slot.def if slot != null else null
	var cat: GSWeaponAttachments = arsenal.attachments if arsenal != null else null
	if slot != _held_code_slot or def != _held_code_def or cat != _held_code_cat:
		_held_code_slot = slot
		_held_code_def = def
		_held_code_cat = cat
		_held_code = FcAttach.held_code(arsenal)
	return _held_code

## Hangs a [AwWorldModel] on [method attachment]'s hand. Client side, with the body.
func _hold_weapon() -> void:
	if held != null:
		return

	held = AwWorldModel.new()
	held.name = "Held"
	held.cast_shadow = held_shadows

	if not held.attach_to(self):
		held.free()
		held = null
		return
	# Hidden until a present says it may show: a body built for a joiner while its player is dead
	# drew its gun at the hand's rest, in mid-air, until the first present reached it.
	held.visible = false
	# A new gun processes; the thinning's record of the old one would keep the next switch from reaching it.
	_held_thin = false
	_refresh_crowd_bits()

## What the drawn body wears for its side ([method FcTeamBodies.wear_key]; "" its own look), and the
## team and [member FcTeamBodies.version] it was last judged for.
var _team_worn := ""
var _team_judged := Vector2i(-1, -1)


## Rebuilds the body when its side's body changed: a team switch, the server's `team_avatars` or `team_tint`,
## a team mode starting or ending. Client side, once a frame; a dead player keeps the body it fell as
## (the ragdoll and the gib are made of it) and changes on the next life.
func follow_team_body() -> void:
	var judged := Vector2i(team, FcTeamBodies.version)
	if judged == _team_judged or body_mesh == null or not is_alive():
		return
	_team_judged = judged
	if FcTeamBodies.wear_key(team) != _team_worn:
		rebuild_body()


## Throws away the drawn body and builds it again from [member avatar]. Client side.
func rebuild_body() -> void:
	if body_mesh == null:
		return
	remove_child(body_mesh)
	body_mesh.queue_free()
	body_mesh = null
	# The hand and the gun in it hung off the old body and went with it.
	_hand = null
	held = null
	_held_sprite = null
	figure = null
	attach_body_mesh(Color.WHITE, avatar)


## Builds the avatar's rig under [member body_mesh]. Returns whether anything drew.
##
## [b]A failure here falls back to the capsule rather than leaving nothing.[/b] A
## player who is invisible because their crest is from a newer build is worse than one
## drawn as a capsule — and `conform` already drops a part it does not have, so
## reaching this at all means the schema itself would not build.
func _wear(avatar: GSAvatar) -> bool:
	figure = GSHumanoidFigure.new()
	figure.name = "Person"
	body_mesh.add_child(figure)
	var height := controller.tunables.stand_height if controller != null and controller.tunables != null else FcPlayerTunables.stand_height_m()
	# In a team mode the side's own body, when it has one (fc_team_bodies.gd); else the player's look.
	_team_worn = FcTeamBodies.wear_key(team)
	figure.build(FcTeamBodies.look_of(avatar, StringName("arena-player-%08d" % player_id), team), height)
	# own_body_back already trails the body as the view tips down; the figure own trail would double it.
	figure.own_look_down_back = 0.0
	# A drawn origin can sit about 0.5 m under the tread it stands on (a slow browser frame between two
	# ticks across a step, crouched): past the stock 0.45 m the lift ray starts under that floor, misses it,
	# and the body is drawn sunk to the waist. Drawing only; no hull fits under a floor this close above it.
	figure.floor_reach = FIGURE_FLOOR_REACH
	if controller != null and controller.tunables != null:
		# This game walks at about the stock run threshold: switch halfway between its walk and run.
		var t := controller.tunables
		var mid := t.max_speed * (1.0 + t.walk_speed_scale) * 0.5
		figure.set_run_speeds(mid, mid - 0.8)
		# This game's full run is a sprint: the run clip raced past 4x and popped a foot at full speed.
		figure.sprint_speed = 6.0

	if not figure.from_art:
		GSLog.debug(CHANNEL, "the people's art is missing; using the capsule", {"player": player_id})
		body_mesh.remove_child(figure)
		figure.queue_free()
		figure = null
		return false

	var crest := FcAvatars.crest_of(avatar)
	var crown := figure.attachment(&"crest") if crest != null else null
	if crown != null:
		crown.add_child(crest)
		_crest = crest
	elif crest != null:
		crest.free()

	return true

## Something to see a remote player as.
##
## [b]An avatar when one is given, a capsule and a nose when one is not.[/b] The
## fallback is not a lesser case: a server with no gs-platform hands out nothing, a
## client that has not been told yet has nothing, and a player has to be visible in
## both. [FcAvatars.stock_avatar] closes most of that gap — it is a real document
## over the same schema, deterministic in the player id — so the capsule is what is
## left when even the schema is absent.
##
## [b]The avatar is what makes gs-user-avatar do anything here.[/b] Before this,
## `FcAvatars` built documents, `FcIdentity` resolved them and
## `FcPlayer` drew a coloured capsule — a value produced correctly and consumed by
## nobody, which is this family's most repeated shape and which the "a method whose
## name occurs once" detector is what caught.
func attach_body_mesh(colour: Color, avatar: GSAvatar = null) -> void:
	if body_mesh != null:
		return

	body_mesh = Node3D.new()
	body_mesh.name = "Body"
	add_child(body_mesh)
	_refresh_crowd_bits()

	if _wear(avatar):
		_hold_weapon()
		return

	_hold_weapon()

	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.85

	var trunk := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = FcPlayerTunables.radius_m()
	capsule.height = FcPlayerTunables.stand_height_m()
	trunk.mesh = capsule
	trunk.material_override = material
	trunk.position = Vector3(0.0, 0.9, 0.0)
	body_mesh.add_child(trunk)

	# A nose, so which way somebody is facing is visible from across the arena. Two
	# overlapping shapes need the smaller one OUTSIDE the larger or the silhouette is
	# one blob — game-playlot drew every NPC icon as a coloured bar that way.
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.16, 0.16, 0.35)
	nose.mesh = box
	nose.material_override = material
	nose.position = Vector3(0.0, 1.5, -0.45)
	body_mesh.add_child(nose)

## Your own body in first person: [param mode] is GSPlayerViewRules' BODY_OFF, BODY_LEGS or
## BODY_FULL. Client side, for the player at this keyboard; placed each frame by [method present]
## at the drawn feet, so it moves with the interpolated eye. The held gun's world model stays hidden.
func present_own_body(mode: int, _yaw: float = 0.0) -> void:
	own_body_mode = mode
	if third_person and is_alive() and camera != null and camera.current:
		# Seen from behind: the whole body and the gun in its hands. Placed by `present`.
		if body_mesh == null:
			attach_body_mesh(Color.WHITE, avatar)
		if _first_person != null:
			_first_person.restore()
		if figure != null:
			figure.first_person = GSHumanoidOwnView.THIRD
			figure.position = Vector3.ZERO
		body_mesh.visible = true
		_present_held()
		return

	if mode <= 0 or not is_alive() or camera == null or not camera.current:
		if _first_person != null:
			_first_person.restore()
		if figure != null:
			figure.first_person = GSHumanoidOwnView.THIRD
		if body_mesh != null:
			body_mesh.visible = false
		if held != null:
			held.visible = false
		return

	if body_mesh == null:
		attach_body_mesh(Color.WHITE, avatar)
	if held != null:
		held.visible = false
	body_mesh.visible = true
	if figure != null:
		figure.first_person = GSHumanoidOwnView.BODY if mode >= 2 else GSHumanoidOwnView.LEGS
		return
	if _first_person == null:
		_first_person = GSPlayerFirstPersonBody.new()
		_first_person.back_offset = 0.0
		# What to keep, by name: the box avatars' parts are not named what a hide list would guess.
		_first_person.shown_names = PackedStringArray(["leg", "foot", "shoe", "boot"])
	_first_person.apply(body_mesh)

## Where your own body stands behind the eye for a view pitch in degrees (negative is down).
func own_body_back(pitch: float) -> float:
	var base := FIRST_PERSON_BACK if own_body_mode >= 2 else FIRST_PERSON_BACK_LEGS
	var down := clampf(-pitch, 0.0, 90.0)
	var extra := first_person_look_down_back if look_down_back_override < 0.0 else look_down_back_override
	return base + extra * clampf((down - 60.0) / 25.0, 0.0, 1.0)

## In first person: places your own body, when one is drawn, at the drawn feet behind the eye, with the wall-run roll.
func _place_own_body(drawn: GSFpsState, delta: float) -> void:
	if _tp_probe != null:
		_tp_probe.reset()
	if own_body_mode <= 0 or body_mesh == null or not body_mesh.visible:
		return
	_pose_body(drawn, drawn.yaw, delta)
	var back := own_body_back(drawn.pitch)
	body_mesh.global_position = drawn.position + Basis(Vector3.UP, deg_to_rad(drawn.yaw)) * Vector3(0.0, 0.0, back)

## What the body is doing now as [enum GSFpsState.Move] bits; remote players too (from the replicated state).
func move_flags() -> int:
	return controller.state.move_flags() if controller != null and controller.state != null else 0

## The light follows the rising edge of the switch bit, on the machine that decides (offline or the server).
func _flashlight_hands(pressed: bool, delta: float) -> void:
	var edge := pressed and not _flashlight_held
	_flashlight_held = pressed
	if flashlight_cfg == null:
		return
	if not flashlight_ready:
		flashlight_ready = true
		flashlight = FcFlashlight.starts_on(flashlight_cfg, flashlight_map)
	if edge and is_alive() and flashlight_cfg.enabled and GSFlashlightRules.allowed_on(flashlight_cfg, flashlight_map):
		flashlight = not flashlight and GSFlashlightRules.can_light(flashlight_cfg, flashlight_charge)
	if flashlight_cfg.battery:
		flashlight_charge = GSFlashlightRules.step_charge(flashlight_cfg, flashlight_charge, flashlight, delta)
		if flashlight and flashlight_charge <= 0.0:
			flashlight = false

# --- Simulation ------------------------------------------------------------

## Advances the player one tick. [b]The order is not arbitrary.[/b] Movement runs first so the shot
## leaves from where the player ends the tick rather than where they started it — half a tick of
## movement at Fatal Contact speeds is fifteen centimetres, which at range is a miss.
## Squeezes the hit zones down with the body. The zones are authored for a standing player; a crouched one is drawn
## about a quarter lower, so without this the head zone floated above the crouched head and a shot at the drawn head
## landed on the chest. Heights (and capsule lengths) scale, widths do not, and the feet stay on the ground.
func fit_hitboxes_to_stance() -> void:
	if controller != null:
		fit_hitboxes_to_crouch(controller.state.crouch_fraction)

## The zones fitted to [param crouch] (0 standing, 1 crouched): the present stance, or the one a rewound shot was drawn at.
func fit_hitboxes_to_crouch(crouch: float) -> void:
	if hitboxes == null or controller == null or controller.tunables == null:
		return
	var t := controller.tunables
	var k := lerpf(1.0, t.crouch_height / maxf(t.stand_height, 0.01), clampf(crouch, 0.0, 1.0))
	if FcHullGrid.enabled and k == _fit_k:
		return
	_fit_k = k
	for box in hitboxes.hitboxes():
		if not box.has_meta(&"stand_y"):
			box.set_meta(&"stand_y", box.position.y)
			box.set_meta(&"stand_h", box.height)
		var y: float = box.get_meta(&"stand_y")
		var h: float = box.get_meta(&"stand_h")
		box.position.y = y * k
		if box.shape == GSHitbox.Shape.CAPSULE:
			box.height = maxf(h * k, box.radius * 2.0 + 0.02)


## Sideways speed across the aim (positive right) that bends the wall-shot barrel; zero while wall-running, as the drawn view does.
static func wall_shot_strafe(state: GSFpsState) -> float:
	if state.is_wall_running():
		return 0.0
	return state.velocity.dot(Basis(Vector3.UP, deg_to_rad(state.yaw)).x)


## Set by the objectives each tick while this player carries a flag under the one-handed rule.
var flag_one_hand := false

## Whether the rig has simulate_idle (fc-weapons API 24); the live shell pins 21, whose idle tick is simulate_tick with no context.
static var idle_tick := GSAddonApi.build_level("fc_weapons") >= 24

## Whether an idle tick hands the rig its posture as a row (fc-weapons API 33, simulate_idle_row): one native call per
## idle weapon instead of the arsenal asking idle_still and idle_posture. Bit-exact either way; off is the A/B arm.
static var idle_row_lane := GSAddonApi.build_level("fc_weapons") >= 33


func simulate_tick(
	tick: int,
	delta: float,
	movement_command: GSFpsCommand,
	combat_command: GSWeaponCommand
) -> GSWeaponOutcome:
	if not health.alive:
		return GSWeaponOutcome.nothing("Dead.")
	tick_pre(tick, movement_command)
	var t_ctl := Time.get_ticks_usec()
	var d := body_delta(tick, delta, movement_command)
	if d > 0.0:
		controller.simulate_tick(tick, d)
	FcFrameProbe.add(&"p_controller", t_ctl)
	return tick_post(tick, delta, combat_command)


## Body tiers (gs-bot 23, on above bot_tier_body_above players): ticks between this bot's motor ticks, written by [code]FcBots[/code]
## from [method GSBotThinkTier.body_period] for a bot no person sees, nears or fights; 1 = every tick (people, and
## every bot while [code]bot_tier_body_every_near/far[/code] are 1 or the match has no more than [code]bot_tier_body_above[/code] players).
var body_every: int = 1
## The tick of this player's last motor tick, for [method body_delta].
var body_last_tick: int = -1
## Ticks this body sat out, for the bench.
static var body_skipped := 0
## A gap longer than this (a death, a map change) is not made up.
const BODY_MAX_GAP := 8
## [method body_delta] reads the state's packed columns (gs-player-controller 36: previous buttons 13, mode 9, slide 17,
## wall run 22, yaw 12) instead of six property calls per bot per tick; false is the property path (cvar ctl_native).
static var body_cols := GSAddonApi.build_level("gs_player_controller") >= 36
## What [method body_delta] answered last, for the batched loop's [method GSFpsController.end_tick].
var body_d := 0.0


## The delta this tick's motor runs with: [param delta] at full rate; 0.0 when the body sits this tick out under
## [member body_every] (its view still turns and its tick count still advances); else the ticks since its last
## motor tick times [param delta], so the skipped time is made up in one longer tick. Any edge ticks at once: a
## button change, a waiting push, or anything but walking on the ground (air, slide, wall run, ladder, swim).
func body_delta(tick: int, delta: float, command: GSFpsCommand) -> float:
	var gap := tick - body_last_tick
	if body_last_tick < 0 or gap <= 0 or gap > BODY_MAX_GAP:
		body_last_tick = tick
		body_d = delta
		return delta
	var s := controller.state
	if body_cols:
		# The state's columns ([code]GSFpsStateColumns[/code], gs-player-controller 36), fetched by name so older builds parse.
		var f: PackedFloat64Array = s.get(&"_f")
		if gap >= body_every or command.buttons != int(f[13]) or controller.has_external_velocity() \
				or int(f[9]) != GSFpsState.Mode.GROUND or f[17] >= 0.0 or f[22] >= 0.0:
			body_last_tick = tick
			body_d = delta * float(gap)
			return body_d
		f[12] = command.yaw
	elif gap >= body_every or command.buttons != s.previous_buttons or controller.has_external_velocity() \
			or not s.is_grounded() or s.is_sliding() or s.is_wall_running():
		body_last_tick = tick
		body_d = delta * float(gap)
		return body_d
	else:
		s.yaw = command.yaw
	s.pitch = command.pitch
	s.tick += 1
	body_skipped += 1
	body_d = 0.0
	return 0.0


## Where this tick started ([method tick_pre]) and what its controller cost before the motor (the batched loop's).
var _tick_start := Vector3.ZERO
var ctl_usec := 0


## [method simulate_tick] up to the controller's tick; the game's batched loop runs the controller's two halves itself.
func tick_pre(tick: int, movement_command: GSFpsCommand) -> void:
	var fine := FcFrameProbe.fine
	var t_fine := Time.get_ticks_usec() if fine else 0
	# Where the tick starts, for the pushes: "was this player in a booster last tick" is
	# asked of this position rather than remembered. See `fc_map_mechanics.gd`.
	_tick_start = controller.state.position
	_yaw_before_tick = controller.state.yaw
	# The previous state's position before this tick replaces it: two ticks back after it.
	# previous_position() (gs-player-controller 25) is render_state(0.0).position without duplicating the state, once per player per tick.
	_position_two_back = controller.previous_position()
	ladder.now = tick
	var view := GSFpsMotor._view_basis(controller.state.yaw, 0.0)
	var intent: Vector3 = view.right * movement_command.move.x + view.forward * movement_command.move.y
	ladder.wish = Vector3(intent.x, 0.0, intent.z).normalized()
	_hull_tick = tick
	controller.apply_command(movement_command)
	if fine:
		FcFrameProbe.add(&"p_pre", t_fine)


## [method simulate_tick] after the controller's tick: the map's mechanics, the health and the weapons.
func tick_post(tick: int, delta: float, combat_command: GSWeaponCommand) -> GSWeaponOutcome:
	if tick_post_head(tick, delta, combat_command):
		var still := _idle_row()
		return tick_idle_row(_posture_row, still)
	return tick_weapons(tick)


## [method tick_post] up to its weapons. True when they tick idle through the row lane: the caller then hands
## [method tick_idle_row] the posture row (FcGame's batched loop fills every such player's in one gs-sim call).
func tick_post_head(tick: int, delta: float, combat_command: GSWeaponCommand) -> bool:
	var fine := FcFrameProbe.fine
	var t_fine := Time.get_ticks_usec() if fine else 0
	_post_moved = false
	fit_hitboxes_to_stance()
	if fine:
		FcFrameProbe.add(&"p_hitbox", t_fine)
	var t_mech := Time.get_ticks_usec()
	if _volumes_asked_tick != tick and mechanics_native and volume_pre != null:
		volume_pre.mark_one(tick, self)
	var clear := _volumes_skip(tick, _tick_start)
	_run_map_mechanics(_tick_start, delta, clear)
	var t_follow := FcFrameProbe.lap_start()
	_follow_map_volumes(clear)
	FcFrameProbe.lap(&"pm_follow", t_follow)
	FcFrameProbe.add(&"p_mechanics", t_mech)
	var t_tail := FcFrameProbe.lap_start()

	var state := controller.state

	# The aim comes from the movement command, not from a second sample (a shot would leave at another angle than the
	# view's). Copied into this player's own command, which nothing keeps past the tick: no new object per player a tick.
	_command.slot = combat_command.slot
	_command.buttons = combat_command.buttons
	_command.yaw = state.yaw
	_command.pitch = state.pitch
	if not is_nan(late_fire_aim.x):
		_command.yaw = late_fire_aim.x
		_command.pitch = late_fire_aim.y
		late_fire_aim = Vector2(NAN, 0.0)
	FcFlagCarry.filter_command(self, _command)
	aiming = _command.is_pressed(BUTTON_AIM)
	_flashlight_hands(_command.is_pressed(FcFlashlight.BUTTON), delta)

	health.tick(tick, delta)

	# Read once: it walks the view's global transform, and the combat origin and the weapon context want the same point.
	_muzzle = muzzle_position()
	if _combat != null:
		_combat.set_authoritative_origin(player_id, _muzzle)

	# The posture feeds the spread (running, air, slide and crouch change the cone): the arsenal asks
	# [method _idle_posture] for the same fields the context below gets, so a moving player takes this path too.
	_posture_tick = tick
	_idle_now = weapons.would_idle(_command)
	FcFrameProbe.lap(&"ph_tail", t_tail)
	return _idle_now and idle_row_lane and controller != null


## The idle weapon tick of a [method tick_post_head] that answered true: [param row] is [method _idle_row]'s
## (its first 9 floats), [param still] its still flag.
func tick_idle_row(row: PackedFloat64Array, still: bool) -> GSWeaponOutcome:
	var t_wp := Time.get_ticks_usec()
	var out: GSWeaponOutcome = weapons.call(&"simulate_idle_row", _command, _posture_tick, row, still)
	_idle_hands()
	FcFrameProbe.add(&"p_weapons", t_wp)
	if FcWeaponCensus.on:
		FcFrameProbe.add(&"pwx_idle_row", t_wp)
	if FcFrameProbe.fine:
		FcFrameProbe.charge_weapon_phases()
	return out


## The weapon tick of a [method tick_post_head] that answered false.
func tick_weapons(tick: int) -> GSWeaponOutcome:
	var t_wp := Time.get_ticks_usec()
	var out: GSWeaponOutcome
	# A shooter with nothing pressed and nothing under way ticks the weapon in hand and no more: the rig
	# builds its own posture then, so the context below (a dozen writes and an extra dictionary) is skipped.
	if _idle_now:
		out = weapons.simulate_idle(_command, tick) if idle_tick else weapons.simulate_tick(_command, tick, null)
		_idle_hands()
		FcFrameProbe.add(&"p_weapons", t_wp)
		if FcWeaponCensus.on:
			FcFrameProbe.add(&"pwx_idle_ctx", t_wp)
		if FcFrameProbe.fine:
			FcFrameProbe.charge_weapon_phases()
		return out
	var ctx := _weapon_context(tick, _muzzle, controller.state)
	if FcFrameProbe.fine:
		FcFrameProbe.add(&"p_wctx", t_wp)
		t_wp = Time.get_ticks_usec()

	# Through the rig, which runs the arsenal and then the bash. It keeps the previous
	# command itself, for the same edge triggers the arsenal used to be handed it for.
	out = weapons.simulate_tick(_command, tick, ctx)
	FcFrameProbe.add(&"p_weapons", t_wp)
	if FcWeaponCensus.on:
		FcFrameProbe.add(&"pwx_full", t_wp)
	if FcFrameProbe.fine:
		FcFrameProbe.charge_weapon_phases()
	return out


# The rig's idle tick asks the shared player bridge for the sprint, and this player has none of
# its controller nodes: without this the hands never go to the sprint carry on a plain run.
func _idle_hands() -> void:
	var hands := weapons.view_model()
	if hands != null:
		hands.set_sprinting(controller.state.sprinting)

## The weapon context of a tick that does more than idle.
func _weapon_context(tick: int, muzzle: Vector3, state: GSFpsState) -> GSWeaponContext:
	# Pushed in from the simulated state, never read out of a rendered one: an
	# interpolated position differs between client and server by design, and feeding it
	# to the spread makes the spread differ too.
	var ctx := GSWeaponContext.make(
		player_id, tick, muzzle, _command.aim_direction()
	)
	ctx.speed = state.horizontal_speed()
	ctx.airborne = not state.is_grounded()
	ctx.crouched = state.is_crouched()
	ctx.sliding = state.is_sliding()
	ctx.sprinting = state.sprinting
	ctx.wall_running = state.is_wall_running()
	ctx.hurt_tick = health.last_damage_tick if health.last_damage_tick >= 0 else -1
	ctx.sprint_blocks_fire = not controller.tunables.sprint_can_shoot
	ctx.sprint_shot_follows_barrel = controller.tunables.sprint_shot_follows_barrel
	ctx.authority = arsenal.authority
	# Sideways speed across the aim, positive right: the client's gun tilts with it, so the wall shot must too.
	ctx.extra[&"strafe"] = wall_shot_strafe(state)
	return ctx






