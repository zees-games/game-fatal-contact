extends GSAudioSceneProbe

const FcPresentation := preload("../game/fc_presentation.gd")

## Asks whether this game actually makes a noise, on a machine that has a sound card. Every assertion about its audio once passed while the game was silent (the catalogue named `.ogg` files nobody had produced; a headless run builds a null sink). The loop is GSAudioSceneProbe; this names the cues. Run through `tools/audio_probe.sh`, not `--headless`.


func _prepare() -> void:
	# A scratch settings document, never this machine's real one.
	var _scratch := FcPresentation.use_scratch_settings("audio_probe")
	GSLog.set_level(GSLog.Level.WARN)


func _make_node() -> Node:
	return FcPresentation.new()


func _audio_of(node: Node) -> Object:
	return node.get("audio")


## Two positional shots that must not sound alike, a flat interface sound, a world sound.
func _probe_ids() -> Array[StringName]:
	return [&"fire_rifle", &"fire_rail", &"hit_marker", &"pickup"]


func _id_width() -> int:
	return 12
