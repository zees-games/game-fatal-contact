extends "fc_net_knives.gd"

const FcEvent := preload("fc_event.gd")
const FcNetLink := preload("fc_net_link.gd")
## Peers that have said they can receive. Server side.
var _ready_peers: Dictionary = {}
var _watched_projectiles: RefCounted = null
## The RPC surface, on both ends. Created by [method attach].
var link: FcNetLink = null

## The bridge's event sending and the projectile watch that feeds it (launches and grenade effects). Split out of fc_net_bridge_b1.gd for file size.


func send_event(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or link == null:
		return

	var payload := encode_event(kind, body)

	if payload.is_empty():
		return

	if peer_id != 0:
		if _ready_peers.has(peer_id):
			link.send_event(peer_id, payload)
		return

	for ready_peer in _ready_peers:
		link.send_event(int(ready_peer), payload)


## An event as the bytes [method receive_event] reads, or empty if it would not encode.
## Public so a harness without a link delivers exactly what the link would carry.
func encode_event(kind: int, body: PackedByteArray) -> PackedByteArray:
	var writer := DotNetWriter.new()
	var wrote := net.messages.encode(FcEvent.new(kind, body), writer)

	if not wrote.ok:
		DotLog.warn(CHANNEL, "could not encode an event", {
			"kind": FcEvents.kind_name(kind), "error": str(wrote.error)
		})
		return PackedByteArray()

	return writer.to_bytes()


func _watch_projectiles() -> void:
	if net == null or not net.is_server or game == null:
		return

	if not game.grenade_effect.is_connected(_on_grenade_effect):
		game.grenade_effect.connect(_on_grenade_effect)

	var layer: RefCounted = game.projectiles

	if layer == _watched_projectiles:
		return

	_watched_projectiles = layer

	if layer != null and not layer.launched.is_connected(_on_launched):
		layer.launched.connect(_on_launched)


func _on_grenade_effect(info: Dictionary) -> void:
	send_event(0, FcEvents.Kind.GRENADE_FX, FcEvents.write_grenade_fx(
		int(info["fx"]), info["position"], float(info["radius"]), float(info["seconds"]), int(info["victim"]), float(info.get("strength", 1.0))))


func _on_launched(spawn: DotWeaponSpawn) -> void:
	send_event(0, FcEvents.Kind.LAUNCH, FcEvents.write_launch(
		spawn, FcContent.weapon_index(spawn.id)
	))
