extends RefCounted
## headless_botthreads' bit comparison of gs-sim's GSSimBotCoast against the script coast ([method FcBots._coast])
## and recoil preview ([method FcBotRecoil.preview]) over 400 random views and 400 random recoil rows.

const FcBots := preload("../game/fc_bots.gd")
const FcBotRecoil := preload("../game/fc_bot_recoil.gd")


## [values got, values wanted, index of the first difference (-1: none), text of that difference] from [param coast].
static func compare(coast: Object, tick_rate: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var views := PackedFloat32Array()
	var steps := PackedInt64Array()
	var recoil := PackedFloat64Array()
	var want := PackedFloat64Array()
	var tick := 50000
	var mind := FcBots.Mind.new()
	mind.last_move = GSFpsCommand.new()
	mind.last_fire = GSWeaponCommand.new()
	for k in 400:
		mind.view_from = Vector2(rng.randf_range(-900.0, 900.0), rng.randf_range(-89.0, 89.0))
		mind.view_to = Vector2(rng.randf_range(-900.0, 900.0), rng.randf_range(-89.0, 89.0)) if k % 7 != 0 else mind.view_from
		mind.every = rng.randi_range(1, 6)
		mind.last_think_tick = tick - rng.randi_range(0, mind.every - 1)
		views.append_array([mind.view_from.x, mind.view_from.y, mind.view_to.x, mind.view_to.y])
		steps.append_array([tick - mind.last_think_tick, mind.every])
		var pair := FcBots._coast(mind, tick)
		want.append((pair[0] as GSFpsCommand).yaw)
		want.append((pair[0] as GSFpsCommand).pitch)
	for k in 400:
		var row := PackedFloat64Array([rng.randf_range(0.05, 1.0), rng.randf_range(0.0, 12.0), rng.randf_range(0.0, 2.0),
			rng.randf_range(0.0, 0.3), rng.randf_range(0.0, 2.0), rng.randf_range(0.0, 2.0), rng.randf_range(0.0, 3.0),
			rng.randf_range(0.0, 2.0), rng.randf_range(-2.0, 2.0), rng.randf_range(0.0, 2.0), rng.randf_range(0.0, 1.0),
			rng.randf_range(0.0, 1.0), rng.randi() & 0x7fffffff, tick - rng.randi_range(0, 60) if k % 9 != 0 else -1000000,
			rng.randi_range(0, 30), rng.randf_range(-4.0, 4.0), rng.randf_range(-4.0, 4.0), rng.randf_range(0.0, 1.0)])
		recoil.append_array(row)
		var offset := FcBotRecoil.preview(row, tick, float(tick_rate))
		want.append(offset.x)
		want.append(offset.y)
	var got: PackedFloat64Array = coast.call(&"step", views, steps, recoil, tick, float(tick_rate))
	var first := -1
	for i in mini(got.size(), want.size()):
		if var_to_bytes(got[i]) != var_to_bytes(want[i]):
			first = i
			break
	var text := "" if first < 0 else ": %s vs %s" % [got[first], want[first]]
	return [got.size(), want.size(), first, text]
