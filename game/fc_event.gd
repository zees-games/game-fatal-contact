extends GSNetMessage

const FcEvents := preload("fc_events.gd")

## Anything the authority tells a client that is not a snapshot. Reliable, to clients.
##
## A kind and a body, rather than one message type per event. gs-net seals its message
## registry by sorting the type names and assigning wire ids from that order, so every
## message type added is a wire-id change on both ends — and the two ends are separate
## programs the moment a browser connects. One message with a kind inside it moves that
## versioning problem into a field this game owns.

const NAME := &"arena.event"

## Bits the kind occupies. Five is 32 kinds; there are far fewer and there will not be
## thirty-two.
const KIND_BITS := 5

## Events only travel server to client, so this is a sanity bound, not a flood guard. A map's first
## state snapshot is tens of kilobytes; past the old 16 KB the body read back empty and unparsed.
const MAX_BODY := 1 << 20

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b]
## It used to, for a typed [code]static func of() -> FcEvent[/code] factory. A script that
## [code]extends GSNetMessage[/code] and preloads ITSELF, first loaded from a module a
## running [GSServer] loads at runtime — which is how every deployed server loads this
## game — leaks the whole script graph at exit on Godot 4.7.2. Measured in
## mg-buses-from-hell (8ed866c) with a two-line reproduction. The registry decodes with a
## bare [code]new()[/code], which is why both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: GSNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: GSNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> GSResult:
	if kind < 0 or kind >= FcEvents.Kind.size():
		return GSResult.fail(GSError.CODE_INVALID, "Unknown event kind %d." % kind)

	return GSResult.success(true)


## Whether every [enum FcEvents.Kind] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(FcEvents.Kind.values().max()) < (1 << KIND_BITS)


func reader() -> GSNetReader:
	return GSNetReader.new(body)


func _to_string() -> String:
	return "FcEvent(%s, %d bytes)" % [FcEvents.kind_name(kind), body.size()]
