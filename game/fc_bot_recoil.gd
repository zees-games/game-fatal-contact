extends RefCounted
## A bot's next recoil as numbers: the row gs-sim's [code]GSSimBotCoast[/code] reads and the script preview of it,
## the same to the bit (headless_botthreads compares them). FcBots turns a firing bot's aim back by it.

## Weapon id -> recoil seed, for [method _seed].
static var _seeds: Dictionary = {}


## The numbers [method preview] works [param arsenal]'s next recoil from, [param taken] the share kept; empty with
## recoil patterns off. Order (gs-sim's [code]recoil_preview[/code]): reset, recovery x2, build x2, build max, pitch x2,
## yaw x2, camera share, follow, seed, the burst's last tick, n, ax, ay, taken (b.* then rules.* in each pair).
static func row(arsenal: GSWeaponArsenal, taken: float) -> PackedFloat64Array:
	var rr := GSWeaponRecoilRules.of(arsenal)
	var slot: GSWeaponSlot = arsenal.current()
	if rr == null or slot == null or slot.behaviour == null or slot.behaviour.def == null:
		return PackedFloat64Array()
	var b := slot.behaviour.def.tuning as GSWeaponBallistics
	if b == null:
		return PackedFloat64Array()
	var state: Dictionary = slot.behaviour.state
	return PackedFloat64Array([rr.reset, b.recoil_recovery, rr.recovery, b.recoil_build, rr.build, b.recoil_build_max,
		b.recoil_pitch, rr.vertical, b.recoil_yaw, rr.horizontal, b.recoil_camera if b.recoil_camera >= 0.0 else rr.punch,
		rr.follow, _seed(b, slot.behaviour.def.id), int(state.get(&"recoil_tick", -1000000)),
		int(state.get(&"recoil_n", 0)), float(state.get(&"recoil_ax", 0.0)), float(state.get(&"recoil_ay", 0.0)), taken])


## Degrees (pitch up, yaw left) the next bullet is turned off its aim, as [method GSWeaponRecoilRules.apply] works it
## at [param tick] (without the posture), times the row's share.
static func preview(r: PackedFloat64Array, tick: int, tick_rate: float) -> Vector2:
	var elapsed := maxf(float(tick - int(r[13])) / maxf(tick_rate, 1.0), 0.0)
	var n := int(r[14]) if elapsed <= r[0] else 0
	var residual := Vector2(r[15], r[16]) * exp(-r[1] * r[2] * elapsed)
	var grow := 1.0 + minf(r[3] * r[4] * float(n), r[5] * r[4])
	var kick := Vector2(r[6] * r[7] * grow, r[8] * r[9] * grow * GSWeaponRecoilRules.drift(int(r[12]), n))
	var share := r[10]
	return ((residual + kick) * (1.0 - share) + residual * share * r[11]) * r[17]


## [method GSWeaponRecoilRules.seed_for], with the hash of a weapon id kept: it is worked from the id's bytes on every
## call, and a coasting bot asks for it each tick it holds the trigger.
static func _seed(b: GSWeaponBallistics, id: StringName) -> int:
	if b.recoil_seed != 0:
		return b.recoil_seed
	var cached: Variant = _seeds.get(id)
	if cached == null:
		cached = GSWeaponRecoilRules.seed_for(b, id)
		_seeds[id] = cached
	return cached
