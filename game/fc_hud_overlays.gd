@tool
extends "fc_hud_labels.gd"

## The HUD's full-screen overlays: sizing one to the whole viewport, and the red hurt edge.


## Covers the whole viewport, like the blind: the HUD's own size leaves the safe-area strip showing.
func _fill_viewport(control: Control) -> void:
	if not is_inside_tree():
		return
	var inverse := get_global_transform().affine_inverse()
	control.position = inverse * Vector2.ZERO
	control.size = inverse.basis_xform(get_viewport_rect().size)


## Frames the hurt overlay is drawn faintly under the cover; its shader compiled on the first hit otherwise.
const HURT_WARM_FRAMES := 3
var _hurt_warm_frames := 0


## Draws the hurt overlay faintly for a few frames (the prewarm calls this under the loading cover).
func warm_hurt() -> void:
	_hurt_warm_frames = HURT_WARM_FRAMES


## The red edge from low health and from a flash.
func _present_hurt(live: bool) -> void:
	if hurt_overlay == null:
		return
	var hurt := 0.0
	if live and player.health != null and player.health.max_health > 0.0:
		var fraction := player.health.health / player.health.max_health
		hurt = clampf((HURT_FROM - fraction) / HURT_FROM, 0.0, 1.0)
		# Squared: a wounded player sees a thin red rim that deepens near death, never a red screen at a third of health.
		hurt *= hurt
	if live and flash_source != null and is_instance_valid(flash_source):
		var flash: Color = flash_source.get(&"flash_colour")
		hurt = maxf(hurt, minf(flash.a * HURT_PULSE_GAIN, HURT_PULSE_MAX))
	if _hurt_warm_frames > 0:
		# Under the loading cover: a faint edge for a few frames so the overlay's shader compiles now, not on the first hit.
		_hurt_warm_frames -= 1
		hurt = maxf(hurt, 0.01)
	hurt_overlay.modulate.a = hurt
	if hurt > 0.0:
		_fill_viewport(hurt_overlay)
