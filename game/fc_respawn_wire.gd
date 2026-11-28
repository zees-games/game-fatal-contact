extends RefCounted
## The respawn delay on the wire: the RESPAWN_WAIT sub-kind of the MORE event, server to client.
## A victim id and the wait in milliseconds; the client counts down from the moment it arrives.

const FcKnifeEvents := preload("fc_knife_events.gd")


static func write_wait(victim: int, sec: float) -> PackedByteArray:
	var w := GSNetWriter.new()
	w.write_varint(FcKnifeEvents.More.RESPAWN_WAIT)
	w.write_varint(victim)
	w.write_varint(maxi(0, int(round(sec * 1000.0))))
	return w.to_bytes()


## Read after the sub-kind.
static func read_wait(reader: GSNetReader) -> Dictionary:
	var out := {"victim": reader.read_varint(), "sec": float(reader.read_varint()) / 1000.0}
	out["ok"] = reader.ok()
	return out
