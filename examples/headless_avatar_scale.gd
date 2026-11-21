extends GSGameCheckSuite

## Every avatar stands at the configured classic-shooter height: 72 units (crouch 54, eye 64) at
## the map's 0.01905 m a unit, whichever body model it wears, and the hull, eye and hit zones agree.

const FcPlayer := preload("../game/fc_player.gd")
const FcPlayerTunables := preload("../game/fc_player_tunables.gd")
const FcConfig := preload("../game/fc_config.gd")
const UNIT := 0.01905


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("arena: avatar scale")
	FcPlayerTunables.configure_body(72.0, 54.0, 16.0, UNIT)
	var config := FcConfig.new()
	_check(config.avatar_height_units == 72.0 and config.avatar_crouch_units == 54.0 and config.avatar_radius_units == 16.0 and is_equal_approx(config.avatar_unit_metres, UNIT), "config defaults are 72 / 54 / 16 units at 0.01905")

	var t := FcPlayer.fc_tunables()
	_check(is_equal_approx(t.stand_height, 72.0 * UNIT), "hull stands 72 units (%.3f m)" % t.stand_height)
	_check(is_equal_approx(t.crouch_height, 54.0 * UNIT), "crouched hull is 54 units")
	_check(is_equal_approx(t.radius * 2.0, 32.0 * UNIT), "hull is 32 units wide")
	_check(is_equal_approx(FcPlayer.eye_height() / UNIT, 64.0), "eye is 64 units (%.1f)" % (FcPlayer.eye_height() / UNIT))
	_check(is_equal_approx(t.height_at(1.0) - t.radius * 0.5, 46.0 * UNIT), "crouched eye is 46 units")
	_check(t.validate().ok, "the tunables validate")

	for body: StringName in GSHumanoidLook.BODIES:
		_measure(body, t.stand_height)

	# A server that wants the 0.0254 m unit, or a taller person, gets that on every body.
	FcPlayerTunables.configure_body(80.0, 40.0, 16.0, 0.0254)
	var tall := FcPlayer.fc_tunables()
	_check(is_equal_approx(tall.stand_height, 80.0 * 0.0254) and is_equal_approx(FcPlayer.eye_height(), 80.0 * 0.0254 - 8.0 * 0.0254), "avatar_height_units 80 at 0.0254 m: hull and eye follow")
	for body: StringName in GSHumanoidLook.BODIES:
		_measure(body, tall.stand_height)
	# A crouch under the hull's width is lifted to it.
	FcPlayerTunables.configure_body(72.0, 10.0, 16.0, UNIT)
	_check(is_equal_approx(FcPlayerTunables.avatar_crouch_units, 32.0), "a crouch shorter than the hull is wide is raised to it")
	FcPlayerTunables.configure_body(72.0, 54.0, 16.0, UNIT)
	_report()
	get_tree().quit(0 if _failed == 0 else 1)


## Builds the body's figure at [param want] and measures the drawn mesh, not the number passed in.
func _measure(body: StringName, want: float) -> void:
	var figure := GSHumanoidFigure.new()
	add_child(figure)
	figure.build(_look(body), want)
	var mesh := figure.find_children("*", "MeshInstance3D", true, false).front() as MeshInstance3D
	var model := figure.find_child("Body", false, false) as Node3D
	if not figure.from_art or mesh == null:
		_check(false, "%s: body model loads" % body)
		figure.free()
		return
	var got := GSHumanoidFrames.measure(mesh, model) * model.transform.basis.get_scale().y
	_check(absf(got - want) < 0.01, "%s stands %.3f m, wanted %.3f (%.1f units)" % [body, got, want, got / UNIT])
	figure.free()


func _look(body: StringName) -> GSHumanoidLook:
	var look := GSHumanoidLook.stock(0)
	look.body = body
	return look
