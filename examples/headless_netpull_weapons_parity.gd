extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcPlayerNet := preload("../game/fc_player_net.gd")
const FcContent := preload("../game/fc_content.gd")
const Roles := preload("../game/fc_weapon_roles.gd")
const W := preload("../game/fc_net_pull_weapons.gd")
const FcNetCarry := preload("../game/fc_net_carry.gd")

## A player's weapon pull (FcPlayerNet.pull, cvars `sv_net_pull_weapons_native`, `sv_net_pull_content_native`): gs-sim's
## `GSSimFpsWeaponNet.pull` writes the same net_* weapon fields, net_weapon and wind-up as AwWeaponNet.pull and FcContent.weapon_index, to the
## bit, over seeded arsenals and rigs, either switch off, no rig, and every wire id. Without the library only the script lane runs, and the suite says so. A person's carry mask, kept until his arsenal
## changes (fc_net_carry.gd), equals FcContent.carry_mask through seeded gives and takes.

const STATES := 20000
const SEED := 6161
const FIELDS: Array[StringName] = [&"net_slot", &"net_fitted", &"net_fire_mode", &"net_magazine", &"net_reserve",
		&"net_reloading", &"net_switching", &"net_fire_seq", &"net_fire_kind", &"net_charge", &"net_weapon"]

var _checks := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _check(condition: bool, what: String, detail := "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _run() -> void:
	print("FC — weapon pull: native and script agree")
	var game := FcGame.new()
	game.name = "G"
	game.tick_rate = 64
	game.headless = true
	game.register_service = false
	game.mode = FcMode.team_deathmatch()
	add_child(game)
	_check(game.setup(FcMap.dm_atrium()).ok, "a game sets up")
	game.start(0)
	var _a := game.add_player(31, "A")
	game.tick({})
	var player := game.player_for(31)
	var rig: AwWeaponRig = player.weapons
	var arsenal: GSWeaponArsenal = player.arsenal
	_check(rig != null and rig.arsenal != null and arsenal != null and not arsenal._slots.is_empty(),
			"the player has a rig and an armed arsenal")
	var net := FcPlayerNet.new()
	var native := W.native() != null
	if not native:
		print("gs-sim has no GSSimFpsWeaponNet.pull: only the script lane is exercised")
	var was := [W.weapons_enabled, W.content_enabled]
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var keys: Array = arsenal._slots.keys()
	var differ := 0
	var native_ran := 0
	var expect_ran := 0
	var first := ""
	for i in STATES:
		var windup := _randomize(rig, arsenal, keys, rng)
		# Every seventh with content off, the next with weapons off: each switch stands alone.
		var weapons := i % 7 != 1
		var content := i % 7 != 0
		if weapons and content:
			expect_ran += 1
		_poison = i % 2 == 0
		var script := _lane(net, rig, arsenal, windup, false, false)
		var got := _lane(net, rig, arsenal, windup, weapons, content)
		if int(got[-1]) >= 0:
			native_ran += 1
		got.resize(FIELDS.size())
		script.resize(FIELDS.size())
		if var_to_bytes(got) != var_to_bytes(script):
			differ += 1
			if first == "":
				first = "state %d: script %s native %s" % [i, script, got]
	print("  %d states, %d with the wire number from the same gs-sim call" % [STATES, native_ran])
	var bare_same := true
	for poison in [false, true]:
		_poison = poison
		var bare := _lane(net, null, arsenal, 0.3, false, false)
		var bare_native := _lane(net, null, arsenal, 0.3, true, true)
		bare_same = bare_same and int(bare_native[-1]) == -1 \
				and var_to_bytes(bare.slice(0, FIELDS.size())) == var_to_bytes(bare_native.slice(0, FIELDS.size()))
	_check(bare_same,
			"without a rig both switches give gs-weapon's pull")
	if native:
		_check(native_ran == expect_ran, "every state with both switches on carried its wire number",
				"%d of %d" % [native_ran, expect_ran])
		_check(differ == 0, "native net_* equal the script's to the bit", "%d differ; %s" % [differ, first])
		var ids := Roles.wire_ids().duplicate()
		ids.append_array([&"", &"fc_no_such_weapon"])
		var wrong := 0
		for id in ids:
			if W.native().weapon_code(id) != FcContent.weapon_index(id):
				wrong += 1
		_check(wrong == 0, "every wire id, an empty and an unknown one map the same", "%d of %d wrong" % [wrong, ids.size()])
		_bench(net, rig, arsenal, keys, rng)
	W.weapons_enabled = was[0]
	W.content_enabled = was[1]
	var carry_wrong := _carry_wrong(arsenal, rng)
	_check(carry_wrong == 0, "the kept carry mask equals FcContent.carry_mask through gives and takes", "%d wrong" % carry_wrong)
	net.free()
	var expected := 7 if native else 4
	var ok := _failed == 0 and _checks == expected
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, expected])
	get_tree().quit(0 if ok else 1)


## How many reads of a kept carry mask differ from the walk, over seeded carried sets each read twice (the second
## from the kept mask), then a second arsenal handed in and the first one back.
func _carry_wrong(arsenal: GSWeaponArsenal, rng: RandomNumberGenerator) -> int:
	var carry := FcNetCarry.new()
	var full := FcContent.carry_mask(arsenal)
	var bits := FcContent.carry_bits()
	var all := (1 << bits) - 1
	var wrong := 0
	for _i in 400:
		FcContent.apply_carry(arsenal, (rng.randi() | (rng.randi() << 32)) & all)
		for _read in 2:
			if carry.mask(arsenal) != FcContent.carry_mask(arsenal):
				wrong += 1
	var other := GSWeaponArsenal.new()
	if carry.mask(other) != FcContent.carry_mask(other):
		wrong += 1
	other.free()
	FcContent.apply_carry(arsenal, full)
	if carry.mask(arsenal) != full:
		wrong += 1
	return wrong


## Seeds the arsenal and rig; returns the wind-up (negative half the time: not winding).
func _randomize(rig: AwWeaponRig, arsenal: GSWeaponArsenal, keys: Array, rng: RandomNumberGenerator) -> float:
	var pick := rng.randi() % 20
	arsenal._current = int(keys[rng.randi() % keys.size()]) if pick < 16 else [30, 40, -2, 99][pick - 16]
	var slot := arsenal.current()
	if slot != null:
		slot.magazine = rng.randi_range(-5, 700)
		slot.fire_mode_index = rng.randi_range(-2, 6)
		var pool := slot.def.ammo_type
		if pool != &"":
			arsenal.ammo().set_cap(pool, 5000)
			arsenal.ammo().set_count(pool, rng.randi_range(0, 3000))
	arsenal._reloading = rng.randi() % 3 == 0
	arsenal._switch_done_tick = 5 if rng.randi() % 4 == 0 else -1
	rig.fire_seq = rng.randi_range(-40, 100)
	rig.fire_kind = rng.randi_range(0, 5)
	# A third on the rounding halves of the 4-bit draw.
	rig.charge_shown = rng.randi_range(-3, 33) / 30.0 if rng.randi() % 3 == 0 else rng.randf_range(-0.5, 1.5)
	match rng.randi() % 4:
		0, 1:
			return -1.0
		2:
			return rng.randi_range(-2, 32) / 30.0
	return rng.randf_range(0.0, 1.3)


## The fields one lane writes from a poisoned start, then the code pull_weapons returned.
## Both lanes of one comparison start from the same poison, so a field neither writes still agrees; it alternates
## between states so a bool one lane writes and the other leaves is caught either way.
var _poison := false


func _lane(net: FcPlayerNet, rig: AwWeaponRig, arsenal: GSWeaponArsenal, windup: float, weapons: bool, content: bool) -> Array:
	for p in FIELDS:
		var v: Variant = net.get(p)
		net.set(p, _poison if v is bool else -7)
	W.weapons_enabled = weapons
	W.content_enabled = content
	var code := W.pull_weapons(net, rig, arsenal, windup)
	W.pull_content(net, arsenal, code)
	var out: Array = []
	for p in FIELDS:
		out.append(net.get(p))
	out.append(code)
	return out


func _bench(net: FcPlayerNet, rig: AwWeaponRig, arsenal: GSWeaponArsenal, keys: Array, rng: RandomNumberGenerator) -> void:
	var _w := _randomize(rig, arsenal, keys, rng)
	var us := []
	for lane in 2:
		W.weapons_enabled = lane == 1
		W.content_enabled = lane == 1
		var t := Time.get_ticks_usec()
		for k in 20000:
			W.pull_content(net, arsenal, W.pull_weapons(net, rig, arsenal, -1.0))
		us.append((Time.get_ticks_usec() - t) / 20000.0)
	print("  bench: script %.2f us, native %.2f us per pull" % [us[0], us[1]])
