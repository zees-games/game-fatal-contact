extends GSNetInput

const FcNetCommand := preload("fc_net_command.gd")
const FcPlayer := preload("fc_player.gd")

## One tick of a player's intent, on the wire.
##
## [b]This is the only thing a client is allowed to send about itself.[/b] Clients
## send inputs, never state — a client that could send a position could send any
## position, and gs-net's whole security model rests on the distinction.
##
## Fatal Contact player has two commands, because two addons that do not know about each
## other each define one: [GSFpsCommand] for movement and [GSWeaponCommand] for
## the weapon. Both already know how to write themselves through a duck-typed
## [code]Variant[/code] writer, for the same reason [GSFpsNetSync] never mentions
## [code]GSNetVar[/code] — an addon that named a gs-net class would fail to parse
## without gs-net installed. Composing them here costs nothing and keeps the
## quantisation decisions in the addon that owns them.
##
## [b]The view angles travel once, not twice.[/b] [GSWeaponCommand] carries its own
## yaw and pitch, and sending them again would be 21 wasted bits per tick — and worse
## than wasted: two copies can disagree, and then the shot leaves at an angle the
## player was not looking along. [FcPlayer.simulate_tick] already overwrites the
## combat command's angles from the simulated movement state, so the movement
## command's copy is the only one that was ever read.

## Movement: the move vector, the view angles, jump and crouch.
var move: GSFpsCommand = GSFpsCommand.new()

## Weapons: the selected slot, attack, reload, and the rest of the buttons.
var fire: GSWeaponCommand = GSWeaponCommand.new()

## How far behind this command's tick the client was drawing everybody else, in quarter ticks: the tick a shot fired on this command was aimed at, as the server rewinds to it
## for lag compensation (`FcGame._rewind_to`). Sent only when a button is down -- a command that cannot fire costs one bit for it -- and capped by the server, never
## trusted: [constant MAX_VIEW_LAG_Q] here, and the combat config's rewind limit there.
var view_lag_q: int = -1

## Send [member view_lag_q] on every command, not only a firing one: while players are solid
## the server rewinds the others to it for this command's movement too. Not on the wire.
var lag_always: bool = false

## 1023 quarter ticks: four seconds at 64 ticks and two at 128, past any rewind limit.
##
## It was 255 in 8 bits, commented as "just under four seconds" -- which is 255 TICKS.
## In quarter ticks it is 64 ticks, one second at 64 and half a second at 128, so on a
## 128-tick server the wire clamped a 300-400 ms player below the rewind limit that was
## meant to compensate them, whatever `fc_max_unlag_ms` said.
const MAX_VIEW_LAG_Q := 1023
const VIEW_LAG_BITS := 10

## The snapshot ticks the client drew the others between at the view tick, as this command's tick
## less [member view_back] and that plus [member view_span]; -1 for none. Sent with the lag (while
## players are solid, and on a firing command), so the server rewinds between the same two samples,
## a lost one included.
##
## [b]Why a shot needs it[/b]. The client draws the others as a blend of two snapshots
## two ticks apart; the server's ring has every tick. At a strafe reversal the blend cuts the
## corner the ring keeps, by up to 12 cm in headless_hitreg_chaos, and torso-edge shots aimed at
## the drawn body missed (pistol at 60 ms, minigun at 30 ms, with a two-snapshot buffer).
var view_back: int = -1
var view_span: int = 0
const VIEW_BACK_BITS := 7
const VIEW_SPAN_BITS := 5

## Per target, on a firing command: `[net_id, back, span]` for each remote player the client drew between two samples of its OWN other than [member view_back]'s pair, or ahead of its newest (extrapolating): ticks back from this command's tick, and on to the newer. Empty for none.
## Why the shared pair is not enough: in a full room the relevance rings (FcNetAoi) send a player 30 m out every fourth snapshot (every second inside the aim cone), a lost snapshot doubles that, and the client blends that player across its own samples 8 to 16 ticks apart or runs it ahead of the newest,
## while [member view_back] names the room's pair two ticks apart: the server stood the far body up to a third of a metre off the one drawn (headless_hitreg_far; the owner's 46.8 m Marksman miss at 7:35.2). With the target's own pair the server blends, or runs ahead, as the client drew it (`FcNetBridge.shot_feet`). An entry may carry three more, `[..., x, y, z]` in millimetres: the resume ease the body was drawn off its samples by (GSNetInterpolator._ease_resume), judged by `sv_shot_ease_max`.
var view_targets: Array = []
## Millimetres to the metre for a view target's ease.
const EASE_PER_M := 1000.0

## Bits each of yaw and pitch take again on a firing command, after [GSFpsCommand]'s 12 and 9 (0.088 and 0.35 degree steps).
## The client predicts its shot along the angles it sampled and draws the spark there; the server traced the coarse ones, up to
## 0.18 degrees lower or higher: 18 cm at 60 m, off a scoped torso's edge or a head. 16 bits are 0.0055 and 0.0027 degrees (3 mm at 60 m),
## 32 bits only on a tick the trigger is down. Movement keeps the coarse angles on every other tick (nightly dot-player-9).
const AIM_BITS := 16


func _write(writer: GSNetWriter) -> void:
	move.write(writer)
	# Slot and buttons only. The angles come from `move`; see the class notes.
	writer.write_uint(clampi(fire.slot, 0, 15), 4)
	writer.write_uint(fire.buttons, GSWeaponCommand.BUTTON_BITS)
	if fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK):
		writer.write_angle(move.yaw, AIM_BITS)
		writer.write_float_range(move.pitch, -90.0, 90.0, AIM_BITS)
	var lagged := (fire.buttons != 0 or lag_always) and view_lag_q >= 0
	writer.write_bool(lagged)
	if lagged:
		writer.write_uint(clampi(view_lag_q, 0, MAX_VIEW_LAG_Q), VIEW_LAG_BITS)
		# A firing command carries it too: the shot is rewound between the same two samples
		# the shooter drew between (`FcNetBridge.shot_feet`), not to the ring's own ticks.
		var bracketed := view_back >= 0
		writer.write_bool(bracketed)
		if bracketed:
			writer.write_uint(clampi(view_back, 0, (1 << VIEW_BACK_BITS) - 1), VIEW_BACK_BITS)
			writer.write_uint(clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1), VIEW_SPAN_BITS)
		# One bit on a lagged command that names no target of its own; only a firing command names any.
		var targeted := fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK) and not view_targets.is_empty()
		writer.write_bool(targeted)
		if targeted:
			writer.write_varint(view_targets.size() - 1)
			for entry: Array in view_targets:
				writer.write_varint(maxi(int(entry[0]), 0))
				writer.write_varint(maxi(int(entry[1]), 0))
				writer.write_varint(maxi(int(entry[2]), 0))
				writer.write_bool(entry.size() == 6)
				for i in range(3, entry.size()):
					writer.write_svarint(int(entry[i]))


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)

	fire = GSWeaponCommand.new()
	fire.slot = reader.read_uint(4)
	fire.buttons = reader.read_uint(GSWeaponCommand.BUTTON_BITS)
	if fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK):
		move.yaw = reader.read_angle(AIM_BITS)
		move.pitch = reader.read_float_range(-90.0, 90.0, AIM_BITS)
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	view_lag_q = -1
	view_back = -1
	view_span = 0
	view_targets = []
	if reader.read_bool():
		view_lag_q = reader.read_uint(VIEW_LAG_BITS)
		if reader.read_bool():
			view_back = reader.read_uint(VIEW_BACK_BITS)
			view_span = reader.read_uint(VIEW_SPAN_BITS)
		if reader.read_bool():
			# Three varints of a byte or more each: a count the packet cannot hold is a malformed one, refused whole rather than read as far as it goes.
			var count := reader.read_varint() + 1
			if count > reader.bits_remaining() / 24:
				reader.exhausted = true
				return
			for _i in count:
				var entry := [reader.read_varint(), reader.read_varint(), reader.read_varint()]
				if reader.read_bool():
					entry.append_array([reader.read_svarint(), reader.read_svarint(), reader.read_svarint()])
				if not reader.ok():
					view_targets = []
					return
				view_targets.append(entry)


## Clamps what a client could exaggerate.
##
## [b]Not optional, and not redundant with quantisation.[/b] Quantisation bounds each
## field on its own; it cannot bound the relationship between them. A move vector of
## (1, 1) is two legal components and a length of 1.41, which is 41% more speed than
## anyone else — [method GSFpsCommand.sanitise] is what clamps the length.
func _sanitise() -> void:
	move.sanitise()
	# `max_slots` matches FcPlayer's arsenal: the pack's five. A slot outside it cannot
	# select anything, but bounding it here keeps a nonsense value out of the simulation
	# rather than relying on every downstream reader to range-check. It was 4 when the
	# arsenal had four, and a hard 4 here would have made the throwable slot unreachable
	# over the wire while it worked offline.
	fire.sanitise(FcPlayer.MAX_SLOTS)
	# Re-derived after both sanitise calls, so a clamped pitch cannot leave the
	# aim pointing somewhere the movement never looked.
	fire.yaw = move.yaw
	fire.pitch = move.pitch
	view_lag_q = clampi(view_lag_q, -1, MAX_VIEW_LAG_Q)
	view_back = clampi(view_back, -1, (1 << VIEW_BACK_BITS) - 1)
	view_span = clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1)
	# A target's pair is judged by the server's rewind (sv_shot_bracket_max_span, the ring's reach), not here; an entry that cannot be one is dropped.
	if not view_targets.is_empty():
		var kept: Array = []
		for entry: Variant in view_targets:
			if entry is Array and (entry as Array).size() in [3, 6] and int(entry[0]) > 0 and int(entry[1]) >= 0 and int(entry[2]) > 0:
				kept.append(entry)
		view_targets = kept


## Stands still and holds fire, looking where it looked (GSNetConfig.starved_input_hold_sec).
func _neutralise() -> void:
	move.move = Vector2.ZERO
	move.buttons = 0
	fire.buttons = 0


## [member view_targets] in absolute ticks: `{net_id: [Vector2i(older, newer), ease]}`, measured from this command's own tick; ease in metres, zero for none.
func view_target_pairs() -> Dictionary:
	var pairs := {}
	for entry: Array in view_targets:
		var older := tick - int(entry[1])
		var ease := Vector3(entry[3], entry[4], entry[5]) / EASE_PER_M if entry.size() == 6 else Vector3.ZERO
		pairs[int(entry[0])] = [Vector2i(older, older + int(entry[2])), ease]
	return pairs


## The view lag in ticks, or -1 for none sent.
func view_lag_ticks() -> float:
	return float(view_lag_q) * 0.25 if view_lag_q >= 0 else -1.0


## Whether two inputs are identical, so a held-still player costs less.
func _equals(other: GSNetInput) -> bool:
	var them := other as FcNetCommand

	if them == null:
		return false

	return move.equals(them.move) and fire.equals(them.fire) and view_lag_q == them.view_lag_q \
		and view_back == them.view_back and view_span == them.view_span and view_targets == them.view_targets


## Bits one command costs, before gs-net's own framing.
static func estimated_bits() -> int:
	return GSFpsCommand.estimated_bits() + 4 + GSWeaponCommand.BUTTON_BITS + 1


func describe() -> Dictionary:
	return {
		"tick": tick,
		"move": move.describe(),
		"fire": fire.describe(),
		"view_lag_ticks": view_lag_ticks(),
		"view_bracket": [view_back, view_span],
		"view_targets": view_targets,
	}
