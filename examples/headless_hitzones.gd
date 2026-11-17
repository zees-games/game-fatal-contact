extends DotGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcContent := preload("../game/fc_content.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcPlayerTunables := preload("../game/fc_player_tunables.gd")

## Hit zones, damage and bot fairness, measured: what one round of every firearm does to each
## zone of a fresh player, and what each bot difficulty lands on a target (hit share, head share,
## damage rate) with the recoil control it is given.

const TICK_RATE := FcContent.TICK_RATE
const ATTACKER := 1
const TARGET := 2
const ZONES := {"head": 1.62, "neck": 1.46, "chest": 1.15, "stomach": 0.85, "leg": 0.5}
const FIREARMS: PackedStringArray = [
	"pistol", "revolver", "derringer", "machine_pistol", "smg", "carbine", "rifle", "bullpup", "burst_rifle",
	"battle_rifle", "lmg", "minigun", "marksman", "sniper", "shotgun", "drum_shotgun",
]
## Automatics and the starting sidearm: none may kill a fresh player with one round anywhere.
const NO_ONE_SHOT: PackedStringArray = ["machine_pistol", "smg", "carbine", "rifle", "bullpup", "burst_rifle", "lmg", "minigun", "pistol"]
const BOT_SECONDS := 12.0
const BOT_RANGE := 12.0
## Bots aim at the chest, so a head hit only comes of recoil and spread: more than this share of a bot's hits in the
## head (measured 0 to 21%) would be the one-shot headshots owners report.
const BOT_MAX_HEAD_SHARE := 0.30
## Shots to kill a fresh player (100 health, no armour) at 10 m, per weapon: [head min, head max, chest min, chest max].
## Every round of a shotgun counts as all its pellets on the zone. The bands are what an FPS player expects:
## automatics need three or more head rounds (so one head and one body round never kill) and four to six to the
## body (the minigun trades damage for rate), heavy single shots two to the head, and only the sniper, the
## marksman, the derringer and a point-blank shotgun kill with one round to the head.
const STK_BOUNDS := {
	"pistol": [3, 4, 4, 6], "revolver": [2, 2, 3, 3], "derringer": [1, 1, 2, 2],
	"machine_pistol": [3, 5, 6, 8], "smg": [3, 4, 5, 7], "carbine": [3, 4, 4, 6], "rifle": [3, 3, 4, 6],
	"bullpup": [3, 4, 4, 6], "burst_rifle": [3, 3, 4, 6], "battle_rifle": [2, 2, 3, 4], "lmg": [3, 4, 4, 6],
	"minigun": [4, 6, 8, 11], "marksman": [1, 1, 2, 2], "sniper": [1, 1, 1, 1], "shotgun": [1, 1, 1, 2],
	"drum_shotgun": [1, 2, 2, 3],
}
## How far each weapon's chest shots-to-kill may grow from 10 m to 70 m (falloff) and with full armour.
const STK_FAR_GROWTH := 2.0
const STK_ARMOUR_GROWTH := 2.0

const CHECKS := 10
const SECTIONS := 4

var _entered := 0
var _completed := 0
var _game: FcGame = null
var _hits: Array[DotDamage] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless hit zones and bot fairness")
	FcBots.think_every = 1
	FcBots.think_near = 0.0
	await _boot()
	await _table()
	_shots_to_kill()
	await _bots()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _boot() -> void:
	_game = FcGame.new()
	_game.name = "Arena"
	_game.tick_rate = TICK_RATE
	_game.score_limit = 0
	_game.time_limit_sec = 0.0
	_game.headless = true
	_game.is_authority = true
	_game.register_service = false
	add_child(_game)
	var map := FcMap.new()
	map.id = &"hitzone_lane"
	map.display_name = "hitzone_lane"
	map.extent = 150.0
	map.wall_height = 8.0
	var _p: RefCounted = map.add_perimeter()
	var _s1: RefCounted = map.add_spawn(Transform3D(Basis(), Vector3(0.0, 0.05, 0.0)))
	var _s2: RefCounted = map.add_spawn(Transform3D(Basis(), Vector3(5.0, 0.05, 0.0)))
	var ready := _game.setup(map)
	_check(ready.ok, "the arena sets up", str(ready.error))
	_game.match_node.rules.warmup_sec = 0.0
	_game.match_node.rules.countdown_sec = 0.0
	var _a := _game.add_player(ATTACKER, "Shooter")
	var _b := _game.add_player(TARGET, "Target")
	_game.start(0)
	_game.tick({})
	_game.combat.damage_applied.connect(func(d: DotDamage) -> void:
		if d.victim == TARGET:
			_hits.append(d))
	await get_tree().physics_frame


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


static func angles_to(from: Vector3, to: Vector3) -> Vector2:
	var d := (to - from).normalized()
	return Vector2(rad_to_deg(atan2(-d.x, -d.z)), rad_to_deg(asin(d.y)))


## Both whole (health and armour as a spawn gives them), [param dist] metres apart along -Z.
func _place(dist: float, weapon: StringName = &"") -> void:
	var tick: int = _game.current_tick()
	var shooter: FcPlayer = _game.player_for(ATTACKER)
	var target: FcPlayer = _game.player_for(TARGET)
	shooter.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -20.0)), tick)
	target.spawn(Transform3D(Basis(), Vector3(-10.0, 0.05, -20.0 - dist)), tick)
	if weapon == &"":
		shooter.give_default_loadout()
	else:
		shooter.arsenal.clear()
		var _given := shooter.arsenal.give(weapon)
		shooter.hold(shooter.arsenal.catalogue.get_def(weapon).slot)
	shooter.arsenal.disabled = false
	for _i in 48:
		_game.tick({})


func _aim_at(height: float, press: bool) -> Array:
	var shooter: FcPlayer = _game.player_for(ATTACKER)
	var target: FcPlayer = _game.player_for(TARGET)
	var k := FcPlayerTunables.body_scale()
	var aim := angles_to(shooter.muzzle_position(), target.global_position + Vector3.UP * height * k)
	var m := DotFpsCommand.new()
	m.yaw = aim.x
	m.pitch = aim.y
	var w := DotWeaponCommand.new()
	w.buttons = DotWeaponCommand.BUTTON_ATTACK if press else 0
	return [m, w]


## One trigger pull at [param zone] of a target that cannot die (so a lethal round does not respawn it), wearing
## [param armour] (a spawn wears none; armour comes from a loadout item or a streak); the damage events it caused.
func _one_round(weapon: StringName, zone: String, dist: float, armour: float) -> Array[DotDamage]:
	_place(dist, weapon)
	var health: DotHealth = _game.combat.health_of(TARGET)
	health.health = 1.0e7
	health.armour = 0.0
	health.max_armour = maxf(health.max_armour, armour)
	var _worn := health.add_armour(armour)
	for _i in 4:
		_game.tick({ATTACKER: _aim_at(ZONES[zone], false)})
	_hits.clear()
	_game.tick({ATTACKER: _aim_at(ZONES[zone], true)})
	for _i in 3:
		_game.tick({ATTACKER: _aim_at(ZONES[zone], false)})
	await get_tree().physics_frame
	var out: Array[DotDamage] = []
	out.assign(_hits)
	return out


## The most health one round took (a shotgun's pellets on one tick are one round, a burst's rounds are not).
static func round_loss(got: Array[DotDamage]) -> float:
	var by_tick := {}
	for d in got:
		by_tick[d.tick] = by_tick.get(d.tick, 0.0) + d.health_lost
	var most := 0.0
	for t: int in by_tick:
		most = maxf(most, by_tick[t])
	return most


func _table() -> void:
	_place(10.0)
	var target: FcPlayer = _game.player_for(TARGET)
	var spawn_health: float = target.health.health
	print("")
	print("    a spawn: health %.0f armour %.0f (max %.0f), head x%.2f neck x%.2f" % [
		spawn_health, target.health.armour, target.health.max_armour, _head_mult(),
		_game.combat.resolver.hit_groups.multiplier(DotHitGroup.NECK)])
	for armour in [0.0, 100.0]:
		_section("one round of every firearm at 10 m, armour %.0f: raw / health lost / zone (! = one round kills)" % armour)
		var dead_in_one := PackedStringArray()
		var header := "    %-15s" % "weapon"
		for zone: String in ZONES:
			header += " %-17s" % zone
		print(header)
		for id in FIREARMS:
			var line := "    %-15s" % id
			for zone: String in ZONES:
				var got: Array[DotDamage] = await _one_round(StringName(id), zone, 10.0, armour)
				var amount := 0.0
				var group := "-"
				for d in got:
					amount += d.amount
					group = String(d.hit_group)
				var lost := round_loss(got)
				var lethal := lost >= spawn_health
				line += " %-17s" % ("%.0f/%.0f/%s%s" % [amount, lost, group, "!" if lethal else ""])
				if lethal and NO_ONE_SHOT.has(id):
					dead_in_one.append("%s@%s" % [id, zone])
			print(line)
		_check(dead_in_one.is_empty(), "no automatic or the pistol kills with one round (armour %.0f)" % armour, ",".join(dead_in_one))
		_completed += 1


## Shots to kill per weapon and body part, deterministic: every round lands where it is meant to, so the numbers are
## the damage data's (catalogue tuning with FC's overrides, the hit-group multipliers from cfg, falloff, armour and the
## game's adjust hook), not the trace's spread. TTK is the time from the first to the killing round at the weapon's
## refire interval.
func _shots_to_kill() -> void:
	var catalogue := FcPlayer.weapon_catalogue()
	_section("shots to kill (TTK ms) per body part at 10 m, chest at 40 / 70 m and with armour 100; head x%.2f leg x%.2f" % [
		_head_mult(), _game.combat.resolver.hit_groups.multiplier(DotHitGroup.LEG)])
	print("    %-15s %-7s %-12s %-12s %-12s %-6s %-6s %-6s" % ["weapon", "damage", "head", "chest", "leg", "40 m", "70 m", "armour"])
	var head_bad := PackedStringArray()
	var chest_bad := PackedStringArray()
	var order_bad := PackedStringArray()
	var far_bad := PackedStringArray()
	var armour_bad := PackedStringArray()
	for id: String in STK_BOUNDS:
		var def := catalogue.get_def(StringName(id))
		var b: DotWeaponBallistics = def.tuning as DotWeaponBallistics if def != null else null
		if b == null:
			head_bad.append("%s: no hitscan ballistics" % id)
			continue
		var interval := def.ticks_at(def.use_interval_ticks, TICK_RATE)
		var head := _rounds_to_kill(b, DotHitGroup.HEAD, 10.0, 0.0)
		var chest := _rounds_to_kill(b, DotHitGroup.CHEST, 10.0, 0.0)
		var leg := _rounds_to_kill(b, DotHitGroup.LEG, 10.0, 0.0)
		var mid := _rounds_to_kill(b, DotHitGroup.CHEST, 40.0, 0.0)
		var far := _rounds_to_kill(b, DotHitGroup.CHEST, 70.0, 0.0)
		var armoured := _rounds_to_kill(b, DotHitGroup.CHEST, 10.0, 100.0)
		var ttk := func(n: int) -> String: return "%d (%.0f)" % [n, 1000.0 * (n - 1) * interval / TICK_RATE]
		var dmg := "%.0f" % b.damage if b.pellets == 1 else "%.0fx%d" % [b.damage, b.pellets]
		print("    %-15s %-7s %-12s %-12s %-12s %-6d %-6d %-6d" % [id, dmg, ttk.call(head), ttk.call(chest), ttk.call(leg), mid, far, armoured])
		var band: Array = STK_BOUNDS[id]
		if head < int(band[0]) or head > int(band[1]):
			head_bad.append("%s %d not %d-%d" % [id, head, band[0], band[1]])
		if chest < int(band[2]) or chest > int(band[3]):
			chest_bad.append("%s %d not %d-%d" % [id, chest, band[2], band[3]])
		if not (head <= chest and chest <= leg):
			order_bad.append("%s %d/%d/%d" % [id, head, chest, leg])
		if far == 0 or float(far) > STK_FAR_GROWTH * chest:
			far_bad.append("%s %d at 70 m vs %d" % [id, far, chest])
		if armoured == 0 or float(armoured) > STK_ARMOUR_GROWTH * chest:
			armour_bad.append("%s %d armoured vs %d" % [id, armoured, chest])
	_check(head_bad.is_empty(), "every firearm's head shots-to-kill is in its band (automatics need 3 or more)", ", ".join(head_bad))
	_check(chest_bad.is_empty(), "every firearm's chest shots-to-kill is in its band", ", ".join(chest_bad))
	_check(order_bad.is_empty(), "the head kills in no more rounds than the chest, the chest in no more than the leg", ", ".join(order_bad))
	_check(far_bad.is_empty(), "falloff at 70 m at most %.0fx the chest rounds at 10 m" % STK_FAR_GROWTH, ", ".join(far_bad))
	_check(armour_bad.is_empty(), "full armour at most %.0fx the chest rounds" % STK_ARMOUR_GROWTH, ", ".join(armour_bad))
	_completed += 1


## Rounds of [param b] at [param group], [param dist] metres away, that kill a fresh player wearing [param armour],
## through the live resolver and a fresh [DotHealth] built like the target's; 0 when a hundred rounds do not.
func _rounds_to_kill(b: DotWeaponBallistics, group: StringName, dist: float, armour: float) -> int:
	var combat: DotCombatManager = _game.combat
	var type: DotDamageType = b.damage_type if b.damage_type != null else combat.damage_type(&"")
	var live: DotHealth = combat.health_of(TARGET)
	var health := DotHealth.new()
	health.max_health = live.max_health
	health.max_armour = maxf(live.max_armour, armour)
	health.reset(0)
	var _worn := health.add_armour(armour)
	var tick: int = _game.current_tick()
	var rounds := 0
	while health.alive and rounds < 100:
		rounds += 1
		for _p in b.pellets:
			var d := DotDamage.make(ATTACKER, TARGET, b.damage_at(1.0) * combat.config.damage_scale, type)
			d.hit_group = group
			d.distance = dist
			d.tick = tick + rounds
			var _applied := health.apply(combat.resolver.resolve(d))
	var dead := not health.alive
	health.free()
	return rounds if dead else 0


func _head_mult() -> float:
	return _game.combat.resolver.hit_groups.multiplier(DotHitGroup.HEAD)


## The real brain at each difficulty, with the rifle, against a still and a strafing target: the share of rounds
## that land, of those in the head, and the damage rate while the trigger is down.
func _bots() -> void:
	_section("bots by difficulty: rifle at %.0f m, %.0f s each" % [BOT_RANGE, BOT_SECONDS])
	var settings := DotBotSettings.of(_game)
	var shares := PackedFloat32Array()
	for preset: String in DotBotProfile.PRESETS:
		shares.append(float(FcBots.RECOIL_CONTROL.get(preset, -1.0)))
	var worst_head := 0.0
	var rising := true
	for i in range(1, shares.size()):
		rising = rising and shares[i] > shares[i - 1] and shares[i] < 1.0
	_check(rising, "bots hold recoil better as difficulty rises, and none perfectly", str(shares))
	for preset: String in DotBotProfile.PRESETS:
		for strafing in [false, true]:
			var _set := settings.set_difficulty(preset)
			var mind := FcBots.Mind.new()
			mind.seed = 7
			_place(BOT_RANGE)
			var bot: FcPlayer = _game.player_for(ATTACKER)
			_game.shot_stats.reset()
			_hits.clear()
			var ticks := int(BOT_SECONDS * TICK_RATE)
			for i in ticks:
				var tick: int = _game.current_tick()
				var m := DotFpsCommand.new()
				if strafing:
					m.move = Vector2(1.0 if (i / 24) % 2 == 0 else -1.0, 0.0)
				_game.tick({ATTACKER: FcBots.think(_game, bot, mind, tick, float(TICK_RATE)), TARGET: [m, DotWeaponCommand.new()]})
				_game.combat.health_of(TARGET).health = 1.0e7
				if i % 16 == 0:
					await get_tree().physics_frame
			var t: Dictionary = _game.shot_stats.total([ATTACKER])
			var heads := 0
			var dealt := 0.0
			for d in _hits:
				dealt += d.amount
				if d.is_headshot():
					heads += 1
			var fired := maxi(int(t["fired"]), 1)
			if _hits.size() >= 8:
				worst_head = maxf(worst_head, float(heads) / _hits.size())
			print("    %-9s %-9s fired %4d landed %5.1f%% head %5.1f%% of hits, raw %.0f/s" % [
				preset, "strafing" if strafing else "still", fired, 100.0 * _hits.size() / fired,
				100.0 * heads / maxf(_hits.size(), 1.0), dealt / BOT_SECONDS])
	_check(worst_head <= BOT_MAX_HEAD_SHARE, "no bot difficulty lands more than %.0f%% of its hits in the head" % (100.0 * BOT_MAX_HEAD_SHARE), "worst %.1f%%" % (100.0 * worst_head))
	var _back := settings.set_difficulty(DotBotProfile.DEFAULT_PRESET)
	_completed += 1
