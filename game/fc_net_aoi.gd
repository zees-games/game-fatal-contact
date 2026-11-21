extends RefCounted

## Relevance tiers for a big server (arena-128-scale-1 / net-aoi-1): distance rings around each player that decide how often, and whether, another player is sent, built on dot-net's own GSNetInterestDistance (no new wire format).
## Defaults: every snapshot out to radius (120 m), nothing past it; on imported maps the PVS (net_visibility) cuts further. Past far_distance (15 m) a player is sent every far_every-th snapshot (2); each further band (far_tiers, 2: past 30 m every fourth) is twice as far and half as often, except inside aim_cone_deg (8) of the observer's aim, where it stays every far_every-th: a scoped shot at 60 m drawn from every fourth snapshot misses the rewind tolerance (headless_hitreg_scope), one drawn from every second does not. Measured with net_probe --control at 64 (docs/perf-64-players.md): with dot-net syncing a thinned entity's acks the rings save bytes, 560 B against 635 per client per snapshot on dm_atrium and 283 against 307 on cp-orange-x3 at the old 40 m / 2 tiers, 411 B on dm_atrium at 20 m / 1 tier with FcPlayerNet.hold_subquantum (fc-dmatrium-bytes-1), 326 B at 15 m / 2 tiers with the 8 degree aim cone (fc-dmatrium-bytes-2); before that sync they cost more than they saved (801-831 B on dm_atrium). The observer's own entity and a beaconed player (always_relevant) are never culled; scoreboard, kill feed and match state are not entity snapshots.
## Off until the room is big (min_players, 32: the tiers start at the 33rd player, with OFF_MARGIN hysteresis); an entity leaving the radius keeps its last drawn pose on the client (no pop). Pinned by headless_netaoi.

const OFF_MARGIN := 2
const BASE_UNSET := -1.0

var min_players: int = 32
var radius: float = 120.0
var far_distance: float = 15.0
var far_every: int = 2
var far_tiers: int = 2
var far_coherent: bool = true
## Degrees either side of a player's aim inside which a far player keeps the first ring's rate
## (dot-net GSNetInterest.aim_cone_deg, set from FcPlayerNet.pull): what a scope looks at
## past the second ring still has every far_every-th snapshot to rewind against. 0 is off.
var aim_cone_deg: float = 8.0

var active: bool = false
## What the interest object held before the first refresh: restored when the tiers go off.
var _base: Dictionary = {}
var _cvars: Dictionary = {}


## Registers the cvars through [param add_cvar] (GSModule.add_cvar) and keeps them to read live.
func bind_cvars(add_cvar: Callable, flags: int) -> void:
	_cvars["min_players"] = add_cvar.call("sv_net_aoi_players", str(min_players),
		"Relevance tiers start above this many players, bots included (0 is always on, 9999 never)", flags)
	_cvars["radius"] = add_cvar.call("sv_net_radius", str(radius),
		"With the tiers on: players farther than this many metres are not sent at all", flags)
	_cvars["far_distance"] = add_cvar.call("sv_net_far_distance", str(far_distance),
		"With the tiers on: past this many metres a player is sent every sv_net_far_every-th snapshot", flags)
	_cvars["far_every"] = add_cvar.call("sv_net_far_every", str(far_every),
		"With the tiers on: the mid ring's snapshot divisor (1 is no rings, 2 is half rate); the ring after it is twice that", flags)
	_cvars["far_tiers"] = add_cvar.call("sv_net_far_tiers", str(far_tiers),
		"With the tiers on: rings past sv_net_far_distance, each twice as far and half as often (1 to 4; more is refused)", flags)
	# Refused with the reason when out of range (GSConVar), never clamped; 4 rings is the shift width of every_for().
	_with_limits(_cvars["far_every"], 1.0, NAN)
	_with_limits(_cvars["far_tiers"], 1.0, 4.0)
	_cvars["far_coherent"] = add_cvar.call("sv_net_far_coherent", "1" if far_coherent else "0",
		"With the tiers on: every client gets the same turns, so peers in step share work (1) or each is staggered (0)", flags)
	_cvars["aim_cone_deg"] = add_cvar.call("sv_net_aim_cone", str(aim_cone_deg),
		"With the tiers on: degrees either side of a player's aim inside which far players keep the first ring's rate (0 is off)", flags)
	_with_limits(_cvars["aim_cone_deg"], 0.0, 180.0)


static func _with_limits(cv: Variant, low: float, high: float) -> void:
	if cv is GSConVar:
		var _c := (cv as GSConVar).with_min(low)
		if not is_nan(high):
			var _d := (cv as GSConVar).with_max(high)


## Reads the cvars (when bound) into the fields.
func pull_cvars() -> void:
	if _cvars.is_empty():
		return
	min_players = (_cvars["min_players"] as GSConVar).get_int()
	radius = (_cvars["radius"] as GSConVar).get_float()
	far_distance = (_cvars["far_distance"] as GSConVar).get_float()
	far_every = (_cvars["far_every"] as GSConVar).get_int()
	far_tiers = (_cvars["far_tiers"] as GSConVar).get_int()
	far_coherent = (_cvars["far_coherent"] as GSConVar).get_bool()
	aim_cone_deg = (_cvars["aim_cone_deg"] as GSConVar).get_float()


## Whether the tiers should be on for [param players] given the current state (with hysteresis).
func wants_on(players: int) -> bool:
	if active:
		return players > min_players - OFF_MARGIN
	return players > min_players


## Applies (or lifts) the tiers on [param interest] for a room of [param players]. Safe to call
## every second; returns true when the state changed.
func refresh(interest: GSNetInterest, players: int) -> bool:
	if interest == null:
		return false
	pull_cvars()
	if _base.is_empty():
		_base = {
			"far_every": interest.far_every, "far_distance": interest.far_distance,
			"far_tiers": interest.far_tiers, "far_coherent": interest.far_coherent,
			"aim_cone_deg": interest.get(&"aim_cone_deg") if &"aim_cone_deg" in interest else 0.0,
			"radius": (interest as GSNetInterestDistance).radius if interest is GSNetInterestDistance else BASE_UNSET,
		}
	var on := wants_on(players)
	var changed := on != active
	active = on
	if on:
		interest.far_every = far_every
		interest.far_distance = far_distance
		interest.far_tiers = far_tiers
		interest.far_coherent = far_coherent
		_set_cone(interest, aim_cone_deg)
		if interest is GSNetInterestDistance:
			(interest as GSNetInterestDistance).radius = radius
	else:
		interest.far_every = int(_base["far_every"])
		interest.far_distance = float(_base["far_distance"])
		interest.far_tiers = int(_base["far_tiers"])
		interest.far_coherent = bool(_base["far_coherent"])
		_set_cone(interest, float(_base["aim_cone_deg"]))
		if interest is GSNetInterestDistance and float(_base["radius"]) != BASE_UNSET:
			(interest as GSNetInterestDistance).radius = float(_base["radius"])
	return changed


## dot-net before API 22 has no aim cone: the rings then go without it.
static func _set_cone(interest: GSNetInterest, degrees: float) -> void:
	if &"aim_cone_deg" in interest:
		interest.set(&"aim_cone_deg", degrees)


## The ring [param distance] metres out falls in: 0 inside far_distance, 1..far_tiers beyond it,
## -1 past the radius (not sent). What dot-net does, written down so a suite can pin it.
func ring_of(distance: float) -> int:
	if distance > radius:
		return -1
	if far_every <= 1 or distance <= far_distance:
		return 0
	var band := 1
	var edge := far_distance * 2.0
	while band < far_tiers and distance > edge:
		band += 1
		edge *= 2.0
	return band


## Snapshots between sends for [param ring] (1 = every one).
func every_for(ring: int) -> int:
	if ring <= 0:
		return 1
	return far_every << (ring - 1)


## [method every_for] for a player [param off_aim_deg] degrees off the observer's aim: inside
## [member aim_cone_deg] no ring past the first.
func every_for_aimed(ring: int, off_aim_deg: float) -> int:
	if ring > 1 and aim_cone_deg > 0.0 and off_aim_deg <= aim_cone_deg:
		return every_for(1)
	return every_for(ring)
