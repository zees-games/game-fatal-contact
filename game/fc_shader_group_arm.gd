extends SubViewport

const FcLoadTimeline := preload("fc_load_timeline.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")

## Enables Forward+'s advanced shader group (lightmaps) with one lightmapped draw before most 3D shaders exist: enabled
## later, it loads for every live shader in one frame (dm_box ~1000 ms on staging; tools/lightmap_first_draw.gd 185 ms
## with no extra shaders, 6993 ms with 60). Off with launch value `cl_shader_group_arm 0`.

## Off: the group is enabled at the level's first lightmapped frame, as before.
static var enabled := true
## Frames drawn before the viewport frees itself: one to enable the group, one more for its pipelines.
const FRAMES := 2

var _left := FRAMES


## Whether this client should arm the group: a drawing Forward+ client that was not told otherwise.
static func wanted() -> bool:
	if not enabled or GSPlatform.is_headless():
		return false
	if RenderingServer.get_current_rendering_method() != "forward_plus":
		return false
	return FcFrameProbe.launch_value("cl_shader_group_arm") != "0"


func _ready() -> void:
	name = "ShaderGroupArm"
	size = Vector2i(4, 4)
	own_world_3d = true
	render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var cam := Camera3D.new()
	add_child(cam)
	cam.make_current()
	var arm := Node3D.new()
	arm.position = Vector3(0.0, 0.0, -3.0)
	var box := MeshInstance3D.new()
	box.name = "Box"
	var mesh := BoxMesh.new()
	mesh.add_uv2 = true
	box.mesh = mesh
	box.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	arm.add_child(box)
	var data := LightmapGIData.new()
	data.lightmap_textures = [_tiny_texture()]
	data.add_user(NodePath("../Box"), Rect2(0, 0, 1, 1), 0, -1)
	var gi := LightmapGI.new()
	gi.light_data = data
	arm.add_child(gi)
	add_child(arm)
	RenderingServer.frame_post_draw.connect(_on_drawn)


func _on_drawn() -> void:
	_left -= 1
	if _left > 0:
		return
	RenderingServer.frame_post_draw.disconnect(_on_drawn)
	FcLoadTimeline.mark("shader group armed")
	queue_free()


static func _tiny_texture() -> Texture2DArray:
	var img := Image.create_empty(4, 4, false, Image.FORMAT_RGBAH)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	var arr := Texture2DArray.new()
	var _e := arr.create_from_images([img])
	return arr
