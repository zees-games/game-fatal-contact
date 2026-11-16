extends Node3D

## Your own arms on dot-player-char's DotPlayerViewArms, holding the weapon where AwViewModel
## measured its grip. Absent below API 8: the view model draws its own hands then.

const NEEDS_LEVEL := 8
## Poses held with the firing hand alone.
const ONE_HAND: Array[StringName] = [&"melee", &"thrown", &"fists"]
## The hand pose (DotViewGrip.kind, dot-player-char's DotViewHandPoses) each weapon art pose closes into.
const POSE_KINDS := {&"rifle": &"rifle", &"pistol": &"pistol", &"heavy": &"launcher", &"melee": &"knife",
	&"thrown": &"grenade", &"fists": &"fists"}
## Weapons whose hands differ from their art pose's (a pump's fore-end, a scoped stock); edit or add ids.
static var hand_kinds := {&"shotgun": &"shotgun", &"drum_shotgun": &"shotgun", &"sniper": &"sniper",
	&"marksman": &"sniper", &"fists": &"fists"}
## Nearest a held grip comes to the eye (metres), so a pistol's hand does not fill the view.
const HANDS_MIN_DISTANCE := 0.3
## Added to it with real hands (dot-player-char 28), whose wrist sits this far behind the grip the fingers close on:
## at 0.3 alone an aimed revolver's wrist came 0.041 m from the eye, inside the camera's near plane (0.04 still 0.048).
static var real_hand_setback := 0.06
## DotPlayerViewArms' own hand size, for a weapon whose profile does not say.
const DEFAULT_HAND_SCALE := 0.5
const ArenaTeamBodies := preload("arena_team_bodies.gd")
## The kit bones a team body's first-person arms keep (by prefix, both sides): [method not_arm].
const ARM_BONES: Array[String] = ["Shoulder.", "UpperArm.", "LowerArm.", "Hand", "Thumb", "Index", "Middle", "Ring", "Pinky"]

## cl_pose_debug: draws the grip sockets, hand targets and arm bones over the view.
static var debug_pose := false
## cl_fp_hand_scale: multiplies the held-hand size of every weapon (1 leaves the profile's).
static var hand_scale_mult := 1.0
## cl_fp_forearm_scale: multiplies the held-forearm size of every weapon.
static var forearm_scale_mult := 1.0
## cl_fp_scope_arms_hide: aim fraction the scoped arms hide at, for every weapon (-1: each weapon's own).
static var scope_arms_hide_override := -1.0
## cl_fp_hold_depth: share of the viewmodel_fov magnification given back as distance (AwViewModel.hands_depth_comp).
## At 1 the gun sat 1.5 m out at its 90-degree size, small behind arms drawn a quarter metre from the eye; 0 keeps it at the authored 0.55 m.
static var hold_depth_comp := 0.0
## cl_fp_max_lean: cap on how far the arms lean to a hand target, for every weapon (-1: each weapon's own).
static var max_lean_override := -1.0

var arms: DotPlayerViewArms = null
var body: Node3D = null
var _grip: DotViewGrip = null
var _own_lean := 0.4
## The game whose `fp_arms` rule (arena_fp_arms) may put one arm set on everybody; null keeps the player's own.
var rules: Object = null
var _arm_set: Array = []
## [wear key, look] of the side's body the arms last wore ([method team_look]).
var _team_set: Array = []
var _boxes: Dictionary = {}
var _art_model := 0
var _art: Array = []
var _look_override := false


static func available() -> bool:
	return DotAddonApi.build_level("dot_player_char") >= NEEDS_LEVEL


## Puts a view model's hands on [param body]'s camera: AwViewModel's own when there is no API, else these arms under [param parent].
static func mount(parent: Node, model: AwViewModel, body: Node3D, look: DotHumanoidLook, p_rules: Object = null) -> Node3D:
	if not available() or not model.has_signal(&"hands_reached"):
		return null
	model.show_arms = false
	var mounted := new()
	mounted.name = "ViewArms"
	mounted.body = body
	mounted.rules = p_rules
	parent.add_child(mounted)
	mounted.arms = DotPlayerViewArms.new()
	mounted.arms.name = "ViewArms"
	mounted.add_child(mounted.arms)
	mounted.arms.build(look, 1.8)
	mounted._own_lean = mounted.arms.max_lean
	mounted._look_override = mounted.arms.has_method(&"set_look_override")
	if &"hands_scale" in model:
		model.hands_scale = mounted.arms.held_scale
		model.hands_min_distance = HANDS_MIN_DISTANCE + (real_hand_setback if mounted.arms.get(&"real_hands") == true else 0.0)
	model.hands_reached.connect(mounted._on_hands)
	return mounted


func _on_hands(anchor: Node3D, grip: Vector3, fore: Vector3, pose: StringName) -> void:
	var one := pose in ONE_HAND
	if _grip == null or _grip.anchor != anchor or _grip.is_two_hand() == one:
		_grip = DotViewGrip.one_hand(anchor, grip) if one else DotViewGrip.two_hand(anchor, grip, fore)
		arms.set_held(_grip)
	_grip.grip = grip
	if not one:
		_grip.support = fore
	var model: AwViewModel = body.weapons.view_model() if body != null and body.weapons != null else null
	# A knife's handle is inside the fist and against the wrist, so keeping the arm out of its box swung the elbow
	# out flat beside the eye (anim_review's T-pose); a blade held in one hand has no forend to clear.
	_grip.bounds = AABB() if pose == &"melee" else weapon_bounds(model, _boxes)
	# Real fingers (dot-player-char 27): which grip they close into and the gun's axes they close round.
	if "kind" in _grip:
		_grip.kind = hand_kind(pose, body.weapons.current_art() if body != null and body.weapons != null else null)
		var held: Dictionary = model.art_hand_grip() if model != null and model.has_method(&"art_hand_grip") else {}
		var to_anchor := anchor.global_transform.basis.orthonormalized().inverse()
		var f: Vector3 = (to_anchor * (held.get("forward", Vector3.ZERO) as Vector3)).normalized()
		var u: Vector3 = (to_anchor * (held.get("up", Vector3.ZERO) as Vector3)).normalized()
		# A grenade's art forward is its own up (the fuse): no gun axis to close round, so the view's own.
		var axes := f.is_normalized() and u.is_normalized() and absf(f.dot(u)) < 0.9
		_grip.forward = f if axes else Vector3.FORWARD
		_grip.up = u if axes else Vector3.UP


## The hand pose [param art] is held in: its id's in [member hand_kinds], else its art pose's ([constant POSE_KINDS]),
## else a rifle's.
static func hand_kind(pose: StringName, art: Resource) -> StringName:
	var id: StringName = art.get(&"id") if art != null else &""
	if hand_kinds.has(id):
		return hand_kinds[id]
	return POSE_KINDS.get(pose, &"rifle")


## The drawn weapon's box in the frame [signal AwViewModel.hands_reached] gives its points in, which the arms keep
## their elbows out of. That frame is often a bare marker (HandsFrame) with no mesh for dot-player-char to measure,
## but its points are the animated node's, so the weapon is measured there. [param boxes] keeps each weapon's own box.
static func weapon_bounds(model: AwViewModel, boxes: Dictionary) -> AABB:
	var weapon: Node3D = model.weapon_node() if model != null else null
	if weapon == null or not weapon.is_inside_tree():
		return AABB()
	var animated: Node3D = weapon
	while animated.get_parent() != model and animated.get_parent() is Node3D:
		animated = animated.get_parent() as Node3D
	if animated.get_parent() != model:
		return AABB()
	var key := weapon.get_instance_id()
	if not boxes.has(key):
		if boxes.size() > 32:
			boxes.clear()
		boxes[key] = DotViewGrip.one_hand(weapon, Vector3.ZERO).bounds_local()
	var box: AABB = boxes[key]
	if not box.has_volume():
		return AABB()
	return (animated.global_transform.affine_inverse() * weapon.global_transform) * box


## The look the server's `fp_arms` rule draws on every player's arms (a stock set, seeded by its value); null for
## each player's own. [param memo] keeps it one object, since the rig rebuilds whenever the drawn look is a new one.
static func arm_set_look(p_rules: Object, memo: Array) -> DotHumanoidLook:
	var set_id := int(p_rules.call(&"rule", "fp_arms")) if p_rules != null and p_rules.has_method(&"rule") else 0
	if set_id <= 0:
		return null
	if memo.size() != 2 or int(memo[0]) != set_id:
		memo.assign([set_id, DotHumanoidLook.stock(set_id)])
	return memo[1] as DotHumanoidLook


## The side's body [param p_body] wears in a team mode (arena_team_bodies.gd), so the arms in view are the
## body's sleeves in its colour; null off a team mode or without a body. [param memo] keeps it one object.
static func team_look(p_body: Object, memo: Array) -> DotHumanoidLook:
	if p_body == null:
		return null
	var team := int(p_body.get(&"team"))
	var wear := ArenaTeamBodies.wear_key(team)
	if wear == "":
		return null
	if memo.size() != 2 or String(memo[0]) != wear:
		var key := StringName("arena-player-%08d" % int(p_body.get(&"player_id")))
		memo.assign([wear, ArenaTeamBodies.look_of(p_body.get(&"avatar") as DotAvatar, key, team)])
	return memo[1] as DotHumanoidLook


## Holding, follows the whole look like the drawn weapon, so pitch never takes the grip out of reach; empty-handed
## (a downed crawl), by yaw only. Hidden with the view model or a scope.
func _process(delta: float) -> void:
	var camera: Camera3D = body.camera if body != null else null
	if camera == null or arms == null:
		return
	var model: AwViewModel = body.weapons.view_model() if body.weapons != null else null
	global_position = camera.global_position
	global_rotation = Vector3(camera.global_rotation.x if holding() else 0.0, camera.global_rotation.y, 0.0)
	if model != null:
		model.hands_depth_comp = hold_depth_comp
	visible = model != null and model.visible and not model.arms_hidden_by_scope() and body.is_alive()
	if model != null:
		var art := _art_of(model)
		if art[0]:
			var own: float = model.call(&"art_hand_scale")
			arms.hand_scale = (own if own > 0.0 else DEFAULT_HAND_SCALE) * hand_scale_mult
		if art[1]:
			var fore: float = model.call(&"art_forearm_scale")
			arms.forearm_scale = (fore if fore > 0.0 else 1.0) * forearm_scale_mult
		model.scope_arms_hide_override = scope_arms_hide_override
		var lean: float = model.call(&"art_max_lean") if art[2] else -1.0
		arms.max_lean = max_lean_override if max_lean_override >= 0.0 else (lean if lean >= 0.0 else _own_lean)
	if _look_override:
		var over := arm_set_look(rules, _arm_set)
		var team := team_look(body, _team_set) if over == null else null
		# A team body is a whole prepared figure: its vest and collar reach into the bottom of the view as the
		# clip breathes, so only its arms are drawn. Set before the override, which rebuilds the mesh with it.
		arms.hide_vertex_fn = not_arm if team != null else Callable()
		arms.set_look_override(over if over != null else team)
	if &"debug_pose" in arms and arms.debug_pose != debug_pose:
		arms.debug_pose = debug_pose
	var v: Vector3 = body.controller.state.velocity
	# The knife's and empty hands' sprint stride: the view model works out how much shows and where in it.
	if model != null:
		arms.run = model.run_amount()
		arms.run_phase = model.run_phase()
	# The knife throw's wind-back turns the knife fist into the throw's pinch.
	if &"throw_grip" in arms:
		var windup: float = body.get(&"windup") if &"windup" in body else -1.0
		arms.throw_grip = clampf(windup, 0.0, 1.0) if windup >= 0.0 else 0.0
	arms.tick(Vector2(v.x, v.z).length(), delta)


## [member DotPlayerViewArms.hide_vertex_fn] for a team body: true for a vertex mostly on any bone but the
## shoulders, arms, hands and fingers.
static func not_arm(bone: StringName, _rest: Vector3) -> bool:
	var name := String(bone)
	for arm in ARM_BONES:
		if name.begins_with(arm):
			return false
	return true


## Which of art_hand_scale, art_forearm_scale and art_max_lean [param model] has, asked once per view model
## rather than three has_method calls a frame.
func _art_of(model: AwViewModel) -> Array:
	var id := model.get_instance_id()
	if id != _art_model:
		_art_model = id
		_art = [model.has_method(&"art_hand_scale"), model.has_method(&"art_forearm_scale"), model.has_method(&"art_max_lean")]
	return _art


func holding() -> bool:
	return arms != null and arms.shown and _grip != null and _grip.is_valid()
