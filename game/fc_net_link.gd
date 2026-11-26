extends GSGameNetLink

const FcFrameProbe := preload("fc_frame_probe.gd")

## The wire this game needs on one node that exists on both ends: the shared skeleton in
## [GSGameNetLink] (snapshot, event, input and request calls, the counters, the loopback seam, the
## perf network table) plus what is this game's own: snapshot coalescing for a browser, voice with
## its own client-to-server frame, the gs-map messages, and a send that reports being dropped.
##
## **Godot refuses an RPC unless both ends declare the same set of `@rpc` methods**, and routes it
## by the receiver's node path. One script on both ends makes the set identical by construction;
## the node is named [constant NODE_NAME] on both, under a parent named the same ([GSServer] and
## [GSClientLink], both `Server`). One extra `@rpc` method on one side makes every RPC between
## them fail, handshake included, and the only symptom is a timeout.

const CHANNEL := "arena.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"Arena"

## Voice rides its own channel ([constant GSGameNetLink.CHANNEL_VOICE]) so a talk spurt (fifty
## frames a second per speaker) never sits in the snapshots' ordered queue. The calls are declared
## `unreliable`; what that becomes on the wire (UDP on a desktop, TCP in a browser) is
## `GSTransportAuto`'s decision, and this file names neither.

## The [Dictionary]-carrying half of [member loopback].
##
## [b]A second callable rather than a wider signature on the first.[/b] `loopback`
## takes a [PackedByteArray] and four call sites hand it one; widening it to a Variant
## would make every one of those pass a byte array through a parameter that no longer
## says so, and the map messages are the only thing on this link that is not bytes.
var loopback_map: Callable = Callable()

var map_sent: int = 0
var map_received: int = 0
## Snapshots received but never decoded, because a newer tick came in the same poll.
var snapshots_coalesced: int = 0

## [b]Decode only the newest snapshot a poll brings[/b] (`cl_snapshot_coalesce`). A browser
## frame that runs long receives several snapshots at once, and decoding every one of them
## (header, entities, reconcile) is most of what a joined browser client spends. With this
## on, a poll's snapshots are held until the end of the poll and only the newest tick's
## parts are applied; the older ones count as lost. That is exactly the loss the server
## already repairs: the ack stays on the last applied tick, so a strict-ack server re-sends
## whatever the skipped ticks carried. Reliable events and map messages flush the held
## snapshots first, so the order between state and events is kept. On by default only in
## a browser; native clients (and every hit-reg suite) decode each snapshot as before.
static var coalesce: bool = GSPlatform.is_web()

var _held: Array[PackedByteArray] = []

## Sends dropped because there was no peer to send them on.
var dropped: int = 0


## Whether the last send found the link live. Null before the first send, so the first
## drop is reported as the edge it is. See [method _can_send].
var _link_live: Variant = null


func _init() -> void:
	channel = CHANNEL


static func attached_to(
	parent: Node, p_bridge: Node, server: bool
) -> Node:
	# Bare new(): naming this script here would be a self-preload, which never frees.
	var link: Node = new()
	link.name = NODE_NAME
	link.bridge = p_bridge
	link.is_server = server
	return link


## Whether a send can go anywhere, with the change reported rather than every call.
##
## [b]On the edge, not per send.[/b] A snapshot goes out thirty-two times a second per
## peer; a line per dropped one is a log nobody can read, and no line at all is a server
## whose clients stopped hearing it without anything saying so. So one WARN when sends
## start being dropped, and one INFO with the count when they stop.
func _live() -> bool:
	var live := loopback.is_valid() or (
		is_inside_tree() and multiplayer != null and multiplayer.has_multiplayer_peer()
	)

	if _link_live == null or bool(_link_live) != live:
		if not live:
			GSLog.warn(CHANNEL, "sends are being dropped: there is no multiplayer peer", {
				"server": is_server,
			})
		elif _link_live != null:
			GSLog.info(CHANNEL, "the link is live again", {
				"server": is_server, "dropped": dropped,
			})

		_link_live = live

	if not live:
		dropped += 1

	return live


# --- Sending ---------------------------------------------------------------

## One encoded voice frame, server to one listener.
##
## [b]Never a broadcast, and the loop over listeners is deliberately not here.[/b]
## [GSVoiceRouter] decides who hears a speaker — everybody, a team, or whoever is
## within range — and a `send(bytes, 0)` convention here would quietly deliver a
## proximity packet to the whole server. This family has shipped that exact bug once
## already, through a bot registered as peer 0.
func send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if peer_id <= 0 or not _live():
		return

	voice_sent += 1
	_cost(&"voice", 1, payload)

	if loopback.is_valid():
		loopback.call(&"voice", peer_id, payload)
	else:
		_net_voice.rpc_id(peer_id, payload)



## One captured voice frame, client to server.
func send_voice_frame(payload: PackedByteArray) -> void:
	if not _live():
		return

	voice_sent += 1
	_cost(&"voice", 1, payload)

	if loopback.is_valid():
		loopback.call(&"voice_frame", 1, payload)
	else:
		_net_voice_frame.rpc_id(1, payload)


## One gs-map protocol message, server to one peer.
##
## [b]A [Dictionary] rather than bytes, and it is the one thing on this link that is
## not bit-packed.[/b] gs-map's messages are five kinds of announcement that happen a
## few times an hour — a bit-packed wire for them would be a second schema to keep in
## step with gs-map's own, for a saving of about forty bytes per map change. The
## bit-packing exists for the snapshot, which is thirty-two of them a second.
func send_map(peer_id: int, payload: Dictionary) -> void:
	if peer_id <= 0 or not _live():
		return

	map_sent += 1

	# [b]`loopback_map`, not `loopback` — and tested separately.[/b] A harness that set the byte loopback and not this one would otherwise call an invalid Callable, which
	# is a crash in a test that was only trying not to open a socket. Falling through to the RPC is wrong too when there is no multiplayer peer, so the send is simply
	# dropped and counted, which is what a lost packet looks like anyway.
	if loopback.is_valid():
		if loopback_map.is_valid():
			loopback_map.call(&"map", peer_id, payload)
	else:
		_net_map.rpc_id(peer_id, payload)


## A client's answer: how far through the download it is, or that it is ready.
func send_map_report(payload: Dictionary) -> void:
	if not _live():
		return

	map_sent += 1

	if loopback.is_valid():
		if loopback_map.is_valid():
			loopback_map.call(&"map_report", 1, payload)
	else:
		_net_map_report.rpc_id(1, payload)


# --- Receiving -------------------------------------------------------------

## State from the authority. Unreliable: a newer snapshot supersedes a lost one, and
## re-sending a hundred-millisecond-old position is worse than useless.
@rpc("authority", "unreliable", "call_remote", CHANNEL_STATE)
func _net_snapshot(payload: PackedByteArray) -> void:
	snapshots_received += 1
	_cost(&"snapshot", 0, payload)

	if bridge == null:
		return

	if coalesce:
		if _held.is_empty():
			_flush_held.call_deferred()
		_held.append(payload)
		return

	_apply_snapshot(payload)


## Its own span: the receive (decode, apply, reconcile, push hooks) runs from the RPC poll,
## outside every frame span.
func _apply_snapshot(payload: PackedByteArray) -> void:
	var t := Time.get_ticks_usec()
	bridge.receive_snapshot(payload)
	FcFrameProbe.add(&"net_snapshot", t)


## Applies the held snapshots of the newest tick (every part of it, in arrival order) and
## drops the rest. Peeking the tick is a 32-bit read; the decode is what is saved.
func _flush_held() -> void:
	if _held.is_empty():
		return
	var held := _held
	_held = []
	if bridge == null:
		return
	if held.size() == 1:
		_apply_snapshot(held[0])
		return

	var ticks := PackedInt64Array()
	ticks.resize(held.size())
	var newest := -1
	for i in held.size():
		var reader := GSNetReader.new(held[i])
		var tick := reader.read_uint(32) if held[i].size() >= 4 else -1
		ticks[i] = tick
		newest = maxi(newest, tick)

	for i in held.size():
		if ticks[i] == newest:
			_apply_snapshot(held[i])
		else:
			snapshots_coalesced += 1


## Anything from the authority that must arrive: HELLO, joins, kills, the match state.
@rpc("authority", "reliable", "call_remote", CHANNEL_STATE)
func _net_event(payload: PackedByteArray) -> void:
	events_received += 1
	_cost(&"event", 0, payload)
	_flush_held()

	if bridge != null:
		var t := Time.get_ticks_usec()
		bridge.receive_event(payload)
		FcFrameProbe.add(&"net_event", t)


## A relayed voice frame. Unreliable: a lost frame is 20 ms of silence a jitter buffer
## conceals, and a resent one arrives after the frames either side of it have played.
@rpc("authority", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice(payload: PackedByteArray) -> void:
	voice_received += 1
	_cost(&"voice", 0, payload)

	if bridge != null:
		bridge.receive_voice(payload)


## A client's captured audio. The speaker is stamped by the server from the transport's
## sender, never read out of the payload — a client that could name its own speaker id
## could put words in anybody's mouth, and the only symptom is exactly that.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice_frame(payload: PackedByteArray) -> void:
	voice_received += 1
	_cost(&"voice", 0, payload)

	if bridge != null:
		bridge.receive_voice_frame(multiplayer.get_remote_sender_id(), payload)


## A map-change announcement from the server.
@rpc("authority", "reliable", "call_remote", CHANNEL_STATE)
func _net_map(payload: Dictionary) -> void:
	map_received += 1
	_flush_held()

	if bridge != null:
		bridge.receive_map(payload)


## A client's progress or readiness. The peer comes from the transport.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_STATE)
func _net_map_report(payload: Dictionary) -> void:
	map_received += 1

	if bridge != null:
		bridge.receive_map_report(multiplayer.get_remote_sender_id(), payload)


## Hands a [Dictionary] payload to this end as though it had arrived over the wire.
func deliver_map(method: StringName, from_peer_id: int, payload: Dictionary) -> void:
	if bridge == null:
		return

	map_received += 1

	if method == &"map":
		bridge.receive_map(payload)
	else:
		bridge.receive_map_report(from_peer_id, payload)


## Hands a payload to this end as though it had arrived over the wire: the voice kinds this game
## routes itself, every other kind through [method GSGameNetLink.deliver].
func deliver(method: StringName, from_peer_id: int, payload: PackedByteArray) -> void:
	match method:
		&"voice":
			if bridge != null:
				voice_received += 1
				_cost(&"voice", 0, payload)
				bridge.receive_voice(payload)
		&"voice_frame":
			if bridge != null:
				voice_received += 1
				_cost(&"voice", 0, payload)
				bridge.receive_voice_frame(from_peer_id, payload)
		_:
			super.deliver(method, from_peer_id, payload)


func describe() -> Dictionary:
	var d := super.describe()
	d["map"] = [map_sent, map_received]
	d["dropped"] = dropped
	d["coalesced"] = snapshots_coalesced
	return d
