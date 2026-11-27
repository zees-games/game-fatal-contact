extends "res://addons/gs_weapon/view/gs_weapon_scope_prefs.gd"

## The player's scope settings (cl_scope_mode, cl_scope_walk_clear): gs-weapon's shared prefs under an
## Fatal Contact name, so the player script reads them without depending on the view arms (which depend on the player).


## Native builds start in the lens view (mode 1): a normal screen with the rifle drawn and the zoom in its own scope. The web build starts in the full-screen scope (mode 2) because the lens's second
## camera in a SubViewport came out flat grey there (Godot 4.7, WebGL2). `cl_scope_mode` picks either; a server scope_mode rule can pin one.
static func default_mode(web: bool) -> int:
	return 2 if web else 1


static func _static_init() -> void:
	mode = default_mode(OS.has_feature("web"))
