extends GSGameCheckSuite

const FcGame := preload("../game/fc_game.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcTickGates := preload("../game/fc_tick_gates.gd")

## The players' loop gates in game/fc_tick_gates.gd leave every field as the full calls do, over seeded runs:
## - `fc_knife_gate`: an idle player's GSWeaponKnives.input and charge_of are skipped. A reference knives that
##   always runs them and a gated one see the same seeded fire buttons, hands, deaths, rule flips, clears and
##   null arsenals; windup, the AIM bit left on the command, the charge and the held edge agree at every step.
## - `fc_flush_idle_skip`: an idle, unprotected player's flushed outcome skips _post_outcome. Two bare FcGames, one
##   posting every outcome in full and one through the skip, get the same seeded outcomes and protection windows;
##   the protection anchors, protected_view and the shot lists agree at every step.

const KNIFE_STEPS := 40000
const FLUSH_STEPS := 20000
const PLAYERS := 5
const SEED := 4127


## A duck-typed arsenal: the hand's def and an empty drop, so a throw stops before any knife flies.
class FakeArsenal:
	extends RefCounted
	var def: GSWeaponDef = null

	func current_def() -> GSWeaponDef:
		return def

	func current_slot() -> int:
		return 0

	func drop_from_slot(_slot: int) -> Dictionary:
		return {}


class FakePlayer:
	extends RefCounted
	var arsenal: FakeArsenal = null
	var alive := true
	var windup := -1.0

	func is_alive() -> bool:
		return alive


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC — players' loop gates: the gated knives and flush posts equal the full calls")
	_knife_part()
	_flush_part()
	_report(4)


func _knife_part() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var knife_def := GSWeaponDef.new()
	knife_def.id = &"knife"
	var gun_def := GSWeaponDef.new()
	gun_def.id = &"rifle"
	var hands: Array = [knife_def, gun_def, null]
	var ref := GSWeaponKnives.new()
	var gated := GSWeaponKnives.new()
	var ref_players: Array[FakePlayer] = []
	var gated_players: Array[FakePlayer] = []
	var arsenals: Array[FakeArsenal] = []
	for i in PLAYERS:
		var arsenal := FakeArsenal.new()
		arsenals.append(arsenal)
		for list: Array[FakePlayer] in [ref_players, gated_players]:
			var p := FakePlayer.new()
			p.arsenal = arsenal
			list.append(p)
	var was_gate := FcTickGates.knife_gate
	FcTickGates.knife_gate = true
	var skips := 0
	var diff := 0
	var first := ""
	for step in KNIFE_STEPS:
		if rng.randf() < 0.01:
			var charge := rng.randf() < 0.5
			ref.rules["charge"] = charge
			gated.rules["charge"] = charge
		if rng.randf() < 0.005:
			var on := rng.randf() < 0.7
			ref.rules["enabled"] = on
			gated.rules["enabled"] = on
		if rng.randf() < 0.003:
			var authority := rng.randf() < 0.8
			ref.is_authority = authority
			gated.is_authority = authority
		if rng.randf() < 0.002:
			ref.clear()
			gated.clear()
		var k := rng.randi_range(0, PLAYERS - 1)
		var id := k + 1
		if rng.randf() < 0.05:
			arsenals[k].def = hands[rng.randi_range(0, 2)]
		var alive := rng.randf() > 0.03
		var bare := rng.randf() < 0.02
		ref_players[k].alive = alive
		gated_players[k].alive = alive
		ref_players[k].arsenal = null if bare else arsenals[k]
		gated_players[k].arsenal = ref_players[k].arsenal
		var fire_ref: GSWeaponCommand = null
		var fire_gated: GSWeaponCommand = null
		if rng.randf() > 0.02:
			fire_ref = GSWeaponCommand.new()
			fire_ref.buttons = rng.randi_range(0, (1 << GSWeaponCommand.BUTTON_BITS) - 1)
			if rng.randf() < 0.6:
				fire_ref.set_button(GSWeaponCommand.BUTTON_AIM, false)
			fire_gated = GSWeaponCommand.new()
			fire_gated.buttons = fire_ref.buttons
		var knife_charge := rng.randf() < 0.8
		# The reference: the calls fc_game_input.gd made before the gate.
		ref.input(id, ref_players[k], fire_ref)
		ref_players[k].windup = ref.charge_of(id) if knife_charge else -1.0
		if FcTickGates.step(gated, id, gated_players[k], fire_gated, knife_charge):
			skips += 1
		var buttons_ref := -1 if fire_ref == null else fire_ref.buttons
		var buttons_gated := -1 if fire_gated == null else fire_gated.buttons
		var same := var_to_bytes(ref_players[k].windup) == var_to_bytes(gated_players[k].windup) \
				and buttons_ref == buttons_gated \
				and var_to_bytes(ref.charge_of(id)) == var_to_bytes(gated.charge_of(id)) \
				and bool(ref._aim_held.get(id, false)) == bool(gated._aim_held.get(id, false)) \
				and ref._charge.get(id, -1) == gated._charge.get(id, -1)
		if not same:
			diff += 1
			if first == "":
				first = "step %d id %d: windup %s/%s buttons %d/%d charge %s/%s" % [step, id, ref_players[k].windup,
						gated_players[k].windup, buttons_ref, buttons_gated, ref._charge.get(id, -1), gated._charge.get(id, -1)]
	FcTickGates.knife_gate = was_gate
	print("  knives: %d steps, %d skipped" % [KNIFE_STEPS, skips])
	_check(skips > KNIFE_STEPS / 4 and skips < KNIFE_STEPS, "the seeded knife steps both skip and run", str(skips))
	_check(diff == 0, "gated knives equal the full input and charge_of to the bit", "%d differ; %s" % [diff, first])
	ref.free()
	gated.free()


func _flush_part() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 1
	var games: Array[FcGame] = [FcGame.new(), FcGame.new()]
	var players: Array = [[], []]
	var shots: Array = [[] as Array[GSShot], [] as Array[GSShot]]
	for g in 2:
		games[g].config.spawn_protection_break = 0
		games[g].config.spawn_protection_move_feet = 0.0
		for i in PLAYERS:
			var p := FcPlayer.new()
			p.health = GSHealth.new()
			players[g].append(p)
	var was_skip := FcTickGates.flush_idle_skip
	var skips := 0
	var diff := 0
	var first := ""
	var tick := 1000
	for step in FLUSH_STEPS:
		tick += rng.randi_range(0, 2)
		var bubble := rng.randf() < 0.7
		var k := rng.randi_range(0, PLAYERS - 1)
		var id := k + 1
		var until := tick + rng.randi_range(-40, 40) if rng.randf() < 0.5 else -1
		var invulnerable := rng.randf() < 0.03
		var view := rng.randf() < 0.5
		var anchored := rng.randf() < 0.3
		var shot_count := 0 if rng.randf() < 0.75 else rng.randi_range(1, 2)
		var spawn_count := 0 if rng.randf() < 0.9 else 1
		var move := GSFpsCommand.new()
		if rng.randf() < 0.3:
			move.move = Vector2(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0))
		for g in 2:
			var game: FcGame = games[g]
			var p: FcPlayer = players[g][k]
			game._tick = tick
			game.config.spawn_protection_bubble = bubble
			p.health.invulnerable_until_tick = until
			p.health.invulnerable = invulnerable
			p.protected_view = view
			if anchored:
				game._protect_anchor[id] = Vector3(id, 0.0, 0.0)
			var outcome := GSWeaponOutcome.new()
			for s in shot_count:
				outcome.shots.append(GSShot.new())
			for s in spawn_count:
				outcome.spawns.append(GSWeaponSpawn.new())
			FcTickGates.flush_idle_skip = g == 1
			if g == 1 and FcTickGates.idle_outcome(outcome, p.health, tick):
				skips += 1
			game._post_flushed(id, p, move, outcome, shots[g])
		var a: FcPlayer = players[0][k]
		var b: FcPlayer = players[1][k]
		var same: bool = a.protected_view == b.protected_view \
				and var_to_bytes(games[0]._protect_anchor) == var_to_bytes(games[1]._protect_anchor) \
				and shots[0].size() == shots[1].size()
		if not same:
			diff += 1
			if first == "":
				first = "step %d id %d: view %s/%s anchors %s/%s shots %d/%d" % [step, id, a.protected_view, b.protected_view,
						games[0]._protect_anchor, games[1]._protect_anchor, shots[0].size(), shots[1].size()]
	FcTickGates.flush_idle_skip = was_skip
	print("  flush: %d steps, %d skipped" % [FLUSH_STEPS, skips])
	_check(skips > FLUSH_STEPS / 10 and skips < FLUSH_STEPS, "the seeded flush posts both skip and post", str(skips))
	_check(diff == 0, "the flush idle skip leaves anchors, protected_view and shots as _post_outcome does", "%d differ; %s" % [diff, first])
	for g in 2:
		for p: FcPlayer in players[g]:
			p.free()
		games[g].free()
