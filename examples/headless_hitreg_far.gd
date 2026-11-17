extends "headless_hitreg_chaos.gd"

## "Hit registration sucks at times" (the owner's recording): far shots in a full room. With more than sv_net_aoi_players in it (64 bots here, 66 players) the relevance rings (ArenaNetAoi) send a player 30-120 m out every fourth snapshot, every second inside the shooter's aim cone; a flick onto a far player shoots it before the cone has caught up (cone 0 here).
## The client draws such a player from its own sparse samples, blended across eight ticks or carried on past the newest (DotNetInterpolator._extrapolate), and the server's rewind must stand the body where that frame drew it, not where its every-tick ring had it (ArenaNetBridge.shot_feet, the per-target view a command carries).
## Every tap is aimed at the drawn torso, middle and edges, with the gun's noise zeroed as headless_hitreg_ping does, at 35, 46.8 and 60 m, over round trips of 30, 60 and 100 ms: on a clean link, with a seeded 0-30 ms jitter, and with the jitter and one snapshot to the shooter lost before each tap. Each miss is put down to its cause from the target's own samples. Then the recording's other cases: a scoped Marksman at a bot 46.8 m out (7:35.2; still and playing, hitscan as shipped and a flying round under sv_ballistics), every bot in the rewind ring every tick, the carbine's 100 to 37 in three hits, and the drum shotgun's pellets by distance (16 is two of its seven 8-point pellets). Deterministic: clocks by hand, seeded draws, the buffer set rather than adapted.

const ArenaNetAoi := preload("../game/arena_net_aoi.gd")
const ArenaNetCommand := preload("../game/arena_net_command.gd")

const FAR_RTTS: Array[int] = [30, 60, 100]
const FAR_RANGES: Array[float] = [35.0, 46.8, 60.0]
const FAR_WEAPONS: Array[StringName] = [&"carbine", &"marksman"]
## name, jitter ms, one snapshot to the shooter lost before each tap.
const FAR_LINKS: Array = [
	["clean", 0.0, false],
	["jitter 0-30 ms", 30.0, false],
	["jitter 0-30 ms, a snapshot lost before each tap", 30.0, true],
]
const BOTS := 64
const SCOPED_RANGE := 46.8
const SHOTGUN_RANGES: Array[float] = [2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 14.0]
## The share of all far taps that must hit; what misses is the client's resume ease (DotNetInterpolator._ease_resume), the client's alone.
const FAR_HIT_FLOOR := 0.95

var _aoi: ArenaNetAoi = null
var _drop_before := false
var _round_base := -1
var _dropped := 0
## "link|rtt|range|weapon|cone" -> [resolved, hit, causes{}, rewind errors[], not easing, not easing hit]
var _far: Dictionary = {}
var _cone := 0.0
## far, scoped, bullets, burst, shotgun.
var _mode := ""
var _damage_log: Array[Dictionary] = []
var _bullet_hits := 0
var _marked := 0
## The room's bots, stood back in their places at every round (a bot joins dead and the game spawns it on a map spawn, in the lane).
var _bots: Array[int] = []
const BOT_SPAWN_WAIT_TICKS := 2000


func _run() -> void:
	print("game-fatal-contact headless far hit registration: relevance rings, sparse samples, 64 bots")
	_build()
	_damage_hook()
	var net: DotNetManager = _clients[SHOOTER_PEER]["net"]
	print("    tick %d Hz, snapshots every %d ticks, interp %.1f ticks, max extrapolation %.3f s, resume ease %.3f s" % [
		TICK_RATE, net.config.ticks_per_snapshot(), net.interpolator.delay_ticks(), net.config.max_extrapolation_sec, net.config.resume_ease_sec])
	_section("64 bots fill the room")
	_add_bots()
	_done()

	_mode = "far"
	for link: Array in FAR_LINKS:
		for rtt in FAR_RTTS:
			_far_section(link, rtt, 0.0, FAR_RANGES)
	# The same at 46.8 m with the aim cone at its shipped 8 degrees, and with the rings off: what the rings cost.
	var lossy: Array = FAR_LINKS[2]
	for rtt in FAR_RTTS:
		_far_section(lossy, rtt, 8.0, [SCOPED_RANGE])
	_aoi.min_players = 9999
	var _off := _aoi.refresh(_server_net.interest, _server_game.players().size())
	for rtt in FAR_RTTS:
		_far_section(lossy, rtt, -1.0, [SCOPED_RANGE])
	_aoi.min_players = 32
	var _on := _aoi.refresh(_server_net.interest, _server_game.players().size())
	_mode = ""
	_far_summary()

	_scoped_bot_sections()
	_bots_recorded_section()
	_burst_section()
	_shotgun_section()
	_ease_wire_section()
	_counters_section()
	_report_sections(_entered, _completed, _entered, -1)


# The room.

func _add_bots() -> void:
	var first := _joins.size()
	var bots: Array[int] = []
	for n in BOTS:
		var id: int = _server_bridge.add_bot("Bot%02d" % n)
		if id == 0:
			break
		bots.append(id)
		# No brain: they stand where they are put, clear of the lane, and only fill the room.
		_server_bridge._bot_minds.erase(id)
	_check(bots.size() == BOTS, "the server adds %d bots" % BOTS, "%d" % bots.size())
	for peer_id: int in _clients:
		var mirrored := 0
		for payload in _joins.slice(first):
			if _clients[peer_id]["bridge"].apply_join(payload).ok:
				mirrored += 1
		_check(mirrored == bots.size(), "client %d mirrors every bot" % peer_id, "%d of %d" % [mirrored, bots.size()])
	_bots = bots
	# The game spawns each bot on a map spawn, in the lane, on a later tick: let that happen, then stand them off it.
	var spawned := {}
	for id in bots:
		var _c := _server_game.player_for(id).spawned.connect(func(_at: Transform3D) -> void: spawned[id] = true)
	var waited := 0
	while waited < BOT_SPAWN_WAIT_TICKS and bots.any(func(id: int) -> bool: return not spawned.has(id) or not _server_game.player_for(id).is_alive()):
		var _t := _step_once(0, false, waited, 0)
		waited += 1
	_check(waited < BOT_SPAWN_WAIT_TICKS, "every bot is up within %d ticks" % BOT_SPAWN_WAIT_TICKS, "%d ticks" % waited)
	_stand_bots()
	_wait_out_protection()
	_aoi = ArenaNetAoi.new()
	var players := _server_game.players().size()
	var _changed := _aoi.refresh(_server_net.interest, players)
	_check(_aoi.active, "the relevance rings go on by themselves at %d players (sv_net_aoi_players %d)" % [players, _aoi.min_players])


## Each room bot to its place on the grid at x 30-58, z 10-38: off the lane (the shooter at the origin, the target down -z, peer 3 at x 40 on z 0) and out of every trace.
func _stand_bots() -> void:
	var tick := _server_game.current_tick()
	for i in _bots.size():
		var at := Vector3(30.0 + 4.0 * float(i % 8), 0.05, 10.0 + 4.0 * float(i / 8))
		for p in _players(_bots[i]):
			if p != null:
				p.spawn(Transform3D(Basis(), at), tick)


func _place(weapon_id: StringName, def: DotWeaponDef, distance: float) -> void:
	super(weapon_id, def, distance)
	_stand_bots()


func _set_cone(degrees: float) -> void:
	_aoi.aim_cone_deg = degrees
	ArenaNetAoi._set_cone(_server_net.interest, degrees)


# The far rounds.

func _far_section(link: Array, rtt: int, cone: float, ranges: Array) -> void:
	_link = link[0]
	_jitter_ticks = int(roundf(float(link[1]) / 1000.0 * float(TICK_RATE)))
	_loss = 0.0
	_drop_before = link[2]
	_cone = cone
	if cone >= 0.0:
		_set_cone(cone)
	var period := float((_clients[SHOOTER_PEER]["net"] as DotNetManager).config.ticks_per_snapshot())
	# The adaptive buffer's rule for the jitter (a period and the p95 lateness); two snapshots on a clean link.
	var buffer := 2.0 if _jitter_ticks == 0 else (period + float(_jitter_ticks)) / period
	for peer_id: int in _clients:
		var interp: DotNetInterpolator = _clients[peer_id]["net"].interpolator
		interp._delay_snapshots = buffer
		interp._target_snapshots = buffer
	_section("far: %s, rtt %d ms, %s, interp %.1f ticks" % [_link, rtt,
		"rings off" if cone < 0.0 else "rings on, aim cone %.0f deg" % cone, buffer * period])
	_ease_reset()
	_dropped = 0
	for r: float in ranges:
		_range = r
		for id in FAR_WEAPONS:
			var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(id)
			if def == null or (def.tuning as DotWeaponBallistics).max_range < r:
				continue
			_rng.seed = hash([_link, rtt, String(id), r])
			_move_rng.seed = hash([rtt, String(id), r])
			_plan_strafe()
			_round(id, rtt)
	print("    snapshots to the shooter lost before taps: %d; resume ease: %d frames off the blend, largest %.3f m" % [_dropped, _eased_frames, _ease_most])
	_range = 0.0
	_drop_before = false
	_done()


func _fire_taps(def: DotWeaponDef, taps: int) -> int:
	_round_base = _step
	var sent := super(def, taps)
	_round_base = -1
	return sent


## Loses one snapshot to the shooter before each tap, sent 2 to 5 snapshot periods before what the shooter draws when it fires (by tap), so every phase against the target's sparse samples comes round.
func _drop_now(peer_id: int, delivery: int) -> bool:
	if not _drop_before or _round_base < 0 or peer_id != SHOOTER_PEER or delivery != DotNetMessage.Delivery.UNRELIABLE:
		return false
	var since := _step - _round_base - 1 - SETTLE_TICKS
	if since < -_tap_ticks:
		return false
	var period := (_clients[SHOOTER_PEER]["net"] as DotNetManager).config.ticks_per_snapshot()
	var tap := floori(float(since) / float(_tap_ticks))
	for t in [tap, tap + 1]:
		if t < 0:
			continue
		var fires: int = t * _tap_ticks
		var lost: int = fires - _down_ticks - _jitter_ticks - period * (2 + t % 4)
		if since >= lost and since < lost + period:
			return true
	return false


func _build() -> void:
	super()
	_server_net.send_fn = func(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
		var at := _down_at()
		if at >= 0 and _drop_now(peer_id, delivery):
			_dropped += 1
			at = -1
		if at >= 0:
			_down.append({"at": at, "peer": peer_id, "bytes": payload})


func _read_frame(k: int) -> void:
	super(k)
	if not _last_frame.is_empty():
		_last_frame["track"] = _track_view(float(_last_frame["time"]))


## The target's own samples on the shooter's client around [param render_tick], as DotNetInterpolator.sample picks them: {older, newer, ahead (past the newest)}.
func _track_view(render_tick: float) -> Dictionary:
	var net: DotNetManager = _clients[SHOOTER_PEER]["net"]
	var behaviour: DotNetBehaviour = (_clients[SHOOTER_PEER]["bridge"] as ArenaNetBridge)._behaviours.get(_target)
	if behaviour == null or behaviour.identity == null:
		return {}
	var track: Variant = net.interpolator._tracks.get(behaviour.identity.net_id)
	if track == null or track.samples.size() < 2:
		return {}
	var s: Array = track.samples
	var last := s.size() - 1
	if render_tick >= float(s[last]["tick"]):
		return {"older": int(s[last - 1]["tick"]), "newer": int(s[last]["tick"]), "ahead": true}
	for i in range(last - 1, -1, -1):
		if render_tick > float(s[i]["tick"]):
			return {"older": int(s[i]["tick"]), "newer": int(s[i + 1]["tick"]), "ahead": false}
	return {"older": int(s[0]["tick"]), "newer": int(s[0]["tick"]), "ahead": false}


func _judge(weapon_id: StringName, ping: int, c: Dictionary) -> void:
	match _mode:
		"far":
			_judge_far(weapon_id, ping, c)
		"scoped":
			_check(int(c["matched"]) >= int(c["sent"]) - 1, "%d ms %s: the server resolves the scoped shots" % [ping, weapon_id], "%d of %d" % [c["matched"], c["sent"]])
			_check(int(c["hit"]) == int(c["matched"]), "%d ms %s: every scoped shot at the drawn chest hits" % [ping, weapon_id], "%d of %d; %s" % [c["hit"], c["matched"], c["first_miss"]])
		"bullets", "burst", "shotgun":
			pass
		_:
			super(weapon_id, ping, c)


func _judge_far(weapon_id: StringName, ping: int, c: Dictionary) -> void:
	var period := float((_clients[SHOOTER_PEER]["net"] as DotNetManager).config.ticks_per_snapshot())
	var key := "%s|%d|%.1f|%s|%s" % [_link, ping, _range, weapon_id, "off" if _cone < 0.0 else str(int(_cone))]
	var row: Array = _far.get_or_add(key, [0, 0, {}, [], 0, 0])
	row[0] += int(c["matched"])
	row[1] += int(c["hit"])
	var unresolved := int(c["sent"]) - int(c["matched"])
	if unresolved > 0:
		row[2]["unresolved"] = int(row[2].get("unresolved", 0)) + unresolved
	var worst_drawn := 0.0
	var worst_how := ""
	for r in _resolved:
		var seen: Dictionary = _drawn_for.get(int(r["tick"]), {})
		if seen.is_empty():
			continue
		var track: Dictionary = seen.get("track", {})
		var eased := float(seen.get("eased", 0.0)) > EASED_M
		var err := float(r["rewind_error"])
		(row[3] as Array).append(err)
		if not eased:
			row[4] += 1
			if r["hit"]:
				row[5] += 1
			if err > worst_drawn:
				worst_drawn = err
				worst_how = "tick %d drawn at %.2f track %s, rewound %s at %.2f" % [int(r["tick"]), float(seen["time"]), track,
					"blended" if r.get("blended", false) else "on the ring", float(r.get("view", -1.0))]
		if r["hit"]:
			continue
		var cause := "rewind off"
		if eased:
			cause = "easing out of an extrapolation"
		elif not track.is_empty() and track["ahead"]:
			cause = "extrapolated past the newest sample"
		elif not track.is_empty() and float(int(track["newer"]) - int(track["older"])) > period:
			cause = "blended across sparse samples"
		elif err <= REWIND_TOLERANCE_M:
			cause = "rewound right"
		row[2][cause] = int(row[2].get(cause, 0)) + 1
	print("      %-9s at %4.1f m: hit %2d of %2d resolved (%d sent); not easing: rewind worst %.3f m %s" % [
		weapon_id, _range, int(c["hit"]), int(c["matched"]), int(c["sent"]), worst_drawn, worst_how if worst_drawn > REWIND_TOLERANCE_M else ""])
	var tag := "%s %d ms %.1f m %s cone %s" % [_link, ping, _range, weapon_id, key.get_slice("|", 4)]
	_check(int(c["matched"]) >= int(c["sent"]) - 1, "%s: the server resolves the taps" % tag, "%d of %d" % [c["matched"], c["sent"]])
	_check(worst_drawn <= REWIND_TOLERANCE_M, "%s: the server stands the body where the shooter drew it" % tag, "worst %.3f m; %s" % [worst_drawn, worst_how])


func _far_summary() -> void:
	_section("far hit rate against 100% expected")
	var totals := {}
	for key: String in _far:
		var row: Array = _far[key]
		var errs: Array = (row[3] as Array).duplicate()
		errs.sort()
		var p50: float = errs[errs.size() / 2] if not errs.is_empty() else 0.0
		var worst: float = errs.back() if not errs.is_empty() else 0.0
		print("    %-72s %3d/%-3d %5.1f%%  not easing %3d/%-3d  rewind p50 %.3f worst %.3f  %s" % [key, row[1], row[0],
			100.0 * float(row[1]) / float(maxi(1, row[0])), row[5], row[4], p50, worst, str(row[2])])
		var parts := key.split("|")
		var t: Array = totals.get_or_add("%s|%s ms|cone %s" % [parts[0], parts[1], parts[4]], [0, 0, 0, 0, {}])
		t[0] += int(row[0])
		t[1] += int(row[1])
		t[2] += int(row[4])
		t[3] += int(row[5])
		for cause: String in row[2]:
			t[4][cause] = int(t[4].get(cause, 0)) + int(row[2][cause])
	for key: String in totals:
		var t: Array = totals[key]
		var rate := float(t[1]) / float(maxi(1, t[0]))
		print("    ALL %-60s %5.1f%% (%d of %d); not easing %5.1f%% (%d of %d); misses %s" % [key, 100.0 * rate, t[1], t[0],
			100.0 * float(t[3]) / float(maxi(1, t[2])), t[3], t[2], str(t[4])])
		_check(t[3] == t[2], "%s: every tap at a body drawn off its samples (not easing) hits" % key, "%d of %d" % [t[3], t[2]])
		_check(rate >= FAR_HIT_FLOOR, "%s: at least %.0f%% of all taps hit" % [key, FAR_HIT_FLOOR * 100.0], "%.1f%%" % (100.0 * rate))
	_done()


# The recording's other cases.

## A server bot to shoot, mirrored on the clients: brainless (still) until [method _scoped_bot_sections] gives it its mind.
func _marked_bot() -> int:
	if _marked != 0:
		return _marked
	_marked = _server_bridge.add_bot("Marked")
	_check(_marked != 0, "the server adds a bot to shoot")
	for peer_id: int in _clients:
		_check(_clients[peer_id]["bridge"].apply_join(_joins[_joins.size() - 1]).ok, "client %d mirrors the bot" % peer_id)
	var waited := 0
	while waited < BOT_SPAWN_WAIT_TICKS and not _server_game.player_for(_marked).is_alive():
		var _t := _step_once(0, false, waited, 0)
		waited += 1
	_check(waited < BOT_SPAWN_WAIT_TICKS, "the bot to shoot is up within %d ticks" % BOT_SPAWN_WAIT_TICKS, "%d ticks" % waited)
	_wait_out_protection()
	return _marked


## Steps past a fresh spawn's protection: a hit it refuses is the game's rule, not the netcode's, and no tap is fired into it.
func _wait_out_protection() -> void:
	for i in _server_game.match_node.spawn_protection_ticks() + 4:
		var _t := _step_once(0, false, i, 0)


## 7:35.2: a scoped Marksman, the shooter nearly still, at a bot's chest 46.8 m out; ammo 10 to 9, no hit.
func _scoped_bot_sections() -> void:
	var marksman: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(&"marksman")
	_check(marksman != null, "the pack has the Marksman")
	if marksman == null:
		return
	var tuning := marksman.tuning as DotWeaponBallistics
	var rules := _server_game.combat_feel.ballistics as DotWeaponBallisticsRules
	print("    marksman: damage %.0f, spread %.2f (%.2f moving), sniper aimed spread %.2f, muzzle velocity %.0f: %s" % [
		tuning.damage, tuning.spread, tuning.spread_moving, tuning.accuracy("spread_aim", "sniper"), tuning.muzzle_velocity,
		"a flying round under sv_ballistics" if DotWeaponTrajectory.is_simulated(tuning) else "hitscan even with sv_ballistics on"])
	_check(not DotWeaponBallisticsRules.simulates(rules, tuning), "as shipped (sv_ballistics 0) the Marksman is hitscan: rewound at the click")
	var bot := _marked_bot()
	var mind: Variant = _server_bridge._bot_minds.get(bot)
	var kept_target := _target
	_target = bot
	_as_played = true
	_range = SCOPED_RANGE
	_link = "jitter 0-30 ms, a snapshot lost before each tap"
	_jitter_ticks = int(roundf(30.0 / 1000.0 * float(TICK_RATE)))
	_drop_before = true
	_set_cone(8.0)
	_mode = "scoped"
	for brain in [false, true]:
		if brain and mind != null:
			_server_bridge._bot_minds[bot] = mind
		else:
			_server_bridge._bot_minds.erase(bot)
		for rtt in FAR_RTTS:
			_section("scoped marksman at a %s bot %.1f m out, rtt %d ms, rings on, a snapshot lost before each tap" % ["playing" if brain else "still", SCOPED_RANGE, rtt])
			_rng.seed = hash(["scoped", rtt, brain])
			_round(&"marksman", rtt)
			_done()
	_server_bridge._bot_minds.erase(bot)
	# sv_ballistics on, the Marksman given a muzzle velocity: the round flies, and each tick of its flight is rewound by the shooter's lag (DotWeaponBullets._fly_tick).
	if rules != null and _server_game.bullet_bridge != null:
		var velocity := tuning.muzzle_velocity
		tuning.muzzle_velocity = 900.0
		rules.set(&"enabled", true)
		_mode = "bullets"
		var counted := func(_id: int, d: DotDamage) -> void:
			if d.victim == _target and not d.refused:
				_bullet_hits += 1
		_server_game.bullet_bridge.bullet_hit.connect(counted)
		for rtt in FAR_RTTS:
			_section("scoped marksman flying a round (sv_ballistics 1, 900 m/s) at a still bot %.1f m out, rtt %d ms" % [SCOPED_RANGE, rtt])
			_bullet_hits = 0
			_rng.seed = hash(["bullets", rtt])
			_round(&"marksman", rtt)
			var taps := _resolved.size()
			print("    rounds fired %d, hits %d" % [taps, _bullet_hits])
			_check(taps >= 2 and _bullet_hits == taps, "%d ms: every round at the still bot's drawn chest hits" % rtt, "%d of %d" % [_bullet_hits, taps])
			_done()
		_server_game.bullet_bridge.bullet_hit.disconnect(counted)
		rules.set(&"enabled", false)
		tuning.muzzle_velocity = velocity
	_mode = ""
	_as_played = false
	_drop_before = false
	_range = 0.0
	_target = kept_target


## The rewind ring holds every bot on every tick (what a rewind without the command's view falls back on).
func _bots_recorded_section() -> void:
	_section("every bot is in the rewind ring every tick")
	var now := _server_game.current_tick()
	var span := 60
	var gaps := 0
	var bots := 0
	for player: ArenaPlayer in _server_game.players():
		if not player.has_meta(&"bot") or not player.is_alive():
			continue
		bots += 1
		for t in range(now - span, now):
			if _server_game.unlag_position_at(player.player_id, float(t)) == null:
				gaps += 1
	_check(bots >= BOTS, "the room has its bots", str(bots))
	_check(gaps == 0, "each of %d bots has a ring entry on each of the last %d ticks" % [bots, span], "%d gaps" % gaps)
	_done()


func _damage_hook() -> void:
	_server_game.combat.shot_resolved.connect(func(shot: DotShot) -> void:
		if shot.attacker != SHOOTER:
			return
		var dealt := 0.0
		var on_body := 0
		var groups: Array[String] = []
		for d: DotDamage in shot.damages:
			if d.victim == _target and not d.refused:
				dealt += d.amount
				on_body += 1
				groups.append("%s %.1f" % [d.hit_group, d.amount])
		_damage_log.append({"tick": shot.tick, "dealt": dealt, "hits": on_body, "pellets": shot.pellets.size(), "groups": groups}))


## 100 to 37 in 0.4 s: three carbine hits of 21, each counted once (a command carried in several packets fires once).
func _burst_section() -> void:
	_section("carbine: three hits take 100 to 37")
	var carbine: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(&"carbine")
	var tuning := carbine.tuning as DotWeaponBallistics
	print("    carbine: damage %.0f, a shot every %d ticks: three hits in %.3f s" % [tuning.damage, carbine.use_interval_ticks,
		2.0 * float(carbine.use_interval_ticks) / float(TICK_RATE)])
	_mode = "burst"
	_link = "clean"
	_jitter_ticks = 0
	_drop_before = false
	_range = 15.0
	_damage_log.clear()
	_round(&"carbine", 60)
	var dealt: Array[float] = []
	var groups := {}
	for d in _damage_log:
		if float(d["dealt"]) > 0.0:
			dealt.append(float(d["dealt"]))
			for g: String in d["groups"]:
				groups[g] = int(groups.get(g, 0)) + 1
	print("    damage a hit %s by group %s" % [dealt, groups])
	_check(_damage_log.size() == _resolved.size(), "each tap resolves once on the server", "%d shots for %d taps" % [_damage_log.size(), _resolved.size()])
	var once := not dealt.is_empty()
	for v in dealt:
		once = once and v <= tuning.damage + 0.001
	_check(once, "no carbine hit deals more than its %.0f (a torso hit; no command fired twice)" % tuning.damage, str(dealt))
	_check(is_equal_approx(100.0 - 3.0 * tuning.damage, 37.0), "three torso hits take 100 to 37", str(100.0 - 3.0 * tuning.damage))
	_range = 0.0
	_mode = ""
	_done()


## The drum shotgun at a still bot's chest, as played (its pattern kept): pellets on the body and damage by distance.
func _shotgun_section() -> void:
	_section("drum shotgun: pellets and damage by distance at a still bot's chest")
	var def: DotWeaponDef = ArenaPlayer.weapon_catalogue().get_def(&"drum_shotgun")
	_check(def != null, "the pack has the drum shotgun")
	if def == null:
		return
	var tuning := def.tuning as DotWeaponBallistics
	print("    drum shotgun: %d pellets of %.0f, spread %.1f (aimed %.2f), fixed pattern %s, max range %.0f m" % [
		tuning.pellets, tuning.damage, tuning.spread, tuning.accuracy("spread_aim", "shotgun"), str(tuning.get(&"fixed_pattern")), tuning.max_range])
	var kept_target := _target
	_target = _marked_bot()
	_server_bridge._bot_minds.erase(_target)
	_mode = "shotgun"
	_link = "clean"
	_jitter_ticks = 0
	_drop_before = false
	var table := {}
	for r in SHOTGUN_RANGES:
		_range = r
		_damage_log.clear()
		_as_played = true
		_round(&"drum_shotgun", 30)
		_as_played = false
		var shots := 0
		var on_body := 0
		var dealt := 0.0
		for d in _damage_log:
			shots += 1
			on_body += int(d["hits"])
			dealt += float(d["dealt"])
		table[r] = float(on_body) / float(maxi(1, shots))
		print("      %4.1f m: %2d shots, pellets on the body %.2f of %d a shot, damage %.1f a shot (%.1f a pellet)" % [
			r, shots, table[r], tuning.pellets, dealt / float(maxi(1, shots)), dealt / float(maxi(1, on_body))])
		_check(shots > 0, "drum shotgun at %.0f m: the shots resolve" % r, str(shots))
		_check(on_body == 0 or is_equal_approx(dealt / float(on_body), tuning.damage), "drum shotgun at %.0f m: each pellet deals its %.0f (no falloff inside its range)" % [r, tuning.damage],
			"%.2f a pellet" % (dealt / float(maxi(1, on_body))))
	_check(float(table[SHOTGUN_RANGES[0]]) >= float(table[SHOTGUN_RANGES.back()]), "fewer pellets land as the pattern opens", str(table))
	_target = kept_target
	_range = 0.0
	_mode = ""
	_done()


## The server's count of how each hitscan rewind stood each body ([member ArenaGame.shot_rewind_counts], logged by `sv_shot_rewind_log_sec`).
func _counters_section() -> void:
	_section("rewind counters")
	var stats: Dictionary = _server_game.shot_rewind_counts
	print("    %s" % str(stats))
	var own := int(stats.get(&"target", 0)) + int(stats.get(&"target_ahead", 0))
	_check(own > 0, "the server stands far bodies on the shooter's own pairs for them", str(stats))
	_check(int(stats.get(&"refused_span", 0)) == 0 and int(stats.get(&"refused_view", 0)) == 0 and int(stats.get(&"refused_ease", 0)) == 0, "no pair or ease an honest client sent is refused", str(stats))
	_check(int(stats.get(&"eased", 0)) > 0, "the server adds the eases the shooter drew far bodies with", str(stats))
	_check(int(stats.get(&"unrecorded", 0)) == 0, "every living body is in the rewind ring", str(stats))
	_done()


## A target's resume ease rides the firing command to the server in millimetres; one over `sv_shot_ease_max` is refused and counted, and the samples stand alone.
func _ease_wire_section() -> void:
	_section("a target's resume ease on the wire")
	var sent := ArenaNetCommand.new()
	sent.tick = 1000
	sent.move = DotFpsCommand.new()
	sent.fire = DotWeaponCommand.new()
	sent.fire.buttons = DotWeaponCommand.BUTTON_ATTACK
	sent.view_lag_q = 40
	sent.view_targets = [[7, 12, 8], [9, 14, 8, 120, -3, -387]]
	var writer := DotNetWriter.new()
	sent.write(writer)
	var got := ArenaNetCommand.new()
	got.read(writer.to_reader())
	var pairs := got.view_target_pairs()
	_check(got.view_targets == sent.view_targets, "the targets and their eases come back as sent", str(got.view_targets))
	_check(pairs.get(7, [])[1] == Vector3.ZERO and pairs.get(9, [])[1].is_equal_approx(Vector3(0.12, -0.003, -0.387)), "an ease reads back in metres", str(pairs))
	var kept := _server_game.shot_ease_max
	var before := int(_server_game.shot_rewind_counts.get(&"refused_ease", 0))
	_server_game.shot_ease_max = 0.5
	_check(_server_bridge._judged_ease(Vector3(0.3, 0.0, 0.3), true) == Vector3(0.3, 0.0, 0.3), "an ease within sv_shot_ease_max is added")
	_check(_server_bridge._judged_ease(Vector3(0.0, 0.0, 0.6), true) == Vector3.ZERO, "one past it is refused")
	_check(int(_server_game.shot_rewind_counts.get(&"refused_ease", 0)) == before + 1, "and counted as refused_ease")
	_server_game.shot_ease_max = 0.0
	_check(_server_bridge._judged_ease(Vector3(0.0, 0.0, 6.0), false) == Vector3(0.0, 0.0, 6.0), "sv_shot_ease_max 0: no limit")
	_server_game.shot_ease_max = kept
	_server_game.shot_rewind_counts[&"refused_ease"] = before
	_done()
