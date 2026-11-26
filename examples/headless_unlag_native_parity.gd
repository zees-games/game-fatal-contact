extends GSGameCheckSuite

const Unlag := preload("../game/fc_game_unlag.gd")
const FcGame := preload("../game/fc_game.gd")

## The shot rewind history (FcGame._unlag_record, cvar `fc_unlag_native`): gs-sim's `GSSimUnlagRing` answers every
## position and crouch read as the script rings do, to the bit, over seeded runs (walks, teleports past the cut, ticks a
## player skips, a ring short enough to wrap many times, reads below 0, between ticks, past the newest and long gone).
## Without the library only the script lane runs, and the suite says so.

const SEED := 9191
const TICKS := 1500
const PLAYERS := 9
const READS := 40


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC — unlag ring: native and script agree")
	var native := GSSim.has(&"unlag")
	if not native:
		print("gs-sim has no unlag module: only the script lane is exercised")
	var checks := 0
	for history: int in [16, FcGame.UNLAG_HISTORY + 4]:
		var got := _compare(history, native)
		checks += 1
		_check(got[0] > 0 and got[1] > 0, "history %d: the seeded reads both find and miss the ring" % history,
				"%d found, %d missed" % [got[0], got[1]])
		if native:
			checks += 1
			_check(got[2] == 0, "history %d: native positions and crouches equal the script's to the bit" % history,
					"%d differ; %s" % [got[2], got[3]])
	var empty := Unlag.ring_position_at([], 3.0) == null and Unlag.ring_crouch_at([], 3.0) == -1.0
	_check(empty, "an empty script ring answers null and -1")
	_report(checks + 1)


## Runs one seeded history through both lanes; [found, missed, differ, first difference].
func _compare(history: int, native: bool) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + history
	var rings := {}
	var ring: Object = ClassDB.instantiate(&"GSSimUnlagRing") if native else null
	if ring != null:
		ring.call(&"set_history", history)
	var feet := {}
	var found := 0
	var missed := 0
	var differ := 0
	var first := ""
	for tick in TICKS:
		var ids := PackedInt64Array()
		var rows := PackedVector3Array()
		var crouches := PackedFloat32Array()
		for id in PLAYERS:
			# A player skips some ticks (dead, not yet joined), and some never record: their reads must miss too.
			if id == PLAYERS - 1 or rng.randf() < 0.08:
				continue
			var at: Vector3 = feet.get(id, Vector3(rng.randf_range(-50, 50), 0.0, rng.randf_range(-50, 50)))
			if rng.randf() < 0.02:
				at += Vector3(rng.randf_range(-40, 40), rng.randf_range(-5, 5), rng.randf_range(-40, 40))
			else:
				at += Vector3(rng.randf_range(-0.4, 0.4), rng.randf_range(-0.1, 0.1), rng.randf_range(-0.4, 0.4))
			feet[id] = at
			var crouch := rng.randf() if rng.randf() < 0.3 else 0.0
			ids.append(id)
			rows.append(at)
			crouches.append(crouch)
			rings[id] = Unlag.ring_record(rings.get(id, []), tick, history, at, crouch)
		if ring != null:
			ring.call(&"record", tick, ids, rows, crouches, FcGame.TELEPORT_CUT)
		for r in READS:
			var id := rng.randi_range(0, PLAYERS)
			var at := float(tick) - rng.randf_range(-1.5, float(history) * 1.5)
			if rng.randf() < 0.2:
				at = floorf(at)
			var want: Variant = Unlag.ring_position_at(rings.get(id, []), at)
			var want_crouch := Unlag.ring_crouch_at(rings.get(id, []), at)
			if want == null:
				missed += 1
			else:
				found += 1
			if ring == null:
				continue
			var got: Variant = ring.call(&"position_at", id, at)
			var got_crouch: float = ring.call(&"crouch_at", id, at)
			if typeof(got) != typeof(want) or (want != null and got != want) or got_crouch != want_crouch:
				differ += 1
				if first.is_empty():
					first = "id %d at %.4f: %s/%s vs %s/%s" % [id, at, str(got), got_crouch, str(want), want_crouch]
	return [found, missed, differ, first]
