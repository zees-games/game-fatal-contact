extends GSGameNetchaosClient

const FcNetBridge := preload("../game/fc_net_bridge.gd")
const FcPresentation := preload("../game/fc_presentation.gd")
const FcSolidBody := preload("../game/fc_solid_body.gd")

## Fatal Contact's side of `tools/netchaos.sh` (dot-game's GSGameNetchaosClient).


func _configure() -> void:
	FcNetBridge.solid_trace = OS.get_environment("NC_SOLID_TRACE") == "1"
	client_scene = "res://game/fc.tscn"
	fire_action = &"arena_fire"


func _prepare(label: String) -> Variant:
	return FcPresentation.use_scratch_settings(label)


func _contacts() -> int:
	return FcSolidBody.hull_stops
