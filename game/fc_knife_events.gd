extends RefCounted
## The wire format of the MORE event, the last kind the 5-bit field has: a varint sub-kind, then its body.
## KNIFE is the first sub-kind; its body is gs-weapon's GSWeaponKnifeWire.

enum More { KNIFE, HOST }

## The gs-weapon level whose knife wire carries the Boomerang's glide and turn.
const GLIDE_LEVEL := 41


static func _w() -> GSNetWriter:
	return GSNetWriter.new()


static func write_knife(
	id: int, owner: int, phase: int, victim: int, at: Vector3, motion: Vector3,
	glide: bool = false, turn: Vector3 = Vector3.ZERO
) -> PackedByteArray:
	var w := _w()
	w.write_varint(More.KNIFE)
	var wire: Script = GSWeaponKnifeWire
	if GSAddonApi.build_level("gs_weapon") >= GLIDE_LEVEL:
		wire.call(&"write_knife", w, id, owner, phase, victim, at, motion, glide, turn)
	else:
		GSWeaponKnifeWire.write_knife(w, id, owner, phase, victim, at, motion)
	return w.to_bytes()


## The sub-kind; the body after it is read with the matching reader.
static func read_more(reader: GSNetReader) -> int:
	return reader.read_varint()


static func read_knife(reader: GSNetReader) -> Dictionary:
	return GSWeaponKnifeWire.read_knife(reader)
