extends "res://addons/gs_weapon/view/gs_weapon_scope_prefs.gd"

## The player's scope settings (cl_scope_mode, cl_scope_walk_clear): gs-weapon's shared prefs under an
## Fatal Contact name, so the player script reads them without depending on the view arms (which depend on the player).


## The browser build starts in the full-screen scope (mode 2). Mode 1 draws its lens from a second camera in a
## SubViewport, and on the web (Godot 4.7, WebGL2) that pass has no directional light and no linear-to-sRGB step, so
## the lens came out flat grey while the surround stayed the whole un-zoomed world. Mode 2 zooms the main camera and
## blacks the surround, with no SubViewport. `cl_scope_mode` still picks either; a server scope_mode rule can pin one.
static func default_mode(web: bool) -> int:
	return 2 if web else 1


static func _static_init() -> void:
	mode = default_mode(OS.has_feature("web"))
