extends "headless_ctf.gd"

## Thinking bots play capture the flag on their own for a few minutes: someone must score a capture.
## The play test's 17 minutes of 32 against 32 never showed one.

const FcBots := preload("../game/fc_bots.gd")

const SECTIONS_SIM := 2
const CHECKS_SIM := 6
const SIM_SECONDS := 240


func _run() -> void:
	print("game-fatal-contact headless ctf bot sim")
	print("")
	await _test_bots_capture("4v4", [910, 911, 912, 913, 914, 915, 916, 917])
	var crowd: Array = []
	for i in 64:
		crowd.append(1000 + i)
	await _test_bots_capture("32v32", crowd)
	_report_sections(_entered, _completed, SECTIONS_SIM, CHECKS_SIM)


func _test_bots_capture(label: String, ids: Array) -> void:
	_section("ctf bot sim %s: thinking bots capture on their own" % label)
	var game := _ctf_game(Callable(), null, ids)
	if game == null:
		return
	var ctf := game.objectives.ctf
	var minds := {}
	for id in game.player_ids():
		minds[id] = FcBots.Mind.new()
	var takes := 0
	var last := {1: "", 2: ""}
	for i in TICK_RATE * SIM_SECONDS:
		var cmds := {}
		for id: int in minds:
			cmds[id] = FcBots.think(game, game.player_for(id), minds[id], game.current_tick() + 1, float(TICK_RATE))
		game.tick(cmds)
		for t in [1, 2]:
			var f := _flag(game, t)
			var s := "%d/%s" % [int(f.state), f.carrier]
			if s != last[t]:
				last[t] = s
				if i % 1 == 0:
					print("t=%.1fs flag%d state=%d carrier=%s scores=%s" % [float(i) / TICK_RATE, t, int(f.state), f.carrier, ctf.scores])
				if int(f.state) == GSObjectiveFlag.State.CARRIED:
					takes += 1
	var total := 0
	for k in ctf.scores:
		total += int(ctf.scores[k])
	print("takes=%d captures=%d" % [takes, total])
	_check(takes > 0, "bots pick up the enemy flag", str(takes))
	_check(total > 0, "and bring one home within %d s" % SIM_SECONDS, str(ctf.scores))
	await _free(game)
	_done()
