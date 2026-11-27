extends Node

const FcContent := preload("../game/fc_content.gd")

## The groups a web client starts on (web_early_groups.json) are the default loadout's, so the first seconds of play draw every weapon the
## player carries; the rest are topped up after the gate opens. Run: [code]./game.sh --no-parse test headless_web_early_groups[/code]

var _checks := 0
var _failed := 0


func _ready() -> void:
	var listed := FileAccess.get_file_as_string("res://web_early_groups.json")
	var data: Variant = JSON.parse_string(listed)
	_check(data is Dictionary and (data as Dictionary).has("fc_weapons"), "the file names the fc_weapons addon")
	var named := PackedStringArray()
	if data is Dictionary:
		for g: Variant in (data as Dictionary).get("fc_weapons", []):
			named.append(str(g))
	var need := AwWeaponGroups.groups_for(FcContent.default_loadout())
	var a := Array(named)
	var b := Array(need)
	a.sort()
	b.sort()
	_check(a == b, "early groups %s equal the default loadout's %s" % [str(a), str(b)])
	print("web_early_groups: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: " + what)
