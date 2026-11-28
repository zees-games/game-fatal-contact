extends "headless_match_modes_and_drops.gd"

# Weapon modes

func _weapon_mode_game(mode: FcMode, ids: Array) -> FcGame:
	var game := FcGame.new()
	game.name = "WeaponModeGame"
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.mode = mode
	add_child(game)
	var ready := game.setup(FcMap.dm_box())
	if not ready.ok:
		return null
	game.start(0)
	for id in ids:
		var _added := game.add_player(id, "Armed %d" % id)
	game.match_node.rules.respawn_delay_sec = 0.2
	_go_live(game)
	return game

## Kill somebody the way the game does it, through gs-combat.
func _kill_through_combat(game: FcGame, killer: int, victim: int, weapon: StringName = &"", headshot := false) -> void:
	var health := game.combat.health_of(victim)
	if health == null:
		return
	var type := game.combat.damage_type(&"bullet")
	if type == null:
		type = GSDamageType.new()
		type.id = &"bullet"
	# Spawn protection off first: `GSHealth.apply` silently refuses everything while it holds, so a kill right after a spawn
	# kills nobody and every later check fails for a reason unrelated to its subject.
	health.invulnerable_until_tick = -1
	var damage := GSDamage.make(killer, victim, health.health + health.armour + 50.0, type)
	damage.tick = game.current_tick()
	damage.weapon_id = weapon
	if headshot:
		damage.hit_group = GSHitGroup.HEAD
	var applied := health.apply(damage)
	if applied != null and applied.lethal:
		game.combat.entity_killed.emit(victim, applied)

# Streaks

func _test_streaks() -> void:
	_section("kill streaks and their rewards")

	_check(
		FcGame.parse_streak_rewards("3:heal, 5:haste,x:y,0:armour") == {3: "heal", 5: "haste"},
		"fc_streak_rewards parses streak:reward pairs and skips the rest"
	)
	_check(FcGame.parse_streak_rewards("").is_empty(), "and empty gives nothing")

	var game := _weapon_mode_game(FcMode.free_for_all(50), [940, 941, 942])
	if game == null:
		_check(false, "a streak game sets up")
		return
	_check(game.streak_rewards.is_empty(), "no streak reward is on by default")
	game.streak_rewards = FcGame.parse_streak_rewards("3:heal,5:haste,7:empowered")
	var rewards: Array[String] = []
	game.streak_reward.connect(func(_p: int, s: int, r: String) -> void: rewards.append("%d:%s" % [s, r]))

	var killer := game.player_for(940)
	for i in range(3):
		killer.health.health = 30.0
		var victim := 941 if i % 2 == 0 else 942
		game.player_for(victim).health.alive = true
		game.player_for(victim).hitboxes.enabled = true
		game.combat.health_of(victim).health = 100.0
		_kill_through_combat(game, 940, victim)
	_check(int(game.streaks.get(940, 0)) == 3 and rewards == ["3:heal"],
		"the third kill without dying is a streak of three and heals (%s)" % ", ".join(rewards))
	_check(killer.health.health >= killer.health.max_health - 0.01, "to full (%.0f)" % killer.health.health)

	game.player_for(941).health.alive = true
	game.player_for(941).hitboxes.enabled = true
	_kill_through_combat(game, 941, 940)
	_check(int(game.streaks.get(940, -1)) == 0, "and dying ends it")

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()

# Respawn delay

const FcRespawnDelay := preload("../game/fc_respawn_delay.gd")
const FcRespawnWire := preload("../game/fc_respawn_wire.gd")
const FcKnifeEvents := preload("../game/fc_knife_events.gd")

## Kills [param victim] and returns the respawn wait the queue holds for it, in seconds.
func _respawn_wait_after_kill(game: FcGame, killer: int, victim: int) -> float:
	_revive_victim(game, victim)
	_kill_through_combat(game, killer, victim)
	var queue := game.match_node.respawns
	if not queue.is_waiting(str(victim)):
		return -1.0
	return float(queue.ready_tick(str(victim)) - game.current_tick()) / float(TICK_RATE)

func _test_respawn_delay() -> void:
	_section("respawn delay: off keeps the mode's, fixed, range, per team, and the kill view cannot skip it")

	var game := _weapon_mode_game(FcMode.team_deathmatch(50), [970, 971, 972, 973])
	if game == null:
		_check(false, "a respawn delay game sets up")
		return
	var d: FcRespawnDelay = game.respawn_delay
	var near := func(a: float, b: float) -> bool: return absf(a - b) < 0.05
	var waits: Array[String] = []
	game.respawn_wait_started.connect(func(v: int, sec: float) -> void: waits.append("%d:%.2f" % [v, sec]))
	var killer := 970
	var killer_team := game.team_of(killer)
	var enemy := 0
	var friend := 0
	for id in [971, 972, 973]:
		if game.team_of(id) != killer_team and enemy == 0:
			enemy = id
		elif game.team_of(id) == killer_team and friend == 0:
			friend = id
	if not _check(enemy != 0 and friend != 0, "the game has two teams with a player on each"):
		remove_child(game)
		game.queue_free()
		return

	_check(not d.active() and d.pick(1, enemy, 5) < 0.0, "nothing set means no delay of its own")
	var off := _respawn_wait_after_kill(game, killer, enemy)
	_check(near.call(off, 0.2) and waits.is_empty(), "all 0 leaves the mode's delay and tells no client (%.2f)" % off)

	d.min_sec = 2.0
	var fixed := _respawn_wait_after_kill(game, killer, enemy)
	_check(near.call(fixed, 2.0) and waits.size() == 1, "a min with no max is a fixed wait (%.2f)" % fixed)
	d.max_sec = 2.0
	_check(near.call(_respawn_wait_after_kill(game, killer, enemy), 2.0), "min equal to max is a fixed wait")

	d.min_sec = 1.0
	d.max_sec = 3.0
	var lo := 99.0
	var hi := 0.0
	for tick in range(200):
		var sec := d.pick(1, enemy, tick)
		lo = minf(lo, sec)
		hi = maxf(hi, sec)
	_check(lo >= 1.0 and hi <= 3.0 and hi - lo > 1.0, "a range picks inside it and spreads over it (%.2f to %.2f)" % [lo, hi])
	_check(d.pick(1, enemy, 7) == d.pick(1, enemy, 7), "the pick is the same for the same victim and tick")
	var ranged := _respawn_wait_after_kill(game, killer, enemy)
	_check(ranged >= 0.95 and ranged <= 3.05, "a kill is held for a time inside the range (%.2f)" % ranged)
	d.min_sec = 0.0
	d.max_sec = 2.0
	_check(d.pick(1, enemy, 3) >= 0.0 and d.pick(1, enemy, 3) <= 2.0, "a max alone picks between 0 and it")

	d.min_sec = 2.0
	d.max_sec = 0.0
	d.team_min[game.team_of(enemy)] = 5.0
	_check(near.call(_respawn_wait_after_kill(game, killer, enemy), 5.0), "a team's own min overrides the global one")
	_check(near.call(_respawn_wait_after_kill(game, enemy, friend), 2.0), "and the other team keeps the global one")
	d.team_min[game.team_of(enemy)] = 0.0
	_check(near.call(_respawn_wait_after_kill(game, killer, enemy), 2.0), "a team value of 0 falls through to the global one")
	d.team_max[game.team_of(enemy)] = 8.0
	var team_range := _respawn_wait_after_kill(game, killer, enemy)
	_check(team_range >= 1.95 and team_range <= 8.05, "min and max fall through separately (%.2f)" % team_range)
	d.team_max.clear()

	var reader := GSNetReader.new(FcRespawnWire.write_wait(enemy, 2.5))
	var kind := FcKnifeEvents.read_more(reader)
	var wire := FcRespawnWire.read_wait(reader)
	_check(kind == FcKnifeEvents.More.RESPAWN_WAIT and bool(wire["ok"]) and int(wire["victim"]) == enemy and near.call(float(wire["sec"]), 2.5),
		"the wait crosses the wire as a MORE sub-kind")
	_check(waits.size() >= 2 and waits[0].begins_with("%d:" % enemy), "the game announces each wait it sets")

	var held := _respawn_wait_after_kill(game, killer, enemy)
	var skipped := game._release_held_respawn(enemy)
	_check(not skipped.ok and game.match_node.respawns.is_waiting(str(enemy)) and not game.player_for(enemy).is_alive(),
		"a kill view skip before the wait is over does not respawn (%.2f)" % held)
	d.floors[enemy] = game.current_tick()
	_check(game._release_held_respawn(enemy).ok and game.player_for(enemy).is_alive(), "once the wait is over it does")

	var client := FcRespawnDelay.new()
	client.note(enemy, 30.0)
	_check(client.remaining(enemy) > 0.0 and client.remaining(friend) == 0.0, "the client counts the wait down for its own player only")

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()

# Kill rewards

## Reads the victim's replacement state: a fresh victim for every kill.
func _revive_victim(game: FcGame, victim: int) -> void:
	var player := game.player_for(victim)
	player.health.alive = true
	player.hitboxes.enabled = true
	game.combat.health_of(victim).health = 100.0

func _test_kill_rewards() -> void:
	_section("kill rewards: +5 health per headshot, capped, the rest off by default")

	var game := _weapon_mode_game(FcMode.free_for_all(50), [950, 951, 952])
	if game == null:
		_check(false, "a kill rewards game sets up")
		return
	var killer := game.player_for(950)
	var c := game.config
	_check(c.headshot_heal == 5.0 and c.max_health_cap == 110.0 and c.player_health == 100.0,
		"defaults: headshot +5, cap 110, start 100")
	_check(not c.kill_reward_haste and not c.kill_reward_empowered and c.kill_reward_heal == 0.0
		and c.kill_reward_armour == 0.0 and game.streak_rewards.is_empty() and float(game.drop_rules["health"]) == 0.0,
		"every other kill reward is off by default")
	_check(killer.health.health == 100.0 and killer.health.max_health == 100.0, "a player starts on 100")

	_revive_victim(game, 951)
	_kill_through_combat(game, 950, 951)
	_check(killer.health.health == 100.0, "a body shot kill gives no health (%.0f)" % killer.health.health)

	_revive_victim(game, 951)
	_kill_through_combat(game, 950, 951, &"", true)
	_check(killer.health.health == 105.0, "a headshot kill gives +5 (%.0f)" % killer.health.health)
	_check(killer.health.max_health == 100.0 and killer.health.overheal_cap == 0.0,
		"and leaves max health and the ordinary heal ceiling alone")
	_check(game.effects == null or not game.effects.has(FcEffects.HASTE, 950), "and gives no haste")

	_revive_victim(game, 952)
	_kill_through_combat(game, 950, 952, &"", true)
	_revive_victim(game, 951)
	_kill_through_combat(game, 950, 951, &"", true)
	_check(killer.health.health == 110.0, "headshots stop at the cap of 110 (%.0f)" % killer.health.health)

	var healed := killer.health.heal(10.0)
	_check(healed == 0.0 and killer.health.health == 110.0, "a pack heals nothing above max health")

	c.max_health_cap = 0.0
	_revive_victim(game, 951)
	_kill_through_combat(game, 950, 951, &"", true)
	_check(killer.health.health == 115.0, "a cap of 0 is unlimited (%.0f)" % killer.health.health)

	c.max_health_cap = 110.0
	c.headshot_heal = 0.0
	killer.health.health = 100.0
	_revive_victim(game, 951)
	_kill_through_combat(game, 950, 951, &"", true)
	_check(killer.health.health == 100.0, "headshot_heal 0 gives nothing")

	c.kill_reward_heal = 20.0
	c.kill_reward_armour = 30.0
	c.kill_reward_haste = true
	killer.health.health = 50.0
	killer.health.max_armour = 100.0
	killer.health.armour = 0.0
	_revive_victim(game, 951)
	_kill_through_combat(game, 950, 951)
	_check(killer.health.health == 70.0 and killer.health.armour == 30.0, "kill_reward_heal and _armour give per kill (%.0f, %.0f)" % [killer.health.health, killer.health.armour])
	if game.effects != null:
		_check(game.effects.has(FcEffects.HASTE, 950), "kill_reward_haste gives haste")
		_check(not game.effects.has(FcEffects.EMPOWERED, 950), "and empowered stays off")

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()

# Medals

## One kill's facts for the medal rules, at [param tick] on a 64-tick server.
func _facts(killer: int, victim: int, tick: int, extra: Dictionary = {}) -> FcAwards.KillFacts:
	var k := FcAwards.KillFacts.new()
	k.killer = killer
	k.victim = victim
	k.tick = tick
	k.tick_rate = 64
	k.distance = float(extra.get("distance", 10.0))
	k.headshot = bool(extra.get("headshot", false))
	k.victim_streak = int(extra.get("victim_streak", 0))
	k.aiming = bool(extra.get("aiming", true))
	k.tags = extra.get("tags", [AwWeaponIds.TAG_PRIMARY])
	k.team_kill = bool(extra.get("team_kill", false))
	return k

## Every medal rule, each with the case beside it that must NOT earn it. The rules are the
## server's (`FcAwards.MedalBook`); a client only draws what they decide.
func _test_medal_rules() -> void:
	_section("medals: each rule, and its near miss")
	var M := FcAwards.Medal
	var book := FcAwards.MedalBook.new()

	var first := book.judge(_facts(1, 2, 100))
	_check(first.has(M.FIRST_BLOOD), "the round's first kill is First Blood (%s)" % [first])
	_check(not book.judge(_facts(3, 4, 900)).has(M.FIRST_BLOOD), "and the second is not")
	book.reset_round()
	_check(book.judge(_facts(3, 4, 2000)).has(M.FIRST_BLOOD), "a new round has its own")

	book.reset_round()
	_check(book.judge(_facts(1, 2, 10, {"headshot": true})).has(M.HEADSHOT), "a kill to the head is a Headshot")
	_check(not book.judge(_facts(1, 3, 1000)).has(M.HEADSHOT), "and one to the body is not")

	# The chain: four seconds is 256 ticks at 64.
	book.reset_round()
	var one := book.judge(_facts(5, 6, 1000))
	var two := book.judge(_facts(5, 7, 1100))
	var three := book.judge(_facts(5, 8, 1300))
	var four := book.judge(_facts(5, 9, 1500))
	_check(not one.has(M.DOUBLE_KILL) and two.has(M.DOUBLE_KILL), "a second kill inside four seconds is a Double Kill")
	_check(three.has(M.TRIPLE_KILL) and not three.has(M.DOUBLE_KILL), "a third is a Triple Kill, and only that")
	_check(four.has(M.MULTI_KILL), "a fourth is a Multi Kill")
	var late := book.judge(_facts(5, 10, 1500 + 257))
	_check(not late.has(M.DOUBLE_KILL) and not late.has(M.MULTI_KILL), "a kill just past the window starts again (%s)" % [late])
	var _died := book.judge(_facts(11, 5, 1760))
	var after_death := book.judge(_facts(5, 12, 1770))
	_check(not after_death.has(M.DOUBLE_KILL), "and dying ends a chain however quick the next kill")

	book.reset_round()
	var _b := book.judge(_facts(21, 20, 10))
	_check(book.judge(_facts(20, 21, 900)).has(M.REVENGE), "killing your last killer is Revenge")
	_check(not book.judge(_facts(20, 21, 1900)).has(M.REVENGE), "once: the next kill of them is not")
	_check(not book.judge(_facts(20, 22, 2900)).has(M.REVENGE), "and nor is killing anybody else")

	book.reset_round()
	_check(book.judge(_facts(30, 31, 10, {"victim_streak": FcAwards.SHUTDOWN_AT})).has(M.SHUTDOWN),
		"ending a streak of %d is a Shutdown" % FcAwards.SHUTDOWN_AT)
	_check(not book.judge(_facts(30, 32, 900, {"victim_streak": FcAwards.SHUTDOWN_AT - 1})).has(M.SHUTDOWN),
		"one shorter is not")

	book.reset_round()
	_check(book.judge(_facts(40, 41, 10, {"distance": 2.0})).has(M.POINT_BLANK), "a kill from 2 m is Point Blank")
	_check(not book.judge(_facts(40, 42, 900, {"distance": 3.5})).has(M.POINT_BLANK), "from 3.5 m it is not")
	_check(not book.judge(_facts(40, 43, 1800, {"distance": 1.0, "tags": [AwWeaponIds.TAG_MELEE]})).has(M.POINT_BLANK),
		"and a knife is always close, so never")

	book.reset_round()
	var scoped := [AwWeaponIds.TAG_HEAVY, AwWeaponIds.TAG_SCOPED]
	_check(book.judge(_facts(50, 51, 10, {"tags": scoped, "aiming": false})).has(M.NO_SCOPE),
		"a scoped weapon's kill without aiming is No Scope")
	_check(not book.judge(_facts(50, 52, 900, {"tags": scoped, "aiming": true})).has(M.NO_SCOPE),
		"aimed, it is not")
	_check(not book.judge(_facts(50, 53, 1800, {"aiming": false})).has(M.NO_SCOPE),
		"and a weapon with no scope never is")

	book.reset_round()
	_check(book.judge(_facts(60, 61, 10, {"distance": FcAwards.LONG_SHOT_M + 5.0})).has(M.LONG_SHOT),
		"a kill from %d m is a Long Shot" % int(FcAwards.LONG_SHOT_M + 5.0))
	_check(not book.judge(_facts(60, 62, 900, {"distance": FcAwards.LONG_SHOT_M - 5.0})).has(M.LONG_SHOT),
		"from %d m it is not" % int(FcAwards.LONG_SHOT_M - 5.0))
	_check(not book.judge(_facts(60, 63, 1800, {"distance": 50.0, "tags": [AwWeaponIds.TAG_EXPLOSIVE]})).has(M.LONG_SHOT),
		"and a rocket lands where it lands, so never")

	book.reset_round()
	var runs: Array = []
	for i in range(4):
		runs.append(book.judge(_facts(70, 71, 10 + 1000 * i)).has(M.NEMESIS))
	_check(runs == [false, false, true, false], "the third kill of one player unanswered is Nemesis, and only the third (%s)" % [runs])
	var _back := book.judge(_facts(71, 70, 9000))
	var again: Array = []
	for i in range(3):
		again.append(book.judge(_facts(70, 71, 10000 + 1000 * i)).has(M.NEMESIS))
	_check(again == [false, false, true], "a kill back starts the count again (%s)" % [again])

	book.reset_round()
	_check(book.judge(_facts(80, 81, 10, {"team_kill": true, "headshot": true})).is_empty(), "a team kill earns nothing")
	_check(book.judge(_facts(82, 82, 20)).is_empty(), "and nor does killing yourself")

	_check(
		FcAwards.points_for([M.HEADSHOT, M.FIRST_BLOOD]) == FcAwards.KILL_POINTS + 25 + 50,
		"a kill's points are the kill's and each medal's"
	)
	_check(FcAwards.medal_name(M.NO_SCOPE) == "No Scope" and FcAwards.medal_sound(M.NO_SCOPE) == &"medal_no_scope",
		"every medal has a name and a sound id")
	_done()

## The same rules reached the way a real kill reaches them: through gs-combat, on an
## authoritative game, with the hit confirmed for the attacker and the medals after the kill.
func _test_medals_from_a_game() -> void:
	_section("medals: a game judges its own kills, and confirms the hits")
	var game := _weapon_mode_game(FcMode.free_for_all(50), [950, 951])
	if game == null:
		_check(false, "a medal game sets up")
		return
	var order: Array[String] = []
	var hits: Array[Dictionary] = []
	var awards: Array[Dictionary] = []
	game.player_killed.connect(func(_e: GSKillFeed.Entry) -> void: order.append("kill"))
	game.hit_confirmed.connect(func(a: int, v: int, amount: float, at: Vector3, head: bool, lethal: bool) -> void:
		hits.append({"a": a, "v": v, "amount": amount, "head": head, "lethal": lethal}))
	game.medals_awarded.connect(func(k: int, v: int, medals: Array, points: int, streak: int) -> void:
		order.append("award")
		awards.append({"k": k, "v": v, "medals": medals, "points": points, "streak": streak}))

	# Past spawn protection, which is three records and not only the health's window.
	for _t in range(int(game.match_node.rules.spawn_protection_sec * TICK_RATE) + TICK_RATE):
		game.tick({})
	var health := game.combat.health_of(951)
	health.invulnerable_until_tick = -1
	var type := game.combat.damage_type(&"bullet")
	var chip := GSDamage.make(950, 951, 20.0, type)
	chip.tick = game.current_tick()
	chip.weapon_id = AwWeaponIds.RIFLE
	var _c := game.combat.apply_damage(chip)
	_check(hits.size() == 1 and int(hits[0]["a"]) == 950 and is_equal_approx(float(hits[0]["amount"]), 20.0) and not bool(hits[0]["lethal"]),
		"a hit that lands is confirmed to its attacker with what it took (%s)" % [hits])

	# Lethal, to the head, with a scoped weapon and the aim not held.
	var killer := game.player_for(950)
	killer.aiming = false
	var shot := GSDamage.make(950, 951, 500.0, type)
	shot.tick = game.current_tick()
	shot.hit_group = GSHitGroup.HEAD
	shot.weapon_id = AwWeaponIds.SNIPER
	var _k := game.combat.apply_damage(shot)
	_check(hits.size() == 2 and bool(hits[1]["lethal"]) and bool(hits[1]["head"]), "the killing hit is confirmed as lethal and to the head")
	var got: Array = awards[0]["medals"] if not awards.is_empty() else []
	var M := FcAwards.Medal
	_check(got.has(M.FIRST_BLOOD) and got.has(M.HEADSHOT) and got.has(M.NO_SCOPE),
		"and the kill earns First Blood, Headshot and No Scope (%s)" % [got.map(func(m: int) -> String: return FcAwards.medal_name(m))])
	_check(order == ["kill", "award"], "after the kill itself, so a client hears the KILL first (%s)" % [order])
	_check(not awards.is_empty() and int(awards[0]["points"]) == FcAwards.points_for(got) and int(awards[0]["streak"]) == 1,
		"with the kill's points and the killer's streak")

	# The aim bit: the weapon command carries it, the simulation records it.
	var ask := GSWeaponCommand.new()
	ask.set_button(FcPlayer.BUTTON_AIM, true)
	var _o := killer.simulate_tick(game.current_tick() + 1, 1.0 / 64.0, GSFpsCommand.new(), ask)
	_check(killer.aiming, "a command with the aim held is a player aiming, on the server")

	# A world death is no medal and no hit confirmed to anybody.
	var before := hits.size()
	var awarded_before := awards.size()
	var world := game.combat.health_of(950)
	var fall := GSDamage.make(0, 950, 500.0, type)
	fall.tick = game.current_tick()
	var _f := game.combat.apply_damage(fall)
	_check(hits.size() == before and awards.size() == awarded_before, "the world killing somebody confirms no hit and awards nothing")

	remove_child(game)
	game.queue_free()
	await get_tree().process_frame
	_done()

## Forward, jumping and firing: what a player does during a freeze.
func _jump_and_fire(a: FcPlayer) -> Array:
	var move := GSFpsCommand.new()
	move.move = Vector2(0.0, 1.0)
	move.yaw = a.controller.state.yaw
	move.set_button(GSFpsCommand.BUTTON_JUMP, true)
	var fire := GSWeaponCommand.new()
	fire.slot = 0
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	fire.set_button(GSWeaponCommand.BUTTON_ATTACK, true)
	return [move, fire]

## The countdown before a round holds everybody still, unarmed and unhurtable, and lets go
## exactly when the round is live; `mp_freezetime` 0 has no countdown at all.
func _test_freeze_countdown() -> void:
	_section("the pre-round freeze")
	var game := _weapon_mode_game(FcMode.free_for_all(25), [960, 961])
	if not _check(game != null, "a two-player game sets up"):
		return
	for _i in range(6):
		await get_tree().process_frame
	var a := game.player_for(960)
	var shots := [0]
	a.used.connect(func(o: GSWeaponOutcome) -> void: shots[0] += o.shots.size())

	var intent := func() -> Array: return _jump_and_fire(a)
	for _k in range(TICK_RATE / 2):
		game.tick({960: intent.call()})
	_check(shots[0] > 0, "baseline: a live player shoots", str(shots[0]))
	shots[0] = 0
	for slot in a.arsenal.slots():
		a.arsenal.slot_at(slot).magazine = a.arsenal.slot_at(slot).def.magazine
	game.freeze_sec = 1.0
	game.apply_match_limits()
	game.match_node.rules.min_players = 1
	game.match_node.rules.intermission_sec = 0.1
	game.match_node.rules.time_limit_sec = 0.0
	game.match_node.rules.score_limit = 1
	var cmds := {960: intent.call(), 961: intent.call()}
	game.match_node.rules.warmup_sec = 0.0
	game.start(game.current_tick())
	var guard := 0
	while game.match_node.state != GSMatch.State.COUNTDOWN and guard < TICK_RATE * 20:
		game.tick({})
		guard += 1
	_check(game.match_node.state == GSMatch.State.COUNTDOWN, "the match reaches its countdown")
	game.tick({})
	var spot := a.controller.state.position
	for _k in range(TICK_RATE / 2):
		game.tick(cmds)
	_check(a.controller.state.position.distance_to(spot) < 0.01,
		"nobody moves or jumps while frozen", str(a.controller.state.position - spot))
	_check(shots[0] == 0, "nobody shoots while frozen", str(shots[0]))
	_check(a.health.invulnerable and game.player_for(961).health.invulnerable, "nobody can be hurt while frozen")
	guard = 0
	while game.match_node.state == GSMatch.State.COUNTDOWN and guard < TICK_RATE * 5:
		game.tick(cmds)
		guard += 1
	_check(game.match_node.state == GSMatch.State.LIVE, "the countdown ends in a live round")
	for _i in range(6):
		await get_tree().process_frame
	# Neither presses a slot key, as a bot never does: spawned into the freeze, both hold the primary.
	_check(a.arsenal.current_slot() == FcContent.DEFAULT_SLOT and game.player_for(961).arsenal.current_slot() == FcContent.DEFAULT_SLOT,
		"a spawn into the freeze holds the starting weapon, not the knife", "%d %d" % [a.arsenal.current_slot(), game.player_for(961).arsenal.current_slot()])
	spot = a.controller.state.position
	var released := {960: intent.call()}
	(released[960][1] as GSWeaponCommand).slot = 3
	for _k in range(TICK_RATE * 2):
		game.tick(released)
		(released[960][1] as GSWeaponCommand).slot = 0
	_check(a.controller.state.position.distance_to(spot) > 0.5, "players move once the round is live")
	_check(shots[0] > 0, "and shoot once live", "%d alive=%s dis=%s state=%d" % [shots[0], a.is_alive(), a.arsenal.disabled, game.match_node.state])
	_check(not a.health.invulnerable and not GSFpsAdminModifiers.is_frozen(a.controller),
		"and are released exactly: no god mode, no freeze left")

	game.freeze_sec = 0.0
	game.apply_match_limits()
	_check(game.match_node.rules.countdown_sec == 0.0, "mp_freezetime 0 leaves no countdown")
	remove_child(game)
	game.queue_free()
	_done()

## Lag compensation: a shot is traced against the other players where the shooter saw
## them, as far back as `fc_max_unlag_ms` allows (2026-10-09; before, never).
func _test_lag_compensation() -> void:
	_section("lag compensation")
	var game := _weapon_mode_game(FcMode.free_for_all(25), [940, 941])
	if not _check(game != null, "a two-player game sets up"):
		return
	for _i in range(6):
		await get_tree().process_frame
	var shooter := game.player_for(940)
	var target := game.player_for(941)
	var floor_y := shooter.controller.state.position.y
	for id in [940, 941]:
		game.combat.health_of(id).invulnerable_until_tick = -1

	# B walks sideways a quarter of a metre a tick, eight metres in front of A, for twenty
	# ticks; the history is what the server records as it ticks.
	var a_at := Vector3(0.0, floor_y, 0.0)
	for k in range(20):
		_stand(game, 940, a_at)
		_stand(game, 941, Vector3(-2.5 + 0.25 * k, floor_y, -8.0))
		game.tick({})
	var now := game.current_tick()
	var back := 12
	var then: Variant = game.unlag_position_at(941, float(now - back))
	_check(then is Vector3 and (then as Vector3).distance_to(target.global_position) > 2.5,
		"the server remembers where B was %d ticks ago (%s, now %s)" % [back, then, target.global_position])

	# A fires at where B WAS, as a client drawing B that far behind would.
	var fire_at := func(view_tick: float) -> bool:
		var shot := GSShot.make(&"rifle", 940, now, 0)
		shot.origin = shooter.global_position + Vector3.UP * 1.5
		var aim: Vector3 = ((then as Vector3) + Vector3.UP * 1.0) - shot.origin
		shot.pellets = [aim.normalized()] as Array[Vector3]
		shot.direction = aim.normalized()
		shot.damage = 5.0
		shot.damage_type = game.combat.damage_type(&"bullet")
		shot.max_range = 100.0
		game._unlag_shooter = 940
		var _r := game.combat.resolve_shot(shot, view_tick)
		# The hit, not the health: what lag compensation decides is whether the trace met
		# B. What the damage then does (armour, protection) is the rules' business.
		for d: GSDamage in shot.damages:
			if d.victim == 941:
				return true
		return false

	_check(fire_at.call(float(now - back)), "a shot aimed where A saw B, %d ticks back, hits B" % back)
	_check(target.global_position.distance_to(Vector3(-2.5 + 0.25 * 19, floor_y, -8.0)) < 0.3,
		"and B is put back where the server has him (%s)" % target.global_position)
	_check(not fire_at.call(-1.0), "the same shot judged against the present misses")
	game.max_unlag_ms = 0.0
	_check(not fire_at.call(float(now - back)), "and with fc_max_unlag_ms 0 nothing is rewound")
	game.max_unlag_ms = 50.0
	_check(not fire_at.call(float(now - back)),
		"nor past the limit: 50 ms is 3 ticks, and %d were asked for" % back)
	game.max_unlag_ms = 500.0
	remove_child(game)
	game.queue_free()
	_done()

func _revive(game: FcGame, id: int) -> void:
	var health := game.combat.health_of(id)
	if health != null and not health.alive:
		health.revive()

## A rocket or grenade launched from inside a team-mate goes on to where it was aimed.
func _test_launch_inside_team_mate() -> void:
	_section("a launch from inside a team-mate")
	var ids := [950, 951, 952, 953]
	var game := _weapon_mode_game(FcMode.team_deathmatch(), ids)
	if not _check(game != null, "a team game sets up"):
		return
	for _i in range(4):
		await get_tree().process_frame
	# Out of the spawn window: protection refuses every hit, and the splash checks would
	# then measure it instead of where the blast went.
	for _protect in range(game.match_node.spawn_protection_ticks() + 2):
		game.tick({})

	var shooter_id := 950
	var mate_id := 0
	var enemy_id := 0
	for id in ids:
		if id == shooter_id:
			continue
		if game.team_of(id) == game.team_of(shooter_id) and mate_id == 0:
			mate_id = id
		elif game.team_of(id) != game.team_of(shooter_id) and enemy_id == 0:
			enemy_id = id
	if not _check(mate_id > 0 and enemy_id > 0, "a team-mate and an enemy",
			"%d %d" % [mate_id, enemy_id]):
		remove_child(game)
		game.queue_free()
		return

	var shooter := game.player_for(shooter_id)
	var floor_y := shooter.controller.state.position.y
	var here := Vector3(0.0, floor_y, 0.0)
	var ahead := Vector3(0.0, floor_y, -8.0)
	var aside := Vector3(4.0, floor_y, 6.0)
	var spare := 0
	for id in ids:
		if id != shooter_id and id != mate_id and id != enemy_id:
			spare = id

	var gone: Array = []
	game.projectiles.detonated.connect(func(at: Vector3, s: GSWeaponSpawn) -> void:
		gone.append([at, s])
	)

	# Everybody where the case wants them, unhurt and unprotected, for a few ticks so
	# the hitboxes are where the bodies are.
	var arrange := func(placed: Dictionary) -> void:
		for _k in range(3):
			for id in placed:
				_stand(game, id, placed[id])
			game.tick({})
		for id in ids:
			_revive(game, id)
			var h := game.combat.health_of(id)
			h.invulnerable_until_tick = -1
			h.invulnerable = false
			h.health = h.max_health
			h.armour = 0.0
		game.projectiles.clear()
		gone.clear()

	var launch := func(fuse: int, toward: Vector3 = Vector3.FORWARD) -> GSWeaponSpawn:
		var s := GSWeaponSpawn.new()
		s.id = AwWeaponIds.LAUNCHER if fuse <= 0 else AwWeaponIds.FRAG
		s.origin = shooter.muzzle_position()
		s.velocity = toward.normalized() * (44.0 if fuse <= 0 else 14.0)
		s.gravity_scale = 0.0 if fuse <= 0 else 1.0
		s.radius = 0.1
		s.fuse_ticks = fuse
		s.life_ticks = TICK_RATE * 4
		s.damage_type = game.combat.damage_type(AwWeaponIds.DAMAGE_BLAST)
		s.splash_radius = 3.0
		s.splash_damage = 60.0
		s.owner_entity = shooter_id
		s.tick = game.current_tick()
		s.meta = {&"sticks": false}
		game.projectiles.launch(s)
		return s

	var fly := func() -> void:
		for _k in range(TICK_RATE * 2):
			if not gone.is_empty():
				break
			game.tick({})

	var hp := func(id: int) -> float:
		return game.combat.health_of(id).health

	# --- A rocket from inside a team-mate.
	arrange.call({shooter_id: here, mate_id: here, enemy_id: ahead, spare: aside})
	var muzzle := shooter.muzzle_position()
	var mate_set := game.combat.hitboxes_of(mate_id)
	if mate_set != null and mate_set.has_method(&"contains_point"):
		_check(bool(mate_set.call(&"contains_point", muzzle)),
			"the muzzle is inside the team-mate's hitboxes (the case under test)")
	# At the enemy's chest, eight metres on.
	var _rocket: GSWeaponSpawn = launch.call(0, ahead + Vector3.UP * 1.2 - muzzle)
	fly.call()
	var at: Vector3 = gone[0][0] if gone.size() == 1 else muzzle
	_check(gone.size() == 1 and at.distance_to(muzzle) > 5.0,
		"a rocket fired from inside a team-mate flies on instead of going off in them",
		"went off %.2f m from the muzzle" % at.distance_to(muzzle))
	_check(is_equal_approx(hp.call(shooter_id), game.combat.health_of(shooter_id).max_health),
		"and its blast does not come back on the shooter", "%.1f" % hp.call(shooter_id))
	_check(hp.call(enemy_id) < game.combat.health_of(enemy_id).max_health,
		"it reaches the enemy it was aimed at",
		"%.1f, went off at %s" % [hp.call(enemy_id), at])

	# --- A grenade from inside a team-mate: it is thrown, not bounced back off the friend.
	arrange.call({shooter_id: here, mate_id: here, enemy_id: aside, spare: aside + Vector3(2, 0, 0)})
	muzzle = shooter.muzzle_position()
	var _frag: GSWeaponSpawn = launch.call(TICK_RATE * 2)
	for _k in range(6):
		game.tick({})
	var frag: FcProjectiles.Flying = (
		game.projectiles.flying()[0] if game.projectiles.live_count() == 1 else null
	)
	_check(frag != null and frag.bounces == 0 and frag.position.z < muzzle.z - 1.0,
		"a grenade thrown from inside a team-mate leaves them rather than bouncing off them",
		str([frag.bounces, frag.position, muzzle]) if frag != null else "none in flight")
	game.projectiles.clear()

	# --- An enemy holding the muzzle is still a point-blank hit.
	arrange.call({shooter_id: here, enemy_id: here, mate_id: aside, spare: aside + Vector3(2, 0, 0)})
	muzzle = shooter.muzzle_position()
	var _point_blank: GSWeaponSpawn = launch.call(0)
	fly.call()
	at = gone[0][0] if gone.size() == 1 else Vector3.INF
	_check(gone.size() == 1 and at.distance_to(muzzle) < 0.5,
		"a rocket fired from inside an enemy goes off at the muzzle",
		"%.2f m from it" % at.distance_to(muzzle))
	_check(hp.call(enemy_id) < game.combat.health_of(enemy_id).max_health,
		"and the enemy takes it", "%.1f" % hp.call(enemy_id))

	# --- The policy is gs-combat's, in one place: with the rule off, the old geometry.
	var rules := game.combat.rules
	if rules != null and "pass_through_team_mate_at_muzzle" in rules:
		rules.set(&"pass_through_team_mate_at_muzzle", false)
		arrange.call({shooter_id: here, mate_id: here, enemy_id: ahead, spare: aside})
		muzzle = shooter.muzzle_position()
		var _off: GSWeaponSpawn = launch.call(0)
		fly.call()
		at = gone[0][0] if gone.size() == 1 else Vector3.INF
		_check(gone.size() == 1 and at.distance_to(muzzle) < 0.5,
			"with GSDamageRules.pass_through_team_mate_at_muzzle off it goes off in the team-mate again",
			"%.2f m from the muzzle" % at.distance_to(muzzle))
		rules.set(&"pass_through_team_mate_at_muzzle", true)

	# --- mp_teammate_passthrough 2: a team-mate merely in the line does not stop a rocket either.
	if rules != null and "pass_through_team_mates" in rules:
		var between := Vector3(0.0, floor_y, -4.0)
		arrange.call({shooter_id: here, mate_id: between, enemy_id: ahead, spare: aside})
		muzzle = shooter.muzzle_position()
		var _blocked: GSWeaponSpawn = launch.call(0, ahead + Vector3.UP * 1.2 - muzzle)
		fly.call()
		at = gone[0][0] if gone.size() == 1 else Vector3.INF
		_check(gone.size() == 1 and absf(at.z - between.z) < 1.0,
			"at the default a team-mate in the line stops a rocket", "went off at %s" % at)

		rules.set(&"pass_through_team_mates", true)
		arrange.call({shooter_id: here, mate_id: between, enemy_id: ahead, spare: aside})
		muzzle = shooter.muzzle_position()
		var _through: GSWeaponSpawn = launch.call(0, ahead + Vector3.UP * 1.2 - muzzle)
		fly.call()
		at = gone[0][0] if gone.size() == 1 else Vector3.INF
		_check(gone.size() == 1 and at.z < between.z - 2.0 and hp.call(enemy_id) < game.combat.health_of(enemy_id).max_health,
			"with pass_through_team_mates (mp_teammate_passthrough 2) it flies past them to the enemy",
			"went off at %s, enemy %.1f" % [at, hp.call(enemy_id)])
		rules.set(&"pass_through_team_mates", false)

	remove_child(game)
	game.queue_free()
	_done()

func _carried(game: FcGame, id: int) -> Array[StringName]:
	var out: Array[StringName] = []
	for slot in game.player_for(id).arsenal.slots():
		var def: GSWeaponDef = game.player_for(id).arsenal.slot_at(slot).def
		out.append(def.id)
	return out

## Gun game and a weapon pool: the mode decides what a player carries.
func _test_weapon_modes() -> void:
	_section("gun game and a weapon pool")

	_check(FcModes.ids().has(&"gungame") and FcModes.ids().has(&"snipers"),
		"gun game and only snipers are modes a server or a vote can name")

	var broken: FcMode = FcMode.gun_game_mode()
	broken.rules.score_limit = 3
	_check(not broken.validate().ok, "a gun game whose score limit is not its list's length is refused")

	var gun: FcMode = FcMode.gun_game_mode()
	var game := _weapon_mode_game(gun, [920, 921])
	if not _check(game != null, "a gun game sets up"):
		return
	# The server's limit (`fc_scorelimit`, 25 here) is kills; gun game's is levels. It
	# used to win, so a gun game needed ten knife kills after the last gun to end.
	_check(game.score_limit == 25 and game.match_node.rules.score_limit == gun.gun_game.size(),
		"and its match ends at the last gun, not at the server's score limit (%d)" % game.match_node.rules.score_limit)
	for _i in range(6):
		await get_tree().process_frame
	var first := StringName(gun.gun_game[0])
	var held := game.player_for(920).arsenal.current_def()
	_check(held != null and held.id == first, "a gun game player spawns holding the first gun (%s)" % (held.id if held else &"none"))
	_check(_carried(game, 920).size() <= 2, "and nothing else but the knife (%s)" % ", ".join(_carried(game, 920)))

	_kill_through_combat(game, 920, 921)
	held = game.player_for(920).arsenal.current_def()
	_check(held != null and held.id == StringName(gun.gun_game[1]),
		"a kill moves the killer to the next gun (%s)" % (held.id if held else &"none"))

	# A knife kill sets the victim back a gun. 920 is on level 1, 921 on 0. Each victim
	# is revived first: a dead one refuses the hit and the check would pass on nothing.
	var knifed := game.match_node.scoreboard.find("920")
	var knifer := game.match_node.scoreboard.find("921")
	_revive(game, 921)
	_kill_through_combat(game, 920, 921, AwWeaponIds.KNIFE)
	_check(knifer != null and knifer.score == 0 and knifer.deaths == 2,
		"a knife kill on the first gun leaves the victim there (921 at %d, %d deaths)" % [knifer.score if knifer else -1, knifer.deaths if knifer else -1])
	_revive(game, 920)
	_kill_through_combat(game, 921, 920, AwWeaponIds.KNIFE)
	_check(knifed != null and knifed.score == 1,
		"a knife kill sets the victim back one gun (920 from 2 to %d)" % (knifed.score if knifed else -1))
	_check(knifer.score == 1, "and moves the knifer on (921 at %d)" % knifer.score)
	gun.gun_game_melee_demotes = false
	_revive(game, 920)
	_kill_through_combat(game, 921, 920, AwWeaponIds.KNIFE)
	_check(knifed.score == 1 and knifer.score == 2,
		"with gun_game_melee_demotes off, a knife kill is only a kill (920 %d, 921 %d)" % [knifed.score, knifer.score])
	gun.gun_game_melee_demotes = true
	remove_child(game)
	game.queue_free()

	var snipers: FcMode = FcMode.only_snipers()
	var sniping := _weapon_mode_game(snipers, [930, 931])
	if not _check(sniping != null, "an only-snipers game sets up"):
		return
	for _i in range(6):
		await get_tree().process_frame
	var allowed := snipers.pool_ids(sniping.player_for(930).arsenal.catalogue)
	var carried := _carried(sniping, 930)
	var stray: Array[StringName] = []
	for id in carried:
		if not allowed.has(id) and id != AwWeaponIds.KNIFE:
			stray.append(id)
	_check(stray.is_empty() and carried.size() >= 1,
		"only snipers carries scoped guns and the knife (%s)" % ", ".join(carried))
	remove_child(sniping)
	sniping.queue_free()
	await get_tree().process_frame
	_done()

func _first_other_team(game: FcGame, id: int) -> int:
	var side := game.team_of(id)
	for index in range(4):
		var other := 800 + index
		if other != id and game.team_of(other) != side:
			return other
	return 0
