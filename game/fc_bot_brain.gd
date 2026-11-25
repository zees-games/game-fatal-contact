extends GSBotBrain

## gs-bot's brain with a cheaper candidate scan (cvar `bot_fast_sense`). The stock scan runs aim_point(), is_enemy(), a subtraction, length(), angle_to() and rad_to_deg() for every contact on every think: O(bots^2) per tick, a large part of the brain's ~200 us per bot at 128 bots.
## This rejects the bodies plainly out of range or cone on squared distance and the cone's cosine first, then runs the stock test on the rest, so its candidates and scores are the stock scan's (and gs-sim's native one's) to the bit:
## brains on worker threads (cvar `bot_threads`) scan here while the serial loop scans natively, and any difference would play a different match.

## false runs the stock [method GSBotBrain._candidates].
static var fast_sense: bool = true

## The cheap reject's margin (m, degrees): it keeps every body within this of the range or the cone for the stock test, as it works in doubles.
const REJECT_SLACK := 0.01

## The gs-bot level whose brain has `_target_down` (the style hears of a kill seen).
const TARGET_DOWN_LEVEL := 32


func _candidates(me: GSBotContact, all: Array, p: GSBotProfile, eye: Vector3, forward: Vector3, half: float, scores: PackedFloat32Array) -> Array[GSBotContact]:
	if not fast_sense or half <= 0.0 or half + REJECT_SLACK >= 180.0:
		return super._candidates(me, all, p, eye, forward, half, scores)
	var cand: Array[GSBotContact] = []
	var reach := p.sight + REJECT_SLACK
	var reach_sq := reach * reach
	var near := CLOSE_NOTICE + REJECT_SLACK
	var near_sq := near * near
	var cos_out := cos(deg_to_rad(half + REJECT_SLACK))
	var me_id := me.id
	var me_team := me.team
	var ex := eye.x
	var ey := eye.y
	var ez := eye.z
	var fx := forward.x
	var fy := forward.y
	var fz := forward.z
	for item in all:
		var c := item as GSBotContact
		if c == null:
			continue
		if not c.alive:
			if c.id == target_id and _visible:
				# As the stock scan: forgotten, and the style hears of the kill (gs-bot 32; older gs-bot only forgets).
				if GSAddonApi.build_level("gs_bot") >= TARGET_DOWN_LEVEL:
					call(&"_target_down")
				else:
					_forget_target()
			continue
		# GSBotContact.is_enemy
		if c.id == me_id or (me_team != 0 and c.team != 0 and me_team == c.team):
			continue
		var pos := c.position
		var tx := pos.x - ex
		var ty := pos.y + c.aim_height - ey
		var tz := pos.z - ez
		var d_sq := tx * tx + ty * ty + tz * tz
		if d_sq > reach_sq:
			continue
		# The target being fought is kept while it is in front (the stock test decides); anybody else far enough out of the cone goes.
		if d_sq > near_sq and not (_visible and c.id == target_id) and fx * tx + fy * ty + fz * tz < cos_out * sqrt(d_sq):
			continue
		# GSBotBrain._candidates' own test, in its own single-precision vectors (aim_point() written out, a call saved).
		var to := pos + Vector3.UP * c.aim_height - eye
		var d := to.length()
		if d > p.sight:
			continue
		var off := rad_to_deg(forward.angle_to(to)) if d > 0.01 else 0.0
		var tracking := _visible and c.id == target_id and off < 90.0
		if off > half and d > CLOSE_NOTICE and not tracking:
			continue
		cand.append(c)
		scores.append(d * (1.0 + off / 60.0))
	return cand
