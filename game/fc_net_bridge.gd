extends "fc_net_bridge_link.gd"

const FcNetCommand := preload("fc_net_command.gd")

## Bytes [method GSNetManager.encode_ack] produces, and the prefix of every input
## packet. Fixed width, so the command that follows starts at a known offset.
const ACK_BYTES := 4

## Microseconds of event handling a frame may spend before later events wait a frame; 0 handles each on arrival.
var event_budget_usec := 0

var _events_waiting: Array[PackedByteArray] = []
var _event_frame := -1
var _event_usec := 0
## 1 when gs-net has GSNetManager.snapshot_due(), 0 when not, -1 before the first ask.
var _snapshot_due_api := -1


## Whether the tick being simulated ends in a snapshot (and the history recorded with it):
## gs-net 19's [code]GSNetManager.snapshot_due()[/code]. True on a shell's older gs-net, which
## cannot say: every tick is then pulled, as before. Called by name, so an older gs-net parses.
func snapshot_due() -> bool:
	if net == null:
		return true
	if _snapshot_due_api < 0:
		_snapshot_due_api = 1 if GSAddonApi.build_level("gs_net") >= 19 and net.has_method(&"snapshot_due") else 0
	return _snapshot_due_api == 0 or bool(net.call(&"snapshot_due"))


# --- Bots ------------------------------------------------------------------


## The bots in the game, oldest first.
func bot_ids() -> Array[int]:
	var out: Array[int] = []
	for id in _bot_minds.keys():
		out.append(int(id))
	out.sort()
	return out


## One client tick: record the local command, predict, reconcile.
##
## The command is recorded into the behaviour and into the manager's input history
## before predicting, because reconciliation replays that history — an input the
## buffer never saw is a tick the replay cannot reproduce, and the correction is then
## measured against a state the server never computed.
func client_tick(tick: int, move: GSFpsCommand, fire: GSWeaponCommand) -> void:
	_tick = tick

	if net == null or net.is_server:
		return

	# A networked client never calls `game.tick`, so the spectate layer is advanced here
	# or not at all. See `FcSpectate.client_tick`.
	if game != null and game.spectate != null:
		game.spectate.client_tick(tick)

	# The copies of every rocket and grenade the server announced, flown for drawing.
	# Here for the same reason: nothing else ticks anything on a mirroring client.
	if game != null and game.projectiles != null:
		game.projectiles.tick(net.clock.tick_duration())
	if game != null:
		game.step_bullet_mirrors(float(tick))

	var command := _command_for(tick, move, fire)
	net.local_inputs().push(command)

	var t := Time.get_ticks_usec()
	# The snapshots read since the last tick, reconciled once against the newest, before
	# this tick predicts on top of them (GSNetConfig.reconcile_once_per_frame; by name for
	# an older shell's gs-net, where each snapshot already reconciled as it came).
	if net.has_method(&"flush_reconcile"):
		var replays := probe_replays_before()
		net.call(&"flush_reconcile")
		probe_replays_after(replays)
		FcFrameProbe.add(&"reconcile", t)
		t = Time.get_ticks_usec()
	# [b]Through gs-net's predictor, not around it[/b] (`GSNetManager.predict_tick`, API 10).
	# Simulating the predicted behaviours here by hand predicted the same thing, but the
	# predictor never saw these ticks: `skip_matching_replays` had nothing remembered to
	# compare a snapshot with unless a replay had happened to cover its tick, so most snapshots
	# replayed the whole lead, and the net graph's prediction row read 0 ms/s. By name, with
	# the old loop kept, for an older shell's gs-net.
	#
	# [b]The old loop predicts what the server will compute, and says so.[/b] The web shell
	# pinned 2026-10-17 has gs-net 0.1.12: the skip (`skip_matching_replays`, `_remember`)
	# but no `predict_tick`. That loop predicted on the command as typed while the server ran
	# it as it arrived, rounded by the wire, so the prediction drifted off the server's by
	# millimetres a tick and never matched a snapshot; and it remembered nothing, so nothing
	# could be skipped anyway. Every snapshot replayed the whole lead: 29-41 ticks re-simulated
	# a frame in a browser, the frame's largest cost. Rounding the command the way the wire
	# does (what `predict_tick` does under `predict_wire_input`) and remembering each tick
	# took a replica of that shell (24 s against three bots) from 92 of 500 snapshots skipped and
	# 9.2 ticks re-simulated a frame to 458 of 485 skipped and 0.6.
	if net.has_method(&"predict_tick"):
		net.call(&"predict_tick", tick, command)
	else:
		# Same object as the one buffered above, so its replays run on the rounded one too.
		var wire := GSNetWriter.new(32)
		command.write(wire)
		command.read(GSNetReader.new(wire.to_bytes()))
		var remember := net.predictor != null and net.predictor.has_method(&"_remember")
		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				if behaviour.has_method("_net_apply_input"):
					behaviour.call("_net_apply_input", command, tick)
				behaviour._net_simulate(tick, net.clock.tick_duration())
			if remember:
				net.predictor.call(&"_remember", identity, tick)
	FcFrameProbe.add(&"predict", t)


## Applies a snapshot. Client side.
##
## [b]Reconciliation is [GSNetManager]'s, not this file's.[/b]
## [method GSNetManager.receive_snapshot] already routes a predicted entity's state to
## [method GSNetPredictor.reconcile] rather than applying it — applying it directly would
## undo everything predicted since — and acknowledges the inputs that state covers.
##
## A second pass here once replayed inputs twice: [method GSNetPredictor.correction_rate] read
## [b]0.500[/b] with it and [b]0.032[/b] without, though the client still converged.
func receive_snapshot(payload: PackedByteArray) -> GSResult:
	if net == null or net.is_server:
		return GSResult.fail(GSError.CODE_FORBIDDEN, "Only a client receives these.")

	# The one place an RTT sample is written. `GSNetStats` has a median and a
	# mean-absolute-deviation behind it and `receive_snapshot` reads
	# `rtt_percentile(0.5)` on every snapshot to feed the clock — and no caller
	# anywhere in gs-net writes a sample, because gs-net never touches a transport.
	# Without this the clock's input lead omits the flight time and, past about 30 ms
	# of latency, every command arrives after its tick and is discarded as late.
	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()) + net.latency.effective() * 2000.0)

	if not FcFrameProbe.on():
		return net.receive_snapshot(payload)
	var t := Time.get_ticks_usec()
	var replays := probe_replays_before()
	var received := net.receive_snapshot(payload)
	probe_replays_after(replays)
	FcFrameProbe.add(&"snapshot", t)
	return received


## The predictor's reconciliation count, for [method probe_replays_after]; -1 with the probe off.
func probe_replays_before() -> int:
	if not FcFrameProbe.on() or net == null or net.predictor == null:
		return -1
	return net.predictor._replays


## Counts the ticks the reconciliation since [param before] replayed, for `cl_perf`.
func probe_replays_after(before: int) -> void:
	if before >= 0 and net.predictor._replays != before:
		FcFrameProbe.count(&"replay_n", net.predictor._last_replay_ticks)


# --- The client-to-server channel ------------------------------------------

## An input packet, with the snapshot acknowledgement in front of it.
##
## [b]gs-net does not send either of these for you.[/b] It owns no client-to-server
## channel — inventing one would need a second socket or make every payload ambiguous
## with a message — so the four bytes of acknowledgement ride inside the input packet
## a host already sends every tick. Wiring it is what makes a property lost to a
## dropped packet get re-sent instead of sitting at a stale value until it happens to
## change again; a game that skips it still works, and a player's health is then
## whatever the last packet that arrived said.
##
## The acknowledgement goes first because it is fixed width. A bit-packed command is
## not, so a reader that had to skip it would need to decode it to know where it ends.
##
## [b]And the command rides with the two before it.[/b] An input is unreliable and a lost
## one is a tick the server simulates on the previous command -- with the view turning,
## a different command -- so the client is corrected for something it did right. Through a
## real UDP relay in front of an ENet server (`headless_lossy`), one copy: the server had a
## moving player's command for 80% of its ticks at 20% loss and 94% at 5%, and corrected
## his prediction on 9% of snapshots; three copies: 99-100% and under 3%. WebSocket never
## loses one, which is why nothing had seen it. The copies come out of the client's own
## replay history, so they are exactly what it predicted with, and the server skips the
## ones it has already simulated.
func encode_input(tick: int, move: GSFpsCommand, fire: GSWeaponCommand) -> PackedByteArray:
	var command := _command_for(tick, move, fire)

	# The ones before this tick from the replay history; this one from the arguments,
	# because a caller may encode before or after `client_tick` recorded it.
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(command)

	var writer := GSNetWriter.new()
	GSNetInput.write_batch(writer, batch)

	var out := net.encode_ack()
	out.append_array(writer.to_bytes())
	return out


var _lag_for_tick := -1
var _lag_for_q := -1
var _back_for := -1
var _span_for := 0
var _render_for := -1.0
var _targets_tick := -1
var _targets_for: Array = []


## The command for [param tick], the same whether [method client_tick] or [method encode_input] made
## it: the server keeps the first copy of a tick to arrive, which is usually the encoded one.
func _command_for(tick: int, move: GSFpsCommand, fire: GSWeaponCommand) -> FcNetCommand:
	var command := FcNetCommand.new()
	command.tick = tick
	command.delta = net.clock.tick_duration()
	command.move = move
	command.fire = fire
	# Measured once per tick: a snapshot read between the two calls moved the receive clock,
	# the server kept one lag and the replay used the other, and bumps diverged.
	if tick != _lag_for_tick:
		_lag_for_tick = tick
		_lag_for_q = view_lag_q(tick)
		_back_for = -1
		_span_for = 0
		var lag := game.collision_lag(float(_lag_for_q) * 0.25) if game != null and _lag_for_q >= 0 else -1.0
		_render_for = float(tick) - lag if lag >= 0.0 else -1.0
		if lag >= 0.0 and net.interpolator.has_method(&"bracket_at"):
			var pair: Vector2i = net.interpolator.call(&"bracket_at", _render_for)
			if pair.x >= 0 and tick - pair.x < (1 << FcNetCommand.VIEW_BACK_BITS) and pair.y - pair.x < (1 << FcNetCommand.VIEW_SPAN_BITS):
				_back_for = tick - pair.x
				_span_for = pair.y - pair.x
	command.view_lag_q = _lag_for_q
	command.view_back = _back_for
	command.view_span = _span_for
	if _render_for >= 0.0 and fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK):
		if _targets_tick != tick:
			_targets_tick = tick
			_targets_for = _view_targets(tick, _render_for, move)
		command.view_targets = _targets_for
	command.lag_always = game != null and game.body_rules.solid
	return command


## [member FcNetCommand.view_targets] for a firing command at [param tick] drawn at [param render]: each remote player within `cl_shot_view_cone_deg` of [param move]'s aim
## that the interpolator drew across a sample pair of its own other than the room's ([member _back_for], [member _span_for]), or ran on past its newest sample.
func _view_targets(tick: int, render: float, move: GSFpsCommand) -> Array:
	var out: Array = []
	if net.interpolator == null or game == null:
		return out
	var room := Vector2i(tick - _back_for, tick - _back_for + _span_for) if _back_for >= 0 else Vector2i(-1, -1)
	var yaw := deg_to_rad(move.yaw)
	var pitch := deg_to_rad(move.pitch)
	var aim := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
	var cone := cos(deg_to_rad(game.shot_view_cone_deg)) if game.shot_view_cone_deg > 0.0 else -2.0
	var eye := _local_eye()
	# The frame on screen was drawn before any snapshot read since: its samples, not newer ones.
	var since := net.clock.received_tick() - _drawn_received
	var fresh := _drawn_tick >= 0.0 and since >= 0 and since <= DRAWN_FRESH_TICKS
	var newest := _drawn_newest if fresh else 1 << 62
	for id: int in _behaviours:
		var other: FcPlayerNet = _behaviours[id]
		if other.identity == null or other.identity.is_predicted() or other.player == null or not other.player.is_alive():
			continue
		var to := other.player.global_position + Vector3.UP - eye
		if eye != Vector3.INF and cone > -1.5 and to.length_squared() > 0.01 and aim.dot(to.normalized()) < cone:
			continue
		var samples: Array = net.interpolator.track_samples(other.identity.net_id)
		var own := _own_pair(samples, render, newest)
		var drawn: Variant = _drawn_feet.get(other.identity.net_id) if fresh and own.x >= 0 else null
		var ease := _drawn_ease(drawn, samples, own) if drawn is Vector3 else Vector3i.ZERO
		if own.x >= 0 and (own != room or render >= float(own.y) or ease != Vector3i.ZERO):
			var entry := [other.identity.net_id, tick - own.x, own.y - own.x]
			if ease != Vector3i.ZERO:
				entry.append_array([ease.x, ease.y, ease.z])
			out.append(entry)
	return out

## How far, in millimetres, [param drawn] sits off the line through [param pair]'s samples at the drawn tick: the resume ease (GSNetInterpolator._ease_resume) the server cannot see.
## Held at the newer past `max_extrapolation_sec`, as the interpolator holds it.
func _drawn_ease(drawn: Vector3, samples: Array, pair: Vector2i) -> Vector3i:
	var a: Variant = null
	var b: Variant = null
	for sample: Dictionary in samples:
		if int(sample["tick"]) == pair.x:
			a = (sample["values"] as Dictionary).get(&"net_position")
		elif int(sample["tick"]) == pair.y:
			b = (sample["values"] as Dictionary).get(&"net_position")
	if not (a is Vector3 and b is Vector3):
		return Vector3i.ZERO
	var t := (_drawn_tick - float(pair.x)) / float(pair.y - pair.x)
	if _drawn_tick - float(pair.y) > net.config.max_extrapolation_sec * float(net.config.tick_rate):
		t = 1.0
	var off := (drawn - (a as Vector3).lerp(b as Vector3, maxf(t, 0.0))) * FcNetCommand.EASE_PER_M
	return Vector3i(roundi(off.x), roundi(off.y), roundi(off.z))

## Where this client's own player's eye is, or [constant Vector3.INF] for none.
func _local_eye() -> Vector3:
	for id: int in _behaviours:
		var mine: FcPlayerNet = _behaviours[id]
		if mine.identity != null and mine.identity.is_predicted() and mine.player != null:
			return mine.player.global_position + Vector3(0.0, FcPlayer.eye_height(), 0.0)
	return Vector3.INF

## The two samples of [param samples] (`{tick, ...}`, oldest first) the interpolator draws between at [param render] (GSNetInterpolator.sample), counting none past tick [param newest]:
## the newest two when it is past the newest, (-1, -1) when it holds one.
static func _own_pair(samples: Array, render: float, newest: int) -> Vector2i:
	var n := samples.size()
	while n > 0 and int(samples[n - 1]["tick"]) > newest:
		n -= 1
	if n < 2 or render <= float(samples[0]["tick"]):
		return Vector2i(-1, -1)
	if render >= float(samples[n - 1]["tick"]):
		return Vector2i(int(samples[n - 2]["tick"]), int(samples[n - 1]["tick"]))
	for i in range(n - 2, -1, -1):
		if render > float(samples[i]["tick"]):
			return Vector2i(int(samples[i]["tick"]), int(samples[i + 1]["tick"]))
	return Vector2i(-1, -1)


## How far behind [param tick] this client is drawing everybody else, in quarter ticks:
## what the server rewinds the other players by when this tick's command fires.
##
## Remote players are drawn at the receive timeline less the interpolation delay
## ([method GSNetManager.interpolate_frame]); this command is for [param tick], ahead of
## the server by the input lead. A shot on it was aimed at players as they were drawn, so
## the difference is the whole of what the server has to undo: the lead, the flight time
## and the interpolation delay. -1 when there is nothing to measure against yet.
func view_lag_q(tick: int) -> int:
	if net == null or net.interpolator == null or not net.clock.is_synced():
		return -1
	var drawn := float(net.clock.received_tick()) - net.interpolator.delay_ticks()
	# The click was aimed at the frame on screen, drawn a fraction into an earlier tick, not at
	# the start of the tick the receive clock has walked on to since: up to a tick of strafe
	# (9 cm at 66 Hz) between the body drawn and the one rewound.
	var since := net.clock.received_tick() - _drawn_received
	if _drawn_tick >= 0.0 and since >= 0 and since <= DRAWN_FRESH_TICKS:
		drawn = _drawn_tick
	return clampi(int(roundf((float(tick) - drawn) * 4.0)), 0, FcNetCommand.MAX_VIEW_LAG_Q)


## How many ticks the receive clock may walk past the last frame drawn before that frame stops
## being what the player is looking at (a frame rate under 16 at 66 Hz, a stall, a re-anchor).
const DRAWN_FRESH_TICKS := 4

var _drawn_tick := -1.0
var _drawn_received := -1
## The newest snapshot tick the interpolator held when that frame was drawn.
var _drawn_newest := -1
## Where that frame drew each remote player, by net id: a snapshot read since moves `net_position` on, not the body on screen.
var _drawn_feet: Dictionary = {}


## Draws the remote entities for this frame ([method GSNetManager.interpolate_frame]) and keeps
## the render tick it drew at, which the next command's view lag is measured from. The client
## calls this instead of the manager's; [param alpha] as there.
func draw_frame(alpha: float = -1.0) -> void:
	if net == null:
		return
	if alpha < 0.0:
		alpha = net.clock.render_alpha()
	net.interpolate_frame(alpha)
	_drawn_tick = -1.0
	if net.interpolator != null and net.clock.is_synced():
		_drawn_received = net.clock.received_tick()
		_drawn_tick = drawn_tick(alpha)
		var timeline: Variant = net.interpolator.get(&"_timeline")
		_drawn_newest = timeline[-1] if timeline is PackedInt32Array and not timeline.is_empty() else -1
		_drawn_feet.clear()
		for id: int in _behaviours:
			var other: FcPlayerNet = _behaviours[id]
			if other.identity != null and not other.identity.is_predicted():
				_drawn_feet[other.identity.net_id] = other.net_position


## The render tick [method GSNetManager.interpolate_frame] draws remote entities at for
## [param alpha], the same arithmetic; -1 when it draws nothing.
func drawn_tick(alpha: float) -> float:
	if net == null or net.is_server or net.interpolator == null or not net.clock.is_synced():
		return -1.0
	return float(net.clock.received_tick()) + clampf(alpha, -1.0, 2.0) + net.clock.receive_slip() \
		- net.interpolator.delay_ticks()


## Takes one of those packets. Server side.
##
## The acknowledgement is applied even when the command is refused: they are
## independent claims, and a duplicate or late input says nothing about which
## snapshots arrived.
func receive_input(peer_id: int, payload: PackedByteArray) -> GSResult:
	if net == null or not net.is_server:
		return GSResult.fail(GSError.CODE_FORBIDDEN, "Only the server takes input.")

	if payload.size() <= ACK_BYTES:
		return GSResult.fail(GSError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))
	inputs_from[peer_id] = int(inputs_from.get(peer_id, 0)) + 1

	var batch := GSNetInput.read_batch(
		GSNetReader.new(payload.slice(ACK_BYTES)),
		func() -> GSNetInput: return FcNetCommand.new()
	)

	if batch.is_empty():
		return GSResult.fail(GSError.CODE_PARSE, "Input packet carries no command.")

	# One call a packet: the copies of ticks already simulated are skipped rather than counted
	# late, and the arrival lead is measured on the packet's own command only. A resend seen
	# first here was in a lost packet, and measuring it made the client's clock jump under loss.
	var buffer := net.input_buffer_for(peer_id)
	_note_late_fires(peer_id, buffer, batch)
	var overflow_before := _input_overflow(buffer)
	var pushed := buffer.push_batch(batch)
	# sv_shot_debug: a command dropped unconsumed past the buffer's capacity is a tick, trigger included, the server
	# never simulated; a tap the client drew can vanish there without a "fire refused" line.
	var overflow := _input_overflow(buffer)
	if overflow > overflow_before and game != null and game.shot_debug:
		GSLog.warn(game.CHANNEL, "shot debug input overflow", {"peer": peer_id, "dropped": overflow - overflow_before,
			"total": overflow, "capacity": buffer.capacity, "consumed": buffer.last_consumed_tick()})
	return pushed


## The inputs gs-net dropped unconsumed from [param buffer] past its capacity (gs-net 27), or 0 on an older link.
static func _input_overflow(buffer: GSNetInput.Buffer) -> int:
	return int(buffer.get(&"overflow_count")) if &"overflow_count" in buffer else 0


## Shots whose command reached the server after its tick was simulated, per peer, oldest first:
## each [tick, view tick or -1, view_back, view_span]. See [method _note_late_fires].
var late_fires: Dictionary = {}
## Late shots fired on the tick after they arrived, and late shots too old to fire.
var late_fire_honoured := 0
var late_fire_dropped := 0
## The ticks each peer's commands have reached the server on, any copy: a resend of one is not a late shot.
var _seen_ticks: Dictionary = {}

## The least number of ticks after its own a late shot is still fired (a quarter second at 64 Hz); see [method late_fire_max_ticks].
const LATE_FIRE_MAX_TICKS := 16


## How many ticks after its own a late shot is still fired: the shot rewind's window (`fc_max_unlag_ms`, at most
## [constant FcGame.COLLISION_LAG_MAX_SEC], 32 ticks at 66 Hz), never under [constant LATE_FIRE_MAX_TICKS]. A server running far below
## its tick rate (64 bots: 4-10 frames a second, 7-16 ticks a frame) hands commands a whole frame late, and a fixed 16 dropped
## those taps although the rewind could still stand the target where the shooter drew it.
func late_fire_max_ticks() -> int:
	if game == null or game.max_unlag_ms <= 0.0:
		return LATE_FIRE_MAX_TICKS
	return maxi(LATE_FIRE_MAX_TICKS, ceili(minf(game.max_unlag_ms * 0.001, FcGame.COLLISION_LAG_MAX_SEC) * float(game.tick_rate)))


## Counts a late shot fired or dropped, on the bridge and in the game's rewind counts (`late_fired`, `late_dropped`), so a dropped
## one is in the `sv_shot_rewind_log_sec` line and never silent.
func _count_late_fire(honoured: bool) -> void:
	if honoured:
		late_fire_honoured += 1
	else:
		late_fire_dropped += 1
	if game != null:
		game.count_shot_rewind(&"late_fired" if honoured else &"late_dropped")


## Finds the shots in [param batch] whose command is new here but for a tick the server has simulated.
## Three lost packets and a late fourth left the only copy of a tap behind its tick, and
## [method GSNetInput.Buffer.push_batch] skips such a copy without a count: the shooter saw the
## shot and the server never fired it. It is queued to fire on the next command with the view
## the shooter drew ([method take_late_fire]); one too old is counted as late and dropped.
func _note_late_fires(peer_id: int, buffer: GSNetInput.Buffer, batch: Array) -> void:
	var seen: Dictionary = _seen_ticks.get_or_add(peer_id, {})
	var consumed := buffer.last_consumed_tick()
	# Whether each tick in the packet holds the trigger, so a late tick is judged against the one before it.
	var held_here: Dictionary = {}
	for item in batch:
		var each := item as FcNetCommand
		if each != null:
			held_here[each.tick] = each.fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK)
	for i in batch.size():
		var command := batch[i] as FcNetCommand
		if command == null or seen.has(command.tick):
			continue
		var held := command.fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK)
		seen[command.tick] = held
		if consumed < 0 or command.tick > consumed or not held:
			continue
		# Only the tick the trigger went down on is the tap. A tap held for three ticks that all came late queued three
		# shots, the second and third fired one after another on the commands after it, and their cooldown refused the
		# shooter's next tap: the client drew one shot per tap and the server fired some taps twice and the next never.
		if bool(held_here.get(command.tick - 1, seen.get(command.tick - 1, false))):
			continue
		# Its next tick reached the server earlier, still held, and was simulated: that tick took the tap's edge and fired it.
		if command.tick + 1 <= consumed and bool(seen.get(command.tick + 1, false)):
			continue
		var age := consumed - command.tick
		if age >= late_fire_max_ticks():
			_count_late_fire(false)
			if i != batch.size() - 1:
				# The packet's own command is counted late by the buffer.
				buffer.late_count += 1
			continue
		var view := float(command.tick) - command.view_lag_ticks() if command.view_lag_q >= 0 else -1.0
		(late_fires.get_or_add(peer_id, []) as Array).append([command.tick, view, command.view_back, command.view_span, command.move.yaw, command.move.pitch, command.view_target_pairs()])
	if seen.size() > 256:
		for tick: int in seen.keys():
			if tick < consumed - 128:
				seen.erase(tick)


## Puts the oldest late shot of [param peer_id] on [param command] (for [param tick]) when that command is not firing itself, with the view lag the shooter drew it at moved to this tick. Returns
## [fire, lag, back, span, yaw, pitch, targets, the shot's own tick] for the player to use, or an empty array. A late shot that waits too long behind firing commands is dropped and counted.
func take_late_fire(peer_id: int, tick: int, command: FcNetCommand) -> Array:
	var queue: Array = late_fires.get(peer_id, [])
	if queue.is_empty():
		return []
	var window := late_fire_max_ticks()
	while not queue.is_empty() and tick - int((queue[0] as Array)[0]) >= window:
		queue.pop_front()
		_count_late_fire(false)
	if queue.is_empty():
		return []
	if command.fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK) and not _held_since(peer_id, int((queue[0] as Array)[0]), command.tick):
		# A new tap of its own on this command: it fires now, and the late one waits for a command that does not.
		return []
	# Not firing, or the late tap still held (its first ticks came late, this one on time): the late tap fires here, once,
	# aimed and rewound as the shooter drew it, rather than the held tick firing it as if it had been pressed now.
	var late: Array = queue.pop_front()
	_count_late_fire(true)
	var fire := command.fire.duplicate_command()
	fire.set_button(GSWeaponCommand.BUTTON_ATTACK, true)
	var behind := tick - int(late[0])
	var view: float = late[1]
	var back: int = int(late[2])
	return [fire, float(tick) - view if view >= 0.0 else command.view_lag_ticks(),
		back + behind if back >= 0 else command.view_back, int(late[3]) if back >= 0 else command.view_span, float(late[4]), float(late[5]), late[6], int(late[0])]


## Whether [param peer_id] held the trigger on every tick from [param from_tick] up to (not including) [param to_tick], as far as
## the commands that reached the server tell: the on-time command at [param to_tick] is then the same tap as the late one.
func _held_since(peer_id: int, from_tick: int, to_tick: int) -> bool:
	var seen: Dictionary = _seen_ticks.get(peer_id, {})
	for t in range(from_tick, to_tick):
		if not bool(seen.get(t, false)):
			return false
	return true


# --- Events and requests ---------------------------------------------------
#
# Everything the server tells a client that is not a snapshot, and everything a client
# asks for. Both ride one message type with a kind inside it — see [FcEvent] — so
# adding one is not a wire-id change on two separately-built programs.


## Releases what `cl_latency_baseline` is holding. A client drives its own clock (`auto_tick` off), so gs-net's own step never runs and held snapshots would wait for ever; call it once a frame.
func advance_latency(delta: float) -> void:
	if net != null and net.latency.busy():
		net.latency.advance(delta)


## Sends one input command to the server, through `cl_latency_baseline` when it is on (the link's RPC is not gs-net's send path).
func send_input(tick: int, move: GSFpsCommand, fire: GSWeaponCommand) -> void:
	if link != null:
		_send_held(link.send_input, encode_input(tick, move, fire))


# --- Monsters ----------------------------------------------------------------


## How many monsters this end replicates or draws.
func monster_count() -> int:
	return _monster_nets.size() if net != null and net.is_server else _monster_mirrors.size()


## Tells every ready peer where the match is. Server side.
func announce_match_state() -> void:
	_send_match_state(0)


## An extend raised the match's score limit: everybody's HUD shows it, and a late joiner
## would otherwise be told the one the match started with.
func note_score_limit_changed() -> void:
	if net != null and net.is_server:
		_send_match_state(0)


## An event arrived. Client side.
##
## Through `GSNetManager.receive` rather than straight to the registry: that is where
## the payload cap, the per-peer rate limit and the direction check live, and a bridge
## that decoded for itself would be a second entry point with none of them.
##
## With [member event_budget_usec] set, events past a frame's budget wait for the next frame, in
## arrival order (a join backlog of 32 players and the arming was one 300 ms frame on staging02).
func receive_event(payload: PackedByteArray) -> GSResult:
	if net == null:
		return GSResult.fail(GSError.CODE_STATE, "No manager.")
	if event_budget_usec <= 0:
		return net.receive(payload, 1)
	if not _events_waiting.is_empty() or _event_usec_this_frame() >= event_budget_usec:
		_wait_event(payload)
		return GSResult.success(0)
	return _receive_timed(payload)


## Events [method receive_event] holds for a later frame.
func events_waiting() -> int:
	return _events_waiting.size()


func _event_usec_this_frame() -> int:
	return _event_usec if _event_frame == Engine.get_process_frames() else 0


func _receive_timed(payload: PackedByteArray) -> GSResult:
	var frame := Engine.get_process_frames()
	if _event_frame != frame:
		_event_frame = frame
		_event_usec = 0
	var started := Time.get_ticks_usec()
	var received := net.receive(payload, 1)
	_event_usec += Time.get_ticks_usec() - started
	return received


func _wait_event(payload: PackedByteArray) -> void:
	_events_waiting.append(payload)
	if is_inside_tree() and not get_tree().process_frame.is_connected(_drain_events):
		get_tree().process_frame.connect(_drain_events)


## On process_frame, after the frame's poll: what the poll's events left of the budget goes to the oldest waiting.
func _drain_events() -> void:
	while not _events_waiting.is_empty() and net != null and _event_usec_this_frame() < event_budget_usec:
		var _received := _receive_timed(_events_waiting.pop_front())
	if _events_waiting.is_empty() or net == null:
		_events_waiting.clear()
		get_tree().process_frame.disconnect(_drain_events)


## A request arrived. Server side.
func receive_request(peer_id: int, payload: PackedByteArray) -> GSResult:
	if net == null:
		return GSResult.fail(GSError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


## A relayed voice frame arrived. Client side.
## Not through [GSNetManager]: a voice frame is an opaque codec blob, and the replication
## schema must not change with the codec. Handled by [member voice_in_fn].
func receive_voice(payload: PackedByteArray) -> GSResult:
	if not voice_in_fn.is_valid():
		return GSResult.fail(GSError.CODE_STATE, "Nothing here plays voice.")

	voice_in_fn.call(payload)
	return GSResult.success(payload.size())


## A client's captured audio arrived. Server side.
##
## The speaker is [param peer_id] as the transport reported it, never read from the payload,
## or a client could put words in anybody's mouth.
func receive_voice_frame(peer_id: int, payload: PackedByteArray) -> GSResult:
	if not voice_relay_fn.is_valid():
		return GSResult.fail(GSError.CODE_STATE, "This end does not relay voice.")

	voice_relay_fn.call(peer_id, payload)
	return GSResult.success(payload.size())


## A gs-map announcement arrived. Client side.
func receive_map(payload: Dictionary) -> GSResult:
	if not map_in_fn.is_valid():
		return GSResult.fail(GSError.CODE_STATE, "This end does not follow maps.")

	map_in_fn.call(payload)
	return GSResult.success(payload.size())


## A client's map progress or readiness arrived. Server side.
func receive_map_report(peer_id: int, payload: Dictionary) -> GSResult:
	if not map_report_fn.is_valid():
		return GSResult.fail(GSError.CODE_STATE, "This end does not host maps.")

	map_report_fn.call(peer_id, payload)
	return GSResult.success(payload.size())


func describe() -> Dictionary:
	return {
		"players": _behaviours.size(),
		"peers": _players_by_peer.size(),
		"tick": _tick,
		"ticked_for": _game_ticked_for,
		"inputs_from": inputs_from,
		"events_waiting": _events_waiting.size(),
	}


func behaviour_for(session_id: int) -> FcPlayerNet:
	return _behaviours.get(session_id)


## Adds a server-side bot called [param display_name]. Its session id, or 0 if the game
## refused it.
func add_bot(display_name: String) -> int:
	if net == null or not net.is_server:
		return 0

	_next_bot += 1
	var session_id := BOT_SESSION_BASE + _next_bot
	var added := game.add_player(session_id, display_name)

	if not added.ok:
		return 0

	var player := added.value as FcPlayer
	player.set_meta(&"bot", true)

	# Owned by the server (peer 0): nobody predicts it, every client mirrors it.
	var identity := _build_identity(player, 0)
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		_behaviours.erase(session_id)
		game.remove_player(session_id)
		return 0

	var mind := FcBots.Mind.new()
	mind.seed = session_id
	_bot_minds[session_id] = mind
	var bot_world := FcBots.world_for(game)
	bot_world.warm()
	# The persona profiles load once, here as the bot joins: on its first tick they were 32 ms of tick 1.
	var _pool := bot_world.personas_for(FcBots.personas_mode)

	var payload := join_payload(session_id)
	player_announced.emit(payload)
	send_event(0, FcEvents.Kind.JOIN, payload)
	return session_id
