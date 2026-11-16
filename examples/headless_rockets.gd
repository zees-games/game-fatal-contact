extends Node

const ArenaGame := preload("../game/arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaMode := preload("../game/arena_mode.gd")
const ArenaPlayer := preload("../game/arena_player.gd")
const ArenaAttach := preload("../game/arena_attach.gd")
const ArenaRocketJump := preload("../game/arena_rocket_jump.gd")
const ArenaProjectileView := preload("../game/arena_projectile_view.gd")
const ArenaProjectiles := preload("../game/arena_projectiles.gd")

## The launchers and grenades of fc-weapons level 27 through the whole FC game: the single-missile launcher's
## one-missile tube and bigger blast under `sv_rocket_*`, grenades bouncing off the floor under `sv_grenade_*`
## (a sticky still sticks), the Rocketjump warhead's damage cut, its blast throwing its own shooter up without
## hurting them while a plain missile hurts and does not throw, each launcher drawn with its own missile, and
## the loadout menu's Warhead row.
##
## [codeblock]
## godot --headless --path . res://examples/headless_rockets.tscn
## [/codeblock]

const TICK_RATE := 64
const EXPECTED_SECTIONS := 4
const EXPECTED_CHECKS := 33

var _checks := 0
var _failed := 0
var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _run() -> void:
	_check(ArenaRocketJump.supported(), "fc-weapons is at the level the rockets need", str(DotAddonApi.build_level("fc_weapons")))

	var game := ArenaGame.new()
	game.name = "G"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = ArenaMode.team_deathmatch()
	add_child(game)
	var ready := game.setup(ArenaMap.dm_atrium())
	_check(ready.ok, "a team game sets up", str(ready.error))
	# No warmup or countdown: the countdown holds everybody still and unhurtable.
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	game.start(0)

	for i in 2:
		var _added := game.add_player(10 + i, "P%d" % i)
	game.tick({})

	_test_rules(game)
	await _test_grenades(game)
	await _test_rocketjump(game, 10, 11)
	_test_view_and_menu(game)

	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	var ok := _failed == 0 and _entered == EXPECTED_SECTIONS and _finished == EXPECTED_SECTIONS and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	get_tree().quit(0 if ok else 1)


func _splash_radius(def: DotWeaponDef) -> float:
	var b := def.tuning as DotWeaponBallistics if def != null else null
	return b.splash_radius if b != null else -1.0


## Owner batch items 2 and 10: one missile with a bigger blast than the quad, and the warhead's cut, both cvars.
func _test_rules(game: ArenaGame) -> void:
	_entered += 1
	print("rules")
	var rules: RefCounted = game.rocket_rules
	var catalogue := ArenaPlayer.weapon_catalogue()
	var single := catalogue.get_def(&"launcher")
	var quad := catalogue.get_def(&"quad_launcher")

	_check(rules != null, "the game holds the sv_rocket rules")
	_check(single != null and single.magazine == 1, "the single-missile launcher fires one missile per load", str(single.magazine if single else -1))
	_check(_splash_radius(single) > _splash_radius(quad), "its blast is bigger than the quad launcher's", "%s > %s" % [_splash_radius(single), _splash_radius(quad)])

	_check(bool(rules.call(&"set_cvar", "sv_rocket_launcher_splash_radius", "7")), "sv_rocket_launcher_splash_radius is a cvar of the rules")
	game.apply_rocket_rules()
	_check(is_equal_approx(_splash_radius(catalogue.get_def(&"launcher")), 7.0), "a change reaches the shared catalogue", str(_splash_radius(catalogue.get_def(&"launcher"))))
	var _back: bool = rules.call(&"set_cvar", "sv_rocket_launcher_splash_radius", "5.5")
	game.apply_rocket_rules()

	var warhead := ArenaAttach.catalogue().get_attachment(ArenaRocketJump.ATTACHMENT)
	_check(warhead != null and is_equal_approx(float(warhead.scale.get("damage", 0.0)), 0.4), "the Rocketjump warhead cuts damage to 0.4", str(warhead.scale if warhead else {}))
	var _cut: bool = rules.call(&"set_cvar", "sv_rocket_jump_damage_scale", "0.25")
	game.apply_rocket_rules()
	_check(is_equal_approx(float(warhead.scale.get("splash_damage", 0.0)), 0.25), "sv_rocket_jump_damage_scale re-cuts the warhead", str(warhead.scale))
	_cut = rules.call(&"set_cvar", "sv_rocket_jump_damage_scale", "0.4")
	game.apply_rocket_rules()

	var fitted := _rocketjump_def()
	_check(ArenaRocketJump.is_rocketjump(fitted), "the fitted launcher carries the warhead")
	var base_splash := (single.tuning as DotWeaponBallistics).splash_damage
	var cut_splash := (fitted.tuning as DotWeaponBallistics).splash_damage
	_check(is_equal_approx(cut_splash, base_splash * 0.4), "and its blast does 0.4 of the plain one", "%s of %s" % [cut_splash, base_splash])
	_finished += 1


func _rocketjump_def() -> DotWeaponDef:
	var fitting := DotWeaponFitting.make(&"launcher")
	fitting.fit(&"warhead", ArenaRocketJump.ATTACHMENT)
	var made := ArenaAttach.catalogue().apply(ArenaPlayer.weapon_catalogue().get_def(&"launcher"), fitting)
	return made.value as DotWeaponDef if made.ok else null


## A grenade dropped onto the floor at [param at] from 2 m, with a fuse far longer than the test.
func _drop(game: ArenaGame, at: Vector3, sticks: bool) -> ArenaProjectiles.Flying:
	var spawn := DotWeaponSpawn.new()
	spawn.id = &"frag"
	spawn.origin = at + Vector3(0.0, 2.0, 0.0)
	spawn.velocity = Vector3(0.0, -6.0, 0.0)
	spawn.gravity_scale = 1.0
	spawn.radius = 0.1
	spawn.fuse_ticks = TICK_RATE * 60
	spawn.life_ticks = TICK_RATE * 70
	spawn.damage_type = game.combat.damage_type(&"blast")
	spawn.owner_entity = 0
	spawn.tick = game.current_tick()
	spawn.meta = {&"sticks": sticks}
	game.projectiles.launch(spawn)
	return game.projectiles.flying().back()


## Flies [param f] for [param ticks] and returns its highest upward speed after its first bounce.
func _fly(game: ArenaGame, f: Object, ticks: int) -> float:
	var up := -INF
	for _k in ticks:
		game.tick({})
		await get_tree().physics_frame
		if int(f.get(&"bounces")) >= 1:
			up = maxf(up, (f.get(&"velocity") as Vector3).y)
	return up


## Owner batch item 9: a frag comes back up off the floor, a sticky does not, and the cvars say how.
func _test_grenades(game: ArenaGame) -> void:
	_entered += 1
	print("grenades")
	var rules := game.grenades_rules
	_check(game.projectiles.grenade_rules == rules, "the projectile layer flies by the game's sv_grenade rules")
	_check(rules.max_bounces == 12 and is_equal_approx(rules.rest_speed, 1.2), "FC's defaults: 12 bounces, rest under 1.2 m/s", "%d %s" % [rules.max_bounces, rules.rest_speed])
	var here := Vector3(4.0, game.player_for(10).controller.state.position.y, 4.0)

	var frag := _drop(game, here, false)
	var up: float = await _fly(game, frag, TICK_RATE * 3)
	_check(up > 1.0, "a frag bounces back up off the floor", "%.2f m/s" % up)
	_check(frag.resting and frag.bounces >= 2, "and settles after a few hops", "%d bounces" % frag.bounces)

	var _set := rules.set_cvar("sv_grenade_bounce", "0")
	var dead := _drop(game, here, false)
	up = await _fly(game, dead, TICK_RATE)
	_check(dead.resting and dead.bounces == 1 and up <= 0.01, "sv_grenade_bounce 0 lands it dead", "%d bounces, %.2f" % [dead.bounces, up])
	_set = rules.set_cvar("sv_grenade_bounce", "0.45")

	_set = rules.set_cvar("sv_grenade_max_bounces", "1")
	var capped := _drop(game, here, false)
	up = await _fly(game, capped, TICK_RATE)
	_check(capped.resting and capped.bounces == 1, "sv_grenade_max_bounces 1 stops it on its first", str(capped.bounces))
	_set = rules.set_cvar("sv_grenade_max_bounces", "12")

	var sticky := _drop(game, here, true)
	up = await _fly(game, sticky, TICK_RATE)
	_check(sticky.resting and sticky.bounces == 0 and sticky.velocity == Vector3.ZERO, "a sticky sticks where it lands", str(sticky.bounces))
	_finished += 1


## Fires [param def]'s missile from 1.2 m over [param shooter]'s feet straight down, and flies it out.
func _fire_down(game: ArenaGame, shooter: int, def: DotWeaponDef) -> void:
	var b := def.tuning as DotWeaponBallistics
	var feet := game.player_for(shooter).controller.state.position
	var spawn := DotWeaponSpawn.new()
	spawn.id = def.id
	spawn.origin = feet + Vector3(0.6, 1.2, 0.0)
	spawn.velocity = Vector3(0.0, -30.0, 0.0)
	spawn.radius = 0.1
	spawn.life_ticks = TICK_RATE * 2
	spawn.damage_type = b.splash_type if b.splash_type != null else b.damage_type
	spawn.splash_radius = b.splash_radius
	spawn.splash_damage = b.splash_damage
	spawn.owner_entity = shooter
	spawn.tick = game.current_tick()
	game.projectiles.launch(spawn)


## How far [param id] rises over [param ticks] from where they stand now.
func _rise(game: ArenaGame, id: int, ticks: int) -> float:
	var start := game.player_for(id).controller.state.position.y
	var top := start
	for _k in ticks:
		game.tick({})
		await get_tree().physics_frame
		top = maxf(top, game.player_for(id).controller.state.position.y)
	return top - start


## Owner batch item 10: the Rocketjump throws its own shooter and spares them; a plain missile hurts and does not.
func _test_rocketjump(game: ArenaGame, shooter: int, other: int) -> void:
	_entered += 1
	print("rocketjump")
	game.combat.rules.self_damage = true
	# Spawn protection (3 s) would turn the plain missile's self damage away; firing ends it in play.
	game.end_spawn_protection(shooter)
	var p := game.player_for(shooter)
	p.controller.state.position = Vector3(0.0, p.controller.state.position.y, 0.0)
	game.player_for(other).controller.state.position = Vector3(30.0, p.controller.state.position.y, 30.0)
	for _k in 32:
		game.tick({})
		await get_tree().physics_frame

	var def := _rocketjump_def()
	var arsenal := p.arsenal
	var given := arsenal.give(&"launcher")
	_check(given.ok, "the shooter is handed the launcher", str(given.error))
	var _held := arsenal.equip(def.slot)
	var fitting := DotWeaponFitting.make(&"launcher")
	fitting.fit(&"warhead", ArenaRocketJump.ATTACHMENT)
	var fitted := arsenal.fit(def.slot, fitting)
	_check(fitted.ok and ArenaRocketJump.is_rocketjump(arsenal.current_def()), "and fits the Rocketjump warhead", str(fitted.error))

	var hp := game.combat.health_of(shooter).health
	_fire_down(game, shooter, arsenal.current_def())
	var rose: float = await _rise(game, shooter, TICK_RATE)
	# Standing on the floor the launch is cut by `jump_ground_scale` (0.6): about 6.8 m/s up against FC's gravity
	# of 22, a metre. A jump first takes the cut off; the plain missile below must stay under 0.3 m.
	_check(rose > 0.6, "its blast throws the shooter up", "%.2f m" % rose)
	_check(is_equal_approx(game.combat.health_of(shooter).health, hp), "without hurting them (sv_rocket_jump_self_damage_scale 0)", "%s -> %s" % [hp, game.combat.health_of(shooter).health])

	var off := DotWeaponFitting.make(&"launcher")
	var bare := arsenal.fit(def.slot, off)
	_check(bare.ok and not ArenaRocketJump.is_rocketjump(arsenal.current_def()), "the warhead comes off")
	for _k in TICK_RATE * 2:
		game.tick({})
		await get_tree().physics_frame
	hp = game.combat.health_of(shooter).health
	_fire_down(game, shooter, arsenal.current_def())
	rose = await _rise(game, shooter, TICK_RATE)
	_check(rose < 0.3, "a plain missile does not throw its shooter (sv_rocket_plain_jump_scale 0)", "%.2f m" % rose)
	_check(game.combat.health_of(shooter).health < hp, "and does hurt them", "%s -> %s, protected %s" % [hp, game.combat.health_of(shooter).health, game.combat.health_of(shooter).is_protected(game.current_tick())])

	var rules: RefCounted = game.rocket_rules
	var still := p.controller.state.velocity
	_check(not ArenaRocketJump.launch(p, def, rules, p.controller.state.position + Vector3(0.0, 0.0, 9.0)), "a blast out of reach pushes nobody")
	_check(p.controller.state.velocity == still, "and leaves their velocity alone")
	_finished += 1


func _labels(node: Node, out: PackedStringArray) -> PackedStringArray:
	if node is Label:
		out.append((node as Label).text)
	for child in node.get_children():
		_labels(child, out)
	return out


## Owner batch item 3 and the loadout: each launcher draws its own missile, and the menu names the mount.
func _test_view_and_menu(game: ArenaGame) -> void:
	_entered += 1
	print("view and menu")
	var view := ArenaProjectileView.new()
	add_child(view)
	view.projectiles = game.projectiles
	var drawn := {}

	for id: StringName in [&"launcher", &"quad_launcher", &"grenade_launcher", &"frag"]:
		var spawn := DotWeaponSpawn.new()
		spawn.id = id
		spawn.origin = Vector3(0.0, 30.0, 0.0)
		spawn.velocity = Vector3(10.0, 0.0, 0.0)
		spawn.fuse_ticks = TICK_RATE * 10 if id in [&"grenade_launcher", &"frag"] else 0
		spawn.tick = game.current_tick()
		game.projectiles.launch(spawn)
		view.present()
		drawn[id] = view.get_child(view.get_child_count() - 1)

	for id: StringName in [&"launcher", &"quad_launcher"]:
		var node: Node = drawn[id]
		_check(node.get_node_or_null(^"Exhaust") != null and node.get_child_count() == 2, "the %s flies its own missile, with a motor glow" % id, str(node.get_children()))
	_check((drawn[&"grenade_launcher"] as Node).get_node_or_null(^"Fuse") != null, "the grenade launcher's round is its own, fused")
	_check((drawn[&"frag"] as Node).get_node_or_null(^"Exhaust") == null, "a frag is still a grenade")
	view.queue_free()

	var base := ArenaPlayer.weapon_catalogue().get_def(&"launcher")
	var choices := ArenaAttach.catalogue().choices_for(base)
	_check(ArenaRocketJump.ATTACHMENT in choices.get(&"warhead", []), "the launcher takes the Rocketjump on its warhead mount", str(choices.keys()))
	var menu := DotWeaponAttachMenu.new()
	add_child(menu)
	menu.open(ArenaAttach.catalogue(), base, DotWeaponFitting.make(&"launcher"))
	var heads := Array(_labels(menu, PackedStringArray())).filter(func(t: String) -> bool: return t.ends_with("Warhead"))
	_check(heads.size() == 1, "the loadout menu has a Warhead row", str(_labels(menu, PackedStringArray())))
	menu.queue_free()
	_finished += 1
