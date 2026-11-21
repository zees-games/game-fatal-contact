extends GSNetMessage

const FcEvents := preload("fc_events.gd")

## A client asking the server for something. Reliable, rare, and never trusted.
##
## The counterpart to [FcEvent]. Same shape and the same reason: one message type
## with a kind inside it, so adding a request is not a wire-id change on both ends.
##
## [b]Nothing in here is a fact.[/b] A request says what a client wants; the server
## decides. In particular the sender is taken from the transport in
## [FcNetLink], never from a field in the body — a peer id inside a payload is a
## claim anybody can make.

const NAME := &"arena.request"

const KIND_BITS := 5
const MAX_BODY := 2048

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b]
## It used to, for a typed [code]static func of() -> FcRequest[/code] factory. A script that
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
	if kind < 0 or kind >= FcEvents.Ask.size():
		return GSResult.fail(GSError.CODE_INVALID, "Unknown request kind %d." % kind)

	return GSResult.success(true)


## Whether every [enum FcEvents.Ask] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(FcEvents.Ask.values().max()) < (1 << KIND_BITS)


func reader() -> GSNetReader:
	return GSNetReader.new(body)


func _to_string() -> String:
	return "FcRequest(%s, %d bytes)" % [FcEvents.ask_name(kind), body.size()]
