extends "res://addons/gs_weapon/view/gs_weapon_scope_prefs.gd"

## The player's scope settings (cl_scope_mode, cl_scope_walk_clear): gs-weapon's shared prefs under an
## Fatal Contact name, so the player script reads them without depending on the view arms (which depend on the player).


## Every build starts in the full-screen scope (mode 2), as Counter-Strike: Source draws it: the main camera zoomed to the weapon's field of view and the screen black round a circle as tall as the
## screen. Mode 1 is a small lens in the middle of a normal screen (the gun's own ocular, a few centimetres wide on a sniper), too small to aim through; on the web its second camera in a SubViewport
## also came out flat grey (Godot 4.7, WebGL2). `cl_scope_mode 1` still picks the lens; a server scope_mode rule can pin either.
static func default_mode(_web: bool) -> int:
	return 2


static func _static_init() -> void:
	mode = default_mode(OS.has_feature("web"))
