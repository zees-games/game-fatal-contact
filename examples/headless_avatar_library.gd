extends Node

## The avatar library as Fatal Contact uses it, offline: the app id on every call, the app's emote / pose / gesture and
## wearable switches honoured, 0 = unlimited and over the cap refused (never trimmed), and the loadout limits.
## godot --headless --path . res://examples/headless_avatar_library.tscn

const AvatarLibrary := preload("res://game/fc_avatar_library.gd")
const CHECKS := 28

var _passed := 0
var _failed := 0


## Records each request and answers from a canned body.
class FakeHttp extends DotHttp:
	var got: Array[String] = []
	var puts: Array = []
	var body: Variant = {}

	func get_json(path: String, _headers: Dictionary = {}) -> DotResult:
		got.append(path)
		return DotResult.success(body)

	func put_json(path: String, b: Variant, _headers: Dictionary = {}) -> DotResult:
		puts.append([path, b])
		return DotResult.success({"ok": true})


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("Fatal Contact avatar library self-test")
	var keep_entries := DotGameAvatarLoadoutMessage.max_entries
	var keep_kind := DotGameAvatarLoadouts.max_per_kind
	var keep_app := AvatarLibrary.app_id
	await _test_app_id()
	await _test_actions()
	await _test_wearables()
	_test_limits()
	DotGameAvatarLoadoutMessage.max_entries = keep_entries
	DotGameAvatarLoadouts.max_per_kind = keep_kind
	AvatarLibrary.app_id = keep_app
	_check(_passed + _failed + 1 == CHECKS, "every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS])
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL: %s %s" % [what, detail])


func _rules(d: Dictionary) -> DotAvatarAppRules:
	return DotAvatarAppRules.from_dict(d, 7).value


func _test_app_id() -> void:
	print("the app id")
	AvatarLibrary.app_id = 0
	var res: DotResult = AvatarLibrary.client_for(null, "https://site.test")
	_check(not res.ok and res.error.code == DotError.CODE_INVALID, "an unset app id is refused")
	AvatarLibrary.app_id = 7
	var http := FakeHttp.new()
	add_child(http)
	res = AvatarLibrary.client_for(http, "https://site.test")
	_check(res.ok and res.value.app_id == 7, "a set app id makes a client for it")
	http.body = {"max": 0, "actions": []}
	var read: DotResult = await AvatarLibrary.read_actions(res.value, _rules({}))
	_check(read.ok and http.got[0] == "https://site.test/api/app/v1/avatar/actions?appId=7", "the read names the app", str(http.got))
	http.queue_free()


func _test_actions() -> void:
	print("actions follow the app's switches")
	AvatarLibrary.app_id = 7
	var http := FakeHttp.new()
	add_child(http)
	var client: DotAvatarLibraryClient = AvatarLibrary.client_for(http, "https://site.test").value
	http.body = {"max": 0, "actions": [
		{"id": 1, "kind": "EMOTE"}, {"id": 2, "kind": "POSE"}, {"id": 3, "kind": "GESTURE"}, {"id": 4, "kind": "EMOTE"},
	]}
	var all_on := _rules({})
	var res: DotResult = await AvatarLibrary.read_actions(client, all_on)
	_check(res.ok and res.value["max"] == 0 and res.value["by_kind"][&"emote"].size() == 2, "all on: every kind is offered")
	var rules := _rules({"emotesEnabled": false})
	res = await AvatarLibrary.read_actions(client, rules)
	_check(res.ok and res.value["by_kind"][&"emote"].is_empty() and res.value["by_kind"][&"pose"].size() == 1, "emotes off: emptied, the rest kept")
	_check(res.value["by_kind"].has(&"gesture"), "an off kind is an empty list, not missing")
	res = await AvatarLibrary.read_actions(client, _rules({"actionsEnabled": false}))
	_check(res.ok and res.value["by_kind"][&"pose"].is_empty() and res.value["by_kind"][&"gesture"].is_empty(), "actions off: every kind empty")
	res = await AvatarLibrary.read_actions(client, _rules({"posesEnabled": false, "gesturesEnabled": false}))
	_check(res.ok and res.value["by_kind"][&"emote"].size() == 2 and res.value["by_kind"][&"pose"].is_empty(), "poses and gestures off alone")
	var puts_before := http.puts.size()
	res = await AvatarLibrary.equip_actions(client, rules, DotAvatarAppRules.EMOTE, [1], 0)
	_check(not res.ok and res.error.code == DotError.CODE_INVALID and res.error.detail == "emote", "equipping an off kind is refused")
	_check(res.error.message.contains("emotesEnabled"), "and names the setting", res.error.message)
	_check(http.puts.size() == puts_before, "with nothing sent")
	res = await AvatarLibrary.equip_actions(client, rules, &"dance", [1], 0)
	_check(not res.ok and res.error.code == DotError.CODE_INVALID, "an unknown kind is refused")
	res = await AvatarLibrary.equip_actions(client, rules, DotAvatarAppRules.POSE, [2, 5], 0)
	_check(res.ok and http.puts[-1][1] == {"kind": "POSE", "actionIds": [2, 5], "appId": 7}, "an on kind is equipped with the app id", str(http.puts))
	res = await AvatarLibrary.equip_actions(client, rules, DotAvatarAppRules.POSE, range(500), 0)
	_check(res.ok and http.puts[-1][1]["actionIds"].size() == 500, "max 0 is unlimited, nothing trimmed")
	puts_before = http.puts.size()
	res = await AvatarLibrary.equip_actions(client, rules, DotAvatarAppRules.POSE, [1, 2, 3], 2)
	_check(not res.ok and res.error.code == DotError.CODE_QUOTA and http.puts.size() == puts_before, "over the cap is quota, nothing sent, nothing trimmed")
	http.body = {"max": -3, "actions": []}
	res = await AvatarLibrary.read_actions(client, rules)
	_check(not res.ok, "a bad max from the site fails loudly")
	http.queue_free()


func _test_wearables() -> void:
	print("wearables follow the app's rules")
	AvatarLibrary.app_id = 7
	var http := FakeHttp.new()
	add_child(http)
	var client: DotAvatarLibraryClient = AvatarLibrary.client_for(http, "https://site.test").value
	http.body = {"wearables": [{"id": 1, "slot": "hat"}, {"id": 2, "slot": "back"}, {"id": 3, "slot": "hat"}]}
	var rules := _rules({"rules": [{"targetKind": "WEARABLE", "targetId": "2", "enabled": false}]})
	var res: DotResult = await AvatarLibrary.read_wearables(client, rules)
	_check(res.ok and res.value.size() == 2 and res.value[0]["id"] == 1 and res.value[1]["id"] == 3, "a wearable the rules hide is dropped")
	res = await AvatarLibrary.read_wearables(client, _rules({"wearablesEnabled": false}))
	_check(res.ok and res.value.is_empty(), "wearables off: none offered")
	var puts_before := http.puts.size()
	res = await AvatarLibrary.set_wearable(client, rules, 2, true)
	_check(not res.ok and res.error.code == DotError.CODE_INVALID and http.puts.size() == puts_before, "putting on a hidden wearable is refused, nothing sent")
	res = await AvatarLibrary.set_wearable(client, rules, 2, false)
	_check(res.ok and http.puts[-1][1] == {"wearableId": 2, "equipped": false, "appId": 7}, "taking a hidden one off is allowed")
	res = await AvatarLibrary.set_wearable(client, rules, 3, true)
	_check(res.ok and http.puts[-1][1] == {"wearableId": 3, "equipped": true, "appId": 7}, "an offered one goes on with the app id")
	res = await AvatarLibrary.set_wearable(client, _rules({"wearablesEnabled": false}), 1, true)
	_check(not res.ok, "with wearables off nothing goes on")
	http.queue_free()


func _test_limits() -> void:
	print("the loadout limits")
	var res: DotResult = AvatarLibrary.apply_loadout_limits(0, 0)
	_check(res.ok and DotGameAvatarLoadoutMessage.max_entries == 0 and DotGameAvatarLoadouts.max_per_kind == 0, "0 and 0 mean unlimited")
	res = AvatarLibrary.apply_loadout_limits(12, 5)
	_check(res.ok and DotGameAvatarLoadoutMessage.max_entries == 12 and DotGameAvatarLoadouts.max_per_kind == 5, "a limit is applied to dot-game")
	res = AvatarLibrary.apply_loadout_limits(-1, 5)
	_check(not res.ok and DotGameAvatarLoadoutMessage.max_entries == 12, "a negative limit is refused and nothing changes")
	res = AvatarLibrary.apply_loadout_limits(3, -1)
	_check(not res.ok and DotGameAvatarLoadouts.max_per_kind == 5, "likewise for the per-kind limit")
	_check(AvatarLibrary.KINDS.size() == 3, "three action kinds")
