extends GSGameCheckSuite

const FcPlayer := preload("../game/fc_player.gd")

## A player tick's head (FcPlayer.tick_post_head, cvar `fc_head_native`): gs-sim's `GSSimPlayerHead.head` gives the
## script's hit zone fit factor (`FcPlayer.crouch_k`) to the bit and its map volumes skip (`FcPlayer.volumes_clear_of`
## behind the prefilter's mark) over seeded bodies (crouch edges and out of range, zero and negative heights, hulls at
## and past the reaches, moves at and past the slack, unmarked), and NAN exactly where the factor is not above 0 (the
## script answers there). The live check (`head_verify` in play) is in headless_mechanics_native_parity.
## Without the library only the script runs, and the suite says so.

const STATES := 20000
const SEED := 4244


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("FC — player tick head: native and script agree")
	var native := GSSim.has(&"player_head")
	if not native:
		print("gs-sim has no player_head module: only the script lane is exercised")
	var head: Object = FcPlayer.make_native_head() if native else null
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var clears := 0
	var crouched := 0
	var nans := 0
	var k_diff := 0
	var clear_diff := 0
	var nan_diff := 0
	var first := ""
	for i in STATES:
		var crouch: float = ([0.0, 0.0, 1.0, 0.001, 0.999, -0.5, 1.5, rng.randf()] as Array[float])[rng.randi_range(0, 7)]
		var ch: float = ([1.0, 1.2, 0.9, 0.0, -0.4, rng.randf_range(0.2, 2.0)] as Array[float])[rng.randi_range(0, 5)]
		var sh: float = ([1.8, 1.8, 2.0, 0.0, 0.005, -1.0, rng.randf_range(0.5, 4.0)] as Array[float])[rng.randi_range(0, 6)]
		var radius: float = ([0.4, 0.4, 0.5, 0.0, 1.0, 1.5, rng.randf_range(0.0, 2.5)] as Array[float])[rng.randi_range(0, 6)]
		var reach: float = ([0.6, 0.6, 0.5, 0.0, 1.0, rng.randf_range(0.0, 2.0)] as Array[float])[rng.randi_range(0, 5)]
		var msh: float = ([1.8, 1.8, 2.0, 3.0, 4.0, rng.randf_range(0.5, 5.0)] as Array[float])[rng.randi_range(0, 5)]
		var waist: float = ([1.0, 1.0, 0.9, 3.0, 4.5, rng.randf_range(0.0, 5.0)] as Array[float])[rng.randi_range(0, 5)]
		var start := Vector3(rng.randf_range(-500, 500), rng.randf_range(-50, 50), rng.randf_range(-500, 500))
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var step: float = ([0.0, 0.3, 0.999, 1.0, 1.0, 1.001, 2.0, rng.randf_range(0.0, 1.5)] as Array[float])[rng.randi_range(0, 7)]
		var position := start + dir * step
		var marked := rng.randf() < 0.8
		var k := FcPlayer.crouch_k(crouch, ch, sh)
		var clear := marked and FcPlayer.volumes_clear_of(radius, reach, msh, waist, start, position)
		clears += 1 if clear else 0
		crouched += 1 if k != 1.0 else 0
		if not native:
			continue
		var r: float = head.head(crouch, ch, sh, radius, reach, msh, waist, start, position, marked)
		if not (k > 0.0):
			nans += 1
			if not is_nan(r):
				nan_diff += 1
				if first == "":
					first = "state %d: factor %s, native %s (want NAN)" % [i, k, r]
			continue
		if is_nan(r):
			nan_diff += 1
			if first == "":
				first = "state %d: factor %s, native NAN" % [i, k]
			continue
		if PackedFloat64Array([absf(r)]).to_byte_array() != PackedFloat64Array([k]).to_byte_array():
			k_diff += 1
			if first == "":
				first = "state %d: factor script %s native %s" % [i, k, absf(r)]
		if (r < 0.0) != clear:
			clear_diff += 1
			if first == "":
				first = "state %d: clear script %s native %s" % [i, clear, r < 0.0]
	print("  %d states: %d clear, %d crouched, %d factor not above 0" % [STATES, clears, crouched, nans])
	_check(clears > STATES / 20 and clears < STATES - STATES / 20, "the seeded bodies are both clear and not", "%d" % clears)
	_check(crouched > STATES / 5, "the seeded bodies crouch", "%d" % crouched)
	if native:
		_check(nans > 0, "some seeded factors are not above 0 (the NAN lane)", "%d" % nans)
		_check(k_diff == 0, "native fit factors equal the script's to the bit", "%d differ; %s" % [k_diff, first])
		_check(clear_diff == 0, "native volumes skips equal the script's", "%d differ; %s" % [clear_diff, first])
		_check(nan_diff == 0, "native answers NAN exactly where the factor is not above 0", "%d differ; %s" % [nan_diff, first])
	_report(6 if native else 2)
