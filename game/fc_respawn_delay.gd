extends RefCounted
## The optional respawn delay after a death (`fc_respawn_min`, `fc_respawn_max`, and per team
## `fc_respawn_min_team<N>`, `fc_respawn_max_team<N>`; docs/modes.md). Seconds, 0 = unset.
##
## It is an override on top of the mode's own delay (FcMode `respawn_delay_sec`, `mp_respawn_delay_sec`):
## with every value 0 the mode's delay is untouched, so a game that sets nothing plays as before.
##
## Per field, a team's value above 0 beats the global one; 0 falls through to the global value.
## The delay is then:
##   max unset (0) or equal to min  -> fixed at min
##   min unset, max set              -> picked between 0 and max
##   both set, max above min         -> picked between min and max
##   max set below min               -> a mistake: fixed at min, reported once per setting
## The pick is seeded from the victim and the tick, so a replayed match draws the same delays.
## The server picks it and tells the dead player's client ([FcRespawnWire]); the client only shows it.

const FcRespawnWire := preload("fc_respawn_wire.gd")

## The teams that get their own cvars (`fc_ctf_teams` allows up to 8).
const TEAMS := 8

var min_sec := 0.0
var max_sec := 0.0
## team -> seconds; a missing team or 0 falls through to the global value.
var team_min: Dictionary = {}
var team_max: Dictionary = {}
## Server: victim id -> the first tick that victim may spawn on, even if the kill view releases it early.
var floors: Dictionary = {}
## Client: id -> the Time.get_ticks_msec() it is due at.
var waits: Dictionary = {}
var _reported: Dictionary = {}


## Anything set at all? False means the mode's own delay stands.
func active() -> bool:
	if min_sec > 0.0 or max_sec > 0.0:
		return true
	for v: Variant in team_min.values():
		if float(v) > 0.0:
			return true
	for v: Variant in team_max.values():
		if float(v) > 0.0:
			return true
	return false


## The [min, max] a team gets after fall-through.
func range_for(team: int) -> Vector2:
	var lo := float(team_min.get(team, 0.0))
	var hi := float(team_max.get(team, 0.0))
	return Vector2(lo if lo > 0.0 else min_sec, hi if hi > 0.0 else max_sec)


## Seconds to wait for this death, or -1.0 when nothing is set for it (the mode's delay stands).
func pick(team: int, victim: int, tick: int) -> float:
	var r := range_for(team)
	var lo := r.x
	var hi := r.y
	if lo <= 0.0 and hi <= 0.0:
		return -1.0
	if hi <= 0.0 or is_equal_approx(hi, lo):
		return lo
	if hi < lo:
		if not _reported.has(team):
			_reported[team] = true
			GSLog.error("fc_respawn_delay", "respawn max is below min, using min as a fixed delay", {"team": team, "min": lo, "max": hi})
		return lo
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([victim, tick])
	return rng.randf_range(lo, hi)


## Server: notes the delay for [param victim]; returns the first tick it may respawn on.
func hold(victim: int, tick: int, sec: float, tick_rate: int) -> int:
	var due := tick + maxi(0, int(round(sec * float(tick_rate))))
	floors[victim] = due
	return due


## Client: the delay [param sec] has started for [param id].
func note(id: int, sec: float) -> void:
	waits[id] = Time.get_ticks_msec() + int(round(sec * 1000.0))


## Client: seconds left for [param id], 0.0 when none.
func remaining(id: int) -> float:
	if not waits.has(id):
		return 0.0
	var left := (int(waits[id]) - Time.get_ticks_msec()) / 1000.0
	if left <= 0.0:
		waits.erase(id)
		return 0.0
	return left
