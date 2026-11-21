extends Node

const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcEvents := preload("../game/fc_events.gd")

## The jail's gate on one clock (jail-sim-tick-1): when it opens and who it lets out, on the server and in
## a client's prediction after replays; only outcomes are checked, so the script runs before and after.
## Run: godot --headless --path . res://examples/headless_jail_clock.tscn

const TICK_RATE := 64
const EXPECTED_CHECKS := 6
const MAP := &"surf_10x_reloaded_fixed"
## The game ticks before the late player joins: its motor count then trails the first player's by this.
const LATE_BY := 200
## Ticks a snapshot replays on a mismatch (about a 100 ms round trip at 64 ticks), and how many such
## replays the client makes while the gate is open: their sum is how far the client's own count runs ahead.
const REPLAY_TICKS := 6
const REPLAYS := 3

## What one player saw of the gate before jail-sim-tick-1, recorded by this script on the code before it
## (main 5b7d015). Each probe is the ticks after the press, then out (let out) or back (put back in the cell),
## then the ticks after closing until a press opens it again.
const SERVER_BEFORE := "1:out 32:out 63:out 64:back 65:back 100:back | reopen after 128"

var _checks := 0
var _failed := 0
var _game: Node = null
var _jail: RefCounted = null
var _gate: Dictionary = {}
var _opened := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	Engine.physics_ticks_per_second = TICK_RATE
	_run.call_deferred()


func _check(condition: bool, what: String, detail: String = "") -> void:
	_checks += 1
	if not condition:
		_failed += 1
	print("  [%s] %s%s" % ["ok" if condition else "FAIL", what, ("  (" + detail + ")") if detail != "" else ""])


func _new_game(authority: bool, game_name: String) -> Node:
	var game := FcGame.new()
	game.name = game_name
	game.tick_rate = TICK_RATE
	game.headless = true
	game.register_service = false
	game.is_authority = authority
	game.mode = FcMode.free_for_all(50)
	add_child(game)
	var made: GSResult = game.setup(FcMap.imported(MAP))
	if not made.ok:
		return null
	game.jail_rules["open"] = 1.0
	game.jail_rules["cooldown"] = 2.0
	game.apply_jail_rules()
	return game


func _join(game: Node, id: int) -> Variant:
	var _a: GSResult = game.add_player(id, "p%d" % id)
	var player = game.player_for(id)
	if player != null and not player.is_alive():
		var _r: GSResult = game.respawn_player(id)
	return player


## Where [param player] ended up after walking into the way out: "out", "back" (the cell) or "lost".
func _where(player) -> String:
	var at: Vector3 = player.controller.state.position
	if at.distance_to(_gate["to"]) < 0.5:
		return "out"
	if at.distance_to(_jail.cell()) < 0.5:
		return "back"
	return "lost %s" % at


func _hold_in_cell(players: Array) -> void:
	for p in players:
		p.controller.teleport(_jail.cell(), 0.0, 0.0)


## One server tick with [param who] stepping into the way out and the rest held in the cell.
func _probe(who, others: Array) -> String:
	_hold_in_cell(others)
	who.controller.teleport((_gate["box"] as AABB).get_center(), 0.0, 0.0)
	_game.tick({})
	return _where(who)


func _idle_to(press_tick: int, offset: int, players: Array) -> void:
	while _game.current_tick() + 1 < press_tick + offset:
		_hold_in_cell(players)
		_game.tick({})


## The presser stands on the button for one tick; the game tick it opened on, or -1.
func _press(presser, others: Array) -> int:
	var before := _opened
	_hold_in_cell(others)
	presser.controller.teleport(_jail.button_box().get_center(), 0.0, 0.0)
	_game.tick({})
	return _game.current_tick() if _opened > before else -1


func _run() -> void:
	print("arena — the jail's gate on the game tick")
	if FcMap.imported(MAP) == null:
		print("  skip  %s is not linked (fc-surf-dm-maps)" % MAP)
		get_tree().quit(0)
		return
	_game = _new_game(true, "S")
	_check(_game != null and _game.map.jail != null, "a server sets up on a map with a jail")
	if _game == null or _game.map.jail == null:
		_finish()
		return
	_jail = _game.map.jail
	_gate = _game.map.pits[_jail.exit_indices[0]]
	_game.jail_changed.connect(func() -> void: _opened += 1)
	_game.start(0)

	var first = _join(_game, 2)
	for i in LATE_BY:
		_game.tick({})
	var late = _join(_game, 3)
	_game.tick({})
	_check(first.is_alive() and late.is_alive(), "two players, the second joined %d ticks after the first" % LATE_BY)

	_server_one_player(first, late)
	_server_two_clocks(first, late)
	_client_after_replays(first, late)
	_finish()


## The authoritative outcome for the player who pressed: unchanged by jail-sim-tick-1.
func _server_one_player(first, late) -> void:
	print("-- the server, one player: when the gate opens, how long, and when it opens again")
	var pressed := _press(first, [late])
	var seen: PackedStringArray = []
	for offset: int in [1, 32, 63, 64, 65, 100]:
		_idle_to(pressed, offset, [first, late])
		seen.append("%d:%s" % [offset, _probe(first, [late])])
	var shut: int = pressed + _jail.open_ticks
	var reopened := -1
	while reopened < 0 and _game.current_tick() < shut + 6 * TICK_RATE:
		var at := _press(first, [late])
		if at >= 0:
			reopened = at
	var line := "%s | reopen after %d" % [" ".join(seen), reopened - shut]
	print("  SERVER %s" % line)
	_check(line == SERVER_BEFORE, "the server's outcome for the presser is what it was before the change",
		"%s, before: %s" % [line, SERVER_BEFORE])
	# Shut and cooled from here on: wait out this opening.
	_idle_to(reopened, _jail.open_ticks + _jail.cooldown_ticks + 1, [first, late])


## Before: the gate opened on the presser's count and each player was asked on their own, so a player
## who joined later (or had been dead) met a gate that was still shut for them.
func _server_two_clocks(first, late) -> void:
	print("-- the server, two players: one presses, the other is let out")
	var pressed := _press(first, [late])
	_idle_to(pressed, 5, [first, late])
	var got := _probe(late, [first])
	_check(pressed >= 0 and got == "out",
		"a gate the first player opened lets the late joiner out 5 ticks later", got)
	_idle_to(pressed, _jail.open_ticks + _jail.cooldown_ticks + 1, [first, late])


## A predicting client: its own game, told the gate by JAIL, simulating its player on the server's
## tick numbers (as `FcPlayerNet._predict` does), replaying as dot-net does after a mismatch.
func _client_after_replays(first, late) -> void:
	print("-- a predicting client, after replays, sees the gate the server sees")
	var client := _new_game(false, "C")
	var mine = _join(client, 2) if client != null else null
	_check(mine != null and mine.controller != null, "a client game holds its own player")
	if mine == null or mine.controller == null:
		return
	var delta := 1.0 / float(TICK_RATE)
	# The old code's best case: the client's count starts equal to the server's.
	mine.controller.state.tick = first.controller.state.tick

	var pressed := _press(first, [late])
	mine.controller.teleport(_jail.button_box().get_center(), 0.0, 0.0)
	var _s = mine.simulate_tick(pressed, delta, GSFpsCommand.new(), GSWeaponCommand.new())
	var j: RefCounted = _jail
	client.apply_jail_state(FcEvents.read_jail(GSNetReader.new(
		FcEvents.write_jail(j.enabled, j.open_ticks, j.cooldown_ticks, j.opened_at))))

	# Ticks pressed+1 .. probe-1 in the cell, each predicted once, and REPLAYS of them replayed again.
	var probe_at: int = pressed + _jail.open_ticks - 2 * REPLAY_TICKS
	var replays := 0
	for t in range(pressed + 1, probe_at):
		_hold_in_cell([first, late])
		_game.tick({})
		mine.controller.teleport(_jail.cell(), 0.0, 0.0)
		_s = mine.simulate_tick(t, delta, GSFpsCommand.new(), GSWeaponCommand.new())
		if replays < REPLAYS and t >= pressed + REPLAY_TICKS * (replays + 1):
			replays += 1
			for r in range(t - REPLAY_TICKS + 1, t + 1):
				mine.controller.teleport(_jail.cell(), 0.0, 0.0)
				_s = mine.simulate_tick(r, delta, GSFpsCommand.new(), GSWeaponCommand.new())

	var server_got := _probe(first, [late])
	mine.controller.teleport((_gate["box"] as AABB).get_center(), 0.0, 0.0)
	_s = mine.simulate_tick(probe_at, delta, GSFpsCommand.new(), GSWeaponCommand.new())
	var client_got := _where(mine)
	_check(server_got == "out" and client_got == server_got,
		"after %d replays of %d ticks the client predicts the way out like the server" % [replays, REPLAY_TICKS],
		"server %s, client %s, %d ticks after the press" % [server_got, client_got, probe_at - pressed])
	client.queue_free()


func _finish() -> void:
	var ok := _failed == 0 and _checks == EXPECTED_CHECKS
	print("%d checks, %d failed (expected %d)" % [_checks, _failed, EXPECTED_CHECKS])
	if _game != null:
		_game.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if ok else 1)
