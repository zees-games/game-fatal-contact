extends DotGameVisualQaCapture

## FC's visual QA capture for the horde monsters (npcs/) and the 20 avatar bodies (`avatar_<part>`, the document's
## BODIES): each idles, walks and runs a circle on the default stage, seen from the victim's eye (an avatar: first
## person free, the eye is a plain outside view), behind-right and the front, at 60 fps. The loop and the checklist are dot-game's
## docs/visual-qa.md; the weapons and the player's own locomotion are tools/anim_review.gd (docs/anim-review.md).
## A monster's figure animates from how far its body moves (`auto_animate`), so a clip moves the body at that pace.
##   bash tools/visual_qa_shot.sh [--only grunt,brute] [--clips walk,run]
##   bash tools/visual_qa_shot.sh --only avatar_kenney_a,avatar_scout --clips walk,run,sprint,crouch_walk,jump

const KINDS: PackedStringArray = ["grunt", "gunner", "brute", "stalker"]
## Metres per second for each clip: the horde's walk and run pace.
const PACE := {"idle": 0.0, "walk": 1.4, "run": 5.0}
const CIRCLE_RADIUS := 3.0
const AVATAR_PREFIX := "avatar_"
## An avatar's clips: ground speed (m/s) and the motion the figure is told. FC's walk, run mid-point and sprint.
const AVATAR_CLIPS := {
	"idle": [0.0, {}], "walk": [2.6, {}], "run": [4.2, {}], "sprint": [6.0, {"sprinting": true}],
	"crouch_walk": [1.8, {"crouched": true}], "jump": [4.2, {"on_floor": false, "vertical": 3.0}],
}
const FcAvatars := preload("../game/fc_avatars.gd")
const FcPlayerTunables := preload("../game/fc_player_tunables.gd")

var _fig: DotHumanoidFigure = null

## Frames a moving clip is driven before frame 0, at negative times along the same path: a figure that animates from its body's motion
## (`auto_animate`) stands in its idle for its first few frames, and foot_slide would judge that start-up as a foot dragging.
const LEAD_IN_FRAMES := 30

var _npc: Node3D = null
var _kind := ""
var _lead_left := 0
var _lead_clip := ""


func _items() -> PackedStringArray:
	var out := KINDS.duplicate()
	for part in FcAvatars.BODIES:
		out.append(AVATAR_PREFIX + String(part).trim_prefix("fc_body_"))
	return out


func _clips(item: String) -> PackedStringArray:
	return PackedStringArray(AVATAR_CLIPS.keys() if item.begins_with(AVATAR_PREFIX) else PACE.keys())


func _stage_avatar(item: String, clip: String) -> DotResult:
	if _kind != item:
		if _fig != null:
			_fig.queue_free()
		var part := item.trim_prefix(AVATAR_PREFIX)
		var key := StringName("arena-player-00000007")
		var avatar := FcAvatars.stock_avatar(key)
		avatar.set_part(FcAvatars.SLOT_BODY, StringName("fc_body_" + part))
		if part.begins_with("kenney_"):
			avatar.set_part(FcAvatars.SLOT_HEAD, StringName("fc_head_" + part))
		_fig = DotHumanoidFigure.new()
		root.add_child(_fig)
		_fig.build(FcAvatars.look_of(avatar, key), FcPlayerTunables.stand_height_m())
		_fig.set_run_speeds(4.2, 3.4)
		_fig.sprint_speed = 6.0
		_kind = item
	_fig.position = Vector3(0.0, 0.0, -CIRCLE_RADIUS)
	_fig.rotation = Vector3.ZERO
	return DotResult.success(clip)


func _stage(item: String, clip: String) -> DotResult:
	if item.begins_with(AVATAR_PREFIX):
		return _stage_avatar(item, clip)
	if _npc == null or _kind != item:
		if _npc != null:
			_npc.queue_free()
		var scene := load("res://npcs/fc_%s.tscn" % item) as PackedScene
		if scene == null:
			return DotResult.fail(DotError.CODE_INVALID, "no npcs/fc_%s.tscn" % item)
		_npc = scene.instantiate() as Node3D
		root.add_child(_npc)
		_kind = item
	_npc.position = Vector3(0.0, 0.0, -CIRCLE_RADIUS)
	_npc.rotation = Vector3.ZERO
	_lead_left = LEAD_IN_FRAMES if float(PACE[clip]) > 0.0 else 0
	_lead_clip = clip
	if _lead_left > 0 and not root.get_tree().process_frame.is_connected(_lead_in):
		root.get_tree().process_frame.connect(_lead_in)
	return DotResult.success(clip)


func _warmup_frames(item: String, clip: String) -> int:
	if item.begins_with(AVATAR_PREFIX):
		return 2
	return LEAD_IN_FRAMES + 2 if float(PACE[clip]) > 0.0 else 2


## One lead-in frame: the body already moving when the recording starts.
func _lead_in() -> void:
	if _lead_left <= 0:
		root.get_tree().process_frame.disconnect(_lead_in)
		return
	_drive(_kind, _lead_clip, -float(_lead_left) / float(fps), 0)
	_lead_left -= 1


func _subject(item: String) -> Node3D:
	return _fig if item.begins_with(AVATAR_PREFIX) else _npc


func _seconds(_item: String, _clip: String) -> float:
	return 3.0


func _drive_avatar(clip: String, t: float) -> void:
	var def: Array = AVATAR_CLIPS[clip]
	var speed: float = def[0]
	var angle := speed * t / CIRCLE_RADIUS
	var from := _fig.position
	if speed > 0.0:
		_fig.position = Vector3(sin(angle), 0.0, -cos(angle)) * CIRCLE_RADIUS
		_fig.rotation.y = -angle
	var motion: Dictionary = (def[1] as Dictionary).duplicate()
	motion["alive"] = true
	motion["speed"] = speed
	motion["velocity"] = (_fig.position - from) * float(fps)
	if clip == "jump":
		_fig.position.y = maxf(0.0, 0.9 * sin(fposmod(t, 0.6) / 0.6 * PI))
		motion["vertical"] = 3.0 if fposmod(t, 0.6) < 0.3 else -3.0
	_fig.set_motion(motion)
	_fig.animate(speed, 1.0 / float(fps))


func _grounded(item: String, clip: String, _t: float) -> bool:
	return clip != "jump" or not item.begins_with(AVATAR_PREFIX)


func _drive(item: String, clip: String, t: float, _frame: int) -> void:
	if item.begins_with(AVATAR_PREFIX):
		_drive_avatar(clip, t)
		return
	var speed: float = PACE[clip]
	if speed <= 0.0:
		return
	var angle := speed * t / CIRCLE_RADIUS
	_npc.position = Vector3(sin(angle), 0.0, -cos(angle)) * CIRCLE_RADIUS
	# Faces along the circle (its tangent), as a walker does: facing the centre would be a sidestep.
	_npc.rotation.y = -angle - PI / 2.0


## The victim's eye at the circle's centre, looking at the monster.
func _place_first_person(item: String) -> void:
	first_person.global_position = Vector3(0.0, 1.6, 0.0)
	first_person.look_at(_subject(item).global_position + Vector3(0.0, 1.0, 0.0))
