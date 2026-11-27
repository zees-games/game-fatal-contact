extends GSKillViewServer

## The kill view's server over FC. [method record] walks the game's living players itself and hands each eye the ring keeps
## straight to [method GSKillViewRing.record]: no eye dictionary per player, and the aux floats filled into one reused buffer
## ([method KillPov.fill_aux]). The ring keeps a sample per [member GSKillViewRules.record_hz] (30) and the tick is 66, so an eye
## is built only when [method GSKillViewRing.is_due] says the ring takes it, the same check [method eye_due] asks: what the
## ring holds is unchanged, sample for sample. [member eyes_fn] still lists the eyes as dictionaries, for a probe or a test.

const KillPov := preload("fc_kill_pov.gd")
const FcPlayer := preload("fc_player.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")

## Off builds every living eye and lets the ring refuse the ones it does not keep, as before:
## headless_bot_pull holds the two to the same samples.
static var ask_due_only := true

## The FC game whose players are the eyes. A Node, so holding it makes no reference cycle.
var game: Node = null


func _init(p_rules: GSKillViewRules = null, p_game: Node = null) -> void:
	super(p_rules)
	game = p_game
	# A bound method holds no strong reference to this server: no cycle.
	eyes_fn = _eyes


func record(time: float) -> void:
	if not rules.enabled or game == null or not is_instance_valid(game) or GSKillViewRing.AUX != KillPov.SIZE:
		super.record(time)
		return
	var fine: bool = FcFrameProbe.fine
	var eyes_us := 0
	var aux_us := 0
	var ring_us := 0
	var t := Time.get_ticks_usec() if fine else 0
	var cursor := Vector2(0.5, 0.5)
	for p: FcPlayer in game.call(&"players"):
		if not _alive(p) or (ask_due_only and not ring.is_due(p.player_id, time)):
			continue
		var xf := eye_transform(p)
		var fov := KillPov.fov_of(p)
		if fine:
			var now := Time.get_ticks_usec()
			eyes_us += now - t
			t = now
		KillPov.fill_aux(p)
		KillPov.keep_tick_aux(p)
		if fine:
			var now := Time.get_ticks_usec()
			aux_us += now - t
			t = now
		var _kept := ring.record(p.player_id, time, xf, fov, cursor, KillPov.aux_buf)
		if fine:
			var now := Time.get_ticks_usec()
			ring_us += now - t
			t = now
	if fine:
		var now := Time.get_ticks_usec()
		eyes_us += now - t
		FcFrameProbe.lap(&"kv_eyes", now - eyes_us)
		FcFrameProbe.lap(&"kv_aux", now - aux_us)
		FcFrameProbe.lap(&"kv_ring", now - ring_us)


## Where [param p]'s eye is and looks: the motor's eye, else eye height above the feet.
static func eye_transform(p: FcPlayer) -> Transform3D:
	var st: GSFpsState = p.controller.state
	var eye: Vector3 = p.controller.motor.eye_position(st) if p.controller.motor != null else st.position + Vector3(0.0, FcPlayer.eye_height(), 0.0)
	return Transform3D(Basis.from_euler(Vector3(deg_to_rad(st.pitch), deg_to_rad(st.yaw), 0.0)), eye)


static func _alive(p: FcPlayer) -> bool:
	return p.health.alive and p.controller != null and p.controller.state != null


## [member eyes_fn]: every living eye the ring keeps now ([method eye_due]; every one outside [method record]), as dictionaries.
func _eyes() -> Array:
	var eyes: Array = []
	if game == null or not is_instance_valid(game):
		return eyes
	for p: FcPlayer in game.call(&"players"):
		if not _alive(p) or (ask_due_only and not eye_due(p.player_id)):
			continue
		eyes.append({"id": p.player_id, "transform": eye_transform(p), "fov": KillPov.fov_of(p), "aux": KillPov.aux_of_tick(p, GSKillViewRing.AUX, true)})
	return eyes
