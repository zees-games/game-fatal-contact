extends Node

## A portrait per player: their avatar's head, rendered once (`UPDATE_ONCE`) into a small viewport and
## drawn in the ranked row; re-rendered only when what they wear changes. Nothing is built with no
## display (every suite): the row draws initials instead.
## Every portrait shares one world, one environment (the world's) and one sun. The sun is in the tree only
## while a portrait renders, and each figure is freed once its picture is taken (the viewport keeps it),
## so between builds the cache adds no light, instance or environment to any frame.

const FcAvatars := preload("fc_avatars.gd")
const SIDE := 96
## How far apart (metres, along X) the figures stand in the shared world, so no camera sees another's.
const SPACING := 4.0
## Frames after a build before its figure and the sun go: the build frame renders it.
const SETTLE_FRAMES := 2
## Figure places before they repeat: far more than ever pose at once.
const SLOTS := 256

## `cl_portrait_builds`: most portraits rendered in one frame (0: no limit). Each is a
## viewport with its own figure; a full row at once was one long frame.
## A portrait over the limit shows the old face (or initials) until a later pass.
static var builds_per_frame: int = 1
## `cl_portrait_keep`: portraits kept for players out of the row, so rank churn in a
## 16v16 does not rebuild the same faces every few seconds (0: only the shown ones).
static var keep_extra: int = 24

## player id -> [SubViewport, digest, last frame shown]
var _made: Dictionary = {}
var _build_frame := -1
var _builds := 0
## The world every portrait renders in; its environment is the one environment.
var _world: World3D = null
## Holds the sun in [member _world]; in the tree only while a portrait is pending.
var _studio: SubViewport = null
## Figures waiting for their picture, freed [constant SETTLE_FRAMES] after [member _last_build].
var _posing: Array[Node] = []
var _last_build := -1
## The next figure's slot (its place along X); figures live only until their picture is taken, so slots roll over.
var _next_slot := 0

func _ready() -> void:
	set_process(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_studio) and not _studio.is_inside_tree():
		_studio.free()

## The portrait for [param id] wearing [param avatar], or null with no display.
func portrait(id: int, avatar: GSAvatar) -> Texture2D:
	if DisplayServer.get_name() == "headless" or avatar == null:
		return null
	var digest := avatar.digest()
	var have: Array = _made.get(id, [])
	var frame := Engine.get_process_frames()
	var old: SubViewport = have[0] as SubViewport if not have.is_empty() and is_instance_valid(have[0]) else null
	if old != null and str(have[1]) == digest:
		have[2] = frame
		return old.get_texture()
	if frame != _build_frame:
		_build_frame = frame
		_builds = 0
	if builds_per_frame > 0 and _builds >= builds_per_frame:
		return old.get_texture() if old != null else null
	_builds += 1
	if old != null:
		old.queue_free()
	var view := _render(avatar, id)
	_made[id] = [view, digest, frame]
	return view.get_texture()

## Forgets players out of the row beyond the [member keep_extra] most recently shown.
func keep_only(ids: Array) -> void:
	var out: Array = []
	for id in _made.keys():
		if not ids.has(id):
			out.append(id)
	if out.size() <= keep_extra:
		return
	out.sort_custom(func(a: Variant, b: Variant) -> bool: return int(_made[a][2]) < int(_made[b][2]))
	for id in out.slice(0, out.size() - keep_extra):
		var have: Array = _made[id]
		if is_instance_valid(have[0]):
			(have[0] as Node).queue_free()
		_made.erase(id)

## Once the last build has rendered: frees the posed figures and takes the sun out of the tree.
func _process(_delta: float) -> void:
	if Engine.get_process_frames() - _last_build < SETTLE_FRAMES:
		return
	for person in _posing:
		if is_instance_valid(person):
			person.queue_free()
	_posing.clear()
	if is_instance_valid(_studio) and _studio.is_inside_tree():
		remove_child(_studio)
	set_process(false)

## The shared world, with the sun's holder in the tree.
func _open_studio() -> void:
	if _world == null:
		_world = World3D.new()
		var environment := Environment.new()
		environment.background_mode = Environment.BG_CLEAR_COLOR
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = Color(0.85, 0.87, 0.95)
		environment.ambient_light_energy = 0.7
		_world.environment = environment
		_studio = SubViewport.new()
		_studio.name = "Studio"
		_studio.size = Vector2i(1, 1)
		_studio.world_3d = _world
		_studio.render_target_update_mode = SubViewport.UPDATE_DISABLED
		var sun := DirectionalLight3D.new()
		# Shining onto the face, which is on the -Z side.
		sun.rotation_degrees = Vector3(-30.0, 160.0, 0.0)
		sun.light_energy = 1.1
		_studio.add_child(sun)
	if not _studio.is_inside_tree():
		add_child(_studio)
	_last_build = Engine.get_process_frames()
	set_process(true)

## Where the next figure stands: clear of every other figure still posing.
func _next_place() -> Vector3:
	_next_slot = (_next_slot + 1) % SLOTS
	return Vector3(SPACING * float(_next_slot), 0.0, 0.0)

func _render(avatar: GSAvatar, id: int) -> SubViewport:
	_open_studio()
	var view := SubViewport.new()
	view.size = Vector2i(SIDE, SIDE)
	view.transparent_bg = true
	view.world_3d = _world
	# The rest of the client runs msaa 0 on the web (gl_compatibility); a 4x resolve per glance face is wasted there.
	view.msaa_3d = Viewport.MSAA_DISABLED if (GSPlatform.is_web() or RenderingServer.get_current_rendering_method() == "gl_compatibility") else Viewport.MSAA_4X
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	# No omni or spot light reaches a portrait: no shadow atlas.
	view.positional_shadow_atlas_size = 0
	add_child(view)

	# The same person the body is (`FcPlayer` draws `FcAvatars.look_of` of the same
	# document and key), standing still, so the face in the row is the face in the world.
	var person := GSHumanoidFigure.new()
	person.position = _next_place()
	view.add_child(person)
	person.build(FcAvatars.look_of(avatar, StringName("arena-player-%08d" % id)), 1.8)
	person.animate(0.0, 0.0)
	# Posed once and never animated (`auto_animate` is off): its per-frame `_process` has nothing to do.
	person.set_process(false)
	_posing.append(person)
	var face := FACE
	var bones := person.skeleton()
	if bones != null and bones.find_bone("Head") >= 0:
		face = _head_of(person, bones)
	face += person.position

	# The figure faces -Z, so the camera is on that side, a little to one side so the
	# head has depth. Near and far hold this figure only, not its neighbours in the shared world.
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = FRAME_SIZE
	camera.far = 6.0
	view.add_child(camera)
	camera.look_at_from_position(face + Vector3(-0.8, 0.15, -3.0), face)
	camera.current = true
	return view

## The middle of the person's head, in the figure's space: the head bone (the bottom of the
## head) carried up through the model, plus a third of a head.
static func _head_of(person: GSHumanoidFigure, bones: Skeleton3D) -> Vector3:
	var to_figure := Transform3D.IDENTITY
	var node: Node = bones
	while node != null and node != person:
		if node is Node3D:
			to_figure = (node as Node3D).transform * to_figure
		node = node.get_parent()
	var head := to_figure * bones.get_bone_global_pose(bones.find_bone("Head")).origin
	return head + Vector3(0.0, 0.2, 0.0)

## Where the head is when there is no skeleton to ask (the capsule), and how much of it the
## frame holds.
const FACE := Vector3(0.0, 1.3, 0.0)
const FRAME_SIZE := 0.66
