extends GSGameCheckSuite

## FcNetAoi: the relevance rings are off for a 16v16, on above sv_net_aoi_players with
## hysteresis, read their cvars live, and describe the same rings dot-net applies.

const FcNetAoi := preload("../game/fc_net_aoi.gd")


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("arena: net relevance rings")
	var console := GSConsole.new()
	add_child(console)
	var aoi := FcNetAoi.new()
	aoi.bind_cvars(console.cvar, GSConVar.FLAG_ARCHIVE)
	var interest := GSNetInterestDistance.new()
	var base := [interest.radius, interest.far_every, interest.far_distance, interest.far_tiers, interest.far_coherent, interest.aim_cone_deg]

	_check(console.get_int("sv_net_aoi_players") == 32 and is_equal_approx(console.get_float("sv_net_radius"), 120.0), "defaults: rings from the 33rd player, 120 m radius")
	_check(console.get_int("sv_net_far_every") == 2 and console.get_int("sv_net_far_tiers") == 2 and is_equal_approx(console.get_float("sv_net_far_distance"), 15.0) and is_equal_approx(console.get_float("sv_net_aim_cone"), 8.0), "defaults: far rings on (far_every 2, dot-net syncs thinned acks), two bands from 15 m, an 8 degree aim cone")

	for players in [1, 16, 31, 32]:
		var changed := aoi.refresh(interest, players)
		_check(not changed and not aoi.active, "%d players: rings stay off" % players)
		_check([interest.radius, interest.far_every, interest.far_distance, interest.far_tiers, interest.far_coherent, interest.aim_cone_deg] == base, "%d players: the interest object is exactly as it was" % players)

	_check(aoi.refresh(interest, 33) and aoi.active, "33 players turn the rings on")
	_check(is_equal_approx(interest.radius, 120.0) and interest.far_every == 2 and interest.far_tiers == 2 and interest.far_coherent and is_equal_approx(interest.far_distance, 15.0) and is_equal_approx(interest.aim_cone_deg, 8.0), "and set radius, divisor, bands, coherence and aim cone on the interest")
	_check(not aoi.refresh(interest, 32) and aoi.active, "32 players do not turn them off again (hysteresis)")
	_check(not aoi.refresh(interest, 31) and aoi.active, "nor 31")
	_check(aoi.refresh(interest, 30) and not aoi.active, "30 players do")
	_check([interest.radius, interest.far_every, interest.far_distance, interest.far_tiers, interest.far_coherent, interest.aim_cone_deg] == base, "and the interest is back to what it was")

	console.set_cvar("sv_net_aoi_players", "0")
	console.set_cvar("sv_net_radius", "50")
	console.set_cvar("sv_net_far_distance", "10")
	console.set_cvar("sv_net_far_every", "4")
	console.set_cvar("sv_net_far_tiers", "3")
	console.set_cvar("sv_net_far_coherent", "0")
	console.set_cvar("sv_net_aim_cone", "15")
	_check(aoi.refresh(interest, 2) and aoi.active, "sv_net_aoi_players 0 is always on")
	_check(is_equal_approx(interest.radius, 50.0) and interest.far_every == 4 and interest.far_tiers == 3 and not interest.far_coherent and is_equal_approx(interest.far_distance, 10.0) and is_equal_approx(interest.aim_cone_deg, 15.0), "cvars are read live")
	console.set_cvar("sv_net_far_every", "99")
	var _r := aoi.refresh(interest, 2)
	_check(interest.far_every == 99, "sv_net_far_every has no ceiling")
	console.set_cvar("sv_net_far_tiers", "9")
	var _t := aoi.refresh(interest, 2)
	_check(interest.far_tiers == 3, "sv_net_far_tiers past 4 is refused, the value stays")
	console.set_cvar("sv_net_aim_cone", "200")
	var _c := aoi.refresh(interest, 2)
	_check(is_equal_approx(interest.aim_cone_deg, 15.0), "sv_net_aim_cone past 180 is refused, the value stays")
	console.set_cvar("sv_net_aim_cone", "0")
	var _z := aoi.refresh(interest, 2)
	_check(interest.aim_cone_deg == 0.0, "sv_net_aim_cone 0 turns the cone off")
	console.set_cvar("sv_net_aoi_players", "9999")
	_check(aoi.refresh(interest, 128) == true and not aoi.active, "9999 turns them off whatever the count")

	var a := FcNetAoi.new()
	_check(a.ring_of(0.0) == 0 and a.ring_of(15.0) == 0 and a.ring_of(15.1) == 1 and a.ring_of(30.0) == 1 and a.ring_of(30.1) == 2 and a.ring_of(120.0) == 2 and a.ring_of(120.1) == -1, "default rings: full rate to 15 m, half to 30 m, a quarter to 120 m, none past")
	_check(a.every_for(0) == 1 and a.every_for(1) == 2 and a.every_for(2) == 4, "full, half and quarter rate")
	_check(a.every_for_aimed(2, 8.0) == 2 and a.every_for_aimed(2, 8.1) == 4 and a.every_for_aimed(1, 0.0) == 2 and a.every_for_aimed(0, 0.0) == 1, "inside the aim cone the quarter band goes at half rate, nothing else changes")
	a.aim_cone_deg = 0.0
	_check(a.every_for_aimed(2, 0.0) == 4, "aim cone 0: off")
	a.far_tiers = 1
	_check(a.ring_of(80.1) == 1 and a.ring_of(120.0) == 1 and a.ring_of(15.1) == 1, "far_tiers 1: half rate to 120 m")
	a.far_tiers = 1
	a.far_every = 1
	_check(a.ring_of(119.0) == 0 and a.ring_of(120.1) == -1 and a.every_for(a.ring_of(119.0)) == 1, "far_every 1: every snapshot to 120 m, nothing past")
	console.free()
	_report()
