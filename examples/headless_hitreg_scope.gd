extends "headless_hitreg_ping.gd"

## "Some of those shots DEFINITELY hit the player": a scoped rifle at range, as it is played. headless_hitreg_ping zeroes the gun's noise to prove the netcode; these rounds keep the tuning. The shooter holds the aim all round (scoped, still) and shoots the middle of the
## drawn torso every second and a half, at [constant RANGES], over the owner's 20 ms and 50 ms. The target is peer 3 walking at the shooter while it strafes and toggles crouch (also with the relevance rings on: 30 m is in the half-rate band and 60 m in the quarter-rate band, but inside the shooter's aim cone, FcNetAoi.aim_cone_deg, so both ranges arrive every second snapshot), then a server bot playing
## with its own brain (the owner's video shot bots at 60 m). A scoped sniper shot from a still shooter has no cone to miss with: the server must register every one.

const FcNetAoi := preload("../game/fc_net_aoi.gd")

const SCOPE_PINGS: Array[int] = [20, 50]
const RANGES: Array[float] = [30.0, 60.0]
const SCOPE_CHECKS := 116


func _run() -> void:
	print("game-fatal-contact headless scoped hit registration at range, tuning kept")
	_build()
	_as_played = true
	var weapons := _scoped_weapons()
	_check(not weapons.is_empty(), "the pack has a scoped hitscan gun of the sniper class", str(weapons))
	for ping in SCOPE_PINGS:
		_section("ping %d ms, scoped, at a player" % ping)
		_rounds(weapons, ping)
		_done()

	# A big room (sv_net_aoi_players, from the 33rd player) sends a player 15-30 m out every
	# second snapshot and 30-120 m every fourth, except inside the shooter's aim cone, where it
	# stays every second: the client draws it from half the samples the server rewinds through.
	var rings := FcNetAoi.new()
	rings.min_players = 0
	_check(_server_net.interest != null and rings.refresh(_server_net.interest, 3), "the relevance rings go on", str(_server_net.interest))
	for ping in SCOPE_PINGS:
		_section("ping %d ms, scoped, at a player, relevance rings on" % ping)
		_rounds(weapons, ping)
		_done()
	rings.min_players = 9999
	var _off := rings.refresh(_server_net.interest, 3)

	_section("a server bot joins")
	# With its weapon styles on: a style crouches the bot, and the rewind carries the crouch it was drawn with
	# (nightly bot-crouch-rewind-60m-1).
	var bot: int = _server_bridge.add_bot("Bolt")
	_check(bot != 0, "the server adds a bot")
	for peer_id: int in _clients:
		_check(_clients[peer_id]["bridge"].apply_join(_joins[_joins.size() - 1]).ok, "client %d mirrors the bot" % peer_id)
	_target = bot
	_done()
	for ping in SCOPE_PINGS:
		_section("ping %d ms, scoped, at a bot" % ping)
		_rounds(weapons, ping)
		_done()
	_report_sections(_entered, _completed, 2 + 3 * SCOPE_PINGS.size(), SCOPE_CHECKS)


func _rounds(weapons: Array[StringName], ping: int) -> void:
	for id in weapons:
		for r in RANGES:
			_range = r
			_round(id, ping)


## The hitscan guns of dot-weapon's "sniper" accuracy class with no cone of their own when
## aimed (a marksman rifle that keeps one is a gun's choice, not the netcode's).
func _scoped_weapons() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _hitscan_weapons():
		var def: DotWeaponDef = FcPlayer.weapon_catalogue().get_def(id)
		var tuning := def.tuning as DotWeaponBallistics
		if DotWeaponAccuracyClass.resolve(tuning.accuracy_class, def.tags, def.id) != "sniper":
			continue
		if tuning.accuracy("spread_aim", "sniper") == 0.0:
			out.append(id)
	return out
