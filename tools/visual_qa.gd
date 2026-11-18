extends DotGameVisualQaCapture

## FC's visual QA capture for the horde monsters (npcs/): each kind idles, walks and runs a circle on the default stage,
## seen from the victim's eye, behind-right and the front, at 60 fps. The loop and the checklist are dot-game's
## docs/visual-qa.md; the weapons and the player's own locomotion are tools/anim_review.gd (docs/anim-review.md).
## A monster's figure animates from how far its body moves (`auto_animate`), so a clip moves the body at that pace.
##   bash tools/visual_qa_shot.sh [--only grunt,brute] [--clips walk,run]

const KINDS: PackedStringArray = ["grunt", "gunner", "brute", "stalker"]
## Metres per second for each clip: the horde's walk and run pace.
const PACE := {"idle": 0.0, "walk": 1.4, "run": 5.0}
const CIRCLE_RADIUS := 3.0

var _npc: Node3D = null
var _kind := ""


func _items() -> PackedStringArray:
	return KINDS


func _clips(_item: String) -> PackedStringArray:
	return PackedStringArray(PACE.keys())


func _stage(item: String, clip: String) -> DotResult:
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
	return DotResult.success(clip)


func _subject(_item: String) -> Node3D:
	return _npc


func _seconds(_item: String, _clip: String) -> float:
	return 3.0


func _drive(_item: String, clip: String, t: float, _frame: int) -> void:
	var speed: float = PACE[clip]
	if speed <= 0.0:
		return
	var angle := speed * t / CIRCLE_RADIUS
	_npc.position = Vector3(sin(angle), 0.0, -cos(angle)) * CIRCLE_RADIUS
	_npc.rotation.y = -angle


## The victim's eye at the circle's centre, looking at the monster.
func _place_first_person(_item: String) -> void:
	first_person.global_position = Vector3(0.0, 1.6, 0.0)
	first_person.look_at(_npc.global_position + Vector3(0.0, 1.0, 0.0))
