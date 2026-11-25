extends Node

## Every weapon model dropped onto a stair run under many RNG seeds: time until it rests, within the bound the drop rules give (sv_weapon_drop_settle_max per fall, sv_weapon_drop_refall_max falls again). SEEDS=n sets the seed count; VERBOSE=1 prints every check.
## Deterministic: each seed seeds the drops' own stream (randomized otherwise); time is physics ticks, not the wall clock. Run: [code]godot --headless --path . res://examples/headless_weapondrop_settle.tscn[/code].

const FcWeaponRoles := preload("../game/fc_weapon_roles.gd")
## Support-check period (a rest may be woken by it) and the ticks a forced rest is grounded for.
const WAKE_EVERY_SEC := GSWeaponDrops.SUPPORT_EVERY
const GROUND_TICKS := 2
const TICKS := 64
## Seconds each seed is watched: a drop still moving after this counts as never settling.
const WATCH_SEC := 40.0
const LANES := 3

var _checks := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	Engine.physics_ticks_per_second = 64
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	if not condition or OS.get_environment("VERBOSE") != "":
		print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _floor(root: Node3D, pos: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	body.add_child(cs)
	root.add_child(body)
	body.position = pos


func _pct(sorted: Array, p: float) -> float:
	return float(sorted[mini(sorted.size() - 1, int(floor(p * sorted.size())))])


## Latest rest time the drop rules allow; 0 when a limit is 0 (no bound).
func _bound(rules: GSWeaponDropRules) -> float:
	if rules.settle_max_sec <= 0.0 or rules.refall_max <= 0:
		return 0.0
	return float(rules.refall_max + 1) * rules.settle_max_sec + float(rules.refall_max) * WAKE_EVERY_SEC + float(GROUND_TICKS + 1) / float(TICKS)


func _run() -> void:
	FcWeaponRoles.ensure()
	var ids: Array = AwWeaponArtTable.table().keys()
	ids.sort()
	var seeds := int(OS.get_environment("SEEDS")) if OS.get_environment("SEEDS") != "" else 6
	var times: Array = []
	var refalls: Array = []
	var worst := ["", 0.0]
	var never := 0
	var rules: GSWeaponDropRules = null
	for sd in seeds:
		seed(1000 + sd)
		var world := Node3D.new()
		add_child(world)
		_floor(world, Vector3(0, -0.5, 0), Vector3(80, 1, 40))
		for s in 12:
			_floor(world, Vector3(0, 0.18 * (s + 1) - 0.5, 0.3 * s + 0.15), Vector3(80, 1, 0.3))
		var drops := GSWeaponDrops.new()
		drops.is_authority = true
		drops.draws = true
		drops.look_of = func(w: StringName) -> Node3D:
			var art: Variant = AwWeaponArtTable.table().get(w)
			if not (art is AwWeaponVisual):
				return null
			return (load("res://game/fc_weapon_drop_wiring.gd") as GDScript).call("look", w)
		drops.rules.lifetime = 0.0
		drops.rules.max_count = 0
		drops.rules.max_active = 0
		drops.seed_rng(1000 + sd)
		rules = drops.rules
		var bad: Array = drops.rules.problems()
		_check(bad.is_empty(), "the drop rules are valid", "; ".join(bad))
		world.add_child(drops)
		var info := {}
		var i := 0
		for lane in LANES:
			for w: StringName in ids:
				var x := float(i) * 0.9 - 35.0
				var z := 0.2 + randf() * 3.0
				var h := 0.18 * clampf(floorf(z / 0.3) + 1.0, 0.0, 12.0)
				var id := drops.spawn({"id": w, "magazine": 1, "reserve": 1}, Vector3(x, 1.2 + h, z), Vector3(0.3, 0.0, 0.3), 0)
				info[id] = {"w": w, "was": false, "last": 0.0}
				i += 1
		var quiet := 0
		for t in int(WATCH_SEC * 64.0):
			await get_tree().physics_frame
			var all_rest := true
			for id: int in info:
				var r := bool(drops._entries[id]["rest"])
				if r and not bool(info[id]["was"]):
					info[id]["last"] = float(t + 1) / 64.0
				info[id]["was"] = r
				all_rest = all_rest and r
			quiet = quiet + 1 if all_rest else 0
			if quiet >= 256:
				break
		for id: int in info:
			var e: Dictionary = drops._entries[id]
			var at := WATCH_SEC
			if bool(e["rest"]):
				at = float(info[id]["last"])
			else:
				never += 1
			times.append(at)
			refalls.append(int(e.get("refalls", 0)))
			if at > float(worst[1]):
				worst = [info[id]["w"], at]
		world.queue_free()
		await get_tree().physics_frame
	times.sort()
	refalls.sort()
	print("settle: %d drops over %d seeds: p50 %.2fs p95 %.2fs p99 %.2fs max %.2fs (%s); refalls p95 %d max %d; never rested %d" % [times.size(), seeds, _pct(times, 0.5), _pct(times, 0.95), _pct(times, 0.99), times.back(), worst[0], _pct(refalls, 0.95), refalls.back(), never])
	_check(never == 0, "every drop came to rest", str(never))
	var bound := _bound(rules)
	if bound <= 0.0:
		print("settle: settle_max_sec %.2f / refall_max %d leave no bound; the distribution is only printed" % [rules.settle_max_sec, rules.refall_max])
	_check(bound <= 0.0 or float(times.back()) <= bound, "the slowest drop settled within the rules' bound %.2fs" % bound, "max %.2f (%s)" % [times.back(), worst[0]])
	_check(rules.refall_max <= 0 or int(refalls.back()) <= rules.refall_max + 1, "no drop fell again more than refall_max times", "max %d" % int(refalls.back()))
	print("weapondrop_settle: %d checks, %d failed" % [_checks, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
